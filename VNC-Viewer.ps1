
<#
.SYNOPSIS
    Interactive VNC Client GUI - PowerShell 5.1 / WPF / XAML
.DESCRIPTION
    Full remote desktop control over VNC (RFB 003.008).
    Theme: Catppuccin Macchiato. Adjustable left panel (size saved to INI).
    Remembers Window Width/Height. Side panel shows raw inputted host.
    Remembers password visibility, recent hosts and recent passwords (INI).
    Paste-from-clipboard button next to host input.
    Dark mode confirmation and error prompts with custom title bar.
    Disabled buttons are hidden instead of greyed out.
    Removed Ctrl+Alt+Del, Refresh, and Win buttons.
    Removed rename and name additions entirely.
    Dropdowns for hosts/passwords limited to a configurable amount (default 5).
    Dark themed scrollbars applied globally (incl. left panel sessions) - made thicker.
    Pinned/Recent sessions show condensed single-line host (no port line).
    Password/Host history dropdown arrow has hover highlight color but text is black.
    Hostnames/IPs strictly validated (no spaces, no full text pages allowed).
    Input boxes and dropdowns matched perfectly to 32px height.
#>

# ============================================================
# CONFIGURATION
# ============================================================
$DefaultHost        = ""
$DefaultPort        = "5900"
$DefaultPassword    = ""
$SessionHistoryFile = [System.IO.Path]::Combine($env:APPDATA, "VncClient_Sessions.json")
$SettingsFile       = [System.IO.Path]::Combine($env:APPDATA, "VncClient_Settings.json")
$ConfigIniFile      = [System.IO.Path]::Combine($env:APPDATA, "VncClient_Config.ini")

# ============================================================
# ASSEMBLIES
# ============================================================
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Drawing

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
    private TcpClient _tcp; private NetworkStream _stream;
    private string _host,_password,_desktopName,_lastError,_serverClipboard,_lastSentClipboard;
    private int _port,_fbWidth,_fbHeight,_frameCount,_fpsFrameCount;
    private byte[] _frameBuffer;
    private volatile bool _connected,_running,_viewOnly,_sharedConnection,_clipboardSync,_hasNewServerClipboard;
    private Thread _readThread;
    private object _writeLock=new object(), _bufferLock=new object();
    private volatile int _frameVersion;
    private long _bytesReceived,_lastPingMs;
    private Stopwatch _connTimer,_fpsTimer;
    private double _currentFps;

    public int FramebufferWidth{get{return _fbWidth;}}
    public int FramebufferHeight{get{return _fbHeight;}}
    public string DesktopName{get{return _desktopName;}}
    public string LastError{get{return _lastError;}}
    public bool IsConnected{get{return _connected;}}
    public int FrameVersion{get{return _frameVersion;}}
    public string Host{get{return _host;}}
    public int Port{get{return _port;}}
    public long BytesReceived{get{return _bytesReceived;}}
    public int FrameCount{get{return _frameCount;}}
    public double CurrentFps{get{return _currentFps;}}
    public long UptimeMs{get{return _connTimer!=null?_connTimer.ElapsedMilliseconds:0;}}
    public long LastPingMs{get{return _lastPingMs;}}
    public bool ViewOnly{get{return _viewOnly;}set{_viewOnly=value;}}
    public bool SharedConnection{get{return _sharedConnection;}}
    public bool ClipboardSync{get{return _clipboardSync;}set{_clipboardSync=value;}}
    public string ServerClipboard{get{return _serverClipboard;}}
    public bool HasNewServerClipboard{get{return _hasNewServerClipboard;}set{_hasNewServerClipboard=value;}}
    public ConcurrentQueue<byte[]> OutQueue=new ConcurrentQueue<byte[]>();

    public VncEngine(){_sharedConnection=true;_viewOnly=false;_clipboardSync=true;}
    public byte[] GetFrameBufferDirect(){return _frameBuffer;}

    private static byte ReverseBits(byte b){byte r=0;for(int i=0;i<8;i++)r=(byte)((r<<1)|((b>>i)&1));return r;}

    private void ReadExact(byte[] buf,int off,int cnt){int t=0;while(t<cnt){int n=_stream.Read(buf,off+t,cnt-t);if(n==0)throw new IOException("Connection closed");t+=n;_bytesReceived+=n;}}
    private byte[] ReadExact(int cnt){byte[] b=new byte[cnt];ReadExact(b,0,cnt);return b;}
    private int ReadU8(){int b=_stream.ReadByte();if(b<0)throw new IOException("Connection closed");_bytesReceived++;return b;}
    private int ReadU16BE(){byte[] b=ReadExact(2);return(b[0]<<8)|b[1];}
    private uint ReadU32BE(){byte[] b=ReadExact(4);return(uint)((b[0]<<24)|(b[1]<<16)|(b[2]<<8)|b[3]);}
    private int ReadS32BE(){return(int)ReadU32BE();}

    public bool Connect(string host,int port,string password,bool shared,bool viewOnly,bool clipSync)
    {
        _host=host;_port=port;_password=password;_lastError=null;_bytesReceived=0;_frameCount=0;
        _currentFps=0;_fpsFrameCount=0;_sharedConnection=shared;_viewOnly=viewOnly;_clipboardSync=clipSync;
        _serverClipboard=null;_hasNewServerClipboard=false;_lastSentClipboard=null;
        try{
            Stopwatch pt=Stopwatch.StartNew();
            _tcp=new TcpClient();_tcp.ReceiveBufferSize=8*1024*1024;_tcp.NoDelay=true;
            Task ct=_tcp.ConnectAsync(host,port);
            if(!ct.Wait(8000)){try{_tcp.Close();}catch{};_lastError="Connection timed out - host unreachable after 8 seconds";return false;}
            if(ct.IsFaulted){Exception bx=ct.Exception!=null?ct.Exception.GetBaseException():null;try{_tcp.Close();}catch{};_lastError=bx!=null?bx.Message:"Connection failed";return false;}
            _stream=_tcp.GetStream();_stream.ReadTimeout=30000;_stream.WriteTimeout=10000;_lastPingMs=pt.ElapsedMilliseconds;
            ReadExact(12);_stream.Write(Encoding.ASCII.GetBytes("RFB 003.008\n"),0,12);
            int sc=ReadU8();byte[] st=ReadExact(sc);bool hasA=false,hasN=false;
            for(int i=0;i<sc;i++){if(st[i]==2)hasA=true;if(st[i]==1)hasN=true;}
            if(hasA){
                _stream.WriteByte(2);byte[] ch=ReadExact(16);byte[] key=new byte[8];
                byte[] pa=Encoding.ASCII.GetBytes(password??"");
                for(int i=0;i<8;i++)key[i]=i<pa.Length?ReverseBits(pa[i]):(byte)0;
                DES des=DES.Create();des.Mode=CipherMode.ECB;des.Padding=PaddingMode.None;des.Key=key;
                ICryptoTransform enc=des.CreateEncryptor();byte[] resp=new byte[16];
                enc.TransformBlock(ch,0,8,resp,0);enc.TransformBlock(ch,8,8,resp,8);
                _stream.Write(resp,0,16);enc.Dispose();des.Dispose();
            }else if(hasN){_stream.WriteByte(1);}else{_lastError="No supported security type";return false;}
            uint ar=ReadU32BE();if(ar!=0){_lastError="Auth failed (code="+ar+")";return false;}
            _stream.WriteByte((byte)(shared?1:0));
            _fbWidth=ReadU16BE();_fbHeight=ReadU16BE();byte[] pf=ReadExact(16);
            uint nl=ReadU32BE();_desktopName=Encoding.ASCII.GetString(ReadExact((int)nl));
            lock(_bufferLock){_frameBuffer=new byte[_fbWidth*_fbHeight*4];}
            byte[] spf=new byte[20];spf[0]=0;Array.Copy(pf,0,spf,4,16);_stream.Write(spf,0,20);
            byte[] em=new byte[16];em[0]=2;em[2]=0;em[3]=3;em[11]=1;em[12]=0xFF;em[13]=0xFF;em[14]=0xFF;em[15]=0x21;_stream.Write(em,0,16);
            _connected=true;_running=true;_connTimer=Stopwatch.StartNew();_fpsTimer=Stopwatch.StartNew();
            _readThread=new Thread(ReadLoop);_readThread.IsBackground=true;_readThread.Name="VNC-Read";_readThread.Start();
            return true;
        }catch(Exception ex){_lastError=ex.Message;return false;}
    }
    public bool Connect(string host,int port,string password){return Connect(host,port,password,true,false,true);}

    private void SendFBUpdateRequest(bool inc){byte[] r=new byte[10];r[0]=3;r[1]=(byte)(inc?1:0);r[6]=(byte)((_fbWidth>>8)&0xFF);r[7]=(byte)(_fbWidth&0xFF);r[8]=(byte)((_fbHeight>>8)&0xFF);r[9]=(byte)(_fbHeight&0xFF);lock(_writeLock){try{if(_stream!=null&&_connected)_stream.Write(r,0,10);}catch{}}}

    private void CopyRectData(byte[] data,int rx,int ry,int rw,int rh){lock(_bufferLock){byte[] fb=_frameBuffer;if(fb==null)return;for(int row=0;row<rh;row++){int dy=ry+row;if(dy<0||dy>=_fbHeight)continue;int cols=Math.Min(rw,_fbWidth-rx);if(cols<=0)continue;int bytes=cols*4;int so=row*rw*4;int dof=dy*_fbWidth*4+rx*4;if(so+bytes>data.Length||dof+bytes>fb.Length)continue;Array.Copy(data,so,fb,dof,bytes);}}}

    private void HandleCopyRectEncoding(int rx,int ry,int rw,int rh){int sx=ReadU16BE(),sy=ReadU16BE();lock(_bufferLock){byte[] fb=_frameBuffer;if(fb==null)return;byte[] tmp=new byte[rw*rh*4];for(int row=0;row<rh;row++){int sy2=sy+row;if(sy2<0||sy2>=_fbHeight)continue;int cols=Math.Min(rw,_fbWidth-sx);if(cols<=0)continue;int so=sy2*_fbWidth*4+sx*4;int to=row*rw*4;int bytes=cols*4;if(so+bytes<=fb.Length&&to+bytes<=tmp.Length)Array.Copy(fb,so,tmp,to,bytes);}CopyRectData(tmp,rx,ry,rw,rh);}}

    public void SendClientCutText(string text){SendClientCutText(text,false);}
    public void SendClientCutText(string text,bool force){if(!_connected||text==null||text.Length==0)return;if(!force&&text==_lastSentClipboard)return;_lastSentClipboard=text;byte[] tb=Encoding.GetEncoding(28591).GetBytes(text);int len=tb.Length;byte[] m=new byte[8+len];m[0]=6;m[4]=(byte)((len>>24)&0xFF);m[5]=(byte)((len>>16)&0xFF);m[6]=(byte)((len>>8)&0xFF);m[7]=(byte)(len&0xFF);Array.Copy(tb,0,m,8,len);lock(_writeLock){try{if(_stream!=null&&_connected)_stream.Write(m,0,m.Length);}catch{}}}

    public void SendTextViaKeysAsync(string text){if(!_connected||_viewOnly||string.IsNullOrEmpty(text))return;Thread t=new Thread(()=>{uint[] mods={0xFFE1,0xFFE2,0xFFE3,0xFFE4,0xFFE9,0xFFEA,0xFFEB,0xFFEC};foreach(uint m in mods)SendKey(m,false);Thread.Sleep(50);foreach(char c in text){if(!_connected)return;uint sym;if(c=='\r')continue;if(c=='\n')sym=0xFF0D;else if(c=='\t')sym=0xFF09;else if(c<0x100)sym=(uint)c;else sym=0x01000000+(uint)c;SendKey(sym,true);Thread.Sleep(5);SendKey(sym,false);Thread.Sleep(5);}foreach(uint m in mods)SendKey(m,false);});t.IsBackground=true;t.Start();}

    private void ReadLoop(){try{SendFBUpdateRequest(false);while(_running&&_connected){byte[] om;while(OutQueue.TryDequeue(out om))lock(_writeLock){try{if(_stream!=null&&_connected)_stream.Write(om,0,om.Length);}catch{}}if(!_stream.DataAvailable){Thread.Sleep(5);continue;}int mt=ReadU8();switch(mt){case 0:ReadU8();int nr=ReadU16BE();for(int r=0;r<nr;r++){int rx=ReadU16BE(),ry=ReadU16BE(),rw=ReadU16BE(),rh=ReadU16BE();int et=ReadS32BE();if(et==0){if(rw>0&&rh>0)CopyRectData(ReadExact(rw*rh*4),rx,ry,rw,rh);}else if(et==1){HandleCopyRectEncoding(rx,ry,rw,rh);}else if(et==-223||et==-239){lock(_bufferLock){_fbWidth=rw;_fbHeight=rh;_frameBuffer=new byte[rw*rh*4];}}else break;}_frameVersion++;_frameCount++;_fpsFrameCount++;if(_fpsTimer.ElapsedMilliseconds>=1000){_currentFps=_fpsFrameCount*1000.0/_fpsTimer.ElapsedMilliseconds;_fpsFrameCount=0;_fpsTimer.Restart();}SendFBUpdateRequest(true);break;case 1:ReadU8();ReadU16BE();ReadExact(ReadU16BE()*6);break;case 2:break;case 3:ReadExact(3);uint tl=ReadU32BE();if(tl>0&&tl<10*1024*1024){byte[] td=ReadExact((int)tl);if(_clipboardSync){_serverClipboard=Encoding.GetEncoding(28591).GetString(td);_hasNewServerClipboard=true;}}break;default:Thread.Sleep(10);break;}}}catch(Exception ex){if(_running){_lastError="Read error: "+ex.Message;_connected=false;}}}

    public void SendPointer(int bm,int x,int y){if(!_connected||_viewOnly)return;OutQueue.Enqueue(new byte[]{5,(byte)bm,(byte)((x>>8)&0xFF),(byte)(x&0xFF),(byte)((y>>8)&0xFF),(byte)(y&0xFF)});}
    public void SendKey(uint ks,bool down){if(!_connected||_viewOnly)return;OutQueue.Enqueue(new byte[]{4,(byte)(down?1:0),0,0,(byte)((ks>>24)&0xFF),(byte)((ks>>16)&0xFF),(byte)((ks>>8)&0xFF),(byte)(ks&0xFF)});}
    public void RequestFullRefresh(){if(!_connected)return;byte[] r=new byte[10];r[0]=3;r[6]=(byte)((_fbWidth>>8)&0xFF);r[7]=(byte)(_fbWidth&0xFF);r[8]=(byte)((_fbHeight>>8)&0xFF);r[9]=(byte)(_fbHeight&0xFF);OutQueue.Enqueue(r);}
    public void Disconnect(){_running=false;_connected=false;if(_connTimer!=null)_connTimer.Stop();if(_fpsTimer!=null)_fpsTimer.Stop();try{if(_stream!=null)_stream.Close();}catch{}try{if(_tcp!=null)_tcp.Close();}catch{}}
    public void Dispose(){Disconnect();}
}
'@

