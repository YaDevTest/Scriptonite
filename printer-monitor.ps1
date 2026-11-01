[CmdletBinding()]
param(
    [ValidateRange(1, 3600)][int]$IntervalSeconds = 30,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'

function Get-PrinterQueueState {
    param($Printer, $WmiPrinter)
    $flags = [uint32]$Printer.PrinterStatus
    $states = New-Object 'System.Collections.Generic.List[string]'
    if (($flags -band 128) -or ($WmiPrinter -and ($WmiPrinter.WorkOffline -or $WmiPrinter.PrinterStatus -eq 7))) { $states.Add('Автономный') }
    if ($flags -band 1) { $states.Add('Приостановлен') }
    $labels = [ordered]@{
        '2'='Ошибка'; '8'='Застревание бумаги'; '16'='Нет бумаги'; '32'='Ручная подача'
        '64'='Проблема с бумагой'; '512'='Занят'; '1024'='Печатает'; '2048'='Выходной лоток полон'
        '4096'='Недоступен'; '8192'='Ожидает'; '16384'='Обработка'; '32768'='Инициализация'
        '65536'='Прогрев'; '131072'='Мало тонера'; '262144'='Нет тонера'; '1048576'='Требуется вмешательство'
        '2097152'='Мало памяти'; '4194304'='Открыта крышка'; '8388608'='Статус сервера неизвестен'; '16777216'='Энергосбережение'
    }
    foreach ($bit in $labels.Keys) { if ($flags -band [uint32]$bit) { $states.Add($labels[$bit]) } }
    if ($states.Count -eq 0) {
        if ($WmiPrinter -and $WmiPrinter.PrinterStatus -eq 4) { $states.Add('Печатает') }
        elseif ($WmiPrinter -and $WmiPrinter.PrinterStatus -eq 5) { $states.Add('Прогрев') }
        else { $states.Add('Простаивает (статус Windows)') }
    }
    return $states -join '; '
}

function Get-PrinterExact {
    param([string]$Name)
    $printer = Get-Printer -Full -ErrorAction Stop | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $printer) { throw "Принтер больше не установлен: $Name" }
    return $printer
}

function Get-PrinterRegistryDeviceId {
    param([string]$Name, [string]$PortName)
    $paths = @(
        "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Print\Printers\$Name\PnPData",
        "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Print\Monitors\USB Monitor\Ports\$PortName"
    )
    foreach ($path in $paths) {
        $data = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if (-not $data) { continue }
        foreach ($property in $data.PSObject.Properties) {
            if ($property.Name -like 'PS*' -or $property.Value -isnot [string]) { continue }
            $value = [string]$property.Value
            if ($value -match '^USBPRINT\\|^USB\\VID_') { return $value }
        }
    }
    return ''
}

function Get-PrinterHardware {
    param($Printer, $WmiPrinter, $PresentIds, [bool]$PresenceAvailable)
    $id = if ($WmiPrinter) { [string]$WmiPrinter.PNPDeviceID } else { '' }
    if (-not $id -or $id -match '^SWD\\PRINTENUM\\') {
        $mapped = Get-PrinterRegistryDeviceId -Name $Printer.Name -PortName $Printer.PortName
        if ($mapped) { $id = $mapped }
    }
    $ids = New-Object 'System.Collections.Generic.List[string]'
    $hardwareIds = New-Object 'System.Collections.Generic.List[string]'
    $pnpData = Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Print\Printers\$($Printer.Name)\PnPData" -ErrorAction SilentlyContinue
    if ($pnpData) {
        foreach ($value in @($pnpData.HardwareID)) {
            if ($value -and -not $hardwareIds.Contains([string]$value)) { $hardwareIds.Add([string]$value) }
        }
    }
    $visited = @{}
    $physicalId = ''
    for ($depth = 0; $id -and $depth -lt 12; $depth++) {
        if ($visited.ContainsKey($id)) { break }
        $visited[$id] = $true
        if ($id -match '^USB\\ROOT_HUB|^PCI\\|^HTREE\\') { break }
        $ids.Add($id)
        if (-not $physicalId -and $id -match '^(USBPRINT|USB)\\') { $physicalId = $id }
        if (-not (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) { break }
        $props = @{}
        Get-PnpDeviceProperty -InstanceId $id -KeyName @('DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_Parent') -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -eq $id -and $null -ne $_.Data } |
            ForEach-Object { $props[$_.KeyName] = $_.Data }
        foreach ($value in @($props['DEVPKEY_Device_HardwareIds'])) {
            if ($value -and -not $hardwareIds.Contains([string]$value)) { $hardwareIds.Add([string]$value) }
        }
        $parent = [string]$props['DEVPKEY_Device_Parent']
        # Do not expose unrelated system devices above the physical USB device.
        if ($id -match '^USB\\VID_' -and $id -notmatch '&MI_[0-9A-F]{2}') { break }
        $id = $parent
    }
    $vidPid = @(@($ids) + @($hardwareIds) | ForEach-Object {
        if ($_ -match 'VID_([0-9A-F]{4}).*PID_([0-9A-F]{4})') { '{0}:{1}' -f $Matches[1], $Matches[2] }
    } | Sort-Object -Unique) -join ', '
    $presence = $null
    if ($physicalId -and $PresenceAvailable) { $presence = $PresentIds.ContainsKey($physicalId) }
    return [PSCustomObject]@{ PhysicalId=$physicalId; Present=$presence; InstanceIds=@($ids); HardwareIds=@($hardwareIds); VidPid=$vidPid }
}

