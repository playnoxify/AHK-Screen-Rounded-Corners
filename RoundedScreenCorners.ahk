#Requires AutoHotkey v2.0+
#SingleInstance Force
Persistent

; ====================================================================
; Rounded Screen Corners for Windows
; Uses the same region method as your brightness GUI
; ====================================================================

; ====================================================================
; Configuration
; ====================================================================
global cornerRadius := 25
global overlayGuis := []
global configFile := A_ScriptDir . "\RoundedScreen.ini"

; ====================================================================
; Initialize
; ====================================================================
LoadSettings()
CreateTrayMenu()
CreateOverlays()

; Monitor for display changes
OnMessage(0x007E, OnDisplayChange)  ; WM_DISPLAYCHANGE
OnMessage(0x02E0, OnDpiChanged)     ; WM_DPICHANGED

; Also check periodically for monitor changes
SetTimer(CheckMonitorChanges, 2000)

; ====================================================================
; Create System Tray Menu
; ====================================================================
CreateTrayMenu() {
    A_TrayMenu.Delete()
    
    ; Corner size submenu
    sizeMenu := Menu()
    sizeMenu.Add("10px", (*) => SetCornerSize(10))
    sizeMenu.Add("15px", (*) => SetCornerSize(15))
    sizeMenu.Add("25px", (*) => SetCornerSize(25))
    sizeMenu.Add("32px", (*) => SetCornerSize(32))
    sizeMenu.Add("40px", (*) => SetCornerSize(40))
    
    ; Check current size
    switch cornerRadius {
        case 10: sizeMenu.Check("10px")
        case 15: sizeMenu.Check("15px")
        case 25: sizeMenu.Check("25px")
        case 32: sizeMenu.Check("32px")
        case 40: sizeMenu.Check("40px")
    }
    
    A_TrayMenu.Add("Corner Size", sizeMenu)
    A_TrayMenu.Add()
    
    ; Auto-start option
    A_TrayMenu.Add("Start with Windows", (*) => ToggleAutoStart())
    if (CheckAutoStart())
        A_TrayMenu.Check("Start with Windows")
    
    A_TrayMenu.Add()
    A_TrayMenu.Add("Refresh", (*) => RefreshOverlays())
    A_TrayMenu.Add("Exit", (*) => ExitApp())
}

; ====================================================================
; Create Overlay Windows
; ====================================================================
CreateOverlays() {
    global overlayGuis
    
    ; Destroy existing overlays
    for guiObj in overlayGuis {
        try guiObj.Destroy()
    }
    overlayGuis := []
    
    ; Get monitor count
    monCount := MonitorGetCount()
    
    ; Create overlay for each monitor
    Loop monCount {
        MonitorGet(A_Index, &left, &top, &right, &bottom)
        width := right - left
        height := bottom - top
        
        ; Create 4 corner overlays for this monitor
        CreateCornerOverlay(left, top, "TL", width, height)
        CreateCornerOverlay(left, top, "TR", width, height)
        CreateCornerOverlay(left, top, "BL", width, height)
        CreateCornerOverlay(left, top, "BR", width, height)
    }
}