$KeysymMapCode = @'
using System.Collections.Generic;
using System.Windows.Input;
public static class KeysymMap
{
    private static Dictionary<Key,uint> _map,_shiftMap;
    static KeysymMap(){
        _map=new Dictionary<Key,uint>();
        _map[Key.F1]=0xFFBE;_map[Key.F2]=0xFFBF;_map[Key.F3]=0xFFC0;_map[Key.F4]=0xFFC1;_map[Key.F5]=0xFFC2;_map[Key.F6]=0xFFC3;_map[Key.F7]=0xFFC4;_map[Key.F8]=0xFFC5;_map[Key.F9]=0xFFC6;_map[Key.F10]=0xFFC7;_map[Key.F11]=0xFFC8;_map[Key.F12]=0xFFC9;
        _map[Key.LeftShift]=0xFFE1;_map[Key.RightShift]=0xFFE2;_map[Key.LeftCtrl]=0xFFE3;_map[Key.RightCtrl]=0xFFE4;_map[Key.LeftAlt]=0xFFE9;_map[Key.RightAlt]=0xFFEA;_map[Key.LWin]=0xFFEB;_map[Key.RWin]=0xFFEC;
        _map[Key.Return]=0xFF0D;_map[Key.Escape]=0xFF1B;_map[Key.Back]=0xFF08;_map[Key.Tab]=0xFF09;_map[Key.Delete]=0xFFFF;_map[Key.Insert]=0xFF63;_map[Key.Home]=0xFF50;_map[Key.End]=0xFF57;_map[Key.PageUp]=0xFF55;_map[Key.PageDown]=0xFF56;
        _map[Key.Up]=0xFF52;_map[Key.Down]=0xFF54;_map[Key.Left]=0xFF51;_map[Key.Right]=0xFF53;_map[Key.Space]=0x0020;_map[Key.CapsLock]=0xFFE5;_map[Key.NumLock]=0xFF7F;_map[Key.Scroll]=0xFF14;_map[Key.PrintScreen]=0xFF61;_map[Key.Pause]=0xFF13;
        _map[Key.OemMinus]=0x002D;_map[Key.OemPlus]=0x003D;_map[Key.OemOpenBrackets]=0x005B;_map[Key.OemCloseBrackets]=0x005D;_map[Key.OemPipe]=0x005C;_map[Key.OemSemicolon]=0x003B;_map[Key.OemQuotes]=0x0027;_map[Key.OemComma]=0x002C;_map[Key.OemPeriod]=0x002E;_map[Key.OemQuestion]=0x002F;_map[Key.OemTilde]=0x0060;
        _map[Key.A]=0x61;_map[Key.B]=0x62;_map[Key.C]=0x63;_map[Key.D]=0x64;_map[Key.E]=0x65;_map[Key.F]=0x66;_map[Key.G]=0x67;_map[Key.H]=0x68;_map[Key.I]=0x69;_map[Key.J]=0x6A;_map[Key.K]=0x6B;_map[Key.L]=0x6C;_map[Key.M]=0x6D;_map[Key.N]=0x6E;_map[Key.O]=0x6F;_map[Key.P]=0x70;_map[Key.Q]=0x71;_map[Key.R]=0x72;_map[Key.S]=0x73;_map[Key.T]=0x74;_map[Key.U]=0x75;_map[Key.V]=0x76;_map[Key.W]=0x77;_map[Key.X]=0x78;_map[Key.Y]=0x79;_map[Key.Z]=0x7A;
        _map[Key.D0]=0x30;_map[Key.D1]=0x31;_map[Key.D2]=0x32;_map[Key.D3]=0x33;_map[Key.D4]=0x34;_map[Key.D5]=0x35;_map[Key.D6]=0x36;_map[Key.D7]=0x37;_map[Key.D8]=0x38;_map[Key.D9]=0x39;
        _map[Key.NumPad0]=0xFFB0;_map[Key.NumPad1]=0xFFB1;_map[Key.NumPad2]=0xFFB2;_map[Key.NumPad3]=0xFFB3;_map[Key.NumPad4]=0xFFB4;_map[Key.NumPad5]=0xFFB5;_map[Key.NumPad6]=0xFFB6;_map[Key.NumPad7]=0xFFB7;_map[Key.NumPad8]=0xFFB8;_map[Key.NumPad9]=0xFFB9;_map[Key.Multiply]=0xFFAA;_map[Key.Add]=0xFFAB;_map[Key.Subtract]=0xFFAD;_map[Key.Decimal]=0xFFAE;_map[Key.Divide]=0xFFAF;
        _shiftMap=new Dictionary<Key,uint>();
        _shiftMap[Key.D1]=0x21;_shiftMap[Key.D2]=0x40;_shiftMap[Key.D3]=0x23;_shiftMap[Key.D4]=0x24;_shiftMap[Key.D5]=0x25;_shiftMap[Key.D6]=0x5E;_shiftMap[Key.D7]=0x26;_shiftMap[Key.D8]=0x2A;_shiftMap[Key.D9]=0x28;_shiftMap[Key.D0]=0x29;
        _shiftMap[Key.OemMinus]=0x5F;_shiftMap[Key.OemPlus]=0x2B;_shiftMap[Key.OemOpenBrackets]=0x7B;_shiftMap[Key.OemCloseBrackets]=0x7D;_shiftMap[Key.OemPipe]=0x7C;_shiftMap[Key.OemSemicolon]=0x3A;_shiftMap[Key.OemQuotes]=0x22;_shiftMap[Key.OemComma]=0x3C;_shiftMap[Key.OemPeriod]=0x3E;_shiftMap[Key.OemQuestion]=0x3F;_shiftMap[Key.OemTilde]=0x7E;
    }
    public static uint GetKeysym(Key key,bool shift){if(shift&&key>=Key.A&&key<=Key.Z)return(uint)(0x41+(key-Key.A));if(shift&&_shiftMap.ContainsKey(key))return _shiftMap[key];if(_map.ContainsKey(key))return _map[key];return 0;}
}
'@

try { [VncEngine] | Out-Null } catch { Add-Type -TypeDefinition $VncEngineCode -ReferencedAssemblies @("System.dll") -Language CSharp }
try { [KeysymMap] | Out-Null } catch { Add-Type -TypeDefinition $KeysymMapCode -ReferencedAssemblies @("PresentationCore","WindowsBase") -Language CSharp }

