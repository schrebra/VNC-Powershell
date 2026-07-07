# 1. PRE-FLIGHT CHECK: Kill any process holding port 5900
 $port = 5900
Write-Host "Checking if port $port is already in use..." -ForegroundColor Cyan
 $connections = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue

if ($connections) {
    foreach ($conn in $connections) {
        $procId = $conn.OwningProcess
        $process = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($process) {
            Write-Host "Port $port is in use by $($process.Name) (PID: $procId). Killing it..." -ForegroundColor Yellow
            Stop-Process -Id $procId -Force
            Start-Sleep -Seconds 1
        }
    }
    Write-Host "Port cleared." -ForegroundColor Green
} else {
    Write-Host "Port $port is free." -ForegroundColor Green
}

# 2. DEFINE THE C# SERVER CODE
 $CSharpCode = @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace PwshVnc
{
    public class VncServer
    {
        private TcpListener _listener;
        private int _port;
        private Thread _serverThread;
        private bool _running;

        private const uint MOUSEEVENTF_LEFTDOWN = 0x02;
        private const uint MOUSEEVENTF_LEFTUP = 0x04;
        private const uint MOUSEEVENTF_RIGHTDOWN = 0x08;
        private const uint MOUSEEVENTF_RIGHTUP = 0x10;
        private const uint MOUSEEVENTF_MIDDLEDOWN = 0x20;
        private const uint MOUSEEVENTF_MIDDLEUP = 0x40;
        private const uint MOUSEEVENTF_WHEEL = 0x0800;
        private const uint WHEEL_DELTA = 120;
        private const uint KEYEVENTF_KEYUP = 0x0002;

        [DllImport("user32.dll")]
        private static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        private static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo);

        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);

        private static object _logLock = new object();
        private static void Log(string msg)
        {
            try
            {
                lock (_logLock)
                {
                    System.IO.File.AppendAllText("C:\\vnc_log.txt", DateTime.Now.ToString("HH:mm:ss.fff") + " " + msg + Environment.NewLine);
                }
            }
            catch { }
        }

        public VncServer(int port)
        {
            _port = port;
            System.IO.File.Delete("C:\\vnc_log.txt");
        }

        public void Start()
        {
            try
            {
                _running = true;
                _listener = new TcpListener(IPAddress.Any, _port);
                _listener.Start();
                _serverThread = new Thread(ClientHandlerLoop);
                _serverThread.IsBackground = true;
                _serverThread.Start();
                Log("Listener successfully started on port " + _port);
            }
            catch (Exception ex)
            {
                Log("FATAL ERROR starting listener: " + ex.Message);
            }
        }

        public void Stop()
        {
            _running = false;
            if (_listener != null) _listener.Stop();
        }

        private void ClientHandlerLoop()
        {
            while (_running)
            {
                try
                {
                    Log("Waiting for client connection...");
                    TcpClient client = _listener.AcceptTcpClient();
                    Log("Client connected!");
                    Thread clientThread = new Thread(() => HandleClient(client));
                    clientThread.IsBackground = true;
                    clientThread.Start();
                }
                catch (Exception ex)
                {
                    Log("Listener Error: " + ex.Message);
                }
            }
        }

        private void HandleClient(TcpClient client)
        {
            client.NoDelay = true;
            using (NetworkStream stream = client.GetStream())
            {
                try
                {
                    Log("HandleClient started.");
                    
                    byte[] protocolVersion = System.Text.Encoding.ASCII.GetBytes("RFB 003.008\n");
                    stream.Write(protocolVersion, 0, protocolVersion.Length);
                    Log("Sent Protocol Version.");
                    
                    ReadExact(stream, 12); 
                    Log("Received Client Protocol Version.");

                    stream.WriteByte(1); stream.WriteByte(1);
                    stream.ReadByte(); 
                    Log("Security Handshake complete.");
                    
                    byte[] secResult = BitConverter.GetBytes(0);
                    if (BitConverter.IsLittleEndian) Array.Reverse(secResult);
                    stream.Write(secResult, 0, secResult.Length);

                    stream.ReadByte(); 
                    Log("Client Init received.");

                    int screenWidth = Screen.PrimaryScreen.Bounds.Width;
                    int screenHeight = Screen.PrimaryScreen.Bounds.Height;
                    Log("Screen Resolution: " + screenWidth + "x" + screenHeight);
                    
                    using (MemoryStream initMs = new MemoryStream())
                    {
                        byte[] w = BitConverter.GetBytes((ushort)screenWidth);
                        byte[] h = BitConverter.GetBytes((ushort)screenHeight);
                        if (BitConverter.IsLittleEndian) { Array.Reverse(w); Array.Reverse(h); }
                        initMs.Write(w, 0, 2); initMs.Write(h, 0, 2);

                        initMs.WriteByte(32); initMs.WriteByte(24); initMs.WriteByte(0); initMs.WriteByte(1);
                        initMs.WriteByte(0); initMs.WriteByte(255); initMs.WriteByte(0); initMs.WriteByte(255);
                        initMs.WriteByte(0); initMs.WriteByte(255); initMs.WriteByte(16); initMs.WriteByte(8);
                        initMs.WriteByte(0); initMs.WriteByte(0); initMs.WriteByte(0); initMs.WriteByte(0);

                        byte[] nameBytes = System.Text.Encoding.ASCII.GetBytes("PowerShell VNC");
                        byte[] nameLen = BitConverter.GetBytes((uint)nameBytes.Length);
                        if (BitConverter.IsLittleEndian) Array.Reverse(nameLen);
                        initMs.Write(nameLen, 0, 4);
                        initMs.Write(nameBytes, 0, nameBytes.Length);

                        byte[] initPayload = initMs.ToArray();
                        stream.Write(initPayload, 0, initPayload.Length);
                    }
                    Log("Server Init sent. Entering main loop.");

                    byte prevButtonMask = 0; 

                    while (_running && client.Connected)
                    {
                        if (stream.DataAvailable)
                        {
                            int msgType = stream.ReadByte();
                            if (msgType == -1) break;

                            try
                            {
                                if (msgType == 0) // SetPixelFormat
                                {
                                    ReadExact(stream, 19); 
                                }
                                else if (msgType == 2) // SetEncodings
                                {
                                    byte[] padCount = ReadExact(stream, 3); 
                                    short count = (short)((padCount[1] << 8) | padCount[2]);
                                    ReadExact(stream, count * 4); 
                                }
                                else if (msgType == 3) // FramebufferUpdateRequest
                                {
                                    ReadExact(stream, 9); 
                                    SendFrameBufferUpdate(stream, screenWidth, screenHeight);
                                }
                                else if (msgType == 4) // KeyEvent
                                {
                                    byte[] payload = ReadExact(stream, 7);
                                    byte downFlag = payload[0];
                                    uint keysym = (uint)((payload[3] << 24) | (payload[4] << 16) | (payload[5] << 8) | payload[6]);
                                    
                                    byte vk = GetVkFromKeysym(keysym);
                                    if (vk != 0)
                                    {
                                        if (downFlag == 1) keybd_event(vk, 0, 0, 0); 
                                        else keybd_event(vk, 0, KEYEVENTF_KEYUP, 0); 
                                    }
                                }
                                else if (msgType == 5) // PointerEvent (Mouse)
                                {
                                    byte[] payload = ReadExact(stream, 5);
                                    byte buttonMask = payload[0];
                                    ushort x = (ushort)((payload[1] << 8) | payload[2]);
                                    ushort y = (ushort)((payload[3] << 8) | payload[4]);

                                    SetCursorPos(x, y);

                                    if ((buttonMask & 1) != (prevButtonMask & 1))
                                    {
                                        if ((buttonMask & 1) != 0) mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
                                        else mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
                                    }
                                    if ((buttonMask & 2) != (prevButtonMask & 2))
                                    {
                                        if ((buttonMask & 2) != 0) mouse_event(MOUSEEVENTF_MIDDLEDOWN, 0, 0, 0, 0);
                                        else mouse_event(MOUSEEVENTF_MIDDLEUP, 0, 0, 0, 0);
                                    }
                                    if ((buttonMask & 4) != (prevButtonMask & 4))
                                    {
                                        if ((buttonMask & 4) != 0) mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, 0);
                                        else mouse_event(MOUSEEVENTF_RIGHTUP, 0, 0, 0, 0);
                                    }
                                    if ((buttonMask & 8) != 0 && (prevButtonMask & 8) == 0)
                                    {
                                        mouse_event(MOUSEEVENTF_WHEEL, 0, 0, WHEEL_DELTA, 0);
                                    }
                                    if ((buttonMask & 16) != 0 && (prevButtonMask & 16) == 0)
                                    {
                                        mouse_event(MOUSEEVENTF_WHEEL, 0, 0, unchecked((uint)(-WHEEL_DELTA)), 0);
                                    }

                                    prevButtonMask = buttonMask;
                                }
                                else if (msgType == 6) // ClientCutText
                                {
                                    byte[] payload = ReadExact(stream, 7);
                                    int length = (int)((payload[3] << 24) | (payload[4] << 16) | (payload[5] << 8) | payload[6]);
                                    ReadExact(stream, length);
                                }
                                else
                                {
                                    Log("ERROR: Unknown MsgType " + msgType + " received. Disconnecting.");
                                    break;
                                }
                            }
                            catch (IOException) { break; } 
                        }
                        else
                        {
                            Thread.Sleep(10);
                        }
                    }
                    Log("Client disconnected normally.");
                }
                catch (Exception ex)
                {
                    Log("Client Handler Error: " + ex.ToString());
                }
            }
        }

        private static byte[] ReadExact(Stream stream, int count)
        {
            byte[] buffer = new byte[count];
            int read = 0;
            while (read < count)
            {
                int r = stream.Read(buffer, read, count - read);
                if (r <= 0) throw new IOException("Client disconnected");
                read += r;
            }
            return buffer;
        }

        private static byte GetVkFromKeysym(uint keysym)
        {
            if (keysym >= 0x61 && keysym <= 0x7A) return (byte)(keysym - 0x20); 
            if (keysym >= 0x41 && keysym <= 0x5A) return (byte)keysym;         
            if (keysym >= 0x30 && keysym <= 0x39) return (byte)keysym;         

            switch (keysym)
            {
                case 0xFF0D: return 0x0D; 
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
                case 0xFFE1: case 0xFFE2: return 0x10; 
                case 0xFFE3: case 0xFFE4: return 0x11; 
                case 0xFFE9: case 0xFFEA: return 0x12; 
                case 0x0020: return 0x20; 
                default: return 0; 
            }
        }

        private void SendFrameBufferUpdate(NetworkStream stream, int width, int height)
        {
            byte[] rawPixels = new byte[width * height * 4]; 
            
            try 
            {
                Bitmap bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
                Graphics g = Graphics.FromImage(bmp);
                g.CopyFromScreen(0, 0, 0, 0, bmp.Size, CopyPixelOperation.SourceCopy);
                g.Dispose();

                BitmapData bmpData = bmp.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, bmp.PixelFormat);
                int byteCount = Math.Abs(bmpData.Stride) * height;
                rawPixels = new byte[byteCount];
                Marshal.Copy(bmpData.Scan0, rawPixels, 0, byteCount);
                bmp.UnlockBits(bmpData);
                bmp.Dispose();
            }
            catch (Exception ex)
            {
                Log("Screen capture failed: " + ex.Message);
                // If screen capture fails (e.g., RDP window is closed), draw a red screen
                // so the VNC client doesn't crash, and we keep the connection alive.
                for (int i = 0; i < rawPixels.Length; i += 4)
                {
                    rawPixels[i] = 0;     // B
                    rawPixels[i + 1] = 0; // G
                    rawPixels[i + 2] = 255; // R
                    rawPixels[i + 3] = 255; // A
                }
            }

            using (MemoryStream ms = new MemoryStream())
            {
                ms.WriteByte(0); ms.WriteByte(0); 
                byte[] numRects = BitConverter.GetBytes((ushort)1);
                if (BitConverter.IsLittleEndian) Array.Reverse(numRects);
                ms.Write(numRects, 0, 2);

                byte[] x = BitConverter.GetBytes((ushort)0);
                byte[] y = BitConverter.GetBytes((ushort)0);
                byte[] w = BitConverter.GetBytes((ushort)width);
                byte[] hh = BitConverter.GetBytes((ushort)height);
                byte[] enc = BitConverter.GetBytes((uint)0);
                if (BitConverter.IsLittleEndian) { Array.Reverse(x); Array.Reverse(y); Array.Reverse(w); Array.Reverse(hh); Array.Reverse(enc); }
                
                ms.Write(x, 0, 2); ms.Write(y, 0, 2); ms.Write(w, 0, 2); ms.Write(hh, 0, 2);
                ms.Write(enc, 0, 4);
                ms.Write(rawPixels, 0, rawPixels.Length);

                byte[] updatePacket = ms.ToArray();
                stream.Write(updatePacket, 0, updatePacket.Length);
            }
        }
    }
}
"@

# 3. COMPILE THE C# CODE
Add-Type -TypeDefinition $CSharpCode -Language CSharp -ReferencedAssemblies @("System.Drawing", "System.Windows.Forms")

# 4. START THE VNC SERVER
 $VncServer = New-Object PwshVnc.VncServer(5900)
 $VncServer.Start()

Write-Host "Interactive VNC Server started on port 5900." -ForegroundColor Green
Write-Host "Connect using a VNC Viewer to '<IP-ADDRESS>:5900'." -ForegroundColor Cyan
Write-Host "Press Ctrl+C in this window to stop the server." -ForegroundColor Yellow

try {
    while ($true) { Start-Sleep -Seconds 1 }
} finally {
    $VncServer.Stop()
    Write-Host "VNC Server stopped." -ForegroundColor Red
}
