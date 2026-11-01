[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidateRange(1, 4096)][int]$MaxMegabytes = 256
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = $PSScriptRoot }
if (-not $OutputDirectory) { $OutputDirectory = (Get-Location).Path }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

$script:PrinterNotifySource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace ScriptonitePrinterWatch {
    public sealed class Notifications : IDisposable {
        IntPtr printer = IntPtr.Zero, change = new IntPtr(-1);
        [DllImport("winspool.drv", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool OpenPrinter(string name, out IntPtr handle, IntPtr defaults);
        [DllImport("winspool.drv", SetLastError=true)] static extern bool ClosePrinter(IntPtr handle);
        [DllImport("winspool.drv", SetLastError=true)]
        static extern IntPtr FindFirstPrinterChangeNotification(IntPtr handle, uint flags, uint options, IntPtr notifyOptions);
        [DllImport("winspool.drv", SetLastError=true)]
        static extern bool FindNextPrinterChangeNotification(IntPtr change, out uint flags, IntPtr options, IntPtr info);
        [DllImport("winspool.drv", SetLastError=true)] static extern bool FindClosePrinterChangeNotification(IntPtr change);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        public Notifications(string name) {
            if (!OpenPrinter(name, out printer, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            change=FindFirstPrinterChangeNotification(printer, 0x0000FF00, 0, IntPtr.Zero);
            if (change==new IntPtr(-1)) { int error=Marshal.GetLastWin32Error(); ClosePrinter(printer); printer=IntPtr.Zero; throw new Win32Exception(error); }
        }
        public uint ReadChanges() {
            uint wait=WaitForSingleObject(change,0);
            if (wait==258) return 0;
            if (wait!=0) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint flags;
            if (!FindNextPrinterChangeNotification(change,out flags,IntPtr.Zero,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return flags;
        }
        public void Dispose() {
            if(change!=new IntPtr(-1)) { FindClosePrinterChangeNotification(change); change=new IntPtr(-1); }
            if(printer!=IntPtr.Zero) { ClosePrinter(printer); printer=IntPtr.Zero; }
        }
    }
}
'@

function Get-SnifferJobStatus {
    param([uint32]$Flags)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pair in @(@(2,'Ошибка'),@(32,'Принтер автономный'),@(64,'Нет бумаги'),@(512,'Задание заблокировано'),@(1024,'Требуется вмешательство'))) {
        if ($Flags -band $pair[0]) { $errors.Add($pair[1]) }
    }
    if ($errors.Count) { return [PSCustomObject]@{ Text=($errors -join '; '); Color='Red'; Printed=$false; Error=$true } }
    $text = 'Ожидает обработки Windows'
    $color = 'Yellow'
    $printed = $false
    if ($Flags -band 4 -or $Flags -band 256) { $text = 'Удаляется / удалено из очереди; печать не подтверждена' }
    elseif ($Flags -band 128) { $text = 'Windows отметила напечатанным; выход бумаги не подтверждён'; $color='Green'; $printed=$true }
    elseif ($Flags -band 4096) { $text = 'Передано принтеру по данным Windows; выход бумаги не подтверждён'; $color='Cyan' }
    elseif ($Flags -band 1) { $text = 'Приостановлено' }
    elseif ($Flags -band 16) { $text = 'Печатается / передаётся по данным Windows'; $color='Cyan' }
    elseif ($Flags -band 8) { $text = 'Формируется задание (spooling)'; $color='Cyan' }
    return [PSCustomObject]@{ Text=$text; Color=$color; Printed=$printed; Error=$false }
}

function Get-SnifferJobObservations {
    param([object[]]$Jobs, [hashtable]$State, [bool]$Baseline)
    $seen = @{}
    foreach ($job in $Jobs) {
        $stamp = [string]$job.SubmittedTime
        try { if ($job.SubmittedTime) { $stamp = ([datetime]$job.SubmittedTime).ToUniversalTime().ToString('o') } } catch {}
        $key = "$($job.ID)|$stamp"
        $seen[$key] = $true
        $flags = [uint32]$job.JobStatus
        $status = Get-SnifferJobStatus $flags
        $document = ([string]$job.DocumentName) -replace '[\x00-\x1F\x7F]', ' '
        if(-not $document){$document='Имя документа недоступно'}
        $sizeText=if($null -ne $job.Size){[string]$job.Size+' байт'}else{'размер недоступен'}
        $tag = "#$($job.ID) «$document» | $sizeText | поступило: $stamp"
        if (-not $State.Records.ContainsKey($key)) {
            $State.Records[$key] = [PSCustomObject]@{ Flags=$flags; Active=$true; Printed=$status.Printed; HadError=$status.Error; Tag=$tag }
            $code = if ($Baseline) { 'JOB_EXISTING' } else { 'JOB_NEW' }
            $prefix = if ($Baseline) { 'Уже в очереди' } else { 'Замечено новое задание' }
            [PSCustomObject]@{ Code=$code; Text="${prefix}: $tag — $($status.Text)"; Color=$status.Color; Count=1 }
            if ($status.Printed -and -not $Baseline) { [PSCustomObject]@{ Code='WINDOWS_PRINTED'; Text="Windows: $tag отмечено напечатанным; бумага не подтверждена"; Color='Green'; Count=1 } }
            if ($status.Error) { [PSCustomObject]@{ Code='JOB_ERROR'; Text="ОШИБКА: $tag — $($status.Text)"; Color='Red'; Count=1 } }
        } else {
            $record = $State.Records[$key]
            if ($record.Flags -ne $flags -or -not $record.Active) {
                [PSCustomObject]@{ Code='JOB_STATE'; Text="Задание $tag — $($status.Text)"; Color=$status.Color; Count=1 }
                if ($status.Printed -and -not $record.Printed) { [PSCustomObject]@{ Code='WINDOWS_PRINTED'; Text="Windows: $tag отмечено напечатанным; бумага не подтверждена"; Color='Green'; Count=1 } }
                if ($status.Error -and (-not $record.HadError -or $record.Flags -ne $flags)) { [PSCustomObject]@{ Code='JOB_ERROR'; Text="ОШИБКА: $tag — $($status.Text)"; Color='Red'; Count=1 } }
            }
            $record.Flags=$flags; $record.Active=$true
            $record.Printed=$record.Printed -or $status.Printed
            $record.HadError=$record.HadError -or $status.Error
            $record.Tag=$tag
        }
    }
    foreach ($key in @($State.Records.Keys)) {
        $record = $State.Records[$key]
        if ($record.Active -and -not $seen.ContainsKey($key)) {
            $record.Active=$false
            $outcome = if ($record.Printed -and -not (Get-SnifferJobStatus $record.Flags).Error) { 'Windows ранее отметила напечатанным; выход бумаги не подтверждён' }
                elseif ($record.HadError) { 'Ранее была ошибка; итог печати не подтверждён' }
                else { 'Завершено, отменено или удалено — итог не подтверждён' }
            [PSCustomObject]@{ Code='JOB_LEFT'; Text="Задание $($record.Tag) покинуло очередь. $outcome"; Color='Yellow'; Count=1 }
        }
    }
    [PSCustomObject]@{ Code='QUEUE_COUNT'; Text=''; Color='Yellow'; Count=$Jobs.Count }
}

function Start-SnifferPrintWatcher {
    param([string]$PrinterName, [datetime]$Started)
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $cancel = New-Object Threading.CancellationTokenSource
    if (-not $script:PendingPrinterWatchers) { $script:PendingPrinterWatchers=New-Object 'System.Collections.Generic.List[object]' }
    foreach($old in @($script:PendingPrinterWatchers.ToArray())) {
        if($old.Async.IsCompleted) {
            try{$null=$old.PowerShell.EndInvoke($old.Async)}catch{}
            $old.PowerShell.Dispose();$old.Runspace.Dispose();$old.Cancel.Dispose()
            $null=$script:PendingPrinterWatchers.Remove($old)
        }
    }
    if (-not $PrinterName) {
        $queue.Enqueue([PSCustomObject]@{ Code='INFO'; Text='IP введён вручную: очередь Windows не выбрана. Результат оценивается только по пакетам.'; Color='Yellow'; Count=0 })
        return [PSCustomObject]@{ Queue=$queue; Cancel=$cancel; PowerShell=$null; Runspace=$null; Async=$null }
    }
    $nativeAvailable = $true
    try { if (-not ('ScriptonitePrinterWatch.Notifications' -as [type])) { Add-Type -TypeDefinition $script:PrinterNotifySource -Language CSharp } }
    catch { $nativeAvailable=$false; $queue.Enqueue([PSCustomObject]@{Code='INFO';Text='Уведомления Spooler не удалось подключить. Быстрые задания могут быть пропущены опросом.';Color='Yellow';Count=0}) }
    $helpers = "function Get-SnifferJobStatus {`n$((Get-Command Get-SnifferJobStatus).Definition)`n}`nfunction Get-SnifferJobObservations {`n$((Get-Command Get-SnifferJobObservations).Definition)`n}`n"
    $body = @'
param($Name, $Started, $Messages, $Cancellation, $UseNotifications)
$ErrorActionPreference='Stop'
function Send-Notice($Code, $Text, $Color='Yellow', $Count=1) {
    $Messages.Enqueue([PSCustomObject]@{ Code=$Code; Text=$Text; Color=$Color; Count=$Count })
}
$notification=$null
$lastOpen=[datetime]::MinValue
$lastJobs=[datetime]::MinValue
$lastEvents=[datetime]::MinValue
$lastQueueError=''
$lastCount=-1
$lastNotifyError=''
$first=$true
$state=@{Records=@{}}
$eventIds=@{}
$operational=$false
try {
    try { $operational=(Get-WinEvent -ListLog 'Microsoft-Windows-PrintService/Operational' -ErrorAction Stop).IsEnabled } catch {}
    if(-not $operational){Send-Notice INFO 'Журнал завершений печати отключён или недоступен. Исчезновение задания само по себе не считается успешной печатью.'}
    while(-not $Cancellation.IsCancellationRequested){
        $now=Get-Date
        if($UseNotifications -and -not $notification -and ($now-$lastOpen).TotalSeconds -ge 3){
            $lastOpen=$now
            try{$notification=New-Object ScriptonitePrinterWatch.Notifications($Name);$lastNotifyError=''}
            catch{if($lastNotifyError -ne $_.Exception.Message){Send-Notice INFO 'Уведомления Spooler недоступны; остаётся опрос очереди. Быстрые задания могут быть пропущены.';$lastNotifyError=$_.Exception.Message}}
        }
        if($notification){
            try{
                $flags=$notification.ReadChanges()
                if($flags -band 0x100){Send-Notice QUEUE_ARRIVAL 'ПОСТУПЛЕНИЕ: Windows сообщила о добавлении задания в выбранную очередь.' Cyan}
            }catch{
                $notification.Dispose();$notification=$null
                Send-Notice INFO 'Связь с уведомлениями Spooler прервалась. Пробую подключиться снова.'
            }
        }
        if(($now-$lastJobs).TotalMilliseconds -ge 500){
            $lastJobs=$now
            try{
                $jobs=@(Get-PrintJob -PrinterName $Name -ErrorAction Stop)
                foreach($event in @(Get-SnifferJobObservations -Jobs $jobs -State $state -Baseline $first)){
                    if($event.Code -eq 'QUEUE_COUNT'){
                        if($lastCount -ne $event.Count){$Messages.Enqueue($event);$lastCount=$event.Count}
                    }else{$Messages.Enqueue($event)}
                }
                $first=$false;$lastQueueError=''
            }catch{
                if($lastQueueError -ne $_.Exception.Message){Send-Notice WATCH_ERROR ('Не удалось прочитать очередь: '+$_.Exception.Message) Red;$lastQueueError=$_.Exception.Message}
            }
        }
        if($operational -and ($now-$lastEvents).TotalSeconds -ge 2){
            $lastEvents=$now
            try{
                $events=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-PrintService/Operational';ID=307;StartTime=$Started} -MaxEvents 256 -ErrorAction Stop)
                foreach($event in ($events|Sort-Object TimeCreated)){
                    $key="$($event.RecordId)|$($event.TimeCreated.ToUniversalTime().ToString('o'))"
                    if($eventIds.ContainsKey($key)){continue}
                    $eventIds[$key]=$true
                    $xml=[xml]$event.ToXml()
                    $printed=$xml.SelectSingleNode("//*[local-name()='DocumentPrinted']")
                    if(-not $printed){continue}
                    $printer=$printed.SelectSingleNode("*[local-name()='Param5']")
                    if(-not $printer -or $printer.InnerText -ne $Name){continue}
                    $id=$printed.SelectSingleNode("*[local-name()='Param1']")
                    $document=$printed.SelectSingleNode("*[local-name()='Param2']")
                    $documentName=if($document){$document.InnerText -replace '[\x00-\x1F\x7F]',' '}else{'Имя документа недоступно'}
                    $size=$printed.SelectSingleNode("*[local-name()='Param7']")
                    $sizeText=if($size){$size.InnerText+' байт'}else{'размер недоступен'}
                    Send-Notice WINDOWS_COMPLETED "Windows зарегистрировала завершение задания #$($id.InnerText) «$documentName» | $sizeText (событие 307). Фактический выход чека не подтверждён." Green
                }
            }catch{}
        }
        $null=$Cancellation.Token.WaitHandle.WaitOne(50)
    }
}finally{if($notification){$notification.Dispose()}}
'@
    $paramEnd = $body.IndexOf("`n")
    $code = $body.Substring(0,$paramEnd+1) + $helpers + $body.Substring($paramEnd+1)
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [PowerShell]::Create()
    $powershell.Runspace=$runspace
    $null=$powershell.AddScript($code).AddArgument($PrinterName).AddArgument($Started).AddArgument($queue).AddArgument($cancel).AddArgument($nativeAvailable)
    $async=$powershell.BeginInvoke()
    return [PSCustomObject]@{ Queue=$queue; Cancel=$cancel; PowerShell=$powershell; Runspace=$runspace; Async=$async }
}

function Stop-SnifferPrintWatcher {
    param($Watcher)
    if (-not $Watcher) { return $true }
    $Watcher.Cancel.Cancel()
    if (-not $Watcher.Async) { $Watcher.Cancel.Dispose(); return $true }
    $done = $Watcher.Async.AsyncWaitHandle.WaitOne(2000)
    if (-not $done) {
        try { $stop=$Watcher.PowerShell.BeginStop($null,$null); $done=$stop.AsyncWaitHandle.WaitOne(500) } catch {}
    }
    $done=$done -and $Watcher.Async.IsCompleted
    if ($done) {
        try { $null=$Watcher.PowerShell.EndInvoke($Watcher.Async) } catch {}
        $Watcher.PowerShell.Dispose(); $Watcher.Runspace.Dispose(); $Watcher.Cancel.Dispose()
    } else { $script:PendingPrinterWatchers.Add($Watcher) }
    return $done
}

function Receive-SnifferPrintMessages {
    param($Watcher, [hashtable]$State, [IO.TextWriter]$Writer)
    if (-not $Watcher) { return }
    if($Watcher.PowerShell -and $Watcher.PowerShell.InvocationStateInfo.State -eq 'Failed' -and -not $State.WatchFailed) {
        $State.WatchFailed=$true
        $Watcher.Queue.Enqueue([PSCustomObject]@{Code='WATCH_ERROR';Text='Фоновое наблюдение за очередью завершилось с ошибкой. Сведения о заданиях после ошибки могут быть неполными.';Color='Red';Count=0})
    }
    $message=$null
    while($Watcher.Queue.TryDequeue([ref]$message)) {
        switch($message.Code) {
            'QUEUE_ARRIVAL' { $State.Arrivals++; $State.SawJobs=$true }
            'JOB_NEW' { $State.JobsSeen++; $State.SawJobs=$true }
            'JOB_EXISTING' { $State.JobsSeen++; $State.SawJobs=$true }
            'WINDOWS_PRINTED' { $State.WindowsReported=$true }
            'WINDOWS_COMPLETED' { $State.WindowsReported=$true; $State.SawJobs=$true }
            'JOB_ERROR' { $State.Errors++; $State.LastJob=[string]$message.Text }
            'WATCH_ERROR' { $State.QueueCount=$null }
            'QUEUE_COUNT' { $State.QueueCount=$message.Count }
        }
        if($message.Code -in @('JOB_STATE','JOB_NEW','JOB_EXISTING','JOB_LEFT','WINDOWS_PRINTED','WINDOWS_COMPLETED')){$State.LastJob=[string]$message.Text}
        if($message.Text) {
            Write-SnifferEvidenceEvent $Writer $State $message.Code $message.Text $message.Color
        }
        $message=$null
    }
}

function Write-SnifferEvidenceEvent {
    param([IO.TextWriter]$Writer,[hashtable]$State,[string]$Code,[string]$Text,[string]$Color='Yellow')
    $line="$([DateTime]::UtcNow.ToString('o')) [ПЕЧАТЬ/$Code] [Принтер: $($State.PrinterName)] $Text"
    $Writer.WriteLine($line)
    Write-Host $Text -ForegroundColor $Color
    if($State.ContainsKey('Evidence') -and $Code -ne 'INFO'){
        if($State.Evidence.Count -lt 10000){$State.Evidence.Add($line)}else{$State.EvidenceTruncated=$true}
    }
}

function Write-SnifferPrintSummary {
    param([IO.TextWriter]$Writer,[hashtable]$State)
    $Writer.WriteLine("`r`n================ НАБЛЮДЕНИЕ ЗА ПЕЧАТЬЮ ================")
    $Writer.WriteLine('Задания Windows: '+$(if($State.SawJobs){'замечены'}else{'не замечены; это не доказывает отсутствие печати'}))
    $Writer.WriteLine("Заданий с идентификаторами замечено: $($State.JobsSeen); уведомлений о поступлении: $($State.Arrivals). Эти числа могут относиться к одним и тем же заданиям и не суммируются.")
    if($State.ContainsKey('NetworkCapture') -and -not $State.NetworkCapture){
        $Writer.WriteLine('Режим очереди Windows (в том числе USB): подтверждается поступление/состояние задания, а не физическая передача USB-байтов.')
    }else{$Writer.WriteLine("Данных на настроенный TCP-порт печати замечено: $($State.PrintBytes) байт (с возможными повторами пакетов).")}
    $Writer.WriteLine('Завершение по данным Windows: '+$(if($State.WindowsReported){'есть сообщение Windows; бумага не подтверждена'}else{'не подтверждено'}))
    $Writer.WriteLine("Сообщений об ошибках задания: $($State.Errors); TCP RST на канале печати: $($State.Resets). RST сам по себе не доказывает сбой задания.")
    if($State.LastJob){$Writer.WriteLine('Последнее наблюдение: '+$State.LastJob)}
    if($State.ContainsKey('Evidence')){
        $Writer.WriteLine("`r`n================ ХРОНОЛОГИЯ ЗАДАНИЙ И ОТПРАВКИ ================")
        foreach($line in $State.Evidence){$Writer.WriteLine($line)}
        if(-not $State.Evidence.Count){$Writer.WriteLine('Событий отправки не замечено. Это не является доказательством отсутствия печати.')}
        if($State.EvidenceTruncated){$Writer.WriteLine('Здесь первые 10000 событий. Остальные ищите в основной хронологии отчёта выше.')}
    }
}

function Get-SnifferTargets {
    $ports = @{}
    try { Get-PrinterPort -ErrorAction Stop | ForEach-Object { $ports[$_.Name] = $_ } } catch {}
    try {
        foreach ($printer in @(Get-Printer -Full -ErrorAction Stop | Sort-Object Name)) {
            $port = $ports[$printer.PortName]
            $networkFound=$false
            if (-not $port -or -not $port.PrinterHostAddress) {
                $type=if($printer.PortName -match '^USB[0-9]+'){ 'USB' }elseif($printer.PortName -like 'WSD*'){ 'WSD / очередь Windows' }else{'Очередь Windows'}
                [PSCustomObject]@{Name=$printer.Name;IP='';Port=$printer.PortName;CapturePort=0;CaptureNetwork=$false;ConnectionType=$type}
                continue
            }
            $address = [string]$port.PrinterHostAddress
            try {
                $ip = $null
                $addresses = if ([Net.IPAddress]::TryParse($address, [ref]$ip)) { @($ip) } else { @([Net.Dns]::GetHostAddresses($address)) }
                foreach ($ipv4 in @($addresses | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork })) {
                    if ([Net.IPAddress]::IsLoopback($ipv4) -or $ipv4.Equals([Net.IPAddress]::Any) -or $ipv4.GetAddressBytes()[0] -ge 224) { continue }
                    $networkFound=$true
                    [PSCustomObject]@{ Name=$printer.Name; IP=$ipv4.ToString(); Port=$printer.PortName; CapturePort=$port.PortNumber; CaptureNetwork=$true; ConnectionType='LAN' }
                }
            } catch { Write-Host "Не удалось определить адрес [$($printer.Name)]: $address" -ForegroundColor DarkYellow }
            if(-not $networkFound){[PSCustomObject]@{Name=$printer.Name;IP='';Port=$printer.PortName;CapturePort=0;CaptureNetwork=$false;ConnectionType='Очередь Windows; IPv4 не определён'}}
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
    $payloadLength = 0
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
        $payloadLength = if ($tcpLength -ge 20 -and $headerLength+$tcpLength -le $length) { $length-$headerLength-$tcpLength } else { 0 }
        $detail = "flags=[$flags] seq=$sequence ack=$ack payload=$payloadLength window=$(Get-SnifferUInt16 $Buffer ($headerLength+14))"
    } elseif ($fragment -eq 0 -and $protocol -eq 'UDP' -and $length -ge ($headerLength+8)) {
        $sourcePort = Get-SnifferUInt16 $Buffer $headerLength
        $destinationPort = Get-SnifferUInt16 $Buffer ($headerLength+2)
        $detail = "UDP-length=$(Get-SnifferUInt16 $Buffer ($headerLength+4))"
        $payloadLength = $length-$headerLength-8
    } elseif ($fragment -eq 0 -and $protocol -eq 'ICMP' -and $length -ge ($headerLength+2)) {
        $detail = "type=$($Buffer[$headerLength]) code=$($Buffer[$headerLength+1])"
    }
    if ($fragment -gt 0) { $detail = "IPv4 fragment offset=$($fragment*8); заголовок TCP/UDP в этом фрагменте не декодируется" }
    return [PSCustomObject]@{
        Source=$source; Destination=$destination; Protocol=$protocol; SourcePort=$sourcePort; DestinationPort=$destinationPort
        Detail=$detail; Flags=$flags; Length=$length; Id=(Get-SnifferUInt16 $Buffer 4); TTL=$Buffer[8]
        Truncated=($length -lt $total); PayloadLength=$payloadLength
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
    $networkCapture=[bool]$Target.IP
    if($null -ne $Target.CaptureNetwork){$networkCapture=[bool]$Target.CaptureNetwork}
    if(-not $networkCapture -and -not $Target.Name){throw 'Для наблюдения без сети выберите установленный принтер по имени.'}
    $localAddress = if($networkCapture){Get-SnifferLocalAddress $Target.IP}else{''}
    $selfTarget = $networkCapture -and $localAddress -eq $Target.IP
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
    $watcher = $null
    $watcherStopped = $false
    $live = @{ PrinterName=$Target.Name; NetworkCapture=$networkCapture; Evidence=(New-Object 'System.Collections.Generic.List[string]'); EvidenceTruncated=$false; SawJobs=$false; JobsSeen=0; Arrivals=0; QueueCount=$null; LastJob=''; WindowsReported=$false; Errors=0; PrintBytes=[uint64]0; LastPrint=[datetime]::MinValue; Resets=0; LastReset=[datetime]::MinValue; WatchFailed=$false }
    $printPort = 0
    $null = [int]::TryParse([string]$Target.CapturePort, [ref]$printPort)
    $completed = $false
    $failure = ''
    $packets = 0
    $bytes = [uint64]0
    $counts = @{}
    $reason = 'Пользователь остановил запись'
    try {
        $writer.WriteLine('SCRIPTONITE — СНИФФЕР ПРИНТЕРА И ЖУРНАЛ ОТПРАВКИ')
        $writer.WriteLine("Принтер: $($Target.Name) | Порт Windows: $($Target.Port) | Режим: $($Target.ConnectionType)")
        if($networkCapture){
            $writer.WriteLine("Цель IPv4: $($Target.IP) | Адаптер IPv4: $localAddress")
            $writer.WriteLine('Захватываются только IPv4-пакеты с IP выбранной цели в источнике или назначении.')
            $writer.WriteLine('Полный HEX/ASCII может содержать чеки и SNMP community. Не публикуйте отчёт без проверки содержимого.')
        }else{
            $writer.WriteLine('Наблюдение за выбранной очередью Windows, включая USB. Сырые USB-пакеты не перехватываются; передача USB-байтов не подтверждается.')
        }
        $writer.WriteLine('Поступление и состояния заданий отслеживаются через очередь Windows и уведомления Spooler; событие 307 используется только если журнал уже включён.')
        $writer.WriteLine('PRINTED/COMPLETE и событие 307 отражают сообщение Windows, а не гарантированный выход бумаги. Данные на TCP-порту могут быть служебными, а не документом.')
        $writer.WriteLine('ARP, IPv6 и USB-трафик не захватываются. Пакеты между другими компьютерами и принтером могут не доходить до этого ПК.')
        $writer.WriteLine('Если IP принтера изменится, фильтр останется на исходном IP. Потери в буферах Windows этим способом не измеряются.')
        if ($selfTarget) { $writer.WriteLine("Цель находится на этом ПК: дополнительно фильтруется порт $selfPort. Локальный loopback-обмен raw-сокет может не показать.") }
        $writer.WriteLine("Лимит основной записи: $LimitMegabytes МБ. Файл не перезаписывается по кругу; при достижении лимита запись останавливается.")
        Write-Host 'Снимаю состояние ДО...' -ForegroundColor Cyan
        $before = Get-SnifferSnapshot $Target.Name $Target.IP $localAddress
        Write-SnifferSnapshot $writer $before 'СОСТОЯНИЕ ДО'
        if($networkCapture){
            $socket = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Raw, [Net.Sockets.ProtocolType]::IP)
            $socket.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($localAddress),0)))
            $socket.ReceiveBufferSize = 8388608
            $null = $socket.IOControl([Net.Sockets.IOControlCode]::ReceiveAll, [byte[]](1,0,0,0), $null)
            $buffer = New-Object byte[] 65535
        }
        $started = Get-Date
        $watcher = Start-SnifferPrintWatcher -PrinterName $Target.Name -Started $started
        $writer.WriteLine("`r`n================ НАЧАЛО ЗАПИСИ UTC $($started.ToUniversalTime().ToString('o')) ================")
        Write-Host "`nЗАПИСЬ ИДЁТ: $($Target.Name) | Порт: $($Target.Port) | $($Target.ConnectionType)" -ForegroundColor Green
        if(-not $networkCapture){Write-Host 'Записываются события выбранной очереди Windows; USB-трафик напрямую не захватывается.' -ForegroundColor DarkGray}
        Write-Host "TXT: $path" -ForegroundColor Cyan
        Write-Host '[0] СТОП — также можно нажать Enter или Esc' -ForegroundColor Yellow
        Write-Host 'Теперь меняйте настройки, переустанавливайте драйвер или запускайте печать.'
        Write-Host 'Приход заданий, ошибки и завершение Windows появятся ниже и сохранятся в TXT.' -ForegroundColor Cyan
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $lastDisplay = -1
        while ($true) {
            if (Test-PrinterSnifferStop) { break }
            Receive-SnifferPrintMessages $watcher $live $writer
            if ($socket -and $socket.Poll(100000, [Net.Sockets.SelectMode]::SelectRead)) {
                $length = $socket.Receive($buffer)
                $packet = Read-SnifferPacket $buffer $length
                $matchesTarget = $packet -and ($packet.Source -eq $Target.IP -or $packet.Destination -eq $Target.IP)
                if ($matchesTarget -and $selfTarget) { $matchesTarget = $packet.SourcePort -eq $selfPort -or $packet.DestinationPort -eq $selfPort }
                if ($matchesTarget) {
                    $packets++; $bytes += $packet.Length
                    if (-not $counts.ContainsKey($packet.Protocol)) { $counts[$packet.Protocol] = 0 }
                    $counts[$packet.Protocol]++
                    Write-SnifferPacket $writer $buffer $packet $packets $Target.IP
                    $onPrintChannel = $packet.Protocol -eq 'TCP' -and $printPort -gt 0 -and ($packet.SourcePort -eq $printPort -or $packet.DestinationPort -eq $printPort)
                    if ($onPrintChannel -and $packet.Destination -eq $Target.IP -and $packet.DestinationPort -eq $printPort -and $packet.PayloadLength -gt 0) {
                        $now = Get-Date
                        if (($now-$live.LastPrint).TotalSeconds -gt 2) {
                            $notice = "ДАННЫЕ НА ПОРТ ПЕЧАТИ: $($Target.IP):$printPort. Наличие задания и выход чека этим ещё не подтверждены."
                            Write-SnifferEvidenceEvent $writer $live 'PRINT_DATA' $notice 'Cyan'
                        }
                        $live.LastPrint=$now; $live.PrintBytes+=$packet.PayloadLength
                    }
                    if ($onPrintChannel -and $packet.Flags -match 'RST') {
                        $live.Resets++
                        $now = Get-Date
                        if (($now-$live.LastReset).TotalSeconds -gt 1) {
                            $notice='TCP RST на канале печати: соединение сброшено. Итог задания по одному пакету не определяется.'
                            Write-SnifferEvidenceEvent $writer $live 'PRINT_TCP_RST' $notice 'Red'
                            $live.LastReset=$now
                        }
                    }
                }
            }elseif(-not $socket){Start-Sleep -Milliseconds 100}
            if ($writer.BaseStream.Length -ge ([int64]$LimitMegabytes*1MB)) { $reason = 'Достигнут лимит размера TXT'; break }
            $second = [int]$clock.Elapsed.TotalSeconds
            if ($second -ne $lastDisplay -and $second % 5 -eq 0) {
                Write-Host "Идёт запись: $second с | [0] Стоп" -ForegroundColor DarkGray
                if($networkCapture){Write-Host "IPv4-пакетов: $packets | IP-байт: $bytes" -ForegroundColor DarkGray}
                $queueText=if($null -eq $live.QueueCount){'неизвестно'}else{[string]$live.QueueCount}
                Write-Host "Документов сейчас в очереди: $queueText | Заданий замечено: $($live.JobsSeen) | Уведомлений о поступлении: $($live.Arrivals)" -ForegroundColor Yellow
                $dataText=if($live.LastPrint -eq [datetime]::MinValue){'пока не замечены'}elseif(((Get-Date)-$live.LastPrint).TotalSeconds -lt 3){'ИДЁТ ПЕРЕДАЧА'}else{'передавались; последнее наблюдение '+$live.LastPrint.ToString('HH:mm:ss')}
                if($networkCapture){Write-Host "Данные на печатный порт: $dataText"}
                $receiptText=if($live.SawJobs){'ДА — задания в выбранной очереди зафиксированы'}else{'пока не замечены'}
                Write-Host "Задания Windows: $receiptText" -ForegroundColor $(if($live.SawJobs){'Green'}else{'DarkGray'})
                $resultText=if($live.Errors -gt 0){"За время записи были ошибки заданий: $($live.Errors). Смотрите события выше."}elseif($live.WindowsReported){'Windows сообщала о завершении; бумага не подтверждена'}else{'завершение печати пока не подтверждено'}
                $resultColor=if($live.Errors -gt 0){'Red'}elseif($live.WindowsReported){'Green'}else{'DarkGray'}
                Write-Host "Результат наблюдения: $resultText" -ForegroundColor $resultColor
                if($live.LastJob){Write-Host ('Последнее: '+$live.LastJob) -ForegroundColor $(if($live.LastJob -like 'ОШИБКА:*'){'Red'}else{'DarkGray'})}
                $lastDisplay = $second
            }
        }
        $ended = Get-Date
        $clock.Stop()
        if($socket){$socket.Close(); $socket=$null}
        $watcherDone = Stop-SnifferPrintWatcher $watcher
        $watcherStopped = $true
        Receive-SnifferPrintMessages $watcher $live $writer
        if(-not $watcherDone){$writer.WriteLine('Наблюдатель очереди не завершил текущий запрос вовремя; сведения о заданиях могут быть неполными.')}
        $writer.WriteLine("`r`n================ ЗАПИСЬ ОСТАНОВЛЕНА ================")
        $writer.WriteLine("Конец UTC: $($ended.ToUniversalTime().ToString('o')) | Причина: $reason")
        if($networkCapture){$writer.WriteLine("Пакетов: $packets | IP-байт: $bytes")}
        foreach ($protocol in ($counts.Keys | Sort-Object)) { $writer.WriteLine("${protocol}: $($counts[$protocol])") }
        Write-SnifferPrintSummary $writer $live
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
        try {
            if($watcher -and -not $watcherStopped){$null=Stop-SnifferPrintWatcher $watcher;Receive-SnifferPrintMessages $watcher $live $writer}
            if (-not $completed) { $writer.WriteLine("`r`nОТЧЁТ НЕПОЛНЫЙ: запись прервана либо часть завершающих действий не выполнена."); Write-SnifferPrintSummary $writer $live }
            $writer.WriteLine("`r`nКОНЕЦ ОТЧЁТА UTC $([DateTime]::UtcNow.ToString('o'))")
        } finally { $writer.Flush(); $writer.Dispose() }
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
        Write-Host 'СНИФФЕР ПРИНТЕРА — USB / LAN / ОЧЕРЕДЬ WINDOWS' -ForegroundColor Cyan
        $targets = @(Get-SnifferTargets)
        for ($i=0; $i -lt $targets.Count; $i++) { Write-Host "[$($i+1)] $($targets[$i].Name) | $($targets[$i].ConnectionType) | $($targets[$i].IP) | $($targets[$i].Port)" }
        $manualNumber = $targets.Count+1
        Write-Host "[$manualNumber] Ввести IPv4 вручную"
        Write-Host '[0] Выход'
        Write-Host "Отчёты рядом со скриптом: $OutputDirectory" -ForegroundColor DarkGray
        Write-Host 'USB: события очереди и имена документов. LAN: дополнительно IPv4-пакеты, которые могут содержать данные чеков.' -ForegroundColor Yellow
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
            $target = [PSCustomObject]@{ Name=''; IP=$ip.ToString(); Port='ручной адрес'; CapturePort=0; CaptureNetwork=$true; ConnectionType='LAN, ручной IP' }
            $portText=([string](Read-Host 'TCP-порт печати [9100], либо 0 если неизвестен')).Trim()
            if(-not $portText){$portText='9100'}
            $portNumber=0
            if(-not [int]::TryParse($portText,[ref]$portNumber) -or $portNumber -lt 0 -or $portNumber -gt 65535){Write-Host 'Неверный номер порта.' -ForegroundColor Yellow;$null=Read-Host 'Enter — назад';continue}
            $target.CapturePort=$portNumber
        } else { $target = $targets[$number-1] }
        try {
            $result = Start-PrinterSnifferSession -Target $target -Directory $OutputDirectory -LimitMegabytes $MaxMegabytes
            if ($result.Completed) { Write-Host "`nГОТОВО. Отчёт сохранён." -ForegroundColor Green }
            else { Write-Host "Отчёт неполный: $($result.Error)" -ForegroundColor Yellow }
            Write-Host "TXT: $($result.Path)" -ForegroundColor Cyan
        } catch { Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red }
        $null = Read-Host 'Enter — вернуться к выбору'
    }
} catch {
    Write-Host "Не удалось открыть сниффер: $($_.Exception.Message)" -ForegroundColor Red
    $null = Read-Host 'Enter — выход'
}
