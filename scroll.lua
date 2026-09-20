-- 反转鼠标滚动方向（轻量版 Scroll Reverser）+ 菜单栏开关
--
-- 为什么需要它：macOS 的“自然滚动”是全局开关，触控板和外接鼠标共用同一个设置。
-- 想要“触控板保持自然、外接鼠标反向”（或反过来）就只能拦事件。
--
-- 原理：用 hs.eventtap 监听 scrollWheel（滚轮/触控板双指）事件，把滚动量取反后
--       重新注入事件流，同时丢弃原始事件。系统已经在事件到达 tap 之前完成了
--       “自然滚动”的翻转，所以我们在这里取反是叠加在系统结果之上的。

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

local function handle(event)
    -- 出错就放行原始事件：宁可滚动方向没反转，也不能把滚动彻底搞死
    local ok, result = pcall(function()
        -- 像素级/连续滚动 = 触控板、妙控鼠标；行级滚动 = 传统滚轮鼠标
        local continuous = event:getProperty(props.scrollWheelEventIsContinuous)
        if M.scope == "mouse" and continuous ~= nil and continuous ~= 0 then
            return false -- 触控板：原样放行
        end
        return reverse(event)
    end)

    if not ok then return false end
    if result == false then return false end

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
    if M.enabled then M.tap:start() else M.tap:stop() end
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
if M.enabled then M.tap:start() end
refreshMenubar()

return M