# ============================================================
# XAML - Catppuccin Macchiato theme, GridSplitter for left panel
# ============================================================
[xml]$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VNC Remote Desktop" Width="1100" Height="720" MinWidth="700" MinHeight="500"
        WindowStartupLocation="CenterScreen" Background="#181926">
  <Window.Resources>
    <Style TargetType="Button" x:Key="ToolBtn">
      <Setter Property="Background" Value="#363a4f"/>
      <Setter Property="Foreground" Value="#cad3f5"/>
      <Setter Property="BorderBrush" Value="#494d64"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,4"/>
      <Setter Property="Margin" Value="2"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#c6a0f6"/><Setter Property="Foreground" Value="#181926"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBox" x:Key="InputBox">
      <Setter Property="Background" Value="#1e2030"/>
      <Setter Property="Foreground" Value="#cad3f5"/>
      <Setter Property="BorderBrush" Value="#494d64"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="4,3"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="Label" x:Key="Lbl">
      <Setter Property="Foreground" Value="#b8c0e0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Padding" Value="4,0"/>
    </Style>
    <Style x:Key="HistBtn" TargetType="Button">
      <Setter Property="Background" Value="#1e2030"/>
      <Setter Property="Foreground" Value="#b8c0e0"/>
      <Setter Property="BorderBrush" Value="#494d64"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#c6a0f6"/>
          <Setter Property="Foreground" Value="Black"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="PanelBtnStyle" TargetType="Button">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#363a4f"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Foreground" Value="#cad3f5"/>
      <Setter Property="Padding" Value="10,8,10,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#c6a0f6"/>
          <Setter Property="Foreground" Value="#181926"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="PanelBtnStyleCurrent" TargetType="Button" BasedOn="{StaticResource PanelBtnStyle}">
      <Setter Property="Background" Value="#363a4f"/>
    </Style>
    <Style x:Key="DarkComboBox" TargetType="ComboBox">
      <Setter Property="Background" Value="#1e2030"/>
      <Setter Property="Foreground" Value="#cad3f5"/>
      <Setter Property="BorderBrush" Value="#494d64"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleButton" Focusable="false" IsChecked="{Binding Path=IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition />
                        <ColumnDefinition Width="20" />
                      </Grid.ColumnDefinitions>
                      <Border x:Name="Border" Grid.ColumnSpan="2" Background="#1e2030" BorderBrush="#494d64" BorderThickness="1" />
                      <Path Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center" Data="M 0 0 L 8 0 L 4 4 Z" Fill="#cad3f5" />
                    </Grid>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}" Margin="8,4,28,4" VerticalAlignment="Center" HorizontalAlignment="Left" TextBlock.Foreground="#cad3f5" />
              <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Grid x:Name="DropDown" SnapsToDevicePixels="True" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <Border x:Name="DropDownBorder" Background="#1e2030" BorderThickness="1" BorderBrush="#494d64" />
                  <ScrollViewer Margin="4,6,4,6" SnapsToDevicePixels="True">
                    <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained" />
                  </ScrollViewer>
                </Grid>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="#1e2030"/>
      <Setter Property="Foreground" Value="#cad3f5"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#c6a0f6"/>
                <Setter Property="Foreground" Value="Black"/>
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter Property="Background" Value="#c6a0f6"/>
                <Setter Property="Foreground" Value="Black"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="#494d64"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Vertical">
          <Setter Property="Width" Value="14"/>
          <Setter Property="MinWidth" Value="14"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="#1e2030">
                  <Border Background="#1e2030" CornerRadius="7" Margin="0"/>
                  <Track Name="PART_Track" IsDirectionReversed="True">
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb Focusable="False">
                        <Thumb.Style>
                          <Style TargetType="Thumb">
                            <Setter Property="Background" Value="#494d64"/>
                            <Setter Property="BorderBrush" Value="Transparent"/>
                            <Setter Property="BorderThickness" Value="0"/>
                            <Setter Property="Template">
                              <Setter.Value>
                                <ControlTemplate TargetType="Thumb">
                                  <Border Background="{TemplateBinding Background}" CornerRadius="7" Margin="2"/>
                                </ControlTemplate>
                              </Setter.Value>
                            </Setter>
                            <Style.Triggers>
                              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#c6a0f6"/></Trigger>
                              <Trigger Property="IsDragging" Value="True"><Setter Property="Background" Value="#c6a0f6"/></Trigger>
                            </Style.Triggers>
                          </Style>
                        </Thumb.Style>
                      </Thumb>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                    </Track.IncreaseRepeatButton>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Height" Value="14"/>
          <Setter Property="MinHeight" Value="14"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="#1e2030">
                  <Border Background="#1e2030" CornerRadius="7" Margin="0"/>
                  <Track Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb Focusable="False">
                        <Thumb.Style>
                          <Style TargetType="Thumb">
                            <Setter Property="Background" Value="#494d64"/>
                            <Setter Property="BorderBrush" Value="Transparent"/>
                            <Setter Property="BorderThickness" Value="0"/>
                            <Setter Property="Template">
                              <Setter.Value>
                                <ControlTemplate TargetType="Thumb">
                                  <Border Background="{TemplateBinding Background}" CornerRadius="7" Margin="2"/>
                                </ControlTemplate>
                              </Setter.Value>
                            </Setter>
                            <Style.Triggers>
                              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#c6a0f6"/></Trigger>
                              <Trigger Property="IsDragging" Value="True"><Setter Property="Background" Value="#c6a0f6"/></Trigger>
                            </Style.Triggers>
                          </Style>
                        </Thumb.Style>
                      </Thumb>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False"/>
                    </Track.IncreaseRepeatButton>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="DropDownMenu" TargetType="ContextMenu">
      <Setter Property="Background" Value="#1e2030"/>
      <Setter Property="BorderBrush" Value="#494d64"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="#cad3f5"/>
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="2">
              <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DropDownItem" TargetType="MenuItem">
      <Setter Property="Background" Value="#1e2030"/>
      <Setter Property="Foreground" Value="#cad3f5"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="Panel" Background="{TemplateBinding Background}">
              <ContentPresenter ContentSource="Header" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Panel" Property="Background" Value="#c6a0f6"/>
                <Setter Property="Foreground" Value="Black"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DropDownSeparator" TargetType="Separator">
      <Setter Property="Background" Value="#363a4f"/>
      <Setter Property="Margin" Value="8,3"/>
      <Setter Property="Height" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Separator">
            <Border Height="1" Background="{TemplateBinding Background}" Margin="{TemplateBinding Margin}"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ContextMenu">
      <Setter Property="Background" Value="#1e2030"/>
      <Setter Property="BorderBrush" Value="#494d64"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="#cad3f5"/>
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="2">
              <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="MenuItem">
      <Setter Property="Background" Value="#1e2030"/>
      <Setter Property="Foreground" Value="#cad3f5"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="Panel" Background="{TemplateBinding Background}">
              <ContentPresenter ContentSource="Header" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Panel" Property="Background" Value="#c6a0f6"/>
                <Setter Property="Foreground" Value="Black"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Separator">
      <Setter Property="Background" Value="#363a4f"/>
      <Setter Property="Margin" Value="8,3"/>
      <Setter Property="Height" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Separator">
            <Border Height="1" Background="{TemplateBinding Background}" Margin="{TemplateBinding Margin}"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <DockPanel x:Name="mainDock">
      <Border x:Name="toolbarBorder" DockPanel.Dock="Top" Background="#24273a" BorderBrush="#363a4f" BorderThickness="0,0,0,1" Padding="4">
        <WrapPanel VerticalAlignment="Center">
          <Button x:Name="btnTogglePanel" Content="&#x2630;" Style="{StaticResource ToolBtn}" Margin="2,2,8,2" FontSize="16" FontWeight="Bold"/>
          <Border Width="1" Background="#363a4f" Margin="4,2"/>
          <Label Content="Host:" Style="{StaticResource Lbl}"/>
          <TextBox x:Name="txtHost" Width="120" Style="{StaticResource InputBox}" Text="$DefaultHost"/>
          <Button x:Name="btnHostHistory" Content="&#x25BC;" Style="{StaticResource HistBtn}" Padding="6,4" Width="26" ToolTip="Recent hosts"/>
          <Button x:Name="btnPasteHost" Content="&#x1F4CB;" Style="{StaticResource ToolBtn}" Padding="6,4" FontSize="12" ToolTip="Paste host from clipboard"/>
          <Label Content="Port:" Style="{StaticResource Lbl}"/>
          <TextBox x:Name="txtPort" Width="50" Style="{StaticResource InputBox}" Text="$DefaultPort"/>
          <Label Content="Password:" Style="{StaticResource Lbl}"/>
          <Grid Width="160">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <PasswordBox x:Name="txtPassword" Grid.Column="0" Background="#1e2030" Foreground="#cad3f5" BorderBrush="#494d64" BorderThickness="1,1,0,1" Padding="4,3" FontSize="13" Height="32" VerticalContentAlignment="Center"/>
            <TextBox x:Name="txtPasswordVisible" Grid.Column="0" Visibility="Collapsed" Background="#1e2030" Foreground="#cad3f5" BorderBrush="#494d64" BorderThickness="1,1,0,1" Padding="4,3" FontSize="13" Height="32" VerticalContentAlignment="Center"/>
            <Button x:Name="btnTogglePw" Grid.Column="1" Width="26" Background="#1e2030" Foreground="#b8c0e0" BorderBrush="#494d64" BorderThickness="1" FontSize="16" Cursor="Hand" Height="32" VerticalAlignment="Stretch" ToolTip="Show/Hide password" Padding="0">&#x1F441;</Button>
            <Button x:Name="btnPwHistory" Grid.Column="2" Content="&#x25BC;" Style="{StaticResource HistBtn}" Width="22" ToolTip="Recent passwords"/>
          </Grid>
          <Button x:Name="btnConnect" Content="Connect" Style="{StaticResource ToolBtn}" Margin="8,2,2,2"/>
          <Button x:Name="btnDisconnect" Content="Disconnect" Style="{StaticResource ToolBtn}" Visibility="Collapsed"/>
          <Border x:Name="sep1" Width="1" Background="#363a4f" Margin="8,2" Visibility="Collapsed"/>
          <Button x:Name="btnFitWindow" Content="Fit Window" Style="{StaticResource ToolBtn}" Visibility="Collapsed"/>
          <Button x:Name="btnFullScreen" Content="Full Screen" Style="{StaticResource ToolBtn}" Visibility="Collapsed"/>
          <Button x:Name="btnClipboard" Content="Clipboard" Style="{StaticResource ToolBtn}" Visibility="Collapsed"/>
          <Border x:Name="sep2" Width="1" Background="#363a4f" Margin="8,2" Visibility="Collapsed"/>
          <Button x:Name="btnSettings" Content="Settings" Style="{StaticResource ToolBtn}"/>
        </WrapPanel>
      </Border>

      <Border x:Name="statsBorder" DockPanel.Dock="Bottom" Background="#181926" BorderBrush="#363a4f" BorderThickness="0,1,0,0">
        <DockPanel>
          <Border DockPanel.Dock="Left" Background="#c6a0f6" Padding="10,4">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="statusDot" Width="8" Height="8" Fill="#ed8796" Margin="0,0,6,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="txtStatus" Text="Disconnected" Foreground="#181926" FontSize="12" VerticalAlignment="Center" FontWeight="SemiBold"/>
            </StackPanel>
          </Border>
          <Border DockPanel.Dock="Right" Padding="10,4"><TextBlock x:Name="txtResolution" Text="" Foreground="#939ab7" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/></Border>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,3">
            <Border Background="#1e2030" CornerRadius="3" Padding="6,2" Margin="3,0"><StackPanel Orientation="Horizontal"><TextBlock Text="FPS: " Foreground="#939ab7" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/><TextBlock x:Name="txtFps" Text="--" Foreground="#a6da95" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center" MinWidth="28"/></StackPanel></Border>
            <Border Background="#1e2030" CornerRadius="3" Padding="6,2" Margin="3,0"><StackPanel Orientation="Horizontal"><TextBlock Text="Frames: " Foreground="#939ab7" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/><TextBlock x:Name="txtFrames" Text="--" Foreground="#eed49f" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center" MinWidth="38"/></StackPanel></Border>
            <Border Background="#1e2030" CornerRadius="3" Padding="6,2" Margin="3,0"><StackPanel Orientation="Horizontal"><TextBlock Text="Data: " Foreground="#939ab7" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/><TextBlock x:Name="txtData" Text="--" Foreground="#8aadf4" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center" MinWidth="55"/></StackPanel></Border>
            <Border Background="#1e2030" CornerRadius="3" Padding="6,2" Margin="3,0"><StackPanel Orientation="Horizontal"><TextBlock Text="Latency: " Foreground="#939ab7" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/><TextBlock x:Name="txtLatency" Text="--" Foreground="#f5a97f" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center" MinWidth="38"/></StackPanel></Border>
            <Border Background="#1e2030" CornerRadius="3" Padding="6,2" Margin="3,0"><StackPanel Orientation="Horizontal"><TextBlock Text="Uptime: " Foreground="#939ab7" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/><TextBlock x:Name="txtUptime" Text="--" Foreground="#c6a0f6" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center" MinWidth="50"/></StackPanel></Border>
          </StackPanel>
        </DockPanel>
      </Border>

      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition x:Name="sidePanelCol" Width="250" MinWidth="160" MaxWidth="600"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border x:Name="sidePanel" Grid.Column="0" Background="#1e2030" BorderBrush="#363a4f" BorderThickness="0,0,1,0" ClipToBounds="True">
          <DockPanel>
            <Border DockPanel.Dock="Top" Background="#24273a" Padding="10,8" BorderBrush="#363a4f" BorderThickness="0,0,0,1">
              <DockPanel>
                <Button x:Name="btnClearHistory" Content="Clear" DockPanel.Dock="Right" Style="{StaticResource ToolBtn}" FontSize="11" Padding="6,2" Width="50" Margin="0,0,2,0" VerticalAlignment="Center" ToolTip="Clear all history"/>
                <TextBlock Text="Sessions" Foreground="#cad3f5" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
              </DockPanel>
            </Border>
            <DockPanel DockPanel.Dock="Top">
              <Border DockPanel.Dock="Top" Background="#1e2030" Padding="10,5" BorderBrush="#363a4f" BorderThickness="0,0,0,1"><TextBlock Text="PINNED" Foreground="#8aadf4" FontSize="11" FontWeight="Bold"/></Border>
              <ScrollViewer DockPanel.Dock="Top" VerticalScrollBarVisibility="Auto" MaxHeight="180"><StackPanel x:Name="pinnedSessionsList"/></ScrollViewer>
            </DockPanel>
            <DockPanel DockPanel.Dock="Top">
              <Border DockPanel.Dock="Top" Background="#1e2030" Padding="10,5" BorderBrush="#363a4f" BorderThickness="0,0,0,1"><TextBlock Text="ACTIVE" Foreground="#a6da95" FontSize="11" FontWeight="Bold"/></Border>
              <ScrollViewer DockPanel.Dock="Top" VerticalScrollBarVisibility="Auto" MaxHeight="200"><StackPanel x:Name="activeSessionsList"/></ScrollViewer>
            </DockPanel>
            <DockPanel>
              <Border DockPanel.Dock="Top" Background="#1e2030" Padding="10,5" BorderBrush="#363a4f" BorderThickness="0,1,0,0"><TextBlock Text="RECENT" Foreground="#939ab7" FontSize="11" FontWeight="Bold"/></Border>
              <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="recentSessionsList"/></ScrollViewer>
            </DockPanel>
          </DockPanel>
        </Border>

        <GridSplitter x:Name="panelSplitter" Grid.Column="1" Width="5" HorizontalAlignment="Center" VerticalAlignment="Stretch" Background="#494d64" ResizeBehavior="PreviousAndNext" ResizeDirection="Columns" ShowsPreview="True" Cursor="SizeWE"/>

        <Border Grid.Column="2" Background="#181926">
          <Grid>
            <ScrollViewer x:Name="scrollViewer" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto" Focusable="False">
              <Canvas x:Name="vncCanvas" Background="#000000" ClipToBounds="True" Focusable="True">
                <Image x:Name="vncImage" Stretch="None" RenderOptions.BitmapScalingMode="NearestNeighbor"/>
              </Canvas>
            </ScrollViewer>
            <Border x:Name="noConnectionOverlay" Background="#181926">
              <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                <TextBlock Text="No Active Connection" FontSize="28" Foreground="#cad3f5" HorizontalAlignment="Center" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <Border Background="#c6a0f6" Width="60" Height="2" HorizontalAlignment="Center" Margin="0,0,0,14"/>
                <TextBlock Text="Enter connection details above and click Connect, or press Enter" FontSize="14" Foreground="#939ab7" HorizontalAlignment="Center"/>
              </StackPanel>
            </Border>
          </Grid>
        </Border>
      </Grid>
    </DockPanel>

    <Border x:Name="fullscreenBar" VerticalAlignment="Top" HorizontalAlignment="Center" Height="0" Background="#DD1e2030" CornerRadius="0,0,8,8" BorderBrush="#c6a0f6" BorderThickness="1,0,1,1" ClipToBounds="True" Panel.ZIndex="100">
      <StackPanel Orientation="Horizontal" Margin="12,6" VerticalAlignment="Center">
        <TextBlock x:Name="fsSessionName" Text="Session" Foreground="#cad3f5" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,16,0"/>
        <Button x:Name="btnFsWindowed" Content="Windowed" Background="#363a4f" Foreground="#cad3f5" BorderBrush="#494d64" Padding="10,4" Margin="2" FontSize="12" Cursor="Hand" BorderThickness="1"/>
        <Button x:Name="btnFsClipboard" Content="Clipboard" Background="#363a4f" Foreground="#cad3f5" BorderBrush="#494d64" Padding="10,4" Margin="2" FontSize="12" Cursor="Hand" BorderThickness="1"/>
        <Button x:Name="btnFsDisconnect" Content="Disconnect" Background="#ed8796" Foreground="#181926" BorderBrush="#ee99a0" Padding="10,4" Margin="2" FontSize="12" Cursor="Hand" BorderThickness="1"/>
      </StackPanel>
    </Border>

    <Border x:Name="fsHoverZone" VerticalAlignment="Top" HorizontalAlignment="Center" Height="6" Width="300" Background="Transparent" Panel.ZIndex="99" Visibility="Collapsed"/>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $Xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

function Get-E($n) { $window.FindName($n) }

$txtHost             = Get-E txtHost
$txtPort             = Get-E txtPort
$txtPassword         = Get-E txtPassword
$txtPasswordVisible  = Get-E txtPasswordVisible
$btnTogglePw         = Get-E btnTogglePw
$btnConnect          = Get-E btnConnect
$btnDisconnect       = Get-E btnDisconnect
$btnFitWindow        = Get-E btnFitWindow
$btnFullScreen       = Get-E btnFullScreen
$btnClipboard        = Get-E btnClipboard
$btnSettings         = Get-E btnSettings
$btnTogglePanel      = Get-E btnTogglePanel
$btnClearHistory     = Get-E btnClearHistory
$btnPasteHost        = Get-E btnPasteHost
$btnHostHistory      = Get-E btnHostHistory
$btnPwHistory        = Get-E btnPwHistory
$txtStatus           = Get-E txtStatus
$txtResolution       = Get-E txtResolution
$txtFps              = Get-E txtFps
$txtFrames           = Get-E txtFrames
$txtData             = Get-E txtData
$txtLatency          = Get-E txtLatency
$txtUptime           = Get-E txtUptime
$statusDot           = Get-E statusDot
$scrollViewer        = Get-E scrollViewer
$vncCanvas           = Get-E vncCanvas
$vncImage            = Get-E vncImage
$sidePanel           = Get-E sidePanel
$sidePanelCol        = Get-E sidePanelCol
$panelSplitter       = Get-E panelSplitter
$pinnedSessionsList  = Get-E pinnedSessionsList
$activeSessionsList  = Get-E activeSessionsList
$recentSessionsList  = Get-E recentSessionsList
$noConnectionOverlay = Get-E noConnectionOverlay
$toolbarBorder       = Get-E toolbarBorder
$statsBorder         = Get-E statsBorder
$fullscreenBar       = Get-E fullscreenBar
$fsHoverZone         = Get-E fsHoverZone
$fsSessionName       = Get-E fsSessionName
$btnFsWindowed       = Get-E btnFsWindowed
$btnFsDisconnect     = Get-E btnFsDisconnect
$btnFsClipboard      = Get-E btnFsClipboard
$sep1                = Get-E sep1
$sep2                = Get-E sep2

$txtPassword.Password       = $DefaultPassword
$txtPasswordVisible.Text    = $DefaultPassword

# ============================================================
# STATE
# ============================================================
$script:vncEngine           = $null
$script:updateTimer         = $null
$script:statsTimer          = $null
$script:clipTimer           = $null
$script:lastFrameVer        = -1
$script:buttonMask          = 0
$script:fitMode             = $false
$script:writeableBmp        = $null
$script:panelOpen           = $true
$script:activeSessions      = @{}
$script:activeSessionKey    = $null
$script:recentSessions      = [System.Collections.ArrayList]::new()
$script:isFullScreen        = $false
$script:savedWindowState    = $null
$script:savedWindowStyle    = $null
$script:savedWindowRect     = $null
$script:savedResizeMode     = [System.Windows.ResizeMode]::CanResize
$script:fsBarVisible        = $false
$script:fsBarTimer          = $null
$script:lastLocalClipboard  = ""
$script:syncingPw           = $false
$script:pwVisible           = $false
$script:vncSettings         = @{ SharedConnection=$true; ViewOnly=$false; RefreshRate=33; ClipboardSync=$true; DropDownCount=5 }
$script:pendingConnect      = $null
$script:pendingConnectKey   = $null
$script:pendingConnectHost  = $null
$script:pendingConnectPort  = 0
$script:pendingConnectPw    = $null
$script:connectAsyncHandle  = $null
$script:connectBgPS         = $null
$script:connectRunspace     = $null
$script:connectPollTimer    = $null
$script:connectCancelled    = $false
$script:panelWidth          = 250
$script:windowWidth         = 1100
$script:windowHeight        = 720
$script:showPassword        = $false
$script:recentHosts         = [System.Collections.ArrayList]::new()
$script:recentPasswords     = [System.Collections.ArrayList]::new()

# ============================================================
# HELPERS
# ============================================================
function B([byte]$r, [byte]$g, [byte]$b) {
    New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb($r, $g, $b))
}

function Get-Password {
    if ($script:pwVisible) { $txtPasswordVisible.Text } else { $txtPassword.Password }
}

