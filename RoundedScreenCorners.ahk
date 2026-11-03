#Requires AutoHotkey v2.0+
#SingleInstance Force
Persistent
A_IconTip := "Display Rounded Corners"
; ====================================================================
; Rounded Screen Corners for Windows 0.5
; Soft Corners version - GDI+ per-pixel alpha
; New: Windows 11 style tray menu (Mica backdrop, rounded corners)
; ====================================================================

; ====================================================================
; Configuration
; ====================================================================
global cornerRadius := 25
global overlayGuis := []
global configFile := A_ScriptDir . "\RoundedScreen.ini"
global pToken := 0
global masterTimerStarted := false
global refreshBusy := false
global refreshPending := false

; MouseGetPos must report SCREEN coordinates. The default is coordinates
; relative to the active window, which put the tray popup in the top-left.
CoordMode("Mouse", "Screen")

; ====================================================================
; Tray popup menu - look and state
; ====================================================================
global mmScale := A_ScreenDPI / 96
global mmMica := VerCompare(A_OSVersion, "10.0.22621") >= 0   ; backdrop needs Windows 11 22H2+
global mmBackdrop := 2          ; 2 = Mica, 3 = Acrylic (closest to Explorer context menu), 4 = Mica Alt
global mmBg := mmMica ? "000000" : "2B2B2B"   ; pure black is see-through on the extended frame
global mmHover := "3A3A3A"
global mmTextColor := "FFFFFF"
global mmSepColor := "444444"
global mmIconFont := VerCompare(A_OSVersion, "10.0.22000") >= 0 ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"

global menuPopups := []
global menuHitMap := Map()
global menuRowSeq := 0
global menuOpenTick := 0
global menuClosedTick := 0
global menuEverActive := false

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
CreateTrayMenu()   ; native menu, kept as a fallback (Shift + right click)
CreateOverlays()

; Replace the native tray menu with the custom Mica popup
OnMessage(0x404, TrayNotify)

; Monitor for display changes
OnMessage(0x007E, OnDisplayChange)  ; WM_DISPLAYCHANGE
OnMessage(0x02E0, OnDpiChanged)     ; WM_DPICHANGED

; Also check periodically for monitor changes
SetTimer(CheckMonitorChanges, 2000)

; Watch for Windows 11 shell overlays (Start Menu, Action Center,
; Search, Widgets) which render above even topmost windows. We can't
; stay above them while they're open, but we CAN force our corners
; to snap back the instant they close, instead of waiting for a click.
global shellOverlayWasOpen := false
SetTimer(CheckShellOverlay, 100)

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
; Create System Tray Menu (native - fallback only)
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
; Tray icon click handler - opens the custom popup instead of the
; native menu. Returning 0 blocks the built-in menu.
; ====================================================================
TrayNotify(wParam, lParam, msg, hwnd) {
    global menuPopups, menuClosedTick
    
    ; 0x205 = WM_RBUTTONUP, 0x202 = WM_LBUTTONUP
    if (lParam != 0x205 && lParam != 0x202)
        return
    
    ; Shift + right click = native fallback menu (safety net)
    if (lParam = 0x205 && GetKeyState("Shift", "P"))
        return
    
    ; Clicking the icon while the popup is open deactivates it first,
    ; so treat a click right after closing as a "toggle off"
    if (menuPopups.Length || A_TickCount - menuClosedTick < 250) {
        CloseMenu()
        return 0
    }
    
    ShowTrayPopup()
    return 0
}

; ====================================================================
; Menu definition
; ====================================================================
BuildMenuItems() {
    global cornerRadius
    
    sizeItems := []
    for s in [10, 15, 25, 32, 40]
        sizeItems.Push(Map("text", s "px", "checked", (cornerRadius = s), "action", SetCornerSize.Bind(s)))
    
    return [
        Map("text", "Corner Size", "icon", Chr(0xE7F4), "children", sizeItems),
        Map("sep", true),
        Map("text", "Start with Windows", "checked", CheckAutoStart(), "action", ToggleAutoStart),
        Map("sep", true),
        Map("text", "Refresh", "icon", Chr(0xE72C), "action", RefreshOverlays),
        Map("text", "Exit", "icon", Chr(0xE7E8), "action", (*) => ExitApp())
    ]
}

