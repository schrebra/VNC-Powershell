<#
.SYNOPSIS
    Interactive VNC Client GUI - PowerShell 5.1 / WPF / XAML
.DESCRIPTION
    Full remote desktop control over VNC (RFB 003.008).
    Features: multi-session, fit-to-window, fullscreen with auto-hide bar,
    session panel with pin/rename, stats, VNC settings, clipboard transfer
    via typing emulation, password visibility toggle, per-session password saving.
#>

# ============================================================
# CONFIGURATION
# ============================================================
 $DefaultHost        = "10.80.10.187"
 $DefaultPort        = "5900"
 $DefaultPassword    = "Admin1!Ad"
 $SessionHistoryFile = [System.IO.Path]::Combine($env:APPDATA, "VncClient_Sessions.json")
 $SettingsFile       = [System.IO.Path]::Combine($env:APPDATA, "VncClient_Settings.json")

# ============================================================
# ASSEMBLIES
# ============================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

# ============================================================
# VNC PROTOCOL ENGINE
# ============================================================
 $VncEngineCode = @'
using System;
using System.IO;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading.Tasks;

public class VncEngine : IDisposable
{
    private TcpClient _tcp;
    private NetworkStream _stream;
    private string _host;
    private int _port;
    private string _password;
    private volatile bool _connected;
    private volatile bool _running;
    private Thread _readThread;
    private object _writeLock = new object();
    private object _bufferLock = new object();

    private int _fbWidth;
    private int _fbHeight;
    private byte[] _frameBuffer;
    private string _desktopName;
    private string _lastError;
    private volatile int _frameVersion;

    private long _bytesReceived;
    private int _frameCount;
    private Stopwatch _connTimer;
    private Stopwatch _fpsTimer;
    private int _fpsFrameCount;
    private double _currentFps;
    private long _lastPingMs;

    private bool _viewOnly;
    private bool _sharedConnection;
    private bool _clipboardSync;
    private string _lastSentClipboard;

    private string _serverClipboard;
    private volatile bool _hasNewServerClipboard;

    public int FramebufferWidth  { get { return _fbWidth; } }
    public int FramebufferHeight { get { return _fbHeight; } }
    public string DesktopName    { get { return _desktopName; } }
    public string LastError      { get { return _lastError; } }
    public bool IsConnected      { get { return _connected; } }
    public int FrameVersion      { get { return _frameVersion; } }
    public string Host           { get { return _host; } }
    public int Port              { get { return _port; } }

    public long BytesReceived    { get { return _bytesReceived; } }
    public int FrameCount        { get { return _frameCount; } }
    public double CurrentFps     { get { return _currentFps; } }
    public long UptimeMs         { get { return _connTimer != null ? _connTimer.ElapsedMilliseconds : 0; } }
    public long LastPingMs       { get { return _lastPingMs; } }
    public bool ViewOnly         { get { return _viewOnly; } set { _viewOnly = value; } }
    public bool SharedConnection { get { return _sharedConnection; } }
    public bool ClipboardSync    { get { return _clipboardSync; } set { _clipboardSync = value; } }

    public string ServerClipboard { get { return _serverClipboard; } }
    public bool HasNewServerClipboard { get { return _hasNewServerClipboard; } set { _hasNewServerClipboard = value; } }

    public ConcurrentQueue<byte[]> OutQueue = new ConcurrentQueue<byte[]>();

    public VncEngine()
    {
        _sharedConnection = true;
        _viewOnly = false;
        _clipboardSync = true;
    }

    public byte[] GetFrameBufferDirect() { return _frameBuffer; }

    private static byte ReverseBits(byte b)
    {
        byte r = 0;
        for (int i = 0; i < 8; i++) r = (byte)((r << 1) | ((b >> i) & 1));
        return r;
    }

    private void ReadExact(byte[] buf, int offset, int count)
    {
        int total = 0;
        while (total < count)
        {
            int n = _stream.Read(buf, offset + total, count - total);
            if (n == 0) throw new IOException("Connection closed");
            total += n;
            _bytesReceived += n;
        }
    }

    private byte[] ReadExact(int count)
    {
        byte[] buf = new byte[count];
        ReadExact(buf, 0, count);
        return buf;
    }

    private int ReadU8()
    {
        int b = _stream.ReadByte();
        if (b < 0) throw new IOException("Connection closed");
        _bytesReceived++;
        return b;
    }

    private int ReadU16BE()
    {
        byte[] b = ReadExact(2);
        return (b[0] << 8) | b[1];
    }

    private uint ReadU32BE()
    {
        byte[] b = ReadExact(4);
        return (uint)((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]);
    }

    private int ReadS32BE() { return (int)ReadU32BE(); }

    public bool Connect(string host, int port, string password,
                        bool shared, bool viewOnly, bool clipSync)
    {
        _host = host; _port = port; _password = password;
        _lastError = null; _bytesReceived = 0; _frameCount = 0;
        _currentFps = 0; _fpsFrameCount = 0;
        _sharedConnection = shared;
        _viewOnly = viewOnly;
        _clipboardSync = clipSync;
        _serverClipboard = null;
        _hasNewServerClipboard = false;
        _lastSentClipboard = null;

        try
        {
            Stopwatch pingTimer = Stopwatch.StartNew();
            _tcp = new TcpClient();
            _tcp.ReceiveBufferSize = 8 * 1024 * 1024;
            _tcp.NoDelay = true;

            // Async connect with 8s timeout – prevents UI freezes on unreachable hosts
            System.Threading.Tasks.Task connectTask = _tcp.ConnectAsync(host, port);
            if (!connectTask.Wait(8000))
            {
                try { _tcp.Close(); } catch { }
                _lastError = "Connection timed out – host unreachable after 8 seconds";
                return false;
            }
            if (connectTask.IsFaulted)
            {
                Exception baseEx = connectTask.Exception != null
                    ? connectTask.Exception.GetBaseException()
                    : null;
                try { _tcp.Close(); } catch { }
                _lastError = baseEx != null ? baseEx.Message : "Connection failed";
                return false;
            }

            _stream = _tcp.GetStream();
            _stream.ReadTimeout  = 30000;
            _stream.WriteTimeout = 10000;
            _lastPingMs = pingTimer.ElapsedMilliseconds;

            ReadExact(12);
            _stream.Write(Encoding.ASCII.GetBytes("RFB 003.008\n"), 0, 12);

            int secCount = ReadU8();
            byte[] secTypes = ReadExact(secCount);
            bool hasVncAuth = false, hasNone = false;
            for (int i = 0; i < secCount; i++)
            {
                if (secTypes[i] == 2) hasVncAuth = true;
                if (secTypes[i] == 1) hasNone    = true;
            }

            if (hasVncAuth)
            {
                _stream.WriteByte(2);
                byte[] challenge = ReadExact(16);
                byte[] key = new byte[8];
                byte[] pass = Encoding.ASCII.GetBytes(password ?? "");
                for (int i = 0; i < 8; i++)
                    key[i] = i < pass.Length ? ReverseBits(pass[i]) : (byte)0;

                DES des = DES.Create();
                des.Mode = CipherMode.ECB; des.Padding = PaddingMode.None; des.Key = key;
                ICryptoTransform enc = des.CreateEncryptor();
                byte[] resp = new byte[16];
                enc.TransformBlock(challenge, 0, 8, resp, 0);
                enc.TransformBlock(challenge, 8, 8, resp, 8);
                _stream.Write(resp, 0, 16);
                enc.Dispose(); des.Dispose();
            }
            else if (hasNone) { _stream.WriteByte(1); }
            else { _lastError = "No supported security type"; return false; }

            uint authResult = ReadU32BE();
            if (authResult != 0) { _lastError = "Auth failed (code=" + authResult + ")"; return false; }

            _stream.WriteByte((byte)(shared ? 1 : 0));

            _fbWidth  = ReadU16BE();
            _fbHeight = ReadU16BE();
            byte[] pf = ReadExact(16);
            uint nameLen = ReadU32BE();
            _desktopName = Encoding.ASCII.GetString(ReadExact((int)nameLen));

            lock (_bufferLock) { _frameBuffer = new byte[_fbWidth * _fbHeight * 4]; }

            byte[] spf = new byte[20];
            spf[0] = 0;
            Array.Copy(pf, 0, spf, 4, 16);
            _stream.Write(spf, 0, 20);

            byte[] encMsg = new byte[16];
            encMsg[0] = 2;
            encMsg[2] = 0; encMsg[3] = 3;
            encMsg[4]=0; encMsg[5]=0; encMsg[6]=0; encMsg[7]=0;
            encMsg[8]=0; encMsg[9]=0; encMsg[10]=0; encMsg[11]=1;
            encMsg[12]=0xFF; encMsg[13]=0xFF; encMsg[14]=0xFF; encMsg[15]=0x21;
            _stream.Write(encMsg, 0, 16);

            _connected = true; _running = true;
            _connTimer = Stopwatch.StartNew();
            _fpsTimer  = Stopwatch.StartNew();

            _readThread = new Thread(ReadLoop);
            _readThread.IsBackground = true;
            _readThread.Name = "VNC-Read";
            _readThread.Start();
            return true;
        }
        catch (Exception ex) { _lastError = ex.Message; return false; }
    }

    public bool Connect(string host, int port, string password)
    {
        return Connect(host, port, password, true, false, true);
    }

    private void SendFBUpdateRequest(bool incremental)
    {
        byte[] req = new byte[10];
        req[0] = 3; req[1] = (byte)(incremental ? 1 : 0);
        req[6] = (byte)((_fbWidth  >> 8) & 0xFF); req[7] = (byte)(_fbWidth  & 0xFF);
        req[8] = (byte)((_fbHeight >> 8) & 0xFF); req[9] = (byte)(_fbHeight & 0xFF);
        lock (_writeLock) { try { if (_stream != null && _connected) _stream.Write(req, 0, 10); } catch { } }
    }

    private void CopyRectData(byte[] data, int rx, int ry, int rw, int rh)
    {
        lock (_bufferLock)
        {
            byte[] fb = _frameBuffer;
            if (fb == null) return;
            for (int row = 0; row < rh; row++)
            {
                int dy = ry + row;
                if (dy < 0 || dy >= _fbHeight) continue;
                int cols = Math.Min(rw, _fbWidth - rx);
                if (cols <= 0) continue;
                int bytes = cols * 4;
                int srcOff = row * rw * 4;
                int dstOff = dy * _fbWidth * 4 + rx * 4;
                if (srcOff + bytes > data.Length || dstOff + bytes > fb.Length) continue;
                Array.Copy(data, srcOff, fb, dstOff, bytes);
            }
        }
    }

    private void HandleCopyRectEncoding(int rx, int ry, int rw, int rh)
    {
        int srcX = ReadU16BE();
        int srcY = ReadU16BE();
        lock (_bufferLock)
        {
            byte[] fb = _frameBuffer;
            if (fb == null) return;
            byte[] temp = new byte[rw * rh * 4];
            for (int row = 0; row < rh; row++)
            {
                int sy = srcY + row;
                if (sy < 0 || sy >= _fbHeight) continue;
                int cols = Math.Min(rw, _fbWidth - srcX);
                if (cols <= 0) continue;
                int srcOff = sy * _fbWidth * 4 + srcX * 4;
                int tmpOff = row * rw * 4;
                int bytes = cols * 4;
                if (srcOff + bytes <= fb.Length && tmpOff + bytes <= temp.Length)
                    Array.Copy(fb, srcOff, temp, tmpOff, bytes);
            }
            CopyRectData(temp, rx, ry, rw, rh);
        }
    }

    public void SendClientCutText(string text)
    {
        SendClientCutText(text, false);
    }

    public void SendClientCutText(string text, bool force)
    {
        if (!_connected || text == null || text.Length == 0) return;
        if (!force && text == _lastSentClipboard) return;
        _lastSentClipboard = text;

        byte[] textBytes = Encoding.GetEncoding(28591).GetBytes(text);
        int len = textBytes.Length;
        byte[] msg = new byte[8 + len];
        msg[0] = 6;
        msg[4] = (byte)((len >> 24) & 0xFF);
        msg[5] = (byte)((len >> 16) & 0xFF);
        msg[6] = (byte)((len >> 8) & 0xFF);
        msg[7] = (byte)(len & 0xFF);
        Array.Copy(textBytes, 0, msg, 8, len);
        lock (_writeLock)
        {
            try { if (_stream != null && _connected) _stream.Write(msg, 0, msg.Length); } catch { }
        }
    }

    public void SendTextViaKeysAsync(string text)
    {
        if (!_connected || _viewOnly || string.IsNullOrEmpty(text)) return;

        Thread t = new Thread(() => {
            // Release all modifier keys to ensure the remote OS doesn't think they are held down
            uint[] mods = { 0xFFE1, 0xFFE2, 0xFFE3, 0xFFE4, 0xFFE9, 0xFFEA, 0xFFEB, 0xFFEC };
            foreach (uint m in mods) SendKey(m, false);
            Thread.Sleep(50);

            foreach (char c in text)
            {
                if (!_connected) return;
                uint sym;
                if (c == '\r') continue;
                if (c == '\n') sym = 0xFF0D; // Return
                else if (c == '\t') sym = 0xFF09; // Tab
                else if (c < 0x100) sym = (uint)c; // Latin1
                else sym = 0x01000000 + (uint)c; // Unicode

                SendKey(sym, true);
                Thread.Sleep(5);
                SendKey(sym, false);
                Thread.Sleep(5);
            }

            // Release all modifier keys again just in case
            foreach (uint m in mods) SendKey(m, false);
        });
        t.IsBackground = true;
        t.Start();
    }

