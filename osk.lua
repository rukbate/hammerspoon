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
--- 位置：默认贴屏幕底边居中；`M.avoidInput = true` 时先定位当前输入区
---   （AX），把面板顶边贴到它的**下缘之下**——只是往上挪开输入框焦点，
---   **不翻到屏幕顶部**（那样会挡住上方对话）。下方空间不够时才顶到屏幕上沿。
---   AX 拿不到就静默退回贴底，不影响显示。
---   每次 show 的探测过程都写 /tmp/osk-ax.log——「为什么没躲开」在屏幕上完全
---   看不出来（不报错也没提示），排查只能看它。
---   两个真机教训（2026-10-02，都是先诊断错、后修对）：
---   ① WorkBuddy（Electron/Chromium）里 **AXFocusedUIElement 恒为 nil**，
---      三条焦点链路全军覆没 → 改用「取焦点窗口 → 按 role 找文本元素」。
---   ② 输入区可能**大到无处可躲**（Word/Pages 正文占满窗口高度）：拿整页矩形
---      去比对重叠只会得到「顶部重叠略小」这种假信号，把键盘抬到顶部照样
---      盖着文档。所以**只在拿不到精确光标时**才认输保持贴底，不凭模糊信息乱动。
---   位置只在 show 时算一次；之后手动拖动的位置一直有效，直到下次收起再打开。
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
M.level       = "assistiveTechHigh" -- 窗口层级：系统辅助面板那一档，盖住任何 App 窗口
                        -- 想低调点可改 "overlay" / "floating"（后者会被部分 App 盖住）
M.avoidInput  = true    -- 显示时躲开输入区：把面板顶边贴到输入区**下缘之下**；
                        -- 下方空间不够才顶到屏幕上沿。拿不到就退回贴底
M.edgeMargin  = 4       -- 面板与屏幕边缘的间距
M.useMouse    = true    -- 把**鼠标位置**当作输入区的代理（2026-10-02，Lin 提的思路）。
                        -- 为什么需要它：为了躲开输入区，前后四轮全在 AX 上打转——猜role、
                        -- 加白名单、换判据，在 WorkBuddy（Electron）里始终「命中 0 个」。
                        -- 根本问题是**AX 能不能暴露输入区取决于那个 App 愿不愿意**，
                        -- 而鼠标位置任何 App 都一定有，一行就拿到、不依赖 App 实现。
                        -- 用户点输入框那一刻鼠标就在输入区里，所以「鼠标停在哪」
                        -- 是个很强的代理。
                        -- 它排在 AX 精确光标之后、粗容器之前（prio 2 vs 1/3）。
                        -- 设false 可关掉，只用 AX 判定。
M.mouseStillTime = 0.4  -- 鼠标要**静置**这么久（秒）才采信它的位置。
                        -- 打开键盘时鼠标可能正在移动，或者刚点完菜单栏就按快捷键——
                        -- 这时位置是噪声，拿它挪键盘会把面板甩到奇怪的地方。
M.mouseAnchorHeight = 120 -- 鼠标位置只是个**点**，没有高度，直接拿来跟面板比重叠
                        -- 毫无意义（点高 0）。所以在它**上方**造一个这么高的
                        -- 「假想输入区」，只取它的**下缘**：面板停在鼠标上方，
                        -- 就不会压住用户刚点击的那个位置。
M.opacity     = 0.78    -- 面板不透明度（1 = 全实心）。Lin 要求半透明
                        -- （2026-10-02）：避让总有兜不住的时候（输入区可能占满
                        -- 整页、或根本探测不到），半透明是最后一道保险——
                        -- 挡不死，至少能透出下面的输入框。
                        -- 0.6~0.8 比较合适；< 0.5 键帽会太透、看不清字。
                        -- 改完立即生效（不用重载），下一次 M.show() 时应用。
                        -- 想临时完全不透明：hs.osk.opacity = 1
M._repeat = nil         -- 按住连发的定时器
M._tap = nil            -- 事件拦截 tap
M._watchdog = nil       -- tap 看门狗（系统禁用后自动重启）
M._capturing = false    -- 正在按（mouseDown 起到 mouseUp 止，期间事件全吞）
M._pressing = nil       -- 当前按住的键记录
M._targetApp = nil      -- show 时记录的目标 App（还原 show 抢走的焦点用）
M._axTimeoutSet = false -- AX 全局超时是否已设（只设一次，见 focusedInputRect）

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
---
--- 半透明做成**函数**而不是加载时算好的常量：Lin 要求「改屏幕键盘为半透明」
--- （2026-10-02）——避让在某些 App 里仍会兜不住（输入区可能占满整页、或压根
--- 找不到），半透明是最后一道保险：挡不死，至少能透出下面的输入框。
--- 做成函数才能让 `M.opacity` 改完立刻生效（改常量得重载模块）。
---
--- **关键：窗口级 alpha 和元素 alpha 是相乘的。**
--- `M.opacity` 已经通过 `canvas:alpha()` 施加在整个窗口上，元素里的 alpha
--- 只会**再乘一遍**。所以元素颜色不该也去承担「透明」任务——那会被乘两次，
--- M.opacity 调到 0.5 时键帽就只剩 0.25，什么都看不清了。
--- 结论：**透明度只由 M.opacity 一个旋钮负责**，元素颜色只负责「面板内部的
--- 深浅层次」，因此这里只给很小的响应幅度 + 一个硬下限。
local function colors()
    local o = M.opacity or 1
    -- 键帽不透明度：给 0.62 的下限。即便面板很透，键帽本体仍要有实体感，
    -- 否则键帽和面板背景糊成一片、看不清键位边界。
    local capAlpha = math.max(0.62, o)
    -- 文字是硬下限 0.85：键盘的首要用途是看字认键，文字跟着面板一起淡到
    -- 0.7 就不好用了。早先写成 0.98*(0.6+0.4*o)，在 o=0.3 时只有 0.706，
    -- 被自己的测试判为不合格——说明这个下限本来就该是硬的。
    local textAlpha = math.max(0.85, math.min(1, 0.90 + 0.10 * o))
    return {
        -- 背景保持较高不透明度：真正让下面输入框透出来的是窗口级 alpha，
        -- 背景再自己降一档就过头了（两层相乘）。
        bg      = rgba("1B1B20", math.max(0.72, 0.88 * o)),
        key     = rgba("3C3C44", 0.96 * capAlpha),
        modKey  = rgba("2E2E36", 0.96 * capAlpha),
        text    = rgba("E8E8EC", textAlpha),
        armed   = rgba("2E7CF6", 0.98 * capAlpha),  -- 修饰键上膛 / caps 开
        pressed = rgba("585864", 0.98 * capAlpha),  -- 按下瞬间
        handle  = rgba("9A9AA4", 0.65 * capAlpha),  -- 拖动把手圆点
    }
