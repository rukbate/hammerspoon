--- window.lua —— 窗口布局热键集
---
--- 全部快捷键都是⌃⌥⌘ +某键（和 kbswap 的 ⌃⌥⌘K、scroll 的 ⌃⌥⌘R 不冲突）。
--- 原始版本（2019）每个热键都重复一遍取窗口/取屏幕/改frame 的代码，而且
--- 直接 win:frame() 不判空——焦点落在 Finder 桌面或没有窗口时 hs.window
--- .focusedWindow() 返回 nil，会抛 "attempt to index a nil value"，
--- 弹出的 Hammerspoon 控制台还会顺手把 Hammerspoon 抢成前台。
--- 现在统一走 withWindow()：判空、判frame 有效性、出错静默兜底。
---
--- 全部用小写键名：hs.keycodes.map 的键都是小写（"a"…"z"/"left"），传大写
--- 虽然多数能被容错处理，但没必要赌。

local M = {}

--------------------------------------------------------------------------------
-- 内部工具
--------------------------------------------------------------------------------

--- 拿到一个可操作的窗口，取不到就返回 nil（不弹错、不抢焦点）。
--- @return hs.window|nil
local function withWindow(fn)
    local win = hs.window.focusedWindow()
    if not win then return nil end

    local frame = win:frame()
    if not frame then return nil end
    local screen = win:screen()
    if not screen then return nil end
    local max = screen:frame()
    if not max then return nil end

    fn(win, frame, max)
end

--- 把 frame 按比例摆放：margin 是相对屏幕宽/高的留白比例。
--- xFrac/yFrac 是目标位置的比例锚点（0.5 = 居中）。
local function place(frame, max, xFrac, yFrac, wFrac, hFrac)
    frame.x = max.x + (max.w - max.w * wFrac) * xFrac
    frame.y = max.y + (max.h - max.h * hFrac) * yFrac
    frame.w = max.w * wFrac
    frame.h = max.h * hFrac
end

--- 把 frame 放到屏幕的某个分区（0/0.5/1 = 左/中/右、上/中/下）。
local function placeAt(frame, max, gx, gy)
    frame.x = max.x + (max.w - frame.w) * gx
    frame.y = max.y + (max.h - frame.h) * gy
end

--- 铺满整屏。菜单栏/Dock 会盖住窗口一角（用的是 screen:frame()，
--- 不是 usableFrame()）——想要避开菜单栏的话换成 hs.screen:usableFrame()。
local function fill(frame, max)
    frame.x, frame.y = max.x, max.y
    frame.w, frame.h = max.w, max.h
end

--------------------------------------------------------------------------------
-- 热键绑定
--------------------------------------------------------------------------------

--- ⌃⌥⌘F：铺满当前屏幕
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "f", function()
    withWindow(function(win, frame, max) fill(frame, max) win:setFrame(frame) end)
end)

--- ⌃⌥⌘M：居中，左右各留 12%
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "m", function()
    withWindow(function(win, frame, max)
        place(frame, max, 0.5, 0, 0.76, 1)
        win:setFrame(frame)
    end)
end)

--- ⌃⌥⌘N：居中，四边各留 20%
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "n", function()
    withWindow(function(win, frame, max)
        place(frame, max, 0.5, 0.5, 0.6, 0.6)
        win:setFrame(frame)
    end)
end)

--- ⌃⌥⌘←/→/↑/↓：窗口靠到对应半屏
local function half(gx, gy)
    return function()
        withWindow(function(win, frame, max)
            placeAt(frame, max, gx, gy)
            win:setFrame(frame)
        end)
    end
end
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "left",  half(0,   0))
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "right", half(1,   0))
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "up",    half(0.5, 0))
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "down",  half(0.5, 1))

--- ⌃⌥⌘[ / ⌃⌥⌘]：窗口移到上/下一块屏幕
--- 注意 moveToScreen 只保证「挪过去」，不保证窗口完整落在新屏幕内；跨不同
--- 分辨率的屏幕时窗口可能有一部分跑出可视区。沿用原脚本的调用方式。
local function moveScreen(step)
    return function()
        withWindow(function(win)
            local screens = hs.screen.allScreens()
            if #screens < 2 then return end

            local current = win:screen()
            if not current then return end

            local idx = 1
            for i, s in ipairs(screens) do
                if s:id() == current:id() then idx = i break end
            end
            local nextIdx = ((idx - 1 + step) % #screens) + 1
            win:moveToScreen(screens[nextIdx])
        end)
    end
end
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "]", moveScreen(1))
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "[", moveScreen(-1))