    private void ReadLoop()
    {
        try
        {
            SendFBUpdateRequest(false);
            while (_running && _connected)
            {
                byte[] outMsg;
                while (OutQueue.TryDequeue(out outMsg))
                    lock (_writeLock) { try { if (_stream != null && _connected) _stream.Write(outMsg, 0, outMsg.Length); } catch { } }

                if (!_stream.DataAvailable) { Thread.Sleep(5); continue; }

                int msgType = ReadU8();
                switch (msgType)
                {
                    case 0:
                        ReadU8();
                        int numRects = ReadU16BE();
                        for (int r = 0; r < numRects; r++)
                        {
                            int rx = ReadU16BE(), ry = ReadU16BE(),
                                rw = ReadU16BE(), rh = ReadU16BE();
                            int encType = ReadS32BE();
                            if (encType == 0) // Raw
                            {
                                if (rw > 0 && rh > 0) CopyRectData(ReadExact(rw * rh * 4), rx, ry, rw, rh);
                            }
                            else if (encType == 1) // CopyRect
                            {
                                HandleCopyRectEncoding(rx, ry, rw, rh);
                            }
                            else if (encType == -223 || encType == -239) // DesktopSize
                            {
                                lock (_bufferLock)
                                {
                                    _fbWidth = rw; _fbHeight = rh;
                                    _frameBuffer = new byte[rw * rh * 4];
                                }
                            }
                            else break;
                        }
                        _frameVersion++; _frameCount++; _fpsFrameCount++;
                        if (_fpsTimer.ElapsedMilliseconds >= 1000)
                        {
                            _currentFps = _fpsFrameCount * 1000.0 / _fpsTimer.ElapsedMilliseconds;
                            _fpsFrameCount = 0; _fpsTimer.Restart();
                        }
                        SendFBUpdateRequest(true);
                        break;

                    case 1:
                        ReadU8(); ReadU16BE();
                        ReadExact(ReadU16BE() * 6);
                        break;

                    case 2:
                        break;

                    case 3:
                        ReadExact(3);
                        uint textLen = ReadU32BE();
                        if (textLen > 0 && textLen < 10 * 1024 * 1024)
                        {
                            byte[] textData = ReadExact((int)textLen);
                            if (_clipboardSync)
                            {
                                _serverClipboard = Encoding.GetEncoding(28591).GetString(textData);
                                _hasNewServerClipboard = true;
                            }
                        }
                        break;

                    default:
                        Thread.Sleep(10);
                        break;
                }
            }
        }
        catch (Exception ex)
        {
            if (_running) { _lastError = "Read error: " + ex.Message; _connected = false; }
        }
    }

    public void SendPointer(int bm, int x, int y)
    {
        if (!_connected || _viewOnly) return;
        OutQueue.Enqueue(new byte[] { 5, (byte)bm,
            (byte)((x>>8)&0xFF), (byte)(x&0xFF),
            (byte)((y>>8)&0xFF), (byte)(y&0xFF) });
    }

    public void SendKey(uint ks, bool down)
    {
        if (!_connected || _viewOnly) return;
        OutQueue.Enqueue(new byte[] { 4, (byte)(down?1:0), 0, 0,
            (byte)((ks>>24)&0xFF), (byte)((ks>>16)&0xFF),
            (byte)((ks>>8)&0xFF),  (byte)(ks&0xFF) });
    }

    public void RequestFullRefresh()
    {
        if (!_connected) return;
        byte[] req = new byte[10]; req[0]=3;
        req[6]=(byte)((_fbWidth >>8)&0xFF); req[7]=(byte)(_fbWidth &0xFF);
        req[8]=(byte)((_fbHeight>>8)&0xFF); req[9]=(byte)(_fbHeight&0xFF);
        OutQueue.Enqueue(req);
    }

    public void Disconnect()
    {
        _running = false; _connected = false;
        if (_connTimer != null) _connTimer.Stop();
        if (_fpsTimer  != null) _fpsTimer.Stop();
        try { if (_stream != null) _stream.Close(); } catch { }
        try { if (_tcp    != null) _tcp.Close();    } catch { }
    }

    public void Dispose() { Disconnect(); }
}
'@

 $KeysymMapCode = @'
using System.Collections.Generic;
using System.Windows.Input;

public static class KeysymMap
{
    private static Dictionary<Key,uint> _map;
    private static Dictionary<Key,uint> _shiftMap;

    static KeysymMap()
    {
        _map = new Dictionary<Key,uint>();
        _map[Key.F1]=0xFFBE;_map[Key.F2]=0xFFBF;_map[Key.F3]=0xFFC0;_map[Key.F4]=0xFFC1;
        _map[Key.F5]=0xFFC2;_map[Key.F6]=0xFFC3;_map[Key.F7]=0xFFC4;_map[Key.F8]=0xFFC5;
        _map[Key.F9]=0xFFC6;_map[Key.F10]=0xFFC7;_map[Key.F11]=0xFFC8;_map[Key.F12]=0xFFC9;
        _map[Key.LeftShift]=0xFFE1;_map[Key.RightShift]=0xFFE2;
        _map[Key.LeftCtrl]=0xFFE3;_map[Key.RightCtrl]=0xFFE4;
        _map[Key.LeftAlt]=0xFFE9;_map[Key.RightAlt]=0xFFEA;
        _map[Key.LWin]=0xFFEB;_map[Key.RWin]=0xFFEC;
        _map[Key.Return]=0xFF0D;_map[Key.Escape]=0xFF1B;
        _map[Key.Back]=0xFF08;_map[Key.Tab]=0xFF09;
        _map[Key.Delete]=0xFFFF;_map[Key.Insert]=0xFF63;
        _map[Key.Home]=0xFF50;_map[Key.End]=0xFF57;
        _map[Key.PageUp]=0xFF55;_map[Key.PageDown]=0xFF56;
        _map[Key.Up]=0xFF52;_map[Key.Down]=0xFF54;
        _map[Key.Left]=0xFF51;_map[Key.Right]=0xFF53;
        _map[Key.Space]=0x0020;_map[Key.CapsLock]=0xFFE5;
        _map[Key.NumLock]=0xFF7F;_map[Key.Scroll]=0xFF14;
        _map[Key.PrintScreen]=0xFF61;_map[Key.Pause]=0xFF13;
        _map[Key.OemMinus]=0x002D;_map[Key.OemPlus]=0x003D;
        _map[Key.OemOpenBrackets]=0x005B;_map[Key.OemCloseBrackets]=0x005D;
        _map[Key.OemPipe]=0x005C;_map[Key.OemSemicolon]=0x003B;
        _map[Key.OemQuotes]=0x0027;_map[Key.OemComma]=0x002C;
        _map[Key.OemPeriod]=0x002E;_map[Key.OemQuestion]=0x002F;
        _map[Key.OemTilde]=0x0060;
        _map[Key.A]=0x61;_map[Key.B]=0x62;_map[Key.C]=0x63;_map[Key.D]=0x64;
        _map[Key.E]=0x65;_map[Key.F]=0x66;_map[Key.G]=0x67;_map[Key.H]=0x68;
        _map[Key.I]=0x69;_map[Key.J]=0x6A;_map[Key.K]=0x6B;_map[Key.L]=0x6C;
        _map[Key.M]=0x6D;_map[Key.N]=0x6E;_map[Key.O]=0x6F;_map[Key.P]=0x70;
        _map[Key.Q]=0x71;_map[Key.R]=0x72;_map[Key.S]=0x73;_map[Key.T]=0x74;
        _map[Key.U]=0x75;_map[Key.V]=0x76;_map[Key.W]=0x77;_map[Key.X]=0x78;
        _map[Key.Y]=0x79;_map[Key.Z]=0x7A;
        _map[Key.D0]=0x30;_map[Key.D1]=0x31;_map[Key.D2]=0x32;_map[Key.D3]=0x33;
        _map[Key.D4]=0x34;_map[Key.D5]=0x35;_map[Key.D6]=0x36;_map[Key.D7]=0x37;
        _map[Key.D8]=0x38;_map[Key.D9]=0x39;
        _map[Key.NumPad0]=0xFFB0;_map[Key.NumPad1]=0xFFB1;_map[Key.NumPad2]=0xFFB2;
        _map[Key.NumPad3]=0xFFB3;_map[Key.NumPad4]=0xFFB4;_map[Key.NumPad5]=0xFFB5;
        _map[Key.NumPad6]=0xFFB6;_map[Key.NumPad7]=0xFFB7;_map[Key.NumPad8]=0xFFB8;
        _map[Key.NumPad9]=0xFFB9;_map[Key.Multiply]=0xFFAA;_map[Key.Add]=0xFFAB;
        _map[Key.Subtract]=0xFFAD;_map[Key.Decimal]=0xFFAE;_map[Key.Divide]=0xFFAF;

        _shiftMap = new Dictionary<Key,uint>();
        _shiftMap[Key.D1]=0x21;_shiftMap[Key.D2]=0x40;_shiftMap[Key.D3]=0x23;
        _shiftMap[Key.D4]=0x24;_shiftMap[Key.D5]=0x25;_shiftMap[Key.D6]=0x5E;
        _shiftMap[Key.D7]=0x26;_shiftMap[Key.D8]=0x2A;_shiftMap[Key.D9]=0x28;
        _shiftMap[Key.D0]=0x29;
        _shiftMap[Key.OemMinus]=0x5F;_shiftMap[Key.OemPlus]=0x2B;
        _shiftMap[Key.OemOpenBrackets]=0x7B;_shiftMap[Key.OemCloseBrackets]=0x7D;
        _shiftMap[Key.OemPipe]=0x7C;_shiftMap[Key.OemSemicolon]=0x3A;
        _shiftMap[Key.OemQuotes]=0x22;_shiftMap[Key.OemComma]=0x3C;
        _shiftMap[Key.OemPeriod]=0x3E;_shiftMap[Key.OemQuestion]=0x3F;
        _shiftMap[Key.OemTilde]=0x7E;
    }

    public static uint GetKeysym(Key key, bool shift)
    {
        if (shift && key >= Key.A && key <= Key.Z) return (uint)(0x41 + (key - Key.A));
        if (shift && _shiftMap.ContainsKey(key)) return _shiftMap[key];
        if (_map.ContainsKey(key)) return _map[key];
        return 0;
    }
}
'@

try { [VncEngine] | Out-Null } catch {
    Add-Type -TypeDefinition $VncEngineCode -ReferencedAssemblies @("System.dll") -Language CSharp
}
try { [KeysymMap] | Out-Null } catch {
    Add-Type -TypeDefinition $KeysymMapCode -ReferencedAssemblies @("PresentationCore","WindowsBase") -Language CSharp
}

