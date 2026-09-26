--- osk.lua —— 屏幕键盘（蓝牙键盘断开时的应急输入设备）
---
--- 用途：蓝牙键盘不在手边时，用鼠标/触控板给前台 App 打字。
--- 开关：点击 kbswap 的菜单栏键盘图标（kbswap.lua 的 click 回调调本模块 toggle）。
--- 备用：axkeyboard.lua（系统「无障碍键盘」开关）保留在盘上但不加载——
---       功能正常，但每次都要开系统设置，Lin 不喜欢；本模块是首选方案。
---
--- 不抢焦点的原理（v3，根治版）：
---   v1/v2 的教训：hs.canvas 的窗口是普通 NSWindow，clickActivating(false)
---   （即 NSWindowStyleMaskNonactivatingPanel）对 borderless NSWindow 形同虚设，
---   点击画布仍会把 Hammerspoon 拉到前台；"检测到被抢 → 还焦点 → 延迟补发
---   按键"是打补丁，AppKit 的激活时序抢不回来（实测 2026-09-26 两轮失败）。
---   v3 换思路：OSK 显示期间挂一个 session 级 eventtap，凡落在键盘面板区域
---   内的鼠标事件一律截获丢弃（回调返回 true，事件不会送达窗口系统）。
---   AppKit 从头到尾"看不见"这次点击，自然无从触发激活 —— 焦点始终留在
---   前台 App，hs.eventtap.keyStroke 合成的按键直达输入目标。
---   画布退化为纯显示层（不开任何鼠标跟踪）。
---
---   仅剩的抢焦点点：canvas:show() 内部走 makeKeyAndOrderFront，打开瞬间会
---   激活 Hammerspoon —— show 后立即 + 延迟三次把焦点还给打开前的目标 App。
---   点击按键阶段不再有任何焦点操作。
---
--- 已知边界：
---   - Secure Input 激活的密码框（系统登录窗、密码管理器解锁）会拦合成事件。
---   - 直接读 HID 的程序（少数游戏、虚拟机客户机）收不到。
---   - 普通 App、浏览器、终端、中文输入法都正常。
---   - 修饰键 sticky：点一下上膛，作用于下一次普通按键后自动释放；不支持
---     「连按两次锁定」。caps lock 是纯内部状态，不向系统发 capslock 事件。
---
--- 测试：.workbuddy/skills/hammerspoon-config-test/example-osk-test.lua

local M = {}

--- 尺寸（基准值 × M.scale；触摸屏用调大 scale 即可整体放大）。
M.scale       = 1.4   -- 全局缩放系数（触摸屏点按需要更大的键）
M.keyH        = 34    -- 键高（pt）
M.unit        = 36    -- 1 个键位单位的宽（pt）
M.gap         = 3     -- 键间距
M.pad         = 6     -- 面板内边距
M.handleH     = 14    -- 顶部拖动把手条高（pt）
M.textSize    = 13
M.repeatDelay = 0.4   -- 按住多久后开始连发（秒）
M.repeatEvery = 0.09  -- 连发间隔（秒）
for _, k in ipairs({ "keyH", "unit", "gap", "pad", "handleH", "textSize" }) do
    M[k] = M[k] * M.scale
end

--- 修饰键 armed 状态（sticky）。shift/ctrl/alt/cmd 对下一次普通按键生效后清空。
M.armed = { shift = false, ctrl = false, alt = false, cmd = false }
M.caps  = false         -- 内部大小写状态（不发系统 capslock 事件）
M._keys = {}            -- 每个键的运行时信息 { def, rect, text, cx, cy, cw, ch, pressed }
M._drag = nil           -- 拖动中：{ mx, my, fx, fy }（鼠标起点 + 面板起点）
M._canvas = nil
M._frame = nil          -- 面板屏幕坐标 { x, y, w, h }（eventtap 命中判定用，NS 坐标）
M.debugLog = false      -- 临时诊断（/tmp/osk-debug.log），已核实坐标，默认关
M._repeat = nil         -- 按住连发的定时器
M._tap = nil            -- 事件拦截 tap
M._watchdog = nil       -- tap 看门狗（系统禁用后自动重启）
M._capturing = false    -- 正在按（mouseDown 起到 mouseUp 止，期间事件全吞）
M._pressing = nil       -- 当前按住的键记录
M._targetApp = nil      -- show 时记录的目标 App（还原 show 抢走的焦点用）

