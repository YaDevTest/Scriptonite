# Bootstrap for: irm https://raw.githubusercontent.com/YaDevTest/Scriptonite/main/start.ps1 | iex
# Keep the launcher in a real file: its self-elevation uses $PSCommandPath.
& {
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
    } catch {
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
    $ErrorActionPreference = 'Stop'
    $previousProtocols = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocols -bor [Net.SecurityProtocolType]::Tls12
        $launcherUrl = 'https://raw.githubusercontent.com/YaDevTest/Scriptonite/main/Scriptonite.ps1'
        $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Scriptonite\launcher'
        $directory = Join-Path $root ([Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory -Force
        $file = Join-Path $directory 'Scriptonite.ps1'
        $bytes=Get-ScriptoniteDownloadBytes -Uri $launcherUrl -Activity 'Scriptonite: download launcher'
        [IO.File]::WriteAllBytes($file,$bytes)
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
