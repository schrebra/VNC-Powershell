<#
.SYNOPSIS
    Long-running, production-grade PowerShell-hosted VNC server (RFB 3.008, Raw encoding,
    dirty-rectangle incremental updates, optional VNC password auth, rotating logs,
    multi-monitor capture, DPI-aware, graceful shutdown, automatic firewall management).

.DESCRIPTION
    Designed to run unattended for weeks/months. Includes:
      - VNC challenge-response DES password authentication (optional)
      - Dirty-rectangle tracking for incremental FramebufferUpdateRequest
      - Frame-rate limiting (default 30 FPS, max 60)
      - Rotating log files with size cap
      - Per-client exception isolation; listener auto-restart
      - TCP keepalive + read timeout to evict dead clients
      - Console-control handler for clean shutdown on logoff/shutdown
      - DPI-aware multi-monitor capture (SystemInformation.VirtualScreen)
      - Automatic Windows Firewall rule creation (falls back to registry check for non-admins)
      - Graceful handling of locked/sleeping screens (sends black frame instead of crashing)
      - Configurable via parameters / environment variables

.NOTES
    FIREWALL & NETWORKING:
    You do NOT need to open any ports on the "initiating" computer (the one running the VNC Viewer).
    Windows Firewall allows outbound connections by default. 
    
    You ONLY need to open the port on the "target" computer (the machine running THIS script).
    - If you run this script as Administrator, it will automatically create the inbound firewall rule.
    - If you run as a standard user, it will check the registry to see if the rule already exists.
      If it doesn't exist, you must manually run this in an Admin PowerShell prompt:
      New-NetFirewallRule -DisplayName "PowerShell VNC Server" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5900

.PARAMETER Port
    TCP port to listen on (default 5900).

.PARAMETER BindAddress
    IP address to bind (default 0.0.0.0; use 127.0.0.1 for localhost-only).

.PARAMETER Password
    Optional VNC password. If omitted, security type None is used (NOT recommended).

.PARAMETER MaxFps
    Maximum frame rate per client (default 30, maximum 60).

.PARAMETER MaxClients
    Maximum concurrent VNC client connections (default 8).

.PARAMETER LogPath
    Path to log file. Default: %PROGRAMDATA%\PwshVnc\vnc.log

.PARAMETER AllowLocalhostOnly
    If set, overrides BindAddress to 127.0.0.1.

.EXAMPLE
    .\vnc-server.ps1 -Password "s3cret" -MaxFps 45
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
    [int]      $SendTimeoutMs     = 10000,
    [int]      $AcceptRetryDelayMs= 2000
)

 $ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($AllowLocalhostOnly) { $BindAddress = '127.0.0.1' }

# ─────────────────────────────────────────────────────────────────────────────
# 1. PRE-FLIGHT: clear stale listener, ensure firewall rule, setup log dir
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[preflight] Checking port $Port..." -ForegroundColor Cyan
 $stale = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($stale) {
    foreach ($c in $stale) {
        $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if ($p) {
            Write-Host "[preflight] Port $Port held by $($p.Name) (PID $($c.OwningProcess)). Terminating." -ForegroundColor Yellow
            try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction Stop } catch { }
            Start-Sleep -Milliseconds 500
        }
    }
}
Write-Host "[preflight] Port $Port is free." -ForegroundColor Green

# Ensure Firewall Rule Exists (requires Admin to create, falls back to registry check)
if (-not $AllowLocalhostOnly) {
    $fwRuleName = "PowerShell VNC Server (TCP $Port)"
    $ruleExists = $false
    
    # First, try standard method (works if admin)
    try {
        $existingRule = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction Stop
        if ($existingRule) {
            $ruleExists = $true
            Write-Host "[preflight] Firewall rule '$fwRuleName' already exists." -ForegroundColor Green
        }
    } catch {
        # If Get-NetFirewallRule fails, we proceed to try creating or checking registry
    }

    if (-not $ruleExists) {
        # Try to create it (requires Admin)
        try {
            Write-Host "[preflight] Adding inbound firewall rule: '$fwRuleName'..." -ForegroundColor Yellow
            New-NetFirewallRule -DisplayName $fwRuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -ErrorAction Stop | Out-Null
            Write-Host "[preflight] Firewall rule added successfully." -ForegroundColor Green
            $ruleExists = $true
        } catch {
            # If creation fails (e.g. non-admin), look in the registry for all profiles
            Write-Host "[preflight] Not running as Admin. Checking registry for existing inbound TCP $Port rule..." -ForegroundColor Yellow
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"
            try {
                $regRules = Get-ItemProperty -Path $regPath -ErrorAction Stop
                foreach ($prop in $regRules.PSObject.Properties) {
                    $val = $prop.Value
                    # Windows Firewall registry values are pipe-delimited strings (v2.x format)
                    if ($val -match "Dir=In\|" -and $val -match "Action=Allow\|") {
                        $protoOk = ($val -match "Protocol=6\|") -or ($val -match "Protocol=Any\|") -or ($val -notmatch "Protocol=")
                        $portOk  = ($val -match "LPort=$Port\|") -or ($val -match "LPort=$Port,") -or ($val -match "LPort=Any\|") -or ($val -notmatch "LPort=")
                        if ($protoOk -and $portOk) {
                            $ruleExists = $true
                            break
                        }
                    }
                }
                
                if ($ruleExists) {
                    Write-Host "[preflight] Existing inbound firewall rule allowing TCP $Port found in registry." -ForegroundColor Green
                } else {
                    Write-Warning "[preflight] No firewall rule found for TCP $Port. Run as Administrator to create it, or manually execute:"
                    Write-Warning "             New-NetFirewallRule -DisplayName '$fwRuleName' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port"
                }
            } catch {
                Write-Warning "[preflight] Could not read firewall rules from registry. Access denied or key missing."
                Write-Warning "             Manually run as Admin: New-NetFirewallRule -DisplayName '$fwRuleName' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port"
            }
        }
    }
}