# ============================================================
# XAML
# ============================================================
[xml]$Xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="VNC Remote Desktop"
    Width="1100" Height="720" MinWidth="700" MinHeight="500"
    WindowStartupLocation="CenterScreen" Background="#1E1E1E">

  <Window.Resources>
    <Style TargetType="Button" x:Key="ToolBtn">
      <Setter Property="Background" Value="#333333"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#555555"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,4"/>
      <Setter Property="Margin" Value="2"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#0078D4"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.4"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBox" x:Key="InputBox">
      <Setter Property="Background" Value="#2D2D30"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#555555"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="4,3"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="Label" x:Key="Lbl">
      <Setter Property="Foreground" Value="#CCCCCC"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Padding" Value="4,0"/>
    </Style>
  </Window.Resources>

  <Grid>
    <DockPanel x:Name="mainDock">
      <Border x:Name="toolbarBorder" DockPanel.Dock="Top" Background="#2D2D30"
              BorderBrush="#3F3F46" BorderThickness="0,0,0,1" Padding="4">
        <WrapPanel VerticalAlignment="Center">
          <Button x:Name="btnTogglePanel" Content="X  Close"
                  Style="{StaticResource ToolBtn}" Margin="2,2,8,2"
                  FontSize="14" FontWeight="Bold"/>
          <Border Width="1" Background="#3F3F46" Margin="4,2"/>
          <Label Content="Host:" Style="{StaticResource Lbl}"/>
          <TextBox x:Name="txtHost" Width="140"
                   Style="{StaticResource InputBox}" Text="$DefaultHost"/>
          <Label Content="Port:" Style="{StaticResource Lbl}"/>
          <TextBox x:Name="txtPort" Width="50"
                   Style="{StaticResource InputBox}" Text="$DefaultPort"/>
          <Label Content="Password:" Style="{StaticResource Lbl}"/>
          <Grid Width="134">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <PasswordBox x:Name="txtPassword" Grid.Column="0"
                         Background="#2D2D30" Foreground="White"
                         BorderBrush="#555555" BorderThickness="1,1,0,1"
                         Padding="4,3" FontSize="13"
                         VerticalContentAlignment="Center"/>
            <TextBox x:Name="txtPasswordVisible" Grid.Column="0" Visibility="Collapsed"
                     Background="#2D2D30" Foreground="White"
                     BorderBrush="#555555" BorderThickness="1,1,0,1"
                     Padding="4,3" FontSize="13"
                     VerticalContentAlignment="Center"/>
            <Button x:Name="btnTogglePw" Grid.Column="1"
                    Width="26" Background="#2D2D30" Foreground="#CCCCCC"
                    BorderBrush="#555555" BorderThickness="1"
                    FontSize="16" Cursor="Hand"
                    VerticalAlignment="Stretch" ToolTip="Show/Hide password"
                    Padding="0">&#x1F441;</Button>
          </Grid>
          <Button x:Name="btnConnect" Content="Connect"
                  Style="{StaticResource ToolBtn}" Margin="8,2,2,2"/>
          <Button x:Name="btnDisconnect" Content="Disconnect"
                  Style="{StaticResource ToolBtn}" IsEnabled="False"/>
          <Border Width="1" Background="#3F3F46" Margin="8,2"/>
          <Button x:Name="btnRefresh" Content="Refresh"
                  Style="{StaticResource ToolBtn}" IsEnabled="False"/>
          <Button x:Name="btnCtrlAltDel" Content="Ctrl+Alt+Del"
                  Style="{StaticResource ToolBtn}" IsEnabled="False"/>
          <Button x:Name="btnWinKey" Content="Win"
                  Style="{StaticResource ToolBtn}" IsEnabled="False"/>
          <Button x:Name="btnFitWindow" Content="Fit Window"
                  Style="{StaticResource ToolBtn}" IsEnabled="False"/>
          <Button x:Name="btnFullScreen" Content="Full Screen"
                  Style="{StaticResource ToolBtn}" IsEnabled="False"/>
          <Button x:Name="btnClipboard" Content="Clipboard"
                  Style="{StaticResource ToolBtn}" IsEnabled="False"/>
          <Button x:Name="btnSettings" Content="Settings"
                  Style="{StaticResource ToolBtn}"/>
        </WrapPanel>
      </Border>

      <Border x:Name="statsBorder" DockPanel.Dock="Bottom" Background="#1B1B1B"
              BorderBrush="#3F3F46" BorderThickness="0,1,0,0">
        <DockPanel>
          <Border DockPanel.Dock="Left" Background="#007ACC" Padding="10,4">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="statusDot" Width="8" Height="8"
                       Fill="#FF4444" Margin="0,0,6,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="txtStatus" Text="Disconnected"
                         Foreground="White" FontSize="12"
                         VerticalAlignment="Center" FontWeight="SemiBold"/>
            </StackPanel>
          </Border>
          <Border DockPanel.Dock="Right" Padding="10,4">
            <TextBlock x:Name="txtResolution" Text=""
                       Foreground="#888888" FontSize="11"
                       FontFamily="Consolas" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Orientation="Horizontal"
                      HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,3">
            <Border Background="#252526" CornerRadius="3" Padding="6,2" Margin="3,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="FPS: " Foreground="#888888" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock x:Name="txtFps" Text="--" Foreground="#4EC9B0" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center" MinWidth="28"/>
              </StackPanel>
            </Border>
            <Border Background="#252526" CornerRadius="3" Padding="6,2" Margin="3,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Frames: " Foreground="#888888" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock x:Name="txtFrames" Text="--" Foreground="#DCDCAA" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center" MinWidth="38"/>
              </StackPanel>
            </Border>
            <Border Background="#252526" CornerRadius="3" Padding="6,2" Margin="3,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Data: " Foreground="#888888" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock x:Name="txtData" Text="--" Foreground="#9CDCFE" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center" MinWidth="55"/>
              </StackPanel>
            </Border>
            <Border Background="#252526" CornerRadius="3" Padding="6,2" Margin="3,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Latency: " Foreground="#888888" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock x:Name="txtLatency" Text="--" Foreground="#CE9178" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center" MinWidth="38"/>
              </StackPanel>
            </Border>
            <Border Background="#252526" CornerRadius="3" Padding="6,2" Margin="3,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Uptime: " Foreground="#888888" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock x:Name="txtUptime" Text="--" Foreground="#C586C0" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center" MinWidth="50"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </DockPanel>
      </Border>

      <DockPanel>
        <Border x:Name="sidePanel" DockPanel.Dock="Left" Width="250"
                Background="#252526" BorderBrush="#3F3F46"
                BorderThickness="0,0,1,0" ClipToBounds="True">
          <DockPanel>
            <Border DockPanel.Dock="Top" Background="#333333"
                    Padding="10,8" BorderBrush="#3F3F46" BorderThickness="0,0,0,1">
              <DockPanel>
                <Button x:Name="btnClearHistory" Content="Clear" DockPanel.Dock="Right"
                        Background="#3F3F46" Foreground="#CCCCCC"
                        BorderBrush="#555555" BorderThickness="1"
                        FontSize="11" Padding="0" Width="45" Margin="0,0,2,0"
                        Cursor="Hand" VerticalAlignment="Center"
                        ToolTip="Clear all history"/>
                <TextBlock Text="Sessions" Foreground="White"
                           FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </DockPanel>
            </Border>
            <DockPanel DockPanel.Dock="Top">
              <Border DockPanel.Dock="Top" Background="#1E2A3A" Padding="10,5"
                      BorderBrush="#3F3F46" BorderThickness="0,0,0,1">
                <TextBlock Text="PINNED" Foreground="#66AAFF" FontSize="11" FontWeight="Bold"/>
              </Border>
              <ScrollViewer DockPanel.Dock="Top" VerticalScrollBarVisibility="Auto" MaxHeight="180">
                <StackPanel x:Name="pinnedSessionsList"/>
              </ScrollViewer>
            </DockPanel>
            <DockPanel DockPanel.Dock="Top">
              <Border DockPanel.Dock="Top" Background="#1E3A1E" Padding="10,5"
                      BorderBrush="#3F3F46" BorderThickness="0,0,0,1">
                <TextBlock Text="ACTIVE" Foreground="#88FF88" FontSize="11" FontWeight="Bold"/>
              </Border>
              <ScrollViewer DockPanel.Dock="Top" VerticalScrollBarVisibility="Auto" MaxHeight="200">
                <StackPanel x:Name="activeSessionsList"/>
              </ScrollViewer>
            </DockPanel>
            <DockPanel>
              <Border DockPanel.Dock="Top" Background="#2D2D30" Padding="10,5"
                      BorderBrush="#3F3F46" BorderThickness="0,1,0,0">
                <TextBlock Text="RECENT" Foreground="#888888" FontSize="11" FontWeight="Bold"/>
              </Border>
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="recentSessionsList"/>
              </ScrollViewer>
            </DockPanel>
          </DockPanel>
        </Border>

        <Border Background="#111111">
          <Grid>
            <ScrollViewer x:Name="scrollViewer"
                          HorizontalScrollBarVisibility="Auto"
                          VerticalScrollBarVisibility="Auto" Focusable="False">
              <Canvas x:Name="vncCanvas" Background="#000000"
                      ClipToBounds="True" Focusable="True">
                <Image x:Name="vncImage" Stretch="None"
                       RenderOptions.BitmapScalingMode="NearestNeighbor"/>
              </Canvas>
            </ScrollViewer>
            <Border x:Name="noConnectionOverlay" Background="#111111">
              <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                <TextBlock Text="No Active Connection"
                           FontSize="28" Foreground="#DDDDDD"
                           HorizontalAlignment="Center" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <Border Background="#0078D4" Width="60" Height="2"
                        HorizontalAlignment="Center" Margin="0,0,0,14"/>
                <TextBlock Text="Enter connection details above and click Connect, or press Enter"
                           FontSize="14" Foreground="#999999"
                           HorizontalAlignment="Center"/>
              </StackPanel>
            </Border>
          </Grid>
        </Border>
      </DockPanel>
    </DockPanel>

    <Border x:Name="fullscreenBar" VerticalAlignment="Top"
            HorizontalAlignment="Center" Height="0"
            Background="#DD2D2D30" CornerRadius="0,0,8,8"
            BorderBrush="#0078D4" BorderThickness="1,0,1,1"
            ClipToBounds="True" Panel.ZIndex="100">
      <StackPanel Orientation="Horizontal" Margin="12,6" VerticalAlignment="Center">
        <TextBlock x:Name="fsSessionName" Text="Session"
                   Foreground="White" FontSize="13" FontWeight="SemiBold"
                   VerticalAlignment="Center" Margin="0,0,16,0"/>
        <Button x:Name="btnFsWindowed" Content="Windowed"
                Background="#333333" Foreground="White" BorderBrush="#555555"
                Padding="10,4" Margin="2" FontSize="12" Cursor="Hand" BorderThickness="1"/>
        <Button x:Name="btnFsRefresh" Content="Refresh"
                Background="#333333" Foreground="White" BorderBrush="#555555"
                Padding="10,4" Margin="2" FontSize="12" Cursor="Hand" BorderThickness="1"/>
        <Button x:Name="btnFsCtrlAltDel" Content="Ctrl+Alt+Del"
                Background="#333333" Foreground="White" BorderBrush="#555555"
                Padding="10,4" Margin="2" FontSize="12" Cursor="Hand" BorderThickness="1"/>
        <Button x:Name="btnFsWinKey" Content="Win"
                Background="#333333" Foreground="White" BorderBrush="#555555"
                Padding="10,4" Margin="2" FontSize="12" Cursor="Hand" BorderThickness="1"/>
        <Button x:Name="btnFsClipboard" Content="Clipboard"
                Background="#333333" Foreground="White" BorderBrush="#555555"
                Padding="10,4" Margin="2" FontSize="12" Cursor="Hand" BorderThickness="1"/>
        <Button x:Name="btnFsDisconnect" Content="Disconnect"
                Background="#662222" Foreground="White" BorderBrush="#884444"
                Padding="10,4" Margin="2" FontSize="12" Cursor="Hand" BorderThickness="1"/>
      </StackPanel>
    </Border>

    <Border x:Name="fsHoverZone" VerticalAlignment="Top"
            HorizontalAlignment="Center" Height="6" Width="300"
            Background="Transparent" Panel.ZIndex="99" Visibility="Collapsed"/>
  </Grid>
</Window>
"@

 $reader = New-Object System.Xml.XmlNodeReader $Xaml
 $window = [Windows.Markup.XamlReader]::Load($reader)

 $txtHost=$window.FindName("txtHost"); $txtPort=$window.FindName("txtPort")
 $txtPassword=$window.FindName("txtPassword"); $txtPasswordVisible=$window.FindName("txtPasswordVisible")
 $btnTogglePw=$window.FindName("btnTogglePw")
 $btnConnect=$window.FindName("btnConnect"); $btnDisconnect=$window.FindName("btnDisconnect")
 $btnRefresh=$window.FindName("btnRefresh"); $btnCtrlAltDel=$window.FindName("btnCtrlAltDel")
 $btnWinKey=$window.FindName("btnWinKey")
 $btnFitWindow=$window.FindName("btnFitWindow"); $btnFullScreen=$window.FindName("btnFullScreen")
 $btnClipboard=$window.FindName("btnClipboard"); $btnSettings=$window.FindName("btnSettings")
 $btnTogglePanel=$window.FindName("btnTogglePanel"); $btnClearHistory=$window.FindName("btnClearHistory")
 $txtStatus=$window.FindName("txtStatus"); $txtResolution=$window.FindName("txtResolution")
 $txtFps=$window.FindName("txtFps"); $txtFrames=$window.FindName("txtFrames")
 $txtData=$window.FindName("txtData"); $txtLatency=$window.FindName("txtLatency")
 $txtUptime=$window.FindName("txtUptime"); $statusDot=$window.FindName("statusDot")
 $scrollViewer=$window.FindName("scrollViewer"); $vncCanvas=$window.FindName("vncCanvas")
 $vncImage=$window.FindName("vncImage"); $sidePanel=$window.FindName("sidePanel")
 $pinnedSessionsList=$window.FindName("pinnedSessionsList")
 $activeSessionsList=$window.FindName("activeSessionsList")
 $recentSessionsList=$window.FindName("recentSessionsList")
 $noConnectionOverlay=$window.FindName("noConnectionOverlay")
 $toolbarBorder=$window.FindName("toolbarBorder"); $statsBorder=$window.FindName("statsBorder")
 $fullscreenBar=$window.FindName("fullscreenBar"); $fsHoverZone=$window.FindName("fsHoverZone")
 $fsSessionName=$window.FindName("fsSessionName")
 $btnFsWindowed=$window.FindName("btnFsWindowed"); $btnFsRefresh=$window.FindName("btnFsRefresh")
 $btnFsCtrlAltDel=$window.FindName("btnFsCtrlAltDel"); $btnFsDisconnect=$window.FindName("btnFsDisconnect")
 $btnFsWinKey=$window.FindName("btnFsWinKey"); $btnFsClipboard=$window.FindName("btnFsClipboard")

 $txtPassword.Password = $DefaultPassword
 $txtPasswordVisible.Text = $DefaultPassword

# ============================================================
# STATE
# ============================================================
 $script:vncEngine=$null; $script:updateTimer=$null; $script:statsTimer=$null; $script:clipTimer=$null
 $script:lastFrameVer=-1; $script:buttonMask=0; $script:fitMode=$false
 $script:writeableBmp=$null; $script:panelOpen=$true
 $script:activeSessions=@{}; $script:activeSessionKey=$null
 $script:recentSessions=[System.Collections.ArrayList]::new()
 $script:isFullScreen=$false; $script:savedWindowState=$null
 $script:savedWindowStyle=$null; $script:savedWindowRect=$null
 $script:savedResizeMode=[System.Windows.ResizeMode]::CanResize
 $script:fsBarVisible=$false; $script:fsBarTimer=$null
 $script:lastLocalClipboard=""
 $script:syncingPw=$false
 $script:pwVisible=$false

 $script:vncSettings = @{
    SharedConnection=$true; ViewOnly=$false
    RefreshRate=33; ClipboardSync=$true
}

 $script:pendingConnect       = $null   # VncEngine currently attempting to connect
 $script:pendingConnectKey    = $null
 $script:pendingConnectHost   = $null
 $script:pendingConnectPort   = 0
 $script:pendingConnectPw     = $null
 $script:connectAsyncHandle   = $null
 $script:connectBgPS          = $null
 $script:connectRunspace      = $null
 $script:connectPollTimer     = $null
 $script:connectCancelled     = $false