function Make-DlgBtn([string]$text, [bool]$primary) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content           = $text
    $b.Height            = 32
    $b.Padding           = [System.Windows.Thickness]::new(12, 0, 12, 0)
    $b.FontSize          = 13
    $b.Cursor            = [System.Windows.Input.Cursors]::Hand
    if ($primary) {
        $b.Background    = B 0xC6 0xA0 0xF6
        $b.Foreground    = [System.Windows.Media.Brushes]::Black
        $b.BorderThickness = [System.Windows.Thickness]::new(0)
    } else {
        $b.Background    = B 0x49 0x4D 0x64
        $b.Foreground    = [System.Windows.Media.Brushes]::Black
        $b.BorderBrush   = B 0x49 0x4D 0x64
    }
    return $b
}

# Shared dark dialog shell: returns ($dlg, $mainDock, $contentDock)
# $contentDock is a DockPanel between the title bar and button panel for body content
function New-DarkDialog([string]$title, [int]$width = 400) {
    $dlg = New-Object System.Windows.Window
    $dlg.Title                     = ""
    $dlg.Width                     = $width
    $dlg.SizeToContent             = [System.Windows.SizeToContent]::Height
    $dlg.WindowStyle               = [System.Windows.WindowStyle]::None
    $dlg.ResizeMode                = [System.Windows.ResizeMode]::NoResize
    $dlg.WindowStartupLocation     = [System.Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner                     = $window
    $dlg.Background                = B 0x1E 0x20 0x30
    $dlg.BorderBrush               = B 0x49 0x4D 0x64
    $dlg.BorderThickness           = [System.Windows.Thickness]::new(1)

    $mainDock = New-Object System.Windows.Controls.DockPanel

    $titleBar = New-Object System.Windows.Controls.Border
    $titleBar.Background  = B 0x24 0x27 0x3A
    $titleBar.Padding     = [System.Windows.Thickness]::new(10, 8, 10, 8)
    [System.Windows.Controls.DockPanel]::SetDock($titleBar, [System.Windows.Controls.Dock]::Top)
    $titleText            = New-Object System.Windows.Controls.TextBlock
    $titleText.Text       = $title
    $titleText.Foreground = B 0xCA 0xD3 0xF5
    $titleText.FontSize   = 14
    $titleText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $titleBar.Child       = $titleText
    $titleBar.Add_MouseLeftButtonDown({ $dlg.DragMove() })
    $mainDock.Children.Add($titleBar) | Out-Null

    $dlg.Content = $mainDock
    return $dlg, $mainDock
}

function Show-ConfirmDialog([string]$title, [string]$message) {
    $dlg, $mainDock = New-DarkDialog $title

    $bp = New-Object System.Windows.Controls.StackPanel
    $bp.Orientation        = [System.Windows.Controls.Orientation]::Horizontal
    $bp.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $bp.Margin             = [System.Windows.Thickness]::new(15, 0, 15, 15)
    [System.Windows.Controls.DockPanel]::SetDock($bp, [System.Windows.Controls.Dock]::Bottom)

    $yes = Make-DlgBtn "Yes" $true;  $yes.Width = 70; $yes.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $no  = Make-DlgBtn "No"  $false; $no.Width  = 70
    $yes.Add_Click({ $dlg.Tag = $true;  $dlg.Close() })
    $no.Add_Click({  $dlg.Tag = $false; $dlg.Close() })
    $bp.Children.Add($yes) | Out-Null
    $bp.Children.Add($no)  | Out-Null
    $mainDock.Children.Add($bp) | Out-Null

    $tbMsg = New-Object System.Windows.Controls.TextBlock
    $tbMsg.Text        = $message
    $tbMsg.Foreground  = B 0xCA 0xD3 0xF5
    $tbMsg.FontSize    = 13
    $tbMsg.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tbMsg.Margin      = [System.Windows.Thickness]::new(15, 15, 15, 12)
    $mainDock.Children.Add($tbMsg) | Out-Null

    $dlg.ShowDialog() | Out-Null
    return [bool]$dlg.Tag
}

function Show-DarkMessageDialog([string]$title, [string]$message) {
    $dlg, $mainDock = New-DarkDialog $title

    $bp = New-Object System.Windows.Controls.StackPanel
    $bp.Orientation        = [System.Windows.Controls.Orientation]::Horizontal
    $bp.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $bp.Margin             = [System.Windows.Thickness]::new(15, 0, 15, 15)
    [System.Windows.Controls.DockPanel]::SetDock($bp, [System.Windows.Controls.Dock]::Bottom)

    $ok = Make-DlgBtn "OK" $true; $ok.Width = 70
    $ok.Add_Click({ $dlg.Close() })
    $bp.Children.Add($ok) | Out-Null
    $mainDock.Children.Add($bp) | Out-Null

    $tbMsg = New-Object System.Windows.Controls.TextBlock
    $tbMsg.Text        = $message
    $tbMsg.Foreground  = B 0xCA 0xD3 0xF5
    $tbMsg.FontSize    = 13
    $tbMsg.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tbMsg.Margin      = [System.Windows.Thickness]::new(15, 15, 15, 12)
    $mainDock.Children.Add($tbMsg) | Out-Null

    $dlg.ShowDialog() | Out-Null
}

# ============================================================
# CONFIG INI
# ============================================================
function Load-ConfigIni {
    if (-not (Test-Path $ConfigIniFile)) { return }
    try {
        $lines = Get-Content $ConfigIniFile
        foreach ($ln in $lines) {
            if ($ln -match '^\s*PanelWidth\s*=\s*(\d+)')        { $w = [int]$Matches[1]; if ($w -ge 160 -and $w -le 600) { $script:panelWidth  = $w } }
            if ($ln -match '^\s*WindowWidth\s*=\s*(\d+)')       { $w = [int]$Matches[1]; if ($w -ge 700)                 { $script:windowWidth = $w } }
            if ($ln -match '^\s*WindowHeight\s*=\s*(\d+)')      { $h = [int]$Matches[1]; if ($h -ge 500)                 { $script:windowHeight= $h } }
            if ($ln -match '^\s*ShowPassword\s*=\s*(\d+)')      { $script:showPassword = [int]$Matches[1] -eq 1 }
        }
        $hc = 0
        foreach ($ln in $lines) { if ($ln -match '^\s*RecentHostCount\s*=\s*(\d+)') { $hc = [int]$Matches[1]; break } }
        for ($i = 0; $i -lt $hc; $i++) {
            $pattern = "^\s*RecentHost$i\s*=\s*(.*)$"
            foreach ($ln in $lines) { if ($ln -match $pattern) { $script:recentHosts.Add($Matches[1]) | Out-Null; break } }
        }
        $pc = 0
        foreach ($ln in $lines) { if ($ln -match '^\s*RecentPasswordCount\s*=\s*(\d+)') { $pc = [int]$Matches[1]; break } }
        for ($i = 0; $i -lt $pc; $i++) {
            $pattern = "^\s*RecentPassword$i\s*=\s*(.*)$"
            foreach ($ln in $lines) { if ($ln -match $pattern) { $script:recentPasswords.Add($Matches[1]) | Out-Null; break } }
        }
    } catch {}
}

function Save-ConfigIni {
    try {
        $sb = New-Object System.Text.StringBuilder
        $sb.AppendLine("[VncClient]")                                                          | Out-Null
        $sb.AppendLine("PanelWidth=$($script:panelWidth)")                                     | Out-Null
        $sb.AppendLine("WindowWidth=$($script:windowWidth)")                                   | Out-Null
        $sb.AppendLine("WindowHeight=$($script:windowHeight)")                                 | Out-Null
        $sb.AppendLine("ShowPassword=$(if($script:showPassword){'1'}else{'0'})")               | Out-Null
        $sb.AppendLine("RecentHostCount=$($script:recentHosts.Count)")                         | Out-Null
        for ($i = 0; $i -lt $script:recentHosts.Count; $i++) {
            $sb.AppendLine("RecentHost$i=$($script:recentHosts[$i])")                          | Out-Null
        }
        $sb.AppendLine("RecentPasswordCount=$($script:recentPasswords.Count)")                 | Out-Null
        for ($i = 0; $i -lt $script:recentPasswords.Count; $i++) {
            $sb.AppendLine("RecentPassword$i=$($script:recentPasswords[$i])")                  | Out-Null
        }
        [System.IO.File]::WriteAllText($ConfigIniFile, $sb.ToString())
    } catch {}
}

# ============================================================
# RECENT HOSTS / PASSWORDS
# ============================================================
function Add-ToRecentHosts([string]$h) {
    if (-not $h) { return }
    $idx = -1
    for ($i = 0; $i -lt $script:recentHosts.Count; $i++) { if ($script:recentHosts[$i] -eq $h) { $idx = $i; break } }
    if ($idx -ge 0) { $script:recentHosts.RemoveAt($idx) }
    $script:recentHosts.Insert(0, $h)
    while ($script:recentHosts.Count -gt $script:vncSettings.DropDownCount) { $script:recentHosts.RemoveAt($script:recentHosts.Count - 1) }
}

function Add-ToRecentPasswords([string]$pw) {
    if (-not $pw) { return }
    $idx = -1
    for ($i = 0; $i -lt $script:recentPasswords.Count; $i++) { if ($script:recentPasswords[$i] -eq $pw) { $idx = $i; break } }
    if ($idx -ge 0) { $script:recentPasswords.RemoveAt($idx) }
    $script:recentPasswords.Insert(0, $pw)
    while ($script:recentPasswords.Count -gt $script:vncSettings.DropDownCount) { $script:recentPasswords.RemoveAt($script:recentPasswords.Count - 1) }
}

function New-HistoryContextMenu([string]$emptyText, [System.Collections.ArrayList]$items, [scriptblock]$onSelect, [scriptblock]$onClear, [string]$clearTitle, [string]$clearConfirmMsg) {
    $ctx = New-Object System.Windows.Controls.ContextMenu
    $ctx.Style = $window.FindResource("DropDownMenu")
    if ($items.Count -eq 0) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header    = $emptyText
        $mi.IsEnabled = $false
        $mi.Style     = $window.FindResource("DropDownItem")
        $ctx.Items.Add($mi) | Out-Null
    } else {
        foreach ($entry in $items) {
            $mi = New-Object System.Windows.Controls.MenuItem
            $mi.Header = $entry
            $mi.Style  = $window.FindResource("DropDownItem")
            $captured  = $entry
            $mi.Add_Click($onSelect.GetNewClosure())
            # Rebind captured inside closure
            $mi.Tag = $captured
            $mi.Add_Click({ & $onSelect $this.Tag }.GetNewClosure())
            $ctx.Items.Add($mi) | Out-Null
        }
        $sep = New-Object System.Windows.Controls.Separator
        $sep.Style = $window.FindResource("DropDownSeparator")
        $ctx.Items.Add($sep) | Out-Null
        $clr = New-Object System.Windows.Controls.MenuItem
        $clr.Header = "Clear Recent"
        $clr.Style  = $window.FindResource("DropDownItem")
        $clr.Add_Click({
            if (Show-ConfirmDialog $clearTitle $clearConfirmMsg) { & $onClear }
        }.GetNewClosure())
        $ctx.Items.Add($clr) | Out-Null
    }
    return $ctx
}

function Show-HostHistoryDropdown {
    $ctx = New-Object System.Windows.Controls.ContextMenu
    $ctx.Style = $window.FindResource("DropDownMenu")
    if ($script:recentHosts.Count -eq 0) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header    = "No recent hosts"
        $mi.IsEnabled = $false
        $mi.Style     = $window.FindResource("DropDownItem")
        $ctx.Items.Add($mi) | Out-Null
    } else {
        foreach ($hh in $script:recentHosts) {
            $mi = New-Object System.Windows.Controls.MenuItem
            $mi.Header = $hh
            $mi.Style  = $window.FindResource("DropDownItem")
            $captured  = $hh
            $mi.Add_Click({ $txtHost.Text = $captured }.GetNewClosure())
            $ctx.Items.Add($mi) | Out-Null
        }
        $sep = New-Object System.Windows.Controls.Separator
        $sep.Style = $window.FindResource("DropDownSeparator")
        $ctx.Items.Add($sep) | Out-Null
        $clr = New-Object System.Windows.Controls.MenuItem
        $clr.Header = "Clear Recent"
        $clr.Style  = $window.FindResource("DropDownItem")
        $clr.Add_Click({
            if (Show-ConfirmDialog "Clear Recent" "Are you sure you want to clear all recent hosts?") {
                $script:recentHosts.Clear(); Save-ConfigIni
            }
        })
        $ctx.Items.Add($clr) | Out-Null
    }
    $btnHostHistory.ContextMenu    = $ctx
    $ctx.PlacementTarget           = $txtHost
    $ctx.Placement                 = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $ctx.IsOpen                    = $true
}

function Show-PwHistoryDropdown {
    $ctx = New-Object System.Windows.Controls.ContextMenu
    $ctx.Style = $window.FindResource("DropDownMenu")
    if ($script:recentPasswords.Count -eq 0) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header    = "No recent passwords"
        $mi.IsEnabled = $false
        $mi.Style     = $window.FindResource("DropDownItem")
        $ctx.Items.Add($mi) | Out-Null
    } else {
        foreach ($pp in $script:recentPasswords) {
            $mi = New-Object System.Windows.Controls.MenuItem
            $mi.Header = $pp
            $mi.Style  = $window.FindResource("DropDownItem")
            $captured  = $pp
            $mi.Add_Click({
                $script:syncingPw = $true
                $txtPassword.Password    = $captured
                $txtPasswordVisible.Text = $captured
                $script:syncingPw = $false
            }.GetNewClosure())
            $ctx.Items.Add($mi) | Out-Null
        }
        $sep = New-Object System.Windows.Controls.Separator
        $sep.Style = $window.FindResource("DropDownSeparator")
        $ctx.Items.Add($sep) | Out-Null
        $clr = New-Object System.Windows.Controls.MenuItem
        $clr.Header = "Clear Recent"
        $clr.Style  = $window.FindResource("DropDownItem")
        $clr.Add_Click({
            if (Show-ConfirmDialog "Clear Recent" "Are you sure you want to clear all recent passwords?") {
                $script:recentPasswords.Clear(); Save-ConfigIni
            }
        })
        $ctx.Items.Add($clr) | Out-Null
    }
    $btnPwHistory.ContextMenu = $ctx
    $ctx.PlacementTarget      = if ($script:pwVisible) { $txtPasswordVisible } else { $txtPassword }
    $ctx.Placement            = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $ctx.IsOpen               = $true
}

