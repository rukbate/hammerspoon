--- micswitch.lua —— 手动切换默认输入设备（2026-10-24）
---
--- 替代 audiopriority 的自动模式：不再周期采样电平（ffmpeg 轮询全停），
--- 菜单栏常驻 🎙 图标 + 当前默认输入名；点开弹菜单，选哪个切哪个。
--- 「麦在不在线」由人眼判断——发射器开关本来就是 Lin 自己的操作。
---
--- 恢复自动模式：init.lua 里 require "micswitch" 改回 require "audiopriority"。

local M = {}

local LOGDIR = os.getenv("HOME") .. "/.hammerspoon/.workbuddy"
local logfile = LOGDIR .. "/micswitch.log"

local function plog(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then return end
    local f = io.open(logfile, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
        f:close()
    end
end

local menu = hs.menubar.new()
if not menu then
    plog("!! hs.menubar.new 失败")
    return M
end

--- 当前默认输入设备名
local function defaultInputName()
    local d = hs.audiodevice.defaultInputDevice()
    return d and d:name() or "?"
end

-- 品牌短标：菜单栏不显示真实设备名，一眼认出当前连的是哪个麦
local BRAND = {
    ["Wireless Mic Rx"]   = "DJI",
    ["HP S1X sound bar"]  = "HP",
}
local function brandLabel(name)
    if BRAND[name] then return BRAND[name] end
    local w = name:match("^%a+") or name  -- 未知设备：取首个单词前 4 字符
    return w:upper():sub(1, 4)
end

--- 画「麦克风图形 + 品牌标」图标（造型对齐 🎙 emoji：实心胶囊挖两道音孔 + U 形托架）。
--- 模板模式：菜单栏深浅色自适应。arc 角度已实测：0°=正上方，顺时针递增。
local function makeIcon(label)
    local ok, imgOrErr = pcall(function()
        local w = 14.6 + 7 * #label
        local c = hs.canvas.new({ x = 0, y = 0, w = w, h = 16.2 })
        -- 话筒头：实心胶囊
        c[1] = { type = "rectangle", action = "fill",
                 frame = { x = 3.96, y = 0.48, w = 6.48, h = 12.24 },
                 roundedRectRadii = { xRadius = 3.24, yRadius = 3.24 } }
        -- 音孔：compositeRule=clear 挖出两道横线（透出背景色）
        c[2] = { type = "rectangle", action = "fill", compositeRule = "clear",
                 frame = { x = 5.28, y = 4.08, w = 3.84, h = 0.72 } }
        c[3] = { type = "rectangle", action = "fill", compositeRule = "clear",
                 frame = { x = 5.28, y = 6.96, w = 3.84, h = 0.72 } }
        -- U 形托架：90°(右) → 180°(下) → 270°(左)
        c[4] = { type = "arc", action = "stroke",
                 center = { x = 7.2, y = 7.92 }, radius = 5.52,
                 startAngle = 90, endAngle = 270, arcClockwise = true,
                 arcRadii = false, strokeWidth = 0.9 }
        -- 竖杆
        c[5] = { type = "rectangle", action = "fill",
                 frame = { x = 6.66, y = 13.3, w = 1.08, h = 1.7 } }
        -- 底座
        c[6] = { type = "rectangle", action = "fill",
                 frame = { x = 3, y = 15.1, w = 8.4, h = 0.84 } }
        -- 品牌标
        c[7] = { type = "text", text = label,
                 frame = { x = 13.6, y = 2, w = 7 * #label + 4, h = 13 },
                 textFont = "Helvetica-Bold", textSize = 10,
                 textAlignment = "left", textLineBreak = "truncateMiddle" }
        local image = c:imageFromCanvas()
        c:delete()
        return image
    end)
    if ok and imgOrErr then return imgOrErr end
    if not ok then plog("!! makeIcon 失败: %s", tostring(imgOrErr)) end
    return nil
end

--- 图标刷新：品牌标 + 麦克风图形；canvas 不可用时退回文字
local function refresh()
    local name = defaultInputName()
    local label = brandLabel(name)
    local img = makeIcon(label)
    if img then
        local ok, err = pcall(menu.setIcon, menu, img, true)
        if ok then
            plog("图标已更新: %s（canvas）", label)
        else
            plog("!! setIcon 失败，回退文字: %s", tostring(err))
            menu:setTitle("🎙 " .. label)
        end
    else
        menu:setTitle("🎙 " .. label)
        plog("图标回退到文字: %s（canvas 不可用）", label)
    end
end

local function pick(name)
    -- 同名候选可能不止一个：USB 设备（如 Jieli 方案的音箱/麦）重枚举后 HAL 里会
    -- 短暂同时存在新旧两个实例，按名字找到的第一个可能是过期的。
    local candidates = {}
    for _, d in ipairs(hs.audiodevice.allInputDevices() or {}) do
        if d:name() == name then table.insert(candidates, d) end
    end
    if #candidates == 0 then
        plog("!! 找不到输入设备: %s", name)
        refresh()
        return
    end

    -- macOS 27 实测的两个坑（2026-10-24）：
    -- 1) USB 设备重枚举期间，CoreAudio 默认设备仲裁会拒绝/静默丢弃切换请求
    --    （连别的设备也切不动，几分钟后自愈）——需要多轮重试。
    -- 2) api 返回 true 也可能不生效（过期实例、虚拟设备）——必须用 uid 验证。
    -- 用同步 usleep 而非 hs.timer：菜单回调上下文里定时器行为不可靠，且点击
    -- 是低频用户操作，阻塞几百毫秒可接受。成功即返回，最坏 ~3 轮 × (0.25s×候选数+1s)。
    for round = 1, 3 do
        for i, d in ipairs(candidates) do
            local ok = d:setDefaultInputDevice()
            hs.timer.usleep(250000)
            local cur = hs.audiodevice.defaultInputDevice()
            if cur and cur:uid() and cur:uid() == d:uid() then
                plog("默认输入 -> %s（第 %d 轮第 %d 个候选成功）", name, round, i)
                refresh()
                return
            end
            plog("  第 %d 轮候选 %d (api=%s) 未生效，当前=%s", round, i, tostring(ok), defaultInputName())
        end
        if round < 3 then hs.timer.usleep(1000000) end
    end
    plog("!! 切换失败：%s，3 轮后默认仍是 %s", name, defaultInputName())
    refresh()
end

--- 传函数给 setMenu：每次点开动态构建，「✓ 当前默认」永远新鲜
local function buildMenu()
    local items = {}
    local cur = defaultInputName()
    for _, d in ipairs(hs.audiodevice.allInputDevices() or {}) do
        local name = d:name()
        local title = (name == cur and "✓ " or "    ") .. name
        if BRAND[name] then
            title = (name == cur and "✓ " or "    ") .. BRAND[name] .. "  ·  " .. name
        end
        table.insert(items, {
            title = title,
            fn = function() pick(name) end,
        })
    end
    table.insert(items, { title = "-" })
    table.insert(items, { title = "刷新", fn = refresh })
    return items
end

-- 不挂 watcher：手动模式下默认输入只被本模块改，pick() 后 refresh() 即可；
-- 标题万一过时，点开菜单时打勾标记是动态构建的，永远准确。

menu:setMenu(buildMenu)
refresh()

M._pick = pick  -- 供调试/远程触发用，无害

plog("micswitch loaded（手动模式，无周期采样）")

return M
