[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidateRange(1, 4096)][int]$MaxMegabytes = 256
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = $PSScriptRoot }
if (-not $OutputDirectory) { $OutputDirectory = (Get-Location).Path }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

function Get-SnifferTargets {
    $ports = @{}
    try { Get-PrinterPort -ErrorAction Stop | ForEach-Object { $ports[$_.Name] = $_ } } catch {}
    try {
        foreach ($printer in @(Get-Printer -Full -ErrorAction Stop | Sort-Object Name)) {
            $port = $ports[$printer.PortName]
            if (-not $port -or -not $port.PrinterHostAddress) { continue }
            $address = [string]$port.PrinterHostAddress
            try {
                $ip = $null
                $addresses = if ([Net.IPAddress]::TryParse($address, [ref]$ip)) { @($ip) } else { @([Net.Dns]::GetHostAddresses($address)) }
                foreach ($ipv4 in @($addresses | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork })) {
                    if ([Net.IPAddress]::IsLoopback($ipv4) -or $ipv4.Equals([Net.IPAddress]::Any) -or $ipv4.GetAddressBytes()[0] -ge 224) { continue }
                    [PSCustomObject]@{ Name=$printer.Name; IP=$ipv4.ToString(); Port=$printer.PortName; CapturePort=$port.PortNumber }
                }
            } catch { Write-Host "Не удалось определить адрес [$($printer.Name)]: $address" -ForegroundColor DarkYellow }
        }
    } catch { Write-Host 'Список принтеров недоступен. Можно ввести IPv4 вручную.' -ForegroundColor Yellow }
}

function Get-SnifferLocalAddress {
    param([string]$Target)
    $probe = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
    try {
        # UDP Connect selects a route/source address; no application data is sent.
        $probe.Connect([Net.IPAddress]::Parse($Target), 9100)
        return $probe.LocalEndPoint.Address.ToString()
    } finally { $probe.Dispose() }
}

function Add-SnifferSnapshotSection {
    param([hashtable]$Data, [string]$Name, [scriptblock]$Read)
    try {
        $values = @(& $Read)
        $Data[$Name] = ConvertTo-Json -InputObject $values -Depth 5 -Compress
    } catch { $Data[$Name] = '[НЕ УДАЛОСЬ ПРОЧИТАТЬ] ' + $_.Exception.Message }
}

function Get-SnifferSnapshot {
    param([string]$PrinterName, [string]$Target, [string]$LocalAddress)
    $data = @{}
    Add-SnifferSnapshotSection $data 'Spooler' {
        Get-Service -Name Spooler -ErrorAction Stop | Select-Object Name, Status, StartType
    }
    Add-SnifferSnapshotSection $data 'Процессы печати' {
        Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -in @('spoolsv','PrintIsolationHost','splwow64') } |
            Sort-Object ProcessName, Id | Select-Object ProcessName, Id, SessionId
    }
    try {
        foreach ($printer in @(Get-Printer -Full -ErrorAction Stop | Sort-Object Name)) {
            $data['Принтер/'+$printer.Name] = [ordered]@{
                Driver=$printer.DriverName; Port=$printer.PortName; Status=[string]$printer.PrinterStatus
                Shared=$printer.Shared; ShareName=$printer.ShareName; Type=[string]$printer.Type
            } | ConvertTo-Json -Compress
        }
    } catch { $data['Принтеры/ошибка'] = $_.Exception.Message }
    Add-SnifferSnapshotSection $data 'Порты печати' {
        Get-PrinterPort -ErrorAction Stop | Sort-Object Name |
            Select-Object Name, Description, PortMonitor, PrinterHostAddress, PortNumber, Protocol, SNMPEnabled
        # Community is deliberately not copied into the configuration snapshot.
    }
    Add-SnifferSnapshotSection $data 'Драйверы печати' {
        Get-PrinterDriver -ErrorAction Stop | Sort-Object Name, PrinterEnvironment |
            Select-Object Name, PrinterEnvironment, Manufacturer, DriverVersion, InfPath, DriverPath
    }
    if ($PrinterName) {
        Add-SnifferSnapshotSection $data 'Задания выбранной очереди' {
            Get-PrintJob -PrinterName $PrinterName -ErrorAction Stop | Sort-Object ID |
                Select-Object ID, DocumentName, JobStatus, SubmittedTime, TotalPages, PagesPrinted, Size
        }
        Add-SnifferSnapshotSection $data 'Состояние выбранного принтера WMI' {
            Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop | Where-Object { $_.Name -eq $PrinterName } |
                Select-Object Name, DriverName, PortName, WorkOffline, PrinterStatus, DetectedErrorState, PNPDeviceID
        }
    }
    Add-SnifferSnapshotSection $data 'IPv4 компьютера' {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Sort-Object InterfaceIndex, IPAddress |
            Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength, AddressState
    }
    Add-SnifferSnapshotSection $data 'Сосед для адреса принтера' {
        Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -eq $Target } |
            Sort-Object InterfaceIndex | Select-Object InterfaceIndex, IPAddress, LinkLayerAddress, State
    }
    Add-SnifferSnapshotSection $data 'Маршруты выбранного адаптера' {
        $interface = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -eq $LocalAddress } | Select-Object -First 1
        if ($interface) {
            Get-NetRoute -AddressFamily IPv4 -InterfaceIndex $interface.InterfaceIndex -ErrorAction Stop |
                Sort-Object DestinationPrefix, NextHop | Select-Object DestinationPrefix, NextHop, RouteMetric
        }
    }
    return ,$data
}