# ============================================================
# SETTINGS (JSON)
# ============================================================
function Load-VncSettings {
    if (-not (Test-Path $SettingsFile)) { return }
    try {
        $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        if ($null -ne $j.SharedConnection) { $script:vncSettings.SharedConnection = [bool]$j.SharedConnection }
        if ($null -ne $j.ViewOnly)         { $script:vncSettings.ViewOnly         = [bool]$j.ViewOnly }
        if ($null -ne $j.RefreshRate)      { $script:vncSettings.RefreshRate      = [int]$j.RefreshRate }
        if ($null -ne $j.ClipboardSync)    { $script:vncSettings.ClipboardSync    = [bool]$j.ClipboardSync }
        if ($null -ne $j.DropDownCount)    { $script:vncSettings.DropDownCount    = [int]$j.DropDownCount }
    } catch {}
}

function Save-VncSettings {
    try { $script:vncSettings | ConvertTo-Json | Set-Content $SettingsFile -Force } catch {}
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
                Host     = $item.Host
                Port     = [int]$item.Port
                Password = $item.Password
                LastUsed = $item.LastUsed
                Pinned   = [bool]$item.Pinned
            }) | Out-Null
        }
    } catch {}
}

function Save-SessionHistory {
    try { $script:recentSessions | ConvertTo-Json -Depth 3 | Set-Content $SessionHistoryFile -Force } catch {}
}

function Add-ToHistory([string]$H, [int]$P, [string]$PW) {
    $key = "${H}:${P}"; $idx = -1
    for ($i = 0; $i -lt $script:recentSessions.Count; $i++) {
        if ("$($script:recentSessions[$i].Host):$($script:recentSessions[$i].Port)" -eq $key) { $idx = $i; break }
    }
    if ($idx -ge 0) {
        $ex = $script:recentSessions[$idx]; $script:recentSessions.RemoveAt($idx)
        $ex.LastUsed = (Get-Date).ToString("yyyy-MM-dd HH:mm")
        if ($PW) { $ex.Password = $PW }
        $script:recentSessions.Insert(0, $ex)
    } else {
        $script:recentSessions.Insert(0, @{ Host=$H; Port=$P; Password=$PW; LastUsed=(Get-Date).ToString("yyyy-MM-dd HH:mm"); Pinned=$false })
    }
    while ($script:recentSessions.Count -gt 30) { $script:recentSessions.RemoveAt($script:recentSessions.Count - 1) }
    Save-SessionHistory
}

function Get-SessionDisplayName($entry) { return "$($entry.Host):$($entry.Port)" }

function Find-HistoryEntry([string]$Key) {
    foreach ($s in $script:recentSessions) { if ("$($s.Host):$($s.Port)" -eq $Key) { return $s } }
    return $null
}

function Remove-HistoryEntry([string]$Key) {
    $idx = -1
    for ($i = 0; $i -lt $script:recentSessions.Count; $i++) {
        if ("$($script:recentSessions[$i].Host):$($script:recentSessions[$i].Port)" -eq $Key) { $idx = $i; break }
    }
    if ($idx -ge 0) { $script:recentSessions.RemoveAt($idx); Save-SessionHistory; Update-SessionPanel }
}

function Toggle-Pin([string]$Key) {
    $e = Find-HistoryEntry $Key
    if ($null -ne $e) { $e.Pinned = -not $e.Pinned; Save-SessionHistory; Update-SessionPanel }
}

# ============================================================
# CLIPBOARD DIALOG
# ============================================================
function Show-ClipboardDialog {
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }

    $dlg = New-Object System.Windows.Window
    $dlg.Title                 = "Clipboard Transfer"
    $dlg.Width                 = 500
    $dlg.Height                = 400
    $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner                 = $window
    $dlg.Background            = B 0x1E 0x20 0x30
    $dlg.ResizeMode            = [System.Windows.ResizeMode]::CanResize
    $dlg.MinWidth              = 400
    $dlg.MinHeight             = 300

    $mainSp = New-Object System.Windows.Controls.DockPanel
    $mainSp.Margin = [System.Windows.Thickness]::new(15)

    $titleTb = New-Object System.Windows.Controls.TextBlock
    $titleTb.Text       = "Clipboard Transfer"
    $titleTb.Foreground = [System.Windows.Media.Brushes]::White
    $titleTb.FontSize   = 18
    $titleTb.FontWeight = [System.Windows.FontWeights]::SemiBold
    $titleTb.Margin     = [System.Windows.Thickness]::new(0, 0, 0, 4)
    [System.Windows.Controls.DockPanel]::SetDock($titleTb, "Top")
    $mainSp.Children.Add($titleTb) | Out-Null

    $helpTb = New-Object System.Windows.Controls.TextBlock
    $helpTb.Text        = "Use 'Type to Remote' to emulate keystrokes and paste text into the remote session. 'Paste from PC Clipboard' retrieves your local clipboard into this box."
    $helpTb.Foreground  = B 0x93 0x9A 0xB7
    $helpTb.FontSize    = 12
    $helpTb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $helpTb.Margin      = [System.Windows.Thickness]::new(0, 0, 0, 10)
    [System.Windows.Controls.DockPanel]::SetDock($helpTb, "Top")
    $mainSp.Children.Add($helpTb) | Out-Null

    $btnPanel = New-Object System.Windows.Controls.StackPanel
    $btnPanel.Orientation       = [System.Windows.Controls.Orientation]::Horizontal
    $btnPanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $btnPanel.Margin            = [System.Windows.Thickness]::new(0, 10, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($btnPanel, "Bottom")

    $btnPaste = Make-DlgBtn "Paste from PC Clipboard" $false; $btnPaste.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
    $btnSend  = Make-DlgBtn "Type to Remote" $true;           $btnSend.Margin  = [System.Windows.Thickness]::new(0, 0, 6, 0)
    $btnClose = Make-DlgBtn "Close" $false
    $btnPanel.Children.Add($btnPaste) | Out-Null
    $btnPanel.Children.Add($btnSend)  | Out-Null
    $btnPanel.Children.Add($btnClose) | Out-Null
    $mainSp.Children.Add($btnPanel) | Out-Null

    $statusLbl = New-Object System.Windows.Controls.TextBlock
    $statusLbl.Text     = ""
    $statusLbl.FontSize = 12
    $statusLbl.Foreground = B 0xCA 0xD3 0xF5
    $statusLbl.Margin   = [System.Windows.Thickness]::new(0, 6, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($statusLbl, "Bottom")
    $mainSp.Children.Add($statusLbl) | Out-Null

    $clipTb = New-Object System.Windows.Controls.TextBox
    $clipTb.AcceptsReturn           = $true
    $clipTb.AcceptsTab              = $true
    $clipTb.TextWrapping            = [System.Windows.TextWrapping]::Wrap
    $clipTb.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $clipTb.FontSize                = 14
    $clipTb.FontFamily              = New-Object System.Windows.Media.FontFamily("Consolas")
    $clipTb.Background              = B 0x24 0x27 0x3A
    $clipTb.Foreground              = [System.Windows.Media.Brushes]::White
    $clipTb.BorderBrush             = B 0x49 0x4D 0x64
    $clipTb.Padding                 = [System.Windows.Thickness]::new(8)
    try { if ([System.Windows.Clipboard]::ContainsText()) { $clipTb.Text = [System.Windows.Clipboard]::GetText() } } catch {}
    $mainSp.Children.Add($clipTb) | Out-Null

    $btnPaste.Add_Click({
        try {
            if ([System.Windows.Clipboard]::ContainsText()) { $clipTb.Text = [System.Windows.Clipboard]::GetText(); $statusLbl.Text = "Pasted from local clipboard." }
            else { $statusLbl.Text = "Local clipboard is empty." }
        } catch { $statusLbl.Text = "Failed to read clipboard." }
    })
    $btnSend.Add_Click({
        $text = $clipTb.Text
        if ($text.Length -eq 0) { $statusLbl.Text = "Nothing to send."; return }
        if ($null -ne $script:vncEngine -and $script:vncEngine.IsConnected) {
            $script:vncEngine.SendTextViaKeysAsync($text)
            $statusLbl.Text = "Typing $($text.Length) characters to remote..."
            $statusLbl.Foreground = B 0xCA 0xD3 0xF5
        } else {
            $statusLbl.Text = "Not connected."
            $statusLbl.Foreground = [System.Windows.Media.Brushes]::OrangeRed
        }
    })
    $btnClose.Add_Click({ $dlg.Close() })

    $dlg.Content = $mainSp
    $dlg.ShowDialog() | Out-Null
    $vncCanvas.Focus()
}

# ============================================================
# SETTINGS DIALOG
# ============================================================
function Show-SettingsDialog {
    $dlg, $mainDock = New-DarkDialog "VNC Settings" 420

    $bsp = New-Object System.Windows.Controls.StackPanel
    $bsp.Orientation        = [System.Windows.Controls.Orientation]::Horizontal
    $bsp.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $bsp.Margin             = [System.Windows.Thickness]::new(20, 0, 20, 20)
    [System.Windows.Controls.DockPanel]::SetDock($bsp, [System.Windows.Controls.Dock]::Bottom)

    $sv = Make-DlgBtn "Save"   $true;  $sv.Width = 90; $sv.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $ca = Make-DlgBtn "Cancel" $false; $ca.Width = 90
    $sv.Add_Click({ $dlg.Tag = "OK";     $dlg.Close() })
    $ca.Add_Click({ $dlg.Tag = "Cancel"; $dlg.Close() })
    $bsp.Children.Add($sv) | Out-Null
    $bsp.Children.Add($ca) | Out-Null
    $mainDock.Children.Add($bsp) | Out-Null

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin   = [System.Windows.Thickness]::new(20, 20, 20, 12)
    $grayFg      = B 0xB8 0xC0 0xE0

    $t2 = New-Object System.Windows.Controls.TextBlock
    $t2.Text       = "Changes apply to new connections (except where noted)."
    $t2.Foreground = B 0x93 0x9A 0xB7
    $t2.FontSize   = 12
    $t2.FontStyle  = [System.Windows.FontStyles]::Italic
    $t2.Margin     = [System.Windows.Thickness]::new(0, 0, 0, 16)
    $sp.Children.Add($t2) | Out-Null

    # Refresh rate
    $rrSp = New-Object System.Windows.Controls.StackPanel; $rrSp.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $rrL  = New-Object System.Windows.Controls.TextBlock; $rrL.Text = "Refresh Rate (applies immediately):"; $rrL.Foreground = $grayFg; $rrL.FontSize = 13; $rrL.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $rrCombo = New-Object System.Windows.Controls.ComboBox; $rrCombo.Style = $window.FindResource("DarkComboBox"); $rrCombo.FontSize = 13; $rrCombo.Height = 32
    $i1 = New-Object System.Windows.Controls.ComboBoxItem; $i1.Content = "~60 FPS (16 ms)"
    $i2 = New-Object System.Windows.Controls.ComboBoxItem; $i2.Content = "~30 FPS (33 ms)"
    $rrCombo.Items.Add($i1) | Out-Null; $rrCombo.Items.Add($i2) | Out-Null
    $rrCombo.SelectedIndex = if ($script:vncSettings.RefreshRate -le 16) { 0 } else { 1 }
    $rrSp.Children.Add($rrL) | Out-Null; $rrSp.Children.Add($rrCombo) | Out-Null; $sp.Children.Add($rrSp) | Out-Null

    # Dropdown count
    $dcSp = New-Object System.Windows.Controls.StackPanel; $dcSp.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $dcL  = New-Object System.Windows.Controls.TextBlock; $dcL.Text = "Dropdown History Count (applies immediately):"; $dcL.Foreground = $grayFg; $dcL.FontSize = 13; $dcL.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $dcCombo = New-Object System.Windows.Controls.ComboBox; $dcCombo.Style = $window.FindResource("DarkComboBox"); $dcCombo.FontSize = 13; $dcCombo.Height = 32
    foreach ($v in @(3, 5, 10, 15, 20)) {
        $item = New-Object System.Windows.Controls.ComboBoxItem; $item.Content = "$v items"; $item.Tag = $v
        $dcCombo.Items.Add($item) | Out-Null
        if ($script:vncSettings.DropDownCount -eq $v) { $dcCombo.SelectedItem = $item }
    }
    if ($null -eq $dcCombo.SelectedItem) { $dcCombo.SelectedIndex = 1 }
    $dcSp.Children.Add($dcL) | Out-Null; $dcSp.Children.Add($dcCombo) | Out-Null; $sp.Children.Add($dcSp) | Out-Null

    $cbShared = New-Object System.Windows.Controls.CheckBox; $cbShared.Content = "  Shared Connection (allow others)";     $cbShared.Foreground = $grayFg; $cbShared.FontSize = 13; $cbShared.IsChecked = $script:vncSettings.SharedConnection; $cbShared.Margin = [System.Windows.Thickness]::new(0,0,0,8); $sp.Children.Add($cbShared) | Out-Null
    $cbVO     = New-Object System.Windows.Controls.CheckBox; $cbVO.Content     = "  View Only (applies immediately)";       $cbVO.Foreground     = $grayFg; $cbVO.FontSize     = 13; $cbVO.IsChecked     = $script:vncSettings.ViewOnly;         $cbVO.Margin     = [System.Windows.Thickness]::new(0,0,0,8); $sp.Children.Add($cbVO)     | Out-Null
    $cbClip   = New-Object System.Windows.Controls.CheckBox; $cbClip.Content   = "  Auto Clipboard Sync (applies immediately)"; $cbClip.Foreground = $grayFg; $cbClip.FontSize = 13; $cbClip.IsChecked   = $script:vncSettings.ClipboardSync;    $cbClip.Margin   = [System.Windows.Thickness]::new(0,0,0,0); $sp.Children.Add($cbClip)   | Out-Null

    $mainDock.Children.Add($sp) | Out-Null
    $dlg.ShowDialog() | Out-Null

    if ($dlg.Tag -eq "OK") {
        $script:vncSettings.RefreshRate      = @(16, 33)[$rrCombo.SelectedIndex]
        $script:vncSettings.SharedConnection = [bool]$cbShared.IsChecked
        $script:vncSettings.ViewOnly         = [bool]$cbVO.IsChecked
        $script:vncSettings.ClipboardSync    = [bool]$cbClip.IsChecked
        $selItem = $dcCombo.SelectedItem
        if ($null -ne $selItem) { $script:vncSettings.DropDownCount = [int]$selItem.Tag }
        Save-VncSettings
        while ($script:recentHosts.Count     -gt $script:vncSettings.DropDownCount) { $script:recentHosts.RemoveAt($script:recentHosts.Count - 1) }
        while ($script:recentPasswords.Count -gt $script:vncSettings.DropDownCount) { $script:recentPasswords.RemoveAt($script:recentPasswords.Count - 1) }
        Save-ConfigIni
        if ($null -ne $script:updateTimer) { $script:updateTimer.Interval = [TimeSpan]::FromMilliseconds($script:vncSettings.RefreshRate) }
        if ($null -ne $script:vncEngine)   { $script:vncEngine.ViewOnly = $script:vncSettings.ViewOnly; $script:vncEngine.ClipboardSync = $script:vncSettings.ClipboardSync }
    }
    $vncCanvas.Focus()
}

# ============================================================
# STATS HELPERS
# ============================================================
function Format-DataSize([long]$b) {
    if ($b -lt 1KB) { return "$b B" }
    if ($b -lt 1MB) { return "{0:N1} KB" -f ($b / 1KB) }
    if ($b -lt 1GB) { return "{0:N1} MB" -f ($b / 1MB) }
    return "{0:N2} GB" -f ($b / 1GB)
}

function Format-Uptime([long]$ms) {
    $ts = [TimeSpan]::FromMilliseconds($ms)
    if ($ts.TotalHours -ge 1) { return "{0:D2}:{1:D2}:{2:D2}" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds }
    return "{0:D2}:{1:D2}" -f $ts.Minutes, $ts.Seconds
}

function Reset-Stats {
    $txtFps.Text = "--"; $txtFrames.Text = "--"; $txtData.Text = "--"; $txtLatency.Text = "--"; $txtUptime.Text = "--"
}

function Update-Stats {
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }
    $txtFps.Text     = "{0:N1}" -f $script:vncEngine.CurrentFps
    $txtFrames.Text  = $script:vncEngine.FrameCount.ToString("N0")
    $txtData.Text    = Format-DataSize $script:vncEngine.BytesReceived
    $txtLatency.Text = "$($script:vncEngine.LastPingMs) ms"
    $txtUptime.Text  = Format-Uptime $script:vncEngine.UptimeMs
}

