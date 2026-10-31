[CmdletBinding()]
param(
    [ValidateRange(1, 3600)][int]$IntervalSeconds = 30,
    [switch]$ShowEmpty,
    [switch]$Once
)

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
        $connectors = @(Merge-UsbConnectors $scan.Ports)
        $current = @{}
        foreach ($connector in $connectors) {
            if (-not $numbers.ContainsKey($connector.Key)) { $numbers[$connector.Key] = $numbers.Count + 1 }
            $connector | Add-Member -NotePropertyName Number -NotePropertyValue $numbers[$connector.Key]
            $current[$connector.Key] = $connector
        }
        $missingMetadata = @($scan.Ports | Where-Object { -not $_.ConnectorKnown }).Count
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
        if (-not $complete -or $connectors.Count -eq 0) {
            Write-Host 'Данные о разъёмах неполные. Число выше не гарантирует полный подсчёт портов; события отключения не формируются.' -ForegroundColor Yellow
            if ($missingMetadata) { Write-Host "Не удалось определить назначение $missingMetadata логических портов." -ForegroundColor Yellow }
            if ($scan.Warnings -contains 'USB hub access error: 5') { Write-Host 'Нужны права администратора: запустите PowerShell от администратора.' -ForegroundColor Yellow }
            foreach ($warning in $scan.Warnings) { Write-Host $warning -ForegroundColor DarkYellow }
        }
        Write-Host 'USB 1, USB 2... — локальные метки; расположение на корпусе определяется переподключением.' -ForegroundColor DarkGray
        if ($events.Count) { Write-Host "`nСОБЫТИЯ:" -ForegroundColor Cyan; foreach ($entry in $events) { Write-Host $entry -ForegroundColor Yellow } }
        Write-Host "`nEnter — проверить сейчас. Повтор через $IntervalSeconds с. Ctrl+C — выход."
        if ($Once) { break }
        $deadline = (Get-Date).AddSeconds($IntervalSeconds)
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Enter') { break }
            Start-Sleep -Milliseconds 100
        }
    }
} catch {
    Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    if (-not $Once) { $null = Read-Host 'Нажмите Enter для выхода' }
    else { throw }
}
