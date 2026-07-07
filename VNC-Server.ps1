<#
.SYNOPSIS
    System Tray VNC Server (RFB 3.008, Raw encoding, dirty-rectangle updates).
.DESCRIPTION
    Runs silently in the system tray. Right-click the tray icon to Start/Stop the server,
    view connected clients, or exit.
    Icon dynamically changes to Green (Running) or Grey (Stopped).
#>
[CmdletBinding()]
param(
    [int]      $Port              = 5900,
    [string]   $BindAddress       = '0.0.0.0',
    [string]   $Password          = $env:VNC_PASSWORD,
    [ValidateRange(1, 60)]
    [int]      $MaxFps            = 30,
    [int]      $MaxClients        = 8,
    [string]   $LogPath           = (Join-Path $env:PROGRAMDATA 'PwshVnc\vnc.log'),
    [long]     $LogMaxBytes       = 10MB,
    [int]      $LogArchives       = 5,
    [string]   $DesktopName       = 'PowerShell VNC',
    [switch]   $AllowLocalhostOnly,
    [ValidateRange(0, 2)]
    [int]      $LogLevel          = 1, # 0=Error, 1=Warn, 2=Info
    [int]      $SendTimeoutMs     = 10000,
    [int]      $AcceptRetryDelayMs= 2000
)

# Hide the PowerShell console window immediately
Add-Type -Name Win32 -Namespace Posh -MemberDefinition '
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'
 $hwnd = [Posh.Win32]::GetConsoleWindow()
if ($hwnd -ne [IntPtr]::Zero) { [Posh.Win32]::ShowWindow($hwnd, 0) | Out-Null }

 $ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($AllowLocalhostOnly) { $BindAddress = '127.0.0.1' }

# Preflight Firewall Check
if (-not $AllowLocalhostOnly) {
    $fwRuleName = "PowerShell VNC Server (TCP $Port)"; $ruleExists = $false
    try { $existingRule = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction Stop; if ($existingRule) { $ruleExists = $true } } catch { }
    if (-not $ruleExists) {
        try { New-NetFirewallRule -DisplayName $fwRuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -ErrorAction Stop | Out-Null; $ruleExists = $true } catch {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"
            try { $regRules = Get-ItemProperty -Path $regPath -ErrorAction Stop; foreach ($prop in $regRules.PSObject.Properties) { $val = $prop.Value; if ($val -match "Dir=In\|" -and $val -match "Action=Allow\|") { $protoOk = ($val -match "Protocol=6\|") -or ($val -match "Protocol=Any\|") -or ($val -notmatch "Protocol="); $portOk = ($val -match "LPort=$Port\|") -or ($val -match "LPort=$Port,") -or ($val -match "LPort=Any\|") -or ($val -notmatch "LPort="); if ($protoOk -and $portOk) { $ruleExists = $true; break } } } } catch { }
        }
    }
}
 $logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

 $CSharpCode = @'