function Set-Connected([bool]$state) {
    if ($state) {
        $btnConnect.Visibility     = [System.Windows.Visibility]::Collapsed
        $btnDisconnect.Visibility  = [System.Windows.Visibility]::Visible
        $sep1.Visibility           = [System.Windows.Visibility]::Visible
        $btnFitWindow.Visibility   = [System.Windows.Visibility]::Visible
        $btnFullScreen.Visibility  = [System.Windows.Visibility]::Visible
        $btnClipboard.Visibility   = [System.Windows.Visibility]::Visible
        $sep2.Visibility           = [System.Windows.Visibility]::Visible
        $statusDot.Fill            = B 0xA6 0xDA 0x95
        $noConnectionOverlay.Visibility = [System.Windows.Visibility]::Collapsed
    } else {
        $btnConnect.Visibility     = [System.Windows.Visibility]::Visible
        $btnDisconnect.Visibility  = [System.Windows.Visibility]::Collapsed
        $sep1.Visibility           = [System.Windows.Visibility]::Collapsed
        $btnFitWindow.Visibility   = [System.Windows.Visibility]::Collapsed
        $btnFullScreen.Visibility  = [System.Windows.Visibility]::Collapsed
        $btnClipboard.Visibility   = [System.Windows.Visibility]::Collapsed
        $sep2.Visibility           = [System.Windows.Visibility]::Collapsed
        $statusDot.Fill            = B 0xED 0x87 0x96
        $txtStatus.Text            = "Disconnected"
        $txtResolution.Text        = ""
        Reset-Stats
    }
}

# ============================================================
# FULLSCREEN
# ============================================================
function Enter-FullScreen {
    if ($script:isFullScreen) { return }
    $script:isFullScreen = $true
    if ($script:panelOpen) { Hide-SidePanel }
    $script:savedWindowState  = $window.WindowState
    $script:savedWindowStyle  = $window.WindowStyle
    $script:savedWindowRect   = @{ Left=$window.Left; Top=$window.Top; Width=$window.Width; Height=$window.Height }
    $script:savedResizeMode   = $window.ResizeMode
    $window.WindowState       = [System.Windows.WindowState]::Normal
    $toolbarBorder.Visibility = [System.Windows.Visibility]::Collapsed
    $statsBorder.Visibility   = [System.Windows.Visibility]::Collapsed
    $window.WindowStyle       = [System.Windows.WindowStyle]::None
    $window.ResizeMode        = [System.Windows.ResizeMode]::NoResize
    $window.Topmost           = $true
    $screen  = [System.Windows.SystemParameters]::PrimaryScreenWidth
    $screenH = [System.Windows.SystemParameters]::PrimaryScreenHeight
    $window.Left = 0; $window.Top = 0; $window.Width = $screen; $window.Height = $screenH
    if (-not $script:fitMode) { $script:fitMode = $true; Apply-FitMode }
    $fsHoverZone.Visibility = [System.Windows.Visibility]::Visible
    $entry = Find-HistoryEntry $script:activeSessionKey
    $fsSessionName.Text = if ($null -ne $entry) { Get-SessionDisplayName $entry } else { $script:activeSessionKey }
    $btnFullScreen.Content = "Windowed"
}

function Exit-FullScreen {
    if (-not $script:isFullScreen) { return }
    $script:isFullScreen   = $false
    $fullscreenBar.Height  = 0
    $fsHoverZone.Visibility = [System.Windows.Visibility]::Collapsed
    $script:fsBarVisible   = $false
    $window.Topmost        = $false
    $window.WindowStyle    = $script:savedWindowStyle
    $window.ResizeMode     = $script:savedResizeMode
    if ($null -ne $script:savedWindowRect) {
        $window.Left   = $script:savedWindowRect.Left
        $window.Top    = $script:savedWindowRect.Top
        $window.Width  = $script:savedWindowRect.Width
        $window.Height = $script:savedWindowRect.Height
    }
    $window.WindowState       = $script:savedWindowState
    $toolbarBorder.Visibility = [System.Windows.Visibility]::Visible
    $statsBorder.Visibility   = [System.Windows.Visibility]::Visible
    $btnFullScreen.Content    = "Full Screen"
}

function Show-FullscreenBar {
    if ($script:fsBarVisible) { return }
    $script:fsBarVisible  = $true
    $fullscreenBar.Height = 44
    if ($null -ne $script:fsBarTimer) { $script:fsBarTimer.Stop() }
    $script:fsBarTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:fsBarTimer.Interval = [TimeSpan]::FromSeconds(3)
    $script:fsBarTimer.Add_Tick({ $script:fsBarTimer.Stop(); Hide-FullscreenBar })
    $script:fsBarTimer.Start()
}

function Hide-FullscreenBar { $script:fsBarVisible = $false; $fullscreenBar.Height = 0 }

# ============================================================
# FIT MODE
# ============================================================
function Apply-FitMode {
    $vncImage.Stretch = [System.Windows.Media.Stretch]::Uniform
    $wb = New-Object System.Windows.Data.Binding("ViewportWidth");  $wb.Source = $scrollViewer
    $hb = New-Object System.Windows.Data.Binding("ViewportHeight"); $hb.Source = $scrollViewer
    $vncCanvas.SetBinding([System.Windows.FrameworkElement]::WidthProperty,  $wb)
    $vncCanvas.SetBinding([System.Windows.FrameworkElement]::HeightProperty, $hb)
    $iwb = New-Object System.Windows.Data.Binding("ViewportWidth");  $iwb.Source = $scrollViewer
    $ihb = New-Object System.Windows.Data.Binding("ViewportHeight"); $ihb.Source = $scrollViewer
    $vncImage.SetBinding([System.Windows.FrameworkElement]::WidthProperty,  $iwb)
    $vncImage.SetBinding([System.Windows.FrameworkElement]::HeightProperty, $ihb)
    $scrollViewer.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $scrollViewer.VerticalScrollBarVisibility   = [System.Windows.Controls.ScrollBarVisibility]::Disabled
}

function Remove-FitMode {
    $vncImage.Stretch = [System.Windows.Media.Stretch]::None
    foreach ($dp in @([System.Windows.FrameworkElement]::WidthProperty, [System.Windows.FrameworkElement]::HeightProperty)) {
        [System.Windows.Data.BindingOperations]::ClearBinding($vncCanvas, $dp)
        [System.Windows.Data.BindingOperations]::ClearBinding($vncImage,  $dp)
    }
    $vncImage.Width  = [double]::NaN
    $vncImage.Height = [double]::NaN
    $scrollViewer.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $scrollViewer.VerticalScrollBarVisibility   = [System.Windows.Controls.ScrollBarVisibility]::Auto
    if ($null -ne $script:vncEngine) { $vncCanvas.Width = $script:vncEngine.FramebufferWidth; $vncCanvas.Height = $script:vncEngine.FramebufferHeight }
}

# ============================================================
# SIDE PANEL
# ============================================================
function Hide-SidePanel {
    $sidePanelCol.MinWidth          = 0
    $sidePanelCol.Width             = 0
    $panelSplitter.Visibility       = [System.Windows.Visibility]::Collapsed
    $script:panelOpen               = $false
    $btnTogglePanel.Content         = [char]0x2630
}

function Show-SidePanel {
    $sidePanelCol.MinWidth          = 160
    $sidePanelCol.Width             = New-Object System.Windows.GridLength($script:panelWidth)
    $panelSplitter.Visibility       = [System.Windows.Visibility]::Visible
    $script:panelOpen               = $true
    $btnTogglePanel.Content         = [char]0x2630
    Update-SessionPanel
}

function Toggle-SidePanel { if ($script:panelOpen) { Hide-SidePanel } else { Show-SidePanel } }

function New-PanelButton([string]$Line1, [string]$Line2, [System.Windows.Media.Brush]$DotColor, [bool]$IsCurrent, [scriptblock]$OnClick, [System.Windows.Controls.ContextMenu]$ContextMenu) {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = if ($IsCurrent) { $window.FindResource("PanelBtnStyleCurrent") } else { $window.FindResource("PanelBtnStyle") }
    $btn.HorizontalContentAlignment = [System.Windows.HorizontalAlignment]::Stretch

    $sp2  = New-Object System.Windows.Controls.StackPanel
    $row1 = New-Object System.Windows.Controls.StackPanel
    $row1.Orientation = [System.Windows.Controls.Orientation]::Horizontal

    if ($null -ne $DotColor) {
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 8; $dot.Height = 8; $dot.Fill = $DotColor
        $dot.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $row1.Children.Add($dot) | Out-Null
    }

    $tb1 = New-Object System.Windows.Controls.TextBlock
    $tb1.Text   = $Line1
    $tb1.FontSize = 13
    if ($IsCurrent) { $tb1.FontWeight = [System.Windows.FontWeights]::Bold }
    $row1.Children.Add($tb1) | Out-Null

    if ($IsCurrent) {
        $ar = New-Object System.Windows.Controls.TextBlock
        $ar.Text = "  <"; $ar.FontSize = 11; $ar.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $row1.Children.Add($ar) | Out-Null
    }

    $sp2.Children.Add($row1) | Out-Null

    if ($Line2) {
        $tb2 = New-Object System.Windows.Controls.TextBlock
        $tb2.Text        = $Line2
        $tb2.FontSize    = 11
        $tb2.FontFamily  = New-Object System.Windows.Media.FontFamily("Consolas")
        $tb2.Margin      = [System.Windows.Thickness]::new(14, 2, 0, 0)
        $tb2.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $sp2.Children.Add($tb2) | Out-Null
    }

    $btn.Content = $sp2
    if ($OnClick)      { $btn.Add_Click($OnClick) }
    if ($ContextMenu)  { $btn.ContextMenu = $ContextMenu }
    return $btn
}

function New-ContextMenu([string]$Key, [bool]$IsActive) {
    $ctx    = New-Object System.Windows.Controls.ContextMenu
    $entry  = Find-HistoryEntry $Key
    $pinned = ($null -ne $entry -and $entry.Pinned)

    if ($IsActive) {
        $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = "Disconnect"; $ck = $Key
        $mi.Add_Click({ Disconnect-Session $ck }.GetNewClosure())
        $ctx.Items.Add($mi) | Out-Null
        $ctx.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    }

    $mi3 = New-Object System.Windows.Controls.MenuItem; $mi3.Header = if ($pinned) { "Unpin" } else { "Pin" }; $ck3 = $Key
    $mi3.Add_Click({ Toggle-Pin $ck3 }.GetNewClosure())
    $ctx.Items.Add($mi3) | Out-Null

    if (-not $IsActive) {
        $ctx.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
        $mi4 = New-Object System.Windows.Controls.MenuItem; $mi4.Header = "Remove from history"; $ck4 = $Key
        $mi4.Add_Click({ Remove-HistoryEntry $ck4 }.GetNewClosure())
        $ctx.Items.Add($mi4) | Out-Null
    }
    return $ctx
}

function Make-EmptyLabel([string]$Text) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text       = "  $Text"
    $tb.Foreground = B 0x93 0x9A 0xB7
    $tb.FontSize   = 12
    $tb.Margin     = [System.Windows.Thickness]::new(10, 8, 10, 8)
    $tb.FontStyle  = [System.Windows.FontStyles]::Italic
    return $tb
}

