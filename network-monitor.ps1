[CmdletBinding()]
param(
    [int]$InterfaceIndex = 0,
    [ValidateRange(1, 3600)][int]$IntervalSeconds = 30,
    [ValidateRange(10, 86400)][int]$QuietSeconds = 90,
    [string]$OutputDirectory
)

# BEGIN SCRIPTONITE ERROR LOGGING
function Write-ScriptoniteError {
    param([string]$Context='Script execution', $ErrorRecord, [string]$Message)
    # No events and an intentional Ctrl+C are normal outcomes, not failures.
    if($ErrorRecord -and ($ErrorRecord.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $ErrorRecord.Exception -is [System.Management.Automation.PipelineStoppedException])){return}
    $state=$script:ScriptoniteErrorLog
    if(-not $state){return}
    $locked=$false
    try{
        [Threading.Monitor]::Enter($state.SyncRoot);$locked=$true
        $detail=$Message
        if($ErrorRecord){
            $detail=($ErrorRecord | Out-String -Width 240).Trim()
            $detail+=[Environment]::NewLine+'Error ID: '+$ErrorRecord.FullyQualifiedErrorId
            $detail+=[Environment]::NewLine+'Exception: '+$ErrorRecord.Exception.ToString()
            $detail+=[Environment]::NewLine+'Location: '+$ErrorRecord.InvocationInfo.PositionMessage
            $detail+=[Environment]::NewLine+'Stack: '+$ErrorRecord.ScriptStackTrace
        }
        $key=$Context+'|'+$detail
        $now=[DateTime]::UtcNow
        # Preserve the first failure and repeated failures at most once a minute.
        if($state.Recent.ContainsKey($key) -and ($now-$state.Recent[$key]).TotalSeconds -lt 60){return}
        $line=$now.ToString('o')+' ['+$state.Script+'] ['+$Context+']'+[Environment]::NewLine+$detail+[Environment]::NewLine+[Environment]::NewLine
        $paths=@()
        if($state.Path){$paths+=$state.Path}
        foreach($directory in $state.Directories){if($directory){$paths+=[IO.Path]::Combine($directory,$state.Name)}}
        foreach($path in @($paths | Select-Object -Unique)){
            try{
                $fullPath=[IO.Path]::GetFullPath($path)
                $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
                $encoding=New-Object Text.UTF8Encoding($true)
                if(-not [IO.File]::Exists($fullPath)){
                    $header='SCRIPTONITE - SCRIPT EXECUTION ERRORS'+[Environment]::NewLine+'Script: '+$state.Script+[Environment]::NewLine+'PowerShell: '+$PSVersionTable.PSVersion+[Environment]::NewLine
                    [IO.File]::WriteAllText($fullPath,$header,$encoding)
                }
                [IO.File]::AppendAllText($fullPath,$line,$encoding)
                if($state.Path -ne $fullPath){Write-Host ('Error log: '+$fullPath) -ForegroundColor Yellow}
                $state.Path=$fullPath
                if($state.Recent.Count -gt 512){$state.Recent.Clear()}
                $state.Recent[$key]=$now
                return
            }catch{ }
        }
        if(-not $state.Failed){Write-Host 'Could not save the error log beside the script or on Desktop.' -ForegroundColor Red;$state.Failed=$true}
    }catch{ }
    finally{if($locked){[Threading.Monitor]::Exit($state.SyncRoot)}}
}
$errorDirectory=$OutputDirectory
if(-not $errorDirectory -and $env:SCRIPTONITE_SOURCE){$errorDirectory=[IO.Path]::GetDirectoryName($env:SCRIPTONITE_SOURCE)}
if(-not $errorDirectory -and $PSScriptRoot -and $PSScriptRoot -notmatch '[\\/]Scriptonite[\\/](scripts|launcher)([\\/]|$)'){$errorDirectory=$PSScriptRoot}
if(-not $errorDirectory){$errorDirectory=[Environment]::GetFolderPath('Desktop')}
$script:ScriptoniteErrorLog=@{
    Script='network-monitor';Path='';Failed=$false;Recent=@{};SyncRoot=(New-Object object)
    Directories=@($errorDirectory,[Environment]::GetFolderPath('Desktop') | Where-Object {$_} | Select-Object -Unique)
    Name=('ScriptoniteErrors_network-monitor_{0}_{1}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'),[guid]::NewGuid().ToString('N').Substring(0,6))
}
trap { Write-ScriptoniteError -Context 'Unhandled script error' -ErrorRecord $_; break }
# END SCRIPTONITE ERROR LOGGING

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Откройте PowerShell от имени администратора и запустите скрипт снова.'
}
if ([Console]::IsInputRedirected) { throw 'Запустите скрипт в обычном PowerShell или Windows Terminal.' }