function Get-PrinterTcpChecks {
    param([hashtable]$Ports)
    $pending = @{}
    $results = @{}
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($port in $Ports.Values) {
            $address = [string]$port.PrinterHostAddress
            $number = 0
            if (-not $address -or -not [int]::TryParse([string]$port.PortNumber, [ref]$number) -or $number -lt 1 -or $number -gt 65535) { continue }
            $key = "$address`:$number"
            if ($pending.ContainsKey($key)) { continue }
            $client = New-Object Net.Sockets.TcpClient
            try {
                $task = $client.ConnectAsync($address, $number)
                $pending[$key] = [PSCustomObject]@{ Client=$client; Task=$task }
            } catch { $client.Dispose(); $results[$key] = 'Нет TCP-ответа' }
        }
        foreach ($key in $pending.Keys) {
            $request = $pending[$key]
            try {
                $remaining = [int][Math]::Max(0, 1000-$clock.ElapsedMilliseconds)
                if (-not $request.Task.IsCompleted -and -not $request.Task.Wait($remaining)) { throw 'Timeout' }
                $null = $request.Task.GetAwaiter().GetResult()
                $results[$key] = 'TCP доступен'
            } catch { $results[$key] = 'Нет TCP-ответа' }
        }
    } finally {
        foreach ($request in $pending.Values) { $request.Client.Dispose() }
        $clock.Stop()
    }
    return ,$results
}

function Get-PrinterSnapshot {
    Write-Progress -Id 31 -Activity 'Загрузка данных принтеров' -Status 'Получаю список очередей Windows...' -PercentComplete -1
    $printers = @(Get-Printer -ErrorAction Stop | Sort-Object Name)
    $wmi = @{}
    Write-Progress -Id 31 -Activity 'Загрузка данных принтеров' -Status 'Читаю состояние устройств Windows (WMI)...' -PercentComplete -1
    try { Get-CimInstance -ClassName Win32_Printer -OperationTimeoutSec 10 -ErrorAction Stop | ForEach-Object { $wmi[$_.Name] = $_ } } catch {}
    $ports = @{}
    Write-Progress -Id 31 -Activity 'Загрузка данных принтеров' -Status 'Читаю порты печати...' -PercentComplete -1
    try { Get-PrinterPort -ErrorAction Stop | ForEach-Object { $ports[$_.Name] = $_ } } catch {}
    Write-Progress -Id 31 -Activity 'Загрузка данных принтеров' -Status 'Проверяю доступность сетевых портов...' -PercentComplete -1
    $tcpChecks = Get-PrinterTcpChecks $ports
    $presentIds = @{}
    $presenceAvailable = $false
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        Write-Progress -Id 31 -Activity 'Загрузка данных принтеров' -Status 'Определяю подключённые USB-устройства...' -PercentComplete -1
        try {
            Get-PnpDevice -PresentOnly -ErrorAction Stop | ForEach-Object { $presentIds[$_.InstanceId] = $true }
            $presenceAvailable = $true
        } catch {}
    }
    $number = 0
    foreach ($printer in $printers) {
        $number++
        Write-Progress -Id 31 -Activity 'Загрузка данных принтеров' -Status ("Принтер $number из $($printers.Count): $($printer.Name) — устройство и очередь") -PercentComplete ([int](100*($number-1)/[Math]::Max(1,$printers.Count)))
        $wp = $wmi[$printer.Name]
        $state = Get-PrinterQueueState $printer $wp
        $hardware = Get-PrinterHardware $printer $wp $presentIds $presenceAvailable
        $connection = 'Не проверена'
        if ($null -ne $hardware.Present) {
            $connection = if ($hardware.Present) { 'USB подключён' } else { 'USB не обнаружен' }
        } elseif ($printer.PortName -match '^(PORTPROMPT:|FILE:|NUL:)$' -or $printer.DriverName -match '^Microsoft (Print To PDF|XPS Document Writer)') {
            $connection = 'Файл / виртуальный'
        }
        $queueCount = $null
        $jobsError = ''
        try { $queueCount = @(Get-PrintJob -PrinterName $printer.Name -ErrorAction Stop).Count } catch { $jobsError = $_.Exception.Message }
        $portInfo = New-Object 'System.Collections.Generic.List[string]'
        $networkStates = New-Object 'System.Collections.Generic.List[string]'
        $names = if ($ports.ContainsKey($printer.PortName)) { @($printer.PortName) } else { @($printer.PortName -split ',\s*') }
        foreach ($name in $names) {
            $port = $ports[$name]
            if ($port) {
                if ($port.PrinterHostAddress) {
                    $portInfo.Add("$name -> $($port.PrinterHostAddress):$($port.PortNumber)")
                    $endpoint = "$($port.PrinterHostAddress):$($port.PortNumber)"
                    if ($tcpChecks.ContainsKey($endpoint)) { $networkStates.Add("$endpoint — $($tcpChecks[$endpoint])") }
                }
                elseif ($port.Description) { $portInfo.Add("$name — $($port.Description)") }
            }
        }
        if ($networkStates.Count) { $connection = $networkStates -join '; ' }
        elseif ($printer.PortName -like 'WSD*') { $connection = 'WSD: связь не подтверждена' }
        elseif ($printer.PortName -like '\\.\pipe\*') { $connection = 'Локальный программный порт' }
        elseif ($printer.Name -like '\\*' -or $printer.PortName -like '\\*') { $connection = 'Общий принтер: связь не подтверждена' }
        [PSCustomObject]@{
            Number=$number; Name=$printer.Name; State=$state; Connection=$connection; Jobs=$queueCount
            JobsError=$jobsError; Port=$printer.PortName; PortDetails=($portInfo -join '; ')
            Driver=$printer.DriverName; Hardware=$hardware; Default=($wp -and $wp.Default)
        }
    }
}