; ====================================================================
; Show the main popup near the cursor
; ====================================================================
ShowTrayPopup() {
    global menuPopups, menuHitMap, menuOpenTick, menuEverActive, mmScale
    
    ; Make sure nothing is left over
    for P in menuPopups
        DestroyPopup(P)
    menuPopups := []
    menuHitMap := Map()
    
    CoordMode("Mouse", "Screen")
    mmScale := A_ScreenDPI / 96
    MouseGetPos(&mx, &my)
    P := CreatePopup(BuildMenuItems(), 0, Round(232 * mmScale))
    GetWorkAreaAt(mx, my, &wl, &wt, &wr, &wb)
    
    ; Open towards the cursor, flip when there is no room
    x := mx
    y := my
    if (x + P.w > wr)
        x := Min(mx, wr) - P.w
    if (y + P.h > wb)
        y := Min(my, wb) - P.h
    x := Max(x, wl)
    y := Max(y, wt)
    
    P.x := x
    P.y := y
    P.gui.Show("x" x " y" y " w" P.w " h" P.h)
    DllCall("SetForegroundWindow", "Ptr", P.gui.Hwnd)
    
    menuPopups.Push(P)
    menuOpenTick := A_TickCount
    menuEverActive := false
    SetTimer(MenuTick, 30)
}

; ====================================================================
; Build one popup window (main menu or submenu)
; ====================================================================
CreatePopup(items, level, w) {
    global mmScale, mmBg, mmTextColor, mmSepColor, mmIconFont, menuHitMap, menuRowSeq
    
    s := mmScale
    g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale")
    g.MarginX := 0
    g.MarginY := 0
    g.BackColor := mmBg
    ApplyMicaStyle(g.Hwnd)
    
    padX := Round(4 * s)
    padTop := Round(5 * s)
    rowW := w - 2 * padX
    itemH := Round(32 * s)
    iconW := Round(36 * s)
    arrowW := Round(28 * s)
    d := Round(8 * s)   ; diameter of the rounded hover highlight corners
    
    P := {gui: g, rows: [], level: level, w: w, h: 0, x: 0, y: 0, hlRow: 0, subRow: 0, alive: true, padTop: padTop}
    y := padTop
    
    for item in items {
        if (item.Has("sep")) {
            sepH := Round(9 * s)
            lineH := Max(1, Round(s))
            inset := Round(2 * s)
            g.Add("Text", "x" (padX + inset) " y" (y + (sepH - lineH) // 2) " w" (rowW - 2 * inset) " h" lineH " Background" mmSepColor)
            y += sepH
            continue
        }
        
        ; Icon column: check mark for toggled items, otherwise the item icon
        glyph := ""
        if (item.Has("checked") && item["checked"])
            glyph := Chr(0xE73E)
        else if (item.Has("icon"))
            glyph := item["icon"]
        
        hasSub := item.Has("children")
        labelW := rowW - iconW - (hasSub ? arrowW : 0)
        
        ; Three adjacent controls (icon | label | arrow) that all change
        ; colour together on hover, so no overlapping transparency is needed
        g.SetFont("s11 c" mmTextColor, mmIconFont)
        ic := g.Add("Text", "x" padX " y" y " w" iconW " h" itemH " Center +0x200 +0x100 Background" mmBg, glyph)
        g.SetFont("s10 c" mmTextColor, "Segoe UI")
        lb := g.Add("Text", "x" (padX + iconW) " y" y " w" labelW " h" itemH " +0x200 +0x100 Background" mmBg, item["text"])
        ctrls := [ic, lb]
        RoundCtrl(ic, iconW, itemH, d, "L")
        
        if (hasSub) {
            g.SetFont("s8 c" mmTextColor, mmIconFont)
            ar := g.Add("Text", "x" (padX + iconW + labelW) " y" y " w" arrowW " h" itemH " Center +0x200 +0x100 Background" mmBg, Chr(0xE76C))
            ctrls.Push(ar)
            RoundCtrl(ar, arrowW, itemH, d, "R")
        } else {
            RoundCtrl(lb, labelW, itemH, d, "R")
        }
        
        menuRowSeq += 1
        row := {id: menuRowSeq, popup: P, item: item, y: y, ctrls: ctrls}
        P.rows.Push(row)
        for c in ctrls {
            menuHitMap[c.Hwnd] := row
            c.OnEvent("Click", MenuRowClicked.Bind(row))
        }
        y += itemH
    }
    
    P.h := y + padTop
    return P
}

; ====================================================================
; Mica / dark mode / rounded corners for a popup window
; ====================================================================
ApplyMicaStyle(hwnd) {
    global mmMica, mmBackdrop
    
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 20, "Int*", 1, "UInt", 4)          ; dark mode
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 33, "Int*", 2, "UInt", 4)          ; rounded corners
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 34, "UInt*", 0x3A3A3A, "UInt", 4)  ; subtle border
    
    if (!mmMica)
        return
    
    ; Extend the frame over the whole window so the backdrop shows through,
    ; then pick the system backdrop type
    margins := Buffer(16, 0xFF)   ; four Int32 values of -1
    DllCall("dwmapi\DwmExtendFrameIntoClientArea", "Ptr", hwnd, "Ptr", margins)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 38, "Int*", mmBackdrop, "UInt", 4)
}

