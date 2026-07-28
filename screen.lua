-- Screen capture utility using macOS built-in screenshot tool

local function triggerScreenshot(modifiers, key)
    hs.eventtap.keyStroke(modifiers, key, 0)
end

hs.hotkey.bind({"cmd", "shift"}, "S", function()
    triggerScreenshot({"cmd", "shift"}, "5")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl"}, "A", function()
    triggerScreenshot({"cmd", "shift"}, "3")
end)

hs.hotkey.bind({"cmd", "alt", "ctrl"}, "W", function()
    triggerScreenshot({"cmd", "shift"}, "4")
    hs.timer.doAfter(0.1, function()
        triggerScreenshot({}, "space")
    end)
end)