; ====================================================================
; Create Single Corner Overlay
; ====================================================================
CreateCornerOverlay(monX, monY, corner, monWidth, monHeight) {
    global overlayGuis, cornerRadius
    
    size := cornerRadius
    
    ; Calculate position
    switch corner {
        case "TL": 
            x := monX
            y := monY
        case "TR": 
            x := monX + monWidth - size
            y := monY
        case "BL": 
            x := monX
            y := monY + monHeight - size
        case "BR": 
            x := monX + monWidth - size
            y := monY + monHeight - size
    }
    
    ; Create GUI - must be layered for proper rendering above the cursor
    cornerGui := Gui("+AlwaysOnTop +ToolWindow -Caption +E0x80000")  ; WS_EX_LAYERED
    cornerGui.BackColor := "000000"
    
    ; Show GUI
    cornerGui.Show("x" x " y" y " w" size " h" size " NA")
    
    hwnd := cornerGui.Hwnd
    
    ; Apply rounded corner shape
    ApplyCornerShape(hwnd, size, corner)
    
    ; CRITICAL: Set the correct extended styles
    ; WS_EX_LAYERED (0x80000) - już ustawione przez +E0x80000
    ; WS_EX_TRANSPARENT (0x20) - allows clicks THROUGH the window
    exStyle := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -20, "Ptr")
    exStyle |= 0x80000 | 0x20  ; WS_EX_LAYERED | WS_EX_TRANSPARENT
    DllCall("SetWindowLong", "Ptr", hwnd, "Int", -20, "Ptr", exStyle)
    
    ; Set transparency (255 = opaque)
    DllCall("SetLayeredWindowAttributes", "Ptr", hwnd, "UInt", 0, "UChar", 255, "UInt", 2)
    
    ; KEY: OnMessage for WM_NCHITTEST must be before SetWindowLong
    ; Subclass the window to return HTTRANSPARENT
    DllCall("SetWindowSubclass", "Ptr", hwnd, "Ptr", CallbackCreate(SubclassProc), "Ptr", hwnd, "Ptr", 0)
    
    ; Setup aggressive timer for ALL corners
    SetTimer(() => ForceWindowOnTop(hwnd), 30)
    
    overlayGuis.Push(cornerGui)
}

; ====================================================================
; Subclass Procedure - przepuszcza kliknięcia, ale renderuje nad kursorem
; ====================================================================
SubclassProc(hwnd, uMsg, wParam, lParam, uIdSubclass, dwRefData) {
    static WM_NCHITTEST := 0x0084
    static HTTRANSPARENT := -1
    
    ; For WM_NCHITTEST, return HTTRANSPARENT
    if (uMsg = WM_NCHITTEST) {
        return HTTRANSPARENT
    }
    
    ; For other messages, call the default procedure
    return DllCall("DefSubclassProc", "Ptr", hwnd, "UInt", uMsg, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; ====================================================================
; Apply Corner Shape - inverse of a rounded rectangle
; ====================================================================
ApplyCornerShape(hwnd, size, corner) {
    ; Create a region that is a square MINUS a rounded corner
    ; This gives us a black corner with a rounded edge
    
    ; Full square
    hFullSquare := DllCall("CreateRectRgn", "Int", 0, "Int", 0, "Int", size, "Int", size, "Ptr")
    
    ; Rounded rectangle to subtract (depending on the corner)
    switch corner {
        case "TL":  ; Top-Left - subtract the bottom-right rounded area
            hRounded := DllCall("CreateRoundRectRgn"
                , "Int", 0, "Int", 0
                , "Int", size * 2 + 1, "Int", size * 2 + 1
                , "Int", size * 2, "Int", size * 2, "Ptr")
                
        case "TR":  ; Top-Right - subtract the bottom-left rounded area
            hRounded := DllCall("CreateRoundRectRgn"
                , "Int", -size, "Int", 0
                , "Int", size + 1, "Int", size * 2 + 1
                , "Int", size * 2, "Int", size * 2, "Ptr")
                
        case "BL":  ; Bottom-Left - subtract the top-right rounded area
            hRounded := DllCall("CreateRoundRectRgn"
                , "Int", 0, "Int", -size
                , "Int", size * 2 + 1, "Int", size + 1
                , "Int", size * 2, "Int", size * 2, "Ptr")
                
        case "BR":  ; Bottom-Right - subtract the top-left rounded area
            hRounded := DllCall("CreateRoundRectRgn"
                , "Int", -size, "Int", -size
                , "Int", size + 1, "Int", size + 1
                , "Int", size * 2, "Int", size * 2, "Ptr")
    }
    
    ; Create the resulting region
    hResult := DllCall("CreateRectRgn", "Int", 0, "Int", 0, "Int", 0, "Int", 0, "Ptr")
    
    ; Subtract the rounded region from the full square
    ; RGN_DIFF (4) = A minus B
    DllCall("CombineRgn", "Ptr", hResult, "Ptr", hFullSquare, "Ptr", hRounded, "Int", 4)
    
    ; Apply the region to the window
    DllCall("SetWindowRgn", "Ptr", hwnd, "Ptr", hResult, "Int", 1)
    
    ; Cleanup
    DllCall("DeleteObject", "Ptr", hFullSquare)
    DllCall("DeleteObject", "Ptr", hRounded)
    ; hResult nie usuwamy - system przejmuje własność po SetWindowRgn
}

; ====================================================================
; Set Corner Size
; ====================================================================
SetCornerSize(size) {
    global cornerRadius
    cornerRadius := size
    SaveSettings()
    RefreshOverlays()
    CreateTrayMenu()
}

; ====================================================================
; Refresh Overlays
; ====================================================================
RefreshOverlays(*) {
    global overlayGuis
    
    ; Stop all timers before destroying
    for guiObj in overlayGuis {
        try {
            ; Timers are associated with the hwnd, so it is enough to clear them
        }
    }
    
    CreateOverlays()
}

; ====================================================================
; Force Window to Stay On Top (for taskbar conflict)
; ====================================================================
ForceWindowOnTop(hwnd) {
    try {
        if !DllCall("IsWindow", "Ptr", hwnd)
            return
        
        ; Set window above taskbar
        DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1  ; HWND_TOPMOST
            , "Int", 0, "Int", 0, "Int", 0, "Int", 0
            , "UInt", 0x0013)  ; SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
    }
}

; ====================================================================
; Save/Load Settings
; ====================================================================
SaveSettings() {
    global cornerRadius, configFile
    IniWrite(cornerRadius, configFile, "Settings", "CornerRadius")
}

LoadSettings() {
    global cornerRadius, configFile
    try {
        cornerRadius := Integer(IniRead(configFile, "Settings", "CornerRadius", 25))
    } catch {
        cornerRadius := 25
    }
}

; ====================================================================
; Auto-start Functions
; ====================================================================
CheckAutoStart() {
    try {
        value := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "RoundedScreen")
        return (value = A_ScriptFullPath)
    }
    return false
}