--- 布局（ANSI 104 键的可用子集，每行宽度恒为 15 单位）。
--- 每个键：t=显示文字 k=hs.keycodes 键名 s=shift 层文字 w=宽度(默认1)
---         mod=修饰键(sticky) rep=按住连发 special="caps"
local function key(t, k, s, w, extra)
    local def = { t = t, k = k, s = s, w = w or 1 }
    if extra then for kk, vv in pairs(extra) do def[kk] = vv end end
    return def
end

local LAYOUT = {
    { -- F 排：esc + F1~F12（Apple 布局；总宽 1.5 + 12×1.125 = 15 单位）
        key("esc", "escape", nil, 1.5),
        key("F1", "f1", nil, 1.125), key("F2", "f2", nil, 1.125),
        key("F3", "f3", nil, 1.125), key("F4", "f4", nil, 1.125),
        key("F5", "f5", nil, 1.125), key("F6", "f6", nil, 1.125),
        key("F7", "f7", nil, 1.125), key("F8", "f8", nil, 1.125),
        key("F9", "f9", nil, 1.125), key("F10", "f10", nil, 1.125),
        key("F11", "f11", nil, 1.125), key("F12", "f12", nil, 1.125),
    },
    {
        key("`", "`", "~"), key("1", "1", "!"), key("2", "2", "@"),
        key("3", "3", "#"), key("4", "4", "$"), key("5", "5", "%"),
        key("6", "6", "^"), key("7", "7", "&"), key("8", "8", "*"),
        key("9", "9", "("), key("0", "0", ")"), key("-", "-", "_"),
        key("=", "=", "+"), key("⌫", "delete", nil, 2, { rep = true }),
    },
    {
        key("⇥", "tab", nil, 1.5),
        key("q", "q"), key("w", "w"), key("e", "e"), key("r", "r"),
        key("t", "t"), key("y", "y"), key("u", "u"), key("i", "i"),
        key("o", "o"), key("p", "p"),
        key("[", "[", "{"), key("]", "]", "}"), key("\\", "\\", "|", 1.5),
    },
    {
        key("⇪", "capslock", nil, 1.75, { special = "caps" }),
        key("a", "a"), key("s", "s"), key("d", "d"), key("f", "f"),
        key("g", "g"), key("h", "h"), key("j", "j"), key("k", "k"),
        key("l", "l"), key(";", ";", ":"), key("'", "'", '"'),
        key("⏎", "return", nil, 2.25),
    },
    {
        key("⇧", "shift", nil, 2.25, { mod = "shift" }),
        key("z", "z"), key("x", "x"), key("c", "c"), key("v", "v"),
        key("b", "b"), key("n", "n"), key("m", "m"),
        key(",", ",", "<"), key(".", ".", ">"), key("/", "/", "?"),
        key("⇧", "shift", nil, 2.75, { mod = "shift" }),
    },
    { -- 底排：esc 移走后空格加宽（5.5）补齐 15 单位
        key("⌃", "ctrl", nil, 1, { mod = "ctrl" }),
        key("⌥", "alt", nil, 1, { mod = "alt" }),
        key("⌘", "cmd", nil, 1.25, { mod = "cmd" }),
        key("", "space", nil, 5.5),
        key("⌘", "cmd", nil, 1.25, { mod = "cmd" }),
        key("⌥", "alt", nil, 1, { mod = "alt" }),
        key("←", "left", nil, 1, { rep = true }),
        key("↑", "up", nil, 1, { rep = true }),
        key("↓", "down", nil, 1, { rep = true }),
        key("→", "right", nil, 1, { rep = true }),
    },
}