function Clear-SelectedPrinterQueue {
    param([string]$Name)
    $null = Get-PrinterExact $Name
    $jobs = @(Get-PrintJob -PrinterName $Name -ErrorAction Stop)
    $removed = 0
    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($job in $jobs) {
        try { Remove-PrintJob -InputObject $job -Confirm:$false -ErrorAction Stop; $removed++ }
        catch { $failures.Add("Задание $($job.ID): $($_.Exception.Message)") }
    }
    $remaining = '?'
    try { $remaining = @(Get-PrintJob -PrinterName $Name -ErrorAction Stop).Count } catch {}
    $message = "[$Name] Запрошено удаление $removed из $($jobs.Count) заданий. Осталось в очереди: $remaining."
    if ($failures.Count) { $message += " Ошибки: $($failures -join '; ')" }
    return $message
}

function Invoke-SelectedPrinterMethod {
    param([string]$Name, [ValidateSet('PrintTestPage','Resume')][string]$Method)
    if ($Method -eq 'PrintTestPage') {
        # WMI printing can fail with access denied even when an interactive user
        # can print. Run the documented interactive PrintUI test-page command.
        return Open-SelectedPrinterWindow -Name $Name -Window 'TestPage'
    }
    $null = Get-PrinterExact $Name
    $printer = Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $printer) { throw 'Windows не предоставила WMI-объект выбранного принтера.' }
    $result = Invoke-CimMethod -InputObject $printer -MethodName $Method -ErrorAction Stop
    if ($null -eq $result -or $null -eq $result.ReturnValue) { throw 'Windows не вернула результат операции.' }
    if ([uint32]$result.ReturnValue -ne 0) { throw "Windows вернула код $($result.ReturnValue). Код 5 означает отказ в доступе." }
    # Resume the queue, then only jobs explicitly paused; no restart or duplication.
    $resumed = 0
    foreach ($job in @(Get-PrintJob -PrinterName $Name -ErrorAction Stop)) {
        if (([uint32]$job.JobStatus -band 1) -ne 0) {
            Resume-PrintJob -InputObject $job -ErrorAction Stop
            $resumed++
        }
    }
    return "[$Name] Пауза очереди снята. Возобновлено приостановленных заданий: $resumed. Автономный режим и физическое подключение не изменялись."
}

function Open-SelectedPrinterWindow {
    param([string]$Name, [ValidateSet('Queue','Properties','TestPage')][string]$Window)
    $printer = Get-PrinterExact $Name
    if ($Name.Contains('"')) { throw 'Не поддерживается кавычка в имени принтера для PrintUI.' }
    $mode = switch ($Window) { 'Queue' { '/o' } 'Properties' { '/p' } 'TestPage' { '/k' } }
    $arguments = 'printui.dll,PrintUIEntry {0} /n "{1}"' -f $mode, $Name
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\rundll32.exe') -ArgumentList $arguments -WindowStyle Normal -ErrorAction Stop | Out-Null
    if ($Window -eq 'TestPage') {
        if ($printer.PortName -match 'PORTPROMPT|PDFPrint' -or $printer.DriverName -match 'PDF') {
            return "[$Name] Запущена тестовая печать через Windows. Проверьте отдельное окно PDF-принтера: может потребоваться выбор имени файла. Создание PDF ещё не подтверждено."
        }
        return "[$Name] Запущена команда тестовой печати Windows. Результат смотрите в очереди и окне Windows; фактическая печать ещё не подтверждена."
    }
    return "Открыто окно Windows для [$Name]."
}

function Restart-PrinterSpooler {
    $service = Get-Service -Name Spooler -ErrorAction Stop
    if ($service.Status -eq 'Running') {
        # No -Force: do not silently stop other dependent services.
        Restart-Service -Name Spooler -ErrorAction Stop
    } else { Start-Service -Name Spooler -ErrorAction Stop }
    $service = Get-Service -Name Spooler -ErrorAction Stop
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
    return 'Диспетчер печати работает. Другие очереди не очищались.'
}

