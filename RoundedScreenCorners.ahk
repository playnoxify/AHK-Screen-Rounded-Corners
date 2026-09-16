#Requires AutoHotkey v2.0+
#SingleInstance Force
Persistent

; ====================================================================
; Rounded Screen Corners for Windows 0.3
; Soft Corners version - GDI+ per-pixel alpha
; Fixed: exit crash, optimized: single shared keep-on-top timer
; ====================================================================

; ====================================================================
; Configuration
; ====================================================================
global cornerRadius := 25
global overlayGuis := []
global configFile := A_ScriptDir . "\RoundedScreen.ini"
global pToken := 0
global masterTimerStarted := false

; ====================================================================
; Initialize GDI+
; ====================================================================
InitGDIPlus()
; Note: GdiplusShutdown deliberately NOT called on exit.
; Calling it during process teardown is unreliable (0xc0000005) -
; the OS reclaims all GDI+/GDI resources automatically when the
; process terminates, so an explicit shutdown call is not required.

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
; GDI+ Init
; ====================================================================
InitGDIPlus() {
    global pToken
    si := Buffer(24, 0)
    NumPut("UInt", 1, si)
    DllCall("gdiplus\GdiplusStartup", "UPtr*", &pToken, "UPtr", si.Ptr, "UPtr", 0)
}

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
    global overlayGuis, masterTimerStarted
    
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
    
    ; Start ONE shared timer for all corner windows (huge CPU saving
    ; vs. one timer per window). Only started once - subsequent
    ; refreshes just repopulate overlayGuis, which the loop reads live.
    if (!masterTimerStarted) {
        SetTimer(KeepAllOnTop, 30)
        masterTimerStarted := true
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
    
    ; Create layered GUI window
    cornerGui := Gui("+AlwaysOnTop +ToolWindow -Caption +E0x80000")  ; WS_EX_LAYERED
    
    ; Show GUI (position/size only - content drawn via UpdateLayeredWindow)
    cornerGui.Show("x" x " y" y " w" size " h" size " NA")
    
    hwnd := cornerGui.Hwnd
    
    ; Make window click-through (WS_EX_TRANSPARENT) - clicks pass through
    exStyle := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -20, "Ptr")
    exStyle |= 0x80000 | 0x20  ; WS_EX_LAYERED | WS_EX_TRANSPARENT
    DllCall("SetWindowLong", "Ptr", hwnd, "Int", -20, "Ptr", exStyle)
    
    ; Draw the soft-edged rounded corner with per-pixel alpha
    DrawCornerAlpha(hwnd, x, y, size, corner)
    
    overlayGuis.Push(cornerGui)
}

; ====================================================================
; Draw Rounded Corner with Soft (Anti-Aliased) Edge using GDI+
; ====================================================================
DrawCornerAlpha(hwnd, x, y, size, corner) {
    screenDC := 0
    hbm := 0
    memDC := 0
    hOldBmp := 0
    pGraphics := 0
    pPath := 0
    pBrush := 0
    
    try {
        ; Create 32bpp top-down DIB section for per-pixel alpha
        screenDC := DllCall("GetDC", "Ptr", 0, "Ptr")
        hbm := CreateAlphaBitmap(size, size)
        memDC := DllCall("CreateCompatibleDC", "Ptr", screenDC, "Ptr")
        hOldBmp := DllCall("SelectObject", "Ptr", memDC, "Ptr", hbm, "Ptr")
        
        ; Create GDI+ graphics on the memory DC
        DllCall("gdiplus\GdipCreateFromHDC", "Ptr", memDC, "UPtr*", &pGraphics)
        
        ; High quality anti-aliasing - key to the soft edge
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)
        DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", pGraphics, "Int", 2)
        DllCall("gdiplus\GdipSetCompositingQuality", "Ptr", pGraphics, "Int", 2)
        
        ; Clear to fully transparent
        DllCall("gdiplus\GdipGraphicsClear", "Ptr", pGraphics, "UInt", 0x00000000)
        
        ; Build path: full square MINUS circle (the "hole") -> Alternate fill mode
        DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &pPath)
        
        ; Outer square
        DllCall("gdiplus\GdipAddPathRectangle", "Ptr", pPath
            , "Float", 0, "Float", 0, "Float", size, "Float", size)
        
        ; Circle (hole) positioned according to corner
        switch corner {
            case "TL":
                ex := 0,     ey := 0
            case "TR":
                ex := -size, ey := 0
            case "BL":
                ex := 0,     ey := -size
            default: ; BR
                ex := -size, ey := -size
        }
        DllCall("gdiplus\GdipAddPathEllipse", "Ptr", pPath
            , "Float", ex, "Float", ey, "Float", size * 2, "Float", size * 2)
        
        ; Fill the path (square minus circle) with solid black
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFF000000, "UPtr*", &pBrush)
        DllCall("gdiplus\GdipFillPath", "Ptr", pGraphics, "Ptr", pBrush, "Ptr", pPath)
        
        ; Push the rendered bitmap to the layered window
        UpdateLayeredWindowAlpha(hwnd, memDC, x, y, size, size)
    } finally {
        ; Guaranteed cleanup even if something above throws -
        ; this is what prevents leaked GDI+ objects/handles over time
        if (pBrush)
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
        if (pPath)
            DllCall("gdiplus\GdipDeletePath", "Ptr", pPath)
        if (pGraphics)
            DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
        if (memDC) {
            if (hOldBmp)
                DllCall("SelectObject", "Ptr", memDC, "Ptr", hOldBmp)
            DllCall("DeleteDC", "Ptr", memDC)
        }
        if (hbm)
            DllCall("DeleteObject", "Ptr", hbm)
        if (screenDC)
            DllCall("ReleaseDC", "Ptr", 0, "Ptr", screenDC)
    }
}