# ============================================================
# SETTINGS
# ============================================================
function Load-VncSettings {
    if (-not (Test-Path $SettingsFile)) { return }
    try {
        $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        if ($null -ne $j.SharedConnection) { $script:vncSettings.SharedConnection=[bool]$j.SharedConnection }
        if ($null -ne $j.ViewOnly)         { $script:vncSettings.ViewOnly=[bool]$j.ViewOnly }
        if ($null -ne $j.RefreshRate)      { $script:vncSettings.RefreshRate=[int]$j.RefreshRate }
        if ($null -ne $j.ClipboardSync)    { $script:vncSettings.ClipboardSync=[bool]$j.ClipboardSync }
    } catch { }
}
function Save-VncSettings {
    try { $script:vncSettings | ConvertTo-Json | Set-Content $SettingsFile -Force } catch { }
}

# ============================================================
# SESSION HISTORY
# ============================================================
function Load-SessionHistory {
    if (-not (Test-Path $SessionHistoryFile)) { return }
    try {
        $json = Get-Content $SessionHistoryFile -Raw | ConvertFrom-Json
        $script:recentSessions.Clear()
        foreach ($item in $json) {
            $script:recentSessions.Add(@{
                Host=$item.Host; Port=[int]$item.Port; Name=$item.Name
                Nickname=$item.Nickname; Password=$item.Password
                LastUsed=$item.LastUsed; Pinned=[bool]$item.Pinned
            }) | Out-Null
        }
    } catch { }
}
function Save-SessionHistory {
    try { $script:recentSessions | ConvertTo-Json -Depth 3 | Set-Content $SessionHistoryFile -Force } catch { }
}
function Add-ToHistory([string]$H,[int]$P,[string]$N,[string]$PW) {
    $key="${H}:${P}"; $idx=-1
    for ($i=0;$i -lt $script:recentSessions.Count;$i++) {
        if ("$($script:recentSessions[$i].Host):$($script:recentSessions[$i].Port)" -eq $key) { $idx=$i; break }
    }
    if ($idx -ge 0) {
        $existing=$script:recentSessions[$idx]; $script:recentSessions.RemoveAt($idx)
        $existing.LastUsed=(Get-Date).ToString("yyyy-MM-dd HH:mm")
        if ($N -and -not $existing.Name) { $existing.Name=$N }
        if ($PW) { $existing.Password=$PW }
        $script:recentSessions.Insert(0,$existing)
    } else {
        $nv=$(if($N){$N}else{$key})
        $script:recentSessions.Insert(0,@{Host=$H;Port=$P;Name=$nv;Nickname="";Password=$PW;LastUsed=(Get-Date).ToString("yyyy-MM-dd HH:mm");Pinned=$false})
    }
    while ($script:recentSessions.Count -gt 30) { $script:recentSessions.RemoveAt($script:recentSessions.Count-1) }
    Save-SessionHistory
}
function Get-SessionDisplayName($entry) {
    if ($entry.Nickname) { return $entry.Nickname }
    if ($entry.Name -and $entry.Name -ne "$($entry.Host):$($entry.Port)") { return $entry.Name }
    return "$($entry.Host):$($entry.Port)"
}
function Find-HistoryEntry([string]$Key) {
    foreach ($s in $script:recentSessions) { if ("$($s.Host):$($s.Port)" -eq $Key) { return $s } }
    return $null
}
function Remove-HistoryEntry([string]$Key) {
    $idx=-1
    for ($i=0;$i -lt $script:recentSessions.Count;$i++) {
        if ("$($script:recentSessions[$i].Host):$($script:recentSessions[$i].Port)" -eq $Key) { $idx=$i; break }
    }
    if ($idx -ge 0) { $script:recentSessions.RemoveAt($idx); Save-SessionHistory; Update-SessionPanel }
}
function Toggle-Pin([string]$Key) {
    $e=Find-HistoryEntry $Key
    if ($null -ne $e) { $e.Pinned=-not $e.Pinned; Save-SessionHistory; Update-SessionPanel }
}
function Rename-Session([string]$Key) {
    $entry=Find-HistoryEntry $Key; if ($null -eq $entry) { return }
    $currentName=Get-SessionDisplayName $entry
    $dlg=New-Object System.Windows.Window
    $dlg.Title="Rename Session"; $dlg.Width=380; $dlg.Height=160
    $dlg.WindowStartupLocation=[System.Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner=$window; $dlg.ResizeMode=[System.Windows.ResizeMode]::NoResize
    $dlg.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x2D,0x2D,0x30)))
    $grid=New-Object System.Windows.Controls.Grid; $grid.Margin=[System.Windows.Thickness]::new(15)
    foreach($i in 1..3){$rd=New-Object System.Windows.Controls.RowDefinition;$rd.Height=[System.Windows.GridLength]::new(1,[System.Windows.GridUnitType]::Auto);$grid.RowDefinitions.Add($rd)}
    $lbl=New-Object System.Windows.Controls.TextBlock; $lbl.Text="Nickname for $Key :"
    $lbl.Foreground=[System.Windows.Media.Brushes]::White; $lbl.FontSize=13; $lbl.Margin=[System.Windows.Thickness]::new(0,0,0,8)
    [System.Windows.Controls.Grid]::SetRow($lbl,0); $grid.Children.Add($lbl)|Out-Null
    $tb=New-Object System.Windows.Controls.TextBox; $tb.Text=$currentName; $tb.FontSize=15
    $tb.Padding=[System.Windows.Thickness]::new(6,4,6,4)
    $tb.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x1E,0x1E,0x1E)))
    $tb.Foreground=[System.Windows.Media.Brushes]::White
    $tb.BorderBrush=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x55,0x55,0x55)))
    $tb.Margin=[System.Windows.Thickness]::new(0,0,0,12)
    [System.Windows.Controls.Grid]::SetRow($tb,1); $grid.Children.Add($tb)|Out-Null
    $bp=New-Object System.Windows.Controls.StackPanel; $bp.Orientation=[System.Windows.Controls.Orientation]::Horizontal
    $bp.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Right; [System.Windows.Controls.Grid]::SetRow($bp,2)
    $ok=New-Object System.Windows.Controls.Button; $ok.Content="Save"; $ok.Width=80; $ok.Padding=[System.Windows.Thickness]::new(0,4,0,4)
    $ok.Margin=[System.Windows.Thickness]::new(0,0,8,0)
    $ok.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0,0x78,0xD4)))
    $ok.Foreground=[System.Windows.Media.Brushes]::White; $ok.BorderThickness=[System.Windows.Thickness]::new(0); $ok.Cursor=[System.Windows.Input.Cursors]::Hand
    $cn=New-Object System.Windows.Controls.Button; $cn.Content="Cancel"; $cn.Width=80; $cn.Padding=[System.Windows.Thickness]::new(0,4,0,4)
    $cn.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x33,0x33,0x33)))
    $cn.Foreground=[System.Windows.Media.Brushes]::White; $cn.BorderBrush=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x55,0x55,0x55))); $cn.Cursor=[System.Windows.Input.Cursors]::Hand
    $ok.Add_Click({$dlg.Tag="OK";$dlg.Close()}); $cn.Add_Click({$dlg.Tag="Cancel";$dlg.Close()})
    $bp.Children.Add($ok)|Out-Null; $bp.Children.Add($cn)|Out-Null; $grid.Children.Add($bp)|Out-Null
    $dlg.Content=$grid; $dlg.ShowDialog()|Out-Null
    if ($dlg.Tag -eq "OK") { $entry.Nickname=$tb.Text.Trim(); Save-SessionHistory; Update-SessionPanel
        if ($Key -eq $script:activeSessionKey) { $txtStatus.Text="Connected - $(Get-SessionDisplayName $entry)" } }
    $vncCanvas.Focus()
}

# ============================================================
# CLIPBOARD DIALOG
# ============================================================
function Show-ClipboardDialog {
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }

    $dlg=New-Object System.Windows.Window
    $dlg.Title="Clipboard Transfer"; $dlg.Width=500; $dlg.Height=400
    $dlg.WindowStartupLocation=[System.Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner=$window; $dlg.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x2D,0x2D,0x30)))
    $dlg.ResizeMode=[System.Windows.ResizeMode]::CanResize; $dlg.MinWidth=400; $dlg.MinHeight=300

    $mainSp=New-Object System.Windows.Controls.DockPanel; $mainSp.Margin=[System.Windows.Thickness]::new(15)

    $titleTb=New-Object System.Windows.Controls.TextBlock; $titleTb.Text="Clipboard Transfer"
    $titleTb.Foreground=[System.Windows.Media.Brushes]::White; $titleTb.FontSize=18; $titleTb.FontWeight=[System.Windows.FontWeights]::SemiBold
    $titleTb.Margin=[System.Windows.Thickness]::new(0,0,0,4); [System.Windows.Controls.DockPanel]::SetDock($titleTb,"Top")
    $mainSp.Children.Add($titleTb)|Out-Null

    $helpTb=New-Object System.Windows.Controls.TextBlock
    $helpTb.Text="Use 'Type to Remote' to emulate keystrokes and paste text into the remote session. 'Paste from PC Clipboard' retrieves your local clipboard into this box."
    $helpTb.Foreground=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x88,0x88,0x88)))
    $helpTb.FontSize=12; $helpTb.TextWrapping=[System.Windows.TextWrapping]::Wrap
    $helpTb.Margin=[System.Windows.Thickness]::new(0,0,0,10); [System.Windows.Controls.DockPanel]::SetDock($helpTb,"Top")
    $mainSp.Children.Add($helpTb)|Out-Null

    $btnPanel=New-Object System.Windows.Controls.StackPanel; $btnPanel.Orientation=[System.Windows.Controls.Orientation]::Horizontal
    $btnPanel.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Right; $btnPanel.Margin=[System.Windows.Thickness]::new(0,10,0,0)
    [System.Windows.Controls.DockPanel]::SetDock($btnPanel,"Bottom")

    $btnPaste=New-Object System.Windows.Controls.Button; $btnPaste.Content="Paste from PC Clipboard"; $btnPaste.Padding=[System.Windows.Thickness]::new(12,6,12,6)
    $btnPaste.Margin=[System.Windows.Thickness]::new(0,0,6,0)
    $btnPaste.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x33,0x33,0x33)))
    $btnPaste.Foreground=[System.Windows.Media.Brushes]::White; $btnPaste.BorderBrush=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x55,0x55,0x55)))
    $btnPaste.Cursor=[System.Windows.Input.Cursors]::Hand; $btnPaste.FontSize=13

    $btnSend=New-Object System.Windows.Controls.Button; $btnSend.Content="Type to Remote"; $btnSend.Padding=[System.Windows.Thickness]::new(12,6,12,6)
    $btnSend.Margin=[System.Windows.Thickness]::new(0,0,6,0)
    $btnSend.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0,0x78,0xD4)))
    $btnSend.Foreground=[System.Windows.Media.Brushes]::White; $btnSend.BorderThickness=[System.Windows.Thickness]::new(0)
    $btnSend.Cursor=[System.Windows.Input.Cursors]::Hand; $btnSend.FontSize=13

    $btnClose=New-Object System.Windows.Controls.Button; $btnClose.Content="Close"; $btnClose.Padding=[System.Windows.Thickness]::new(12,6,12,6)
    $btnClose.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x33,0x33,0x33)))
    $btnClose.Foreground=[System.Windows.Media.Brushes]::White; $btnClose.BorderBrush=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x55,0x55,0x55)))
    $btnClose.Cursor=[System.Windows.Input.Cursors]::Hand; $btnClose.FontSize=13

    $btnPanel.Children.Add($btnPaste)|Out-Null
    $btnPanel.Children.Add($btnSend)|Out-Null; $btnPanel.Children.Add($btnClose)|Out-Null
    $mainSp.Children.Add($btnPanel)|Out-Null

    $statusLbl=New-Object System.Windows.Controls.TextBlock; $statusLbl.Text=""; $statusLbl.FontSize=12
    $statusLbl.Foreground=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x4E,0xC9,0xB0)))
    $statusLbl.Margin=[System.Windows.Thickness]::new(0,6,0,0)
    [System.Windows.Controls.DockPanel]::SetDock($statusLbl,"Bottom")
    $mainSp.Children.Add($statusLbl)|Out-Null

    $clipTb=New-Object System.Windows.Controls.TextBox
    $clipTb.AcceptsReturn=$true; $clipTb.AcceptsTab=$true; $clipTb.TextWrapping=[System.Windows.TextWrapping]::Wrap
    $clipTb.VerticalScrollBarVisibility=[System.Windows.Controls.ScrollBarVisibility]::Auto
    $clipTb.FontSize=14; $clipTb.FontFamily=(New-Object System.Windows.Media.FontFamily("Consolas"))
    $clipTb.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x1E,0x1E,0x1E)))
    $clipTb.Foreground=[System.Windows.Media.Brushes]::White
    $clipTb.BorderBrush=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x55,0x55,0x55)))
    $clipTb.Padding=[System.Windows.Thickness]::new(8)
    try { if ([System.Windows.Clipboard]::ContainsText()) { $clipTb.Text=[System.Windows.Clipboard]::GetText() } } catch { }
    $mainSp.Children.Add($clipTb)|Out-Null

    $btnPaste.Add_Click({
        try {
            if ([System.Windows.Clipboard]::ContainsText()) {
                $clipTb.Text=[System.Windows.Clipboard]::GetText()
                $statusLbl.Text="Pasted from local clipboard."
            } else { $statusLbl.Text="Local clipboard is empty." }
        } catch { $statusLbl.Text="Failed to read clipboard." }
    })

    $btnSend.Add_Click({
        $text=$clipTb.Text
        if ($text.Length -eq 0) { $statusLbl.Text="Nothing to send."; return }
        if ($null -ne $script:vncEngine -and $script:vncEngine.IsConnected) {
            $script:vncEngine.SendTextViaKeysAsync($text)
            $statusLbl.Text="Typing $($text.Length) characters to remote..."
            $statusLbl.Foreground=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x4E,0xC9,0xB0)))
        } else { $statusLbl.Text="Not connected."; $statusLbl.Foreground=[System.Windows.Media.Brushes]::OrangeRed }
    })

    $btnClose.Add_Click({ $dlg.Close() })

    $dlg.Content=$mainSp; $dlg.ShowDialog()|Out-Null

    # Return focus to VNC Canvas so keyboard works immediately after pasting
    $vncCanvas.Focus()
}