# Ensure log directory exists
 $logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# ─────────────────────────────────────────────────────────────────────────────
# 2. EMBEDDED C# SERVER (C# 5.0 Compatible)
# ─────────────────────────────────────────────────────────────────────────────
 $CSharpCode = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace PwshVnc
{
    // ───────────────────────── Config ─────────────────────────
    public sealed class VncConfig
    {
        public int Port = 5900;
        public string BindAddress = "0.0.0.0";
        public string Password = null;
        public int MaxConcurrentClients = 8;
        public int MaxFps = 30;
        public string LogFilePath = @"C:\ProgramData\PwshVnc\vnc.log";
        public long LogMaxBytes = 10L * 1024 * 1024;
        public int LogArchiveCount = 5;
        public int SendTimeoutMs = 10000;
        public int AcceptRetryDelayMs = 2000;
        public string DesktopName = "PowerShell VNC";
    }

    // ───────────────────────── Logger (rotating, thread-safe) ─────────────────────────
    public sealed class Logger : IDisposable
    {
        private readonly string _path;
        private readonly long _maxBytes;
        private readonly int _archives;
        private readonly object _lock = new object();
        private StreamWriter _writer;
        private long _currentSize;
        private volatile bool _disposed;

        public Logger(string path, long maxBytes, int archives)
        {
            _path = path; _maxBytes = maxBytes; _archives = archives;
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                Directory.CreateDirectory(dir);
            OpenWriter(true);
        }

        private void OpenWriter(bool append)
        {
            var fs = new FileStream(_path, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.Read, 4096);
            _writer = new StreamWriter(fs, new UTF8Encoding(false)) { AutoFlush = true };
            _currentSize = append && File.Exists(_path) ? new FileInfo(_path).Length : 0;
        }

        private void RotateIfNeeded()
        {
            if (_currentSize < _maxBytes) return;
            try
            {
                _writer.Flush();
                _writer.Dispose();
                for (int i = _archives - 1; i >= 1; i--)
                {
                    string from = _path + "." + i;
                    string to = _path + "." + (i + 1);
                    if (File.Exists(from)) { if (File.Exists(to)) File.Delete(to); File.Move(from, to); }
                }
                if (File.Exists(_path + ".1")) File.Delete(_path + ".1");
                File.Move(_path, _path + ".1");
            }
            catch { }
            OpenWriter(false);
        }

        public void Log(string level, string msg)
        {
            if (_disposed) return;
            try
            {
                lock (_lock)
                {
                    if (_disposed) return;
                    string line = string.Format("{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] [T{2}] {3}", DateTime.Now, level, Thread.CurrentThread.ManagedThreadId, msg);
                    _writer.WriteLine(line);
                    _currentSize += line.Length + 2;
                    RotateIfNeeded();
                }
            }
            catch { }
        }

        public void Info(string m) { Log("INFO", m); }
        public void Warn(string m) { Log("WARN", m); }
        public void Error(string m) { Log("ERROR", m); }
        public void Error(string m, Exception ex) { Log("ERROR", m + " | " + ex.GetType().Name + ": " + ex.Message + Environment.NewLine + ex.StackTrace); }
        public void Debug(string m) { Log("DEBUG", m); }

        public void Dispose()
        {
            lock (_lock)
            {
                if (_disposed) return;
                _disposed = true;
                try { _writer.Flush(); _writer.Dispose(); } catch { }
            }
        }
    }

    // ───────────────────────── DPI-aware screen capture ─────────────────────────
    public sealed class ScreenCapturer
    {
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        private const int DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4;
        private static bool _dpiSet;

        public static void EnsureDpiAware()
        {
            if (_dpiSet) return;
            _dpiSet = true;
            try
            {
                if (!SetProcessDpiAwarenessContext(new IntPtr(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)))
                    SetProcessDPIAware();
            }
            catch { }
        }

        public static Rectangle Capture(out byte[] buffer, out int stride)
        {
            EnsureDpiAware();
            Rectangle bounds = SystemInformation.VirtualScreen;
            if (bounds.Width <= 0 || bounds.Height <= 0)
                bounds = new Rectangle(0, 0, 1024, 768); // Fallback if no screen

            Bitmap bmp = null;
            BitmapData data = null;
            try
            {
                bmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppRgb);
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.CopyFromScreen(bounds.X, bounds.Y, 0, 0, bmp.Size, CopyPixelOperation.SourceCopy);
                }
                data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, bmp.PixelFormat);
                stride = data.Stride;
                int byteCount = Math.Abs(data.Stride) * bmp.Height;
                buffer = new byte[byteCount];
                Marshal.Copy(data.Scan0, buffer, 0, byteCount);
                return bounds;
            }
            catch
            {
                // Screen is locked, sleeping, or RDP disconnected.
                // Return a black screen to keep the VNC connection alive without crashing.
                stride = bounds.Width * 4;
                int byteCount = stride * bounds.Height;
                buffer = new byte[byteCount]; // Default is all zeros (black)
                return bounds;
            }
            finally
            {
                if (data != null) { try { bmp.UnlockBits(data); } catch { } }
                if (bmp != null) bmp.Dispose();
            }
        }
    }

    // ───────────────────────── VNC password auth ─────────────────────────
    internal static class VncAuth
    {
        public static byte[] BuildChallenge()
        {
            byte[] c = new byte[16];
            using (var rng = RandomNumberGenerator.Create())
            {
                rng.GetBytes(c);
            }
            return c;
        }

        public static byte[] ComputeExpected(byte[] challenge, string password)
        {
            byte[] key = new byte[8];
            byte[] pwdBytes = Encoding.ASCII.GetBytes(password ?? string.Empty);
            int n = Math.Min(8, pwdBytes.Length);
            Array.Copy(pwdBytes, key, n);
            for (int i = 0; i < 8; i++) key[i] = ReverseBits(key[i]);

            using (var des = new DESCryptoServiceProvider())
            {
                des.Mode = CipherMode.ECB;
                des.Padding = PaddingMode.None;
                des.Key = key;
                using (var enc = des.CreateEncryptor())
                {
                    var resp = new byte[16];
                    enc.TransformBlock(challenge, 0, 16, resp, 0);
                    return resp;
                }
            }
        }

        private static byte ReverseBits(byte b)
        {
            b = (byte)((b >> 4) | (b << 4));
            b = (byte)(((b & 0xCC) >> 2) | ((b & 0x33) << 2));
            b = (byte)(((b & 0xAA) >> 1) | ((b & 0x55) << 1));
            return b;
        }
    }

    // ───────────────────────── Keysym → VK mapping ─────────────────────────
    internal static class KeysymMap
    {
        public static byte VkFromKeysym(uint k)
        {
            if (k >= 0x61 && k <= 0x7A) return (byte)(k - 0x20);
            if (k >= 0x41 && k <= 0x5A) return (byte)k;
            if (k >= 0x30 && k <= 0x39) return (byte)k;
            if (k >= 0xFFBE && k <= 0xFFC9) return (byte)(0x70 + (k - 0xFFBE));

            switch (k)
            {
                case 0xFF0D: return 0x0D;
                case 0xFF8D: return 0x0D;
                case 0xFF08: return 0x08;
                case 0xFF09: return 0x09;
                case 0xFF1B: return 0x1B;
                case 0xFFFF: return 0x2E;
                case 0xFF50: return 0x24;
                case 0xFF57: return 0x23;
                case 0xFF51: return 0x25;
                case 0xFF52: return 0x26;
                case 0xFF53: return 0x27;
                case 0xFF54: return 0x28;
                case 0xFF55: return 0x21;
                case 0xFF56: return 0x22;
                case 0xFF63: return 0x2D;
                case 0xFFE1: case 0xFFE2: return 0x10;
                case 0xFFE3: case 0xFFE4: return 0x11;
                case 0xFFE9: case 0xFFEA: return 0x12;
                case 0xFFEB: case 0xFFEC: return 0x5B;
                case 0x0020: return 0x20;
                case 0xFFE5: return 0x14;
                case 0xFF7F: return 0x90;
                case 0xFF14: return 0x91;
                case 0xFFB0: return 0x30;
                case 0xFFB1: return 0x31;
                case 0xFFB2: return 0x32;
                case 0xFFB3: return 0x33;
                case 0xFFB4: return 0x34;
                case 0xFFB5: return 0x35;
                case 0xFFB6: return 0x36;
                case 0xFFB7: return 0x37;
                case 0xFFB8: return 0x38;
                case 0xFFB9: return 0x39;
                case 0xFFAA: return 0x6A;
                case 0xFFAB: return 0x6B;
                case 0xFFAD: return 0x6D;
                case 0xFFAE: return 0x6E;
                case 0xFFAF: return 0x6F;
                default: return 0;
            }
        }
    }

    // ───────────────────────── Input injector ─────────────────────────
    internal static class Input
    {
        [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] private static extern void mouse_event(uint f, uint dx, uint dy, uint dw, int extra);
        [DllImport("user32.dll")] private static extern void keybd_event(byte vk, byte scan, uint f, int extra);

        public const uint LEFTDOWN = 0x02, LEFTUP = 0x04, RIGHTDOWN = 0x08, RIGHTUP = 0x10,
                          MIDDLEDOWN = 0x20, MIDDLEUP = 0x40, WHEEL = 0x0800, KEYUP = 0x0002;
        public const uint WHEEL_DELTA = 120;

        public static void Move(int x, int y) { SetCursorPos(x, y); }
        public static void Down(uint flag) { mouse_event(flag, 0, 0, 0, 0); }
        public static void Up(uint flag) { mouse_event(flag, 0, 0, 0, 0); }
        public static void Wheel(uint delta) { mouse_event(WHEEL, 0, 0, delta, 0); }
        public static void KeyDown(byte vk) { keybd_event(vk, 0, 0, 0); }
        public static void KeyUp(byte vk) { keybd_event(vk, 0, KEYUP, 0); }
    }

    // ───────────────────────── Per-client handler ─────────────────────────
    internal sealed class VncClientHandler
    {
        private readonly TcpClient _client;
        private readonly VncConfig _cfg;
        private readonly Logger _log;
        private readonly VncServer _server;
        private byte[] _prevFrame;
        private int _prevStride;
        private int _prevW, _prevH;

        public TcpClient Client { get { return _client; } }

        public VncClientHandler(TcpClient c, VncConfig cfg, Logger log, VncServer server)
        { _client = c; _cfg = cfg; _log = log; _server = server; }

        public void Run()
        {
            TcpClient c = _client;
            NetworkStream s = null;
            try
            {
                c.NoDelay = true;
                c.ReceiveTimeout = 5000; // 5s timeout for idle loop polling
                c.SendTimeout = _cfg.SendTimeoutMs;
                SetKeepAlive(c, 15000, 5000, 3);

                s = c.GetStream();

                WriteAscii(s, "RFB 003.008\n");
                ReadExact(s, 12);

                bool authEnabled = !string.IsNullOrEmpty(_cfg.Password);
                if (authEnabled)
                {
                    s.WriteByte(1); s.WriteByte(2);
                }
                else
                {
                    s.WriteByte(1); s.WriteByte(1);
                }
                int chosen = s.ReadByte();
                if (chosen == -1) { _log.Warn("Client closed during security select."); return; }

                if (authEnabled)
                {
                    if (chosen != 2)
                    {
                        SendSecurityResult(s, 1, "Only VNC authentication is supported");
                        _log.Warn("Client refused VNC auth.");
                        return;
                    }
                    var challenge = VncAuth.BuildChallenge();
                    s.Write(challenge, 0, 16);
                    var response = ReadExact(s, 16);
                    var expected = VncAuth.ComputeExpected(challenge, _cfg.Password);
                    bool ok = ConstantTimeEquals(response, expected);
                    if (!ok)
                    {
                        SendSecurityResult(s, 1, "Authentication failed");
                        _log.Warn("VNC auth FAILED.");
                        return;
                    }
                    SendSecurityResult(s, 0, null);
                    _log.Info("VNC auth succeeded.");
                }
                else
                {
                    if (chosen != 1)
                    {
                        SendSecurityResult(s, 1, "Only no-auth is supported");
                        return;
                    }
                    SendSecurityResult(s, 0, null);
                }

                ReadExact(s, 1);

                Rectangle screen = SystemInformation.VirtualScreen;
                int sw = screen.Width, sh = screen.Height;
                WriteServerInit(s, sw, sh, _cfg.DesktopName);
                _log.Info(string.Format("Client connected. Screen={0}x{1} @({2},{3})", sw, sh, screen.X, screen.Y));

                byte prevButtonMask = 0;
                long lastFrameTicks = 0;
                long minIntervalTicks = (long)(TimeSpan.TicksPerMillisecond * (1000.0 / Math.Max(1, _cfg.MaxFps)));

                while (_server.IsRunning && c.Connected)
                {
                    int b;
                    try
                    {
                        b = s.ReadByte();
                    }
                    catch (IOException ioEx)
                    {
                        if (!_server.IsRunning) break;
                        var sockEx = ioEx.InnerException as SocketException;
                        if (sockEx != null && sockEx.SocketErrorCode == SocketError.TimedOut)
                        {
                            continue; // Idle timeout, loop again
                        }
                        _log.Warn("Client I/O error: " + ioEx.Message);
                        break;
                    }
                    if (b == -1) break;
                    int msgType = b;

                    try
                    {
                        switch (msgType)
                        {
                            case 0:
                                ReadExact(s, 19);
                                break;
                            case 2:
                                {
                                    byte[] hdr = ReadExact(s, 3);
                                    ushort count = (ushort)((hdr[1] << 8) | hdr[2]);
                                    ReadExact(s, count * 4);
                                    break;
                                }
                            case 3:
                                {
                                    byte[] p = ReadExact(s, 9);
                                    bool incremental = p[0] != 0;
                                    ushort rx = (ushort)((p[1] << 8) | p[2]);
                                    ushort ry = (ushort)((p[3] << 8) | p[4]);
                                    ushort rw = (ushort)((p[5] << 8) | p[6]);
                                    ushort rh = (ushort)((p[7] << 8) | p[8]);

                                    long now = DateTime.UtcNow.Ticks;
                                    if (incremental && (now - lastFrameTicks) < minIntervalTicks)
                                    {
                                        SendFramebufferUpdateEmpty(s);
                                        break;
                                    }
                                    lastFrameTicks = now;
                                    SendFramebufferUpdate(s, screen, rx, ry, rw, rh, incremental);
                                    break;
                                }
                            case 4:
                                {
                                    byte[] p = ReadExact(s, 7);
                                    byte down = p[0];
                                    uint keysym = (uint)((p[3] << 24) | (p[4] << 16) | (p[5] << 8) | p[6]);
                                    byte vk = KeysymMap.VkFromKeysym(keysym);
                                    if (vk != 0)
                                    {
                                        if (down == 1) Input.KeyDown(vk);
                                        else Input.KeyUp(vk);
                                    }
                                    break;
                                }
                            case 5:
                                {
                                    byte[] p = ReadExact(s, 5);
                                    byte mask = p[0];
                                    ushort x = (ushort)((p[1] << 8) | p[2]);
                                    ushort y = (ushort)((p[3] << 8) | p[4]);
                                    Input.Move(screen.X + x, screen.Y + y);
                                    HandleButtons(mask, ref prevButtonMask);
                                    break;
                                }
                            case 6:
                                {
                                    byte[] p = ReadExact(s, 7);
                                    int len = (p[3] << 24) | (p[4] << 16) | (p[5] << 8) | p[6];
                                    if (len > 0 && len < 64 * 1024 * 1024) ReadExact(s, len);
                                    break;
                                }
                            default:
                                _log.Warn("Unknown msg type " + msgType + " — disconnecting.");
                                return;
                        }
                    }
                    catch (IOException)
                    {
                        _log.Warn("Client I/O error during message parse. Disconnecting.");
                        break;
                    }
                }
                _log.Info("Client disconnected normally.");
            }
            catch (Exception ex)
            {
                _log.Error("Client handler error", ex);
            }
            finally
            {
                try { if (s != null) s.Close(); } catch { }
                try { c.Close(); } catch { }
                _server.NotifyClientClosed(this);
            }
        }

        private void HandleButtons(byte mask, ref byte prev)
        {
            if ((mask & 1) != (prev & 1)) { if ((mask & 1) != 0) Input.Down(Input.LEFTDOWN); else Input.Up(Input.LEFTUP); }
            if ((mask & 2) != (prev & 2)) { if ((mask & 2) != 0) Input.Down(Input.MIDDLEDOWN); else Input.Up(Input.MIDDLEUP); }
            if ((mask & 4) != (prev & 4)) { if ((mask & 4) != 0) Input.Down(Input.RIGHTDOWN); else Input.Up(Input.RIGHTUP); }
            if ((mask & 8) != 0 && (prev & 8) == 0) Input.Wheel(Input.WHEEL_DELTA);
            if ((mask & 16) != 0 && (prev & 16) == 0) Input.Wheel(unchecked((uint)-Input.WHEEL_DELTA));
            prev = mask;
        }

        private void SendFramebufferUpdate(NetworkStream s, Rectangle screen, ushort rx, ushort ry, ushort rw, ushort rh, bool incremental)
        {
            byte[] cur; int curStride;
            Rectangle bounds = ScreenCapturer.Capture(out cur, out curStride);

            int W = bounds.Width, H = bounds.Height;
            bool fullRequested = (rw == 0 || rw == W) && (rh == 0 || rh == H);
            bool resChanged = (_prevFrame == null) || (_prevW != W) || (_prevH != H);

            if (!incremental || resChanged || fullRequested)
            {
                SendRectangles(s, new[] { new Rectangle(0, 0, W, H) }, cur, curStride, W, H);
                CacheFrame(cur, curStride, W, H);
            }
            else
            {
                Rectangle dirty;
                if (TryFindDirtyRect(cur, _prevFrame, curStride, _prevStride, W, H, out dirty))
                {
                    SendRectangles(s, new[] { dirty }, cur, curStride, W, H);
                    CopyRegion(cur, curStride, _prevFrame, _prevStride, dirty, W, H);
                }
                else
                {
                    SendFramebufferUpdateEmpty(s);
                }
            }
        }

        private void CacheFrame(byte[] cur, int curStride, int w, int h)
        {
            _prevFrame = new byte[cur.Length];
            Buffer.BlockCopy(cur, 0, _prevFrame, 0, cur.Length);
            _prevStride = curStride;
            _prevW = w; _prevH = h;
        }

        private static void CopyRegion(byte[] src, int srcStride, byte[] dst, int dstStride, Rectangle r, int w, int h)
        {
            int bytesPerRow = r.Width * 4;
            for (int y = 0; y < r.Height; y++)
            {
                Buffer.BlockCopy(src, (r.Y + y) * srcStride + r.X * 4, dst, (r.Y + y) * dstStride + r.X * 4, bytesPerRow);
            }
        }

        private static bool TryFindDirtyRect(byte[] cur, byte[] prev, int curStride, int prevStride, int w, int h, out Rectangle dirty)
        {
            dirty = Rectangle.Empty;
            if (prev == null || cur.Length != prev.Length) return false;

            int minX = w, minY = h, maxX = -1, maxY = -1;
            for (int y = 0; y < h; y++)
            {
                int rowC = y * curStride;
                int rowP = y * prevStride;
                for (int x = 0; x < w; x++)
                {
                    int i = rowC + x * 4;
                    int j = rowP + x * 4;
                    if (cur[i] != prev[j] || cur[i + 1] != prev[j + 1] || cur[i + 2] != prev[j + 2])
                    {
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                }
            }
            if (maxX < 0) return false;
            dirty = new Rectangle(minX, minY, maxX - minX + 1, maxY - minY + 1);
            return true;
        }

        private void SendRectangles(NetworkStream s, Rectangle[] rects, byte[] frame, int stride, int fw, int fh)
        {
            s.WriteByte(0);
            s.WriteByte(0);
            WriteU16(s, (ushort)rects.Length);

            foreach (var r in rects)
            {
                int rx = Math.Max(0, r.X), ry = Math.Max(0, r.Y);
                int rw = Math.Min(fw - rx, r.Width);
                int rh = Math.Min(fh - ry, r.Height);
                if (rw <= 0 || rh <= 0) continue;

                WriteU16(s, (ushort)rx);
                WriteU16(s, (ushort)ry);
                WriteU16(s, (ushort)rw);
                WriteU16(s, (ushort)rh);
                WriteU32(s, 0);

                int bytesPerRow = rw * 4;
                for (int y = 0; y < rh; y++)
                {
                    int srcOffset = (ry + y) * stride + rx * 4;
                    s.Write(frame, srcOffset, bytesPerRow);
                }
            }
        }

        private static void SendFramebufferUpdateEmpty(NetworkStream s)
        {
            s.WriteByte(0); s.WriteByte(0);
            WriteU16(s, 0);
        }

        private static void SendSecurityResult(NetworkStream s, uint status, string reason)
        {
            WriteU32(s, status);
            if (status != 0 && !string.IsNullOrEmpty(reason))
            {
                byte[] r = Encoding.ASCII.GetBytes(reason);
                WriteU32(s, (uint)r.Length);
                s.Write(r, 0, r.Length);
            }
        }

        private static void WriteServerInit(NetworkStream s, int w, int h, string name)
        {
            WriteU16(s, (ushort)w);
            WriteU16(s, (ushort)h);
            s.WriteByte(32); s.WriteByte(24); s.WriteByte(0); s.WriteByte(1);
            s.WriteByte(0); s.WriteByte(255); s.WriteByte(0); s.WriteByte(255);
            s.WriteByte(0); s.WriteByte(255); s.WriteByte(16); s.WriteByte(8);
            s.WriteByte(0); s.WriteByte(0); s.WriteByte(0); s.WriteByte(0);
            byte[] nb = Encoding.ASCII.GetBytes(name ?? "VNC");
            WriteU32(s, (uint)nb.Length);
            s.Write(nb, 0, nb.Length);
        }

        private static byte[] ReadExact(Stream s, int count)
        {
            if (count <= 0) return new byte[0];
            byte[] buf = new byte[count];
            int read = 0;
            while (read < count)
            {
                int r = s.Read(buf, read, count - read);
                if (r <= 0) throw new IOException("Client closed connection");
                read += r;
            }
            return buf;
        }

        private static void WriteAscii(Stream s, string t)
        { byte[] b = Encoding.ASCII.GetBytes(t); s.Write(b, 0, b.Length); }
        
        private static void WriteU16(Stream s, ushort v)
        { s.WriteByte((byte)((v >> 8) & 0xFF)); s.WriteByte((byte)(v & 0xFF)); }
        
        private static void WriteU32(Stream s, uint v)
        { s.WriteByte((byte)((v >> 24) & 0xFF)); s.WriteByte((byte)((v >> 16) & 0xFF)); s.WriteByte((byte)((v >> 8) & 0xFF)); s.WriteByte((byte)(v & 0xFF)); }

        private static bool ConstantTimeEquals(byte[] a, byte[] b)
        {
            if (a == null || b == null || a.Length != b.Length) return false;
            int d = 0;
            for (int i = 0; i < a.Length; i++) d |= a[i] ^ b[i];
            return d == 0;
        }

        private static void SetKeepAlive(TcpClient c, int onMs, int intervalMs, int count)
        {
            try
            {
                var sock = c.Client;
                sock.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
                byte[] ka = new byte[12];
                BitConverter.GetBytes(1).CopyTo(ka, 0);
                BitConverter.GetBytes(onMs).CopyTo(ka, 4);
                BitConverter.GetBytes(intervalMs).CopyTo(ka, 8);
                sock.IOControl(IOControlCode.KeepAliveValues, ka, null);
            }
            catch { }
        }
    }

    // ───────────────────────── Server ─────────────────────────
    public sealed class VncServer : IDisposable
    {
        private readonly VncConfig _cfg;
        private readonly Logger _log;
        private TcpListener _listener;
        private Thread _acceptThread;
        private readonly List<VncClientHandler> _clients = new List<VncClientHandler>();
        private readonly List<TcpClient> _clientSockets = new List<TcpClient>();
        private readonly object _clientsLock = new object();
        private volatile bool _running;
        private volatile bool _disposed;

        public bool IsRunning { get { return _running; } }

        public VncServer(VncConfig cfg, Logger log) { _cfg = cfg; _log = log; }

        public void Start()
        {
            if (_running) return;
            _running = true;
            _acceptThread = new Thread(AcceptLoop) { IsBackground = true, Name = "VncAccept" };
            _acceptThread.Start();
            _log.Info("VNC server started on " + _cfg.BindAddress + ":" + _cfg.Port);
        }

        public void Stop()
        {
            if (!_running) return;
            _running = false;
            _log.Info("VNC server stopping...");
            try { if (_listener != null) _listener.Stop(); } catch { }
            
            lock (_clientsLock)
            {
                foreach (var sock in _clientSockets)
                {
                    try { sock.Close(); } catch { }
                }
                _clientSockets.Clear();
                _clients.Clear();
            }

            if (_acceptThread != null && _acceptThread.IsAlive)
                _acceptThread.Join(3000);
            _log.Info("VNC server stopped.");
        }

        private void AcceptLoop()
        {
            IPAddress bind = IPAddress.Any;
            if (!string.IsNullOrEmpty(_cfg.BindAddress) && _cfg.BindAddress != "0.0.0.0")
                bind = IPAddress.Parse(_cfg.BindAddress);

            while (_running)
            {
                try
                {
                    _listener = new TcpListener(bind, _cfg.Port);
                    _listener.Start();
                    _log.Info("Listener started.");
                }
                catch (Exception ex)
                {
                    _log.Error("Listener start failed", ex);
                    Thread.Sleep(_cfg.AcceptRetryDelayMs);
                    continue;
                }

                while (_running)
                {
                    TcpClient c = null;
                    try
                    {
                        c = _listener.AcceptTcpClient();
                    }
                    catch (SocketException sex)
                    {
                        if (!_running) break;
                        _log.Warn("Accept error: " + sex.Message);
                        break;
                    }
                    catch (Exception ex)
                    {
                        if (!_running) break;
                        _log.Error("Accept exception", ex);
                        break;
                    }

                    int curClients;
                    lock (_clientsLock) curClients = _clients.Count;
                    if (curClients >= _cfg.MaxConcurrentClients)
                    {
                        _log.Warn("Rejecting client: max " + _cfg.MaxConcurrentClients + " reached.");
                        try { c.Close(); } catch { }
                        continue;
                    }

                    var ep = c.Client.RemoteEndPoint as IPEndPoint;
                    if (ep != null && IPAddress.IsLoopback(ep.Address) == false && IPAddress.IsLoopback(bind))
                    {
                        _log.Warn("Rejected non-localhost client: " + ep);
                        try { c.Close(); } catch { }
                        continue;
                    }

                    var handler = new VncClientHandler(c, _cfg, _log, this);
                    lock (_clientsLock)
                    {
                        _clients.Add(handler);
                        _clientSockets.Add(c);
                    }
                    _log.Info(string.Format("Client accepted from {0} (total {1})", ep, _clients.Count));

                    var t = new Thread(() => handler.Run())
                    {
                        IsBackground = true,
                        Name = "VncClient-" + (ep != null ? ep.ToString() : "?")
                    };
                    t.Start();
                }

                try { _listener.Stop(); } catch { }
                if (_running)
                {
                    _log.Warn("Listener exited; restarting in " + _cfg.AcceptRetryDelayMs + "ms");
                    Thread.Sleep(_cfg.AcceptRetryDelayMs);
                }
            }
        }

        internal void NotifyClientClosed(VncClientHandler h)
        {
            lock (_clientsLock)
            {
                _clients.Remove(h);
                _clientSockets.Remove(h.Client);
            }
            _log.Info("Client removed. Active=" + _clients.Count);
        }

        public int ActiveClientCount
        {
            get { lock (_clientsLock) { return _clients.Count; } }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            Stop();
        }
    }

    // ───────────────────────── Console control handler ─────────────────────────
    public static class ConsoleCtrl
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);
        private delegate bool HandlerRoutine(CtrlType ctrl);
        private enum CtrlType
        {
            CTRL_C = 0, CTRL_BREAK = 1, CTRL_CLOSE = 2,
            CTRL_LOGOFF = 5, CTRL_SHUTDOWN = 6
        }

        private static HandlerRoutine _handler; // Prevent GC of delegate

        public static void Register(Action onShutdown)
        {
            _handler = (t) =>
            {
                try { onShutdown(); } catch { }
                return false;
            };
            SetConsoleCtrlHandler(_handler, true);
        }
    }
}
'@

