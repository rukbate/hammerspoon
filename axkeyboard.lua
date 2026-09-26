--- axkeyboard.lua —— 系统「辅助功能键盘」开关（蓝牙键盘断开时的应急输入）
---
--- 点击 kbswap 的菜单栏键盘图标开/关 macOS 自带的辅助功能键盘
--- （系统设置 → 辅助功能 → 键盘 → 辅助功能键盘）。
---
--- 为什么不是自绘 osk.lua：自绘面板的「点击不抢焦点」三层都堵不住——
---   * hs.canvas 的 NonactivatingPanel 掩码在 borderless NSWindow 上无效；
---   * hs.canvas:show() 内部 makeKeyAndOrderFront，打开即激活 Hammerspoon；
---   * AppKit 的点击激活晚于 mouseDown 回调返回，activate() 异步还焦点
---     永远慢一拍（v1 同步守卫、v2 延迟补发两轮真机实测都失败）。
--- 系统辅助功能键盘由系统自己管理，不抢前台焦点，本来就是这个场景的正解。
---
--- 程序化开关的三条死路（macOS 27 实测，勿重蹈）：
---   1. 没有可 open 的 bundle：/System/Library/Input Methods 下已无
---      Accessibility Keyboard.app，各框架里也没有 app/xpc/appex 形态的面板；
---   2. AccessibilityUIServer（面板现在的宿主）不注册任何 URL scheme；
---   3. `defaults write com.apple.universalaccess` 被 cfprefsd 按 entitlement
---      拒绝（沙箱内外都一样，"Could not write domain"）——但 **read 是可以的**。
--- 所以唯一可行通道：Hammerspoon 有辅助功能权限 → 用 hs.axuielement 找到
--- 「系统设置」里那个开关并 AXPress。状态判定用可读的偏好键
--- virtualKeyboardOnOff + 开关自身的 AXValue 双重核对。
---
--- 测试：.workbuddy/skills/hammerspoon-config-test/example-axkeyboard-test.lua

local M = {}

M.bundleID = "com.apple.systempreferences"
--- 打开「辅助功能 → 键盘」窗格的 deep link，按可能性排序逐个尝试
--- （第一个是新式 System Settings 扩展 id，第二个是旧式 id）。
M.deepLinks = {
    "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Keyboard",
    "x-apple.systempreferences:com.apple.preference.universalaccess?Keyboard",
}
--- 开关行的匹配文字。macOS 27 中文本地化叫「无障碍键盘」（侧边栏「无障碍」），
--- 旧版叫「辅助功能键盘」；英文是 "Accessibility Keyboard"。
M.matchTexts = { "无障碍键盘", "辅助功能键盘", "Accessibility Keyboard" }
M.pollEvery   = 0.5   -- 搜索开关的轮询间隔（秒）
M.pollMax     = 12    -- 总共搜多久放弃（秒）
M.linkRetryAt = 6     -- 第 N 次轮询仍没找到时换下一个 deep link
M.confirmDelay= 0.5   -- 按下后多久开始确认（秒）
M.confirmMax  = 6     -- 确认轮数上限（6×0.5s = 3s）

M._busy = false       -- 切换流程进行中（防连点交叉）
--- 诊断日志（每次尝试的关键动作 + 失败时整棵 AX 树 dump 都落这里）
M.logPath = "/tmp/axkeyboard-debug.log"

local function log(msg)
    if not M.logPath then return end
    local f = io.open(M.logPath, "a")
    if f then
        f:write(os.date("%F %T ") .. msg .. "\n")
        f:close()
    end
end

--- 偏好键当前值（面板开 = 1）。只读通道，写被系统拒绝。
function M.readPref()
    local out = hs.execute("defaults read com.apple.universalaccess virtualKeyboardOnOff 2>/dev/null")
    return out ~= nil and out:find("1") ~= nil
end

M.isShowing = M.readPref

local function truthy(v)
    return v == true or v == 1 or v == "1"
end

local function isSettingsRunning()
    local app = hs.application.get(M.bundleID)
    return app ~= nil and app:isRunning()
end

--------------------------------------------------------------------------------
-- AX 树搜索
--------------------------------------------------------------------------------