end

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
    local C = colors()
    for _, k in ipairs(M._keys) do
        local def = k.def
        c:elementAttribute(k.text, "text", labelFor(def))

        local fill = def.mod and C.modKey or C.key
        local on = (def.mod and M.armed[def.mod]) or
            (def.special == "caps" and M.caps)
        if on then fill = C.armed end
        if k.pressed then fill = C.pressed end
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
                        -- 越界钳制：把面板留在当前屏幕内，避免拖到屏幕外找不回来
                        local sf = hs.screen.mainScreen():frame()
                        nx = math.max(sf.x, math.min(nx, sf.x + sf.w - M._frame.w))
                        ny = math.max(sf.y, math.min(ny, sf.y + sf.h - M._frame.h))
                        M._canvas:topLeft({ x = nx, y = ny })
                        M._frame.x = nx
                        M._frame.y = ny
                        -- 起点跟着走：否则第二次拖动的偏移量会越来越离谱
                        M._drag.mx, M._drag.my = loc.x, loc.y
                        M._drag.fx, M._drag.fy = nx, ny
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

        -- 面板内但没在「按住」状态的左键 up/dragged 也必须吞掉。
        -- 典型场景：在面板外按下鼠标 → 拖进面板 → 松手。此时 _capturing 为
        -- false，这个 mouseUp 会漏给画布窗口，AppKit 收到就激活 Hammerspoon
        -- ——正是 v3 要根治的抢焦点。判定只看坐标在不在面板内。
        if t == types.leftMouseUp or t == types.leftMouseDragged then
            local loc = ev:location()
            if loc and inPanel(loc.x, loc.y) then return true end
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
-- 位置：躲开输入焦点（光标 / 输入框）
--------------------------------------------------------------------------------

--- 诊断日志：/tmp/osk-ax.log。
--- 「键盘为什么没躲开」在屏幕上完全看不出来（不报错、也没提示），不看日志
--- 只能猜：到底是 AX 没给出焦点、还是给了但取不到光标矩形、还是矩形太大
--- 没法避让。所以每次 show 都把探测链路逐条落盘，排查时先看这个文件。
--- 文件超过 256KB 自动截断，避免长期运行把 /tmp 撑爆。
local function diag(fmt, ...)
    local path = "/tmp/osk-ax.log"
    local f = io.open(path, "r")
    if f then
        local size = f:seek("end")
        f:close()
        if size > 256 * 1024 then
            local t = io.open(path, "w")
            if t then t:close() end
        end
    end
    local out = io.open(path, "a")
    if not out then return end
    out:write(string.format("%s  ", os.date("%F %T")), string.format(fmt, ...), "\n")
    out:close()
end

--- 一次 AX 读取，永不抛异常（AX 权限被撤销、App 半死都会抛）。
local function axAttr(el, name)
    if not el then return nil end
    local ok, v = pcall(function() return el:attributeValue(name) end)
    if ok then return v end
    return nil
end

--- 带参数的 AX 读取（AXBoundsForRange 走这里），同样不抛。
local function axParam(el, name, param)
    if not el then return nil end
    local ok, v = pcall(function() return el:parameterizedAttributeValue(name, param) end)
    if ok then return v end
    return nil
end