--- 面板总宽高（所有行同宽，取第一行算；顶部另有拖动把手条）。
local function panelSize()
    local units = 0
    for _, k in ipairs(LAYOUT[1]) do units = units + k.w end
    local w = units * M.unit + (#LAYOUT[1] - 1) * M.gap + M.pad * 2
    local h = M.handleH + M.gap
        + #LAYOUT * M.keyH + (#LAYOUT - 1) * M.gap + M.pad * 2
    return w, h
end

local function rgba(hex, a)
    local r = tonumber(hex:sub(1, 2), 16) / 255
    local g = tonumber(hex:sub(3, 4), 16) / 255
    local b = tonumber(hex:sub(5, 6), 16) / 255
    return { red = r, green = g, blue = b, alpha = a }
end

--- 深色半透明面板：浅色/深色系统主题下都可读，靠阴影/描边与背景区分。
local COLORS = {
    bg      = rgba("1B1B20", 0.88),
    key     = rgba("3C3C44", 0.96),
    modKey  = rgba("2E2E36", 0.96),
    text    = rgba("E8E8EC", 0.98),
    armed   = rgba("2E7CF6", 0.98),   -- 修饰键上膛 / caps 开
    pressed = rgba("585864", 0.98),   -- 按下瞬间
    handle  = rgba("9A9AA4", 0.65),   -- 拖动把手圆点
}

--------------------------------------------------------------------------------
-- 按键输出
--------------------------------------------------------------------------------

--- 这个键是不是字母（caps 只对字母有意义）。
local function isLetter(def)
    return def.k:find("^%a$") ~= nil
end

--- 发一个键。修饰键用 sticky 状态拼 mods 表，发完清空。
local function sendKey(def)
    local mods = {}
    local shift = M.armed.shift
    if isLetter(def) and M.caps then shift = not shift end
    if shift            then mods[#mods + 1] = "shift" end
    if M.armed.ctrl     then mods[#mods + 1] = "ctrl" end
    if M.armed.alt      then mods[#mods + 1] = "alt" end
    if M.armed.cmd      then mods[#mods + 1] = "cmd" end
    hs.eventtap.keyStroke(mods, def.k, 0)
    M.armed = { shift = false, ctrl = false, alt = false, cmd = false }
end

--- 键帽当前该显示什么：字母看 caps/shift，其它看 shift 层定义。
local function labelFor(def)
    if def.mod or def.special then return def.t end
    if isLetter(def) then
        return (M.armed.shift ~= M.caps) and def.t:upper() or def.t
    end
    return M.armed.shift and (def.s or def.t) or def.t
end

--- 把所有键帽的文字和底色刷到当前状态。
local function refreshKeycaps()
    local c = M._canvas
    if not c then return end
    for _, k in ipairs(M._keys) do
        local def = k.def
        c:elementAttribute(k.text, "text", labelFor(def))

        local fill = def.mod and COLORS.modKey or COLORS.key
        local on = (def.mod and M.armed[def.mod]) or
            (def.special == "caps" and M.caps)
        if on then fill = COLORS.armed end
        if k.pressed then fill = COLORS.pressed end
        c:elementAttribute(k.rect, "fillColor", fill)
    end
end

--------------------------------------------------------------------------------
-- 按住连发（⌫ 和方向键）
--------------------------------------------------------------------------------

local function stopRepeat()
    if M._repeat then
        if M._repeat.after then M._repeat.after:stop() end
        if M._repeat.every then M._repeat.every:stop() end
        M._repeat = nil
    end
end

local function startRepeat(def)
    stopRepeat()
    M._repeat = {
        after = hs.timer.doAfter(M.repeatDelay, function()
            if not M._repeat then return end
            M._repeat.every = hs.timer.doEvery(M.repeatEvery, function()
                sendKey(def)
            end)
        end),
    }
end

--------------------------------------------------------------------------------
-- 按键处理（由 eventtap 事件驱动，不再走 canvas 鼠标回调）
--------------------------------------------------------------------------------

--- 找到 id 对应的键记录。
local function keyById(id)
    for _, k in ipairs(M._keys) do
        if k.def.id == id then return k end
    end
end

--- 屏幕坐标 → 命中的键记录（面板局部坐标做几何命中）。
local function hitTest(gx, gy)
    if not M._frame then return nil end
    local lx = gx - M._frame.x
    local ly = gy - M._frame.y
    for _, k in ipairs(M._keys) do
        if lx >= k.cx and lx <= k.cx + k.cw and ly >= k.cy and ly <= k.cy + k.ch then
            return k
        end
    end
    return nil
end

local function inPanel(gx, gy)
    if not M._frame then return false end
    return gx >= M._frame.x and gx <= M._frame.x + M._frame.w
       and gy >= M._frame.y and gy <= M._frame.y + M._frame.h
end

local function pressKey(k)
    k.pressed = true
    M._pressing = k
    local def = k.def
    if def.mod then
        M.armed[def.mod] = not M.armed[def.mod]
    elseif def.special == "caps" then
        M.caps = not M.caps
    else
        sendKey(def)
        if def.rep then startRepeat(def) end
    end
    refreshKeycaps()
end

local function releaseKey()
    local k = M._pressing
    M._pressing = nil
    if not k then return end
    k.pressed = false
    if k.def.rep then stopRepeat() end
    refreshKeycaps()
end

--- eventtap 回调：返回 true = 吞掉事件（不会送达窗口系统）。
--- 任何 Lua 错误都会让系统禁用整个 tap，所以整体 pcall，错误落盘。
---
--- 坐标系（真机核实 2026-09-26）：ev:location() 与 hs.screen:frame() 同为
--- NS 全局坐标（主屏左下角原点，y 向上），直接比较即可，无需换算。
--- （推断成 CG 左上原点坐标系反而把点击镜像打空过一次，见 SKILL.md 勘误 3。）
local function onTap(ev)
    local ok, keep = pcall(function()
        if not M.isShowing() then return false end
        local types = hs.eventtap.event.types
        local t = ev:getType() -- 注意：方法名是 getType，不是 type

        if t == types.leftMouseDown then
            local loc = ev:location()
            -- 临时诊断：真机坐标系核实后可删
            if M.debugLog then
                local f = io.open("/tmp/osk-debug.log", "a")
                if f then
                    f:write(string.format("%s down raw=(%s,%s) frame=%s\n",
                        os.date("%T"), tostring(loc and loc.x), tostring(loc and loc.y),
                        M._frame and
                        string.format("%.0f,%.0f %.0fx%.0f", M._frame.x, M._frame.y, M._frame.w, M._frame.h) or "nil"))
                    f:close()
                end
            end
            if not loc then return false end
            if not inPanel(loc.x, loc.y) then return false end
            M._capturing = true
            local k = hitTest(loc.x, loc.y)
            if k then
                pressKey(k)
            else
                -- 落在把手/缝隙/内边距：进入拖动模式（按住拖到哪面板到哪）
                M._drag = { mx = loc.x, my = loc.y, fx = M._frame.x, fy = M._frame.y }
            end
            return true
        end

        if M._capturing then
            if t == types.leftMouseDragged then
                if M._drag and M._canvas then
                    local loc = ev:location()
                    if loc then
                        local nx = M._drag.fx + (loc.x - M._drag.mx)
                        local ny = M._drag.fy + (loc.y - M._drag.my)
                        M._canvas:topLeft({ x = nx, y = ny })
                        M._frame.x = nx
                        M._frame.y = ny
                    end
                end
                -- 按住键时拖动（无 _drag）：只吞事件，不打断连发
                return true
            end
            if t == types.leftMouseUp then
                M._capturing = false
                M._drag = nil
                releaseKey()
                return true
            end
        end

        -- 右键/中键落在面板内：吞掉，避免右键菜单/激活把 Hammerspoon 拉到前台
        if (t == types.rightMouseDown or t == types.rightMouseUp
            or t == types.rightMouseDragged or t == types.otherMouseDown
            or t == types.otherMouseUp or t == types.otherMouseDragged) then
            local loc = ev:location()
            if loc and inPanel(loc.x, loc.y) then return true end
        end

        return false
    end)
    if not ok then
        print("[osk] 事件回调出错: " .. tostring(keep))
        local f = io.open("/tmp/osk-err.log", "a")
        if f then
            f:write(os.date("%F %T ") .. tostring(keep) .. "\n")
            f:close()
        end
        return false
    end
    return keep
end

--------------------------------------------------------------------------------
-- 焦点还原（仅 show 那一瞬间需要；点击阶段焦点不会被碰）
--------------------------------------------------------------------------------

local function isHammerspoon(app)
    return app ~= nil and app:name() == "Hammerspoon"
end

--- show 内部 makeKeyAndOrderFront 会激活 Hammerspoon，且激活是异步的：
--- 立即 + 延迟三次检查，前台仍是 Hammerspoon 就把目标 App 拉回来。
local function restoreFocusOnce()
    if not M._targetApp then return end
    local ok, front = pcall(hs.window.frontmostApplication)
    if ok and isHammerspoon(front) then M._targetApp:activate() end
end

--------------------------------------------------------------------------------
-- 构建 / 开关
--------------------------------------------------------------------------------

--- 画布坐标 = 屏幕绝对坐标。每次 show 都重建：位置跟着当前屏幕走。
local function build(x, y)
    if M._canvas then M._canvas:delete() end
    M._canvas = nil
    M._keys = {}

    local w, h = panelSize()
    M._frame = { x = x, y = y, w = w, h = h }
    local c = hs.canvas.new({ x = x, y = y, w = w, h = h })
    M._canvas = c

    local elems = {}
    -- 注意：hs.canvas 元素的坐标必须包在 frame = {} 里；x/y/w/h 平铺在顶层
    -- 会被 isValueValidForAttribute 拒绝（控制台报 "not a valid canvas attribute"）。
    elems[#elems + 1] = {
        type = "rectangle",
        id = "bg",
        action = "fill",
        frame = { x = 0, y = 0, w = w, h = h },
        fillColor = COLORS.bg,
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
    }
    -- 顶部拖动把手：一排圆点提示可拖。落在把手/缝隙/内边距的按下都会拖动。
    elems[#elems + 1] = {
        type = "text",
        id = "handle",
        text = "· · · · ·",
        textSize = 12 * M.scale,
        textColor = COLORS.handle,
        textAlignment = "center",
        frame = { x = 0, y = M.pad, w = w, h = M.handleH },
    }

    local idx = 2 -- bg + handle 占 2
    for row, rowKeys in ipairs(LAYOUT) do
        local ux = M.pad
        local ky = M.pad + M.handleH + M.gap + (row - 1) * (M.keyH + M.gap)
        for ci, def in ipairs(rowKeys) do
            def.id = "k" .. row .. "_" .. ci
            local kw = def.w * M.unit + (def.w - 1) * M.gap
            idx = idx + 1
            elems[idx] = {
                type = "rectangle",
                id = def.id,
                action = "fill",
                frame = { x = ux, y = ky, w = kw, h = M.keyH },
                fillColor = def.mod and COLORS.modKey or COLORS.key,
                roundedRectRadii = { xRadius = 5, yRadius = 5 },
            }
            local rectIdx = idx
            idx = idx + 1
            elems[idx] = {
                type = "text",
                id = def.id .. "_t",
                text = labelFor(def),
                textSize = M.textSize,
                textColor = COLORS.text,
                textAlignment = "center",
                frame = { x = ux, y = ky + (M.keyH - M.textSize) / 2 - 1, w = kw, h = M.textSize + 4 },
            }
            M._keys[#M._keys + 1] = {
                def = def, rect = rectIdx, text = idx, pressed = false,
                cx = ux, cy = ky, cw = kw, ch = M.keyH,
            }
            ux = ux + kw + M.gap
        end
    end

    for i, e in ipairs(elems) do
        c[i] = e
    end

    -- 纯显示层：不开任何鼠标跟踪（点击由 eventtap 在上游拦截）。
    c:level(hs.canvas.windowLevels.floating)
    -- canJoinAllSpaces：所有空间（含全屏 App）上层都可见。不叠加 moveToActiveSpace ——
    -- 两者语义冲突，canJoinAllSpaces 已经覆盖了「出现在当前空间」。
    c:behaviorAsLabels({ "canJoinAllSpaces" })
end

function M.show()
    stopRepeat()
    M._capturing = false
    M._drag = nil
    M._pressing = nil

    -- 记下打开前的输入目标（点击 kbswap 菜单栏图标不会改变前台，
    -- 所以这里拿到的就是用户正在打字的 App）
    M._targetApp = nil
    local ok, front = pcall(hs.window.frontmostApplication)
    if ok and front and not isHammerspoon(front) then M._targetApp = front end

    local f = hs.screen.mainScreen():frame()
    local w, h = panelSize()
    local x = f.x + (f.w - w) / 2
    local y = f.y + f.h - h - 4
    build(x, y)
    M._canvas:show()

    for _, d in ipairs({ 0, 0.1, 0.3, 0.6 }) do
        hs.timer.doAfter(d, restoreFocusOnce)
    end

    -- 显示期间启用事件拦截
    if not M._tap then
        M._tap = hs.eventtap.new({
            hs.eventtap.event.types.leftMouseDown,
            hs.eventtap.event.types.leftMouseUp,
            hs.eventtap.event.types.leftMouseDragged,
            hs.eventtap.event.types.rightMouseDown,
            hs.eventtap.event.types.rightMouseUp,
            hs.eventtap.event.types.rightMouseDragged,
            hs.eventtap.event.types.otherMouseDown,
            hs.eventtap.event.types.otherMouseUp,
            hs.eventtap.event.types.otherMouseDragged,
        }, onTap)
    end
    M._tap:start()
    -- 临时诊断：确认 tap 真的启动了
    if M.debugLog then
        local f = io.open("/tmp/osk-debug.log", "a")
        if f then
            f:write(os.date("%T") .. " show: tap started, enabled=" .. tostring(M._tap:isEnabled()) .. "\n")
            f:close()
        end
    end
    -- 看门狗：回调若被系统禁用（异常/超时），5 秒内拉起
    if M._watchdog then M._watchdog:stop() end
    M._watchdog = hs.timer.doEvery(5, function()
        if M.isShowing() and M._tap and not M._tap:isEnabled() then
            M._tap:start()
        end
    end)
end

function M.hide()
    stopRepeat()
    M._capturing = false
    M._drag = nil
    M._pressing = nil
    if M._canvas then M._canvas:hide() end
    if M._tap then M._tap:stop() end
    if M._watchdog then M._watchdog:stop() end
    M._watchdog = nil
end

function M.isShowing()
    return M._canvas ~= nil and M._canvas:isShowing()
end

function M.toggle()
    if M.isShowing() then M.hide() else M.show() end
end

--- 键盘插回来时主动收起（供 kbswap 未来调用，暂不接线）。
function M.hideIfShowing()
    if M.isShowing() then M.hide() end
end

_G.hsOnScreenKeyboard = M
return M
