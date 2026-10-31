# Bootstrap for: irm https://raw.githubusercontent.com/YaDevTest/Scriptonite/main/start.ps1 | iex
# Keep the launcher in a real file: its self-elevation uses $PSCommandPath.
& {
    $ErrorActionPreference = 'Stop'
    $previousProtocols = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocols -bor [Net.SecurityProtocolType]::Tls12
        $launcherUrl = 'https://raw.githubusercontent.com/YaDevTest/Scriptonite/main/Scriptonite.ps1'
        $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Scriptonite\launcher'
        $directory = Join-Path $root ([Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory -Force
        $file = Join-Path $directory 'Scriptonite.ps1'
        Invoke-WebRequest -Uri $launcherUrl -UseBasicParsing -TimeoutSec 30 -OutFile $file
        $text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
        if (-not $text.Trim() -or $text.TrimStart() -match '^(?i:<!DOCTYPE\s+html|<html\b)') {
            throw 'Expected Scriptonite.ps1, received an empty file or HTML page.'
        }
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Downloaded Scriptonite.ps1 has a syntax error: $($parseErrors[0].Message)" }
        # Always preserve Cyrillic text when running in Windows PowerShell 5.1.
        [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($true)))
        $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $powerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $file
        if ($LASTEXITCODE -ne 0) { throw "PowerShell exited with code $LASTEXITCODE." }
    } catch {
        Write-Host "Could not start Scriptonite: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocols
    }
}
