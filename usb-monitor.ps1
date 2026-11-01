[CmdletBinding()]
param(
    [ValidateRange(1, 3600)][int]$IntervalSeconds = 30,
    [switch]$ShowEmpty,
    [switch]$Once,
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
    Script='usb-monitor';Path='';Failed=$false;Recent=@{};SyncRoot=(New-Object object)
    Directories=@($errorDirectory,[Environment]::GetFolderPath('Desktop') | Where-Object {$_} | Select-Object -Unique)
    Name=('ScriptoniteErrors_usb-monitor_{0}_{1}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'),[guid]::NewGuid().ToString('N').Substring(0,6))
}
trap { Write-ScriptoniteError -Context 'Unhandled script error' -ErrorRecord $_; break }
# END SCRIPTONITE ERROR LOGGING

$ErrorActionPreference = 'Stop'
# Read-only USB hub IOCTLs documented in usbioctl.h (Windows 8+).
# Connector metadata, not device class or CM_DEVCAP_REMOVABLE, decides whether
# a port is externally accessible. One physical connector may have companions.
$nativeSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ScriptonitePhysicalUsb {
    public class Port {
        public string Key, Hub, DriverKey = "", Device = "", InstanceId = "", Functions = "", DeviceType = "USB";
        public string ChildHub = "";
        public int Index, Status = -1, Vid, Pid;
        public bool ConnectorKnown, UserConnectable, TypeC;
        public List<string> Companions = new List<string>();
    }
    public class ScanResult {
        public List<Port> Ports = new List<Port>();
        public List<string> Warnings = new List<string>();
    }
    class DeviceNode {
        public uint DevInst, Parent;
        public string Driver, Name, Id, Class;
    }
    public static class Reader {
        [StructLayout(LayoutKind.Sequential)] struct InterfaceData {
            public uint Size; public Guid ClassGuid; public uint Flags; public IntPtr Reserved;
        }
        [StructLayout(LayoutKind.Sequential)] struct DeviceData {
            public uint Size; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved;
        }
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr SetupDiGetClassDevs(ref Guid guid, string enumerator, IntPtr hwnd, uint flags);
        [DllImport("setupapi.dll", SetLastError=true)]
        static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr device, ref Guid guid, uint index, ref InterfaceData data);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref InterfaceData data, IntPtr detail, uint size, out uint required, ref DeviceData device);
        [DllImport("setupapi.dll", SetLastError=true)]
        static extern bool SetupDiEnumDeviceInfo(IntPtr set, uint index, ref DeviceData data);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool SetupDiGetDeviceRegistryProperty(IntPtr set, ref DeviceData data, uint property, out uint type, byte[] value, uint size, out uint required);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool SetupDiGetDeviceInstanceId(IntPtr set, ref DeviceData data, StringBuilder id, uint size, out uint required);
        [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DllImport("cfgmgr32.dll")] static extern uint CM_Get_Parent(out uint parent, uint devinst, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inSize, byte[] output, uint outSize, out uint returned, IntPtr overlapped);

        static uint Code(uint function) { return (0x22u << 16) | (function << 2); }
        static byte[] Buffer(int port, int size) {
            byte[] b = new byte[size]; Array.Copy(BitConverter.GetBytes(port), b, 4); return b;
        }
        static string Wide(byte[] b, int start) {
            if (b.Length <= start) return "";
            string s = Encoding.Unicode.GetString(b, start, (b.Length-start) & ~1);
            int end = s.IndexOf('\0'); return end < 0 ? s : s.Substring(0, end);
        }
        public static string Normalize(string path) {
            if (String.IsNullOrEmpty(path)) return "";
            if (path.StartsWith(@"\\?\") || path.StartsWith(@"\\.\") || path.StartsWith(@"\??\")) path = path.Substring(4);
            return path.ToUpperInvariant();
        }
        static bool Query(SafeFileHandle h, uint fn, byte[] b, uint inputSize, out uint returned) {
            return DeviceIoControl(h, Code(fn), b, inputSize, b, (uint)b.Length, out returned, IntPtr.Zero);
        }
        static string Property(IntPtr set, ref DeviceData d, uint key) {
            byte[] b = new byte[8192]; uint t, n;
            return SetupDiGetDeviceRegistryProperty(set, ref d, key, out t, b, (uint)b.Length, out n) ? Wide(b, 0) : "";
        }
        static string Instance(IntPtr set, ref DeviceData d) {
            StringBuilder b = new StringBuilder(4096); uint n;
            return SetupDiGetDeviceInstanceId(set, ref d, b, 4096, out n) ? b.ToString() : "";
        }
        static List<string> Hubs() {
            Guid guid = new Guid("f18a0e88-c30c-11d0-8815-00a0c906bed8");
            IntPtr set = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero, 0x12);
            if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
            List<string> hubs = new List<string>();
            try {
                for (uint i=0;;i++) {
                    InterfaceData inf = new InterfaceData(); inf.Size=(uint)Marshal.SizeOf(typeof(InterfaceData));
                    if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref inf)) {
                        int error=Marshal.GetLastWin32Error(); if (error == 259) break; throw new Win32Exception(error);
                    }
                    DeviceData d = new DeviceData(); d.Size=(uint)Marshal.SizeOf(typeof(DeviceData)); uint needed;
                    SetupDiGetDeviceInterfaceDetail(set, ref inf, IntPtr.Zero, 0, out needed, ref d);
                    if (needed < 6) throw new InvalidOperationException("USB hub interface size unavailable");
                    IntPtr buf=Marshal.AllocHGlobal((int)needed);
                    try {
                        Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                        if (!SetupDiGetDeviceInterfaceDetail(set, ref inf, buf, needed, out needed, ref d)) throw new Win32Exception(Marshal.GetLastWin32Error());
                        hubs.Add(Marshal.PtrToStringUni(IntPtr.Add(buf, 4)));
                    } finally { Marshal.FreeHGlobal(buf); }
                }
            } finally { SetupDiDestroyDeviceInfoList(set); }
            return hubs;
        }
        static List<DeviceNode> Devices() {
            Guid guid=Guid.Empty; IntPtr set=SetupDiGetClassDevs(ref guid, null, IntPtr.Zero, 6);
            if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
            List<DeviceNode> nodes=new List<DeviceNode>();
            try {
                for (uint i=0;;i++) {
                    DeviceData d=new DeviceData(); d.Size=(uint)Marshal.SizeOf(typeof(DeviceData));
                    if (!SetupDiEnumDeviceInfo(set, i, ref d)) {
                        int error=Marshal.GetLastWin32Error(); if (error == 259) break; throw new Win32Exception(error);
                    }
                    uint parent; CM_Get_Parent(out parent, d.DevInst, 0);
                    string name=Property(set,ref d,12); if (name.Length == 0) name=Property(set,ref d,0);
                    nodes.Add(new DeviceNode { DevInst=d.DevInst, Parent=parent, Driver=Property(set,ref d,9), Name=name, Id=Instance(set,ref d), Class=Property(set,ref d,7) });
                }
            } finally { SetupDiDestroyDeviceInfoList(set); }
            return nodes;
        }
        public static Port DecodeConnection(byte[] b) {
            // usbioctl.h uses #pragma pack(1): status offset is 31, not 32.
            if (b.Length < 35) throw new ArgumentException("USB connection buffer is too short");
            return new Port { Index=BitConverter.ToInt32(b,0), Status=BitConverter.ToInt32(b,31), Vid=BitConverter.ToUInt16(b,12), Pid=BitConverter.ToUInt16(b,14) };
        }
        public static Port DecodeConnector(byte[] b) {
            if (b.Length < 18) throw new ArgumentException("USB connector buffer is too short");
            uint flags=BitConverter.ToUInt32(b,8);
            Port p=new Port { Index=BitConverter.ToInt32(b,0), ConnectorKnown=true, UserConnectable=(flags & 1)!=0, TypeC=(flags & 8)!=0 };
            int companion=BitConverter.ToUInt16(b,14); string hub=Wide(b,16);
            if (companion>0 && hub.Length>0) p.Companions.Add(Normalize(hub)+"|"+companion);
            return p;
        }
        static string PortString(SafeFileHandle h, uint fn, int index) {
            byte[] b=Buffer(index,8192); uint n;
            return Query(h,fn,b,12,out n) && n>=10 ? Wide(b,8) : "";
        }
        public static ScanResult Scan() {
            ScanResult result=new ScanResult();
            foreach (string hubPath in Hubs()) {
                using (SafeFileHandle h=CreateFile(hubPath,0xC0000000,3,IntPtr.Zero,3,0,IntPtr.Zero)) {
                    if (h.IsInvalid) { result.Warnings.Add("USB hub access error: "+Marshal.GetLastWin32Error()); continue; }
                    byte[] info=new byte[256]; uint returned; int count;
                    if (Query(h,277,info,(uint)info.Length,out returned) && returned>=6) count=BitConverter.ToUInt16(info,4);
                    else {
                        info=new byte[76];
                        if (!Query(h,258,info,76,out returned) || returned<7) { result.Warnings.Add("USB hub port count unavailable"); continue; }
                        count=info[6];
                    }
                    if (count>255) { result.Warnings.Add("Invalid USB hub port count"); continue; }
                    string hub=Normalize(hubPath);
                    for (int index=1;index<=count;index++) {
                        Port p=new Port { Key=hub+"|"+index, Hub=hub, Index=index };
                        byte[] connector=Buffer(index,8192);
                        if (Query(h,278,connector,18,out returned) && returned>=18) {
                            Port decoded=DecodeConnector(connector);
                            p.ConnectorKnown=true; p.UserConnectable=decoded.UserConnectable; p.TypeC=decoded.TypeC;
                            p.Companions.AddRange(decoded.Companions);
                            if ((BitConverter.ToUInt32(connector,8)&4)!=0) {
                                for (ushort companionIndex=1;companionIndex<32;companionIndex++) {
                                    byte[] next=Buffer(index,8192); Array.Copy(BitConverter.GetBytes(companionIndex),0,next,12,2);
                                    if (!Query(h,278,next,18,out returned) || returned<18) break;
                                    Port extra=DecodeConnector(next); if (extra.Companions.Count==0 || p.Companions.Contains(extra.Companions[0])) break;
                                    p.Companions.AddRange(extra.Companions);
                                }
                            }
                        }
                        byte[] connection=Buffer(index,4096);
                        if (Query(h,274,connection,35,out returned) && returned>=35) {
                            Port decoded=DecodeConnection(connection); p.Status=decoded.Status; p.Vid=decoded.Vid; p.Pid=decoded.Pid;
                            if (p.Status!=0) {
                                p.DriverKey=PortString(h,264,index);
                                if (connection[24]!=0) p.ChildHub=Normalize(PortString(h,261,index));
                            }
                        } else if (p.UserConnectable) result.Warnings.Add("USB port connection status unavailable");
                        result.Ports.Add(p);
                    }
                }
            }
            List<DeviceNode> devices=Devices();
            Dictionary<string,DeviceNode> drivers=new Dictionary<string,DeviceNode>(StringComparer.OrdinalIgnoreCase);
            Dictionary<uint,DeviceNode> instances=new Dictionary<uint,DeviceNode>();
            foreach (DeviceNode d in devices) { if (d.Driver.Length>0) drivers[d.Driver]=d; instances[d.DevInst]=d; }
            foreach (Port p in result.Ports) {
                DeviceNode d;
                if (p.DriverKey.Length==0 || !drivers.TryGetValue(p.DriverKey,out d)) continue;
                p.Device=d.Name; p.InstanceId=d.Id;
                SortedSet<string> functions=new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
                HashSet<string> classes=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (DeviceNode child in devices) {
                    DeviceNode cursor=child; HashSet<uint> visited=new HashSet<uint>();
                    for (int depth=0;depth<32 && visited.Add(cursor.DevInst);depth++) {
                        if (cursor.DevInst==d.DevInst) { classes.Add(child.Class); if (child.Name.Length>0 && child.Class!="USB") functions.Add(child.Name); break; }
                        if (!instances.TryGetValue(cursor.Parent,out cursor)) break;
                    }
                }
                p.Functions=String.Join("; ",new List<string>(functions).ToArray());
                if (classes.Contains("XnaComposite") || p.Device.IndexOf("Xbox",StringComparison.OrdinalIgnoreCase)>=0) p.DeviceType="Gamepad";
                else if (classes.Contains("Mouse")) p.DeviceType="Mouse";
                else if (classes.Contains("Keyboard")) p.DeviceType="Keyboard";
                else if (classes.Contains("DiskDrive")) p.DeviceType="Storage";
                else if (classes.Contains("Ports")) p.DeviceType="COM";
            }
            return result;
        }
    }
}
'@