using System; using System.Collections.Generic; using System.Drawing; using System.Drawing.Imaging; using System.IO; using System.Net; using System.Net.Sockets; using System.Runtime.InteropServices; using System.Security.Cryptography; using System.Text; using System.Threading; using System.Windows.Forms;
namespace PwshVnc {
    public struct ClientInfo { public string Endpoint; public DateTime ConnectedAt; }
    public sealed class VncConfig {
        public int Port=5900; public string BindAddress="0.0.0.0"; public string Password=null; public int MaxConcurrentClients=8; public int MaxFps=30;
        public string LogFilePath=@"C:\ProgramData\PwshVnc\vnc.log"; public long LogMaxBytes=10L*1024*1024; public int LogArchiveCount=5; public int SendTimeoutMs=10000;
        public int AcceptRetryDelayMs=2000; public string DesktopName="PowerShell VNC"; public int LogLevel=1;
    }
    public sealed class Logger : IDisposable {
        private readonly string _path; private readonly long _maxBytes; private readonly int _archives; private readonly object _lock=new object(); private StreamWriter _writer; private long _currentSize; private volatile bool _disposed; private readonly int _logLevel;
        public Logger(string path, long maxBytes, int archives, int logLevel) { _path=path; _maxBytes=maxBytes; _archives=archives; _logLevel=logLevel; string dir=Path.GetDirectoryName(path); if(!string.IsNullOrEmpty(dir)&&!Directory.Exists(dir)) Directory.CreateDirectory(dir); OpenWriter(true); }
        private void OpenWriter(bool append) { var fs=new FileStream(_path, append?FileMode.Append:FileMode.Create, FileAccess.Write, FileShare.Read, 4096); _writer=new StreamWriter(fs, new UTF8Encoding(false)){AutoFlush=true}; _currentSize=append&&File.Exists(_path)?new FileInfo(_path).Length:0; }
        private void RotateIfNeeded() { if(_currentSize<_maxBytes) return; try { _writer.Flush(); _writer.Dispose(); for(int i=_archives-1;i>=1;i--) { string from=_path+"."+i; string to=_path+"."+(i+1); if(File.Exists(from)) { if(File.Exists(to)) File.Delete(to); File.Move(from,to); } } if(File.Exists(_path+".1")) File.Delete(_path+".1"); File.Move(_path,_path+".1"); } catch { } OpenWriter(false); }
        public void Log(string level, string msg) { if(_disposed) return; int lvl=level=="ERROR"?0:level=="WARN"?1:2; if(lvl>_logLevel) return; try { lock(_lock) { if(_disposed) return; string line=string.Format("{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] [T{2}] {3}", DateTime.Now, level, Thread.CurrentThread.ManagedThreadId, msg); _writer.WriteLine(line); _currentSize+=line.Length+2; RotateIfNeeded(); } } catch { } }
        public void Info(string m){Log("INFO",m);} public void Warn(string m){Log("WARN",m);} public void Error(string m){Log("ERROR",m);} public void Error(string m, Exception ex){Log("ERROR",m+" | "+ex.GetType().Name+": "+ex.Message+Environment.NewLine+ex.StackTrace);}
        public void Dispose() { lock(_lock) { if(_disposed) return; _disposed=true; try { _writer.Flush(); _writer.Dispose(); } catch { } } }
    }
    public sealed class ScreenCapturer {
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        private const int DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4; private static bool _dpiSet;
        [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
        [StructLayout(LayoutKind.Sequential)] private struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT ptScreenPos; }
        [DllImport("user32.dll")] private static extern bool GetCursorInfo(ref CURSORINFO pci);
        [DllImport("user32.dll")] private static extern bool DrawIconEx(IntPtr hdc, int xLeft, int yTop, IntPtr hIcon, int cxWidth, int cyHeight, int istepIfAniCur, IntPtr hbrFlickerFreeDraw, int diFlags);
        private const int CURSOR_SHOWING = 0x00000001; private const int DI_NORMAL = 0x0003;
        public static Logger Log { get; set; } private static bool _captureErrorLogged = false;
        public static void EnsureDpiAware() { if(_dpiSet) return; _dpiSet=true; try { if(!SetProcessDpiAwarenessContext(new IntPtr(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2))) SetProcessDPIAware(); } catch { } }
        public static Rectangle Capture(out byte[] buffer, out int stride) {
            EnsureDpiAware(); Rectangle bounds = SystemInformation.VirtualScreen;
            if(bounds.Width<=0||bounds.Height<=0) bounds=new Rectangle(0,0,1024,768);
            Bitmap bmp=null; BitmapData data=null;
            try {
                bmp=new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppRgb);
                using(Graphics g=Graphics.FromImage(bmp)) {
                    g.CopyFromScreen(bounds.X, bounds.Y, 0, 0, bmp.Size, CopyPixelOperation.SourceCopy);
                    CURSORINFO pci; pci.cbSize=Marshal.SizeOf(typeof(CURSORINFO)); pci.flags=0; pci.hCursor=IntPtr.Zero; pci.ptScreenPos=new POINT();
                    if(GetCursorInfo(ref pci)&&pci.flags==CURSOR_SHOWING&&pci.hCursor!=IntPtr.Zero) { IntPtr hdc=g.GetHdc(); try { DrawIconEx(hdc, pci.ptScreenPos.X-bounds.X, pci.ptScreenPos.Y-bounds.Y, pci.hCursor, 0, 0, 0, IntPtr.Zero, DI_NORMAL); } finally { g.ReleaseHdc(hdc); } }
                }
                data=bmp.LockBits(new Rectangle(0,0,bmp.Width,bmp.Height), ImageLockMode.ReadOnly, bmp.PixelFormat);
                stride=data.Stride; int byteCount=Math.Abs(data.Stride)*bmp.Height; buffer=new byte[byteCount]; Marshal.Copy(data.Scan0, buffer, 0, byteCount);
                _captureErrorLogged=false; return bounds;
            } catch(Exception ex) {
                if(!_captureErrorLogged) { if(Log!=null) Log.Error("Screen capture failed (returning black frame).", ex); _captureErrorLogged=true; }
                stride=bounds.Width*4; int byteCount=stride*bounds.Height; buffer=new byte[byteCount]; return bounds;
            } finally { if(data!=null) { try { bmp.UnlockBits(data); } catch { } } if(bmp!=null) bmp.Dispose(); }
        }
    }
    internal static class VncAuth {
        public static byte[] BuildChallenge() { byte[] c=new byte[16]; using(var rng=RandomNumberGenerator.Create()) { rng.GetBytes(c); } return c; }
        public static byte[] ComputeExpected(byte[] challenge, string password) {
            byte[] key=new byte[8]; byte[] pwdBytes=Encoding.ASCII.GetBytes(password??string.Empty); int n=Math.Min(8, pwdBytes.Length); Array.Copy(pwdBytes, key, n);
            for(int i=0;i<8;i++) key[i]=ReverseBits(key[i]);
            using(var des=new DESCryptoServiceProvider()) { des.Mode=CipherMode.ECB; des.Padding=PaddingMode.None; des.Key=key; using(var enc=des.CreateEncryptor()) { var resp=new byte[16]; enc.TransformBlock(challenge, 0, 16, resp, 0); return resp; } }
        }
        private static byte ReverseBits(byte b) { b=(byte)((b>>4)|(b<<4)); b=(byte)(((b&0xCC)>>2)|((b&0x33)<<2)); b=(byte)(((b&0xAA)>>1)|((b&0x55)<<1)); return b; }
    }
    internal static class KeysymMap {
        public static byte VkFromKeysym(uint k) {
            if(k>=0x61&&k<=0x7A) return (byte)(k-0x20); if(k>=0x41&&k<=0x5A) return (byte)k; if(k>=0x30&&k<=0x39) return (byte)k; if(k>=0xFFBE&&k<=0xFFC9) return (byte)(0x70+(k-0xFFBE));
            switch(k) {
                case 0xFF0D: case 0xFF8D: return 0x0D; case 0xFF08: return 0x08; case 0xFF09: return 0x09; case 0xFF1B: return 0x1B; case 0xFFFF: return 0x2E;
                case 0xFF50: return 0x24; case 0xFF57: return 0x23; case 0xFF51: return 0x25; case 0xFF52: return 0x26; case 0xFF53: return 0x27; case 0xFF54: return 0x28;
                case 0xFF55: return 0x21; case 0xFF56: return 0x22; case 0xFF63: return 0x2D; case 0xFFE1: case 0xFFE2: return 0x10; case 0xFFE3: case 0xFFE4: return 0x11;
                case 0xFFE9: case 0xFFEA: return 0x12; case 0xFFEB: case 0xFFEC: return 0x5B; case 0x0020: return 0x20; case 0xFFE5: return 0x14; case 0xFF7F: return 0x90;
                case 0xFF14: return 0x91; case 0xFFB0: return 0x30; case 0xFFB1: return 0x31; case 0xFFB2: return 0x32; case 0xFFB3: return 0x33; case 0xFFB4: return 0x34;
                case 0xFFB5: return 0x35; case 0xFFB6: return 0x36; case 0xFFB7: return 0x37; case 0xFFB8: return 0x38; case 0xFFB9: return 0x39; case 0xFFAA: return 0x6A;
                case 0xFFAB: return 0x6B; case 0xFFAD: return 0x6D; case 0xFFAE: return 0x6E; case 0xFFAF: return 0x6F; default: return 0;
            }
        }
    }
    internal static class Input {
        [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] private static extern void mouse_event(uint f, uint dx, uint dy, uint dw, int extra);
        [DllImport("user32.dll")] private static extern void keybd_event(byte vk, byte scan, uint f, int extra);
        public const uint LEFTDOWN=0x02, LEFTUP=0x04, RIGHTDOWN=0x08, RIGHTUP=0x10, MIDDLEDOWN=0x20, MIDDLEUP=0x40, WHEEL=0x0800, KEYUP=0x0002; public const uint WHEEL_DELTA=120;
        public static void Move(int x, int y) { SetCursorPos(x, y); } public static void Down(uint flag) { mouse_event(flag, 0, 0, 0, 0); } public static void Up(uint flag) { mouse_event(flag, 0, 0, 0, 0); }
        public static void Wheel(uint delta) { mouse_event(WHEEL, 0, 0, delta, 0); } public static void KeyDown(byte vk) { keybd_event(vk, 0, 0, 0); } public static void KeyUp(byte vk) { keybd_event(vk, 0, KEYUP, 0); }
    }
    internal sealed class VncClientHandler {
        private readonly TcpClient _client; private readonly VncConfig _cfg; private readonly Logger _log; private readonly VncServer _server; private byte[] _prevFrame; private int _prevStride; private int _prevW, _prevH;
        public string Endpoint { get; private set; } public DateTime ConnectedAt { get; private set; } public TcpClient Client { get { return _client; } }
        public VncClientHandler(TcpClient c, VncConfig cfg, Logger log, VncServer server, string endpoint) { _client=c; _cfg=cfg; _log=log; _server=server; Endpoint=endpoint; ConnectedAt=DateTime.UtcNow; }
        public void Run() {
            TcpClient c=_client; NetworkStream s=null;
            try {
                c.NoDelay=true; c.ReceiveTimeout=5000; c.SendTimeout=_cfg.SendTimeoutMs; SetKeepAlive(c, 15000, 5000, 3); s=c.GetStream();
                WriteAscii(s, "RFB 003.008\n"); ReadExact(s, 12);
                bool authEnabled=!string.IsNullOrEmpty(_cfg.Password);
                if(authEnabled) { s.WriteByte(1); s.WriteByte(2); } else { s.WriteByte(1); s.WriteByte(1); }
                int chosen=s.ReadByte(); if(chosen==-1) return;
                if(authEnabled) {
                    if(chosen!=2) { SendSecurityResult(s, 1, "Only VNC authentication is supported"); _log.Warn("Client refused VNC auth."); return; }
                    var challenge=VncAuth.BuildChallenge(); s.Write(challenge, 0, 16); var response=ReadExact(s, 16); var expected=VncAuth.ComputeExpected(challenge, _cfg.Password);
                    if(!ConstantTimeEquals(response, expected)) { SendSecurityResult(s, 1, "Authentication failed"); _log.Warn("VNC auth FAILED."); return; }
                    SendSecurityResult(s, 0, null);
                } else { if(chosen!=1) { SendSecurityResult(s, 1, "Only no-auth is supported"); return; } SendSecurityResult(s, 0, null); }
                ReadExact(s, 1);
                Rectangle screen=SystemInformation.VirtualScreen; int sw=screen.Width, sh=screen.Height; WriteServerInit(s, sw, sh, _cfg.DesktopName);
                byte prevButtonMask=0; long lastFrameTicks=0; long minIntervalTicks=(long)(TimeSpan.TicksPerMillisecond*(1000.0/Math.Max(1, _cfg.MaxFps)));
                while(_server.IsRunning&&c.Connected) {
                    int b;
                    try { b=s.ReadByte(); } catch(IOException ioEx) { if(!_server.IsRunning) break; var sockEx=ioEx.InnerException as SocketException; if(sockEx!=null&&sockEx.SocketErrorCode==SocketError.TimedOut) continue; _log.Warn("Client I/O error: "+ioEx.Message); break; }
                    if(b==-1) break; int msgType=b;
                    try {
                        switch(msgType) {
                            case 0: ReadExact(s, 19); break;
                            case 2: byte[] hdr=ReadExact(s, 3); ushort count=(ushort)((hdr[1]<<8)|hdr[2]); ReadExact(s, count*4); break;
                            case 3:
                                byte[] p=ReadExact(s, 9); bool incremental=p[0]!=0; ushort rx=(ushort)((p[1]<<8)|p[2]); ushort ry=(ushort)((p[3]<<8)|p[4]); ushort rw=(ushort)((p[5]<<8)|p[6]); ushort rh=(ushort)((p[7]<<8)|p[8]);
                                long now=DateTime.UtcNow.Ticks;
                                if(incremental&&(now-lastFrameTicks)<minIntervalTicks) { SendFramebufferUpdateEmpty(s); break; }
                                lastFrameTicks=now; SendFramebufferUpdate(s, screen, rx, ry, rw, rh, incremental); break;
                            case 4:
                                byte[] pk=ReadExact(s, 7); byte down=pk[0]; uint keysym=(uint)((pk[3]<<24)|(pk[4]<<16)|(pk[5]<<8)|pk[6]); byte vk=KeysymMap.VkFromKeysym(keysym);
                                if(vk!=0) { if(down==1) Input.KeyDown(vk); else Input.KeyUp(vk); } break;
                            case 5:
                                byte[] pm=ReadExact(s, 5); byte mask=pm[0]; ushort x=(ushort)((pm[1]<<8)|pm[2]); ushort y=(ushort)((pm[3]<<8)|pm[4]); Input.Move(screen.X+x, screen.Y+y); HandleButtons(mask, ref prevButtonMask); break;
                            case 6: byte[] pc=ReadExact(s, 7); int len=(pc[3]<<24)|(pc[4]<<16)|(pc[5]<<8)|pc[6]; if(len>0&&len<64*1024*1024) ReadExact(s, len); break;
                            default: _log.Warn("Unknown msg type "+msgType); return;
                        }
                    } catch(IOException) { _log.Warn("Client I/O error during parse."); break; }
                }
            } catch(Exception ex) { _log.Error("Client handler error", ex); } finally { try { if(s!=null) s.Close(); } catch { } try { c.Close(); } catch { } _server.NotifyClientClosed(this); }
        }
        private void HandleButtons(byte mask, ref byte prev) {
            if((mask&1)!=(prev&1)) { if((mask&1)!=0) Input.Down(Input.LEFTDOWN); else Input.Up(Input.LEFTUP); }
            if((mask&2)!=(prev&2)) { if((mask&2)!=0) Input.Down(Input.MIDDLEDOWN); else Input.Up(Input.MIDDLEUP); }
            if((mask&4)!=(prev&4)) { if((mask&4)!=0) Input.Down(Input.RIGHTDOWN); else Input.Up(Input.RIGHTUP); }
            if((mask&8)!=0&&(prev&8)==0) Input.Wheel(Input.WHEEL_DELTA);
            if((mask&16)!=0&&(prev&16)==0) Input.Wheel(unchecked((uint)-Input.WHEEL_DELTA));
            prev=mask;
        }
        private void SendFramebufferUpdate(NetworkStream s, Rectangle screen, ushort rx, ushort ry, ushort rw, ushort rh, bool incremental) {
            byte[] cur; int curStride; Rectangle bounds=ScreenCapturer.Capture(out cur, out curStride); int W=bounds.Width, H=bounds.Height;
            bool fullRequested=(rw==0||rw==W)&&(rh==0||rh==H); bool resChanged=(_prevFrame==null)||(_prevW!=W)||(_prevH!=H);
            if(!incremental||resChanged||fullRequested) { SendRectangles(s, new[] { new Rectangle(0,0,W,H) }, cur, curStride, W, H); CacheFrame(cur, curStride, W, H); }
            else { Rectangle dirty; if(TryFindDirtyRect(cur, _prevFrame, curStride, _prevStride, W, H, out dirty)) { SendRectangles(s, new[] { dirty }, cur, curStride, W, H); CopyRegion(cur, curStride, _prevFrame, _prevStride, dirty, W, H); } else { SendFramebufferUpdateEmpty(s); } }
        }
        private void CacheFrame(byte[] cur, int curStride, int w, int h) { _prevFrame=new byte[cur.Length]; Buffer.BlockCopy(cur, 0, _prevFrame, 0, cur.Length); _prevStride=curStride; _prevW=w; _prevH=h; }
        private static void CopyRegion(byte[] src, int srcStride, byte[] dst, int dstStride, Rectangle r, int w, int h) { int bytesPerRow=r.Width*4; for(int y=0;y<r.Height;y++) Buffer.BlockCopy(src, (r.Y+y)*srcStride+r.X*4, dst, (r.Y+y)*dstStride+r.X*4, bytesPerRow); }
        private static bool TryFindDirtyRect(byte[] cur, byte[] prev, int curStride, int prevStride, int w, int h, out Rectangle dirty) {
            dirty=Rectangle.Empty; if(prev==null||cur.Length!=prev.Length) return false; int minX=w, minY=h, maxX=-1, maxY=-1;
            for(int y=0;y<h;y++) { int rowC=y*curStride; int rowP=y*prevStride; for(int x=0;x<w;x++) { int i=rowC+x*4; int j=rowP+x*4; if(cur[i]!=prev[j]||cur[i+1]!=prev[j+1]||cur[i+2]!=prev[j+2]) { if(x<minX) minX=x; if(x>maxX) maxX=x; if(y<minY) minY=y; if(y>maxY) maxY=y; } } }
            if(maxX<0) return false; dirty=new Rectangle(minX, minY, maxX-minX+1, maxY-minY+1); return true;
        }
        private void SendRectangles(NetworkStream s, Rectangle[] rects, byte[] frame, int stride, int fw, int fh) {
            s.WriteByte(0); s.WriteByte(0); WriteU16(s, (ushort)rects.Length);
            foreach(var r in rects) { int rx=Math.Max(0,r.X), ry=Math.Max(0,r.Y); int rw=Math.Min(fw-rx,r.Width); int rh=Math.Min(fh-ry,r.Height); if(rw<=0||rh<=0) continue;
                WriteU16(s, (ushort)rx); WriteU16(s, (ushort)ry); WriteU16(s, (ushort)rw); WriteU16(s, (ushort)rh); WriteU32(s, 0);
                int bytesPerRow=rw*4; for(int y=0;y<rh;y++) { int srcOffset=(ry+y)*stride+rx*4; s.Write(frame, srcOffset, bytesPerRow); } }
        }
        private static void SendFramebufferUpdateEmpty(NetworkStream s) { s.WriteByte(0); s.WriteByte(0); WriteU16(s, 0); }
        private static void SendSecurityResult(NetworkStream s, uint status, string reason) { WriteU32(s, status); if(status!=0&&!string.IsNullOrEmpty(reason)) { byte[] r=Encoding.ASCII.GetBytes(reason); WriteU32(s, (uint)r.Length); s.Write(r, 0, r.Length); } }
        private static void WriteServerInit(NetworkStream s, int w, int h, string name) { WriteU16(s, (ushort)w); WriteU16(s, (ushort)h); s.WriteByte(32); s.WriteByte(24); s.WriteByte(0); s.WriteByte(1); s.WriteByte(0); s.WriteByte(255); s.WriteByte(0); s.WriteByte(255); s.WriteByte(0); s.WriteByte(255); s.WriteByte(16); s.WriteByte(8); s.WriteByte(0); s.WriteByte(0); s.WriteByte(0); s.WriteByte(0); byte[] nb=Encoding.ASCII.GetBytes(name??"VNC"); WriteU32(s, (uint)nb.Length); s.Write(nb, 0, nb.Length); }
        private static byte[] ReadExact(Stream s, int count) { if(count<=0) return new byte[0]; byte[] buf=new byte[count]; int read=0; while(read<count) { int r=s.Read(buf, read, count-read); if(r<=0) throw new IOException("Client closed connection"); read+=r; } return buf; }
        private static void WriteAscii(Stream s, string t) { byte[] b=Encoding.ASCII.GetBytes(t); s.Write(b, 0, b.Length); }
        private static void WriteU16(Stream s, ushort v) { s.WriteByte((byte)((v>>8)&0xFF)); s.WriteByte((byte)(v&0xFF)); }
        private static void WriteU32(Stream s, uint v) { s.WriteByte((byte)((v>>24)&0xFF)); s.WriteByte((byte)((v>>16)&0xFF)); s.WriteByte((byte)((v>>8)&0xFF)); s.WriteByte((byte)(v&0xFF)); }
        private static bool ConstantTimeEquals(byte[] a, byte[] b) { if(a==null||b==null||a.Length!=b.Length) return false; int d=0; for(int i=0;i<a.Length;i++) d|=a[i]^b[i]; return d==0; }
        private static void SetKeepAlive(TcpClient c, int onMs, int intervalMs, int count) { try { var sock=c.Client; sock.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true); byte[] ka=new byte[12]; BitConverter.GetBytes(1).CopyTo(ka, 0); BitConverter.GetBytes(onMs).CopyTo(ka, 4); BitConverter.GetBytes(intervalMs).CopyTo(ka, 8); sock.IOControl(IOControlCode.KeepAliveValues, ka, null); } catch { } }
    }
    public sealed class VncServer : IDisposable {
        private readonly VncConfig _cfg; private readonly Logger _log; private TcpListener _listener; private Thread _acceptThread;
        private readonly List<VncClientHandler> _clients=new List<VncClientHandler>(); private readonly List<TcpClient> _clientSockets=new List<TcpClient>(); private readonly object _clientsLock=new object(); private volatile bool _running; private volatile bool _disposed;
        public bool IsRunning { get { return _running; } }
        public VncServer(VncConfig cfg, Logger log) { _cfg=cfg; _log=log; }
        public void Start() { if(_running) return; _running=true; _acceptThread=new Thread(AcceptLoop) { IsBackground=true, Name="VncAccept" }; _acceptThread.Start(); }
        public void Stop() { if(!_running) return; _running=false; try { if(_listener!=null) _listener.Stop(); } catch { } lock(_clientsLock) { foreach(var sock in _clientSockets) { try { sock.Close(); } catch { } } _clientSockets.Clear(); _clients.Clear(); } if(_acceptThread!=null&&_acceptThread.IsAlive) _acceptThread.Join(3000); }
        private void AcceptLoop() {
            IPAddress bind=IPAddress.Any; if(!string.IsNullOrEmpty(_cfg.BindAddress)&&_cfg.BindAddress!="0.0.0.0") bind=IPAddress.Parse(_cfg.BindAddress);
            while(_running) {
                try { _listener=new TcpListener(bind, _cfg.Port); _listener.Start(); } catch(Exception ex) { _log.Error("Listener start failed", ex); Thread.Sleep(_cfg.AcceptRetryDelayMs); continue; }
                while(_running) {
                    TcpClient c=null; try { c=_listener.AcceptTcpClient(); } catch(SocketException sex) { if(!_running) break; _log.Warn("Accept error: "+sex.Message); break; } catch(Exception ex) { if(!_running) break; _log.Error("Accept exception", ex); break; }
                    int curClients; lock(_clientsLock) curClients=_clients.Count;
                    if(curClients>=_cfg.MaxConcurrentClients) { _log.Warn("Rejecting client: max "+_cfg.MaxConcurrentClients+" reached."); try { c.Close(); } catch { } continue; }
                    var ep=c.Client.RemoteEndPoint as IPEndPoint;
                    if(ep!=null&&IPAddress.IsLoopback(ep.Address)==false&&IPAddress.IsLoopback(bind)) { _log.Warn("Rejected non-localhost client: "+ep); try { c.Close(); } catch { } continue; }
                    string endpointStr=ep!=null?ep.ToString():"Unknown"; var handler=new VncClientHandler(c, _cfg, _log, this, endpointStr);
                    lock(_clientsLock) { _clients.Add(handler); _clientSockets.Add(c); }
                    var t=new Thread(() => handler.Run()) { IsBackground=true, Name="VncClient-"+(ep!=null?ep.ToString():"?") }; t.Start();
                }
                try { _listener.Stop(); } catch { } if(_running) { _log.Warn("Listener exited; restarting in "+_cfg.AcceptRetryDelayMs+"ms"); Thread.Sleep(_cfg.AcceptRetryDelayMs); }
            }
        }
        internal void NotifyClientClosed(VncClientHandler h) { lock(_clientsLock) { _clients.Remove(h); _clientSockets.Remove(h.Client); } }
        public int ActiveClientCount { get { lock(_clientsLock) { return _clients.Count; } } }
        public ClientInfo[] GetActiveClients() { lock(_clientsLock) { ClientInfo[] arr=new ClientInfo[_clients.Count]; for(int i=0;i<_clients.Count;i++) arr[i]=new ClientInfo { Endpoint=_clients[i].Endpoint, ConnectedAt=_clients[i].ConnectedAt }; return arr; } }
        public void Dispose() { if(_disposed) return; _disposed=true; Stop(); }
    }
}
'@

 $referencedAssemblies = @('System.Drawing','System.Windows.Forms')
