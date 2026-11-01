@echo off
setlocal
title Scriptonite
set "SCRIPTONITE_SOURCE=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $text=[IO.File]::ReadAllText($env:SCRIPTONITE_SOURCE,[Text.Encoding]::UTF8); $marker='#==SCRIPTONITE_PS1==#'; $offset=$text.LastIndexOf($marker); if ($offset -lt 0) { throw 'Embedded script was not found.' }; $payload=$text.Substring($offset+$marker.Length); $root=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Scriptonite\launcher'; $run=Join-Path $root ([Guid]::NewGuid().ToString('N')); $null=New-Item -ItemType Directory -Path $run -Force; $entry=Join-Path $run 'Scriptonite.ps1'; [IO.File]::WriteAllText($entry,$payload,(New-Object Text.UTF8Encoding($true))); & $entry } catch { $failure=$_; $saved=$false; $name='ScriptoniteErrors_cmd_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.txt'; foreach($dir in @([IO.Path]::GetDirectoryName($env:SCRIPTONITE_SOURCE),[Environment]::GetFolderPath('Desktop'))){try{$log=Join-Path $dir $name; [IO.File]::WriteAllText($log,('SCRIPTONITE CMD - '+[DateTime]::UtcNow.ToString('o')+[Environment]::NewLine+$failure.Exception.ToString()+[Environment]::NewLine+$failure.InvocationInfo.PositionMessage+[Environment]::NewLine+$failure.ScriptStackTrace),(New-Object Text.UTF8Encoding($true))); Write-Host ('Error log: '+$log) -ForegroundColor Yellow; $saved=$true; break}catch{}}; if(-not $saved){Write-Host 'Could not save error log beside CMD or on Desktop.' -ForegroundColor Red}; Write-Host ('Scriptonite: '+$failure.Exception.Message) -ForegroundColor Red; exit 1 }"
if errorlevel 1 (
    echo Scriptonite could not start.
    pause
)
exit /b
#==SCRIPTONITE_PS1==#
[CmdletBinding()]
param([string]$ReportDirectory)

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
$errorDirectory=$ReportDirectory
if(-not $errorDirectory -and $env:SCRIPTONITE_SOURCE){$errorDirectory=[IO.Path]::GetDirectoryName($env:SCRIPTONITE_SOURCE)}
if(-not $errorDirectory -and $PSScriptRoot -and $PSScriptRoot -notmatch '[\\/]Scriptonite[\\/](scripts|launcher)([\\/]|$)'){$errorDirectory=$PSScriptRoot}
if(-not $errorDirectory){$errorDirectory=[Environment]::GetFolderPath('Desktop')}
$script:ScriptoniteErrorLog=@{
    Script='Scriptonite';Path='';Failed=$false;Recent=@{};SyncRoot=(New-Object object)
    Directories=@($errorDirectory,[Environment]::GetFolderPath('Desktop') | Where-Object {$_} | Select-Object -Unique)
    Name=('ScriptoniteErrors_Scriptonite_{0}_{1}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'),[guid]::NewGuid().ToString('N').Substring(0,6))
}
trap { Write-ScriptoniteError -Context 'Unhandled script error' -ErrorRecord $_; break }
# END SCRIPTONITE ERROR LOGGING

$ErrorActionPreference = 'Stop'

function Show-ScriptoniteHeader {
    Clear-Host
    $Host.UI.RawUI.WindowTitle = 'Scriptonite'
    Write-Host @'
╔═══════╗                     ╔═╗             ╔═╗                         ╔═╗   ╔═╗
║ ╔═════╝ ╔═══════╗ ╔═╗ ╔═══╗ ╚═╝ ╔═══════╗ ╔═╝ ╚═╗   ╔═══════╗ ╔═══════╗ ╚═╝ ╔═╝ ╚═╗     ╔═══╗
║ ╚═════╗ ║ ╔═════╝ ║ ╚═╝ ╔═╝ ╔═╗ ║ ╔═══╗ ║ ╚═╗ ╔═╝   ║ ╔═══╗ ║ ║ ╔═══╗ ║ ╔═╗ ╚═╗ ╔═╝   ╔═╝   ╚═╗
╚═════╗ ║ ║ ║       ║ ╔═══╝   ║ ║ ║ ║   ║ ║   ║ ║     ║ ║   ║ ║ ║ ║   ║ ║ ║ ║   ║ ║     ║ ╔═════╝
╔═════╝ ║ ║ ╚═════╗ ║ ║       ║ ║ ║ ╚═══╝ ║   ║ ╚═══╗ ║ ╚═══╝ ║ ║ ║   ║ ║ ║ ║   ║ ╚═══╗ ║ ╚═════╗
╚═══════╝ ╚═══════╝ ╚═╝       ╚═╝ ║ ╔═════╝   ╚═════╝ ╚═══════╝ ╚═╝   ╚═╝ ╚═╝   ╚═════╝ ╚═══════╝
                                  ║ ║
                                  ╚═╝
'@ -ForegroundColor White
    Write-Host 'Хранилище диагностических скриптов' -ForegroundColor DarkGray
    Write-Host ''
}