function Write-SnifferSnapshot {
    param([IO.TextWriter]$Writer, [hashtable]$Snapshot, [string]$Title)
    $Writer.WriteLine("`r`n================ $Title ================")
    foreach ($key in ($Snapshot.Keys | Sort-Object)) {
        $Writer.WriteLine("`r`n[$key]")
        $Writer.WriteLine([string]$Snapshot[$key])
    }
    $Writer.Flush()
}

function Write-SnifferChanges {
    param([IO.TextWriter]$Writer, [hashtable]$Before, [hashtable]$After)
    $Writer.WriteLine("`r`n================ ИЗМЕНЕНИЯ ДО / ПОСЛЕ ================")
    $keys = @(@($Before.Keys) + @($After.Keys) | Sort-Object -Unique)
    $changed = 0
    foreach ($key in $keys) {
        if (-not $Before.ContainsKey($key)) { $Writer.WriteLine("ДОБАВЛЕНО [$key]: $($After[$key])"); $changed++ }
        elseif (-not $After.ContainsKey($key)) { $Writer.WriteLine("УДАЛЕНО [$key]: $($Before[$key])"); $changed++ }
        elseif ([string]$Before[$key] -ne [string]$After[$key]) {
            $Writer.WriteLine("`r`nИЗМЕНИЛОСЬ [$key]")
            $Writer.WriteLine("ДО:    $($Before[$key])")
            $Writer.WriteLine("ПОСЛЕ: $($After[$key])")
            $changed++
        }
    }
    if (-not $changed) { $Writer.WriteLine('В собранных параметрах изменений не обнаружено.') }
    $Writer.WriteLine('Недоступные данные отмечены отдельно. Различия не доказывают причину неисправности или восстановления.')
}

function Get-SnifferUInt16 {
    param([byte[]]$Buffer, [int]$Offset)
    return [int]$Buffer[$Offset]*256 + [int]$Buffer[$Offset+1]
}

function Get-SnifferUInt32 {
    param([byte[]]$Buffer, [int]$Offset)
    return [uint32](([uint64]$Buffer[$Offset] -shl 24) -bor ([uint64]$Buffer[$Offset+1] -shl 16) -bor ([uint64]$Buffer[$Offset+2] -shl 8) -bor [uint64]$Buffer[$Offset+3])
}