$script:socket = $null
$script:buffer = New-Object byte[] 65535
$script:heard = @{}
$script:events = New-Object 'System.Collections.Generic.List[object]'
$script:live = $false
$previousDevices = @{}
$previousNeighbors = @{}
$baseline = $false
$networkKey = ''
$cycle = 0
$pendingPings = @()
$consoleGuard = $null

function Start-NetworkConsoleGuard {
    # Prevent accidental mouse selection from pausing the legacy Windows console.
    try {
        if (-not ('ScriptoniteNetwork.ConsoleInputGuard' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ScriptoniteNetwork {
    public sealed class ConsoleInputGuard : IDisposable {
        readonly IntPtr input;
        readonly uint previous;
        bool changed;
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr GetStdHandle(int standardHandle);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetConsoleMode(IntPtr handle, out uint mode);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool SetConsoleMode(IntPtr handle, uint mode);
        public ConsoleInputGuard() {
            input=GetStdHandle(-10);
            uint mode;
            if(input==IntPtr.Zero || input==new IntPtr(-1) || !GetConsoleMode(input,out mode)) return;
            previous=mode;
            uint running=(mode | 0x0080u) & ~0x0040u;
            if(running!=mode) changed=SetConsoleMode(input,running);
        }
        public void Dispose() {
            if(!changed) return;
            // EXTENDED_FLAGS must be set while restoring the QuickEdit bit.
            if(SetConsoleMode(input,previous | 0x0080u)) {
                SetConsoleMode(input,previous);
                changed=false;
            }
        }
    }
}
'@ -Language CSharp
        }
        return New-Object ScriptoniteNetwork.ConsoleInputGuard
    } catch { Write-ScriptoniteError -Context 'network-monitor.ps1 / Start-NetworkConsoleGuard / catch at line 69' -ErrorRecord $_;  Write-Verbose ('Не удалось отключить быстрое выделение: '+$_.Exception.Message) }
}

function Add-Event([string]$Message, [string]$Color = 'Yellow') {
    $entry = [PSCustomObject]@{ Text = "$(Get-Date -Format 'HH:mm:ss') $Message"; Color = $Color }
    $script:events.Add($entry)
    if ($script:events.Count -gt 20) { $script:events.RemoveAt(0) }
    if ($script:live) { Write-Host $entry.Text -ForegroundColor $Color }
}

function Test-OtherSubnet([string]$IPAddress) {
    # Active scanning is restricted to /24, so the first three octets identify it.
    return $IPAddress -notlike "$script:net.*"
}

function Read-Traffic {
    # A bounded batch keeps the keyboard and scanning responsive on a busy link.
    for ($batch = 0; $batch -lt 128; $batch++) {
        if (-not $script:socket.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) { break }
        $length = $script:socket.Receive($script:buffer)
        $b = $script:buffer
        if ($length -lt 20 -or ($b[0] -shr 4) -ne 4) { continue }
        $source = $b[12..15] -join '.'
        $destination = $b[16..19] -join '.'
        # Private IPv4 and link-local sources; suppress ordinary Internet replies.
        $private = $b[12] -eq 10 -or
            ($b[12] -eq 172 -and $b[13] -ge 16 -and $b[13] -le 31) -or
            ($b[12] -eq 192 -and $b[13] -eq 168) -or
            ($b[12] -eq 169 -and $b[13] -eq 254)
        if (-not $private -or -not (Test-OtherSubnet $source)) { continue }
        $protocol = switch ($b[9]) {
            6 { 'TCP' }
            17 { 'UDP' }
            1 { 'ICMP' }
            2 { 'IGMP' }
            default { "IP/$($b[9])" }
        }
        $headerLength = ($b[0] -band 15) * 4
        $fragmentOffset = (($b[6] -band 31) * 256) + $b[7]
        if ($b[9] -eq 17 -and $fragmentOffset -eq 0 -and $headerLength -ge 20 -and $length -ge ($headerLength + 8)) {
            $port = ([int]$b[$headerLength + 2] * 256) + $b[$headerLength + 3]
            $protocol = switch ($port) {
                5353 { 'UDP/mDNS' }
                5355 { 'UDP/LLMNR' }
                1900 { 'UDP/SSDP' }
                137 { 'UDP/NBNS' }
                67 { 'UDP/DHCP' }
                68 { 'UDP/DHCP' }
                default { "UDP/$port" }
            }
        }
        $scope = 'Другая подсеть'
        $now = Get-Date
        if (-not $script:heard.ContainsKey($source)) {
            Add-Event "ДРУГОЙ IP: обнаружен $source"
        } elseif ($script:heard[$source].Quiet) {
            Add-Event "ДРУГОЙ IP: $source снова передаёт данные"
        }
        $script:heard[$source] = [PSCustomObject]@{
            IP = $source; Подсеть = $scope; Протокол = $protocol
            Получатель = $destination; LastSeen = $now; Quiet = $false
        }
    }
    $now = Get-Date
    foreach ($device in $script:heard.Values) {
        if (-not $device.Quiet -and ($now - $device.LastSeen).TotalSeconds -ge $QuietSeconds) {
            $device.Quiet = $true
            Add-Event "ДРУГОЙ IP: $($device.IP) — давно не замечен (нет пакетов $QuietSeconds с)"
        }
    }
}

function Show-Table($Rows, [string]$Color = 'White') {
    if (@($Rows).Count -eq 0) { Write-Host 'Нет записей.' -ForegroundColor $Color; return }
    $formatted = $Rows | Sort-Object { [version]$_.IP } | Format-Table -AutoSize | Out-String -Width 200
    Write-Host $formatted -ForegroundColor $Color
}

try {
    $consoleGuard = Start-NetworkConsoleGuard
    while ($true) {
        $script:live = $false
        $configs = @(Get-NetIPConfiguration | Where-Object { $_.IPv4Address })
        $cfg = if ($InterfaceIndex) {
            $configs | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex } | Select-Object -First 1
        } else {
            $configs | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        }
        if (-not $cfg) { throw 'Активный адаптер не найден. Можно указать -InterfaceIndex НОМЕР.' }
        $addr = $cfg.IPv4Address | Select-Object -First 1
        if ($addr.PrefixLength -ne 24) {
            throw "Эта версия сканирует /24. У адаптера $($addr.IPAddress)/$($addr.PrefixLength)."
        }
        $script:localIP = $addr.IPAddress
        $script:net = ($script:localIP -split '\.')[0..2] -join '.'
        $key = "$($cfg.InterfaceIndex):$script:localIP/$($addr.PrefixLength)"
        if ($networkKey -ne $key) {
            if ($script:socket) { $script:socket.Close(); $script:socket = $null }
            $script:socket = New-Object System.Net.Sockets.Socket(
                [System.Net.Sockets.AddressFamily]::InterNetwork,
                [System.Net.Sockets.SocketType]::Raw,
                [System.Net.Sockets.ProtocolType]::IP
            )
            $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($script:localIP), 0)
            $script:socket.Bind($endpoint)
            $script:socket.IOControl([System.Net.Sockets.IOControlCode]::ReceiveAll, [byte[]](1,0,0,0), $null) | Out-Null
            $script:socket.ReceiveBufferSize = 1048576
            $script:heard = @{}
            $previousDevices = @{}
            $previousNeighbors = @{}
            $baseline = $false
            $networkKey = $key
            $script:events.Clear()
            Add-Event "АДАПТЕР: $($cfg.InterfaceAlias), $script:localIP/24. Создаётся исходный список." 'Cyan'
        }

        $cycle++
        Clear-Host
        Write-Host "Проверка №$cycle | $($cfg.InterfaceAlias) | $script:localIP/24 | $(Get-Date)" -ForegroundColor Cyan
        Write-Host 'Сканирование и прослушивание...'

        $pendingPings = @()
        foreach ($number in 1..254) {
            $ip = "$script:net.$number"
            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                $task = $ping.SendPingAsync($ip, 1000)
                $pendingPings += [PSCustomObject]@{ IP = $ip; Ping = $ping; Task = $task }
            } catch { Write-ScriptoniteError -Context 'network-monitor.ps1 / Main / catch at line 197' -ErrorRecord $_;  $ping.Dispose(); throw }
        }
        while (@($pendingPings | Where-Object { -not $_.Task.IsCompleted }).Count -gt 0) {
            Read-Traffic
            Start-Sleep -Milliseconds 25
        }
        $currentPing = @{}
        foreach ($request in $pendingPings) {
            try {
                if ($request.Task.GetAwaiter().GetResult().Status -eq 'Success') {
                    $currentPing[$request.IP] = [PSCustomObject]@{ IP = $request.IP; Статус = 'Ping' }
                }
            } catch { Write-ScriptoniteError -Context 'network-monitor.ps1 / Main / catch at line 209' -ErrorRecord $_; } finally { $request.Ping.Dispose() }
        }
        $pendingPings = @()
        Read-Traffic

        $allNeighbors = @{}
        Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $cfg.InterfaceIndex |
            Where-Object {
                $_.State -in @('Reachable', 'Stale', 'Delay', 'Probe', 'Unreachable') -and
                $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(00[-:]?){6}$|^(FF[-:]?){6}$'
            } | ForEach-Object {
                $allNeighbors[$_.IPAddress] = [PSCustomObject]@{
                    IP = $_.IPAddress; MAC = $_.LinkLayerAddress; Статус = "$($_.State)"
                }
            }
        $neighbors = @{}
        foreach ($ip in $allNeighbors.Keys) {
            if (Test-OtherSubnet $ip) { $neighbors[$ip] = $allNeighbors[$ip] }
        }
        $devices = @{}
        foreach ($ip in $allNeighbors.Keys) {
            if (-not (Test-OtherSubnet $ip)) {
                $devices[$ip] = [PSCustomObject]@{ IP = $ip; MAC = $allNeighbors[$ip].MAC; Статус = $allNeighbors[$ip].Статус }
            }
        }
        foreach ($ip in $currentPing.Keys) {
            $mac = if ($allNeighbors.ContainsKey($ip)) { $allNeighbors[$ip].MAC } else { '' }
            $devices[$ip] = [PSCustomObject]@{ IP = $ip; MAC = $mac; Статус = 'Ping' }
        }
        $statusChanges = @()
        if ($baseline) {
            foreach ($ip in $devices.Keys) {
                if (-not $previousDevices.ContainsKey($ip)) {
                    Add-Event "УСТРОЙСТВО: появился $ip | $($devices[$ip].Статус)" 'Green'
                } elseif ($previousDevices[$ip].Статус -ne $devices[$ip].Статус) {
                    $statusChanges += [PSCustomObject]@{
                        IP = $ip; MAC = $devices[$ip].MAC
                        Было = $previousDevices[$ip].Статус; Стало = $devices[$ip].Статус
                    }
                    Add-Event "УСТРОЙСТВО: $ip | $($previousDevices[$ip].Статус) -> $($devices[$ip].Статус)"
                }
            }
            foreach ($ip in $previousDevices.Keys) {
                if (-not $devices.ContainsKey($ip)) { Add-Event "УСТРОЙСТВО: $ip пропало из списка наблюдаемых" 'Red' }
            }
            foreach ($ip in $neighbors.Keys) {
                if (-not $previousNeighbors.ContainsKey($ip)) {
                    if (-not $script:heard.ContainsKey($ip)) { Add-Event "ДРУГОЙ IP: обнаружен $ip" }
                } else {
                    $old = $previousNeighbors[$ip]
                    $new = $neighbors[$ip]
                    if ($old.Статус -ne $new.Статус) { Add-Event "ДРУГОЙ IP: $ip | $($old.Статус) -> $($new.Статус)" }
                    if ($old.MAC -ne $new.MAC) { Add-Event "ДРУГОЙ IP: $ip | MAC $($old.MAC) -> $($new.MAC)" }
                }
            }
            foreach ($ip in $previousNeighbors.Keys) {
                if (-not $neighbors.ContainsKey($ip) -and -not $script:heard.ContainsKey($ip)) {
                    Add-Event "ДРУГОЙ IP: $ip больше не наблюдается"
                }
            }
        }
        $previousDevices = $devices
        $previousNeighbors = $neighbors
        $baseline = $true

        Write-Host "`nУСТРОЙСТВА СВОЕЙ ПОДСЕТИ $script:net.0/24:"
        Write-Host ('{0,-16} {1,-20} {2}' -f 'IP', 'MAC', 'Статус')
        foreach ($device in ($devices.Values | Sort-Object { [version]$_.IP })) {
            $color = if ($device.Статус -eq 'Ping') { 'White' } else { 'Yellow' }
            Write-Host ('{0,-16} {1,-20} {2}' -f $device.IP, $device.MAC, $device.Статус) -ForegroundColor $color
        }
        if ($statusChanges.Count -gt 0) {
            Write-Host "`nИЗМЕНИЛСЯ СТАТУС:" -ForegroundColor Yellow
            Show-Table $statusChanges 'Yellow'
        }
        Write-Host ''
        Write-Host 'ДРУГИЕ IP В СЕТИ:' -ForegroundColor Yellow
        $otherIPs = @{}
        foreach ($ip in $neighbors.Keys) {
            $observation = switch ($neighbors[$ip].Статус) {
                'Reachable' { 'Недавно доступен' }
                'Probe' { 'Проверяется доступность' }
                'Delay' { 'Ожидается проверка' }
                'Unreachable' { 'Не отвечает на проверку ARP' }
                default { 'Адрес известен Windows' }
            }
            $otherIPs[$ip] = [PSCustomObject]@{
                IP = $ip; MAC = $neighbors[$ip].MAC
                Наблюдение = $observation; 'Последний пакет' = '-'
            }
        }
        foreach ($device in $script:heard.Values) {
            $mac = if ($neighbors.ContainsKey($device.IP)) { $neighbors[$device.IP].MAC } else { '-' }
            $observation = if ($device.Quiet) { "Давно не замечен (нет пакетов $QuietSeconds с)" } else { 'Недавно замечен' }
            if ($neighbors.ContainsKey($device.IP) -and $neighbors[$device.IP].Статус -eq 'Reachable') {
                $observation = 'Недавно доступен'
            }
            $otherIPs[$device.IP] = [PSCustomObject]@{
                IP = $device.IP; MAC = $mac; Наблюдение = $observation
                'Последний пакет' = $device.LastSeen.ToString('HH:mm:ss')
            }
        }
        Show-Table @($otherIPs.Values) 'Yellow'
        Write-Host 'ПОСЛЕДНИЕ 20 СОБЫТИЙ:' -ForegroundColor Cyan
        foreach ($entry in $script:events) { Write-Host $entry.Text -ForegroundColor $entry.Color }
        Write-Host "`nЕсли подключение изменилось, нажмите Enter. Повтор через $IntervalSeconds с. Ctrl+C — остановить."
        Write-Host 'Прослушивание продолжается во время ожидания; новые события появляются ниже.'
        $script:live = $true
        $deadline = (Get-Date).AddSeconds($IntervalSeconds)
        while ((Get-Date) -lt $deadline) {
            Read-Traffic
            if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Enter') { break }
            Start-Sleep -Milliseconds 50
        }
    }
} catch { Write-ScriptoniteError -Context 'network-monitor.ps1 / Main / catch at line 324' -ErrorRecord $_; 
    Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($consoleGuard) { $consoleGuard.Dispose() }
    foreach ($request in $pendingPings) { $request.Ping.Dispose() }
    if ($script:socket) { $script:socket.Close() }
}