function Merge-UsbConnectors {
    param($Ports)
    $nodes = @{}
    $edges = @{}
    foreach ($port in $Ports) { $nodes[$port.Key] = $port; $edges[$port.Key] = New-Object 'System.Collections.Generic.List[string]' }
    foreach ($port in $Ports) {
        foreach ($key in $port.Companions) {
            if ($nodes.ContainsKey($key)) { $edges[$port.Key].Add($key); $edges[$key].Add($port.Key) }
        }
    }
    # A separately plugged-in hub belongs to the device connected to a PC socket.
    # Its downstream sockets must not inflate the count of sockets on the PC.
    $externalHubs = @{}
    foreach ($port in $Ports) { if ($port.ConnectorKnown -and $port.UserConnectable -and $port.ChildHub) { $externalHubs[$port.ChildHub] = $true } }
    do {
        $changed = $false
        foreach ($port in $Ports) {
            if ($externalHubs.ContainsKey($port.Hub) -and $port.ChildHub -and -not $externalHubs.ContainsKey($port.ChildHub)) {
                $externalHubs[$port.ChildHub] = $true; $changed = $true
            }
        }
    } while ($changed)
    $visited = @{}
    foreach ($start in ($nodes.Keys | Sort-Object)) {
        if ($visited.ContainsKey($start)) { continue }
        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        $queue.Enqueue($start)
        $members = @()
        while ($queue.Count) {
            $key = $queue.Dequeue()
            if ($visited.ContainsKey($key)) { continue }
            $visited[$key] = $true
            $members += $nodes[$key]
            foreach ($next in $edges[$key]) { if (-not $visited.ContainsKey($next)) { $queue.Enqueue($next) } }
        }
        if (-not @($members | Where-Object { $_.ConnectorKnown -and $_.UserConnectable -and -not $externalHubs.ContainsKey($_.Hub) }).Count) { continue }
        $active = @($members | Where-Object { $_.Status -gt 0 } | Sort-Object Key)
        $unknown = @($members | Where-Object { $_.Status -lt 0 }).Count -gt 0
        $selected = if ($active.Count) { $active[0] } else { $members[0] }
        $status = if ($active.Count) { $selected.Status } elseif ($unknown) { -1 } else { 0 }
        $name = $selected.Device
        if ($status -eq 0) { $name = 'Пусто' }
        elseif ($status -eq -1) { $name = 'Не удалось прочитать состояние' }
        elseif (-not $name) { $name = 'USB-устройство (название не определено)' }
        $vidPid = if ($selected.Vid -or $selected.Pid) { '{0:X4}:{1:X4}' -f $selected.Vid, $selected.Pid } else { '-' }
        [PSCustomObject]@{
            Key = ($members.Key | Sort-Object)[0]; Device = $name; Status = $status
            VidPid = $vidPid; InstanceId = $selected.InstanceId; Functions = $selected.Functions; DeviceType = $selected.DeviceType
            TypeC = @($members | Where-Object { $_.TypeC }).Count -gt 0
            Members = @($members.Key | Sort-Object); Signature = "$($selected.Vid):$($selected.Pid):$($selected.InstanceId)"
        }
    }
}

