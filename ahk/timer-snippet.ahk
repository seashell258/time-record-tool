; =============================================================================
; Timer 記錄整合 — Alt+T 開始 / Alt+Y 停止
; 附加到 Seashell (2).ahk 末尾，AHK v2 語法。
; =============================================================================

global TIMER_WEBAPP_URL := "YOUR_WEBAPP_URL"
global TIMER_TOKEN      := "YOUR_TOKEN"

global TimerFloatGui         := ""
global TimerFloatTaskCtrl    := ""
global TimerFloatElapsedCtrl := ""
global TimerStartTick        := 0
global TimerCurrentTask      := ""

; --- Alt+T: 開啟輸入視窗 ---------------------------------------------------
!t::TimerShowInput()

TimerShowInput() {
    inputGui := Gui("+AlwaysOnTop +ToolWindow", "新任務 (Shift+Enter 送出、Enter 換行、Esc 取消)")
    inputGui.SetFont("s11", "Segoe UI")
    inputGui.MarginX := 12
    inputGui.MarginY := 12
    ; Multi = multi-line. WantTab lets Tab insert a tab character.
    ; Enter naturally inserts a newline (default multiline Edit behavior) —
    ; this is important for Chinese IME, whose Enter confirms candidates.
    edit := inputGui.AddEdit("w480 r5 vTaskText Multi WantTab")
    inputGui.OnEvent("Escape", (*) => inputGui.Destroy())

    submit(*) {
        task := edit.Value
        inputGui.Destroy()
        task := Trim(task)
        if (task = "") {
            MsgBox("任務內容是空的，沒有送出。", "Timer", "IconI")
            return
        }
        TimerStart(task)
    }

    HotIfWinActive("ahk_id " inputGui.Hwnd)
    Hotkey("+Enter", submit, "On")
    HotIfWinActive()

    inputGui.OnEvent("Close", (*) => (
        HotIfWinActive("ahk_id " inputGui.Hwnd),
        Hotkey("+Enter", "Off"),
        HotIfWinActive()
    ))

    inputGui.Show()
    edit.Focus()
}

TimerStart(task) {
    try {
        body := TimerJsonBody(Map("action", "start", "task", task, "token", TIMER_TOKEN))
        resp := TimerHttp(body)
        if !InStr(resp, '"ok":true') {
            MsgBox("開始失敗（server）：" . resp, "Timer", "IconX")
            return
        }
        TimerShowFloat(task)
    } catch as e {
        MsgBox("開始失敗：" . e.Message . "`n`n" . e.What . " at " . e.File . ":" . e.Line, "Timer", "IconX")
    }
}

; --- JSON body construction -------------------------------------------------
TimerJsonBody(map) {
    parts := ""
    for key, val in map {
        if (parts != "")
            parts .= ","
        parts .= '"' . key . '":' . TimerJsonString(val)
    }
    return "{" . parts . "}"
}

TimerJsonString(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r`n", "\n")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\n")
    s := StrReplace(s, "`t", "\t")
    return '"' . s . '"'
}

; --- HTTP POST to the Apps Script Web App -----------------------------------
; WinHttp default is to follow redirects (Option 6 defaults to TRUE), so we
; don't need to set it explicitly. Apps Script issues a 302 to script.googleusercontent.com.
TimerHttp(body) {
    req := ComObject("WinHttp.WinHttpRequest.5.1")
    req.Open("POST", TIMER_WEBAPP_URL, false)
    req.SetRequestHeader("Content-Type", "application/json")
    req.Send(body)
    if (req.Status < 200 || req.Status >= 300)
        throw Error("HTTP " . req.Status . ": " . req.ResponseText)
    return req.ResponseText
}

TimerShowFloat(task) {
    global TimerFloatGui, TimerFloatTaskCtrl, TimerFloatElapsedCtrl, TimerStartTick, TimerCurrentTask
    TimerHideFloat()

    TimerCurrentTask := task
    TimerStartTick := A_TickCount

    TimerFloatGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000", "TimerFloat")
    ; E0x08000000 = WS_EX_NOACTIVATE — click won't steal focus
    TimerFloatGui.BackColor := "1e1e1e"
    TimerFloatGui.SetFont("s10 cWhite", "Segoe UI")
    TimerFloatGui.MarginX := 10
    TimerFloatGui.MarginY := 8

    display := "● " . SubStr(task, 1, 20)
    if (StrLen(task) > 20)
        display .= "…"
    TimerFloatTaskCtrl := TimerFloatGui.AddText("w220", display)
    TimerFloatElapsedCtrl := TimerFloatGui.AddText("w220", "00:00:00")

    monWidth := A_ScreenWidth, monHeight := A_ScreenHeight
    TimerFloatGui.Show("x" (monWidth - 260) " y" (monHeight - 100) " NoActivate")

    SetTimer(TimerTick, 1000)
    TimerTick()
}

TimerHideFloat() {
    global TimerFloatGui
    SetTimer(TimerTick, 0)
    if (TimerFloatGui != "" && WinExist("ahk_id " TimerFloatGui.Hwnd)) {
        TimerFloatGui.Destroy()
    }
    TimerFloatGui := ""
}

TimerTick() {
    global TimerFloatElapsedCtrl, TimerStartTick
    if (TimerFloatElapsedCtrl = "")
        return
    elapsed := (A_TickCount - TimerStartTick) // 1000
    h := elapsed // 3600
    m := (elapsed // 60) - h * 60
    s := Mod(elapsed, 60)
    TimerFloatElapsedCtrl.Text := Format("{:02}:{:02}:{:02}", h, m, s)
}

; --- Alt+Y: 停止當前計時 ----------------------------------------------------
!y::TimerStop()

TimerStop() {
    global TimerCurrentTask
    try {
        body := TimerJsonBody(Map("action", "stop", "token", TIMER_TOKEN))
        resp := TimerHttp(body)
        if InStr(resp, '"error":"no_active"') {
            TimerFlashTip("沒有進行中的任務")
            return
        }
        if !InStr(resp, '"ok":true') {
            MsgBox("停止失敗（server）：" . resp, "Timer", "IconX")
            return
        }
        task := TimerExtractString(resp, "task")
        minutes := TimerExtractInt(resp, "duration_min")
        TimerHideFloat()
        TimerCurrentTask := ""
        TimerFlashTip("已停止：" . SubStr(task, 1, 30) . " (" . minutes . " 分鐘)")
    } catch as e {
        MsgBox("停止失敗：" . e.Message . "`n`n" . e.What . " at " . e.File . ":" . e.Line, "Timer", "IconX")
    }
}

TimerFlashTip(text) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -1000)
}

TimerExtractString(json, key) {
    if RegExMatch(json, '"' . key . '"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
        return TimerJsonUnescape(m[1])
    return ""
}

TimerExtractInt(json, key) {
    if RegExMatch(json, '"' . key . '"\s*:\s*(-?\d+)', &m)
        return m[1] + 0
    return 0
}

TimerJsonUnescape(s) {
    s := StrReplace(s, "\n", "`n")
    s := StrReplace(s, "\t", "`t")
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, "\\", "\")
    return s
}