function Update-SessionPanel {
    $pinnedSessionsList.Children.Clear()
    $activeSessionsList.Children.Clear()
    $recentSessionsList.Children.Clear()

    # --- Pinned ---
    $pinnedEntries = @($script:recentSessions | Where-Object { $_.Pinned })
    if ($pinnedEntries.Count -eq 0) {
        $pinnedSessionsList.Children.Add((Make-EmptyLabel "No pinned sessions")) | Out-Null
    } else {
        foreach ($s in $pinnedEntries) {
            $k     = "$($s.Host):$($s.Port)"
            $isAct = $script:activeSessions.ContainsKey($k)
            $isCur = ($k -eq $script:activeSessionKey)
            $dc    = $null
            if ($isAct) { $eng = $script:activeSessions[$k]; $dc = if ($eng.IsConnected) { [System.Windows.Media.Brushes]::LimeGreen } else { [System.Windows.Media.Brushes]::OrangeRed } }
            $cK = $k; $rH = $s.Host; $rP = $s.Port; $rPW = $s.Password
            $oc = if ($isAct) {
                { Switch-ToSession $cK }.GetNewClosure()
            } else {
                {
                    $txtHost.Text = $rH; $txtPort.Text = $rP.ToString()
                    if ($rPW) { $script:syncingPw = $true; $txtPassword.Password = $rPW; $txtPasswordVisible.Text = $rPW; $script:syncingPw = $false }
                    Do-Connect
                }.GetNewClosure()
            }
            $btn = New-PanelButton -Line1 $s.Host -Line2 "" -DotColor $dc -IsCurrent $isCur -OnClick $oc -ContextMenu (New-ContextMenu $k $isAct)
            $pinnedSessionsList.Children.Add($btn) | Out-Null
        }
    }

    # --- Active ---
    $addedAct = $false
    foreach ($k in @($script:activeSessions.Keys)) {
        $entry = Find-HistoryEntry $k
        if ($null -ne $entry -and $entry.Pinned) { continue }
        $addedAct = $true
        $eng   = $script:activeSessions[$k]
        $isCur = ($k -eq $script:activeSessionKey)
        $dc    = if ($eng.IsConnected) { [System.Windows.Media.Brushes]::LimeGreen } else { [System.Windows.Media.Brushes]::OrangeRed }
        $parts = $k -split ':'
        $cK    = $k
        $btn   = New-PanelButton -Line1 $parts[0] -Line2 "Port: $($parts[1])" -DotColor $dc -IsCurrent $isCur -OnClick { Switch-ToSession $cK }.GetNewClosure() -ContextMenu (New-ContextMenu $k $true)
        $activeSessionsList.Children.Add($btn) | Out-Null
    }
    if (-not $addedAct) { $activeSessionsList.Children.Add((Make-EmptyLabel "No active sessions")) | Out-Null }

    # --- Recent (condensed, single line) ---
    $hasRec = $false
    foreach ($s in $script:recentSessions) {
        $k = "$($s.Host):$($s.Port)"
        if ($script:activeSessions.ContainsKey($k)) { continue }
        if ($s.Pinned) { continue }
        $hasRec = $true
        $rH = $s.Host; $rP = $s.Port; $rPW = $s.Password
        $btn = New-PanelButton -Line1 $s.Host -Line2 "" -DotColor $null -IsCurrent $false -OnClick {
            $txtHost.Text = $rH; $txtPort.Text = $rP.ToString()
            if ($rPW) { $script:syncingPw = $true; $txtPassword.Password = $rPW; $txtPasswordVisible.Text = $rPW; $script:syncingPw = $false }
            Do-Connect
        }.GetNewClosure() -ContextMenu (New-ContextMenu $k $false)
        $recentSessionsList.Children.Add($btn) | Out-Null
    }
    if (-not $hasRec) { $recentSessionsList.Children.Add((Make-EmptyLabel "No recent sessions")) | Out-Null }
}

# ============================================================
# SESSION MANAGEMENT
# ============================================================
function Switch-ToSession([string]$SessionKey) {
    if (-not $script:activeSessions.ContainsKey($SessionKey)) { return }
    if ($SessionKey -eq $script:activeSessionKey) { return }
    if ($null -ne $script:updateTimer) { $script:updateTimer.Stop(); $script:updateTimer = $null }
    $script:writeableBmp = $null; $script:lastFrameVer = -1; $vncImage.Source = $null
    $script:vncEngine       = $script:activeSessions[$SessionKey]
    $script:activeSessionKey = $SessionKey

    if ($script:vncEngine.IsConnected) {
        $fw    = $script:vncEngine.FramebufferWidth
        $fh    = $script:vncEngine.FramebufferHeight
        $parts = $SessionKey -split ':'
        $txtHost.Text = $parts[0]; $txtPort.Text = $parts[1]
        $entry = Find-HistoryEntry $SessionKey
        if ($null -ne $entry -and $entry.Password) {
            $script:syncingPw = $true; $txtPassword.Password = $entry.Password; $txtPasswordVisible.Text = $entry.Password; $script:syncingPw = $false
        }
        if ($script:fitMode) { Apply-FitMode } else { $vncCanvas.Width = $fw; $vncCanvas.Height = $fh }
        $dn = if ($null -ne $entry) { Get-SessionDisplayName $entry } else { $SessionKey }
        Set-Connected $true; $txtStatus.Text = "Connected - $dn"; $txtResolution.Text = "${fw} x ${fh}"
        $script:updateTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:updateTimer.Interval = [TimeSpan]::FromMilliseconds($script:vncSettings.RefreshRate)
        $script:updateTimer.Add_Tick({ Update-Frame })
        $script:updateTimer.Start()
        $script:vncEngine.RequestFullRefresh()
        $vncCanvas.Focus()
    }
    Update-SessionPanel
}

function Disconnect-Session([string]$SessionKey) {
    if (-not $script:activeSessions.ContainsKey($SessionKey)) { return }
    $script:activeSessions[$SessionKey].Disconnect()
    $script:activeSessions.Remove($SessionKey)
    if ($SessionKey -eq $script:activeSessionKey) { Stop-VncSession -KeepOthers }
    Update-SessionPanel
}

function Purge-DeadSessions {
    $dead = @($script:activeSessions.Keys | Where-Object { -not $script:activeSessions[$_].IsConnected })
    if ($dead.Count -gt 0) {
        foreach ($dk in $dead) { $script:activeSessions[$dk].Disconnect(); $script:activeSessions.Remove($dk) }
        Update-SessionPanel
    }
}

function Update-Frame {
    if ($null -eq $script:vncEngine) { return }
    if (-not $script:vncEngine.IsConnected) {
        $err = $script:vncEngine.LastError
        $key = $script:activeSessionKey
        if ($null -ne $key -and $script:activeSessions.ContainsKey($key)) { $script:activeSessions.Remove($key) }
        Stop-VncSession -KeepOthers
        $txtStatus.Text = "Lost: $err"
        Update-SessionPanel
        return
    }
    $ver = $script:vncEngine.FrameVersion
    if ($ver -eq $script:lastFrameVer) { return }
    $script:lastFrameVer = $ver
    $w  = $script:vncEngine.FramebufferWidth
    $h  = $script:vncEngine.FramebufferHeight
    $fb = $script:vncEngine.GetFrameBufferDirect()
    if ($null -eq $fb -or $w -le 0 -or $h -le 0) { return }
    if ($null -eq $script:writeableBmp -or $script:writeableBmp.PixelWidth -ne $w -or $script:writeableBmp.PixelHeight -ne $h) {
        $script:writeableBmp = New-Object System.Windows.Media.Imaging.WriteableBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Bgr32, $null)
        $vncImage.Source = $script:writeableBmp
        if (-not $script:fitMode) { $vncCanvas.Width = $w; $vncCanvas.Height = $h }
        $txtResolution.Text = "${w} x ${h}"
    }
    try { $script:writeableBmp.WritePixels((New-Object System.Windows.Int32Rect(0, 0, $w, $h)), $fb, ($w * 4), 0) } catch {}
}

function Stop-VncSession {
    param([switch]$KeepOthers)
    if ($null -ne $script:updateTimer) { $script:updateTimer.Stop(); $script:updateTimer = $null }
    if ($KeepOthers) {
        $script:vncEngine = $null
    } else {
        if ($null -ne $script:vncEngine) { $script:vncEngine.Disconnect(); $script:vncEngine = $null }
        foreach ($k in @($script:activeSessions.Keys)) { $script:activeSessions[$k].Disconnect() }
        $script:activeSessions.Clear()
    }
    $script:activeSessionKey = $null
    $script:writeableBmp     = $null
    $script:lastFrameVer     = -1
    $vncImage.Source         = $null
    if ($script:fitMode -and -not $script:isFullScreen) { Remove-FitMode; $script:fitMode = $false; $btnFitWindow.Content = "Fit Window" }
    if ($script:isFullScreen) { Exit-FullScreen }
    Set-Connected $false
    $noConnectionOverlay.Visibility = [System.Windows.Visibility]::Visible
    Update-SessionPanel
}

function Get-ScaledPos($e) {
    $pos = $e.GetPosition($vncImage)
    $x   = [int]$pos.X; $y = [int]$pos.Y
    if ($script:fitMode -and $null -ne $script:vncEngine) {
        $dw = $vncImage.ActualWidth;  $dh = $vncImage.ActualHeight
        $fw = $script:vncEngine.FramebufferWidth; $fh = $script:vncEngine.FramebufferHeight
        if ($dw -gt 0 -and $dh -gt 0 -and $fw -gt 0 -and $fh -gt 0) {
            $scale = [Math]::Min($dw / $fw, $dh / $fh)
            $x = [int](($pos.X - ($dw - $fw * $scale) / 2) / $scale)
            $y = [int](($pos.Y - ($dh - $fh * $scale) / 2) / $scale)
        }
    }
    if ($null -ne $script:vncEngine) {
        $x = [Math]::Max(0, [Math]::Min($x, $script:vncEngine.FramebufferWidth  - 1))
        $y = [Math]::Max(0, [Math]::Min($y, $script:vncEngine.FramebufferHeight - 1))
    }
    return @{ X = $x; Y = $y }
}

# ============================================================
# CONNECT (async via runspace)
# ============================================================
function Do-Connect {
    if ($null -ne $script:connectAsyncHandle -and -not $script:connectAsyncHandle.IsCompleted) { return }

    $h = $txtHost.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($h)) { Show-DarkMessageDialog "Invalid Input" "Enter a host."; return }
    if ($txtHost.Text -ne $h) { Show-DarkMessageDialog "Invalid Input" "Hostnames cannot contain leading or trailing spaces."; return }

    $isValid = ($h -match '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$') -or
               ($h -match '^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$') -or
               ($h -match '^(?=.{1,255}$)[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$')
    if (-not $isValid) { Show-DarkMessageDialog "Invalid Input" "Enter a valid hostname or IP address."; return }

    if (-not ($txtPort.Text.Trim() -match '^\d+$')) { Show-DarkMessageDialog "Invalid Input" "Enter a valid numeric port."; return }
    $p  = [int]$txtPort.Text.Trim()
    $pw = Get-Password
    $sk = "${h}:${p}"

    Add-ToRecentHosts $h
    if ($pw) { Add-ToRecentPasswords $pw }
    Save-ConfigIni

    if ($script:activeSessions.ContainsKey($sk)) {
        if ($script:activeSessions[$sk].IsConnected) { Switch-ToSession $sk; return }
        else { $script:activeSessions[$sk].Disconnect(); $script:activeSessions.Remove($sk) }
    }

    if ($null -ne $script:updateTimer) { $script:updateTimer.Stop(); $script:updateTimer = $null }
    $script:writeableBmp = $null; $script:lastFrameVer = -1; $vncImage.Source = $null

    $txtStatus.Text        = "Connecting to ${h}:${p} ..."
    $window.Cursor         = [System.Windows.Input.Cursors]::Wait
    $btnConnect.Visibility = [System.Windows.Visibility]::Collapsed
    $btnDisconnect.Visibility = [System.Windows.Visibility]::Visible
    $btnDisconnect.Content = "Cancel"
    $statusDot.Fill        = B 0xEE 0xD4 0x9F

    $shared   = $script:vncSettings.SharedConnection
    $viewOnly = $script:vncSettings.ViewOnly
    $clipSync = $script:vncSettings.ClipboardSync
    $ne       = New-Object VncEngine

    $script:pendingConnect      = $ne
    $script:pendingConnectKey   = $sk
    $script:pendingConnectHost  = $h
    $script:pendingConnectPort  = $p
    $script:pendingConnectPw    = $pw
    $script:connectCancelled    = $false

    $script:connectRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:connectRunspace.Open()
    $script:connectBgPS = [System.Management.Automation.PowerShell]::Create()
    $script:connectBgPS.Runspace = $script:connectRunspace
    $script:connectBgPS.AddScript('param($e,$h,$p,$pw,$sh,$vo,$cs) return $e.Connect($h,$p,$pw,$sh,$vo,$cs)') | Out-Null
    $script:connectBgPS.AddArgument($ne)       | Out-Null
    $script:connectBgPS.AddArgument($h)        | Out-Null
    $script:connectBgPS.AddArgument($p)        | Out-Null
    $script:connectBgPS.AddArgument($pw)       | Out-Null
    $script:connectBgPS.AddArgument($shared)   | Out-Null
    $script:connectBgPS.AddArgument($viewOnly) | Out-Null
    $script:connectBgPS.AddArgument($clipSync) | Out-Null

    try { $script:connectAsyncHandle = $script:connectBgPS.BeginInvoke() }
    catch {
        Complete-PendingConnect
        Show-DarkMessageDialog "Connection Error" "Failed to start connection:`n$($_.Exception.Message)"
        return
    }

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
    $ne  = $script:pendingConnect
    $sk  = $script:pendingConnectKey
    $h   = $script:pendingConnectHost
    $p   = $script:pendingConnectPort
    $pw  = $script:pendingConnectPw
    $ok  = $false

    try { $result = $script:connectBgPS.EndInvoke($script:connectAsyncHandle); if ($result -and $result.Count -gt 0) { $ok = [bool]$result[0] } } catch { $ok = $false }
    try { $script:connectBgPS.Dispose() }   catch {}
    try { $script:connectRunspace.Close() } catch {}
    try { $script:connectRunspace.Dispose() } catch {}

    $script:connectAsyncHandle = $null
    $script:connectBgPS        = $null
    $script:connectRunspace    = $null
    $btnDisconnect.Content     = "Disconnect"

    if ($script:connectCancelled) {
        if ($null -ne $ne) { $ne.Disconnect() }
        $btnConnect.Visibility    = [System.Windows.Visibility]::Visible
        $btnDisconnect.Visibility = [System.Windows.Visibility]::Collapsed
        $statusDot.Fill           = B 0xED 0x87 0x96
        $txtStatus.Text           = "Cancelled"
        $script:pendingConnect    = $null
        return
    }

    if ($ok) {
        $fw = $ne.FramebufferWidth; $fh = $ne.FramebufferHeight
        $script:vncEngine        = $ne
        $script:activeSessionKey = $sk
        $script:activeSessions[$sk] = $ne
        Add-ToHistory -H $h -P $p -PW $pw
        $entry = Find-HistoryEntry $sk
        $dn    = if ($null -ne $entry) { Get-SessionDisplayName $entry } else { $sk }
        if ($script:fitMode) { Apply-FitMode } else { $vncCanvas.Width = $fw; $vncCanvas.Height = $fh }
        Set-Connected $true; $txtStatus.Text = "Connected - $dn"; $txtResolution.Text = "${fw} x ${fh}"; $vncCanvas.Focus()
        $script:updateTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:updateTimer.Interval = [TimeSpan]::FromMilliseconds($script:vncSettings.RefreshRate)
        $script:updateTimer.Add_Tick({ Update-Frame })
        $script:updateTimer.Start()
        Update-SessionPanel
    } else {
        $err = if ($null -ne $ne) { $ne.LastError } else { "Unknown error" }
        if ($null -ne $ne) { $ne.Disconnect() }
        $btnConnect.Visibility    = [System.Windows.Visibility]::Visible
        $btnDisconnect.Visibility = [System.Windows.Visibility]::Collapsed
        $statusDot.Fill           = B 0xED 0x87 0x96
        $txtStatus.Text           = "Failed: $err"
        if ($null -ne $script:activeSessionKey -and $script:activeSessions.ContainsKey($script:activeSessionKey)) {
            Switch-ToSession $script:activeSessionKey
        } else {
            $noConnectionOverlay.Visibility = [System.Windows.Visibility]::Visible
        }
        Show-DarkMessageDialog "Connection Failed" "Connection failed:`n$err"
    }
    $script:pendingConnect = $null
}