function Test-ScriptoniteAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally {
        $identity.Dispose()
    }
}

function Start-ScriptoniteElevated {
    param([string]$ScriptPath, [string]$PowerShellPath, [string]$ReportDirectory)

    # EncodedCommand safely carries paths containing spaces or apostrophes.
    $escapedPath = $ScriptPath.Replace("'", "''")
    $command = "& '$escapedPath'"
    if($ReportDirectory){$command += " -ReportDirectory '$($ReportDirectory.Replace("'", "''"))'"}
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    try {
        Start-Process -FilePath $PowerShellPath -Verb RunAs -WindowStyle Normal -ErrorAction Stop -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
        ) | Out-Null
        return $true
    } catch { Write-ScriptoniteError -Context 'Scriptonite.ps1 / Start-ScriptoniteElevated / catch at line 46' -ErrorRecord $_; 
        Write-Host ''
        Write-Host 'Scriptonite нужны права администратора.' -ForegroundColor Yellow
        Write-Host 'Разрешение не получено. Скрипты не запущены.' -ForegroundColor Yellow
        Write-Host "Причина: $($_.Exception.Message)" -ForegroundColor DarkGray
        return $false
    }
}

function Get-ScriptoniteDownloadBytes {
    param(
        [Parameter(Mandatory=$true)][uri]$Uri,
        [string]$Activity='Scriptonite: download',
        [ValidateRange(1,3600)][int]$TimeoutSeconds=120
    )
    if($Uri.Scheme -ne 'https'){throw 'Download requires HTTPS.'}
    $ProgressPreference='Continue'
    $previousProtocols=[Net.ServicePointManager]::SecurityProtocol
    $client=$null; $handler=$null; $response=$null; $stream=$null; $memory=$null; $cancel=$null
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $received=[int64]0; $total=[int64]-1; $lastDraw=[int64]-200
    $showProgress={
        param([bool]$Finished=$false)
        if(-not $Finished -and $timer.ElapsedMilliseconds-$lastDraw -lt 200){return}
        $speed=$received/1KB/[Math]::Max(0.001,$timer.Elapsed.TotalSeconds)
        $percent=-1
        if($total -ge 0){
            $percent=if($total -gt 0){[int][Math]::Min(100,[Math]::Floor(100.0*$received/$total))}else{100}
            $status='{0:N1} / {1:N1} KB | {2}% | {3:N1} KB/s' -f ($received/1KB),($total/1KB),$percent,$speed
        }else{
            $status='{0:N1} KB | total unknown | {1:N1} KB/s' -f ($received/1KB),$speed
        }
        if($Finished){$status+=' | done'}
        Write-Progress -Id 35 -Activity $Activity -Status $status -PercentComplete $percent
        $lastDraw=$timer.ElapsedMilliseconds
    }
    try {
        Add-Type -AssemblyName System.Net.Http
        [Net.ServicePointManager]::SecurityProtocol=$previousProtocols -bor [Net.SecurityProtocolType]::Tls12
        $handler=New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect=$true
        $client=New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('Scriptonite/1.0')
        $cancel=New-Object Threading.CancellationTokenSource
        $cancel.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
        Write-Progress -Id 35 -Activity $Activity -Status 'Connecting... | 0.0 KB' -PercentComplete -1
        $request=$client.GetAsync($Uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token)
        while(-not $request.IsCompleted){
            if($cancel.IsCancellationRequested){throw 'Download timeout.'}
            Start-Sleep -Milliseconds 100
        }
        $response=$request.GetAwaiter().GetResult()
        if(-not $response.IsSuccessStatusCode){throw "Download failed: HTTP $([int]$response.StatusCode) ($($response.ReasonPhrase))."}
        if($null -ne $response.Content.Headers.ContentLength){$total=[int64]$response.Content.Headers.ContentLength}
        $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $memory=New-Object IO.MemoryStream
        $buffer=New-Object byte[] 8192
        . $showProgress
        while($true){
            if($cancel.IsCancellationRequested){throw 'Download timeout.'}
            $read=$stream.ReadAsync($buffer,0,$buffer.Length,$cancel.Token)
            while(-not $read.IsCompleted){
                if($cancel.IsCancellationRequested){throw 'Download timeout.'}
                . $showProgress
                Start-Sleep -Milliseconds 100
            }
            $count=$read.GetAwaiter().GetResult()
            if($count -eq 0){break}
            $memory.Write($buffer,0,$count)
            $received+=$count
            . $showProgress
        }
        if($total -ge 0 -and $received -ne $total){throw "Incomplete download: $received of $total bytes."}
        . $showProgress $true
        return ,$memory.ToArray()
    } catch { Write-ScriptoniteError -Context 'Scriptonite.ps1 / Get-ScriptoniteDownloadBytes / catch at line 122' -ErrorRecord $_; 
        if($cancel -and $cancel.IsCancellationRequested){throw "Download timed out after $TimeoutSeconds seconds."}
        throw
    } finally {
        Write-Progress -Id 35 -Activity $Activity -Completed
        $timer.Stop()
        if($stream){$stream.Dispose()}
        if($memory){$memory.Dispose()}
        if($response){$response.Dispose()}
        if($client){$client.Dispose()}elseif($handler){$handler.Dispose()}
        if($cancel){$cancel.Dispose()}
        [Net.ServicePointManager]::SecurityProtocol=$previousProtocols
    }
}

