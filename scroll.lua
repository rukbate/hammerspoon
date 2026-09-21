-- 反转鼠标滚动方向（轻量版 Scroll Reverser）+ 菜单栏开关
--
-- 为什么需要它：macOS 的“自然滚动”是全局开关，触控板和外接鼠标共用同一个设置。
-- 想要“触控板保持自然、外接鼠标反向”（或反过来）就只能拦事件。
--
-- 原理：用 hs.eventtap 监听 scrollWheel 事件。两层处理：
--   1) 反转：把滚动量取反后重新注入，丢弃原始事件。系统已经在事件到达 tap
--      之前完成了“自然滚动”的翻转，所以这里取反是叠加在系统结果之上的。
--   2) 平滑（可选，M.smooth）：滚轮鼠标发出的是行级离散事件（一格 = 一行，
--      跳变感明显）。开启后不再转发原始事件，而是把滚动量（换成像素）攒进
--      缓冲区，由 hs.timer 按 1/125 秒的节奏做指数衰减式发放，合成像素级
--      连续事件 —— 效果类似 Mos 的 smooth scrolling。
--      合成的事件会被本 tap 再次看到，靠 eventSourceUnixProcessID 识别
--      “自己人”直接放行，防止死循环。

local M = {}

-- ========================= 配置 =========================
M.enabled = true

-- "mouse" : 只反转传统滚轮鼠标，触控板保持系统设置（推荐）
-- "all"   : 所有指点设备一起反转（等于系统关掉“自然滚动”，但可以随时秒切）
M.scope = "mouse"

-- 反转水平方向（横向滚动）。一般不需要。
M.horizontal = false

-- 菜单栏图标
M.showMenubar = true

-- 平滑滚动（只对滚轮类离散事件生效；触控板本来就是像素级连续的，不受影响）
M.smooth = true
M.smoothInterval = 0.008    -- 合成事件的发放间隔（秒），1/125s
M.smoothDecay = 0.30        -- 每拍发放剩余量的比例：越小尾越长、越“黄油”
M.smoothPixelsPerLine = 33  -- 1 行 ≈ 多少像素（决定整体滚动速度）
M.smoothMaxStep = 64        -- 单次发放的像素上限
M.smoothMaxBuffer = 240     -- 缓冲上限：飞轮狂甩时防积压失控

-- false : 点击图标直接开关（默认）
-- true  : 点击图标弹出下拉菜单（勾选式，和系统其它状态栏图标一致）
-- 注意：hs.menubar 的点击回调和下拉菜单互斥 —— 源码里写死了“挂了菜单之后
--       setClickCallback 永远不会被调用”，所以这里只能二选一。
M.menubarMenu = false

-- 让 macOS 记住你 ⌘ 拖动图标后的位置
M.menubarAutosaveName = "ScrollReverse"
-- =======================================================

local props = hs.eventtap.event.properties
local TYPES = hs.eventtap.event.types

-- 滚动量分散在多个字段里：传统滚轮鼠标用 DeltaAxis，触控板/像素级平滑滚动用
-- PointDeltaAxis 和 FixedPtDeltaAxis。必须一起取反，否则会出现“某些 App 里
-- 方向没变”的诡异情况。
local FIELDS = {}
for _, name in ipairs({
    "scrollWheelEventDeltaAxis1",
    "scrollWheelEventDeltaAxis2",
    "scrollWheelEventFixedPtDeltaAxis1",
    "scrollWheelEventFixedPtDeltaAxis2",
    "scrollWheelEventPointDeltaAxis1",
    "scrollWheelEventPointDeltaAxis2",
}) do
    if props[name] then FIELDS[#FIELDS + 1] = props[name] end
end

-- 轴 1 = 垂直，轴 2 = 水平
local function isHorizontal(field)
    for i = 2, #FIELDS, 2 do
        if FIELDS[i] == field then return true end
    end
    return false
end

local function reverse(event)
    local newEvent = event:copy()
    for _, field in ipairs(FIELDS) do
        if M.horizontal or not isHorizontal(field) then
            local v = event:getProperty(field)
            if type(v) == "number" then
                newEvent:setProperty(field, -v)
            end
        end
    end
    return newEvent
end

-- ==================== 平滑滚动引擎 ====================
-- 把“一格一格”的行级滚轮事件改造成像素级连续事件：
--   原始事件(±1行) → 换算成像素并取反 → 攒进 buf → 定时器按指数衰减发放。
-- 每拍发 step = buf * decay（保证 |step| ≥ 1 直到耗尽，≤ maxStep 防瞬移），
-- 发完后剩余量不足半像素就清零。buf 为 0 且无新事件时定时器自动停。
local buf = 0          -- 待发放像素（含方向）
local drainTimer = nil -- 发放定时器；只有发放中才存在

local SRC_PID = nil    -- 本进程 pid，用于识别“自己合成的事件”
local PROP_SOURCE_PID = props.eventSourceUnixProcessID
local PROP_CONTINUOUS = props.scrollWheelEventIsContinuous
local PROP_PHASE = props.scrollWheelEventScrollPhase
local PROP_MOMENTUM = props.scrollWheelEventMomentumPhase

-- 我们自己 post 的像素事件会重新进入本 tap。识别顺序：
--   1) 源进程 ID 是 Hammerspoon 自己（CGEventField 自动记录创建者，最可靠）
--   2) 兜底指纹：连续事件 + 相位全零 + 行增量为零 —— 真触控板/妙控鼠标的
--      连续事件必带非零相位（首个事件必有 began）或非零行增量，占不满这个组合
local function isOurs(event)
    if SRC_PID and event:getProperty(PROP_SOURCE_PID) == SRC_PID then
        return true
    end
    return event:getProperty(PROP_CONTINUOUS) == 1
        and (event:getProperty(PROP_PHASE) or 0) == 0
        and (event:getProperty(PROP_MOMENTUM) or 0) == 0
        and (event:getProperty(props.scrollWheelEventDeltaAxis1) or 0) == 0
