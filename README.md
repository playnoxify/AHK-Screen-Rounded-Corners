Rounded Screen Corners for Windows

A lightweight AutoHotkey v2 utility that adds rounded corners to the edges of your Windows screen by placing small transparent overlay windows in each corner.

The tool is designed to provide a clean, modern rounded-corner appearance while remaining lightweight and unobtrusive.

Features
🖥️ Rounded corners on all connected monitors
🔄 Automatically detects display configuration changes
🎯 Supports multiple monitors
⚙️ Adjustable corner radius
🪟 Overlay windows stay above the taskbar and other windows
🖱️ Click-through overlays — they do not interfere with mouse input
🚀 Optional Start with Windows functionality
💾 Saves the selected corner size between launches
🔃 Refresh overlays manually from the tray menu or with Ctrl + Alt + R
📌 Runs quietly in the Windows system tray
Corner Sizes

The tray menu provides several predefined corner sizes:

10px
15px
25px
32px
40px

The currently selected size is automatically marked in the tray menu.

System Tray Menu

The application runs in the Windows system tray and provides quick access to:

Corner Size — select the desired corner radius
Start with Windows — enable or disable automatic startup
Refresh — recreate the corner overlays
Exit — close the application
How It Works

The application creates four small overlay windows for each connected monitor — one for each corner.

Windows GDI region functions are used to create the corner shape. The overlays are configured as layered, always-on-top, transparent windows and are made click-through so they do not interfere with normal interaction with applications.

The application also periodically checks for changes in the monitor configuration and recreates the overlays when necessary.

Requirements
Windows 10 or later
AutoHotkey v2

The script requires AutoHotkey v2:

#Requires AutoHotkey v2.0+
Installation
Run the script
Install AutoHotkey v2.
Download the .ahk script.
Run the script.
The application will appear in the Windows system tray.
Start automatically with Windows

Right-click the tray icon and enable:

Start with Windows

The application will then register itself in the current user's Windows startup configuration.

Usage

After launching the script, the rounded corners are applied automatically.

Use the tray icon to change the corner size or refresh the overlays.

You can also press:

Ctrl + Alt + R

to refresh all overlays manually.

Configuration

The selected corner radius is stored in:

RoundedScreen.ini

The configuration file is created in the same directory as the script.

Multi-Monitor Support

Each connected monitor receives its own set of four corner overlays.

The application monitors display changes such as:

Connecting or disconnecting a monitor
Changing display resolution
Changes affecting the Windows display configuration
DPI changes

The overlays are automatically refreshed when such changes are detected.
