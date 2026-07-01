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

; --- Floating window: stub for now, replaced in Task 7 ---------------------
TimerShowFloat(task) {
    ToolTip("Started: " . SubStr(task, 1, 40))
    SetTimer(() => ToolTip(), -2000)
}