; ====================================================================
; Round only the outer edge of a row control (L = left, R = right)
; so the three adjacent controls of a row form one rounded highlight
; ====================================================================
RoundCtrl(ctrl, w, h, d, side) {
    if (side = "L")
        rgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w + d + 1, "Int", h + 1, "Int", d, "Int", d, "Ptr")
    else
        rgn := DllCall("CreateRoundRectRgn", "Int", -d, "Int", 0, "Int", w + 1, "Int", h + 1, "Int", d, "Int", d, "Ptr")
    DllCall("SetWindowRgn", "Ptr", ctrl.Hwnd, "Ptr", rgn, "Int", true)
}

; ====================================================================
; Work area of the monitor that contains a point
; ====================================================================
GetWorkAreaAt(px, py, &l, &t, &r, &b) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (px >= ml && px < mr && py >= mt && py < mb) {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            return
        }
    }
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
}

; ====================================================================
; Tick while the popup is open: close on focus loss, hover, submenus
; ====================================================================
MenuTick() {
    global menuPopups, menuHitMap, menuEverActive, menuOpenTick
    
    if (!menuPopups.Length) {
        SetTimer(MenuTick, 0)
        return
    }
    
    ; Close when none of our popups is active any more
    anyActive := false
    for P in menuPopups {
        if (WinActive("ahk_id " P.gui.Hwnd)) {
            anyActive := true
            break
        }
    }
    if (anyActive) {
        menuEverActive := true
    } else if (menuEverActive || A_TickCount - menuOpenTick > 600) {
        CloseMenu()
        return
    }
    
    ; Which row is under the cursor?
    MouseGetPos(,,, &ctrlHwnd, 2)
    hoverRow := menuHitMap.Has(ctrlHwnd) ? menuHitMap[ctrlHwnd] : 0
    
    for P in menuPopups.Clone() {
        if (!P.alive)
            continue
        
        if (hoverRow && hoverRow.popup == P) {
            curId := P.hlRow ? P.hlRow.id : 0
            if (curId != hoverRow.id) {
                SetHighlight(P, hoverRow)
                subId := P.subRow ? P.subRow.id : 0
                if (subId != hoverRow.id) {
                    CloseChildren(P)
                    if (hoverRow.item.Has("children"))
                        OpenSubmenu(P, hoverRow)
                }
            }
        } else if (!P.subRow && P.hlRow) {
            SetHighlight(P, 0)
        }
    }
}

SetHighlight(P, row) {
    if (P.hlRow)
        PaintRow(P.hlRow, false)
    P.hlRow := row
    if (row)
        PaintRow(row, true)
}

PaintRow(row, on) {
    global mmBg, mmHover
    color := on ? mmHover : mmBg
    for c in row.ctrls {
        c.Opt("Background" color)
        c.Redraw()
    }
}