# ============================================================
# SETTINGS DIALOG
# ============================================================
function Show-SettingsDialog {
    $dlg=New-Object System.Windows.Window
    $dlg.Title="VNC Settings"; $dlg.Width=420; $dlg.Height=320
    $dlg.WindowStartupLocation=[System.Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner=$window; $dlg.ResizeMode=[System.Windows.ResizeMode]::NoResize
    $dlg.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x2D,0x2D,0x30)))
    $sp=New-Object System.Windows.Controls.StackPanel; $sp.Margin=[System.Windows.Thickness]::new(20)
    $grayFg=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0xCC,0xCC,0xCC)))

    $t1=New-Object System.Windows.Controls.TextBlock; $t1.Text="VNC Connection Settings"
    $t1.Foreground=[System.Windows.Media.Brushes]::White; $t1.FontSize=18; $t1.FontWeight=[System.Windows.FontWeights]::SemiBold
    $t1.Margin=[System.Windows.Thickness]::new(0,0,0,6); $sp.Children.Add($t1)|Out-Null
    $t2=New-Object System.Windows.Controls.TextBlock; $t2.Text="Changes apply to new connections (except where noted)."
    $t2.Foreground=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x88,0x88,0x88)))
    $t2.FontSize=12; $t2.FontStyle=[System.Windows.FontStyles]::Italic; $t2.Margin=[System.Windows.Thickness]::new(0,0,0,16); $sp.Children.Add($t2)|Out-Null

    $rrSp=New-Object System.Windows.Controls.StackPanel; $rrSp.Margin=[System.Windows.Thickness]::new(0,0,0,12)
    $rrL=New-Object System.Windows.Controls.TextBlock; $rrL.Text="Refresh Rate (applies immediately):"; $rrL.Foreground=$grayFg; $rrL.FontSize=13
    $rrL.Margin=[System.Windows.Thickness]::new(0,0,0,4); $rrSp.Children.Add($rrL)|Out-Null
    $rrCombo=New-Object System.Windows.Controls.ComboBox; $rrCombo.FontSize=13; $rrCombo.Padding=[System.Windows.Thickness]::new(4)
    $i1=New-Object System.Windows.Controls.ComboBoxItem; $i1.Content="~60 FPS (16 ms)"; $i1.Foreground=[System.Windows.Media.Brushes]::Black
    $i2=New-Object System.Windows.Controls.ComboBoxItem; $i2.Content="~30 FPS (33 ms)"; $i2.Foreground=[System.Windows.Media.Brushes]::Black
    $rrCombo.Items.Add($i1)|Out-Null; $rrCombo.Items.Add($i2)|Out-Null
    $rrCombo.SelectedIndex=$(if($script:vncSettings.RefreshRate -le 16){0}else{1})
    $rrSp.Children.Add($rrCombo)|Out-Null; $sp.Children.Add($rrSp)|Out-Null

    $cbShared=New-Object System.Windows.Controls.CheckBox; $cbShared.Content="  Shared Connection (allow others)"; $cbShared.Foreground=$grayFg; $cbShared.FontSize=13
    $cbShared.IsChecked=$script:vncSettings.SharedConnection; $cbShared.Margin=[System.Windows.Thickness]::new(0,0,0,8); $sp.Children.Add($cbShared)|Out-Null
    $cbVO=New-Object System.Windows.Controls.CheckBox; $cbVO.Content="  View Only (applies immediately)"; $cbVO.Foreground=$grayFg; $cbVO.FontSize=13
    $cbVO.IsChecked=$script:vncSettings.ViewOnly; $cbVO.Margin=[System.Windows.Thickness]::new(0,0,0,8); $sp.Children.Add($cbVO)|Out-Null
    $cbClip=New-Object System.Windows.Controls.CheckBox; $cbClip.Content="  Auto Clipboard Sync (applies immediately)"; $cbClip.Foreground=$grayFg; $cbClip.FontSize=13
    $cbClip.IsChecked=$script:vncSettings.ClipboardSync; $cbClip.Margin=[System.Windows.Thickness]::new(0,0,0,16); $sp.Children.Add($cbClip)|Out-Null

    $bsp=New-Object System.Windows.Controls.StackPanel; $bsp.Orientation=[System.Windows.Controls.Orientation]::Horizontal; $bsp.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Right
    $sv=New-Object System.Windows.Controls.Button; $sv.Content="Save"; $sv.Width=90; $sv.Padding=[System.Windows.Thickness]::new(0,6,0,6); $sv.Margin=[System.Windows.Thickness]::new(0,0,8,0)
    $sv.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0,0x78,0xD4))); $sv.Foreground=[System.Windows.Media.Brushes]::White
    $sv.BorderThickness=[System.Windows.Thickness]::new(0); $sv.Cursor=[System.Windows.Input.Cursors]::Hand; $sv.FontSize=13
    $ca=New-Object System.Windows.Controls.Button; $ca.Content="Cancel"; $ca.Width=90; $ca.Padding=[System.Windows.Thickness]::new(0,6,0,6)
    $ca.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x33,0x33,0x33))); $ca.Foreground=[System.Windows.Media.Brushes]::White
    $ca.BorderBrush=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x55,0x55,0x55))); $ca.Cursor=[System.Windows.Input.Cursors]::Hand; $ca.FontSize=13
    $sv.Add_Click({$dlg.Tag="OK";$dlg.Close()}); $ca.Add_Click({$dlg.Tag="Cancel";$dlg.Close()})
    $bsp.Children.Add($sv)|Out-Null; $bsp.Children.Add($ca)|Out-Null; $sp.Children.Add($bsp)|Out-Null
    $dlg.Content=$sp; $dlg.ShowDialog()|Out-Null
    if ($dlg.Tag -eq "OK") {
        $script:vncSettings.RefreshRate=@(16,33)[$rrCombo.SelectedIndex]
        $script:vncSettings.SharedConnection=[bool]$cbShared.IsChecked; $script:vncSettings.ViewOnly=[bool]$cbVO.IsChecked
        $script:vncSettings.ClipboardSync=[bool]$cbClip.IsChecked; Save-VncSettings
        if ($null -ne $script:updateTimer) { $script:updateTimer.Interval=[TimeSpan]::FromMilliseconds($script:vncSettings.RefreshRate) }
        if ($null -ne $script:vncEngine) { $script:vncEngine.ViewOnly=$script:vncSettings.ViewOnly; $script:vncEngine.ClipboardSync=$script:vncSettings.ClipboardSync }
    }
    $vncCanvas.Focus()
}

# ============================================================
# HELPERS
# ============================================================
function Format-DataSize([long]$b) { if($b -lt 1024){return "$b B"};if($b -lt 1MB){return "{0:N1} KB" -f ($b/1KB)};if($b -lt 1GB){return "{0:N1} MB" -f ($b/1MB)};return "{0:N2} GB" -f ($b/1GB) }
function Format-Uptime([long]$ms) { $ts=[TimeSpan]::FromMilliseconds($ms);if($ts.TotalHours -ge 1){return "{0:D2}:{1:D2}:{2:D2}" -f [int]$ts.TotalHours,$ts.Minutes,$ts.Seconds};return "{0:D2}:{1:D2}" -f $ts.Minutes,$ts.Seconds }
function Reset-Stats { $txtFps.Text="--";$txtFrames.Text="--";$txtData.Text="--";$txtLatency.Text="--";$txtUptime.Text="--" }
function Update-Stats { if($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected){return};$txtFps.Text="{0:N1}" -f $script:vncEngine.CurrentFps;$txtFrames.Text=$script:vncEngine.FrameCount.ToString("N0");$txtData.Text=Format-DataSize $script:vncEngine.BytesReceived;$txtLatency.Text="$($script:vncEngine.LastPingMs) ms";$txtUptime.Text=Format-Uptime $script:vncEngine.UptimeMs }
function Set-Connected([bool]$state) {
    $txtHost.IsEnabled=-not $state;$txtPort.IsEnabled=-not $state;$txtPassword.IsEnabled=-not $state;$txtPasswordVisible.IsEnabled=-not $state;$btnTogglePw.IsEnabled=-not $state
    $btnConnect.IsEnabled=-not $state;$btnDisconnect.IsEnabled=$state;$btnRefresh.IsEnabled=$state
    $btnCtrlAltDel.IsEnabled=$state;$btnWinKey.IsEnabled=$state;$btnFitWindow.IsEnabled=$state;$btnFullScreen.IsEnabled=$state;$btnClipboard.IsEnabled=$state
    if($state){$statusDot.Fill=[System.Windows.Media.Brushes]::LimeGreen;$noConnectionOverlay.Visibility=[System.Windows.Visibility]::Collapsed}
    else{$statusDot.Fill=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0xFF,0x44,0x44)));$txtStatus.Text="Disconnected";$txtResolution.Text="";Reset-Stats}
}

# ============================================================
# FULLSCREEN
# ============================================================
function Enter-FullScreen {
    if($script:isFullScreen){return}; $script:isFullScreen=$true
    if($script:panelOpen){$sidePanel.Width=0;$script:panelOpen=$false;$btnTogglePanel.Content="Sessions"}
    $script:savedWindowState=$window.WindowState; $script:savedWindowStyle=$window.WindowStyle
    $script:savedWindowRect=@{Left=$window.Left;Top=$window.Top;Width=$window.Width;Height=$window.Height}
    $script:savedResizeMode=$window.ResizeMode
    $window.WindowState=[System.Windows.WindowState]::Normal
    $toolbarBorder.Visibility=[System.Windows.Visibility]::Collapsed; $statsBorder.Visibility=[System.Windows.Visibility]::Collapsed
    $window.WindowStyle=[System.Windows.WindowStyle]::None
    $window.ResizeMode=[System.Windows.ResizeMode]::NoResize
    $window.Topmost=$true
    $screen=[System.Windows.SystemParameters]::PrimaryScreenWidth
    $screenH=[System.Windows.SystemParameters]::PrimaryScreenHeight
    $window.Left=0; $window.Top=0; $window.Width=$screen; $window.Height=$screenH
    $window.WindowState=[System.Windows.WindowState]::Normal
    if(-not $script:fitMode){$script:fitMode=$true;Apply-FitMode}
    $fsHoverZone.Visibility=[System.Windows.Visibility]::Visible
    $dispName=$script:activeSessionKey; $entry=Find-HistoryEntry $script:activeSessionKey
    if($null -ne $entry){$dispName=Get-SessionDisplayName $entry}; $fsSessionName.Text=$dispName
    $btnFullScreen.Content="Windowed"
}
function Exit-FullScreen {
    if(-not $script:isFullScreen){return}; $script:isFullScreen=$false
    $fullscreenBar.Height=0;$fsHoverZone.Visibility=[System.Windows.Visibility]::Collapsed;$script:fsBarVisible=$false
    $window.Topmost=$false; $window.WindowStyle=$script:savedWindowStyle
    $window.ResizeMode=$script:savedResizeMode
    if($null -ne $script:savedWindowRect){$window.Left=$script:savedWindowRect.Left;$window.Top=$script:savedWindowRect.Top;$window.Width=$script:savedWindowRect.Width;$window.Height=$script:savedWindowRect.Height}
    $window.WindowState=$script:savedWindowState
    $toolbarBorder.Visibility=[System.Windows.Visibility]::Visible;$statsBorder.Visibility=[System.Windows.Visibility]::Visible
    $btnFullScreen.Content="Full Screen"
}
function Show-FullscreenBar {
    if($script:fsBarVisible){return};$script:fsBarVisible=$true;$fullscreenBar.Height=44
    if($null -ne $script:fsBarTimer){$script:fsBarTimer.Stop()}
    $script:fsBarTimer=New-Object System.Windows.Threading.DispatcherTimer; $script:fsBarTimer.Interval=[TimeSpan]::FromSeconds(3)
    $script:fsBarTimer.Add_Tick({$script:fsBarTimer.Stop();Hide-FullscreenBar});$script:fsBarTimer.Start()
}
function Hide-FullscreenBar { $script:fsBarVisible=$false;$fullscreenBar.Height=0 }