function Restart-PrinterUsbDevice {
    param([string]$InstanceId)
    if ($InstanceId -notmatch '^USBPRINT\\|^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\|^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}&') {
        throw 'Перезапуск разрешён только для точно определённого USB-устройства принтера.'
    }
    if ([Environment]::OSVersion.Version.Build -lt 19041) {
        throw 'Перезапуск через pnputil требует Windows 10 2004 или новее.'
    }
    $device = Get-PnpDevice -PresentOnly -InstanceId $InstanceId -ErrorAction Stop |
        Where-Object { $_.InstanceId -eq $InstanceId } | Select-Object -First 1
    if (-not $device) { throw 'USB-устройство сейчас не подключено.' }
    $tool = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    $output = @(& $tool /restart-device $InstanceId 2>&1)
    $code = $LASTEXITCODE
    if ($code -eq 3010) { return 'Windows запросила перезагрузку ПК для завершения перезапуска устройства. Автоматическая перезагрузка не выполняется.' }
    if ($code -ne 0) { throw "PnPUtil: код $code. $($output -join ' ')" }
    return "USB-устройство перезапущено: $InstanceId"
}

function Set-SelectedPrinterOnline {
    param([string]$Name)
    $printer = Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop |
        Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $printer) { throw "Windows не предоставила объект принтера: $Name" }
    if ($printer.WorkOffline) {
        $null = Set-CimInstance -InputObject $printer -Property @{ WorkOffline=$false } -ErrorAction Stop
        $check = Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop |
            Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if (-not $check -or $check.WorkOffline) { throw 'Windows не подтвердила снятие режима «Работать автономно».' }
    }
    return Invoke-SelectedPrinterMethod -Name $Name -Method Resume
}

function Invoke-PrinterRecoveryStep {
    param([string]$Title, [scriptblock]$Action)
    Write-Host "`n$Title" -ForegroundColor Cyan
    try {
        $detail = @(& $Action) -join "`n"
        if ($detail) { Write-Host $detail -ForegroundColor Green }
        return [PSCustomObject]@{ Success=$true; Title=$Title; Detail=$detail }
    } catch {
        $detail = $_.Exception.Message
        Write-Host $detail -ForegroundColor Red
        return [PSCustomObject]@{ Success=$false; Title=$Title; Detail=$detail }
    }
}

function Get-SelectedPrinterLanTarget {
    param([string]$Name)
    $printer = Get-PrinterExact $Name
    # Use the installed TCP/IP port's explicit address, never guess an address
    # from a user-assigned queue name, driver name, WSD UUID or pooled ports.
    $ports = @(Get-PrinterPort -ErrorAction Stop | Where-Object { $_.Name -eq $printer.PortName -and $_.PrinterHostAddress })
    if ($ports.Count -ne 1) { throw 'Для этой очереди не найден один однозначный TCP/IP-порт с адресом. Проверьте вкладку «Порты».' }
    $port = $ports[0]
    return [PSCustomObject]@{
        Name=$Name; Address=[string]$port.PrinterHostAddress; PortName=[string]$printer.PortName
        Driver=[string]$printer.DriverName; Community=[string]$port.SNMPCommunity
    }
}

function New-PrinterSnmpClient {
    try { return New-Object -ComObject OlePrn.OleSNMP -ErrorAction Stop }
    catch { throw 'В Windows недоступен компонент OlePrn.OleSNMP. Для этой версии используйте веб-интерфейс или фирменную утилиту принтера.' }
}

function Get-PrinterResetOids {
    param($Tree)
    # ISNMP.GetTree returns a two-dimensional array of OIDs and values.
    # Scan only for exact instances of prtGeneralReset, irrespective of layout.
    $found = @{}
    foreach ($value in $Tree) {
        if ($value -isnot [string]) { continue }
        $oid = $value.Trim().TrimStart('.')
        if ($oid -match '^43\.') { $oid = '1.3.6.1.2.1.' + $oid }
        if ($oid -match '^1\.3\.6\.1\.2\.1\.43\.5\.1\.1\.3\.[1-9][0-9]*$') { $found['.'+$oid] = $true }
    }
    return @($found.Keys | Sort-Object)
}