; ====================================================================
; Helper: Create 32bpp Top-Down DIB Section (for alpha bitmap)
; ====================================================================
CreateAlphaBitmap(w, h) {
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)      ; biSize
    NumPut("Int", w, bi, 4)        ; biWidth
    NumPut("Int", -h, bi, 8)       ; biHeight (negative = top-down)
    NumPut("UShort", 1, bi, 12)    ; biPlanes
    NumPut("UShort", 32, bi, 14)   ; biBitCount
    NumPut("UInt", 0, bi, 16)      ; biCompression (BI_RGB)
    
    return DllCall("CreateDIBSection", "Ptr", 0, "Ptr", bi, "UInt", 0
        , "Ptr*", 0, "Ptr", 0, "UInt", 0, "Ptr")
}

; ====================================================================
; Helper: Update Layered Window with per-pixel alpha (soft edges)
; ====================================================================
UpdateLayeredWindowAlpha(hwnd, hdcSrc, x, y, w, h) {
    ptSrc := Buffer(8, 0)   ; POINT {0,0}
    ptDst := Buffer(8, 0)
    NumPut("Int", x, ptDst, 0)
    NumPut("Int", y, ptDst, 4)
    
    sz := Buffer(8, 0)
    NumPut("Int", w, sz, 0)
    NumPut("Int", h, sz, 4)
    
    blend := Buffer(4, 0)
    NumPut("UChar", 0,   blend, 0)  ; AC_SRC_OVER
    NumPut("UChar", 0,   blend, 1)  ; Flags
    NumPut("UChar", 255, blend, 2)  ; SourceConstantAlpha
    NumPut("UChar", 1,   blend, 3)  ; AC_SRC_ALPHA
    
    DllCall("UpdateLayeredWindow"
        , "Ptr", hwnd
        , "Ptr", 0
        , "Ptr", ptDst
        , "Ptr", sz
        , "Ptr", hdcSrc
        , "Ptr", ptSrc
        , "UInt", 0
        , "Ptr", blend
        , "UInt", 2)  ; ULW_ALPHA
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
    CreateOverlays()
}

; ====================================================================
; Keep ALL corner windows on top - single shared timer tick
; (replaces the old one-timer-per-window approach, which spawned
; up to 16 independent 15ms timers on a 4-monitor setup)
; ====================================================================
KeepAllOnTop() {
    global overlayGuis
    for guiObj in overlayGuis {
        try {
            hwnd := guiObj.Hwnd
            if !DllCall("IsWindow", "Ptr", hwnd)
                continue
            
            DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1  ; HWND_TOPMOST
                , "Int", 0, "Int", 0, "Int", 0, "Int", 0
                , "UInt", 0x0003 | 0x0010)  ; SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
        }
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
    SetTimer(() => RefreshOverlays(), -500)
    return 0
}

OnDpiChanged(wParam, lParam, msg, hwnd) {
    SetTimer(() => RefreshOverlays(), -500)
    return 0
}

CheckMonitorChanges() {
    global lastMonitorCount, lastScreenWidth, lastScreenHeight
    
    currentCount := MonitorGetCount()
    currentWidth := A_ScreenWidth
    currentHeight := A_ScreenHeight
    
    if (currentCount != lastMonitorCount 
        || currentWidth != lastScreenWidth 
        || currentHeight != lastScreenHeight) {
        
        lastMonitorCount := currentCount
        lastScreenWidth := currentWidth
        lastScreenHeight := currentHeight
        
        SetTimer(() => RefreshOverlays(), -300)
    }
}