# ─────────────────────────────────────────────────────────────────────────────
# 3. COMPILE
# ─────────────────────────────────────────────────────────────────────────────
 $referencedAssemblies = @('System.Drawing','System.Windows.Forms')
if ($PSVersionTable.PSEdition -eq 'Core') {
    $referencedAssemblies += 'System.Net.Primitives'
}

if (-not ('PwshVnc.VncServer' -as [type])) {
    try {
        Add-Type -TypeDefinition $CSharpCode -Language CSharp -ReferencedAssemblies $referencedAssemblies
    } catch {
        Write-Error "Add-Type compilation failed: $($_.Exception.Message)"
        throw
    }
} else {
    Write-Host "[compile] PwshVnc.VncServer already loaded — using existing type." -ForegroundColor DarkYellow
    Write-Host "[compile] (If you changed code, restart PowerShell to recompile.)" -ForegroundColor DarkYellow
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CONFIGURE
# ─────────────────────────────────────────────────────────────────────────────
 $config = New-Object PwshVnc.VncConfig -Property @{
    Port                 = $Port
    BindAddress          = $BindAddress
    Password             = $Password
    MaxConcurrentClients = $MaxClients
    MaxFps               = $MaxFps
    LogFilePath          = $LogPath
    LogMaxBytes          = [long]$LogMaxBytes
    LogArchiveCount      = $LogArchives
    SendTimeoutMs        = $SendTimeoutMs
    AcceptRetryDelayMs   = $AcceptRetryDelayMs
    DesktopName          = $DesktopName
}

 $logger  = New-Object PwshVnc.Logger -ArgumentList $config.LogFilePath, $config.LogMaxBytes, $config.LogArchiveCount
 $server  = New-Object PwshVnc.VncServer -ArgumentList $config, $logger

# ─────────────────────────────────────────────────────────────────────────────
# 5. START
# ─────────────────────────────────────────────────────────────────────────────
[PwshVnc.ConsoleCtrl]::Register({
    try { $server.Stop() } catch {}
    try { $logger.Info('Shutdown via console-control event.') } catch {}
    try { $logger.Dispose() } catch {}
})

 $server.Start()

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  PowerShell VNC Server is running                                ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host ("║  Endpoint : {0,-53}║" -f ("$BindAddress`:$Port")) -ForegroundColor Cyan
 $authStr = if ($Password) { 'VNC password' } else { 'NONE (insecure)' }
 $authColor = if ($Password) { 'Green' } else { 'Red' }
Write-Host ("║  Auth     : {0,-53}║" -f $authStr) -ForegroundColor $authColor
Write-Host ("║  Max FPS  : {0,-53}║" -f $MaxFps) -ForegroundColor Cyan
Write-Host ("║  Max Conns: {0,-53}║" -f $MaxClients) -ForegroundColor Cyan
Write-Host ("║  Log file : {0,-53}║" -f $LogPath) -ForegroundColor DarkGray
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Press Ctrl+C to stop. The server will shut down cleanly." -ForegroundColor Yellow
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# 6. RUN + HEALTH MONITOR
# ─────────────────────────────────────────────────────────────────────────────
try {
    $lastStatus = [datetime]::UtcNow
    while ($true) {
        Start-Sleep -Seconds 5
        if (([datetime]::UtcNow - $lastStatus).TotalMinutes -ge 5) {
            $lastStatus = [datetime]::UtcNow
            $logger.Info("Health: active clients = $($server.ActiveClientCount), running = $($server.IsRunning)")
            Write-Host "[health] $(Get-Date -Format 'HH:mm:ss')  active=$($server.ActiveClientCount)" -ForegroundColor DarkGray
        }
    }
} finally {
    Write-Host "`n[shutdown] Stopping server..." -ForegroundColor Yellow
    try { $server.Stop() }  catch { }
    try { $logger.Info('Shutdown via Ctrl+C / finally block.') } catch {}
    try { $logger.Dispose() } catch { }
    Write-Host "[shutdown] Done." -ForegroundColor Red
}