# ============================================================
# FIT MODE
# ============================================================
function Apply-FitMode {
    $vncImage.Stretch=[System.Windows.Media.Stretch]::Uniform
    $wb=New-Object System.Windows.Data.Binding("ViewportWidth");$wb.Source=$scrollViewer; $hb=New-Object System.Windows.Data.Binding("ViewportHeight");$hb.Source=$scrollViewer
    $vncCanvas.SetBinding([System.Windows.FrameworkElement]::WidthProperty,$wb);$vncCanvas.SetBinding([System.Windows.FrameworkElement]::HeightProperty,$hb)
    $iwb=New-Object System.Windows.Data.Binding("ViewportWidth");$iwb.Source=$scrollViewer;$ihb=New-Object System.Windows.Data.Binding("ViewportHeight");$ihb.Source=$scrollViewer
    $vncImage.SetBinding([System.Windows.FrameworkElement]::WidthProperty,$iwb);$vncImage.SetBinding([System.Windows.FrameworkElement]::HeightProperty,$ihb)
    $scrollViewer.HorizontalScrollBarVisibility=[System.Windows.Controls.ScrollBarVisibility]::Disabled;$scrollViewer.VerticalScrollBarVisibility=[System.Windows.Controls.ScrollBarVisibility]::Disabled
}
function Remove-FitMode {
    $vncImage.Stretch=[System.Windows.Media.Stretch]::None
    foreach($dp in @([System.Windows.FrameworkElement]::WidthProperty,[System.Windows.FrameworkElement]::HeightProperty)){[System.Windows.Data.BindingOperations]::ClearBinding($vncCanvas,$dp);[System.Windows.Data.BindingOperations]::ClearBinding($vncImage,$dp)}
    $vncImage.Width=[double]::NaN;$vncImage.Height=[double]::NaN
    $scrollViewer.HorizontalScrollBarVisibility=[System.Windows.Controls.ScrollBarVisibility]::Auto;$scrollViewer.VerticalScrollBarVisibility=[System.Windows.Controls.ScrollBarVisibility]::Auto
    if($null -ne $script:vncEngine){$vncCanvas.Width=$script:vncEngine.FramebufferWidth;$vncCanvas.Height=$script:vncEngine.FramebufferHeight}
}

# ============================================================
# SIDE PANEL
# ============================================================
function New-PanelButton([string]$Line1,[string]$Line2,[System.Windows.Media.Brush]$DotColor,[bool]$IsCurrent,[scriptblock]$OnClick,[System.Windows.Controls.ContextMenu]$ContextMenu) {
    $btn=New-Object System.Windows.Controls.Button
    $btn.HorizontalContentAlignment=[System.Windows.HorizontalAlignment]::Stretch
    $btn.BorderThickness=[System.Windows.Thickness]::new(0,0,0,1)
    $btn.BorderBrush=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x3F,0x3F,0x46)))
    $btn.Padding=[System.Windows.Thickness]::new(10,8,10,8); $btn.Cursor=[System.Windows.Input.Cursors]::Hand
    if($IsCurrent){$btn.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x0E,0x4A,0x0E)))}
    else{$btn.Background=[System.Windows.Media.Brushes]::Transparent}
    $btn.Foreground=[System.Windows.Media.Brushes]::White

    $sp2=New-Object System.Windows.Controls.StackPanel
    $row1=New-Object System.Windows.Controls.StackPanel;$row1.Orientation=[System.Windows.Controls.Orientation]::Horizontal
    if($null -ne $DotColor){$dot=New-Object System.Windows.Shapes.Ellipse;$dot.Width=8;$dot.Height=8;$dot.Fill=$DotColor;$dot.Margin=[System.Windows.Thickness]::new(0,0,6,0);$dot.VerticalAlignment=[System.Windows.VerticalAlignment]::Center;$row1.Children.Add($dot)|Out-Null}
    $tb1=New-Object System.Windows.Controls.TextBlock;$tb1.Text=$Line1;$tb1.FontSize=13
    if($IsCurrent){$tb1.Foreground=[System.Windows.Media.Brushes]::White;$tb1.FontWeight=[System.Windows.FontWeights]::Bold}
    else{$tb1.Foreground=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0xCC,0xCC,0xCC)))}
    $row1.Children.Add($tb1)|Out-Null
    if($IsCurrent){$ar=New-Object System.Windows.Controls.TextBlock;$ar.Text="  <";$ar.FontSize=11;$ar.Foreground=[System.Windows.Media.Brushes]::LimeGreen;$ar.VerticalAlignment=[System.Windows.VerticalAlignment]::Center;$row1.Children.Add($ar)|Out-Null}
    $sp2.Children.Add($row1)|Out-Null
    if($Line2){
        $tb2=New-Object System.Windows.Controls.TextBlock
        $tb2.Text=$Line2
        $tb2.FontSize=11
        $tb2.FontFamily=(New-Object System.Windows.Media.FontFamily("Consolas"))
        $tb2.Margin=[System.Windows.Thickness]::new(14,2,0,0)
        $tb2.Foreground=[System.Windows.Media.Brushes]::White
        $sp2.Children.Add($tb2)|Out-Null
    }
    $btn.Content=$sp2
    if($OnClick){$btn.Add_Click($OnClick)}
    if($ContextMenu){$btn.ContextMenu=$ContextMenu}
    return $btn
}
function New-ContextMenu([string]$Key,[bool]$IsActive) {
    $ctx=New-Object System.Windows.Controls.ContextMenu
    if($IsActive){$mi=New-Object System.Windows.Controls.MenuItem;$mi.Header="Disconnect";$ck=$Key;$mi.Add_Click({Disconnect-Session $ck}.GetNewClosure());$ctx.Items.Add($mi)|Out-Null;$ctx.Items.Add((New-Object System.Windows.Controls.Separator))|Out-Null}
    $mi2=New-Object System.Windows.Controls.MenuItem;$mi2.Header="Rename...";$ck2=$Key;$mi2.Add_Click({Rename-Session $ck2}.GetNewClosure());$ctx.Items.Add($mi2)|Out-Null
    $entry=Find-HistoryEntry $Key;$pinned=($null -ne $entry -and $entry.Pinned)
    $mi3=New-Object System.Windows.Controls.MenuItem;$mi3.Header=$(if($pinned){"Unpin"}else{"Pin"})
    $ck3=$Key;$mi3.Add_Click({Toggle-Pin $ck3}.GetNewClosure());$ctx.Items.Add($mi3)|Out-Null
    if(-not $IsActive){$ctx.Items.Add((New-Object System.Windows.Controls.Separator))|Out-Null
        $mi4=New-Object System.Windows.Controls.MenuItem;$mi4.Header="Remove from history"
        $ck4=$Key;$mi4.Add_Click({Remove-HistoryEntry $ck4}.GetNewClosure());$ctx.Items.Add($mi4)|Out-Null}
    return $ctx
}
function Make-EmptyLabel([string]$Text) {$tb=New-Object System.Windows.Controls.TextBlock;$tb.Text="  $Text";$tb.Foreground=[System.Windows.Media.Brushes]::Gray;$tb.FontSize=12;$tb.Margin=[System.Windows.Thickness]::new(10,8,10,8);$tb.FontStyle=[System.Windows.FontStyles]::Italic;return $tb}
function Update-SessionPanel {
    $pinnedSessionsList.Children.Clear();$activeSessionsList.Children.Clear();$recentSessionsList.Children.Clear()
    $pinnedEntries=@($script:recentSessions | Where-Object {$_.Pinned})
    if($pinnedEntries.Count -eq 0){$pinnedSessionsList.Children.Add((Make-EmptyLabel "No pinned sessions"))|Out-Null}
    else{foreach($s in $pinnedEntries){$k="$($s.Host):$($s.Port)";$dn=Get-SessionDisplayName $s;$isAct=$script:activeSessions.ContainsKey($k);$isCur=($k -eq $script:activeSessionKey)
        $dc=$null;if($isAct){$eng=$script:activeSessions[$k];$dc=$(if($eng.IsConnected){[System.Windows.Media.Brushes]::LimeGreen}else{[System.Windows.Media.Brushes]::OrangeRed})}
        $l2=$(if($dn -ne $k){$k}else{""});$cK=$k;$rH=$s.Host;$rP=$s.Port;$rPW=$s.Password
        $oc=$(if($isAct){{Switch-ToSession $cK}.GetNewClosure()}else{{$txtHost.Text=$rH;$txtPort.Text=$rP.ToString();if($rPW){$script:syncingPw=$true;$txtPassword.Password=$rPW;$txtPasswordVisible.Text=$rPW;$script:syncingPw=$false};Do-Connect}.GetNewClosure()})
        $btn=New-PanelButton -Line1 $dn -Line2 $l2 -DotColor $dc -IsCurrent $isCur -OnClick $oc -ContextMenu (New-ContextMenu $k $isAct);$pinnedSessionsList.Children.Add($btn)|Out-Null}}
    $addedAct=$false
    foreach($k in @($script:activeSessions.Keys)){$entry=Find-HistoryEntry $k;if($null -ne $entry -and $entry.Pinned){continue};$addedAct=$true
        $eng=$script:activeSessions[$k];$isCur=($k -eq $script:activeSessionKey);$dc=$(if($eng.IsConnected){[System.Windows.Media.Brushes]::LimeGreen}else{[System.Windows.Media.Brushes]::OrangeRed})
        $dn=$k;if($null -ne $entry){$dn=Get-SessionDisplayName $entry};$dsk=$eng.DesktopName;if(-not $dsk){$dsk="Connecting..."}
        $l2=$(if($dn -ne $k){"$k - $dsk"}else{$dsk});$cK=$k
        $btn=New-PanelButton -Line1 $dn -Line2 $l2 -DotColor $dc -IsCurrent $isCur -OnClick {Switch-ToSession $cK}.GetNewClosure() -ContextMenu (New-ContextMenu $k $true);$activeSessionsList.Children.Add($btn)|Out-Null}
    if(-not $addedAct){$activeSessionsList.Children.Add((Make-EmptyLabel "No active sessions"))|Out-Null}
    $hasRec=$false
    foreach($s in $script:recentSessions){$k="$($s.Host):$($s.Port)";if($script:activeSessions.ContainsKey($k)){continue};if($s.Pinned){continue};$hasRec=$true
        $dn=Get-SessionDisplayName $s;$l2=$(if($dn -ne $k){"$k  |  $($s.LastUsed)"}else{$s.LastUsed});$rH=$s.Host;$rP=$s.Port;$rPW=$s.Password
        $btn=New-PanelButton -Line1 $dn -Line2 $l2 -DotColor $null -IsCurrent $false -OnClick {$txtHost.Text=$rH;$txtPort.Text=$rP.ToString();if($rPW){$script:syncingPw=$true;$txtPassword.Password=$rPW;$txtPasswordVisible.Text=$rPW;$script:syncingPw=$false};Do-Connect}.GetNewClosure() -ContextMenu (New-ContextMenu $k $false);$recentSessionsList.Children.Add($btn)|Out-Null}
    if(-not $hasRec){$recentSessionsList.Children.Add((Make-EmptyLabel "No recent sessions"))|Out-Null}
}
function Toggle-SidePanel {
    if($script:panelOpen){$sidePanel.Width=0;$script:panelOpen=$false;$btnTogglePanel.Content="Sessions"}
    else{$sidePanel.Width=250;$script:panelOpen=$true;$btnTogglePanel.Content="X  Close";Update-SessionPanel}
}

