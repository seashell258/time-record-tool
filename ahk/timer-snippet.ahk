; =============================================================================
; Timer 記錄整合 — Alt+T 開始 / Alt+Y 停止
; 附加到 Seashell (2).ahk 末尾，AHK v2 語法。
; =============================================================================

TIMER_WEBAPP_URL := "YOUR_WEBAPP_URL"
TIMER_TOKEN      := "YOUR_TOKEN"

global TimerFloatGui         := ""
global TimerFloatTaskCtrl    := ""
global TimerFloatElapsedCtrl := ""
global TimerStartTick        := 0
global TimerCurrentTask      := ""

; --- Alt+T: 開啟輸入視窗 ---------------------------------------------------
!t::TimerShowInput()

TimerShowInput() {
    inputGui := Gui("+AlwaysOnTop +ToolWindow", "新任務")
    inputGui.SetFont("s11", "Segoe UI")
    inputGui.MarginX := 12
    inputGui.MarginY := 12
    edit := inputGui.AddEdit("w480 r5 vTaskText -WantReturn Multi WantTab")
    inputGui.OnEvent("Escape", (*) => inputGui.Destroy())

    submit(*) {
        task := edit.Value
        inputGui.Destroy()
        if (Trim(task) != "")
            TimerStart(task)
    }
    newline(*) {
        edit.Value := edit.Value . "`r`n"
        SendMessage(0xB1, -1, -1, edit.Hwnd)  ; caret to end
    }

    HotIfWinActive("ahk_id " inputGui.Hwnd)
    Hotkey("Enter", submit, "On")
    Hotkey("+Enter", newline, "On")
    HotIfWinActive()

    inputGui.OnEvent("Close", (*) => (
        HotIfWinActive("ahk_id " inputGui.Hwnd),
        Hotkey("Enter", "Off"),
        Hotkey("+Enter", "Off"),
        HotIfWinActive()
    ))

    inputGui.Show()
    edit.Focus()
}

TimerStart(task) {
    body := TimerJsonBody(Map("action", "start", "task", task, "token", TIMER_TOKEN))
    try {
        resp := TimerHttp(body)
    } catch as e {
        MsgBox("開始失敗：" . e.Message, "Timer", "IconX")
        return
    }
    if !InStr(resp, '"ok":true') {
        MsgBox("開始失敗（server）：" . resp, "Timer", "IconX")
        return
    }
    TimerShowFloat(task)
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
TimerHttp(body) {
    req := ComObject("WinHttp.WinHttpRequest.5.1")
    req.Option(6) := true   ; auto-follow redirects (Apps Script uses 302)
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

    TimerFloatGui := Gui("+AlwaysOnTop -Caption +ToolWindow +LastFound +E0x08000000", "TimerFloat")
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
    body := TimerJsonBody(Map("action", "stop", "token", TIMER_TOKEN))
    try {
        resp := TimerHttp(body)
    } catch as e {
        MsgBox("停止失敗：" . e.Message, "Timer", "IconX")
        return
    }
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
