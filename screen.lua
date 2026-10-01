-- screen.lua —— 截屏工具
--
-- 三个热键：
--   ⌘⇧S→ 打开系统「截图/录屏」面板（等价于按⌘⇧5）
--   ⌃⌥⌘A → 交互式截全屏（区域选择，等价于 ⌘⇧3 的交互模式）
--   ⌃⌥⌘W → 交互式截单个窗口
--
-- 实现说明：⌘⇧3 / ⌘⇧4 都是「进入交互模式」的快捷键，直接用
-- screencapture 的命令行开关更可靠——原来这个窗口热键是
-- 「模拟按 ⌘⇧4 → 延迟 0.1 秒 → 再模拟按空格」，0.1 秒是个猜测：
-- 系统面板没起来就按空格，什么都不发生；面板起得慢还会误吞掉用户
-- 紧接着按的按键。`-i -w` 一次到位，没有时序可赌。
--
-- 键名一律小写：hs.keycodes.map 的键都是小写（"a"…"z"），
-- 大写能不能被容错处理没必要赌。

local function bind(mods, key, fn)
    hs.hotkey.bind(mods, key, fn)
end

--- 跑一条 screencapture 命令。失败也不弹窗——截屏失败静默比弹窗好。
local function capture(args)
    hs.execute("/usr/sbin/screencapture " .. args .. " 2>/dev/null")
end

-- 截图/录屏面板：还是走系统快捷键，面板本身没有等价的命令行开关
bind({ "cmd", "shift" }, "s", function()
    hs.eventtap.keyStroke({ "cmd", "shift" }, "5", 0)
end)

-- 交互式选区域截屏
bind({ "ctrl", "alt", "cmd" }, "a", function()
    capture("-i")
end)

-- 交互式选单个窗口截屏（-w = 只截窗口，鼠标悬停即可选中）
bind({ "ctrl", "alt", "cmd" }, "w", function()
    capture("-i -w")
end)