end

local function stopDrain()
    if drainTimer then
        drainTimer:stop()
        drainTimer = nil
    end
    buf = 0
end

local function drain()
    if buf == 0 then
        stopDrain()
        return
    end
    local step = buf * M.smoothDecay
    if math.abs(step) < 1 then step = (buf > 0) and 1 or -1 end
    if math.abs(step) > M.smoothMaxStep then
        step = (buf > 0) and M.smoothMaxStep or -M.smoothMaxStep
    end
    step = (step >= 0) and math.floor(step + 0.5) or math.ceil(step - 0.5)
    local remaining = math.abs(buf)
    if math.abs(step) > remaining then
        step = (buf > 0) and math.max(1, math.floor(remaining + 0.5))
                     or math.min(-1, math.ceil(remaining - 0.5))
    end
    buf = buf - step
    if math.abs(buf) < 0.5 then buf = 0 end

    -- 竖直方向的像素事件；{"pixel"} 让 App 按像素平滑处理而不是整行跳
    local ev = hs.eventtap.event.newScrollEvent({0, step}, {}, "pixel")
    ev:setProperty(PROP_CONTINUOUS, 1)
    ev:post()
end

local function bufferScroll(event)
    -- 行级事件：FixedPt 是带小数的行数（高分辨率滚轮会有），Delta 是整数行
    local fixed = event:getProperty(props.scrollWheelEventFixedPtDeltaAxis1)
    local line = event:getProperty(props.scrollWheelEventDeltaAxis1)
    local lines = (type(fixed) == "number" and fixed ~= 0) and fixed or (line or 0)
    local pixels = -lines * M.smoothPixelsPerLine -- 取反在这里一并完成
    if pixels == 0 then return false end

    buf = buf + pixels
    if buf > M.smoothMaxBuffer then buf = M.smoothMaxBuffer
    elseif buf < -M.smoothMaxBuffer then buf = -M.smoothMaxBuffer end

    if not drainTimer then
        drainTimer = hs.timer.doEvery(M.smoothInterval, drain)
    end
    return true -- 原始事件已吸收进缓冲，丢弃
end
-- =====================================================

local function handle(event)
    -- 出错就放行原始事件：宁可滚动方向没反转，也不能把滚动彻底搞死
    local ok, result = pcall(function()
        if isOurs(event) then return false end -- 自己合成的像素事件，放行

        -- 像素级/连续滚动 = 触控板、妙控鼠标；行级滚动 = 传统滚轮鼠标
        local continuous = event:getProperty(PROP_CONTINUOUS)
        if M.scope == "mouse" and continuous ~= nil and continuous ~= 0 then
            return false -- 触控板：原样放行
        end
        -- 平滑开启且是离散滚轮事件 → 吸收进缓冲，由定时器发放像素事件
        if M.smooth and continuous ~= nil and continuous == 0 then
            if bufferScroll(event) then return true end
        end
        return reverse(event)
    end)

    if not ok then return false end
    if result == false then return false end
    if result == true then return true end

    -- 返回 true 丢弃原始事件，第二个返回值是要注入的新事件
    return true, {result}
end

M.tap = hs.eventtap.new({TYPES.scrollWheel}, handle)

-- 菜单栏图标：自己画的鼠标，中键（滚轮）实心 = 开 / 空心 = 关。
-- 生成脚本在 .workbuddy/tools/make_mouse_icons.py（纯标准库），改完几何重跑即可。
-- 用 PNG 而不是 hs.image.imageFromASCII 是因为后者是 ASCIImage（网格 = 像素数），
-- 放大到菜单栏尺寸会糊；这个版本也没有 SF Symbol 支持。
local function loadIcon(name)
    local ok, img = pcall(function()
        local i = hs.image.imageFromPath((hs.configdir:gsub("/$", "")) .. "/assets/" .. name)
        if i then
            -- 素材是 32×32 像素，按 16pt 显示（Retina @2x 正好一比一）
            i = i:size({ w = 16, h = 16 }) or i
            i:template(true) -- 模板图：菜单栏浅色/深色模式自动反色
        end
        return i
    end)
    return ok and img or nil
