[CmdletBinding()]
param([string]$OutputDirectory, [ValidateRange(1,4096)][int]$MaxMegabytes=256)
$ErrorActionPreference='Stop'
if(-not $OutputDirectory){$OutputDirectory=if($PSScriptRoot){$PSScriptRoot}else{(Get-Location).Path}}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
try{$admin=(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
if(-not $admin){
    $command="& '$($PSCommandPath.Replace("'","''"))' -OutputDirectory '$($OutputDirectory.Replace("'","''"))' -MaxMegabytes $MaxMegabytes"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    try{Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -ErrorAction Stop | Out-Null}
    catch{Write-Host 'Нужны права администратора. Запись не запущена.' -ForegroundColor Yellow; $null=Read-Host 'Enter — выход'}
    return
}
if([Console]::IsInputRedirected){throw 'Запустите скрипт в обычном PowerShell или Windows Terminal.'}
Write-Host 'Загрузка: подготовка общего журнала системы печати...' -ForegroundColor Cyan
$null=New-Item -ItemType Directory -Path $OutputDirectory -Force
$path=Join-Path $OutputDirectory ('PrintSystem_{0}_{1}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'),[guid]::NewGuid().ToString('N').Substring(0,6))
$writer=New-Object IO.StreamWriter($path,$false,(New-Object Text.UTF8Encoding($true)))
$writer.AutoFlush=$true
$messages=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$cancel=New-Object Threading.CancellationTokenSource
$shared=New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,object]'
$started=Get-Date
$operationalConfig=$null;$restoreOperational=$false
try{
 $operationalConfig=New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration('Microsoft-Windows-PrintService/Operational')
 if(-not $operationalConfig.IsEnabled){
  $operationalConfig.IsEnabled=$true;$operationalConfig.SaveChanges();$restoreOperational=$true
  $messages.Enqueue([pscustomobject]@{Time=Get-Date;Kind='ЖУРНАЛ';Text='Журнал PrintService/Operational включён на время записи.';Color='Cyan'})
 }
}catch{$messages.Enqueue([pscustomobject]@{Time=Get-Date;Kind='ОШИБКА';Text=('Не удалось включить журнал PrintService/Operational: '+$_.Exception.Message);Color='Red'})}
$worker=@'
param($Messages,$Cancel,$Shared,$Started)
$ErrorActionPreference='Stop'
function Send($kind,$text,$color='Yellow'){$Messages.Enqueue([pscustomobject]@{Time=Get-Date;Kind=$kind;Text=$text;Color=$color})}
function Collect($name,$items,$properties,$previous,$baseline){
    $next=@{}
    foreach($item in $items){
        $key=[string]$item.Name
        if($name -eq 'Драйвер'){$key+=' | '+[string]$item.PrinterEnvironment}
        if(!$key){continue}
        $value=[ordered]@{}
        foreach($property in $properties){$value[$property]=[string]$item.$property}
        $json=ConvertTo-Json -InputObject $value -Compress
        $next[$key]=$json
        if(!$baseline){
            if(!$previous.ContainsKey($key)){Send 'ДОБАВЛЕНО' "$name [$key] $json" Green}
            elseif($previous[$key] -cne $json){Send 'ИЗМЕНЕНО' "$name [$key] БЫЛО: $($previous[$key]) СТАЛО: $json" Yellow}
        }
    }
    if(!$baseline){foreach($key in @($previous.Keys)){if(!$next.ContainsKey($key)){Send 'УДАЛЕНО' "$name [$key] $($previous[$key])" Red}}}
    return ,$next
}
$oldPrinters=@{};$oldPorts=@{};$oldDrivers=@{};$oldJobs=@{};$errors=@{};$initial=$true;$baselines=@{};$lastSpooler=''
while(!$Cancel.IsCancellationRequested){
 $Shared['Stage']='Состояние службы Spooler'
 try{
  $service=Get-Service Spooler -ErrorAction Stop
  $spooler=[string]$service.Status
  if($lastSpooler -and $lastSpooler -ne $spooler){Send 'SPOOLER' "$lastSpooler -> $spooler" Yellow}
  $lastSpooler=$spooler
 }catch{$spooler='Unknown';if(!$errors.ContainsKey('spooler')){Send 'ОШИБКА' ('Spooler: '+$_.Exception.Message) Red;$errors['spooler']=$true}}
 if($spooler -ne 'Unknown'){$errors.Remove('spooler')}
 if($spooler -eq 'Running'){
  $Shared['Stage']='Получаю список принтеров'
  try{
   $printers=@(Get-Printer -ErrorAction Stop | Sort-Object Name)
   $oldPrinters=Collect 'Принтер' $printers @('DriverName','PortName','PrinterStatus','Shared','ShareName') $oldPrinters (!$baselines.ContainsKey('Printers'))
   $errors.Remove('printers')
   $Shared['Printers']=($oldPrinters|ConvertTo-Json -Compress -Depth 4)
   if(!$baselines.ContainsKey('Printers')){$Shared['BaselinePrinters']=$Shared['Printers'];$baselines['Printers']=$true}
   foreach($printer in $printers){
    if($Cancel.IsCancellationRequested){break}
    $Shared['Stage']='Очередь: '+$printer.Name
    try{
     $currentJobs=@{}
     foreach($job in @(Get-PrintJob -PrinterName $printer.Name -ErrorAction Stop)){
      $key=$printer.Name+'|'+$job.ID+'|'+$job.SubmittedTime
      $record=[ordered]@{Printer=$printer.Name;ID=$job.ID;Document=$job.DocumentName;Size=$job.Size;Status=[string]$job.JobStatus;Submitted=[string]$job.SubmittedTime}|ConvertTo-Json -Compress
      $currentJobs[$key]=$record
      $jobError=([uint32]$job.JobStatus -band (2 -bor 32 -bor 64 -bor 512 -bor 1024)) -ne 0
      $color=if($jobError){'Red'}else{'Cyan'}
      $previousJobs=if($oldJobs.ContainsKey($printer.Name)){$oldJobs[$printer.Name]}else{@{}}
      if(!$previousJobs.ContainsKey($key)){Send $(if($initial){'ЗАДАНИЕ УЖЕ В ОЧЕРЕДИ'}else{'НОВОЕ ЗАДАНИЕ'}) $record $color}
      elseif($previousJobs[$key] -cne $record){Send 'СТАТУС ЗАДАНИЯ' $record $(if($jobError){'Red'}else{'Yellow'})}
     }
     if($oldJobs.ContainsKey($printer.Name)){foreach($key in @($oldJobs[$printer.Name].Keys)){if(!$currentJobs.ContainsKey($key)){Send 'ЗАДАНИЕ ПОКИНУЛО ОЧЕРЕДЬ' ($oldJobs[$printer.Name][$key]+' | Итог не подтверждён.') Yellow}}}
     $oldJobs[$printer.Name]=$currentJobs
     if($errors.ContainsKey('jobs:'+ $printer.Name)){$errors.Remove('jobs:'+ $printer.Name);Send 'ОЧЕРЕДЬ' "Чтение восстановлено: $($printer.Name)" Green}
    }catch{$errorKey='jobs:'+ $printer.Name;if(!$errors.ContainsKey($errorKey)){Send 'ОШИБКА' "Очередь [$($printer.Name)]: $($_.Exception.Message)" Red;$errors[$errorKey]=$true}}
   }
   foreach($name in @($oldJobs.Keys)){if($name -notin @($printers.Name)){$oldJobs.Remove($name)}}
  }catch{if(!$errors.ContainsKey('printers')){Send 'ОШИБКА' ('Список принтеров: '+$_.Exception.Message) Red;$errors['printers']=$true}}
  $Shared['Stage']='Получаю порты печати'
  try{$oldPorts=Collect 'Порт' @(Get-PrinterPort -ErrorAction Stop | Sort-Object Name) @('Description','PrinterHostAddress','PortNumber','Protocol') $oldPorts (!$baselines.ContainsKey('Ports'));$Shared['Ports']=($oldPorts|ConvertTo-Json -Compress -Depth 4);if(!$baselines.ContainsKey('Ports')){$Shared['BaselinePorts']=$Shared['Ports'];$baselines['Ports']=$true};$errors.Remove('ports')}
  catch{if(!$errors.ContainsKey('ports')){Send 'ОШИБКА' ('Порты: '+$_.Exception.Message) Red;$errors['ports']=$true}}
  $Shared['Stage']='Получаю драйверы печати'
  try{$oldDrivers=Collect 'Драйвер' @(Get-PrinterDriver -ErrorAction Stop | Sort-Object Name) @('Manufacturer','DriverVersion','InfPath','DriverPath','PrinterEnvironment') $oldDrivers (!$baselines.ContainsKey('Drivers'));$Shared['Drivers']=($oldDrivers|ConvertTo-Json -Compress -Depth 4);if(!$baselines.ContainsKey('Drivers')){$Shared['BaselineDrivers']=$Shared['Drivers'];$baselines['Drivers']=$true};$errors.Remove('drivers')}
  catch{if(!$errors.ContainsKey('drivers')){Send 'ОШИБКА' ('Драйверы: '+$_.Exception.Message) Red;$errors['drivers']=$true}}
 }
 if($initial -and $baselines.Count -eq 3){$Shared['BaselineReady']=$true;Send 'НАЧАЛО' 'Исходная проверка завершена. Можно начинать действия с принтерами.' Green;$initial=$false}
 $Shared['Stage']='Ожидание изменений'
 $null=$Cancel.Token.WaitHandle.WaitOne(700)
}
'@