# ============================================================
# SESSION MANAGEMENT
# ============================================================
function Switch-ToSession([string]$SessionKey) {
    if(-not $script:activeSessions.ContainsKey($SessionKey)){return}
    if($SessionKey -eq $script:activeSessionKey){return}
    if($null -ne $script:updateTimer){$script:updateTimer.Stop();$script:updateTimer=$null}
    $script:writeableBmp=$null;$script:lastFrameVer=-1;$vncImage.Source=$null
    $script:vncEngine=$script:activeSessions[$SessionKey];$script:activeSessionKey=$SessionKey
    if($script:vncEngine.IsConnected){
        $fw=$script:vncEngine.FramebufferWidth;$fh=$script:vncEngine.FramebufferHeight
        $entry=Find-HistoryEntry $SessionKey;$dn=$(if($null -ne $entry){Get-SessionDisplayName $entry}else{$SessionKey})
        $parts=$SessionKey -split ':';$txtHost.Text=$parts[0];$txtPort.Text=$parts[1]
        if($null -ne $entry -and $entry.Password){$script:syncingPw=$true;$txtPassword.Password=$entry.Password;$txtPasswordVisible.Text=$entry.Password;$script:syncingPw=$false}
        if($script:fitMode){Apply-FitMode}else{$vncCanvas.Width=$fw;$vncCanvas.Height=$fh}
        Set-Connected $true;$txtStatus.Text="Connected - $dn";$txtResolution.Text="${fw} x ${fh}"
        $script:updateTimer=New-Object System.Windows.Threading.DispatcherTimer;$script:updateTimer.Interval=[TimeSpan]::FromMilliseconds($script:vncSettings.RefreshRate)
        $script:updateTimer.Add_Tick({Update-Frame});$script:updateTimer.Start();$script:vncEngine.RequestFullRefresh();$vncCanvas.Focus()
    }
    Update-SessionPanel
}
function Disconnect-Session([string]$SessionKey) {
    if(-not $script:activeSessions.ContainsKey($SessionKey)){return}
    $script:activeSessions[$SessionKey].Disconnect();$script:activeSessions.Remove($SessionKey)
    if($SessionKey -eq $script:activeSessionKey){Stop-VncSession -KeepOthers};Update-SessionPanel
}
function Update-Frame {
    if($null -eq $script:vncEngine){return}
    if(-not $script:vncEngine.IsConnected){$err=$script:vncEngine.LastError;$key=$script:activeSessionKey
        if($null -ne $key -and $script:activeSessions.ContainsKey($key)){$script:activeSessions.Remove($key)}
        Stop-VncSession -KeepOthers;$txtStatus.Text="Lost: $err";Update-SessionPanel;return}
    $ver=$script:vncEngine.FrameVersion;if($ver -eq $script:lastFrameVer){return};$script:lastFrameVer=$ver
    $w=$script:vncEngine.FramebufferWidth;$h=$script:vncEngine.FramebufferHeight;$fb=$script:vncEngine.GetFrameBufferDirect()
    if($null -eq $fb -or $w -le 0 -or $h -le 0){return}
    if($null -eq $script:writeableBmp -or $script:writeableBmp.PixelWidth -ne $w -or $script:writeableBmp.PixelHeight -ne $h){
        $script:writeableBmp=New-Object System.Windows.Media.Imaging.WriteableBitmap($w,$h,96,96,[System.Windows.Media.PixelFormats]::Bgr32,$null)
        $vncImage.Source=$script:writeableBmp;if(-not $script:fitMode){$vncCanvas.Width=$w;$vncCanvas.Height=$h};$txtResolution.Text="${w} x ${h}"}
    try{$script:writeableBmp.WritePixels((New-Object System.Windows.Int32Rect(0,0,$w,$h)),$fb,($w*4),0)}catch{}
}
function Stop-VncSession {
    param([switch]$KeepOthers)
    if($null -ne $script:updateTimer){$script:updateTimer.Stop();$script:updateTimer=$null}
    if($KeepOthers){$script:vncEngine=$null}else{if($null -ne $script:vncEngine){$script:vncEngine.Disconnect();$script:vncEngine=$null};foreach($k in @($script:activeSessions.Keys)){$script:activeSessions[$k].Disconnect()};$script:activeSessions.Clear()}
    $script:activeSessionKey=$null;$script:writeableBmp=$null;$script:lastFrameVer=-1;$vncImage.Source=$null
    if($script:fitMode -and -not $script:isFullScreen){Remove-FitMode;$script:fitMode=$false;$btnFitWindow.Content="Fit Window"}
    if($script:isFullScreen){Exit-FullScreen}
    Set-Connected $false;$noConnectionOverlay.Visibility=[System.Windows.Visibility]::Visible
    $btnConnect.IsEnabled=$true;$txtHost.IsEnabled=$true;$txtPort.IsEnabled=$true;$txtPassword.IsEnabled=$true;$txtPasswordVisible.IsEnabled=$true;$btnTogglePw.IsEnabled=$true;Update-SessionPanel
}
function Get-ScaledPos($e) {
    $pos=$e.GetPosition($vncImage);$x=[int]$pos.X;$y=[int]$pos.Y
    if($script:fitMode -and $null -ne $script:vncEngine){$dw=$vncImage.ActualWidth;$dh=$vncImage.ActualHeight;$fw=$script:vncEngine.FramebufferWidth;$fh=$script:vncEngine.FramebufferHeight
        if($dw -gt 0 -and $dh -gt 0 -and $fw -gt 0 -and $fh -gt 0){$scale=[Math]::Min($dw/$fw,$dh/$fh);$x=[int](($pos.X-($dw-$fw*$scale)/2)/$scale);$y=[int](($pos.Y-($dh-$fh*$scale)/2)/$scale)}}
    if($null -ne $script:vncEngine){$x=[Math]::Max(0,[Math]::Min($x,$script:vncEngine.FramebufferWidth-1));$y=[Math]::Max(0,[Math]::Min($y,$script:vncEngine.FramebufferHeight-1))}
    return @{X=$x;Y=$y}
}

# ============================================================
# CONNECT FUNCTION (reusable - Async)
# ============================================================
function Do-Connect {
    # Ignore if a connect attempt is already in flight
    if ($null -ne $script:connectAsyncHandle -and -not $script:connectAsyncHandle.IsCompleted) { return }

    $h = $txtHost.Text.Trim()
    if (-not ($txtPort.Text.Trim() -match '^\d+$')) {
        [System.Windows.MessageBox]::Show("Enter a valid numeric port.","VNC","OK","Warning"); return
    }
    $p = [int]$txtPort.Text.Trim()
    if ($script:pwVisible) { $pw = $txtPasswordVisible.Text } else { $pw = $txtPassword.Password }
    $sk = "${h}:${p}"

    if ([string]::IsNullOrEmpty($h)) {
        [System.Windows.MessageBox]::Show("Enter a host.","VNC","OK","Warning"); return
    }
    if ($script:activeSessions.ContainsKey($sk)) {
        if ($script:activeSessions[$sk].IsConnected) { Switch-ToSession $sk; return }
        else { $script:activeSessions[$sk].Disconnect(); $script:activeSessions.Remove($sk) }
    }

    if ($null -ne $script:updateTimer) { $script:updateTimer.Stop(); $script:updateTimer = $null }
    $script:writeableBmp = $null; $script:lastFrameVer = -1; $vncImage.Source = $null

    # UI: lock inputs, keep Disconnect enabled so the user can cancel
    $txtStatus.Text = "Connecting to ${h}:${p} ..."
    $window.Cursor  = [System.Windows.Input.Cursors]::Wait
    $btnConnect.IsEnabled       = $false
    $txtHost.IsEnabled          = $false
    $txtPort.IsEnabled          = $false
    $txtPassword.IsEnabled      = $false
    $txtPasswordVisible.IsEnabled = $false
    $btnTogglePw.IsEnabled      = $false
    $btnDisconnect.IsEnabled    = $true     # acts as Cancel during connect
    $btnDisconnect.Content      = "Cancel"
    $statusDot.Fill = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0xF0,0xC0,0x00)))

    $shared   = $script:vncSettings.SharedConnection
    $viewOnly = $script:vncSettings.ViewOnly
    $clipSync = $script:vncSettings.ClipboardSync
    $ne       = New-Object VncEngine

    $script:pendingConnect     = $ne
    $script:pendingConnectKey  = $sk
    $script:pendingConnectHost = $h
    $script:pendingConnectPort = $p
    $script:pendingConnectPw   = $pw
    $script:connectCancelled   = $false

    # Background runspace so the UI thread is never blocked
    $script:connectRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:connectRunspace.Open()
    $script:connectBgPS = [System.Management.Automation.PowerShell]::Create()
    $script:connectBgPS.Runspace = $script:connectRunspace
    [void]$script:connectBgPS.AddScript(@'
        param($engine,$h,$p,$pw,$sh,$vo,$cs)
        $ok = $engine.Connect($h,$p,$pw,$sh,$vo,$cs)
        return $ok
'@)
    [void]$script:connectBgPS.AddArgument($ne)
    [void]$script:connectBgPS.AddArgument($h)
    [void]$script:connectBgPS.AddArgument($p)
    [void]$script:connectBgPS.AddArgument($pw)
    [void]$script:connectBgPS.AddArgument($shared)
    [void]$script:connectBgPS.AddArgument($viewOnly)
    [void]$script:connectBgPS.AddArgument($clipSync)

    try { $script:connectAsyncHandle = $script:connectBgPS.BeginInvoke() }
    catch {
        Complete-PendingConnect
        [System.Windows.MessageBox]::Show("Failed to start connection:`n$($_.Exception.Message)","VNC","OK","Error")
        return
    }

    # Poll the background job from the UI thread so the UI keeps pumping messages
    if ($null -ne $script:connectPollTimer) { $script:connectPollTimer.Stop() }
    $script:connectPollTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:connectPollTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:connectPollTimer.Add_Tick({ Complete-PendingConnect -IfDone })
    $script:connectPollTimer.Start()
}

function Complete-PendingConnect {
    param([switch]$IfDone)

    if ($null -eq $script:connectAsyncHandle) { return }
    if ($IfDone -and -not $script:connectAsyncHandle.IsCompleted) { return }

    $script:connectPollTimer.Stop()
    $window.Cursor = $null

    $ne = $script:pendingConnect
    $sk = $script:pendingConnectKey
    $h  = $script:pendingConnectHost
    $p  = $script:pendingConnectPort
    $pw = $script:pendingConnectPw

    $ok = $false
    try {
        $result = $script:connectBgPS.EndInvoke($script:connectAsyncHandle)
        if ($result -and $result.Count -gt 0) { $ok = [bool]$result[0] }
    } catch {
        $ok = $false
    }
    try { $script:connectBgPS.Dispose() } catch {}
    try { $script:connectRunspace.Close() } catch {}
    try { $script:connectRunspace.Dispose() } catch {}

    $script:connectAsyncHandle = $null
    $script:connectBgPS        = $null
    $script:connectRunspace    = $null

    # Reset Disconnect button back to normal label/behaviour
    $btnDisconnect.Content = "Disconnect"

    if ($script:connectCancelled) {
        # User cancelled – just clean up
        if ($null -ne $ne) { $ne.Disconnect() }
        $btnConnect.IsEnabled       = $true
        $txtHost.IsEnabled          = $true
        $txtPort.IsEnabled          = $true
        $txtPassword.IsEnabled      = $true
        $txtPasswordVisible.IsEnabled = $true
        $btnTogglePw.IsEnabled      = $true
        $btnDisconnect.IsEnabled    = $false
        $statusDot.Fill = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0xFF,0x44,0x44)))
        $txtStatus.Text = "Cancelled"
        $script:pendingConnect = $null
        return
    }

    if ($ok) {
        $fw = $ne.FramebufferWidth; $fh = $ne.FramebufferHeight; $name = $ne.DesktopName
        $script:vncEngine = $ne
        $script:activeSessionKey = $sk
        $script:activeSessions[$sk] = $ne
        Add-ToHistory -H $h -P $p -N $name -PW $pw
        $entry = Find-HistoryEntry $sk
        $dn = $(if ($null -ne $entry) { Get-SessionDisplayName $entry } else { $sk })
        if ($script:fitMode) { Apply-FitMode } else { $vncCanvas.Width = $fw; $vncCanvas.Height = $fh }
        Set-Connected $true
        $txtStatus.Text = "Connected - $dn"
        $txtResolution.Text = "${fw} x ${fh}"
        $vncCanvas.Focus()
        $script:updateTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:updateTimer.Interval = [TimeSpan]::FromMilliseconds($script:vncSettings.RefreshRate)
        $script:updateTimer.Add_Tick({ Update-Frame })
        $script:updateTimer.Start()
        Update-SessionPanel
    } else {
        $err = if ($null -ne $ne) { $ne.LastError } else { "Unknown error" }
        if ($null -ne $ne) { $ne.Disconnect() }
        $btnConnect.IsEnabled       = $true
        $txtHost.IsEnabled          = $true
        $txtPort.IsEnabled          = $true
        $txtPassword.IsEnabled      = $true
        $txtPasswordVisible.IsEnabled = $true
        $btnTogglePw.IsEnabled      = $true
        $btnDisconnect.IsEnabled    = $false
        $statusDot.Fill = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0xFF,0x44,0x44)))
        $txtStatus.Text = "Failed: $err"
        if ($null -ne $script:activeSessionKey -and $script:activeSessions.ContainsKey($script:activeSessionKey)) {
            Switch-ToSession $script:activeSessionKey
        } else {
            $noConnectionOverlay.Visibility = [System.Windows.Visibility]::Visible
        }
        [System.Windows.MessageBox]::Show("Connection failed:`n$err","VNC","OK","Error")
    }

    $script:pendingConnect = $null
}

function Cancel-PendingConnect {
    if ($null -eq $script:connectAsyncHandle -or $script:connectAsyncHandle.IsCompleted) { return $false }
    $script:connectCancelled = $true
    # Forcing the TcpClient closed will cause ConnectAsync.Wait() to return promptly
    if ($null -ne $script:pendingConnect) {
        try { $script:pendingConnect.Disconnect() } catch {}
    }
    return $true
}

# ============================================================
# CLIPBOARD AUTO-SYNC
# ============================================================
function Sync-Clipboard {
    if($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected){return}
    if(-not $script:vncSettings.ClipboardSync){return}
    # Server -> Local
    if($script:vncEngine.HasNewServerClipboard){
        $script:vncEngine.HasNewServerClipboard=$false
        $srvTxt=$script:vncEngine.ServerClipboard
        if($srvTxt){
            try{
                $curLocal=""
                try{if([System.Windows.Clipboard]::ContainsText()){$curLocal=[System.Windows.Clipboard]::GetText()}}catch{}
                if($curLocal -ne $srvTxt){
                    [System.Windows.Clipboard]::SetText($srvTxt)
                    $script:lastLocalClipboard=$srvTxt
                }
            }catch{}
        }
    }
    # Local -> Server
    try{
        if([System.Windows.Clipboard]::ContainsText()){
            $lt=[System.Windows.Clipboard]::GetText()
            if($lt -and $lt -ne $script:lastLocalClipboard){
                $script:lastLocalClipboard=$lt
                $script:vncEngine.SendClientCutText($lt)
            }
        }
    }catch{}
}