if ($PSVersionTable.PSEdition -eq 'Core') { $referencedAssemblies += 'System.Net.Primitives' }
if (-not ('PwshVnc.VncServer' -as [type])) { try { Add-Type -TypeDefinition $CSharpCode -Language CSharp -ReferencedAssemblies $referencedAssemblies } catch { throw } }

 $script:config = New-Object PwshVnc.VncConfig -Property @{
    Port=$Port; BindAddress=$BindAddress; Password=$Password; MaxConcurrentClients=$MaxClients; MaxFps=$MaxFps; LogFilePath=$LogPath; LogMaxBytes=[long]$LogMaxBytes; LogArchiveCount=$LogArchives; SendTimeoutMs=$SendTimeoutMs; AcceptRetryDelayMs=$AcceptRetryDelayMs; DesktopName=$DesktopName; LogLevel=$LogLevel
}
 $script:logger = New-Object PwshVnc.Logger -ArgumentList $config.LogFilePath, $config.LogMaxBytes, $config.LogArchiveCount, $config.LogLevel
[PwshVnc.ScreenCapturer]::Log = $logger
 $script:server = New-Object PwshVnc.VncServer -ArgumentList $config, $logger

# --- Dynamic Icon Generation ---
function New-TrayIcon {
    param([string]$ColorHex, [string]$BorderHex)
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $fill = [System.Drawing.ColorTranslator]::FromHtml($ColorHex)
    $border = [System.Drawing.ColorTranslator]::FromHtml($BorderHex)
    $brush = New-Object System.Drawing.SolidBrush($fill)
    $pen = New-Object System.Drawing.Pen($border, 2)
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $g.DrawEllipse($pen, 2, 2, 12, 12)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $bmp.Dispose()
    return $icon
}
 $script:iconRunning = New-TrayIcon -ColorHex "#32CD32" -BorderHex "#006400" # LimeGreen / DarkGreen
 $script:iconStopped = New-TrayIcon -ColorHex "#A9A9A9" -BorderHex "#696969" # DarkGray / DimGray