function Save-ScriptoniteDownload {
    param(
        [Parameter(Mandatory = $true)][uri]$Uri,
        [Parameter(Mandatory = $true)][string]$CacheDirectory
    )
    $bytes=Get-ScriptoniteDownloadBytes -Uri $Uri -Activity ('Загрузка: '+$Uri.Segments[-1])
    return Save-ScriptoniteScriptBytes -Bytes $bytes -CacheDirectory $CacheDirectory
}

function Save-ScriptoniteScriptBytes {
    param([byte[]]$Bytes, [string]$CacheDirectory)

    if (-not $Bytes -or $Bytes.Length -eq 0) { throw 'GitHub вернул пустой файл.' }
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $text = $utf8.GetString($Bytes).TrimStart([char]0xFEFF)
    if ($text.TrimStart() -match '^(?i:<!DOCTYPE\s+html|<html\b)') {
        throw 'Вместо скрипта получена HTML-страница. Нужна прямая ссылка Raw.'
    }
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "В скачанном скрипте ошибка синтаксиса: $($parseErrors[0].Message)"
    }
    $null = New-Item -ItemType Directory -Path $CacheDirectory -Force
    # Separate immutable file for every run: an open monitor is never overwritten.
    $filename = 'script-{0}.ps1' -f [Guid]::NewGuid().ToString('N')
    $target = Join-Path $CacheDirectory $filename
    [IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding($true)))
    return $target
}

function Start-ScriptoniteMonitor {
    param([string]$ScriptPath, [string]$PowerShellPath, [string]$OutputDirectory)

    # Native ArgumentList is joined into one string; quote the path explicitly.
    $arguments = '-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
    if($OutputDirectory){
        $quotedDirectory=$OutputDirectory -replace '(\\+)$', '$1$1'
        $arguments += ' -OutputDirectory "{0}"' -f $quotedDirectory
    }
    # The launcher is already elevated; the new visible PowerShell inherits its token.
    Start-Process -FilePath $PowerShellPath -ArgumentList $arguments -WindowStyle Normal -ErrorAction Stop | Out-Null
}