function Read-SnifferPacket {
    param([byte[]]$Buffer, [int]$Length)
    if ($Length -lt 20 -or ($Buffer[0] -shr 4) -ne 4) { return $null }
    $headerLength = ($Buffer[0] -band 15)*4
    $total = Get-SnifferUInt16 $Buffer 2
    if ($headerLength -lt 20 -or $total -lt $headerLength -or $Length -lt $headerLength) { return $null }
    $length = [Math]::Min($Length, $total)
    $source = $Buffer[12..15] -join '.'
    $destination = $Buffer[16..19] -join '.'
    $fragment = (Get-SnifferUInt16 $Buffer 6) -band 0x1FFF
    $protocol = switch ($Buffer[9]) { 6 { 'TCP' } 17 { 'UDP' } 1 { 'ICMP' } 2 { 'IGMP' } default { 'IP/'+$Buffer[9] } }
    $detail = ''
    $flags = ''
    $sourcePort = $null
    $destinationPort = $null
    if ($fragment -eq 0 -and $protocol -eq 'TCP' -and $length -ge ($headerLength+20)) {
        $sourcePort = Get-SnifferUInt16 $Buffer $headerLength
        $destinationPort = Get-SnifferUInt16 $Buffer ($headerLength+2)
        $sequence = Get-SnifferUInt32 $Buffer ($headerLength+4)
        $ack = Get-SnifferUInt32 $Buffer ($headerLength+8)
        $flagList = New-Object 'System.Collections.Generic.List[string]'
        foreach ($flag in @(@(1,'FIN'),@(2,'SYN'),@(4,'RST'),@(8,'PSH'),@(16,'ACK'),@(32,'URG'),@(64,'ECE'),@(128,'CWR'))) {
            if ($Buffer[$headerLength+13] -band $flag[0]) { $flagList.Add($flag[1]) }
        }
        $flags = $flagList -join ','
        $tcpLength = ($Buffer[$headerLength+12] -shr 4)*4
        $payloadLength = [Math]::Max(0, $length-$headerLength-$tcpLength)
        $detail = "flags=[$flags] seq=$sequence ack=$ack payload=$payloadLength window=$(Get-SnifferUInt16 $Buffer ($headerLength+14))"
    } elseif ($fragment -eq 0 -and $protocol -eq 'UDP' -and $length -ge ($headerLength+8)) {
        $sourcePort = Get-SnifferUInt16 $Buffer $headerLength
        $destinationPort = Get-SnifferUInt16 $Buffer ($headerLength+2)
        $detail = "UDP-length=$(Get-SnifferUInt16 $Buffer ($headerLength+4))"
    } elseif ($fragment -eq 0 -and $protocol -eq 'ICMP' -and $length -ge ($headerLength+2)) {
        $detail = "type=$($Buffer[$headerLength]) code=$($Buffer[$headerLength+1])"
    }
    if ($fragment -gt 0) { $detail = "IPv4 fragment offset=$($fragment*8); заголовок TCP/UDP в этом фрагменте не декодируется" }
    return [PSCustomObject]@{
        Source=$source; Destination=$destination; Protocol=$protocol; SourcePort=$sourcePort; DestinationPort=$destinationPort
        Detail=$detail; Flags=$flags; Length=$length; Id=(Get-SnifferUInt16 $Buffer 4); TTL=$Buffer[8]
        Truncated=($length -lt $total)
    }
}

function Write-SnifferPacket {
    param([IO.TextWriter]$Writer, [byte[]]$Buffer, $Packet, [int]$Number, [string]$Target)
    $direction = if ($Packet.Source -eq $Target) { 'ОТ ПРИНТЕРА' } else { 'К ПРИНТЕРУ' }
    $source = $Packet.Source
    $destination = $Packet.Destination
    if ($null -ne $Packet.SourcePort) { $source += ':'+$Packet.SourcePort; $destination += ':'+$Packet.DestinationPort }
    $Writer.WriteLine("`r`n#$Number $([DateTime]::UtcNow.ToString('o')) [$direction] $($Packet.Protocol) $source -> $destination bytes=$($Packet.Length) IP-ID=$($Packet.Id) TTL=$($Packet.TTL)")
    if ($Packet.Detail) { $Writer.WriteLine($Packet.Detail) }
    if ($Packet.Truncated) { $Writer.WriteLine('ВНИМАНИЕ: получена усечённая IPv4-датаграмма.') }
    for ($offset=0; $offset -lt $Packet.Length; $offset+=16) {
        $count = [Math]::Min(16, $Packet.Length-$offset)
        $hex = New-Object 'System.Collections.Generic.List[string]'
        $ascii = New-Object Text.StringBuilder
        for ($i=0; $i -lt $count; $i++) {
            $value = $Buffer[$offset+$i]
            $hex.Add($value.ToString('X2'))
            $null = $ascii.Append($(if ($value -ge 32 -and $value -le 126) { [char]$value } else { '.' }))
        }
        $Writer.WriteLine(('{0:X4}  {1,-47}  {2}' -f $offset, ($hex -join ' '), $ascii.ToString()))
    }
}

