hs.hotkey.bind({"cmd", "alt", "ctrl"}, "W", function()
    hs.notify.new({title="Hammerspoon", informativeText="Hello world"}):send()
 end)
 
 hs.hotkey.bind({"cmd", "alt", "ctrl"}, "H", function()
    local win = hs.window.focusedWindow()
    local f = win:frame()
 
    f.x = f.x - 10
    win:setFrame(f)
 end)

 hs.hotkey.bind({"cmd", "alt", "ctrl"}, "Left", function()
    local win = hs.window.focusedWindow()
    local f = win:frame()
    local screen = win:screen()
    local max = screen:frame()

    f.x = max.x
    f.y = max.y
    f.w = max.w / 2
    f.h = max.h
    win:setFrame(f)
 end)