end

local ICONS = { on = loadIcon("scroll-on.png"), off = loadIcon("scroll-off.png") }
local GLYPH_ON, GLYPH_OFF = "⇅", "⊘" -- 图标加载失败时的兜底字形

local function statusLine()
    if not M.enabled then return "滚动反转：已关闭" end
    return "滚动反转：" .. (M.scope == "mouse" and "仅滚轮鼠标" or "全部设备")
end

local function refreshMenubar()
    if not M.menubarItem then return end
    local icon = M.enabled and ICONS.on or ICONS.off
    if icon then
        M.menubarItem:setIcon(icon)
    else
        M.menubarItem:setTitle(M.enabled and GLYPH_ON or GLYPH_OFF)
    end
    local tip = statusLine()
    if M.menubarMenu then
        tip = tip .. "\n点击展开菜单"
    else
        tip = tip .. "\n点击开关 · ⌥点击切换范围"
    end
    M.menubarItem:setTooltip(tip)
end

function M.setEnabled(on)
    M.enabled = on and true or false
    if M.enabled then
        M.tap:start()
    else
        stopDrain() -- 关掉时把没收尾的缓冲和定时器一起清掉
        M.tap:stop()
    end
    refreshMenubar()
end

function M.setScope(scope)
    M.scope = scope
    refreshMenubar()
end

function M.start() M.setEnabled(true) end
function M.stop() M.setEnabled(false) end

-- 排查用：控制台执行 hsScrollReverse.probe()，然后滚一下鼠标/触控板，
-- 会打印这条事件的 isContinuous 和各字段数值，用来确认 scope 该设成什么。
function M.probe()
    local probe
    probe = hs.eventtap.new({TYPES.scrollWheel}, function(e)
        print(string.format(
            "[probe] isContinuous=%s  Delta1=%s  PointDelta1=%s  FixedPt1=%s  phase=%s",
            tostring(e:getProperty(props.scrollWheelEventIsContinuous)),
            tostring(e:getProperty(props.scrollWheelEventDeltaAxis1)),
            tostring(e:getProperty(props.scrollWheelEventPointDeltaAxis1)),
            tostring(e:getProperty(props.scrollWheelEventFixedPtDeltaAxis1)),
            tostring(e:getProperty(props.scrollWheelEventScrollPhase))
        ))
        probe:stop()
        return false
    end)
    probe:start()
    print("[probe] 现在滚动一下鼠标或触控板…")
end

-- 热键循环：仅鼠标 -> 全部设备 -> 关闭 -> 仅鼠标
local function cycleFromHotkey()
    if not M.enabled then
        M.setScope("mouse")
        M.setEnabled(true)
    elseif M.scope == "mouse" then
        M.setScope("all")
    else
        M.setEnabled(false)
    end
    hs.alert.show(statusLine(), 0.8)
end
hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "r", cycleFromHotkey)

local function menuTable()
    return {
        { title = "启用滚动反转", checked = M.enabled, fn = function() M.setEnabled(not M.enabled) end },
        { title = "平滑滚动（滚轮）", checked = M.smooth, fn = function()
            M.smooth = not M.smooth
            if not M.smooth then stopDrain() end
        end },
        { title = "-" },
        { title = "仅滚轮鼠标", checked = M.enabled and M.scope == "mouse", fn = function() M.setScope("mouse"); M.setEnabled(true) end },
        { title = "全部设备（含触控板）", checked = M.enabled and M.scope == "all", fn = function() M.setScope("all"); M.setEnabled(true) end },
        { title = "-" },
        { title = "排查设备类型（打印到控制台）", fn = function() M.probe() end },
    }
end

if M.showMenubar then
    -- 必须持有这个引用：菜单栏对象的 __gc 会调用 removeStatusItem()，
    -- 引用一丢，Lua 回收它，图标就从菜单栏消失了。
    M.menubarItem = hs.menubar.new(true, M.menubarAutosaveName)
    if M.menubarItem then
        if M.menubarMenu then
            M.menubarItem:setMenu(menuTable)
        else
            M.menubarItem:setClickCallback(function(mods)
                if mods and mods.alt then
                    M.setScope(M.scope == "mouse" and "all" or "mouse")
                else
                    M.setEnabled(not M.enabled)
                end
                hs.alert.show(statusLine(), 0.8)
            end)
        end
    end
end

-- 初始状态
SRC_PID = hs.processInfo.processID -- 识别自己合成的事件，防止 tap 死循环
if M.enabled then M.tap:start() end
refreshMenubar()

return M