--- 深度优先收集后代（限深限广，设置页 AX 树可能很大）。
local function descendants(root)
    local out, stack = {}, { { el = root, d = 0 } }
    while #stack > 0 do
        local cur = table.remove(stack)
        if cur.d <= 25 and #out < 5000 then
            local kids = cur.el:attributeValue("AXChildren")
            if kids then
                for _, k in ipairs(kids) do
                    out[#out + 1] = k
                    stack[#stack + 1] = { el = k, d = cur.d + 1 }
                end
            end
        end
    end
    return out
end

local function textMatches(el)
    for _, pat in ipairs(M.matchTexts) do
        -- 注意：SwiftUI 的 StaticText 把文字放在 AXValue（不是 AXTitle），
        -- 这是真机 dump 坐实的；四个属性都查。
        for _, attr in ipairs({ "AXTitle", "AXDescription", "AXValue", "AXValueDescription", "AXHelp" }) do
            local v = el:attributeValue(attr)
            if type(v) == "string" and v:find(pat, 1, true) then return true end
        end
    end
    return false
end

local function pressable(el)
    local role = el:attributeValue("AXRole")
    return role == "AXCheckBox" or role == "AXSwitch" or role == "AXToggle"
end

--- 找「辅助功能键盘」开关。SwiftUI 设置行的常见结构是
--- AXGroup(行) > [AXStaticText("辅助功能键盘"), AXCheckBox(开关)]——文字和
--- 开关是**兄弟**；也有标题挂在行容器上、开关是后代的情况。所以按
--- 自身 → 后代 → 兄弟 → 祖先 的顺序找可按压元素。
local function resolveToggle(el)
    if pressable(el) then return el end
    -- 后代（限深 3）：标题挂在行容器上
    local kids = { el }
    for d = 1, 3 do
        local next = {}
        for _, e in ipairs(kids) do
            for _, k in ipairs(e:attributeValue("AXChildren") or {}) do
                if pressable(k) then return k end
                next[#next + 1] = k
            end
        end
        kids = next
    end
    -- 兄弟：文字和开关同属一个行容器
    local p = el:attributeValue("AXParent")
    if p then
        for _, s in ipairs(p:attributeValue("AXChildren") or {}) do
            if pressable(s) then return s end
        end
    end
    -- 祖先链兜底
    for _ = 1, 6 do
        p = p and p:attributeValue("AXParent")
        if not p then break end
        if pressable(p) then return p end
    end
    return nil
end

--- 遍历所有窗口找开关（主窗口优先）。
local function findToggle()
    local app = hs.application.get(M.bundleID)
    if not app or not app:isRunning() then return nil end
    local axApp = hs.axuielement.applicationElement(app)
    if not axApp then return nil end
    local wins = axApp:attributeValue("AXWindows") or {}
    local main = axApp:attributeValue("AXMainWindow")
    if main then table.insert(wins, 1, main) end

    for _, win in ipairs(wins or {}) do
        for _, el in ipairs(descendants(win)) do
            if textMatches(el) then
                local t = resolveToggle(el)
                if t then return t end
            end
        end
    end
    return nil
end

--- 失败诊断：把每个窗口的 AX 树（role/title/desc/value）dump 到日志。
local function dumpTree()
    if not M.logPath then return end
    log("===== AX 树 dump 开始 =====")
    local ok, err = pcall(function()
        local app = hs.application.get(M.bundleID)
        if not app then log("System Settings 未运行") return end
        local axApp = hs.axuielement.applicationElement(app)
        local wins = axApp:attributeValue("AXWindows") or {}
        local main = axApp:attributeValue("AXMainWindow")
        if main then table.insert(wins, 1, main) end
        local n = 0
        local function walk(el, depth)
            if depth > 12 or n > 3000 then return end
            n = n + 1
            local t = el:attributeValue("AXTitle")
            local d = el:attributeValue("AXDescription")
            local v = el:attributeValue("AXValue")
            if type(v) == "table" then v = "<obj>" end
            log(string.rep(" ", depth * 2) .. tostring(el:attributeValue("AXRole") or "?")
                .. (t ~= nil and (" | T=" .. tostring(t)) or "")
                .. (d ~= nil and (" | D=" .. tostring(d)) or "")
                .. (v ~= nil and (" | V=" .. tostring(v)) or ""))
            for _, k in ipairs(el:attributeValue("AXChildren") or {}) do
                walk(k, depth + 1)
            end
        end
        for wi, win in ipairs(wins or {}) do
            log("-- 窗口 " .. wi .. " --")
            walk(win, 0)
        end
    end)
    if not ok then log("dump 出错: " .. tostring(err)) end
    log("===== AX 树 dump 结束 =====")
end

--- 按压：级联 AXPress → AXPick → setAttributeValue，全程记录哪个生效。
--- SwiftUI Toggle 可能不认 AXPress；部分实现只暴露 AXPick；再不行直接写值。
local function press(el)
    -- 先记录元素声明的动作列表（诊断用）
    local okN, names = pcall(function() return el:actionNames() end)
    if okN and type(names) == "table" then
        local list = {}
        for _, a in ipairs(names) do list[#list + 1] = tostring(a) end
        log("元素支持的动作: " .. table.concat(list, ","))
    else
        local ok2, legacy = pcall(function() return el:attributeValue("AXActions") end)
        if ok2 and type(legacy) == "table" then
            local list = {}
            for _, a in ipairs(legacy) do
                list[#list + 1] = type(a) == "table" and tostring(a.name) or tostring(a)
            end
            log("元素支持的动作(legacy): " .. table.concat(list, ","))
        end
    end

    for _, action in ipairs({ "AXPress", "AXPick" }) do
        -- hs.axuielement 的动作执行方法是 performAction（无 doAction）；
        -- 返回：接受=元素对象（truthy）、拒绝=false、错误=nil+err。
        local ok, res = pcall(function() return el:performAction(action) end)
        log("performAction(" .. action .. ") → ok=" .. tostring(ok) .. " ret=" .. tostring(res))
        if ok and res ~= nil and res ~= false then
            return action
        end
    end
    -- 兜底：直写 AXValue。注意 setAttributeValue 成功返回的也是元素对象
    -- （truthy 但非 true），且 SwiftUI 开关实测不吃直写，只作最后手段。
    local val = not truthy(el:attributeValue("AXValue"))
    local okS, resS = pcall(function() return el:setAttributeValue("AXValue", val) end)
    log("setAttributeValue(AXValue=" .. tostring(val) .. ") → " .. tostring(okS) .. "/" .. tostring(resS))
    if okS and resS ~= nil and resS ~= false then return "setvalue" end
    return nil
end

--------------------------------------------------------------------------------
-- 开/关流程：发 deep link → 轮询找开关 → 按压 → 复核（带宽限与重按）
--------------------------------------------------------------------------------

function M.toggle()
    if M._busy then
        hs.alert.show("正在切换辅助功能键盘…", 1)
        return
    end
    M._busy = true
    local openedByUs = not isSettingsRunning()
    local polls, linksTried, target = 0, 0, nil
    if M.logPath then
        log("toggle 开始：pref=" .. tostring(M.readPref()) .. " openedByUs=" .. tostring(openedByUs))
    end

    local function finish(ok, msg)
        M._busy = false
        log("finish ok=" .. tostring(ok) .. " target=" .. tostring(target) .. " msg=" .. tostring(msg))
        if ok then
            hs.alert.show("辅助功能键盘已" .. (target and "打开" or "关闭"), 2)
        else
            hs.alert.show("切换辅助功能键盘失败：" .. (msg or "未知原因")
                .. (M.logPath and ("（详情见 " .. M.logPath .. "）") or ""), 4)
        end
        -- 系统设置是流程顺带拉起来的，成功后替用户关掉
        if ok and openedByUs then
            hs.timer.doAfter(0.5, function()
                local a = hs.application.get(M.bundleID)
                if a then a:kill() end
            end)
        end
    end

    local step
    step = function()
        if not M._busy then return end

        local el = findToggle()
        if el then
            -- 开关自身的 AXValue 才是系统里的真实状态（偏好键可能滞后）
            target = not truthy(el:attributeValue("AXValue"))
            log("找到开关：role=" .. tostring(el:attributeValue("AXRole"))
                .. " value=" .. tostring(el:attributeValue("AXValue"))
                .. " → target=" .. tostring(target))
            press(el)

            -- 按压后轮询确认（每轮都重找元素，防旧元素失效造成假阴性）；
            -- 超过 confirmMax 轮仍没生效才重按，避免双重切换。
            local confirms, repressed = 0, false
            local confirm
            confirm = function()
                if not M._busy then return end
                confirms = confirms + 1
                local el2 = findToggle()
                local cur = el2 and truthy(el2:attributeValue("AXValue"))
                if (cur ~= nil and cur == target) or M.readPref() == target then
                    finish(true)
                    return
                end
                if confirms < M.confirmMax then
                    hs.timer.doAfter(0.5, confirm)
                    return
                end
                if repressed then
                    dumpTree()
                    finish(false, "开关按压后状态未变化")
                    return
                end
                -- 重按一轮：先按最新状态重算目标，再走一遍按压级联
                repressed = true
                confirms = 0
                local el3 = findToggle()
                if el3 then target = not truthy(el3:attributeValue("AXValue")) end
                log("重按：target=" .. tostring(target))
                press(el3 or el)
                hs.timer.doAfter(0.5, confirm)
            end
            hs.timer.doAfter(M.confirmDelay, confirm)
            return
        end

        polls = polls + 1
        if polls == 1 and linksTried < #M.deepLinks then
            linksTried = linksTried + 1
            log("发 deep link #" .. linksTried .. ": " .. M.deepLinks[linksTried])
            hs.execute("open '" .. M.deepLinks[linksTried] .. "'")
        elseif polls >= M.linkRetryAt and linksTried < #M.deepLinks then
            linksTried = linksTried + 1
            log("没找到开关，换发 deep link #" .. linksTried .. ": " .. M.deepLinks[linksTried])
            hs.execute("open '" .. M.deepLinks[linksTried] .. "'")
        end
        if polls * M.pollEvery >= M.pollMax then
            dumpTree()
            finish(false, "系统设置里找不到「辅助功能键盘」开关（窗格未打开或界面层级变了）")
            return
        end
        hs.timer.doAfter(M.pollEvery, step)
    end
    step()
end

_G.hsAccessibilityKeyboard = M
return M