# ============================================================
# LOAD
# ============================================================
Load-SessionHistory; Load-VncSettings
Update-SessionPanel

# ============================================================
# EVENT HANDLERS
# ============================================================
 $btnConnect.Add_Click({ Do-Connect })
 $btnDisconnect.Add_Click({
    if (Cancel-PendingConnect) { return }
    if ($null -ne $script:activeSessionKey) { Disconnect-Session $script:activeSessionKey }
    else { Stop-VncSession }
})
 $btnRefresh.Add_Click({if($null -ne $script:vncEngine -and $script:vncEngine.IsConnected){$script:vncEngine.RequestFullRefresh()}; $vncCanvas.Focus()})
 $btnCtrlAltDel.Add_Click({if($null -ne $script:vncEngine -and $script:vncEngine.IsConnected){$script:vncEngine.SendKey(0xFFE3,$true);$script:vncEngine.SendKey(0xFFE9,$true);$script:vncEngine.SendKey(0xFFFF,$true);Start-Sleep -Milliseconds 50;$script:vncEngine.SendKey(0xFFFF,$false);$script:vncEngine.SendKey(0xFFE9,$false);$script:vncEngine.SendKey(0xFFE3,$false)}; $vncCanvas.Focus()})
 $btnWinKey.Add_Click({if($null -ne $script:vncEngine -and $script:vncEngine.IsConnected){$script:vncEngine.SendKey(0xFFEB,$true);Start-Sleep -Milliseconds 50;$script:vncEngine.SendKey(0xFFEB,$false)}; $vncCanvas.Focus()})
 $btnFitWindow.Add_Click({if($null -eq $script:vncEngine){return};$script:fitMode=-not $script:fitMode;if($script:fitMode){$btnFitWindow.Content="1:1 Mode";Apply-FitMode}else{$btnFitWindow.Content="Fit Window";Remove-FitMode}; $vncCanvas.Focus()})
 $btnFullScreen.Add_Click({if($script:isFullScreen){Exit-FullScreen}else{Enter-FullScreen}; $vncCanvas.Focus()})
 $btnClipboard.Add_Click({ Show-ClipboardDialog })
 $btnSettings.Add_Click({Show-SettingsDialog})
 $btnTogglePanel.Add_Click({Toggle-SidePanel})
 $btnClearHistory.Add_Click({$script:recentSessions.Clear();Save-SessionHistory;Update-SessionPanel})

# Password visibility toggle
 $btnTogglePw.Add_Click({
    if(-not $script:pwVisible){
        $script:syncingPw=$true
        $txtPasswordVisible.Text=$txtPassword.Password
        $script:syncingPw=$false
        $txtPassword.Visibility=[System.Windows.Visibility]::Collapsed
        $txtPasswordVisible.Visibility=[System.Windows.Visibility]::Visible
        $btnTogglePw.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0,0x78,0xD4)))
        $btnTogglePw.Foreground=[System.Windows.Media.Brushes]::White
        $script:pwVisible=$true
        $txtPasswordVisible.Focus()
        $txtPasswordVisible.SelectAll()
    } else {
        $script:syncingPw=$true
        $txtPassword.Password=$txtPasswordVisible.Text
        $script:syncingPw=$false
        $txtPassword.Visibility=[System.Windows.Visibility]::Visible
        $txtPasswordVisible.Visibility=[System.Windows.Visibility]::Collapsed
        $btnTogglePw.Background=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x2D,0x2D,0x30)))
        $btnTogglePw.Foreground=(New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0xCC,0xCC,0xCC)))
        $script:pwVisible=$false
        $txtPassword.Focus()
    }
})

# Keep PasswordBox and TextBox in sync
 $txtPassword.Add_PasswordChanged({
    if($script:syncingPw){return}
    $script:syncingPw=$true
    $txtPasswordVisible.Text=$txtPassword.Password
    $script:syncingPw=$false
})
 $txtPasswordVisible.Add_TextChanged({
    if($script:syncingPw){return}
    $script:syncingPw=$true
    $txtPassword.Password=$txtPasswordVisible.Text
    $script:syncingPw=$false
})

# Enter key in host/port/password triggers connect
 $txtHost.Add_KeyDown({param($s,$e);if($e.Key -eq [System.Windows.Input.Key]::Return -and $btnConnect.IsEnabled){Do-Connect;$e.Handled=$true}})
 $txtPort.Add_KeyDown({param($s,$e);if($e.Key -eq [System.Windows.Input.Key]::Return -and $btnConnect.IsEnabled){Do-Connect;$e.Handled=$true}})
 $txtPassword.Add_KeyDown({param($s,$e);if($e.Key -eq [System.Windows.Input.Key]::Return -and $btnConnect.IsEnabled){Do-Connect;$e.Handled=$true}})
 $txtPasswordVisible.Add_KeyDown({param($s,$e);if($e.Key -eq [System.Windows.Input.Key]::Return -and $btnConnect.IsEnabled){Do-Connect;$e.Handled=$true}})

# Fullscreen bar
 $btnFsWindowed.Add_Click({Exit-FullScreen; $vncCanvas.Focus()})
 $btnFsRefresh.Add_Click({if($null -ne $script:vncEngine -and $script:vncEngine.IsConnected){$script:vncEngine.RequestFullRefresh()}; $vncCanvas.Focus()})
 $btnFsCtrlAltDel.Add_Click({if($null -ne $script:vncEngine -and $script:vncEngine.IsConnected){$script:vncEngine.SendKey(0xFFE3,$true);$script:vncEngine.SendKey(0xFFE9,$true);$script:vncEngine.SendKey(0xFFFF,$true);Start-Sleep -Milliseconds 50;$script:vncEngine.SendKey(0xFFFF,$false);$script:vncEngine.SendKey(0xFFE9,$false);$script:vncEngine.SendKey(0xFFE3,$false)}; $vncCanvas.Focus()})
 $btnFsWinKey.Add_Click({if($null -ne $script:vncEngine -and $script:vncEngine.IsConnected){$script:vncEngine.SendKey(0xFFEB,$true);Start-Sleep -Milliseconds 50;$script:vncEngine.SendKey(0xFFEB,$false)}; $vncCanvas.Focus()})
 $btnFsClipboard.Add_Click({ Show-ClipboardDialog })
 $btnFsDisconnect.Add_Click({if($null -ne $script:activeSessionKey){Disconnect-Session $script:activeSessionKey}else{Stop-VncSession}; $vncCanvas.Focus()})
 $fsHoverZone.Add_MouseEnter({if($script:isFullScreen){Show-FullscreenBar}})
 $fullscreenBar.Add_MouseEnter({if($null -ne $script:fsBarTimer){$script:fsBarTimer.Stop()}})
 $fullscreenBar.Add_MouseLeave({if($script:isFullScreen -and $script:fsBarVisible){if($null -ne $script:fsBarTimer){$script:fsBarTimer.Stop()};$script:fsBarTimer=New-Object System.Windows.Threading.DispatcherTimer;$script:fsBarTimer.Interval=[TimeSpan]::FromSeconds(1.5);$script:fsBarTimer.Add_Tick({$script:fsBarTimer.Stop();Hide-FullscreenBar});$script:fsBarTimer.Start()}})
 $window.Add_PreviewMouseMove({param($s,$e);if(-not $script:isFullScreen){return};$pos=$e.GetPosition($window);if($pos.Y -le 8){$wc=$window.ActualWidth/2;if([Math]::Abs($pos.X-$wc) -lt 200){Show-FullscreenBar}}})
 $window.Add_PreviewKeyDown({param($s,$e);if($script:isFullScreen -and $e.Key -eq [System.Windows.Input.Key]::Escape){Exit-FullScreen;$e.Handled=$true}})

# Mouse
 $vncCanvas.Add_MouseMove({param($s,$e);if($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected){return};$p=Get-ScaledPos $e;$script:vncEngine.SendPointer($script:buttonMask,$p.X,$p.Y)})
 $vncCanvas.Add_MouseDown({param($s,$e);if($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected){return}
    $s.Focus() | Out-Null
    switch($e.ChangedButton){([System.Windows.Input.MouseButton]::Left){$script:buttonMask=$script:buttonMask-bor 1}([System.Windows.Input.MouseButton]::Middle){$script:buttonMask=$script:buttonMask-bor 2}([System.Windows.Input.MouseButton]::Right){$script:buttonMask=$script:buttonMask-bor 4}}
    $p=Get-ScaledPos $e;$script:vncEngine.SendPointer($script:buttonMask,$p.X,$p.Y);$s.CaptureMouse();$e.Handled=$true})
 $vncCanvas.Add_MouseUp({param($s,$e);if($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected){return}
    switch($e.ChangedButton){([System.Windows.Input.MouseButton]::Left){$script:buttonMask=$script:buttonMask-band(-bnot 1)}([System.Windows.Input.MouseButton]::Middle){$script:buttonMask=$script:buttonMask-band(-bnot 2)}([System.Windows.Input.MouseButton]::Right){$script:buttonMask=$script:buttonMask-band(-bnot 4)}}
    $p=Get-ScaledPos $e;$script:vncEngine.SendPointer($script:buttonMask,$p.X,$p.Y);$s.ReleaseMouseCapture();$e.Handled=$true})
 $vncCanvas.Add_MouseWheel({param($s,$e);if($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected){return};$p=Get-ScaledPos $e;$sb=$(if($e.Delta -gt 0){8}else{16});$script:vncEngine.SendPointer(($script:buttonMask-bor $sb),$p.X,$p.Y);$script:vncEngine.SendPointer($script:buttonMask,$p.X,$p.Y);$e.Handled=$true})

# Keyboard
 $vncCanvas.Add_PreviewKeyDown({param($s,$e);if($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected){return};$key=$(if($e.Key -eq [System.Windows.Input.Key]::System){$e.SystemKey}else{$e.Key});$shift=(([System.Windows.Input.Keyboard]::Modifiers)-band[System.Windows.Input.ModifierKeys]::Shift)-ne 0;$ks=[KeysymMap]::GetKeysym($key,$shift);if($ks -ne 0){$script:vncEngine.SendKey($ks,$true);$e.Handled=$true}})
 $vncCanvas.Add_PreviewKeyUp({param($s,$e);if($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected){return};$key=$(if($e.Key -eq [System.Windows.Input.Key]::System){$e.SystemKey}else{$e.Key});$shift=(([System.Windows.Input.Keyboard]::Modifiers)-band[System.Windows.Input.ModifierKeys]::Shift)-ne 0;$ks=[KeysymMap]::GetKeysym($key,$shift);if($ks -ne 0){$script:vncEngine.SendKey($ks,$false);$e.Handled=$true}})
 $vncCanvas.Add_PreviewTextInput({param($s,$e);if($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected){return};foreach($ch in $e.Text.ToCharArray()){$sym=[uint32][char]$ch;if($sym -gt 0 -and $sym -lt 0x100){$script:vncEngine.SendKey($sym,$true);$script:vncEngine.SendKey($sym,$false)}};$e.Handled=$true})
 $vncCanvas.Add_GotFocus({$vncCanvas.Cursor=[System.Windows.Input.Cursors]::None})
 $vncCanvas.Add_LostFocus({$vncCanvas.Cursor=$null})

# ============================================================
# TIMERS
# ============================================================
# Stats timer (1 Hz) - updates stats display and prunes dead sessions
 $script:statsTimer=New-Object System.Windows.Threading.DispatcherTimer;$script:statsTimer.Interval=[TimeSpan]::FromSeconds(1)
 $script:statsTimer.Add_Tick({
    Update-Stats
    if($script:panelOpen){$dead=@();foreach($k in @($script:activeSessions.Keys)){if(-not $script:activeSessions[$k].IsConnected){$dead+=$k}};if($dead.Count -gt 0){foreach($dk in $dead){$script:activeSessions[$dk].Disconnect();$script:activeSessions.Remove($dk)};Update-SessionPanel}}
})
 $script:statsTimer.Start()

# Clipboard timer (4 Hz) - faster polling for responsive clipboard sync
 $script:clipTimer=New-Object System.Windows.Threading.DispatcherTimer;$script:clipTimer.Interval=[TimeSpan]::FromMilliseconds(250)
 $script:clipTimer.Add_Tick({Sync-Clipboard})
 $script:clipTimer.Start()

 $window.Add_Closing({
    if ($null -ne $script:statsTimer)    { $script:statsTimer.Stop() }
    if ($null -ne $script:clipTimer)     { $script:clipTimer.Stop() }
    if ($null -ne $script:fsBarTimer)    { $script:fsBarTimer.Stop() }
    if ($null -ne $script:connectPollTimer) { $script:connectPollTimer.Stop() }
    if ($null -ne $script:connectAsyncHandle -and -not $script:connectAsyncHandle.IsCompleted) {
        $script:connectCancelled = $true
        if ($null -ne $script:pendingConnect) { try { $script:pendingConnect.Disconnect() } catch {} }
        try { if ($null -ne $script:connectBgPS) { $script:connectBgPS.EndInvoke($script:connectAsyncHandle) } } catch {}
    }
    if ($null -ne $script:connectBgPS)     { try { $script:connectBgPS.Dispose() } catch {} }
    if ($null -ne $script:connectRunspace) { try { $script:connectRunspace.Close() } catch {}; try { $script:connectRunspace.Dispose() } catch {} }
    Stop-VncSession
})

 $window.ShowDialog() | Out-Null