; ====================================================================
; Submenus
; ====================================================================
OpenSubmenu(P, row) {
    global menuPopups, mmScale
    
    s := mmScale
    cw := Round(124 * s)
    overlap := Round(6 * s)
    C := CreatePopup(row.item["children"], P.level + 1, cw)
    
    x := P.x + P.w - overlap
    y := P.y + row.y - C.padTop
    GetWorkAreaAt(P.x + P.w, P.y + row.y, &wl, &wt, &wr, &wb)
    if (x + cw > wr)
        x := P.x - cw + overlap
    if (y + C.h > wb)
        y := wb - C.h
    if (y < wt)
        y := wt
    
    C.x := x
    C.y := y
    C.gui.Show("NA x" x " y" y " w" cw " h" C.h)
    menuPopups.Push(C)
    P.subRow := row
}

CloseChildren(P) {
    global menuPopups
    keep := []
    for Q in menuPopups {
        if (Q.level > P.level)
            DestroyPopup(Q)
        else
            keep.Push(Q)
    }
    menuPopups := keep
    P.subRow := 0
}

DestroyPopup(P) {
    global menuHitMap
    P.alive := false
    for row in P.rows {
        for c in row.ctrls {
            try menuHitMap.Delete(c.Hwnd)
        }
    }
    try P.gui.Destroy()
}

CloseMenu(*) {
    global menuPopups, menuHitMap, menuClosedTick
    SetTimer(MenuTick, 0)
    for P in menuPopups
        DestroyPopup(P)
    menuPopups := []
    menuHitMap := Map()
    menuClosedTick := A_TickCount
}

MenuRowClicked(row, *) {
    item := row.item
    if (item.Has("children") || !item.Has("action"))
        return
    action := item["action"]
    CloseMenu()
    action.Call()
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
    cornerGui := Gui("+AlwaysOnTop +ToolWindow -Caption +E0x80000", "RSC_CornerOverlay")  ; WS_EX_LAYERED, titled so strays can be found
    
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
    ; Debounce: a display change fires WM_DISPLAYCHANGE once PER WINDOW
    ; (every overlay gets it) and several timers also call this function.
    ; Re-arming the SAME timer collapses all of those into one rebuild.
    SetTimer(DoRefreshOverlays, -150)
}

DoRefreshOverlays() {
    global refreshBusy, refreshPending
    
    ; Never rebuild re-entrantly. An interrupted rebuild used to overwrite
    ; the window list and leave live overlay windows that nothing tracked,
    ; so even a manual Refresh could not remove them.
    if (refreshBusy) {
        refreshPending := true
        return
    }
    
    refreshBusy := true
    try {
        CreateOverlays()
        DestroyStrayOverlays()
    } finally {
        refreshBusy := false
    }
    
    if (refreshPending) {
        refreshPending := false
        SetTimer(DoRefreshOverlays, -150)
    }
}

; ====================================================================
; Safety net: close any overlay window that is not in the tracked list
; (found by its window title)
; ====================================================================
DestroyStrayOverlays() {
    global overlayGuis
    
    tracked := Map()
    for g in overlayGuis {
        try tracked[g.Hwnd] := true
    }
    
    for hwnd in WinGetList("RSC_CornerOverlay ahk_class AutoHotkeyGUI ahk_pid " ProcessExist()) {
        if (!tracked.Has(hwnd)) {
            try DllCall("DestroyWindow", "Ptr", hwnd)
        }
    }
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

#HotIf menuPopups.Length > 0
Esc::CloseMenu()        ; Esc closes the tray popup
#HotIf

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

; ====================================================================
; Detect Start Menu / Action Center / Search / Widgets closing
; These render in a shell layer above ALL topmost windows while
; open - nothing can be done about that. But the moment they close,
; we force-recreate our overlays instead of relying on the regular
; 30ms position timer, which can otherwise leave DWM's composition
; surface for our windows stale until something else triggers a redraw.
; ====================================================================
CheckShellOverlay() {
    global shellOverlayWasOpen
    
    isOpen := WinExist("ahk_class Windows.UI.Core.CoreWindow") ? true : false
    
    if (shellOverlayWasOpen && !isOpen) {
        ; Just closed - snap corners back immediately
        RefreshOverlays()
    }
    
    shellOverlayWasOpen := isOpen
}