function Invoke-PrinterLanReset {
    param([string]$Name, [switch]$RecoveryConfirmed)
    $target = Get-SelectedPrinterLanTarget $Name
    Write-Host "`nLAN-ПРИНТЕР: $Name" -ForegroundColor Cyan
    Write-Host "Адрес: $($target.Address) | Порт Windows: $($target.PortName)"
    Write-Host "Драйвер: $($target.Driver)"
    Write-Host 'Проверяется стандарт Printer MIB. Марка Xprinter/Rongta сама по себе не гарантирует его поддержку.' -ForegroundColor DarkGray
    Write-Host 'Для сброса нужны поддержка SNMP и community с правом записи.' -ForegroundColor Yellow
    Write-Host 'Введите community скрыто или нажмите Enter для значения из порта Windows / public.'
    $secret = Read-Host 'SNMP community' -AsSecureString
    $community = $target.Community
    if (-not $community) { $community = 'public' }
    $pointer = [IntPtr]::Zero
    $client = $null
    try {
        if ($secret -and $secret.Length -gt 0) {
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
            $community = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        }
        $client = New-PrinterSnmpClient
        # Zero retries: a timed-out write must not silently repeat a reset.
        $null = $client.Open($target.Address, $community, 0, 1000)
        $description = ''
        try { $description = [string]$client.Get('.1.3.6.1.2.1.1.1.0') } catch {}
        if ($description) { Write-Host "Ответ устройства: $description" -ForegroundColor Cyan }
        try {
            $tree = $client.GetTree('.1.3.6.1.2.1.43.5.1.1.3')
            $oids = @(Get-PrinterResetOids $tree)
        } catch { throw 'Объект SNMP-сброса не получен: возможны отсутствие поддержки, закрытый UDP 161 или неподходящая community. Команда сброса не отправлялась.' }
        if (-not $oids.Count) { throw 'Принтер не предоставил prtGeneralReset. Непроверенные команды Xprinter/Rongta не отправляются; нужен способ для конкретной модели.' }
        $oid = $oids[0]
        if ($oids.Count -gt 1) {
            if ($RecoveryConfirmed) { throw 'Принтер сообщил несколько объектов сброса. Автоматически выбирать один небезопасно; сетевой сброс не отправлен.' }
            Write-Host 'Устройство сообщило несколько объектов сброса:' -ForegroundColor Yellow
            for ($i=0; $i -lt $oids.Count; $i++) { Write-Host "[$($i+1)] $($oids[$i])" }
            $index = 0
            if (-not [int]::TryParse([string](Read-Host 'Выберите объект или 0 — отмена'), [ref]$index) -or $index -lt 1 -or $index -gt $oids.Count) {
                return 'LAN-сброс отменён. Команда не отправлялась.'
            }
            $oid = $oids[$index-1]
        }
        $state = $client.Get($oid)
        if ($null -eq $state -or [int]$state -ne 3) { throw "Принтер не подтвердил состояние notResetting(3). Сброс не отправлен; значение: $state." }
        Write-Host "Объект сброса найден: $oid" -ForegroundColor Green
        Write-Host 'Наличие объекта не гарантирует, что разрешена запись или поддерживается каждый вид сброса.' -ForegroundColor DarkGray
        Write-Host 'Сброс прервёт работу устройства и может очистить его оперативные буферы, включая чеки.' -ForegroundColor Yellow
        Write-Host 'Заводской сброс не предлагается. IP, DHCP и другие сетевые параметры скрипт не изменяет.' -ForegroundColor DarkGray
        if ($RecoveryConfirmed) {
            $value = 5
            Write-Host 'Выполняется ранее подтверждённый тёплый сброс к сохранённым настройкам.' -ForegroundColor Yellow
        } else {
            Write-Host '[1] Тёплый сброс к сохранённым настройкам (resetToNVRAM)'
            Write-Host '[2] Перезапуск устройства (powerCycleReset, если поддерживается)'
            Write-Host '[0] Отмена'
            $choice = ([string](Read-Host 'Подтвердите действие')).Trim()
            $value = switch ($choice) { '1' { 5 } '2' { 4 } default { 0 } }
        }
        if ($value -eq 0) { return 'LAN-сброс отменён. Команда не отправлялась.' }
        $check = Get-SelectedPrinterLanTarget $Name
        if ($check.Address -ne $target.Address -or $check.PortName -ne $target.PortName -or $check.Driver -ne $target.Driver) {
            throw 'Адрес, драйвер или порт изменились во время проверки. Сброс отменён.'
        }
        try { $null = $client.Set($oid, [int]$value) }
        catch { throw 'Подтверждение SNMP SET не получено. Возможны отказ в записи, неподдерживаемая операция или потеря ответа при сбросе. Результат неизвестен; автоматический повтор не выполняется.' }
        return "[$Name / $($target.Address)] Получено подтверждение SNMP-команды сброса. Завершение перезапуска и готовность к печати ещё не проверены."
    } finally {
        if ($client) {
            try { $null = $client.Close() } catch {}
            if ([Runtime.InteropServices.Marshal]::IsComObject($client)) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($client) }
        }
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if ($secret) { $secret.Dispose() }
        $community = $null
    }
}

