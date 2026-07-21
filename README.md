# Interactive VNC Client GUI

A standalone, lightweight, high-performance VNC client written entirely in **PowerShell 5.1**, **WPF/XAML**, and **inlined C#**. Designed with the dark **Catppuccin Macchiato** aesthetic, it delivers low-latency remote desktop streaming without relying on external third-party dependencies or heavy installation packages.

<img width="60%" alt="2026-07-21_151836" src="https://github.com/user-attachments/assets/0cbdea9a-e819-4613-a904-ba668939de3a" />

---

## What It Is

This tool is a self-contained PowerShell script that builds an interactive Graphical User Interface (GUI) over the **RFB 003.008 (Remote Framebuffer)** protocol. By combining PowerShell with directly compiled C# code (`Add-Type`), it bypasses the typical performance limitations of script-based viewers to provide high-frame-rate desktop rendering and responsive input handling.

---

## Why It Exists

Standard remote management software often requires administrative privileges, heavy installer runtimes, or paid subscriptions. Many lightweight VNC tools lack modern visual interfaces, persistent multi-session tabs, or high-DPI scaling support. 

This project was created to provide a **portable, zero-dependency, single-script remote desktop client** for Windows environments. It bridges the gap between scriptability and native software performance—allowing IT administrators, security researchers, and power users to quickly initiate remote sessions on internal networks without installation overhead.

---

## Key Features

### High-Performance Rendering & Input Engine
* **60 FPS Capability:** Dynamic refresh logic targeting sub-16ms update intervals.
* **Asynchronous Network I/O:** Threaded socket reads and writes prevent UI freezes during network spikes.
* **Pointer Coalescing:** Eliminates cursor lag by collapsing mouse movement events prior to transmission over the wire.
* **Zero-Latency Native Cursor:** Native OS cursor support avoids remote cursor rendering delays.
* **Integrated C# Decoders:** Fast memory manipulation and direct buffer writes to WPF `WriteableBitmap` objects.

### Modern UI & Session Management
* **Catppuccin Macchiato Theme:** Clean dark-mode design with cohesive, high-contrast visual cues.
* **Multi-Session Management:** Simultaneous tracking of active, pinned, and recent remote hosts via a resizable side panel.
* **State Persistence:** Automatically saves window geometry, side-panel width, host history, password visibility settings, and session details to local INI/JSON configurations.
* **Fast Pre-Flight Pings:** Quickly checks host reachability via ICMP before attempting socket handshakes.
* **Flexible View Modes:** Supports 1:1 pixel rendering, proportional window fitting, and an immersive Full Screen overlay mode.

### Workflow Utilities
* **Bi-Directional Clipboard Synchronization:** Background clipboard monitoring alongside a manual keystroke-injection clipboard tool for tricky remote shells.
* **Input Validation & Safety:** Enforces IP/hostname structure to prevent standard execution errors.
* **Dynamic Password Masking:** In-line toggle for visible plain-text password verification or standard password masking.

---

## Target Audience

* **System Administrators & Engineers:** Who need a quick, safe, portable tool to connect to servers, headless machines, or embedded devices without installing new software.
* **Security Professionals & Labs:** Operating in constrained or isolated Windows environments where third-party installers are restricted.
* **Power Users:** Who want a clean, dark-themed VNC manager capable of handling multiple saved targets smoothly.

---