--- 鼠标/光标位置 —— **AX 之外的独立来源**（2026-10-02，Lin 提的思路）。
---
--- 为什么要有这条：为了躲开输入区，前后四轮全在 AX 上打转——猜 role、加白名单、
--- 换判据，结果在 WorkBuddy（Electron）里始终「命中 0 个」。**问题在于 AX 能不能
--- 暴露输入区取决于那个 App 愿不愿意**，而鼠标位置**任何 App 都一定有**，
--- `hs.mouse.getAbsolutePosition()` 一行就拿到，不依赖权限也不依赖 App 实现。
---
--- 用户点输入框那一刻，鼠标就在输入区里。所以「鼠标停在哪」是个**很不错的代理**。
---
--- 用法上有两条重要限制（都因为它只是个点，不是矩形）：
--- * **只在鼠标停留一段时间后采信**。用户打开键盘时鼠标可能正在移动，或者
---   停在面板外（比如刚点完菜单栏图标就按快捷键）。刚动过的鼠标位置是噪声，
---   用它挪键盘会把面板甩到奇怪的位置。要「静置」过 `M.mouseStillTime` 秒
---   才认，否则返回 nil。
--- * **它只是个点，没有高度**，所以不能直接当容器用（点的高度是 0，
---   拿去跟面板比重叠毫无意义）。做法是把它当成「输入区的上沿提示」：
---   在鼠标位置**上方**加一个合理高度，得到一个「假想输入区」矩形，
---   让它只提供**下缘**这个信息——面板停在鼠标上方就不会压住点击处。
---   标记为 `precise`（它比整页容器精确得多，比真光标粗但足够用）。
local function mouseAnchor()
    if M.avoidInput ~= true then return nil end
    if M.useMouse == false then return nil end
    -- **函数名是 `absolutePosition`，不是 `getAbsolutePosition`**（查本机
    -- docs.json 确认，签名 `hs.mouse.absolutePosition([point]) -> point`，
    -- 无参即读当前值）。写错名字会被 pcall 静默吞掉、整个功能永不生效——
    -- 跟 A3 那次 `pcall(app)` 一模一样的坑，所以在这里显式注明。
    --
    -- 坐标系：本项目已真机坐实是**左上原点、y 向下**，与 hs.screen:frame() /
    -- hs.canvas 同一套（见 MEMORY「坐标系」条目），可直接与面板几何比较。
    local ok, pos = pcall(hs.mouse.absolutePosition)
    if not ok or type(pos) ~= "table" or not pos.x or not pos.y then
        diag("鼠标位置读不到（pcall 失败）")
        return nil
    end
    local x, y = pos.x, pos.y

    -- 静置判断：跟上一次记录的位置比，位置没变 + 停够了时间才算「静置」。
    --
    -- **时钟必须用 `hs.timer.absoluteTime()`（纳秒单调时钟）**：
    -- *不能用 `os.time()`* —— 它只到**秒**级精度，而 mouseStillTime 默认 0.4s
    --  是亚秒阈值。同秒内两次 show 会算出 `now - last.t == 0 < 0.4`，
    --  静置判定永远不成立（实测踩到：测试里两次 show 挨着跑，
    --  鼠标候选一次都没生效）。
    -- *也不能用 `os.clock()`* —— 那是 CPU 时间，空闲时根本不走。
    -- absoluteTime 还能免疫「系统时间被调整」，比 secondsSinceEpoch 更稳。
    local now
    if hs.timer and hs.timer.absoluteTime then
        local okT, t = pcall(hs.timer.absoluteTime)
        now = (okT and t) and t / 1e9 or os.time()
    else
        now = os.time()
    end
    local last = M._mouse
    local still = false
    if last and last.x == x and last.y == y then
        still = (now - last.t) >= (M.mouseStillTime or 0.4)
    end
    M._mouse = { x = x, y = y, t = now }
    if not still then
        diag("鼠标在动（或刚移动）(%d,%d) → 不用它定位", x, y)
        return nil
    end

    -- 点→矩形：在鼠标上方造一个「假想输入区」。
    -- 高度取 120 是经验值：够覆盖常见输入框（单行/多行几行）的高度，
    -- 又不会像整页容器那样让避让判断失效。
    local h = M.mouseAnchorHeight or 120
    local rect = { x = x - 1, y = y - h, w = 2, h = h }
    diag("鼠标静置于 (%d,%d) → 假想输入区 (%.0f,%.0f %.0fx%.0f) 下缘 %.0f",
        x, y, rect.x, rect.y, rect.w, rect.h, rect.y + rect.h)
    return rect
end

--- A2「按 role 找输入框」的遍历上限。Chromium 会把可编辑区埋好几层
--- （实测 WorkBuddy 在第 3 层，但层级会随版本变），深度给到 6 留余量；
--- 累计节点数也设上限——AX 查询每次都是 IPC，不能把整棵 AX 树走穿。
--- 想知道真实层级就执行 `hs.osk.dumpAXTree()`，它会打印每层节点数与 role 统计。
local MAX_TEXT_DEPTH = 6
local MAX_TEXT_NODES = 24

--- 可编辑文本区的 AX role。A2 那条「按 role 找输入框」的路子按这个列表找。
--- 覆盖原生 App（AXTextField / AXTextArea / AXSecureTextField）与
--- Chromium/Electron 的两种角色写法（AXTextField、AXTextArea，
--- 以及少数版本的 AXSearchField / AXComboBox）。
local TEXT_ROLES = {
    "AXTextField", "AXTextArea", "AXSecureTextField",
    "AXSearchField", "AXComboBox",
}

--- **遇到可编辑 role 就停，不再往下挖**（Chromium 会把文本框再套一层 wrapper，
--- 继续下降只会命中 wrapper 那个「整页大矩形」，反而更糟）。
local TEXT_ROLE_SET = {}
for _, r in ipairs(TEXT_ROLES) do TEXT_ROLE_SET[r] = true end