function ConvertTo-UsbInstanceId {
    param([string]$Value)
    $value=$Value.Trim().Trim([char]0)
    # USB Monitor can store either a PnP instance ID or a device-interface path.
    $value=$value -replace '^\\\\\?\\','' -replace '^\\\?\?\\',''
    $value=$value -replace '#\{[0-9A-Fa-f-]+\}.*$',''
    $value=$value.Replace('#','\')
    if($value -match '^(USBPRINT|USB)\\' -and $value -notmatch '^USB\\ROOT_HUB'){return $value}
    return ''
}

function Get-UsbPrinterBindings {
    param([object[]]$Connectors)
    # PnP CDXML cmdlets emit their own verbose progress records in Windows PS5.
    # Keep the scanner's single progress indicator; this preference is local.
    $ProgressPreference='SilentlyContinue'
    $warnings=New-Object 'System.Collections.Generic.List[string]'
    $names=@{};$queues=@{};$queueRead=$false
    $registryRoot='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Print\Monitors\USB Monitor\Ports'
    try{foreach($key in @(Get-ChildItem -LiteralPath $registryRoot -ErrorAction Stop)){if($key.PSChildName -match '^USB[0-9]+$'){$names[$key.PSChildName]=$true}}}
    catch{Write-ScriptoniteError -Context 'Перечисление привязок USB Monitor' -ErrorRecord $_;if($_.CategoryInfo.Category -ne 'ObjectNotFound'){$warnings.Add('Не удалось перечислить привязки USB Monitor: '+$_.Exception.Message)}}
    try{foreach($port in @(Get-PrinterPort -ErrorAction Stop)){if($port.Name -match '^USB[0-9]+$'){$names[$port.Name]=$true}}}
    catch{Write-ScriptoniteError -Context 'Список портов печати' -ErrorRecord $_;$warnings.Add('Не удалось прочитать список портов печати: '+$_.Exception.Message)}
    try{
        foreach($printer in @(Get-Printer -ErrorAction Stop)){
            foreach($portName in @($printer.PortName -split ',\s*')){
                if($portName -notmatch '^USB[0-9]+$'){continue}
                $names[$portName]=$true
                if(!$queues.ContainsKey($portName)){$queues[$portName]=New-Object 'System.Collections.Generic.List[string]'}
                $queues[$portName].Add([string]$printer.Name)
            }
        }
        $queueRead=$true
    }catch{Write-ScriptoniteError -Context 'Список очередей печати' -ErrorRecord $_;$warnings.Add('Не удалось прочитать очереди печати: '+$_.Exception.Message)}
    $byInstance=@{}
    foreach($connector in $Connectors){
        if($connector.InstanceId -and $connector.Status -gt 0){
            if(!$byInstance.ContainsKey($connector.InstanceId)){$byInstance[$connector.InstanceId]=New-Object 'System.Collections.Generic.List[object]'}
            $byInstance[$connector.InstanceId].Add($connector)
        }
    }
    $parentCache=@{};$propertyApi=[bool](Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($name in @($names.Keys | Sort-Object)){
        $deviceId='';$readError=''
        try{
            $data=Get-ItemProperty -LiteralPath ($registryRoot+'\'+$name) -ErrorAction Stop
            # Only device identity fields; Parent Device Id may name a root hub.
            foreach($field in @('Device Id','DeviceID','DeviceInstanceId','PnPDeviceID','Device Path')){
                $value=$data.PSObject.Properties[$field]
                if($value -and $value.Value -is [string]){$deviceId=ConvertTo-UsbInstanceId $value.Value;if($deviceId){break}}
            }
        }catch{Write-ScriptoniteError -Context ("USB Monitor: $name") -ErrorRecord $_;if($_.CategoryInfo.Category -ne 'ObjectNotFound'){$readError=$_.Exception.Message}}
        $chain=New-Object 'System.Collections.Generic.List[string]'
        $id=$deviceId;$match=$null;$vidPid='-';$viaHub=$false
        for($depth=0;$id -and $depth -lt 32;$depth++){
            if($chain.Contains($id)){break}
            if($id -match '^USB\\ROOT_HUB|^PCI\\|^HTREE\\'){break}
            $chain.Add($id)
            if($vidPid -eq '-' -and $id -match 'VID_([0-9A-F]{4}).*PID_([0-9A-F]{4})'){$vidPid=$Matches[1]+':'+$Matches[2]}
            if($byInstance.ContainsKey($id)){
                if($byInstance[$id].Count -eq 1){$match=$byInstance[$id][0];$viaHub=($chain.Count -gt 1 -and $match.Device -match 'hub|концентратор')}
                break
            }
            if(!$propertyApi){break}
            if(!$parentCache.ContainsKey($id)){
                $parent=''
                try{$prop=Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop | Where-Object InstanceId -eq $id | Select-Object -First 1;$parent=[string]$prop.Data}catch{Write-ScriptoniteError -Context ("PnP Parent: $name | $id") -ErrorRecord $_}
                $parentCache[$id]=$parent
            }
            $id=$parentCache[$id]
        }
        $physical='Не сопоставлен';$state='Текущий разъём не подтверждён';$device='-'
        if($match){
            $physical='USB '+$match.Number
            if($viaHub){$physical+=' (через хаб)'}
            $device=$match.Device
            $state=if($match.Status -eq 1){'Устройство подключено'}else{'Ошибка USB: '+$match.Status}
        }elseif(!$deviceId){$state=if($readError){'Привязка недоступна'}else{'Нет идентификатора в USB Monitor'}}
        $queue=if(!$queueRead){'Не удалось прочитать'}elseif($queues.ContainsKey($name)){($queues[$name] | Sort-Object) -join '; '}else{'Нет очередей'}
        $rows.Add([pscustomobject]@{LogicalPort=$name;Queues=$queue;PhysicalPort=$physical;Device=$device;VidPid=$vidPid;State=$state;DeviceId=$deviceId;PhysicalKey=$(if($match){$match.Key}else{''})})
        if($readError){$warnings.Add("$name : $readError")}
    }
    return [pscustomobject]@{Rows=$rows.ToArray();Warnings=$warnings.ToArray()}
}

function Get-UsbPortChanges {
    param([hashtable]$Previous, [hashtable]$Current)
    foreach ($key in $Current.Keys) {
        $now = $Current[$key]
        if (-not $Previous.ContainsKey($key)) { continue }
        $old = $Previous[$key]
        if ($old.Status -lt 0 -or $now.Status -lt 0) { continue }
        if ($old.Status -eq 0 -and $now.Status -gt 0) { "ПОДКЛЮЧЕНО: USB $($now.Number) — $($now.Device)" }
        elseif ($old.Status -gt 0 -and $now.Status -eq 0) { "ОТКЛЮЧЕНО: USB $($now.Number) — $($old.Device)" }
        elseif ($old.Status -gt 0 -and $now.Status -gt 0 -and ($old.VidPid -ne $now.VidPid -or ($old.InstanceId -and $now.InstanceId -and $old.InstanceId -ne $now.InstanceId))) { "ЗАМЕНЕНО: USB $($now.Number) — $($old.Device) -> $($now.Device)" }
        elseif ($old.Status -ne $now.Status) { "СОСТОЯНИЕ: USB $($now.Number) — $($now.Device) (код $($now.Status))" }
    }
}

try {
    if (-not ('ScriptonitePhysicalUsb.Reader' -as [type])) { Add-Type -TypeDefinition $nativeSource -Language CSharp }
    $Host.UI.RawUI.WindowTitle = 'Scriptonite — Физические USB-порты'
    $previous = @{}
    $numbers = @{}
    $cycle = 0
    $events = New-Object 'System.Collections.Generic.List[string]'
    while ($true) {
        $cycle++
        Clear-Host
        Write-Host "ФИЗИЧЕСКИЕ USB-ПОРТЫ | Проверка №$cycle | $(Get-Date)" -ForegroundColor Cyan
        Write-Host 'Опрашиваю разъёмы через USB-хабы...'
        $scan = [ScriptonitePhysicalUsb.Reader]::Scan()
        foreach($warning in $scan.Warnings){Write-ScriptoniteError -Context 'Опрос USB-хабов' -Message $warning}
        $connectors = @(Merge-UsbConnectors $scan.Ports)
        $current = @{}
        foreach ($connector in $connectors) {
            if (-not $numbers.ContainsKey($connector.Key)) { $numbers[$connector.Key] = $numbers.Count + 1 }
            $connector | Add-Member -NotePropertyName Number -NotePropertyValue $numbers[$connector.Key]
            $current[$connector.Key] = $connector
        }
        $missingMetadata = @($scan.Ports | Where-Object { -not $_.ConnectorKnown }).Count
        if($missingMetadata){Write-ScriptoniteError -Context 'Метаданные USB-разъёмов' -Message ("Не получены сведения о назначении $missingMetadata портов")}
        foreach($badPort in @($scan.Ports | Where-Object {$_.Status -gt 1})){Write-ScriptoniteError -Context 'Состояние USB-устройства' -Message ("$($badPort.Key) | код USB: $($badPort.Status)")}
        $complete = $scan.Warnings.Count -eq 0 -and $missingMetadata -eq 0
        if ($complete) {
            foreach ($message in @(Get-UsbPortChanges $previous $current)) {
                $events.Add("$(Get-Date -Format 'HH:mm:ss') $message")
                if ($events.Count -gt 20) { $events.RemoveAt(0) }
            }
            $previous = $current
        }
        $occupied = @($connectors | Where-Object { $_.Status -gt 0 }).Count
        $empty = @($connectors | Where-Object { $_.Status -eq 0 }).Count
        $unknown = @($connectors | Where-Object { $_.Status -lt 0 }).Count
        if ($complete -and $connectors.Count -gt 0) {
            Write-Host "`nФизических внешних разъёмов по данным Windows: $($connectors.Count) | Занято: $occupied | Пусто: $empty" -ForegroundColor Green
        } else {
            Write-Host "`nПодтверждено разъёмов: $($connectors.Count) | Опрос неполный | Состояние неизвестно: $unknown" -ForegroundColor Yellow
        }
        $rows = @($connectors | Where-Object { $ShowEmpty -or $_.Status -ne 0 } | Sort-Object Number | ForEach-Object {
            $state = switch ($_.Status) { 0 { 'Пусто' } 1 { 'Подключено' } -1 { 'Неизвестно' } default { "Ошибка USB (код $($_.Status))" } }
            $type = if ($_.TypeC) { 'USB-C' } else { 'USB' }
            $deviceType = switch ($_.DeviceType) { 'Mouse' { 'Мышь' } 'Gamepad' { 'Геймпад' } 'Keyboard' { 'Клавиатура' } 'Storage' { 'Накопитель' } default { $_.DeviceType } }
            [PSCustomObject]@{ Порт = "USB $($_.Number)"; Разъём = $type; Устройство = $_.Device; Тип = $deviceType; 'VID:PID' = $_.VidPid; Состояние = $state }
        })
        if ($rows.Count) { Write-Host ($rows | Format-Table -AutoSize -Wrap | Out-String -Width ([Math]::Max(60, $Host.UI.RawUI.WindowSize.Width - 1))) }
        else { Write-Host 'На подтверждённых внешних разъёмах устройств не обнаружено.' }
        Write-Host 'ПОРТЫ ПЕЧАТИ USB — СОПОСТАВЛЕНИЕ С РАЗЪЁМАМИ:' -ForegroundColor Cyan
        Write-Progress -Id 34 -Activity 'Сопоставление USB-портов печати' -Status 'Читаю порты, очереди и идентификаторы устройств...' -PercentComplete -1
        try{$bindings=Get-UsbPrinterBindings $connectors}
        finally{Write-Progress -Id 34 -Activity 'Сопоставление USB-портов печати' -Completed}
        if($bindings.Rows.Count){
            $bindingRows=@($bindings.Rows | ForEach-Object {[pscustomobject]@{'Логический порт'=$_.LogicalPort;'Очереди печати'=$_.Queues;'Физический разъём'=$_.PhysicalPort;'VID:PID'=$_.VidPid;'Устройство'=$_.Device;'Состояние'=$_.State}})
            Write-Host ($bindingRows | Format-Table -Wrap | Out-String -Width ([Math]::Max(80,$Host.UI.RawUI.WindowSize.Width-1)))
        }else{Write-Host 'USB-портов печати в доступных данных Windows не найдено.' -ForegroundColor DarkGray}
        foreach($warning in $bindings.Warnings){Write-Host $warning -ForegroundColor Yellow}
        Write-Host 'Сопоставление — по Instance ID и родителям PnP. «Не сопоставлен» не означает, что разъём пуст.' -ForegroundColor DarkGray
        if (-not $complete -or $connectors.Count -eq 0) {
            Write-Host 'Данные о разъёмах неполные. Число выше не гарантирует полный подсчёт портов; события отключения не формируются.' -ForegroundColor Yellow
            if ($missingMetadata) { Write-Host "Не удалось определить назначение $missingMetadata логических портов." -ForegroundColor Yellow }
            if ($scan.Warnings -contains 'USB hub access error: 5') { Write-Host 'Нужны права администратора: запустите PowerShell от администратора.' -ForegroundColor Yellow }
            foreach ($warning in $scan.Warnings) { Write-Host $warning -ForegroundColor DarkYellow }
        }
        Write-Host 'USB 1, USB 2... — локальные метки; расположение на корпусе определяется переподключением.' -ForegroundColor DarkGray
        if($script:ScriptoniteErrorLog.Path){Write-Host ("Журнал ошибок: "+$script:ScriptoniteErrorLog.Path) -ForegroundColor DarkGray}
        if ($events.Count) { Write-Host "`nСОБЫТИЯ:" -ForegroundColor Cyan; foreach ($entry in $events) { Write-Host $entry -ForegroundColor Yellow } }
        Write-Host "`nEnter — проверить сейчас. Повтор через $IntervalSeconds с. Ctrl+C — выход."
        if ($Once) { break }
        $deadline = (Get-Date).AddSeconds($IntervalSeconds)
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Enter') { break }
            Start-Sleep -Milliseconds 100
        }
    }
} catch {Write-ScriptoniteError -Context 'USB-сканер: остановлен с ошибкой' -ErrorRecord $_
    Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    if (-not $Once) { $null = Read-Host 'Нажмите Enter для выхода' }
    else { throw }
}
