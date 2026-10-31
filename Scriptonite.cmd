@echo off
setlocal
title Scriptonite
set "SCRIPTONITE_SOURCE=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $text=[IO.File]::ReadAllText($env:SCRIPTONITE_SOURCE,[Text.Encoding]::UTF8); $marker='#==SCRIPTONITE_PS1==#'; $offset=$text.LastIndexOf($marker); if ($offset -lt 0) { throw 'Embedded script was not found.' }; $payload=$text.Substring($offset+$marker.Length); $root=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Scriptonite\launcher'; $run=Join-Path $root ([Guid]::NewGuid().ToString('N')); $null=New-Item -ItemType Directory -Path $run -Force; $entry=Join-Path $run 'Scriptonite.ps1'; [IO.File]::WriteAllText($entry,$payload,(New-Object Text.UTF8Encoding($true))); & $entry } catch { Write-Host ('Scriptonite: '+$_.Exception.Message) -ForegroundColor Red; exit 1 }"
if errorlevel 1 (
    echo Scriptonite could not start.
    pause
)
exit /b
#==SCRIPTONITE_PS1==#
[CmdletBinding()]
param()

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
    param([string]$ScriptPath, [string]$PowerShellPath)

    # EncodedCommand safely carries paths containing spaces or apostrophes.
    $escapedPath = $ScriptPath.Replace("'", "''")
    $command = "& '$escapedPath'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    try {
        Start-Process -FilePath $PowerShellPath -Verb RunAs -WindowStyle Normal -ErrorAction Stop -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
        ) | Out-Null
        return $true
    } catch {
        Write-Host ''
        Write-Host 'Scriptonite нужны права администратора.' -ForegroundColor Yellow
        Write-Host 'Разрешение не получено. Скрипты не запущены.' -ForegroundColor Yellow
        Write-Host "Причина: $($_.Exception.Message)" -ForegroundColor DarkGray
        return $false
    }
}

function Save-ScriptoniteDownload {
    param(
        [Parameter(Mandatory = $true)][uri]$Uri,
        [Parameter(Mandatory = $true)][string]$CacheDirectory
    )

    if ($Uri.Scheme -ne 'https') { throw 'Для скачивания требуется HTTPS-ссылка.' }

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $response = $null
    $oldProtocols = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocols -bor [Net.SecurityProtocolType]::Tls12
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('Scriptonite/1.0')
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Скачивание не удалось: HTTP $([int]$response.StatusCode) ($($response.ReasonPhrase))."
        }
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        return Save-ScriptoniteScriptBytes -Bytes $bytes -CacheDirectory $CacheDirectory
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocols
        if ($response) { $response.Dispose() }
        $client.Dispose()
    }
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
    $filename = 'network-monitor-{0}.ps1' -f [Guid]::NewGuid().ToString('N')
    $target = Join-Path $CacheDirectory $filename
    [IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding($true)))
    return $target
}

function Start-ScriptoniteMonitor {
    param([string]$ScriptPath, [string]$PowerShellPath)

    # Native ArgumentList is joined into one string; quote the path explicitly.
    $arguments = '-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
    # The launcher is already elevated; the new visible PowerShell inherits its token.
    Start-Process -FilePath $PowerShellPath -ArgumentList $arguments -WindowStyle Normal -ErrorAction Stop | Out-Null
}

$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powerShellPath)) { throw 'Windows PowerShell не найден.' }

Show-ScriptoniteHeader
if (-not (Test-ScriptoniteAdministrator)) {
    Write-Host 'Запрашиваю права администратора...' -ForegroundColor Cyan
    if (-not $PSCommandPath) {
        Write-Host 'Сохраните Scriptonite.ps1 в файл и запустите его снова.' -ForegroundColor Yellow
        $null = Read-Host 'Нажмите Enter для выхода'
        return
    }
    if (-not (Start-ScriptoniteElevated -ScriptPath $PSCommandPath -PowerShellPath $powerShellPath)) {
        $null = Read-Host 'Нажмите Enter для выхода'
    }
    return
}

$monitorUrl = [uri]'https://raw.githubusercontent.com/YaDevTest/Scriptonite/main/network-monitor.ps1'
$cacheDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Scriptonite\scripts'
$status = ''

while ($true) {
    Show-ScriptoniteHeader
    Write-Host '[1] Монитор сети' -ForegroundColor White
    Write-Host '[0] Выход' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Монитор открывается в отдельном PowerShell от администратора.' -ForegroundColor DarkGray
    if ($status) { Write-Host $status -ForegroundColor Cyan }
    Write-Host ''
    $choice = Read-Host 'Выберите скрипт'
    switch ($choice.Trim()) {
        '0' { return }
        '1' {
            try {
                Write-Host 'Скачиваю актуальный монитор с GitHub...' -ForegroundColor Cyan
                $monitorPath = Save-ScriptoniteDownload -Uri $monitorUrl -CacheDirectory $cacheDirectory
                Start-ScriptoniteMonitor -ScriptPath $monitorPath -PowerShellPath $powerShellPath
                $status = 'Монитор запущен в отдельном окне. Меню готово к работе.'
            } catch {
                Write-Host "Не удалось запустить монитор: $($_.Exception.Message)" -ForegroundColor Red
                $status = 'Монитор не запущен. Можно повторить выбор [1].'
                $null = Read-Host 'Нажмите Enter для возврата в меню'
            }
        }
        default { $status = 'Введите 1 для запуска монитора или 0 для выхода.' }
    }
}