--- 把当前焦点窗口的 AX 树整棵 dump 到 /tmp/osk-axtree.log。
---
--- 为什么需要它：2026-10-02 这次避让连挂三轮——第一轮误判成「Word 正文躲不开」，
--- 第二轮发现 WorkBuddy 里 AXFocusedUIElement 恒为 nil、但按 role 找还是
--- **命中 0 个**；第三轮半透明做出来了，位置依然不对，日志仍是「命中 0 个」。
--- 到这一步就只能看真实 AX 树长什么样，继续猜 role / 猜深度全是盲猜。
---
--- **本函数已被自动触发**（见 focusedInputInfo 里的自动 dump）：A2 命中 0 个
--- 时会自动跑一次并落盘，不需要手动执行。只有想随时看时才手动跑
--- `hs.osk.dumpAXTree()`。
---
--- 除了 role 与层级，还记**每个节点能不能给出 AXSelectedTextRange**——
--- 这条判据比 role 名字更本质：只要一个元素能返回文本选区，它就是可编辑文本区，
--- 哪怕它的 role 是 `AXGroup` 或别的怪名字。role 白名单靠不住时（Electron 的
--- role 会随版本变），它能兜住。
function M.dumpAXTree()
    local app = hs.application.frontmostApplication()
    if not app then diag("dumpAXTree: 没有前台 App"); return end
    local okW, win = pcall(function() return app:focusedWindow() end)
    if not okW or not win then
        diag("dumpAXTree: %s 没有焦点窗口", app:name()); return
    end
    local okE, winEl = pcall(hs.axuielement.windowElement, win)
    if not okE or not winEl then
        diag("dumpAXTree: windowElement() 拿不到（%s）", app:name()); return
    end

    local path = "/tmp/osk-axtree.log"
    local f = io.open(path, "w")
    if not f then diag("dumpAXTree: 写不了 %s", path); return end
    f:write(string.format("=== %s  窗口「%s」  %s ===\n",
        os.date("%F %T"), win:title(), app:name()))

    local counts, layers = {}, {}
    -- 「能返回文本选区」的节点清单。这是 role 白名单之外的第二条判据，
    -- 也是判断「这个 App 到底把输入框暴露成什么」最直接的证据。
    local selHits = {}
    local function walk(el, depth, pathStr)
        if depth > 8 or counts.total > 400 then return end
        counts.total = (counts.total or 0) + 1
        local role = axAttr(el, "AXRole") or "?"
        counts[role] = (counts[role] or 0) + 1
        layers[depth] = layers[depth] or 0
        layers[depth] = layers[depth] + 1

        -- 能不能给出文本选区？能 → 它就是可编辑文本区（不管 role 叫什么）
        local sel = axAttr(el, "AXSelectedTextRange")
            or axAttr(el, "AXSelectedTextRanges")
        local flag = ""
        if sel ~= nil then
            flag = "  <<< 可编辑(有选区)"
            selHits[#selHits + 1] = string.format("%s%s  depth=%d",
                pathStr, role, depth)
        elseif TEXT_ROLE_SET[role] then
            flag = "  <<< 文本 role"
        end

        -- 有矩形的节点才可能是输入区，记下来
        local pos  = axAttr(el, "AXPosition")
        local size = axAttr(el, "AXSize")
        if type(pos) == "table" and type(size) == "table"
            and pos.x and pos.y and size.w and size.h then
            f:write(string.format("%s%s  (%.0f,%.0f %.0fx%.0f)%s\n",
                pathStr, role, pos.x, pos.y, size.w, size.h, flag))
        else
            f:write(string.format("%s%s%s\n", pathStr, role, flag))
        end

        local kids = axAttr(el, "AXChildren")
        if type(kids) == "table" then
            for i = 1, math.min(#kids, 30) do
                walk(kids[i], depth + 1, pathStr .. "  ")
            end
        end
    end
    walk(winEl, 0, "")

    if #selHits > 0 then
        f:write("\n--- 能返回文本选区的节点（= 真正的可编辑文本区）---\n")
        for _, l in ipairs(selHits) do f:write(l .. "\n") end
    else
        f:write("\n--- 能返回文本选区的节点：**一个都没有**---\n")
        f:write("(说明这个 App/窗口压根没把可编辑区暴露给 AX)\n")
    end

    f:write("\n--- 各深度节点数 ---\n")
    for d = 0, 8 do
        if layers[d] then f:write(string.format("深度 %d: %d\n", d, layers[d])) end
    end
    f:write("\n--- role 统计 ---\n")
    local names = {}
    for r in pairs(counts) do if r ~= "total" then names[#names + 1] = r end end
    table.sort(names)
    for _, r in ipairs(names) do
        f:write(string.format("%-28s %d\n", r, counts[r]))
    end
    f:close()
    diag("dumpAXTree: 已写入 %s（%d 个节点）", path, counts.total or 0)
    return path
end

--- 矩形是否可用（x/y 必须是数字，w/h 缺省当 0）。
local function validRect(r)
    return type(r) == "table"
        and tonumber(r.x) ~= nil and tonumber(r.y) ~= nil
        and tonumber(r.w or 0) ~= nil and tonumber(r.h or 0) ~= nil
end

local function rectOf(b)
    if not validRect(b) then return nil end
    return { x = b.x, y = b.y, w = b.w or 0, h = b.h or 0 }
end

--- 在一个 AX 元素上取矩形，逐级降级，结果塞进 out（带来源标注）：
---   ① AXSelectedTextRange  + AXBoundsForRange → 插入光标那条细线（精确）
---   ② AXSelectedTextRanges（复数）→ 有些 App 只给这个；取最后一个，
---      因为插入点永远在选区末端
---   ③ AXPosition + AXSize → 整个输入框 / 容器（不精确，只能当粗判据）
--- range 参数写成 {location=, length=}，dylib 会转成 kAXValueCFRangeType
--- （写 {starts=, ends=} 也认）。
--- 在一个元素上做三级降级探测，把找到的矩形塞进 out。
--- 返回值只表示「**这个元素有没有给出候选**」，不区分精确还是粗判据——
--- 调用方据此决定还要不要往更外围的路子（子层/父层/App 元素）上找。
--- 精确优先由 focusedInputInfo 在所有候选里统一排。
---
--- 注意：拿到 box（粗判据）时也必须返回 true。早先这里返回 false，导致
--- focusedInputInfo 以为「还没找到」而继续走 App 元素兜底；那条路在真实环境里
--- 常能返回一个看似精确的光标框，于是整页容器的「两边都躲不开 → 保持贴底」
--- 判定被它盖掉，把键盘抬到顶部、照样盖着正文（2026-10-02 Word 那个 bug）。
local function probeElement(el, label, out)
    if not el then return false end

    local range = axAttr(el, "AXSelectedTextRange")
    if type(range) == "table" and tonumber(range.location) then
        local b = rectOf(axParam(el, "AXBoundsForRange", range))
        if b then
            out[#out + 1] = { src = label .. "/range", rect = b, precise = true, prio = 1 }
            return true
        end
    end

    local rs = axAttr(el, "AXSelectedTextRanges")
    if type(rs) == "table" and #rs > 0 then
        for i = #rs, 1, -1 do
            local r = rs[i]
            if type(r) == "table" and tonumber(r.location) then
                local b = rectOf(axParam(el, "AXBoundsForRange", r))
                if b then
                    out[#out + 1] = { src = label .. "/ranges", rect = b, precise = true, prio = 1 }
                    return true
                end
            end
        end
    end

    local pos  = axAttr(el, "AXPosition")
    local size = axAttr(el, "AXSize")
    if type(pos) == "table" and type(size) == "table" then
        local b = rectOf({ x = pos.x, y = pos.y, w = size.w, h = size.h })
        if b then
            -- prio 3 = 粗容器（整个输入框/正文区）。排在 AX 精确光标（1）与
            -- 鼠标位置（2）之后——「整页容器但子层藏光标」那个场景就靠这个
            -- 优先级把子层光标选出来。早先这里不设 prio（跟精确候选一样是默认 1），
            -- 结果整页容器排在子层光标前面，直接把子层光标顶掉了。
            out[#out + 1] = { src = label .. "/box", rect = b,
                precise = false, prio = 3 }
            return true
        end
    end
    return false
end

--- 取当前输入焦点的矩形信息。
--- 返回 { rect = {x,y,w,h}, precise = bool, src = string } 或 nil。
---
--- 坐标系：AX 返回的是**左上原点、y 向下**的全局坐标，与 hs.screen:frame() /
--- hs.canvas 对 Lua 暴露的坐标是**同一套**，直接用，不要翻转。
--- 依据（本机源码核实，2026-10-02）：libcanvas.m 里 Lua 侧 ↔ NS 侧之间靠
--- RectWithFlippedYCoordinate 转换，翻转基准是 `[[NSScreen screens][0]
--- frame].size.height`（主屏高）—— 说明 Lua 侧给的就已经是 y 向下那套。
--- 这里若自作主张翻转，会把面板送到屏幕另一头，性质和 2026-09-26 那次
--- 「把点击镜像打空」完全一样。
---
--- 探测分两类，**全部尝试、收集候选、统一排序**（不是谁先有结果谁赢）：
---   A. 焦点元素链：systemWide 的 AXFocusedUIElement，再从它往下（子层 ≤8）
---      与往上（父层）各探一次。这三层是同一来源，子层里的**精确光标**比外层的
---      **整页容器**更有信息量，所以外层给了矩形也要继续往下找。
---   B. 焦点窗口里的文本元素：拿前台 App 的焦点窗口，按 role 找出其中的
---      文本框/文本区（见 TEXT_ROLES）。
---      —— 2026-10-02 真机实测：WorkBuddy（Electron/Chromium）里
---      **AXFocusedUIElement 恒为 nil**，A 类全军覆没，而输入框明明在窗口里。
---      Chromium 的 AX 树把可编辑区挂在窗口下、不作为「焦点元素」暴露，
---      只能按 role 去找。这条路是 Electron 类 App 的主力路径。
---
--- 全部拿不到（没AX 权限、App 不支持 AX、焦点不在文本框）→ nil，调用方退回
--- 默认贴底，绝不因为 AX 失败就让键盘显示不出来。
local function focusedInputInfo(frontApp)
    local out = {}

    -- 焦点窗口：A2 要用。frontApp 由调用方传入（它已经取过一遍并排除了
    -- Hammerspoon 自己），这里不再重复取，免得两处判断不一致。
    frontApp = frontApp or hs.application.frontmostApplication()
    local win = nil
    if frontApp and not isHammerspoon(frontApp) then
        local okW, w = pcall(function() return frontApp:focusedWindow() end)
        if okW then win = w end
        diag("前台 App=%s 焦点窗口=%s",
            frontApp and frontApp:name() or "?",
            (win and win:title()) or "nil")
    end

    local function probe(el, label)
        if el then probeElement(el, label, out) end
    end

    local ok = pcall(function()
        local sw = hs.axuielement.systemWideElement()
        if not sw then diag("systemWideElement() = nil"); return end

        -- 给 AX 查询装上超时闸。默认超时很长（数秒），前台 App 卡住时
        -- M.show() 会被一起拖住、键盘迟迟出不来。
        -- 注意：在 systemWideElement 上设超时是**进程全局**的（文档原文：
        -- 影响所有没单独设过超时的元素），所以只设一次。
        if not M._axTimeoutSet then
            pcall(function() sw:setTimeout(1.0) end)
            M._axTimeoutSet = true
        end

        -- A1：焦点元素 + 子层 + 父层
        local el = axAttr(sw, "AXFocusedUIElement")
        if el then
            diag("A1 焦点元素 role=%s", tostring(axAttr(el, "AXRole")))
            probe(el, "focus")

            local kids = axAttr(el, "AXChildren")
            if type(kids) == "table" then
                for i = 1, math.min(#kids, 8) do
                    probe(kids[i], "child" .. i)
                end
            end
            probe(axAttr(el, "AXParent"), "parent")
        else
            diag("A1 AXFocusedUIElement = nil（该 App 不把它当焦点元素暴露）")
        end

        -- A2：焦点窗口的 AX 树里按 role 找文本元素。
        -- 这是 Electron/Chromium 类 App 的主力路径（2026-10-02 真机坐实）：
        -- WorkBuddy 里 AXFocusedUIElement 恒为 nil，输入框只出现在窗口的 AX 树里。
        --
        -- 实现要点（都踩过）：
        -- * 只查 childrenWithRole 不够——它只返回**直接子层**，而 Chromium 的
        --   输入框往往埋在第 3 层。所以逐层往下取 AXChildren 自己做 BFS。
        -- * 命中就是「**整层**有文本 role 就停」，不是「某个元素命中就停」：
        --   逐元素停的话，同层里其它没命中的容器照样会往下降，照样挖到
        --   坏候选（Chromium 的输入框外面常挂着一堆兄弟容器）。
        -- * 停下之后**不再往命中元素底下挖**：Chromium 会把真正的输入框再套
        --   一层 wrapper，继续下降只会命中 wrapper 那个「整页大矩形」，
        --   反而更糟（那正是第一轮误判成「输入区占满整页躲不开」的坑）。
        -- * 深度与累计节点数都设上限——AX 查询每次都是 IPC，不能走穿整棵 AX 树。
        --   想知道真实层级就执行 `hs.osk.dumpAXTree()`。
        if win then
            local okW, winEl = pcall(hs.axuielement.windowElement, win)
            if okW and winEl then
                local layer = { winEl }
                local found = 0
                for depth = 0, MAX_TEXT_DEPTH do
                    -- 先把整层扫一遍，分成「可编辑文本区」和「不是」两类。
                    -- 这么分的理由（踩过）：逐元素处理时，同层里命中的元素虽然不下降，
                    -- 但**同层其它未命中的元素照样会往下降**——Chromium 那种
                    -- 「输入框外面还挂着一堆兄弟容器」的结构里，照样会挖到坏候选。
                    -- 整层判定才能保证「这层有输入框，就不再往下钻」。
                    local hits, rest = {}, {}
                    for _, el in ipairs(layer) do
                        local role = axAttr(el, "AXRole")
                        -- 判据1：role 在白名单里。
                        -- 判据2：**能返回文本选区**。这条比 role 名字更本质——
                        -- 只要元素能给出 AXSelectedTextRange，它就是可编辑文本区，
                        -- 哪怕 role 是 AXGroup 或别的怪名字（Electron 的 role 会随版本
                        -- 变，白名单早晚会对不上）。两条任一成立就算命中。
                        local sel = nil
                        if not (role and TEXT_ROLE_SET[role]) then
                            sel = axAttr(el, "AXSelectedTextRange")
                            if sel == nil then sel = axAttr(el, "AXSelectedTextRanges") end
                        end
                        if (role and TEXT_ROLE_SET[role]) or sel ~= nil then
                            hits[#hits + 1] = { el = el, role = role or "?" }
                        else
                            rest[#rest + 1] = el
                        end
                    end

                    if #hits > 0 then
                        for _, h in ipairs(hits) do
                            if found >= MAX_TEXT_NODES then break end
                            found = found + 1
                            -- 标签带深度，日志能直接看出它埋在哪一层
                            probe(h.el, string.format("d%d.%s",
                                depth, (h.role:gsub("^AX", ""))))
                        end
                        diag("A2 第 %d 层命中 %d 个文本元素，就此停住不再下钻", depth, #hits)
                        break
                    end

                    -- 本层没有输入区，才下降一层；累计节点数设上限——
                    -- AX 查询每次都是 IPC，不能把整棵 AX 树走穿。
                    local nextLayer = {}
                    for _, el in ipairs(rest) do
                        if #nextLayer >= MAX_TEXT_NODES then break end
                        local kids = axAttr(el, "AXChildren")
                        if type(kids) == "table" then
                            for i = 1, #kids do
                                if #nextLayer >= MAX_TEXT_NODES then break end
                                nextLayer[#nextLayer + 1] = kids[i]
                            end
                        end
                    end
                    if #nextLayer == 0 then break end
                    layer = nextLayer
                end
                diag("A2 文本元素命中 %d 个", found)
                -- 命中 0 个说明这个 App 的输入区压根没被 role 白名单捞到。
                -- 与其继续猜 role，不如直接把真实 AX 树落盘（自动诊断，
                -- 别指望用户记得手动跑）。只对同一个 App 自动跑一次，否则
                -- 每次开键盘都 dump 一次会拖慢启动。
                if found == 0 then
                    local appName = frontApp and frontApp:name() or "?"
                    if M._dumpedFor ~= appName then
                        M._dumpedFor = appName
                        pcall(M.dumpAXTree)
                    end
                end
            else
                diag("A2 windowElement() 拿不到")
            end
        end

        -- A3：App 元素 → AXFocusedWindow → AXFocusedUIElement
        -- 注意 applicationElement 是 **Constructor，必须传 hs.application 对象**。
        -- 早先写成无参的 pcall(app) 调用，等于没传 app，这条路从来没通过。
        if frontApp and not isHammerspoon(frontApp) then
            local okA, appEl = pcall(hs.axuielement.applicationElement, frontApp)
            if okA and appEl then
                local awin = axAttr(appEl, "AXFocusedWindow")
                probe(awin and axAttr(awin, "AXFocusedUIElement"), "app")
            else
                diag("A3 applicationElement() 失败")
            end
        end
    end)
    if not ok then diag("AX 探测抛异常（权限被撤销？）"); return nil end

    -- A4：鼠标/光标位置。**先加进来**，这样排序时它自然参与竞争：
    -- 精确光标(prio 1) > 鼠标位置(prio 2) > 粗容器(prio 3)。
    -- 理由：AX 给的插入光标是真正最准的；找不到时鼠标位置是很强的代理
    --（用户点输入框那一刻鼠标就在里面），而粗容器只能当兜底。
    local mrect = mouseAnchor()
    if mrect then
        out[#out + 1] = { src = "mouse", rect = mrect,
            precise = true, prio = 2 }
    end

    if #out == 0 then diag("所有路径都没拿到矩形"); return nil end

    for _, c in ipairs(out) do
        diag("  候选 %-14s %s (%.0f,%.0f %.0fx%.0f)",
            c.src, c.precise and "光标" or "容器",
            c.rect.x, c.rect.y, c.rect.w, c.rect.h)
    end
    -- 统一排序：prio 小者优先（AX 光标 1 < 鼠标 2 < 粗容器 3）。
    -- **不用 table.sort**——Lua 的 table.sort 不保证稳定，同 prio 时顺序是未定义的，
    -- 会出现「有时用鼠标有时用 AX」的随机行为。显式按 idx 兜底即可（稳定排序）。
    for i, c in ipairs(out) do c.idx = i end
    table.sort(out, function(a, b)
        local pa, pb = a.prio or 1, b.prio or 1
        if pa ~= pb then return pa < pb end
        return a.idx < b.idx
    end)
    return out[1]
end

--- 这个矩形是不是「大到无处可躲」。
--- Word / Pages / 浏览器的正文区能占满整个窗口高度，这时往上挪、贴底都压到它
--- ——拿整页矩形去比对重叠只会得到「顶部重叠略小」这种假信号，把键盘抬到顶部
--- 照样盖着文档，比贴底更糟。所以这种情况下认输，保持贴底。
--- 注意只在**拿不到精确光标**时才认输（调用方保证）；有精确光标时不存在这个问题，
--- 因为光标那条细线不可能有整页那么高。
local function unavoidablyLarge(rect, ph)
    return (rect.h or 0) > ph * 1.5
end

--- 选面板左上角。
---
--- Lin 的要求（2026-10-02）：**只要往上挪开输入框就行，不用翻到屏幕顶部。**
--- 聊天 App 的输入框通常在窗口底部、离屏幕底边还有一段（工具栏/引用区/状态栏），
--- 键盘停在输入框下缘之下就够了，既不挡输入、也不挡上方对话。
--- 所以这里是「精确落位」而不是「顶/底二选一」。
---
--- 规则按「拿到的信息有多精确」分档：
---   * 有明确下缘（精确光标，或不算大的容器）
---       → 面板顶边贴在它下缘 + 间距；下方放不下才往上顶_screen 顶。
---   * 大容器（只有整页矩形、贴顶贴底都躲不开）
---       → 保持贴底，不凭模糊信息乱动。这种情况下真正的解法不是挪键盘，
---         而是缩短输入区或换个滚动位置。
local function choosePosition(frame, w, h, info)
    local m       = M.edgeMargin
    local x       = frame.x + (frame.w - w) / 2
    local yBottom = frame.y + frame.h - h - m
    local yTop= frame.y + m
    if not (M.avoidInput and info) then return x, yBottom end

    local caret = info.rect

    -- 粗判据的大容器：无处可躲，保持贴底
    if not info.precise and unavoidablyLarge(caret, h) then
        diag("只有整页容器（h=%.0f vs 面板 %.0f），两边都躲不开 → 保持贴底",
            caret.h or 0, h)
        return x, yBottom
    end

    -- 输入区的高度（光标高度为 0 时按一行估）
    local ch = (caret.h and caret.h > 0) and caret.h or 18
    local caretBottom = caret.y + ch

    -- 首选：面板顶边贴在输入区下缘之下
    local y = caretBottom + m
    if y + h <= frame.y + frame.h - m then
        diag("精确落位：面板顶边=%.0f（输入区下缘 %.0f + 间距 %d）", y, caretBottom, m)
        return x, y
    end

    -- 下方放不下 → 顶到屏幕上沿
    diag("输入区下缘之下放不下（需要 %.0f，可用 %.0f）→ 顶到屏幕顶部",
        y + h, frame.y + frame.h - m)
    return x, yTop
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

    -- 窗口级透明度。canvas 自己的背景矩形虽然带了 alpha，但 Hammerspoon 的
    -- canvas 窗口默认仍是不透明的 NSWindow——不设这一句，元素里的 alpha 只会在
    -- 面板**内部**混色，透不出下面被盖住的输入框。窗口级 alpha 才是真半透明。
    -- 与元素颜色里的 alpha 相乘，所以键帽/文字的保底系数依然有效。
    pcall(function() c:alpha(M.opacity or 1) end)

    local elems = {}
    local C = colors()          -- 颜色按当前 M.opacity 现算
    -- 注意：hs.canvas 元素的坐标必须包在 frame = {} 里；x/y/w/h 平铺在顶层
    -- 会被 isValueValidForAttribute 拒绝（控制台报 "not a valid canvas attribute"）。
    elems[#elems + 1] = {
        type = "rectangle",
        id = "bg",
        action = "fill",
        frame = { x = 0, y = 0, w = w, h = h },
        fillColor = C.bg,
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
    }
    -- 顶部拖动把手：一排圆点提示可拖。落在把手/缝隙/内边距的按下都会拖动。
    elems[#elems + 1] = {
        type = "text",
        id = "handle",
        text = "· · · · ·",
        textSize = 12 * M.scale,
        textColor = C.handle,
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
                fillColor = def.mod and C.modKey or C.key,
                roundedRectRadii = { xRadius = 5, yRadius = 5 },
            }
            local rectIdx = idx
            idx = idx + 1
            elems[idx] = {
                type = "text",
                id = def.id .. "_t",
                text = labelFor(def),
                textSize = M.textSize,
                textColor = C.text,
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
    -- 层级要足够高：普通 App 窗口（Docker Desktop 这类全屏大窗口）激活时会盖到
    -- floating 层之上，所以直接用系统辅助面板那一档。
    c:level(hs.canvas.windowLevels[M.level] or M.level)
    -- canJoinAllSpaces：所有空间（含全屏 App）上层都可见。不叠加 moveToActiveSpace ——
    -- 两者语义冲突，canJoinAllSpaces 已经覆盖了「出现在当前空间」。
    c:behaviorAsLabels({ "canJoinAllSpaces" })
end

--- 把面板顶回最前。别的 App 激活时（Docker Desktop 之类），它的窗口会盖到画布
--- 前面；每次激活事件都重新断言一次层级，保证键盘始终在最上层。
function M.raise()
    if not M._canvas then return end
    pcall(function()
        M._canvas:level(hs.canvas.windowLevels[M.level] or M.level)
        M._canvas:orderAbove()
    end)
end

--- 显示期间监听 App 激活，趁机把面板顶回最前。
local function startRaiseWatcher()
    if M._raiseWatcher then return end
    local ok = pcall(function()
        M._raiseWatcher = hs.application.watcher.new(function(_, event)
            if event == hs.application.watcher.activated and M.isShowing() then
                hs.timer.doAfter(0.05, M.raise)
            end
        end)
        if M._raiseWatcher then M._raiseWatcher:start() end
    end)
    if not ok then M._raiseWatcher = nil end
end

local function stopRaiseWatcher()
    if not M._raiseWatcher then return end
    pcall(function() M._raiseWatcher:stop() end)
    M._raiseWatcher = nil
end

--- 设不透明度并立即生效（不用收起重开）。clamp 到 0.3~1。
--- 用法：hs.osk.setOpacity(0.6)  更通透 / hs.osk.setOpacity(1) 全实心
function M.setOpacity(v)
    v = tonumber(v) or 1
    v = math.max(0.3, math.min(1, v))
    M.opacity = v
    if M._canvas then
        pcall(function() M._canvas:alpha(v) end)
        -- 键帽/文字颜色也随opacity 变，得重刷一遍
        local C = colors()
        for _, k in ipairs(M._keys) do
            local def = k.def
            local fill = def.mod and C.modKey or C.key
            local on = (def.mod and M.armed[def.mod]) or
                (def.special == "caps" and M.caps)
            if on then fill = C.armed end
            if k.pressed then fill = C.pressed end
            pcall(function() M._canvas:elementAttribute(k.rect, "fillColor", fill) end)
            pcall(function() M._canvas:elementAttribute(k.text, "textColor", C.text) end)
        end
    end
    diag("setOpacity(%.2f)", v)
    return v
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

    -- 躲开输入区：优先用光标所在的细条，拿不到就用整个输入框/输入区，
    -- 再拿不到就在焦点窗口里按 role 找（Electron/Chromium 类 App）。
    -- 输入区不在键盘这块屏幕上时不做避让 —— 两套屏幕坐标混用会算错位置。
    local info = nil
    if M.avoidInput then
        info = focusedInputInfo(M._targetApp)
        if info then
            local r  = info.rect
            local cx = r.x + r.w / 2
            local cy = r.y + r.h / 2
            if cx < f.x or cx > f.x + f.w or cy < f.y or cy > f.y + f.h then
                diag("输入区不在主屏上 → 不做避让")
                info = nil
            end
        end
    end
    local x, y = choosePosition(f, w, h, info)

    if M.debugLog then
        diag("show: %s -> panel=(%.0f,%.0f) screen=%s",
            info and string.format("%s %.0f,%.0f %.0fx%.0f", info.src,
                info.rect.x, info.rect.y, info.rect.w, info.rect.h) or "无输入焦点信息",
            x, y, string.format("%.0f,%.0f %.0fx%.0f", f.x, f.y, f.w, f.h))
    end
    diag("show -> panel=(%.0f,%.0f) %s", x, y,
        info and string.format("依据 %s %s", info.src,
            info.precise and "(精确光标)" or "(容器粗判)")
            or "无输入焦点信息 → 默认贴底")

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
    startRaiseWatcher()
    M.raise()
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
    stopRaiseWatcher()
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