# --- System Tray GUI Setup ---
 $notify = New-Object System.Windows.Forms.NotifyIcon
 $notify.Icon = $script:iconStopped
 $notify.Visible = $true
 $notify.Text = "PowerShell VNC Server"

 $menu = New-Object System.Windows.Forms.ContextMenuStrip
 $miStatus = $menu.Items.Add("Server Stopped")
 $miStatus.Enabled = $false
 $menu.Items.Add("-") | Out-Null
 $miStart = $menu.Items.Add("Start Server")
 $miStop = $menu.Items.Add("Stop Server")
 $menu.Items.Add("-") | Out-Null
 $miClients = $menu.Items.Add("Connected Clients: 0")
 $menu.Items.Add("-") | Out-Null
 $miExit = $menu.Items.Add("Exit")

function Update-MenuState {
    if ($script:server.IsRunning) {
        $miStatus.Text = "Running on $($script:config.BindAddress):$($script:config.Port)"
        $miStart.Enabled = $false
        $miStop.Enabled = $true
        $notify.Icon = $script:iconRunning
    } else {
        $miStatus.Text = "Server Stopped"
        $miStart.Enabled = $true
        $miStop.Enabled = $false
        $notify.Icon = $script:iconStopped
    }
    $clients = $script:server.GetActiveClients()
    $miClients.Text = "Connected Clients: $($clients.Count)"
}

 $miStart.Add_Click({
    $script:server.Start()
    Update-MenuState
})

 $miStop.Add_Click({
    $script:server.Stop()
    Update-MenuState
})

 $miClients.Add_Click({
    $clients = $script:server.GetActiveClients()
    if ($clients.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No clients currently connected.", "VNC Server Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } else {
        $msg = "Active Clients:`n`n"
        foreach ($c in $clients) {
            $dur = ([datetime]::UtcNow - $c.ConnectedAt).ToString('hh\:mm\:ss')
            $msg += "$($c.Endpoint)  (Duration: $dur)`n"
        }
        [System.Windows.Forms.MessageBox]::Show($msg, "VNC Server Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

 $miExit.Add_Click({
    if ($script:server.IsRunning) { $script:server.Stop() }
    $script:logger.Dispose()
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

 $notify.ContextMenuStrip = $menu

# Auto-start the server on launch
 $server.Start()
Update-MenuState

# Timer to keep client count updated in the menu
 $timer = New-Object System.Windows.Forms.Timer
 $timer.Interval = 2000
 $timer.Add_Tick({ Update-MenuState })
 $timer.Start()

# Run the WinForms message loop (keeps script alive in background)
[System.Windows.Forms.Application]::Run()
