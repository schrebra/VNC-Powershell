# PowerShell VNC Suite

A 100% pure PowerShell and C# implementation of a VNC Client (Viewer) and VNC Server. Utilizing WPF for the user interface and native Windows APIs for screen capture and input injection, this suite requires no third-party executables, DLLs, or installation packages.

<img width="60%" alt="image" src="https://github.com/user-attachments/assets/da07c390-7f2e-43b0-acdf-1aa834ed14c9" />


---

## What is it?

This project consists of two standalone PowerShell scripts:

* **VNC Viewer (`vnc-viewer.ps1`):** A fully interactive, WPF-based remote desktop client. It connects to any standard VNC server (including TightVNC, RealVNC, and our custom server) using the RFB 003.008 protocol.
* **VNC Server (`vnc-server.ps1`):** A system tray application that hosts a VNC server, allowing remote inbound connections to view and control the host machine's screen, keyboard, and mouse.

---

## Why it exists?

Traditional VNC software requires heavy installation packages, often leaving behind background services, registry keys, and deep driver hooks. This suite exists to provide a completely portable, zero-installation remote desktop solution. 

Because it is pure PowerShell, it can be:
* Run directly from a USB drive.
* Deployed instantly via RMM tools, SCCM, or Intune without packaging.
* Audited easily by security teams (the C# code is embedded directly in the script).
* Used in restricted environments where traditional `.exe` installations are blocked by AppLocker or WDAC policies.

---

## Who it's for?

* **System Administrators & Helpdesk:** Need quick, portable access to remote machines without installing agents.
* **Security Professionals:** Require a transparent, scriptable remote access tool where the source code is readily available for audit.
* **Developers:** Interested in how the RFB (Remote Frame Buffer) protocol, dirty-rectangle screen diffing, and asynchronous TCP networking work under the hood in .NET/C#.
* **Power Users:** Want a lightweight, bloat-free alternative to commercial remote desktop software.

---

## Features

### VNC Viewer Features
* **Non-Blocking Async UI:** Connects to unreachable hosts on a background runspace without freezing the interface. Features a hard 8-second timeout and a "Cancel" button.
* **Multi-Session Support:** Connect to multiple remote machines simultaneously and switch between them via an active session sidebar.
* **Fit-to-Window & Fullscreen:** Scale the remote display to fit the window or enter borderless fullscreen mode with an auto-hiding toolbar.
* **Session Management:** Saves connection history to JSON. Supports pinning, renaming, and per-session password saving.
* **Clipboard Transfer:** Emulates keystrokes to securely paste complex clipboard data into the remote session.
* **Live Statistics:** Real-time display of FPS, frame count, bandwidth usage, connection latency, and uptime.
* **Password Visibility Toggle:** Show or hide the password input field on the fly.

### VNC Server Features
* **System Tray Integration:** Runs silently in the background. No console window. Right-click the tray icon to Start/Stop the server, view connected clients, or exit.
* **Dynamic Tray Icon:** Visually indicates server status (Green circle = Running, Grey circle = Stopped).
* **RFB 003.008 Protocol:** Fully compliant with standard VNC clients. Supports VNC password authentication (DES challenge-response).
* **Dirty-Rectangle Tracking:** Captures only the parts of the screen that have changed, drastically reducing bandwidth and CPU usage.
* **Native Cursor Rendering:** Draws the local mouse cursor directly into the video frame, fixing the "invisible cursor" issue common with headless VMs (like VMware).
* **DPI-Aware Multi-Monitor Capture:** Correctly captures all monitors regardless of Windows display scaling settings.
* **Automatic Firewall Management:** Detects missing inbound firewall rules and attempts to create them automatically (falls back gracefully for non-admins).
* **Rotating Logs:** Configurable log levels (Error, Warn, Info) and automatic log rotation to prevent disk bloat over long uptimes.

---

## Usage

Ensure you are running PowerShell 5.1 or higher (PowerShell Core 7+ is also supported). 

To start the Server:
powershell.exe -ExecutionPolicy Bypass -File .\vnc-server.ps1 -Password "YourSecretPass"

To launch the Viewer:
powershell.exe -ExecutionPolicy Bypass -File .\vnc-viewer.ps1

---

## Limitations & Notes

> **Session 0 Isolation:** Like all standard VNC servers running as a background service, the server script cannot capture the interactive user desktop if run as a SYSTEM-level background service. For interactive desktop control, run the server script directly within the user's session.

> **Windows Only:** Because the scripts rely on System.Windows.Forms, System.Drawing, and Windows Win32 APIs (user32.dll, kernel32.dll), they are strictly compatible with Windows operating systems.