function Write-SnifferPrintEvents {
    param([IO.TextWriter]$Writer, [datetime]$StartTime, [datetime]$EndTime)
    $Writer.WriteLine("`r`n================ СОБЫТИЯ ПЕЧАТИ ЗА ВРЕМЯ ЗАПИСИ ================")
    foreach ($log in @('Microsoft-Windows-PrintService/Admin','Microsoft-Windows-PrintService/Operational')) {
        $Writer.WriteLine("`r`n[$log]")
        try {
            $info = Get-WinEvent -ListLog $log -ErrorAction Stop
            if (-not $info.IsEnabled) { $Writer.WriteLine('Журнал отключён. Скрипт его не включал.'); continue }
            $events = @(Get-WinEvent -FilterHashtable @{ LogName=$log; StartTime=$StartTime; EndTime=$EndTime } -MaxEvents 1000 -ErrorAction Stop)
            foreach ($event in ($events | Sort-Object TimeCreated)) {
                $Writer.WriteLine("$($event.TimeCreated.ToUniversalTime().ToString('o')) ID=$($event.Id) Level=$($event.LevelDisplayName)")
                $Writer.WriteLine($event.Message)
            }
            if ($events.Count -eq 1000) { $Writer.WriteLine('Достигнут лимит 1000 событий: журнал в отчёте может быть неполным.') }
        } catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $Writer.WriteLine('Событий за интервал не найдено.') }
            else { $Writer.WriteLine('Не удалось прочитать журнал: '+$_.Exception.Message) }
        }
    }
    foreach ($log in @('System','Application')) {
        $Writer.WriteLine("`r`n[$log — события Spooler/PrintIsolationHost]")
        try {
            $filter = @{ LogName=$log; StartTime=$StartTime; EndTime=$EndTime }
            if ($log -eq 'System') { $filter.ProviderName = 'Service Control Manager' }
            else { $filter.ProviderName = @('Application Error','Windows Error Reporting') }
            $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 1000 -ErrorAction Stop)
            foreach ($event in @($events | Where-Object { $_.Message -match 'Spooler|Диспетчер печати|PrintIsolationHost|spoolsv|splwow64' } | Sort-Object TimeCreated)) {
                $Writer.WriteLine("$($event.TimeCreated.ToUniversalTime().ToString('o')) ID=$($event.Id)")
                $Writer.WriteLine($event.Message)
            }
            if ($events.Count -eq 1000) { $Writer.WriteLine('Достигнут лимит чтения 1000 событий; часть событий могла не попасть в отчёт.') }
        } catch { $Writer.WriteLine('События отсутствуют или недоступны: '+$_.Exception.Message) }
    }
}

function Test-PrinterSnifferStop {
    if (-not [Console]::KeyAvailable) { return $false }
    $key = [Console]::ReadKey($true)
    return $key.Key -in @('D0','NumPad0','Enter','Escape','S')
}