$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powerShellPath)) { throw 'Windows PowerShell не найден.' }
if(-not $ReportDirectory){
    if($env:SCRIPTONITE_SOURCE -and (Test-Path -LiteralPath $env:SCRIPTONITE_SOURCE)){
        $ReportDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($env:SCRIPTONITE_SOURCE))
    }elseif($PSScriptRoot -and $PSScriptRoot -notlike '*\Scriptonite\launcher\*'){
        $ReportDirectory=$PSScriptRoot
    }else{$ReportDirectory=[Environment]::GetFolderPath('Desktop')}
}
$ReportDirectory=[IO.Path]::GetFullPath($ReportDirectory)

Show-ScriptoniteHeader
if (-not (Test-ScriptoniteAdministrator)) {
    Write-Host 'Запрашиваю права администратора...' -ForegroundColor Cyan
    if (-not $PSCommandPath) {
        Write-Host 'Сохраните Scriptonite.ps1 в файл и запустите его снова.' -ForegroundColor Yellow
        $null = Read-Host 'Нажмите Enter для выхода'
        return
    }
    if (-not (Start-ScriptoniteElevated -ScriptPath $PSCommandPath -PowerShellPath $powerShellPath -ReportDirectory $ReportDirectory)) {
        $null = Read-Host 'Нажмите Enter для выхода'
    }
    return
}

$catalog = [ordered]@{
    '1' = @{ Name = 'Монитор сети'; Uri = [uri]'https://raw.githubusercontent.com/YaDevTest/Scriptonite/main/network-monitor.ps1'; Report=$true }
    '2' = @{ Name = 'Монитор USB'; Uri = [uri]'https://raw.githubusercontent.com/YaDevTest/Scriptonite/main/usb-monitor.ps1'; Report=$true }
    '3' = @{ Name = 'Монитор принтеров'; Uri = [uri]'https://raw.githubusercontent.com/YaDevTest/Scriptonite/main/printer-monitor.ps1'; Report=$true }
    '4' = @{ Name = 'Сниффер принтера (USB / LAN)'; Uri = [uri]'https://raw.githubusercontent.com/YaDevTest/Scriptonite/main/printer-sniffer.ps1'; Report=$true }
    '5' = @{ Name = 'Сниффер всей системы печати'; Uri = [uri]'https://raw.githubusercontent.com/YaDevTest/Scriptonite/main/print-system-sniffer.ps1'; Report=$true }
}
$cacheDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Scriptonite\scripts'
$status = ''

while ($true) {
    Show-ScriptoniteHeader
    foreach ($number in $catalog.Keys) {
        Write-Host "[$number] $($catalog[$number].Name)" -ForegroundColor White
    }
    Write-Host '[0] Выход' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Монитор открывается в отдельном PowerShell от администратора.' -ForegroundColor DarkGray
    if ($status) { Write-Host $status -ForegroundColor Cyan }
    Write-Host ''
    $choice = ([string](Read-Host 'Выберите скрипт')).Trim()
    if ($choice -eq '0') { return }
    if (-not $catalog.Contains($choice)) {
        $status = 'Введите 1 — сеть, 2 — USB, 3 — принтеры, 4 — сниффер принтера, 5 — вся система печати или 0 — выход.'
        continue
    }
    $selected = $catalog[$choice]
    try {
        Write-Host "Скачиваю с GitHub: $($selected.Name)..." -ForegroundColor Cyan
        $monitorPath = Save-ScriptoniteDownload -Uri $selected.Uri -CacheDirectory $cacheDirectory
        Write-Host 'Скачивание завершено. Запускаю скрипт; подготовка данных будет показана в новом окне...' -ForegroundColor Cyan
        if($selected.Report){Start-ScriptoniteMonitor -ScriptPath $monitorPath -PowerShellPath $powerShellPath -OutputDirectory $ReportDirectory}
        else{Start-ScriptoniteMonitor -ScriptPath $monitorPath -PowerShellPath $powerShellPath}
        $status = "$($selected.Name) запущен в отдельном окне. Меню готово к работе."
    } catch { Write-ScriptoniteError -Context 'Scriptonite.ps1 / Main / catch at line 241' -ErrorRecord $_; 
        Write-Host "Не удалось запустить $($selected.Name): $($_.Exception.Message)" -ForegroundColor Red
        $status = "Скрипт не запущен. Можно повторить выбор [$choice]."
        $null = Read-Host 'Нажмите Enter для возврата в меню'
    }
}