ToggleAutoStart() {
    if (CheckAutoStart()) {
        try RegDelete("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "RoundedScreen")
    } else {
        try RegWrite(A_ScriptFullPath, "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "RoundedScreen")
    }
    CreateTrayMenu()
}

; ====================================================================
; Hotkeys
; ====================================================================
^!r::RefreshOverlays()  ; Ctrl+Alt+R to refresh

; ====================================================================
; Monitor Display Changes
; ====================================================================
global lastMonitorCount := MonitorGetCount()
global lastScreenWidth := A_ScreenWidth
global lastScreenHeight := A_ScreenHeight

OnDisplayChange(wParam, lParam, msg, hwnd) {
    ; Wait a bit for Windows to finish updating displays
    SetTimer(() => RefreshOverlays(), -500)
    return 0
}

OnDpiChanged(wParam, lParam, msg, hwnd) {
    ; DPI changed - refresh overlays
    SetTimer(() => RefreshOverlays(), -500)
    return 0
}

CheckMonitorChanges() {
    global lastMonitorCount, lastScreenWidth, lastScreenHeight
    
    currentCount := MonitorGetCount()
    currentWidth := A_ScreenWidth
    currentHeight := A_ScreenHeight
    
    ; Check if monitor configuration changed
    if (currentCount != lastMonitorCount 
        || currentWidth != lastScreenWidth 
        || currentHeight != lastScreenHeight) {
        
        lastMonitorCount := currentCount
        lastScreenWidth := currentWidth
        lastScreenHeight := currentHeight
        
        ; Refresh overlays after a short delay
        SetTimer(() => RefreshOverlays(), -300)
    }
}