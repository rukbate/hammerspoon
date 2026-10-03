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

--- 诊断日志：/tmp/hs-window.log
---
--- **必须记「每次热键实际作用到了哪个窗口」**，因为这类故障在屏幕上完全看不出来
--- （Lin 2026-10-03 报「⌃⌥⌘ 方向键四个都不行了」，看起来像热键没绑定，
--- 实际可能是 setFrame 作用到了别的窗口上）。日志要能区分三种情况：
---   ① 压根没拿到窗口（nil）
---   ② 拿到的是 Hammerspoon 自己的窗口（键盘画布）→ 按了等于按在键盘上
---   ③ 拿到了真窗口但 setFrame 失败
--- 不记的话就只能靠猜，而「猜」正是这个项目反复栽跟头的地方。
local LOG = "/tmp/hs-window.log"
local function diag(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = fmt end
    local f = io.open(LOG, "a")
    if f then
        f:write(os.date("%F %T ") .. tostring(msg) .. "\n")
        f:close()
    end
end

--- 这个窗口是不是 Hammerspoon 自己的（osk 键盘画布、控制台）。
---
--- **必须排除，否则热键会作用到键盘面板上。** 2026-10-03 真机 bug：
--- osk 的 `show()` 会 `M._canvas:show()`，这一步**激活 Hammerspoon**
--- （NSWindow 的 makeKeyAndOrderFront，激活是异步的），之后靠
--- `restoreFocusOnce` 在 0/0.1/0.3/0.6s 四个点把前台 App 抢回来。
--- 只要那几次里有一次没成功（Hammerspoon 自己又被激活、或目标 App
--- activate 失败），`hs.window.focusedWindow()` 返回的就是**键盘画布**——
--- 于是 ⌃⌥⌘← 的 setFrame 全作用在键盘面板上，用户看到的就是
--- 「热键彻底没反应」。四个方向一起失效正是这个症状。
---
--- 用 pcall 包住：测试桩件里的假窗口没有 application() 方法。
--- @return boolean
local function isOwnWindow(win)
    local ok, app = pcall(function() return win:application() end)
    if not ok or not app then return false end
    local ok2, name = pcall(function() return app:name() end)
    if not ok2 or not name then return false end
    return name == "Hammerspoon"
end

--- 最近一次「真正的」目标窗口。focusedWindow() 被 Hammerspoon 自己占住时的兜底。
--- @type hs.window|nil
local lastRealWindow = nil

--- 窗口是否还活着（关掉的窗口调 frame() 可能抛，不是返回 nil）。
local function alive(win)
    if not win then return false end
    local ok, frame = pcall(function() return win:frame() end)
    return ok and frame ~= nil
end

--- 拿到一个可操作的窗口，取不到就返回 nil（不弹错、不抢焦点）。
--- @return hs.window|nil
local function withWindow(fn, key)
    local focused = hs.window.focusedWindow()
    local win = focused

    if win and isOwnWindow(win) then
        diag("[%s] 焦点窗口是 Hammerspoon 自己（多半是 osk 键盘画布）→ 改用最近的真窗口",
            tostring(key))
        win = (alive(lastRealWindow) and lastRealWindow) or nil
    end

    -- 兜底窗口可能是上一次留下的、现在已经关掉的
    if win and not alive(win) then
        diag("[%s] 兜底窗口已失效，清掉", tostring(key))
        lastRealWindow = nil
        win = nil
    end

    if not win then
        diag("[%s] 拿不到可操作窗口（focused=%s）",
            tostring(key), focused and "Hammerspoon" or "nil")
        return nil
    end

    local frame = win:frame()
    if not frame then return nil end
    local screen = win:screen()
    if not screen then return nil end
    local max = screen:frame()
    if not max then return nil end

    diag("[%s] 作用到窗口 (%.0f,%.0f %.0fx%.0f)",
        tostring(key), frame.x, frame.y, frame.w, frame.h)

    lastRealWindow = win
    local ok, err = pcall(fn, win, frame, max)
    if not ok then
        diag("[%s] setFrame 抛错：%s", tostring(key), tostring(err))
    end
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

--- 绑一个热键，并把**键名传进 withWindow** ——诊断日志要能指出是哪个键，
--- 否则四个方向键同时失效时，日志里分不出是谁触发的。
local function bind(key, fn)
    hs.hotkey.bind({ "ctrl", "alt", "cmd" }, key, function()
        fn(key)
    end)
end

--- ⌃⌥⌘F：铺满当前屏幕
bind("f", function(key)
    withWindow(function(win, frame, max) fill(frame, max) win:setFrame(frame) end, key)
end)

--- ⌃⌥⌘M：居中，左右各留 12%
bind("m", function(key)
    withWindow(function(win, frame, max)
        place(frame, max, 0.5, 0, 0.76, 1)
        win:setFrame(frame)
    end, key)
end)

--- ⌃⌥⌘N：居中，四边各留 20%
bind("n", function(key)
    withWindow(function(win, frame, max)
        place(frame, max, 0.5, 0.5, 0.6, 0.6)
        win:setFrame(frame)
    end, key)
end)

--- ⌃⌥⌘←/→/↑/↓：窗口靠到对应半屏
--- 只挪位置，**不改窗口大小** —— 想改大小用 ⌃⌥⌘F/N 或系统绿按钮。
local function half(gx, gy)
    return function(key)
        withWindow(function(win, frame, max)
            placeAt(frame, max, gx, gy)
            win:setFrame(frame)
        end, key)
    end
end
bind("left",  half(0,   0))
bind("right", half(1,   0))
bind("up",    half(0.5, 0))
bind("down",  half(0.5, 1))

--- ⌃⌥⌘[ / ⌃⌥⌘]：窗口移到上/下一块屏幕
--- 注意 moveToScreen 只保证「挪过去」，不保证窗口完整落在新屏幕内；跨不同
--- 分辨率的屏幕时窗口可能有一部分跑出可视区。沿用原脚本的调用方式。
local function moveScreen(step)
    return function(key)
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
        end, key)
    end
end
bind("]", moveScreen(1))
bind("[", moveScreen(-1))