function Invoke-ExperimentalPrinterRecovery {
    param([string]$Name)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Для восстановления нужны права администратора.'
        }
    } finally { $identity.Dispose() }
    $original = Get-PrinterExact $Name
    $driver = [string]$original.DriverName
    $port = [string]$original.PortName
    $wmi = Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop |
        Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    $present = @{}
    $presenceAvailable = $false
    try {
        Get-PnpDevice -PresentOnly -ErrorAction Stop | ForEach-Object { $present[$_.InstanceId] = $true }
        $presenceAvailable = $true
    } catch {}
    $hardware = Get-PrinterHardware $original $wmi $present $presenceAvailable
    $usbId = ''
    $lanTarget = $null
    # An explicit TCP/IP queue port takes precedence over any stale USB PnP
    # association, even if that printer is also physically attached over USB.
    try { $lanTarget = Get-SelectedPrinterLanTarget $Name } catch {}
    if (-not $lanTarget -and $hardware.Present -eq $true -and $hardware.PhysicalId -match '^USBPRINT\\|^USB\\VID_') { $usbId = $hardware.PhysicalId }

    Write-Host "`nЭКСПЕРИМЕНТАЛЬНОЕ ВОССТАНОВЛЕНИЕ: $Name" -ForegroundColor Yellow
    Write-Host "Драйвер: $driver"
    Write-Host "Порт: $port"
    if ($lanTarget) { Write-Host "Подключение определено: LAN / TCP-IP — $($lanTarget.Address)" -ForegroundColor Cyan }
    elseif ($usbId) { Write-Host 'Подключение определено: USB' -ForegroundColor Cyan }
    else { Write-Host 'Физическое подключение не подтверждено: будет выполнено восстановление очереди Windows.' -ForegroundColor Yellow }
    Write-Host 'Будет перезапущен Spooler — временно прервётся печать на ВСЕХ принтерах.' -ForegroundColor Yellow
    Write-Host 'Документы будут удалены ТОЛЬКО из выбранной очереди.' -ForegroundColor Red
    Write-Host 'Будет снята пауза и режим «Работать автономно» выбранной очереди.'
    if ($usbId) {
        Write-Host "USB-устройство будет перезапущено: $usbId" -ForegroundColor Yellow
        Write-Host 'У МФУ на время могут отключиться и другие функции этого же устройства.' -ForegroundColor DarkGray
    } elseif ($lanTarget) {
        Write-Host "Для LAN-принтера $($lanTarget.Address) будет проверен SNMP и отправлен тёплый сброс к сохранённым настройкам, если поддерживается." -ForegroundColor Yellow
    } else { Write-Host 'Адрес LAN или подключённое USB-устройство не подтверждены: перезапуск устройства пропускается.' -ForegroundColor DarkGray }
    Write-Host 'Очередь, драйвер и порт не переустанавливаются; пакеты драйверов не удаляются.' -ForegroundColor DarkGray
    Write-Host 'Для общего принтера служба печати на удалённом сервере не перезапускается.' -ForegroundColor DarkGray
    Write-Host '[1] Начать восстановление'
    Write-Host '[0] Отмена'
    if (([string](Read-Host 'Подтверждение')).Trim() -ne '1') { return 'Восстановление отменено. Изменений нет.' }

    $steps = New-Object 'System.Collections.Generic.List[object]'
    $spoolerStep = Invoke-PrinterRecoveryStep '1. Перезапуск диспетчера печати' { Restart-PrinterSpooler }
    $steps.Add($spoolerStep)
    if (-not $spoolerStep.Success) {
        return "Восстановление остановлено: Spooler не перезапущен. $($spoolerStep.Detail)"
    }
    $clearStep = Invoke-PrinterRecoveryStep '2. Очистка выбранной очереди' {
        $check = Get-PrinterExact $Name
        if ($check.DriverName -ne $driver -or $check.PortName -ne $port) { throw 'Драйвер или порт изменились во время операции; очистка отменена.' }
        $detail = Clear-SelectedPrinterQueue $Name
        $left = @(Get-PrintJob -PrinterName $Name -ErrorAction Stop).Count
        if ($left -gt 0) { throw "После запроса удаления в очереди ещё $left заданий. $detail" }
        $detail
    }
    $steps.Add($clearStep)
    if (-not $clearStep.Success) {
        return "Восстановление остановлено: выбранную очередь не удалось очистить. $($clearStep.Detail)"
    }
    if ($usbId) { $steps.Add((Invoke-PrinterRecoveryStep '3. Перезапуск USB-устройства принтера' { Restart-PrinterUsbDevice $usbId })) }
    elseif ($lanTarget) { $steps.Add((Invoke-PrinterRecoveryStep '3. Проверка и сброс LAN-принтера' { Invoke-PrinterLanReset -Name $Name -RecoveryConfirmed })) }
    $steps.Add((Invoke-PrinterRecoveryStep '4. Снятие автономного режима и паузы' { Set-SelectedPrinterOnline $Name }))
    $steps.Add((Invoke-PrinterRecoveryStep '5. Проверка драйвера и порта' {
        $check = Get-PrinterExact $Name
        if ($check.DriverName -ne $driver -or $check.PortName -ne $port) { throw 'Драйвер или порт изменились. Проверьте настройки выбранного принтера.' }
        "Очередь [$Name] доступна. Драйвер и порт прежние."
    }))
    $failed = @($steps | Where-Object { -not $_.Success })
    if ($failed.Count) {
        return "Восстановление выполнено частично. Ошибки: $(($failed | ForEach-Object { "$($_.Title): $($_.Detail)" }) -join '; ')."
    }
    return 'Сброс выполнен. Готовность к печати не подтверждена: проверьте подключение и отправьте тестовую страницу пунктом [2].'
}