function Start-PrinterSnifferSession {
    param($Target, [string]$Directory, [int]$LimitMegabytes)
    $localAddress = Get-SnifferLocalAddress $Target.IP
    $selfTarget = $localAddress -eq $Target.IP
    $selfPort = 0
    if ($selfTarget -and (-not [int]::TryParse([string]$Target.CapturePort, [ref]$selfPort) -or $selfPort -lt 1 -or $selfPort -gt 65535)) {
        throw 'Это IP самого компьютера. Без известного порта эмулятора захват затронет весь трафик ПК; выберите удалённый принтер.'
    }
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $filename = 'PrinterCapture_{0}_{1}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0,6)
    $path = Join-Path $Directory $filename
    $writer = New-Object IO.StreamWriter($path, $false, (New-Object Text.UTF8Encoding($true)))
    $writer.AutoFlush = $true
    $socket = $null
    $completed = $false
    $failure = ''
    $packets = 0
    $bytes = [uint64]0
    $counts = @{}
    $reason = 'Пользователь остановил запись'
    try {
        $writer.WriteLine('SCRIPTONITE — СНИФФЕР LAN-ПРИНТЕРА')
        $writer.WriteLine("Принтер: $($Target.Name) | Цель IPv4: $($Target.IP) | Адаптер IPv4: $localAddress")
        $writer.WriteLine('Захватываются только IPv4-пакеты с IP выбранной цели в источнике или назначении.')
        $writer.WriteLine('Полный HEX/ASCII может содержать чеки и SNMP community. Не публикуйте отчёт без проверки содержимого.')
        $writer.WriteLine('ARP, IPv6 и USB-трафик не захватываются. Пакеты между другими компьютерами и принтером могут не доходить до этого ПК.')
        $writer.WriteLine('Если IP принтера изменится, фильтр останется на исходном IP. Потери в буферах Windows этим способом не измеряются.')
        if ($selfTarget) { $writer.WriteLine("Цель находится на этом ПК: дополнительно фильтруется порт $selfPort. Локальный loopback-обмен raw-сокет может не показать.") }
        $writer.WriteLine("Лимит пакетной части: $LimitMegabytes МБ. Файл не перезаписывается по кругу; при достижении лимита запись останавливается.")
        Write-Host 'Снимаю состояние ДО...' -ForegroundColor Cyan
        $before = Get-SnifferSnapshot $Target.Name $Target.IP $localAddress
        Write-SnifferSnapshot $writer $before 'СОСТОЯНИЕ ДО'
        $socket = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Raw, [Net.Sockets.ProtocolType]::IP)
        $socket.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($localAddress),0)))
        $socket.ReceiveBufferSize = 8388608
        $null = $socket.IOControl([Net.Sockets.IOControlCode]::ReceiveAll, [byte[]](1,0,0,0), $null)
        $buffer = New-Object byte[] 65535
        $started = Get-Date
        $writer.WriteLine("`r`n================ ПАКЕТЫ | НАЧАЛО UTC $($started.ToUniversalTime().ToString('o')) ================")
        Write-Host "`nЗАПИСЬ ИДЁТ: $($Target.Name) — $($Target.IP)" -ForegroundColor Green
        Write-Host "TXT: $path" -ForegroundColor Cyan
        Write-Host '[0] СТОП — также можно нажать Enter или Esc' -ForegroundColor Yellow
        Write-Host 'Теперь меняйте настройки, переустанавливайте драйвер или запускайте печать.'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $lastDisplay = -1
        while ($true) {
            if (Test-PrinterSnifferStop) { break }
            if ($socket.Poll(100000, [Net.Sockets.SelectMode]::SelectRead)) {
                $length = $socket.Receive($buffer)
                $packet = Read-SnifferPacket $buffer $length
                $matchesTarget = $packet -and ($packet.Source -eq $Target.IP -or $packet.Destination -eq $Target.IP)
                if ($matchesTarget -and $selfTarget) { $matchesTarget = $packet.SourcePort -eq $selfPort -or $packet.DestinationPort -eq $selfPort }
                if ($matchesTarget) {
                    $packets++; $bytes += $packet.Length
                    if (-not $counts.ContainsKey($packet.Protocol)) { $counts[$packet.Protocol] = 0 }
                    $counts[$packet.Protocol]++
                    Write-SnifferPacket $writer $buffer $packet $packets $Target.IP
                    if ($writer.BaseStream.Length -ge ([int64]$LimitMegabytes*1MB)) { $reason = 'Достигнут лимит размера TXT'; break }
                }
            }
            $second = [int]$clock.Elapsed.TotalSeconds
            if ($second -ne $lastDisplay -and $second % 5 -eq 0) {
                Write-Host "Идёт запись: $second с | Пакетов: $packets | IP-байт: $bytes | [0] Стоп" -ForegroundColor DarkGray
                $lastDisplay = $second
            }
        }
        $ended = Get-Date
        $clock.Stop()
        $socket.Close(); $socket = $null
        $writer.WriteLine("`r`n================ ЗАПИСЬ ОСТАНОВЛЕНА ================")
        $writer.WriteLine("Конец UTC: $($ended.ToUniversalTime().ToString('o')) | Причина: $reason")
        $writer.WriteLine("Пакетов: $packets | IP-байт: $bytes")
        foreach ($protocol in ($counts.Keys | Sort-Object)) { $writer.WriteLine("${protocol}: $($counts[$protocol])") }
        Write-Host 'Запись остановлена. Снимаю состояние ПОСЛЕ и события печати...' -ForegroundColor Cyan
        $after = Get-SnifferSnapshot $Target.Name $Target.IP $localAddress
        Write-SnifferSnapshot $writer $after 'СОСТОЯНИЕ ПОСЛЕ'
        Write-SnifferChanges $writer $before $after
        Write-SnifferPrintEvents $writer $started $ended
        $completed = $true
    } catch {
        $failure = $_.Exception.Message
        $writer.WriteLine("`r`nОШИБКА ЗАПИСИ: $failure")
    } finally {
        if ($socket) { $socket.Close() }
        if (-not $completed) { $writer.WriteLine("`r`nОТЧЁТ НЕПОЛНЫЙ: запись прервана либо часть завершающих действий не выполнена.") }
        $writer.WriteLine("`r`nКОНЕЦ ОТЧЁТА UTC $([DateTime]::UtcNow.ToString('o'))")
        $writer.Flush()
        $writer.Dispose()
    }
    return [PSCustomObject]@{ Path=$path; Completed=$completed; Error=$failure; Packets=$packets }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $admin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
    if (-not $admin) {
        if (-not $PSCommandPath) { throw 'Сохраните скрипт в файл и запустите PowerShell от администратора.' }
        $scriptPath = $PSCommandPath.Replace("'", "''")
        $directory = $OutputDirectory.Replace("'", "''")
        $command = "& '$scriptPath' -OutputDirectory '$directory' -MaxMegabytes $MaxMegabytes"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        try {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -WindowStyle Normal -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -ErrorAction Stop | Out-Null
        } catch { Write-Host 'Нужны права администратора. Запись не запущена.' -ForegroundColor Yellow; $null = Read-Host 'Enter — выход' }
        return
    }
    $Host.UI.RawUI.WindowTitle = 'Scriptonite — Сниффер принтера'
    while ($true) {
        Clear-Host
        Write-Host 'СНИФФЕР LAN-ПРИНТЕРА — ВЫБЕРИТЕ ЦЕЛЬ' -ForegroundColor Cyan
        $targets = @(Get-SnifferTargets)
        for ($i=0; $i -lt $targets.Count; $i++) { Write-Host "[$($i+1)] $($targets[$i].Name) | $($targets[$i].IP) | $($targets[$i].Port)" }
        $manualNumber = $targets.Count+1
        Write-Host "[$manualNumber] Ввести IPv4 вручную"
        Write-Host '[0] Выход'
        Write-Host "Отчёты рядом со скриптом: $OutputDirectory" -ForegroundColor DarkGray
        Write-Host 'Содержимое пакетов записывается полностью, включая возможные данные чеков.' -ForegroundColor Yellow
        $number = 0
        if (-not [int]::TryParse([string](Read-Host 'Выбор'),[ref]$number) -or $number -lt 0 -or $number -gt $manualNumber) { continue }
        if ($number -eq 0) { return }
        if ($number -eq $manualNumber) {
            $address = ([string](Read-Host 'IPv4 принтера')).Trim()
            $ip = $null
            if (-not [Net.IPAddress]::TryParse($address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [Net.IPAddress]::IsLoopback($ip) -or $ip.GetAddressBytes()[0] -ge 224 -or $address -eq '0.0.0.0') {
                Write-Host 'Введите IPv4 конкретного устройства, например 192.168.1.87.' -ForegroundColor Yellow
                $null = Read-Host 'Enter — назад'; continue
            }
            $target = [PSCustomObject]@{ Name=''; IP=$ip.ToString(); Port='ручной адрес'; CapturePort=0 }
        } else { $target = $targets[$number-1] }
        try {
            $result = Start-PrinterSnifferSession -Target $target -Directory $OutputDirectory -LimitMegabytes $MaxMegabytes
            if ($result.Completed) { Write-Host "`nГОТОВО. Пакетов: $($result.Packets)" -ForegroundColor Green }
            else { Write-Host "Отчёт неполный: $($result.Error)" -ForegroundColor Yellow }
            Write-Host "TXT: $($result.Path)" -ForegroundColor Cyan
        } catch { Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red }
        $null = Read-Host 'Enter — вернуться к выбору'
    }
} catch {
    Write-Host "Не удалось открыть сниффер: $($_.Exception.Message)" -ForegroundColor Red
    $null = Read-Host 'Enter — выход'
}