function Cancel-PendingConnect {
    if ($null -eq $script:connectAsyncHandle -or $script:connectAsyncHandle.IsCompleted) { return $false }
    $script:connectCancelled = $true
    if ($null -ne $script:pendingConnect) { try { $script:pendingConnect.Disconnect() } catch {} }
    return $true
}

# ============================================================
# CLIPBOARD SYNC
# ============================================================
function Sync-Clipboard {
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }
    if (-not $script:vncSettings.ClipboardSync) { return }

    if ($script:vncEngine.HasNewServerClipboard) {
        $script:vncEngine.HasNewServerClipboard = $false
        $srvTxt = $script:vncEngine.ServerClipboard
        if ($srvTxt) {
            try {
                $curLocal = ""
                try { if ([System.Windows.Clipboard]::ContainsText()) { $curLocal = [System.Windows.Clipboard]::GetText() } } catch {}
                if ($curLocal -ne $srvTxt) { [System.Windows.Clipboard]::SetText($srvTxt); $script:lastLocalClipboard = $srvTxt }
            } catch {}
        }
    }

    try {
        if ([System.Windows.Clipboard]::ContainsText()) {
            $lt = [System.Windows.Clipboard]::GetText()
            if ($lt -and $lt -ne $script:lastLocalClipboard) { $script:lastLocalClipboard = $lt; $script:vncEngine.SendClientCutText($lt) }
        }
    } catch {}
}

# ============================================================
# LOAD
# ============================================================
Load-ConfigIni; Load-SessionHistory; Load-VncSettings
$sidePanelCol.Width = New-Object System.Windows.GridLength($script:panelWidth)
$window.Width       = $script:windowWidth
$window.Height      = $script:windowHeight

if ($script:showPassword) {
    $txtPassword.Visibility        = [System.Windows.Visibility]::Collapsed
    $txtPasswordVisible.Visibility = [System.Windows.Visibility]::Visible
    $btnTogglePw.Background        = B 0xC6 0xA0 0xF6
    $btnTogglePw.Foreground        = B 0x18 0x19 0x26
    $script:pwVisible              = $true
}
Update-SessionPanel

# ============================================================
# EVENT HANDLERS
# ============================================================
$btnConnect.Add_Click({ Do-Connect })

$btnDisconnect.Add_Click({
    if (Cancel-PendingConnect) { return }
    if ($null -ne $script:activeSessionKey) { Disconnect-Session $script:activeSessionKey } else { Stop-VncSession }
})

$btnFitWindow.Add_Click({
    if ($null -eq $script:vncEngine) { return }
    $script:fitMode = -not $script:fitMode
    if ($script:fitMode) { $btnFitWindow.Content = "1:1 Mode"; Apply-FitMode } else { $btnFitWindow.Content = "Fit Window"; Remove-FitMode }
    $vncCanvas.Focus()
})

$btnFullScreen.Add_Click({ if ($script:isFullScreen) { Exit-FullScreen } else { Enter-FullScreen }; $vncCanvas.Focus() })
$btnClipboard.Add_Click({ Show-ClipboardDialog })
$btnSettings.Add_Click({ Show-SettingsDialog })
$btnTogglePanel.Add_Click({ Toggle-SidePanel })
$btnClearHistory.Add_Click({ $script:recentSessions.Clear(); Save-SessionHistory; Update-SessionPanel })

$btnPasteHost.Add_Click({
    try {
        if ([System.Windows.Clipboard]::ContainsText()) {
            $clipText = [System.Windows.Clipboard]::GetText().Trim()
            if ($clipText) { $txtHost.Text = $clipText; $txtHost.Focus(); $txtHost.SelectAll() }
        }
    } catch {}
})

$btnHostHistory.Add_Click({ Show-HostHistoryDropdown })
$btnPwHistory.Add_Click({ Show-PwHistoryDropdown })

# Hostname input restrictions
$txtHost.Add_PreviewTextInput({
    param($s, $e)
    $e.Handled = $e.Text -notmatch '^[a-zA-Z0-9\.\-:]$'
})
$txtHost.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Space) { $e.Handled = $true }
})

[System.Windows.DataObject]::AddPastingHandler($txtHost, [System.Windows.DataObjectPastingEventHandler]{
    param($s, $e)
    if ($e.DataObject.GetDataPresent([System.Windows.DataFormats]::Text)) {
        $text    = [string]$e.DataObject.GetData([System.Windows.DataFormats]::Text)
        $cleaned = $text -replace '[^a-zA-Z0-9\.\-:]', ''
        if ($cleaned -ne $text) {
            $e.CancelCommand()
            if (-not [string]::IsNullOrEmpty($cleaned)) {
                $txtHost.SelectedText  = $cleaned
                $txtHost.CaretIndex    = $txtHost.SelectionStart + $cleaned.Length
                $txtHost.SelectionLength = 0
            }
        }
    } else { $e.CancelCommand() }
})

$window.Add_SizeChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Normal) {
        $script:windowWidth  = [int]$window.ActualWidth
        $script:windowHeight = [int]$window.ActualHeight
    }
})

$panelSplitter.Add_DragCompleted({
    try { $w = [int]$sidePanelCol.ActualWidth; if ($w -ge 160 -and $w -le 600) { $script:panelWidth = $w; Save-ConfigIni } } catch {}
})
$panelSplitter.Add_DragDelta({
    try { $w = [int]$sidePanelCol.ActualWidth; if ($w -ge 160 -and $w -le 600) { $script:panelWidth = $w } } catch {}
})

$btnTogglePw.Add_Click({
    if (-not $script:pwVisible) {
        $script:syncingPw              = $true
        $txtPasswordVisible.Text       = $txtPassword.Password
        $script:syncingPw              = $false
        $txtPassword.Visibility        = [System.Windows.Visibility]::Collapsed
        $txtPasswordVisible.Visibility = [System.Windows.Visibility]::Visible
        $btnTogglePw.Background        = B 0xC6 0xA0 0xF6
        $btnTogglePw.Foreground        = B 0x18 0x19 0x26
        $script:pwVisible              = $true
        $script:showPassword           = $true
        Save-ConfigIni
        $txtPasswordVisible.Focus(); $txtPasswordVisible.SelectAll()
    } else {
        $script:syncingPw              = $true
        $txtPassword.Password          = $txtPasswordVisible.Text
        $script:syncingPw              = $false
        $txtPassword.Visibility        = [System.Windows.Visibility]::Visible
        $txtPasswordVisible.Visibility = [System.Windows.Visibility]::Collapsed
        $btnTogglePw.Background        = B 0x1E 0x20 0x30
        $btnTogglePw.Foreground        = B 0xB8 0xC0 0xE0
        $script:pwVisible              = $false
        $script:showPassword           = $false
        Save-ConfigIni
        $txtPassword.Focus()
    }
})

$txtPassword.Add_PasswordChanged({
    if ($script:syncingPw) { return }
    $script:syncingPw = $true; $txtPasswordVisible.Text = $txtPassword.Password; $script:syncingPw = $false
})
$txtPasswordVisible.Add_TextChanged({
    if ($script:syncingPw) { return }
    $script:syncingPw = $true; $txtPassword.Password = $txtPasswordVisible.Text; $script:syncingPw = $false
})

$onEnter = {
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return -and $btnConnect.Visibility -eq [System.Windows.Visibility]::Visible) {
        Do-Connect; $e.Handled = $true
    }
}
$txtHost.Add_KeyDown($onEnter); $txtPort.Add_KeyDown($onEnter)
$txtPassword.Add_KeyDown($onEnter); $txtPasswordVisible.Add_KeyDown($onEnter)

$btnFsWindowed.Add_Click({ Exit-FullScreen; $vncCanvas.Focus() })
$btnFsClipboard.Add_Click({ Show-ClipboardDialog })
$btnFsDisconnect.Add_Click({
    if ($null -ne $script:activeSessionKey) { Disconnect-Session $script:activeSessionKey } else { Stop-VncSession }
    $vncCanvas.Focus()
})

$fsHoverZone.Add_MouseEnter({ if ($script:isFullScreen) { Show-FullscreenBar } })
$fullscreenBar.Add_MouseEnter({ if ($null -ne $script:fsBarTimer) { $script:fsBarTimer.Stop() } })
$fullscreenBar.Add_MouseLeave({
    if ($script:isFullScreen -and $script:fsBarVisible) {
        if ($null -ne $script:fsBarTimer) { $script:fsBarTimer.Stop() }
        $script:fsBarTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:fsBarTimer.Interval = [TimeSpan]::FromSeconds(1.5)
        $script:fsBarTimer.Add_Tick({ $script:fsBarTimer.Stop(); Hide-FullscreenBar })
        $script:fsBarTimer.Start()
    }
})

$window.Add_PreviewMouseMove({
    param($s, $e)
    if (-not $script:isFullScreen) { return }
    $pos = $e.GetPosition($window)
    if ($pos.Y -le 8 -and [Math]::Abs($pos.X - $window.ActualWidth / 2) -lt 200) { Show-FullscreenBar }
})

$window.Add_PreviewKeyDown({
    param($s, $e)
    if ($script:isFullScreen -and $e.Key -eq [System.Windows.Input.Key]::Escape) { Exit-FullScreen; $e.Handled = $true }
})

$vncCanvas.Add_MouseMove({
    param($s, $e)
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }
    $p = Get-ScaledPos $e; $script:vncEngine.SendPointer($script:buttonMask, $p.X, $p.Y)
})

$vncCanvas.Add_MouseDown({
    param($s, $e)
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }
    $s.Focus() | Out-Null
    switch ($e.ChangedButton) {
        ([System.Windows.Input.MouseButton]::Left)   { $script:buttonMask = $script:buttonMask -bor 1 }
        ([System.Windows.Input.MouseButton]::Middle) { $script:buttonMask = $script:buttonMask -bor 2 }
        ([System.Windows.Input.MouseButton]::Right)  { $script:buttonMask = $script:buttonMask -bor 4 }
    }
    $p = Get-ScaledPos $e; $script:vncEngine.SendPointer($script:buttonMask, $p.X, $p.Y)
    $s.CaptureMouse(); $e.Handled = $true
})

$vncCanvas.Add_MouseUp({
    param($s, $e)
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }
    switch ($e.ChangedButton) {
        ([System.Windows.Input.MouseButton]::Left)   { $script:buttonMask = $script:buttonMask -band (-bnot 1) }
        ([System.Windows.Input.MouseButton]::Middle) { $script:buttonMask = $script:buttonMask -band (-bnot 2) }
        ([System.Windows.Input.MouseButton]::Right)  { $script:buttonMask = $script:buttonMask -band (-bnot 4) }
    }
    $p = Get-ScaledPos $e; $script:vncEngine.SendPointer($script:buttonMask, $p.X, $p.Y)
    $s.ReleaseMouseCapture(); $e.Handled = $true
})

$vncCanvas.Add_MouseWheel({
    param($s, $e)
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }
    $p  = Get-ScaledPos $e
    $sb = if ($e.Delta -gt 0) { 8 } else { 16 }
    $script:vncEngine.SendPointer(($script:buttonMask -bor $sb), $p.X, $p.Y)
    $script:vncEngine.SendPointer($script:buttonMask, $p.X, $p.Y)
    $e.Handled = $true
})

$vncCanvas.Add_PreviewKeyDown({
    param($s, $e)
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }
    $key   = if ($e.Key -eq [System.Windows.Input.Key]::System) { $e.SystemKey } else { $e.Key }
    $shift = (([System.Windows.Input.Keyboard]::Modifiers) -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    $ks    = [KeysymMap]::GetKeysym($key, $shift)
    if ($ks -ne 0) { $script:vncEngine.SendKey($ks, $true); $e.Handled = $true }
})

$vncCanvas.Add_PreviewKeyUp({
    param($s, $e)
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }
    $key   = if ($e.Key -eq [System.Windows.Input.Key]::System) { $e.SystemKey } else { $e.Key }
    $shift = (([System.Windows.Input.Keyboard]::Modifiers) -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    $ks    = [KeysymMap]::GetKeysym($key, $shift)
    if ($ks -ne 0) { $script:vncEngine.SendKey($ks, $false); $e.Handled = $true }
})

$vncCanvas.Add_PreviewTextInput({
    param($s, $e)
    if ($null -eq $script:vncEngine -or -not $script:vncEngine.IsConnected) { return }
    foreach ($ch in $e.Text.ToCharArray()) {
        $sym = [uint32][char]$ch
        if ($sym -gt 0 -and $sym -lt 0x100) { $script:vncEngine.SendKey($sym, $true); $script:vncEngine.SendKey($sym, $false) }
    }
    $e.Handled = $true
})

$vncCanvas.Add_GotFocus({  $vncCanvas.Cursor = [System.Windows.Input.Cursors]::None })
$vncCanvas.Add_LostFocus({ $vncCanvas.Cursor = $null })

# ============================================================
# TIMERS
# ============================================================
$script:statsTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:statsTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:statsTimer.Add_Tick({
    Update-Stats
    if ($script:panelOpen) { Purge-DeadSessions }
})
$script:statsTimer.Start()

$script:clipTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:clipTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:clipTimer.Add_Tick({ Sync-Clipboard })
$script:clipTimer.Start()

$window.Add_Closing({
    foreach ($t in @($script:statsTimer, $script:clipTimer, $script:fsBarTimer, $script:connectPollTimer)) {
        if ($null -ne $t) { $t.Stop() }
    }
    if ($null -ne $script:connectAsyncHandle -and -not $script:connectAsyncHandle.IsCompleted) {
        $script:connectCancelled = $true
        if ($null -ne $script:pendingConnect) { try { $script:pendingConnect.Disconnect() } catch {} }
        try { if ($null -ne $script:connectBgPS) { $script:connectBgPS.EndInvoke($script:connectAsyncHandle) } } catch {}
    }
    if ($null -ne $script:connectBgPS)    { try { $script:connectBgPS.Dispose() }    catch {} }
    if ($null -ne $script:connectRunspace) { try { $script:connectRunspace.Close(); $script:connectRunspace.Dispose() } catch {} }
    try {
        $w = [int]$sidePanelCol.ActualWidth
        if ($w -ge 160 -and $w -le 600) { $script:panelWidth = $w }
        if ($window.WindowState -eq [System.Windows.WindowState]::Normal) {
            $script:windowWidth  = [int]$window.ActualWidth
            $script:windowHeight = [int]$window.ActualHeight
        }
    } catch {}
    Save-ConfigIni
    Stop-VncSession
})

$window.ShowDialog() | Out-Null