function Show-PrinterHardware {
    param($Printer)
    Write-Host "`nПРИНТЕР: $($Printer.Name)" -ForegroundColor Cyan
    Write-Host "Драйвер: $($Printer.Driver)"
    Write-Host "Порт (как указан в Windows): $($Printer.Port)"
    if ($Printer.PortDetails) { Write-Host $Printer.PortDetails }
    Write-Host "Связь: $($Printer.Connection)"
    if ($Printer.JobsError) { Write-Host "Очередь не удалось прочитать: $($Printer.JobsError)" -ForegroundColor Yellow }
    if ($Printer.Hardware.VidPid) { Write-Host "USB VID:PID: $($Printer.Hardware.VidPid)" -ForegroundColor Green }
    else { Write-Host 'USB VID/PID не определён: очередь может быть сетевой, виртуальной или не привязана к PnP-устройству.' -ForegroundColor DarkGray }
    Write-Host 'ИДЕНТИФИКАТОРЫ УСТРОЙСТВА:' -ForegroundColor Cyan
    foreach ($id in $Printer.Hardware.InstanceIds) { Write-Host $id }
    Write-Host 'HARDWARE ID ДЛЯ ПОИСКА ДРАЙВЕРОВ:' -ForegroundColor Cyan
    if ($Printer.Hardware.HardwareIds.Count) { foreach ($id in $Printer.Hardware.HardwareIds) { Write-Host $id } }
    else { Write-Host 'Windows не предоставила Hardware ID для этой очереди.' -ForegroundColor DarkGray }
}

function Read-PrinterMenu {
    param([int]$Seconds)
    if ([Console]::IsInputRedirected) { return [string](Read-Host 'Выбор') }
    Write-Host 'Выбор: ' -NoNewline
    $text = ''
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Enter') { Write-Host ''; return $text }
            if ($key.Key -eq 'Backspace') {
                if ($text.Length) { $text = $text.Substring(0, $text.Length-1); Write-Host "`b `b" -NoNewline }
            } elseif (-not [char]::IsControl($key.KeyChar)) {
                $text += $key.KeyChar
                Write-Host $key.KeyChar -NoNewline
                # Allow time to finish selecting an action once typing starts.
                $deadline = (Get-Date).AddSeconds($Seconds)
            }
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Host ''
    return ''
}

function Get-PrinterDisplayColor {
    param($Printer)
    $errorStates = 'Автоном|Приостанов|Ошибка|Застревание|Нет бумаги|Проблема с бумагой|Недоступен|Нет тонера|Требуется вмешательство|Мало памяти|Открыта крышка|Статус сервера неизвестен|Выходной лоток полон'
    if (($null -ne $Printer.Jobs -and $Printer.Jobs -gt 0) -or $Printer.JobsError -or
        $Printer.State -match $errorStates -or $Printer.Connection -match 'USB не обнаружен|Нет TCP-ответа') {
        return 'Red'
    }
    return 'White'
}

function Split-PrinterCell {
    param([string]$Text, [int]$Width)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in @($Text.Replace("`r", '').Split("`n"))) {
        if (-not $part.Length) { $lines.Add(''); continue }
        for ($offset = 0; $offset -lt $part.Length; $offset += $Width) {
            $lines.Add($part.Substring($offset, [Math]::Min($Width, $part.Length-$offset)))
        }
    }
    return ,$lines.ToArray()
}

function Write-PrinterTableRow {
    param([string[]]$Cells, [int[]]$Widths, [string]$Color)
    $wrapped = @{}
    $height = 1
    for ($column = 0; $column -lt $Widths.Count; $column++) {
        $wrapped[$column] = Split-PrinterCell $Cells[$column] $Widths[$column]
        $height = [Math]::Max($height, $wrapped[$column].Count)
    }
    for ($line = 0; $line -lt $height; $line++) {
        for ($column = 0; $column -lt $Widths.Count; $column++) {
            $text = if ($line -lt $wrapped[$column].Count) { $wrapped[$column][$line] } else { '' }
            $cellColor = if ($column -eq 3) { 'Yellow' } else { $Color }
            Write-Host $text.PadRight($Widths[$column]) -ForegroundColor $cellColor -NoNewline
            if ($column -lt $Widths.Count-1) { Write-Host ' ' -ForegroundColor $Color -NoNewline }
        }
        Write-Host ''
    }
}

function Write-PrinterTable {
    param([object[]]$Printers)
    $headers = @('№', 'Принтер', 'Состояние', 'Документы', 'Порт', 'Связь')
    $widths = @(3, 12, 16, 9, 8, 12)
    $limits = @(3, 32, 42, 9, 28, 50)
    $rows = @($Printers | ForEach-Object {
        $count = if ($null -eq $_.Jobs) { '?' } else { [string]$_.Jobs }
        [PSCustomObject]@{ Cells=@([string]$_.Number, [string]$_.Name, [string]$_.State, $count, [string]$_.Port, [string]$_.Connection); Color=(Get-PrinterDisplayColor $_) }
    })
    $desired = @($widths)
    foreach ($row in $rows) {
        for ($column = 0; $column -lt $widths.Count; $column++) {
            $desired[$column] = [Math]::Max($desired[$column], [Math]::Min($limits[$column], $row.Cells[$column].Length))
        }
    }
    $available = [Math]::Max(65, $Host.UI.RawUI.WindowSize.Width-1)
    $remaining = $available - 5 - ($widths | Measure-Object -Sum).Sum
    while ($remaining -gt 0) {
        $grew = $false
        foreach ($column in @(1, 2, 4, 5)) {
            if ($widths[$column] -lt $desired[$column] -and $remaining -gt 0) {
                $widths[$column]++; $remaining--; $grew = $true
            }
        }
        if (-not $grew) { break }
    }
    Write-Host ''
    Write-PrinterTableRow $headers $widths 'White'
    $separators = @($widths | ForEach-Object { '-' * $_ })
    Write-PrinterTableRow $separators $widths 'White'
    foreach ($row in $rows) { Write-PrinterTableRow $row.Cells $widths $row.Color }
    Write-Host ''
}