$eventWorker=@'
param($Messages,$Cancel,$Started)
$ErrorActionPreference='Stop'
$logs=@('Microsoft-Windows-PrintService/Admin','Microsoft-Windows-PrintService/Operational','System')
$cursors=@{};$errors=@{};$enabled=@{}
function Send($kind,$text,$color='Cyan'){$Messages.Enqueue([pscustomobject]@{Time=Get-Date;Kind=$kind;Text=$text;Color=$color})}
foreach($log in $logs){
 try{$enabled[$log]=[bool](Get-WinEvent -ListLog $log -ErrorAction Stop).IsEnabled;if(!$enabled[$log]){Send 'ЖУРНАЛ' "$log отключён; сведения из него недоступны." Yellow}}
 catch{$enabled[$log]=$false;Send 'ОШИБКА' "$log : $($_.Exception.Message)" Red}
}
while(!$Cancel.IsCancellationRequested){
 foreach($log in $logs){
  if(!$enabled[$log] -or $Cancel.IsCancellationRequested){continue}
  try{
   if($cursors.ContainsKey($log)){
    $xpath="*[System[EventRecordID > $($cursors[$log])"
    if($log -eq 'System'){$xpath+=" and Provider[@Name='Service Control Manager']"}
    $xpath+=']]'
    $events=@(Get-WinEvent -LogName $log -FilterXPath $xpath -Oldest -MaxEvents 500 -ErrorAction Stop)
   }else{
    $filter=@{LogName=$log;StartTime=$Started}
    if($log -eq 'System'){$filter.ProviderName='Service Control Manager'}
    $events=@(Get-WinEvent -FilterHashtable $filter -Oldest -MaxEvents 500 -ErrorAction Stop)
   }
   foreach($event in $events){
    $cursors[$log]=[long]$event.RecordId
    $text=([string]$event.Message) -replace '[\r\n]+',' '
    if($log -eq 'System' -and $text -notmatch 'spooler|spoolsv|диспетчер печати'){continue}
    if(!$text){$text='Описание недоступно'}
    $color=if($event.Level -in @(1,2)){'Red'}else{'Cyan'}
    Send 'СОБЫТИЕ WINDOWS' "$($event.TimeCreated.ToString('o')) | $log | ID=$($event.Id) | $text" $color
   }
   $errors.Remove($log)
  }catch{
   if($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*' -and !$errors.ContainsKey($log)){Send 'ОШИБКА' "$log : $($_.Exception.Message)" Red;$errors[$log]=$true}
  }
 }
 $null=$Cancel.Token.WaitHandle.WaitOne(500)
}
'@
function Stop-PrintBackground($PowerShell,$Runspace,$Async){
 if(!$Async){return $true}
 $done=$Async.AsyncWaitHandle.WaitOne(1500)
 if(!$done){try{$stop=$PowerShell.BeginStop($null,$null);$null=$stop.AsyncWaitHandle.WaitOne(500)}catch{}}
 if(!$Async.IsCompleted){return $false}
 try{$null=$PowerShell.EndInvoke($Async)}catch{}
 $PowerShell.Dispose();$Runspace.Dispose()
 return $true
}
$eventRunspace=$null;$eventPowerShell=$null;$eventAsync=$null;$workersStopped=$false

try{
 $runspace=[RunspaceFactory]::CreateRunspace();$runspace.Open()
 $powershell=[PowerShell]::Create();$powershell.Runspace=$runspace
 $null=$powershell.AddScript($worker).AddArgument($messages).AddArgument($cancel).AddArgument($shared).AddArgument($started)
 $async=$powershell.BeginInvoke()
 $eventRunspace=[RunspaceFactory]::CreateRunspace();$eventRunspace.Open()
 $eventPowerShell=[PowerShell]::Create();$eventPowerShell.Runspace=$eventRunspace
 $null=$eventPowerShell.AddScript($eventWorker).AddArgument($messages).AddArgument($cancel).AddArgument($started)
 $eventAsync=$eventPowerShell.BeginInvoke()
}catch{
 $cancel.Cancel()
 if($async){$null=Stop-PrintBackground $powershell $runspace $async}
 if($eventAsync){$null=Stop-PrintBackground $eventPowerShell $eventRunspace $eventAsync}
 if($restoreOperational){try{$operationalConfig.IsEnabled=$false;$operationalConfig.SaveChanges()}catch{}}
 if($operationalConfig){$operationalConfig.Dispose()};$writer.Dispose();$cancel.Dispose()
 throw
}
$reason='Остановлено пользователем';$readyShown=$false;$lastStage='';$completed=$false
try{
 $writer.WriteLine('SCRIPTONITE — ОБЩИЙ ЖУРНАЛ СИСТЕМЫ ПЕЧАТИ')
 $writer.WriteLine('Начало UTC: '+$started.ToUniversalTime().ToString('o'))
 $writer.WriteLine('События Windows и опрос очередей. Быстрые задания могут быть пропущены; завершение Windows не доказывает выход бумаги. USB и сетевые пакеты напрямую не захватываются.')
 Write-Host "TXT: $path" -ForegroundColor Cyan
 Write-Host 'Загрузка: собираю исходное состояние; текущий этап показан ниже.' -ForegroundColor Yellow
 Write-Host '[1] Удаление принтеров  [2] Смена порта  [3] Оживление  [4] Переустановка драйвера' -ForegroundColor Cyan
 Write-Host 'Клавиши 1–4 только записывают отметку в журнал. [0] / Esc — остановить.' -ForegroundColor Yellow
 while($true){
  $message=$null;$batch=0
  while($batch -lt 200 -and $messages.TryDequeue([ref]$message)){
   $line='{0} [{1}] {2}' -f $message.Time.ToUniversalTime().ToString('o'),$message.Kind,$message.Text
   $writer.WriteLine($line);Write-Host $line -ForegroundColor $message.Color;$batch++;$message=$null
  }
  if(!$readyShown -and $shared.ContainsKey('Stage') -and $shared['Stage'] -ne $lastStage){$lastStage=[string]$shared['Stage'];Write-Progress -Id 33 -Activity 'Загрузка системы печати' -Status $lastStage -PercentComplete -1}
  if(!$readyShown -and $shared.ContainsKey('BaselineReady')){
   Write-Progress -Id 33 -Activity 'Загрузка системы печати' -Completed
   foreach($category in @('Printers','Ports','Drivers')){if($shared.ContainsKey('Baseline'+$category)){$writer.WriteLine("ИСХОДНОЕ СОСТОЯНИЕ [$category]: $($shared['Baseline'+$category])")}}
   Write-Host 'ЗАПИСЬ ИДЁТ. Можно начинать изменения.' -ForegroundColor Green;$readyShown=$true
  }
  if($eventAsync.IsCompleted){$reason='Чтение событий Windows остановилось: '+$eventPowerShell.InvocationStateInfo.Reason;break}
  if($async.IsCompleted){$reason='Наблюдатель остановился';if($powershell.InvocationStateInfo.Reason){$reason+=': '+$powershell.InvocationStateInfo.Reason.Message};break}
  if($writer.BaseStream.Length -ge ([int64]$MaxMegabytes*1MB)){$reason='Достигнут лимит размера TXT';break}
  if([Console]::KeyAvailable){
   $key=[Console]::ReadKey($true)
   if($key.Key -in @('D0','NumPad0','Escape')){break}
   $stage=switch($key.KeyChar){'1'{'Удаление принтеров'}'2'{'Смена порта'}'3'{'Оживление принтера'}'4'{'Переустановка драйвера'}default{''}}
   if($stage){$line="$([DateTime]::UtcNow.ToString('o')) [ОТМЕТКА] $stage";$writer.WriteLine($line);Write-Host $line -ForegroundColor Magenta}
  }
  Start-Sleep -Milliseconds 100
 }
 $cancel.Cancel()
 $inventoryDone=Stop-PrintBackground $powershell $runspace $async
 $eventsDone=Stop-PrintBackground $eventPowerShell $eventRunspace $eventAsync
 $workersStopped=$true
 $done=$inventoryDone -and $eventsDone
 if(!$done){$writer.WriteLine('ВНИМАНИЕ: запрос Windows не завершился вовремя, данные могут быть неполными.')}
 $message=$null;while($messages.TryDequeue([ref]$message)){$writer.WriteLine(('{0} [{1}] {2}' -f $message.Time.ToUniversalTime().ToString('o'),$message.Kind,$message.Text));$message=$null}
 foreach($category in @('Printers','Ports','Drivers')){if($shared.ContainsKey($category)){$writer.WriteLine("ПОСЛЕДНЕЕ СОСТОЯНИЕ [$category]: $($shared[$category])")}}
 $writer.WriteLine("Конец UTC: $([DateTime]::UtcNow.ToString('o')) | $reason")
 $completed=$true
}finally{
 Write-Progress -Id 33 -Activity 'Загрузка системы печати' -Completed
 if(!$cancel.IsCancellationRequested){$cancel.Cancel()}
 if(!$workersStopped){
  $inventoryDone=Stop-PrintBackground $powershell $runspace $async
  $eventsDone=Stop-PrintBackground $eventPowerShell $eventRunspace $eventAsync
  $workersStopped=$true
 }
 if(!$completed){$writer.WriteLine('ОТЧЁТ НЕПОЛНЫЙ: запись прервана.')}
 if($restoreOperational){
  try{$operationalConfig.IsEnabled=$false;$operationalConfig.SaveChanges();$writer.WriteLine('Журнал PrintService/Operational возвращён в исходное выключенное состояние.')}
  catch{$writer.WriteLine('Не удалось восстановить исходное состояние журнала PrintService/Operational: '+$_.Exception.Message);Write-Host 'Не удалось восстановить исходное состояние журнала печати Windows.' -ForegroundColor Yellow}
 }
 if($operationalConfig){$operationalConfig.Dispose()}
 $writer.Dispose()
 if($inventoryDone -and $eventsDone){$cancel.Dispose()}
}
Write-Host "Запись остановлена: $reason" -ForegroundColor Cyan
Write-Host "TXT: $path" -ForegroundColor Green
$null=Read-Host 'Enter — выход'