try {
    Write-Host 'Загрузка: подключаю модуль управления печатью Windows...' -ForegroundColor Cyan
    Import-Module PrintManagement -ErrorAction Stop
    $Host.UI.RawUI.WindowTitle = 'Scriptonite — Принтеры'
    $selectedName = ''
    $message = ''
    $cycle = 0
    while ($true) {
        $cycle++
        Clear-Host
        Write-Host "ПРИНТЕРЫ | Проверка №$cycle | $(Get-Date)" -ForegroundColor Cyan
        Write-Host 'Загрузка: получаю принтеры, порты, устройства и очереди. Текущий шаг показан в индикаторе...' -ForegroundColor Yellow
        try { $printers = @(Get-PrinterSnapshot) }
        finally { Write-Progress -Id 31 -Activity 'Загрузка данных принтеров' -Completed }
        Clear-Host
        Write-Host "ПРИНТЕРЫ | Проверка №$cycle | $(Get-Date)" -ForegroundColor Cyan
        if ($printers.Count) {
            Write-PrinterTable $printers
        } else { Write-Host 'Установленные принтеры не найдены.' -ForegroundColor Yellow }
        Write-Host '«Простаивает» — состояние очереди Windows; оно само по себе не доказывает, что принтер включён.' -ForegroundColor DarkGray
        Write-Host 'Для LAN проверяется указанный TCP-порт без отправки данных; TCP-ответ не гарантирует готовность к печати.' -ForegroundColor DarkGray
        if ($Once) { break }
        $selected = $printers | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
        if ($selected) {
            $selectedColor = Get-PrinterDisplayColor $selected
            if ($selectedColor -eq 'White') { $selectedColor = 'Green' }
            Write-Host "`nВЫБРАН: $($selected.Name) | Драйвер: $($selected.Driver)" -ForegroundColor $selectedColor
            Write-Host "Порт: $($selected.Port) | VID:PID: $(if ($selected.Hardware.VidPid) { $selected.Hardware.VidPid } else { 'не определён' })" -ForegroundColor $selectedColor
            Write-Host ''
            Write-Host '[1] Очистить очередь'
            Write-Host '[2] Тестовая страница'
            Write-Host '[3] Возобновить печать'
            Write-Host '[4] Окно очереди Windows'
            Write-Host '[5] Свойства принтера'
            Write-Host '[6] Порт и аппаратные ID'
            Write-Host '[7] Назад к списку принтеров'
            Write-Host '[8] Оживить принтер (экспериментально)' -ForegroundColor Yellow
        } else { $selectedName = ''; Write-Host 'Выберите принтер по номеру.' }
        Write-Host ''
        if ($selected) { Write-Host 'Введите номер действия (1–8).' }
        else { Write-Host 'Номер — выбрать принтер' }
        Write-Host 'Enter — обновить'
        Write-Host '[0] Выход'
        Write-Host "Автообновление: $IntervalSeconds с."
        if ($message) {
            $messageColor = if ($message -match 'Ошиб|Не удалось|остановлено') { 'Red' } else { 'Yellow' }
            Write-Host $message -ForegroundColor $messageColor
            $message = ''
        }
        $choice = (Read-PrinterMenu $IntervalSeconds).Trim().ToUpperInvariant()
        if ($choice -eq '0') { return }
        if (-not $choice) { continue }
        if (-not $selected) {
            $number = 0
            if ([int]::TryParse($choice, [ref]$number)) {
                $candidate = $printers | Where-Object { $_.Number -eq $number } | Select-Object -First 1
                if ($candidate) { $selectedName = $candidate.Name } else { $message = 'Нет принтера с таким номером.' }
            } else { $message = 'Введите номер принтера.' }
            continue
        }
        if ($choice -eq '7') { $selectedName = ''; continue }
        try {
            switch ($choice) {
                '1' { $message = Clear-SelectedPrinterQueue $selected.Name }
                '2' { $message = Invoke-SelectedPrinterMethod $selected.Name 'PrintTestPage' }
                '3' { $message = Invoke-SelectedPrinterMethod $selected.Name 'Resume' }
                '4' { $message = Open-SelectedPrinterWindow $selected.Name 'Queue' }
                '5' { $message = Open-SelectedPrinterWindow $selected.Name 'Properties' }
                '6' { Show-PrinterHardware $selected; $null = Read-Host 'Enter — вернуться к меню принтера' }
                '8' { $message = Invoke-ExperimentalPrinterRecovery $selected.Name; $null = Read-Host 'Enter — вернуться к меню принтера' }
                default { $message = 'Неизвестная команда.' }
            }
        } catch { $message = "Ошибка: $($_.Exception.Message)" }
    }
} catch {
    Write-Host "Не удалось открыть монитор принтеров: $($_.Exception.Message)" -ForegroundColor Red
    if ($Once) { throw }
    $null = Read-Host 'Нажмите Enter для выхода'
}
