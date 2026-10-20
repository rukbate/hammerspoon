--- kbswap.lua —— 蓝牙键盘连上时，自动把 Command 与 Option 对调（只动蓝牙键盘）
---
--- 为什么不用系统自带的「键盘 → 修饰键」：那套设置是按键盘记录的，但 macOS 里被识别成
--- Bluetooth Low Energy 的键盘（MX Keys、Lofree、多数 BLE 机械键盘）压根不会出现在
--- 那个下拉列表里，选不到。所以只能走 hidutil。
---
--- 引擎一 hidutil（默认）：
---   向「那一把蓝牙键盘」的 HID 服务下发映射表，把 ⌥(usage 0xE2) 与 ⌘(0xE3) 的
---   usage 互换。作用点在 HID 层且限定在单个设备上，所以：
---     · 内置键盘完全不受影响（它的 Transport 是 FIFO，蓝牙设备是 Bluetooth Low Energy）
---     · Option 组合键出特殊字符也是正常的（比事件层改 flags 干净）
---   代价：Apple TN2450 写明映射会随键盘服务被移除而丢失（断开重连、休眠唤醒、重启
---   都会），所以靠轮询把它重新挂上。设备重新枚举时 IORegistryEntryID 会变，用它判断。
---   另注意 UserKeyMapping 是「整个数组」属性 —— 下发会覆盖该设备上原有的映射表。
---   清空时我们只清自己那套（逐条比对），但同一把键盘上如果有别人的映射，会被我们顶掉。
---
--- 引擎二 eventtap（兜底）：
---   本文件第一版的做法，在 CGEvent 层改 flags。CGEvent 拿不到「事件来自哪台物理
---   设备」，所以是全局交换 —— 蓝牙键盘连着时内置键盘也会一起换。只在 hidutil 不灵时用。
---
--- 热键 ⌃⌥⌘K：hidutil 引擎在「跟随蓝牙键盘 ⇄ 停用」间切换；
---            eventtap 引擎是「自动 → 强制交换 → 强制关闭」三态。
--- 菜单栏图标：实心键盘 = 蓝牙键盘在线，斜杠键盘 = 不在线。
---点击 = 打开/关闭自绘屏幕键盘（osk.lua，蓝牙键盘断开时的应急输入）。
---      系统「无障碍键盘」方案（axkeyboard.lua）已降级为备用，未在 init.lua 中加载。
--- 切换 ⌘/⌥ 交换模式只走 ⌃⌥⌘K。
--- 提示：蓝牙键盘连上/断开时弹 "Keyboard connected / disconnected"（措辞见
---       M.msgConnected / M.msgDisconnected）。

local M = {}

--------------------------------------------------------------------------------
-- 配置
--------------------------------------------------------------------------------

M.engine       = "hidutil"  -- "hidutil" 只换蓝牙键盘 | "eventtap" 全局交换（旧方案，兜底）
M.mode         = "auto"     -- "auto" 跟随蓝牙键盘 | "off" 停用（eventtap 另有 "on" 强制交换）
--- 状态变迁日志。**只记变化**（设备出现/消失、下发成败、读回发现映射被收走），
--- 不记每轮 —— 轮询 2 秒一次，记全程一天就是几万行。防呆是取巧：打开调试输出的人
--- 自己看得见，落盘的这份是给「事情已经过去、只能看日志」准备的。
--- 为什么放仓库里而不是 /tmp：Lin 找不到的日志等于没写（2026-10-05 的教训）。
--- 日志路径可注入（M.logPath），测试里要存旧值再还原。
M.logPath    = (os.getenv("HOME") or ".") .. "/.hammerspoon/.workbuddy/kbswap.log"
M.logMaxBytes = 512 * 1024    -- 超了就整份重写。诊断日志不需要跨天历史

--- 写一行状态变迁日志。**绝不能抛**：诊断函数把功能搞挂是最讽刺的死法
--- （2026-10-05 在 osk 的 diag() 上真发生过）。所以整段 pcall。
local function plog(fmt, ...)
    if not M.logPath then return end
    -- 格式化放在 pcall 外面：`...`（变长参数）在非 vararg 函数里不可用。
    -- 顺带满足「诊断绝不该抛」——格式化失败就把 fmt 原样写进去。
    local msg = tostring(fmt)
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, tostring(fmt), ...)
        if ok then msg = formatted end
    end
    pcall(function()
        -- 年份必须带上：只写「10-17」会被读成 2010 年，排查时先要愣一下（Lin 2026-10-17）
        local stamp = os.date("%Y-%m-%d %H:%M:%S")
        -- 超限先清空：append 打开时拿不到大小，退而用「写完再判」
        local f = io.open(M.logPath, "a")
        if not f then return end
        f:write(stamp, "  ", msg, "\n")
        f:close()
        local probe = io.open(M.logPath, "r")
        if probe then
            local big = #probe:read("*a") > M.logMaxBytes
            probe:close()
            if big then
                local w = io.open(M.logPath, "w")
                if w then
                    w:write(stamp, "  （日志超限，已截断）\n")
                    w:close()
                end
            end
        end
    end)
end

M._plog = plog   -- 暴露给测试与排障（直接验证「格式化失败也不抛」这类边界）

M.pollInterval = 2          -- 检测间隔（秒）。5 秒偏慢：蓝牙键盘重连后的空窗体感明显
M.profilerTTL  = 30         -- system_profiler 结果的缓存时间（秒），它是唯一慢的一环
M.reassert     = 60         -- ⚠️ 已不再参与判定（2026-10-17）。原为「每隔多久重挂一次
                             -- 映射」的兜底，现由每轮读回验证取代。留着只为兼容旧配置。
M.swapRight    = true       -- 是否连右侧 ⌥/⌘（usage 0xE6/0xE7）一起换
M.notify       = true       -- 蓝牙键盘连接/断开时弹提示
M.msgConnected    = "Keyboard connected: %s"    -- %s = 设备名（拿不到时自动去掉分隔符）
M.msgDisconnected = "Keyboard disconnected"
M.debug        = false      -- 打开后每次下发/失败都打印到 Console
M.hotkeyMods   = { "ctrl", "alt", "cmd" }
M.hotkeyKey    = "k"

M.showMenubar         = true      -- 菜单栏图标（见文件头）
M.menubarAutosaveName = "KbSwap"  -- 让 macOS 记住 ⌘ 拖动后的图标位置

M.active       = false      -- 当前是否真的挂上了交换（只读）
M.targets      = {}         -- 最近一次识别到的蓝牙键盘（只读）
M.lastDevice   = nil        -- 最近一次识别到的蓝牙键盘名（只读）
M.lastError    = nil        -- 最近一次失败原因（只读）

local HIDUTIL  = "/usr/bin/hidutil"
local PROFILER = "/usr/sbin/system_profiler"
local PROFILER_ARGS = { "SPBluetoothDataType", "-detailLevel", "mini" }

--- HID Keyboard/Keypad page 的用法码。左 ⌥/⌘ 是 0xE2/0xE3，右 ⌥/⌘ 是 0xE6/0xE7。
local USAGE_LALT, USAGE_LGUI = 0x7000000E2, 0x7000000E3
local USAGE_RALT, USAGE_RGUI = 0x7000000E6, 0x7000000E7

--- 0x700000000 | usage。hidutil 读回来的值是十进制，校验用这组。
local D_LALT, D_LGUI = 30064771298, 30064771299
local D_RALT, D_RGUI = 30064771302, 30064771303

local EMPTY_MAP = '{"UserKeyMapping":[]}'

local TYPES   = hs.eventtap.event.types
local WATCHED = { TYPES.flagsChanged, TYPES.keyDown, TYPES.keyUp }

local CYCLE = {
    hidutil = { auto = "off", off = "auto" },
    eventtap = { auto = "on", on = "off", off = "auto" },
}
local MODE_LABEL = {
    hidutil = { auto = "跟随蓝牙键盘", off = "已停用" },
    eventtap = { auto = "自动跟随蓝牙键盘", on = "强制交换（全局）", off = "强制关闭" },
}

--------------------------------------------------------------------------------
-- 一、小工具
--------------------------------------------------------------------------------

--- 去掉空白和标点做名字比对，保留字母数字与非 ASCII 字节（中文设备名不能被切掉）。
--- @param s string
--- @return string
local function norm(s)
    return (tostring(s):lower():gsub("[%s%p]", ""))
end

--- @param s string
--- @return string 带引号的 JSON 字符串
local function jsonStr(s)
    return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

--- 包成 shell 单引号字符串（内部单引号按 '...'\''...' 转义）。
--- @param s string
--- @return string
local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- 读回的输出里必须出现「这台设备自己的」RegistryID（hidutil 读回来是十六进制）。
--- 为什么非查不可：兜底的 Transport 匹配会命中同一传输下的所有设备（比如蓝牙鼠标），
--- 只看「值对不对」的话，鼠标被写上映射也会被判成功 —— 于是报告已交换、而键盘其实没换。
--- 拿不到 regid 的设备只能退化成不做这一层校验。
--- @param out string
--- @param t table 设备描述
--- @return boolean
local function hitDevice(out, t)
    if type(out) ~= "string" or not out:find("%S") then return false end
    if #t.regids == 0 then return true end

    -- 归一化后再找（2026-10-18 加）：输出格式漂移（大写 / 0x 前缀）时
    -- 原样小写比对会恒假，症状是「映射照常每轮写上，但状态行说没挂上」。
    -- 做法：整体小写 + 删掉所有 "0x" 子串。十进制数值只含 0-9（没有 x），
    -- 不受影响；十六进制 regid 无论大小写、带不带前缀都落到同一格式。
    local flat = " " .. out:lower():gsub("0x", ""):gsub("%s+", " ") .. " "
    for _, regid in ipairs(t.regids) do
        local hex = string.format("%x", tonumber(regid) or 0)
        if flat:find(" " .. hex .. " ", 1, true) then return true end
    end
    return false
end

--- @param out string
--- @param want table 十进制数值列表
--- @return boolean 是否全部出现
local function hasAll(out, want)
    if type(out) ~= "string" then return false end
    for _, d in ipairs(want) do
        if not out:find(tostring(d), 1, true) then return false end
    end
    return true
end

--- 把 hidutil 读回来的属性文本解析成 src/dst 配对。
--- 单条形如 `{ HIDKeyboardModifierMappingDst = 30064771298; ...Src = 30064771299; }`。
--- @param out string
--- @return table 形如 { {src=..., dst=...}, ... }
local function parseMapping(out)
    local list = {}
    for block in tostring(out):gmatch("{[^}]*}") do
        local src = block:match("HIDKeyboardModifierMappingSrc%s*=%s*(%d+)")
        local dst = block:match("HIDKeyboardModifierMappingDst%s*=%s*(%d+)")
        if src and dst then
            list[#list + 1] = { src = tonumber(src), dst = tonumber(dst) }
        end
    end
    return list
end

--- 「我们可能下过的」全部配对 —— 左右两对都算，与当前 swapRight 无关。
--- @return table 形如 { ["src>dst"] = true }
local function ourPairs()
    local set = {}
    set[D_LGUI .. ">" .. D_LALT] = true
    set[D_LALT .. ">" .. D_LGUI] = true
    set[D_RGUI .. ">" .. D_RALT] = true
    set[D_RALT .. ">" .. D_RGUI] = true
    return set
end

--- 这份映射是不是「我们这套」：每条 src/dst 都在我们的配对表里，且至少有一条。
--- 为什么不直接查数值是否出现：上一轮如果只换了左侧（swapRight 改动过），
--- 读回里就没有右侧那两个数值，用「全包含」会漏判、残留清不掉。
--- 反过来「逐条都属于我们」既能认出残留，也不会误删用户自己设的其它映射。
--- @param out string
--- @return boolean
local function isOurMapping(out)
    local list = parseMapping(out)
    if #list == 0 then return false end

    local set = ourPairs()
    for _, e in ipairs(list) do
        if not set[e.src .. ">" .. e.dst] then return false end
    end
    return true
end

--- 本次交换涉及的十进制值（读回校验用）。
local function expectedDecimals()
    local t = { D_LGUI, D_LALT }
    if M.swapRight then
        t[#t + 1] = D_RGUI
        t[#t + 1] = D_RALT
    end
    return t
end

--- UserKeyMapping 的 JSON 主体。
--- src/dst 必须成对出现，只写单向的话另一侧不会跟着换。
--- @return string
local function mappingPayload()
    local list = {
        { USAGE_LGUI, USAGE_LALT },
        { USAGE_LALT, USAGE_LGUI },
    }
    if M.swapRight then
        list[#list + 1] = { USAGE_RGUI, USAGE_RALT }
        list[#list + 1] = { USAGE_RALT, USAGE_RGUI }
    end

    local parts = {}
    for _, pair in ipairs(list) do
        parts[#parts + 1] = string.format(
            '{"HIDKeyboardModifierMappingSrc":0x%X,"HIDKeyboardModifierMappingDst":0x%X}',
            pair[1], pair[2])
    end
    return '{"UserKeyMapping":[' .. table.concat(parts, ",") .. ']}'
end

--------------------------------------------------------------------------------
-- 二、hidutil 调用
--------------------------------------------------------------------------------

--- 跑一次 hidutil property。setJSON 与 getKey 至少给一个。
--- @param match string|nil --matching 的 JSON
--- @param setJSON string|nil --set 的内容
--- @param getKey string|nil --get 的属性名
--- @return string output, boolean ok, number rc
local function runHidutil(match, setJSON, getKey)
    local cmd = HIDUTIL .. " property"
    if match then cmd = cmd .. " --matching " .. shq(match) end
    if setJSON then cmd = cmd .. " --set " .. shq(setJSON) end
    if getKey then cmd = cmd .. " --get " .. shq(getKey) end
    cmd = cmd .. " 2>&1"

    if M.debug then print("[kbswap] $ " .. cmd) end

    local out, ok, _, rc = hs.execute(cmd)
    -- hs.execute 在不同版本上返回值个数略有出入，稳妥点直接把第 2/4 个都取出来
    if ok == nil then ok = (rc == nil and out ~= nil and out ~= "") or rc == 0 end
    return tostring(out or ""), (ok and true or false), tonumber(rc) or (ok and 0 or 1)
end

--- 针对一个设备依次尝试的匹配方式：从精确到宽泛。
--- hidutil 的匹配字典支持 VendorID/ProductID/Product/Transport/PrimaryUsagePage/PrimaryUsage。
--- 实测这三种在本机都能命中，列成梯子是为了万一某个字段在特定键盘上没上报。
--- @param t table 设备描述
--- @return table 匹配 JSON 字符串列表
local function matchersFor(t)
    local list = {}
    if t.vid and t.pid then
        list[#list + 1] = string.format(
            '{"VendorID":%d,"ProductID":%d,"PrimaryUsagePage":1,"PrimaryUsage":6}', t.vid, t.pid)
        list[#list + 1] = string.format('{"VendorID":%d,"ProductID":%d}', t.vid, t.pid)
    end
    if t.name then
        list[#list + 1] = string.format(
            '{"Product":%s,"PrimaryUsagePage":1,"PrimaryUsage":6}', jsonStr(t.name))
    end
    if t.transport then
        list[#list + 1] = string.format(
            '{"Transport":%s,"PrimaryUsagePage":1,"PrimaryUsage":6}', jsonStr(t.transport))
    end
    return list
end

--- 蓝牙键盘的两条兜底匹配（覆盖 BR/EDR 与 BLE 两种传输名）。
--- @return table
local function transportMatchers()
    return {
        '{"Transport":"Bluetooth Low Energy","PrimaryUsagePage":1,"PrimaryUsage":6}',
        '{"Transport":"Bluetooth","PrimaryUsagePage":1,"PrimaryUsage":6}',
    }
end

--------------------------------------------------------------------------------
-- 三、设备发现
--------------------------------------------------------------------------------

--- 解析 `hidutil list --ndjson`。
--- 只挑「键盘 usage（page 1 / usage 6）+ 传输名里带 Bluetooth」的条目。
--- @param text string
--- @return table 条目列表
local function parseHidList(text)
    local out = {}
    for line in tostring(text):gmatch("[^\r\n]+") do
        local page  = tonumber(line:match('"PrimaryUsagePage":%s*(-?%d+)'))
        local usage = tonumber(line:match('"PrimaryUsage":%s*(-?%d+)'))

        if page == 1 and usage == 6 then
            local transport = line:match('"Transport":%s*"([^"]*)"')
            if transport and transport:lower():find("bluetooth", 1, true) then
                out[#out + 1] = {
                    name      = line:match('"Product":%s*"([^"]*)"'),
                    vid       = tonumber(line:match('"VendorID":%s*(-?%d+)')),
                    pid       = tonumber(line:match('"ProductID":%s*(-?%d+)')),
                    transport = transport,
                    regid     = line:match('"IORegistryEntryID":%s*(%d+)'),
                }
            end
        end
    end
    return out
end

--- 同一把设备会以多个服务出现（键盘一个、多媒体键一个），按 VID/PID 归并，
--- 把各自的 IORegistryEntryID 收集起来当「重新枚举」的指纹。
--- @param items table parseHidList 的结果
--- @return table 设备列表
local function aggregate(items)
    local byKey, order = {}, {}
    for _, d in ipairs(items) do
        local key = (d.vid and d.pid) and (d.vid .. ":" .. d.pid) or ("name:" .. tostring(d.name))
        if not byKey[key] then
            byKey[key] = {
                key       = key,
                name      = d.name,
                vid       = d.vid,
                pid       = d.pid,
                transport = d.transport,
                regids    = {},
                _seen     = {},
            }
            order[#order + 1] = key
        end
        local t = byKey[key]
        t.name = t.name or d.name
        t.transport = t.transport or d.transport
        if d.regid and not t._seen[d.regid] then
            t._seen[d.regid] = true
            t.regids[#t.regids + 1] = d.regid
        end
    end

    local out = {}
    for _, key in ipairs(order) do
        local t = byKey[key]
        table.sort(t.regids)                       -- 顺序稳定，指纹才可比
        t.sig = table.concat(t.regids, ",")
        t._seen = nil
        out[#out + 1] = t
    end
    return out
end

--- system_profiler 的设备分类缓存。它是唯一慢的一环（约 0.2s），
--- 只在需要时异步刷新：eventtap 引擎每轮都刷，hidutil 引擎按 profilerTTL 刷。
--- `failed` 记 task 失败次数：tickHidutil 靠它区分「还没回来」（继续等）和
--- 「回来了但拿不到」（按老逻辑走，宁可换错也不漏键盘）。
--- @type table
local profilerCache = { at = 0, byName = {}, keyboardNames = {}, pending = false, failed = 0 }

--- 解析 system_profiler 的蓝牙设备树。
--- 输出形如（缩进代表层级，设备名行以冒号结尾）：
---       Connected:
---           MX Anywhere 2S:
---               Minor Type: Mouse
---       Not Connected:
---           Flow84@Lofree:
---               Minor Type: Keyboard
--- 用缩进深度判断层级，不写死空格数，省得系统改格式就崩。
--- @param text string
--- @return table 形如 { {name=..., minorType=..., connected=true}, ... }
local function parseBluetooth(text)
    local devices, inConnected = {}, false
    local segIndent, devIndent, cur = nil, nil, nil

    for line in tostring(text):gmatch("[^\r\n]+") do
        local indent, body = line:match("^(%s*)(.-)%s*$")

        if body ~= "" then
            local depth = #indent

            if body:sub(-1) == ":" then
                local label = body:sub(1, -2)

                if label == "Connected" or label == "Not Connected" then
                    inConnected = (label == "Connected")
                    segIndent, devIndent, cur = depth, nil, nil
                elseif inConnected and segIndent and depth > segIndent then
                    -- 段内比段标题更深、且不比上一个设备名更深的行 = 新设备
                    if devIndent == nil or depth <= devIndent then
                        devIndent = depth
                        cur = { name = label, connected = true }
                        devices[#devices + 1] = cur
                    end
                end
            elseif inConnected and cur and body:match("^Minor Type:") then
                cur.minorType = body:match("^Minor Type:%s*(.-)%s*$")
            end
        end
    end

    return devices
end

--- @param text string system_profiler 输出
--- @return string|nil 已连接的蓝牙键盘名
local function findConnectedKeyboard(text)
    for _, d in ipairs(parseBluetooth(text)) do
        if d.minorType == "Keyboard" then return d.name end
    end
    return nil
end

--- 异步刷新分类缓存。system_profiler 要 0.2 秒，绝不放在主线程上。
--- @param force boolean 忽略 TTL 强制刷新
--- @return boolean 是否发起了刷新
local function refreshProfiler(force)
    if profilerCache.pending then return false end
    if not force and (os.time() - profilerCache.at) < M.profilerTTL then return false end

    profilerCache.pending = true
    local task = hs.task.new(PROFILER, function(code, out)
        profilerCache.pending = false
        if code ~= 0 or not out then
            -- 拿不到分类信息不算致命：宁可多认几个设备，也不漏掉真键盘
            -- 记一次失败：tickHidutil 靠它决定「还要不要继续等缓存」
            -- （无限等下去 = 永远不交换，比换错更糟）。
            profilerCache.failed = (profilerCache.failed or 0) + 1
            if M.debug then print("[kbswap] system_profiler 失败，退出码 " .. tostring(code)) end
            return
        end

        local byName, keyboards = {}, {}
        for _, d in ipairs(parseBluetooth(out)) do
            if d.minorType then byName[norm(d.name)] = d.minorType end
            if d.minorType == "Keyboard" then keyboards[#keyboards + 1] = d.name end
        end
        profilerCache.byName, profilerCache.keyboardNames = byName, keyboards
        profilerCache.at = os.time()
        M.lastDevice = keyboards[1] or M.lastDevice
    end, PROFILER_ARGS)

    -- hs.task.new 在进程创建失败时返回 nil（2026-10-19 加）：直接 :start() 会抛
    if not task then
        profilerCache.pending = false
        profilerCache.failed = (profilerCache.failed or 0) + 1
        if M.debug then print("[kbswap] system_profiler 进程创建失败（task 为 nil）") end
        return false
    end

    task:start()
    return true
end

--- 把 HID 里的候选设备过滤成「确实是键盘」的目标。
--- 判断依据：HID 里带键盘 usage 的蓝牙设备中，排除掉 system_profiler 明确标成非键盘的
--- （典型就是罗技鼠标 —— 它的 HID 里带 keyboard usage，会被误判成键盘）。
--- 分类信息缺失时保留设备，宁可换错也不要不换。
--- @param candidates table
--- @return table
local function filterTargets(candidates)
    local out = {}
    for _, t in ipairs(candidates) do
        local minor = t.name and profilerCache.byName[norm(t.name)]
        if not (minor and minor ~= "Keyboard") then
            out[#out + 1] = t
        elseif M.debug then
            print("[kbswap] 跳过非键盘设备：" .. tostring(t.name) .. "（" .. minor .. "）")
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- 四、下发与撤销
--------------------------------------------------------------------------------

--- key -> { target, matcher, sig }
local applied = {}

--- 按设备把 hidutil 读回的属性文本拆开，收集每台设备上的**十进制数值**。
--- 为什么要拆：Transport 兜底匹配会同时命中键盘和蓝牙鼠标，读回的输出里两台设备
--- 各带一份映射。只看「值在不在」会把**鼠标**的映射当成键盘的 —— 键盘其实没挂上，
--- 却被判成「还挂着」，于是永远不重挂。
--- ⚠️ 行级解析里 Src 和 Dst 是**两行**（`{ ...Dst = x; ...Src = y; }`），
--- 所以不能沿用 parseMapping 那种 `if src and dst` 的配对写法 —— 它永远为假，
--- 一条都收集不到（2026-10-17 踩过，症状是「读回永远判定为没挂上」→ 每轮重复下发）。
--- @param out string
--- @return table 形如 { ["1000256da"] = { 30064771299, 30064771298, ... }, ... }
--- 按设备把 hidutil 读回的属性文本拆开。
--- 为什么要拆：Transport 兜底匹配会同时命中键盘和蓝牙鼠标，读回的输出里两台设备
--- 各带一份映射。只看「值在不在」会把**鼠标**的映射当成键盘的 —— 键盘其实没挂上，
--- 却被判成「还挂着」，于是永远不重挂。
--- 输出形如：`1000256da   UserKeyMapping   ( { .. } )`，空映射是 `( )`。
---
--- **归一化**（2026-10-18 加）：regid 统一成「小写、无 0x 前缀」再当 key。
--- macOS 更新改了输出格式（大写十六进制 / 加 0x 前缀）不会让交换失效，但会让
--- deviceOK 恒假 → applyTarget 永远记不上 → 状态行谎报 false、每 2 秒刷一条错误。
--- 格式漂移时日志里也看不出原因，所以 applyTarget 的失败路径会把原始输出截一段
--- 写进 plog（见那边）。
--- @param out string
--- @return table 形如 { ["1000256da"] = { {src=..., dst=...}, ... }, ... }
local function parseMappingByDevice(out)
    local byDev, cur = {}, nil
    for line in tostring(out):gmatch("[^\r\n]+") do
        -- lower + 容忍 0x 前缀：查询端（hitDevice / mappingStillOn）用的 key 是
        -- string.format("%x", regid)（小写无前缀），两边必须落在同一格式上。
        local raw = line:lower():match("^%s*(0?x?[%x]+)%s+userkeymapping")
        local regid = raw and raw:gsub("^0x", "") or nil
        if regid then
            cur = byDev[regid] or {}
            byDev[regid] = cur
        elseif cur then
            local v = line:match("HIDKeyboardModifierMapping%a+%s*=%s*(%d+)")
            if v then cur[#cur + 1] = tonumber(v) end
            -- **只有「整行只有一个 )」才是段收尾**。旧判据是 `find(")")`，
            -- 它会把每对映射的收尾行 `    },` 也当成段结束 —— 于是每台设备
            -- 只收得到**第一对**的值，第二对起全部丢失（2026-10-18 修）。
            -- 后果：allOurs 漏检第二对（别人的映射混在后面也发现不了）、
            -- mappingStillOn 的「一条都不能多」检查形同虚设。
            -- ⚠️ 模式里的 `)` 必须转义成 `%)`：Lua 把它当捕获括号，
            -- 未配对直接 "invalid pattern capture"（本轮踩到）。
            if line:match("^%s*%)%s*$") then cur = nil end
        end
    end
    return byDev
end

--- 这把设备上我们自己那套映射现在还在吗？
--- ⚠️ 必须按「这台设备自己的 RegistryID」逐台查：Transport 兜底匹配一次会命中
--- 同一传输下的所有蓝牙设备，读回的输出里混着别人的映射。
--- @param rec table applied 里的记录
--- @return boolean
local function mappingStillOn(rec)
    local out = runHidutil(rec.matcher, nil, "UserKeyMapping")
    local byDev = parseMappingByDevice(out)

    local want, need = {}, 0
    for _, v in ipairs(expectedDecimals()) do
        want[v] = true
        need = need + 1
    end

    for _, regid in ipairs(rec.target.regids or {}) do
        local vals = byDev[string.format("%x", tonumber(regid) or 0)]
        if vals and #vals > 0 then
            local seen, cnt, allOurs = {}, 0, true
            for _, v in ipairs(vals) do
                if not seen[v] then seen[v] = true; cnt = cnt + 1 end
            end
            for v in pairs(seen) do
                if not want[v] then allOurs = false end
            end
            -- 一条都不能多（多的说明这是别人设的映射），一条都不能少
            if allOurs and cnt >= need then return true end
        end
    end

    plog("读回发现 %s 上的映射不在了（键盘重连 / 休眠唤醒都会这样）→ 本轮立刻重挂",
        tostring(rec.target.name))
    return false
end

--- 给一把键盘挂上交换。
--- ⚠️ 判定「已经挂好」只有一个依据：**把设备上的映射读回来核对**。
--- 它取代了原来的时间判据（`sig 没变 + 距上次不到 reassert`），那个判据会错满
--- reassert（60 秒）——映射随键盘服务移除而丢失，而同一把键盘重连后的
--- IORegistryEntryID 常常一模一样，于是「已经下发过」长期成立不了。
--- 读回也取代了 reassert 的兜底重挂：**每 2 秒就核对一次**，休眠唤醒这类场景在
--- 两秒内就会被发现并重挂，没必要再每分钟无谓地重写一遍 HID 属性
--- （2026-10-17 实测：那每 60 秒一次的「已下发」让日志全是噪音）。
--- @param t table 设备描述
--- @return boolean 是否处于「已挂上」状态
local function applyTarget(t)
    local rec = applied[t.key]
    if rec and rec.sig == t.sig and mappingStillOn(rec) then
        return true
    end

    local payload = mappingPayload()
    local want = expectedDecimals()
    local lastOut = nil            -- 最后一次读回，失败时写进日志（排障用）

    for _, m in ipairs(matchersFor(t)) do
        local out, ok = runHidutil(m, payload)
        lastOut = out
        local valueOK, deviceOK = hasAll(out, want), hitDevice(out, t)

        -- hidutil 的 --set 会把设置后的属性打印出来，直接拿它当读回校验，省一次进程。
        -- 两层都要过：值里有我们那套 src/dst，且命中的是这台设备自己的 RegistryID。
        if ok and valueOK and deviceOK then
            applied[t.key] = { target = t, matcher = m, sig = t.sig }
            M.lastError = nil
            M.lastFailDetail = nil   -- 成功了，失败去重的记忆也清掉
            plog("已下发 ⇄ -> %s（%s）", tostring(t.name), m)
            if M.debug then
                print(string.format("[kbswap] 已下发 -> %s（%s）", tostring(t.name), m))
            end
            return true
        end

        if M.debug then
            local why = (not ok) and "命令失败"
                or (not valueOK) and "值没落上"
                or "命中的是别的设备"
            print(string.format("[kbswap] 匹配失败（%s）：%s", why, m))
        end
    end

    M.lastError = "无法向 " .. tostring(t.name) .. " 下发映射"
    -- **失败路径把读回内容带进日志**（2026-10-18 加）：hidutil 输出格式漂移时
    -- （macOS 升级改了 regid 写法之类），映射照样每轮写上、只是校验认不出，
    -- 没有这段原始输出，日志里只有干巴巴一句「无法下发」，看不出是格式问题。
    -- **同一台设备连续失败的输出几乎不变**（2026-10-19 加）：每 2 秒打一遍
    -- 等于刷屏，内容没变就只重试不吭声；变了（读回内容漂移）才再打。
    local detail = string.format("%s（本轮失败，下一轮重试）；最后一条命令读回：%s",
        M.lastError, tostring(lastOut):sub(1, 300))
    if M.lastFailDetail ~= detail then
        M.lastFailDetail = detail
        plog("%s", detail)
        print("[kbswap] " .. M.lastError)
    end
    return false
end

--- 读回文本里**每一台设备、每一条配对**都是我们这套吗？
--- 比 isOurMapping 严：isOurMapping 是「至少有一条是我们的」，用它当清除前的
--- 闸门会误伤 —— 键盘上有我们的 + 鼠标上有用户自己的，混合读回同样满足
--- 「至少一条是我们的」，于是清除动作把鼠标上用户自己的映射也清掉了。
--- 注意这里按「十进制数值」判（parseMappingByDevice 收的就是数值列表）：
--- 每台设备上的每个值都必须落在 expectedDecimals() 里。
--- @param out string
--- @return boolean
local function allOurs(out)
    local byDev = parseMappingByDevice(out)
    local want = {}
    for _, v in ipairs(expectedDecimals()) do want[v] = true end
    for _, list in pairs(byDev) do
        for _, v in ipairs(list) do
            if not want[v] then return false end
        end
    end
    return true
end

--- 撤销我们自己的映射。只清 applied 里记着的那些 —— 不碰设备上其它来源的映射。
---
--- ⚠️ **不能直接拿 rec.matcher 清**（2026-10-18 修）：键盘固件上报名对不上时，
--- 当年下发用的 matcher 会退化到 Transport 兜底，那种 matcher 命中同一 BLE
--- 传输下**所有** keyboard usage 设备 —— 包括用户自己用 hidutil 设过映射的
--- 罗技鼠标。UserKeyMapping 是整数组属性，一条 `--set 空数组` 全部抹掉。
--- 对策：按目标重新生成候选（VID/PID → Product → Transport，精确的在前），
--- 精确 matcher 直接清；只有落到 Transport 兜底时才先读回，确认读到的
--- **全都是我们这套**才清，否则宁可不清（留一行日志，用户可手动处理）。
local function clearAll()
    for _, rec in pairs(applied) do
        local done = false
        for _, m in ipairs(matchersFor(rec.target)) do
            local risky = m:find('"Transport"') ~= nil
            if risky then
                local outR = runHidutil(m, nil, "UserKeyMapping")
                if not allOurs(outR) then
                    -- 读回里混着别人的映射：这个 matcher 清下去会误伤。
                    -- Transport 是候选列表最后一个，循环到此结束。
                    plog("撤销 %s 时跳过兜底匹配（读回里混着别人的映射，清了会误伤同传输的其它设备）：%s",
                        tostring(rec.target.name), m)
                    if M.debug then
                        print("[kbswap] 跳过兜底撤销（读回不纯）：" .. m)
                    end
                else
                    local _, ok = runHidutil(m, EMPTY_MAP)
                    done = ok and true or false
                    if M.debug then
                        print(string.format("[kbswap] 已撤销 %s（%s，ok=%s）",
                            tostring(rec.target.name), m, tostring(ok)))
                    end
                    if done then break end
                end
            else
                -- 精确 matcher（VID/PID 或 Product）只可能命中这一台，直接清
                local out, ok = runHidutil(m, EMPTY_MAP)
                if ok and hitDevice(out, rec.target) then
                    done = true
                    if M.debug then
                        print(string.format("[kbswap] 已撤销 %s（%s）",
                            tostring(rec.target.name), m))
                    end
                    break
                end
            end
        end
        if not done then M.lastError = "撤销失败：" .. tostring(rec.target.name) end
    end
    applied = {}
end

--- 清掉「我们自己下的」残留映射。
--- 场景：改了配置重载 Hammerspoon，上一个实例的 applied 记录没了，但设备上还挂着映射。
--- 先读回、逐条确认那是我们这套配对才清 —— 免得把用户自己用 hidutil 设的映射误删。
--- ⚠️ 闸门必须是 allOurs（每台每套都是我们的）而不是 isOurMapping（至少一条）：
--- 后者在「键盘有我们的 + 鼠标有用户的」混合读回下同样为真，清下去就误伤
--- （2026-10-18 修，和 clearAll 同一个病根）。
local function clearStale()
    for _, m in ipairs(transportMatchers()) do
        local out = runHidutil(m, nil, "UserKeyMapping")
        if allOurs(out) then
            runHidutil(m, EMPTY_MAP)
            if M.debug then print("[kbswap] 清掉残留映射：" .. m) end
        end
    end
end

--------------------------------------------------------------------------------
-- 五、eventtap 引擎（兜底）
--------------------------------------------------------------------------------

local FLAG_MASKS = hs.eventtap.event.rawFlagMasks or {}
local MASK_CMD   = FLAG_MASKS.command    -- NX_COMMANDMASK   0x00100000
local MASK_ALT   = FLAG_MASKS.alternate  -- NX_ALTERNATEMASK 0x00080000

--- Lua 5.3+ 才有位运算符（Hammerspoon 跑的是 5.4.7，这里只是兜个底）。
local HAS_BITOPS = (function()
    local chunk = load("return 1 & 1")
    return chunk ~= nil and chunk() == 1
end)()

--- 首选：直接对事件的原始 flags 整数做位交换。
--- 只动 cmd / alt 这两位，fn、numericPad、以及 deviceLeftCommand 这类
--- 「左/右修饰键」位全部原样留着。
--- setFlags() 是 CGEventSetFlags 整体覆盖，会把这些位一并抹掉，所以不用它当主路径。
--- @param e userdata hs.eventtap.event
--- @return userdata|nil 交换后的事件；无需交换时 nil
local function swapViaRawFlags(e)
    local raw = e:rawFlags()
    if type(raw) ~= "number" then return nil end
    local raw0 = raw

    local hasCmd = (raw & MASK_CMD) ~= 0
    local hasAlt = (raw & MASK_ALT) ~= 0
    -- 两个都按或都没按，换了等于没换
    if hasCmd == hasAlt then return nil end

    raw = raw & ~(MASK_CMD | MASK_ALT)
    if hasCmd then raw = raw | MASK_ALT end
    if hasAlt then raw = raw | MASK_CMD end

    e:rawFlags(raw)
    if M.debug then
        print(string.format("[kbswap] flags 0x%X -> 0x%X", raw0, raw))
    end
    return e
end

--- 回退：用 getFlags/setFlags 的表形式。
--- getFlags() 只为「按下的」修饰键放字段，没按的键是 nil，所以
--- `f.cmd, f.alt = f.alt, f.cmd` 正好把「没按」的那一侧置回 nil。
--- @param e userdata hs.eventtap.event
--- @return userdata|nil
local function swapViaSetFlags(e)
    local f = e:getFlags()
    if type(f) ~= "table" then return nil end
    if f.cmd == f.alt then return nil end

    f.cmd, f.alt = f.alt, f.cmd
    e:setFlags(f)
    if M.debug then
        print(string.format("[kbswap] setFlags -> cmd=%s alt=%s", tostring(f.cmd), tostring(f.alt)))
    end
    return e
end

--- @param e userdata hs.eventtap.event
--- @return userdata|nil
local function swapModifiers(e)
    if HAS_BITOPS and MASK_CMD and MASK_ALT then
        -- rawFlags 是官方标注的 experimental 方法，万一这版行为有出入就落回表形式
        local ok, result = pcall(swapViaRawFlags, e)
        if ok and result ~= nil then return result end
    end
    return swapViaSetFlags(e)
end

--- eventtap 回调。返回 false, event 表示「用这个事件替换原事件继续往下传」，
--- 而不是 true（吞掉后自己 post）—— 这样 keycode、字符、重复标志、时间戳
--- 这些字段全都原样保留，只动了修饰键。
local function onEvent(e)
    -- 双保险：tap 只在交换态启动，这里再按 M.active 设一道闸 —— 就算有事件
    -- 漏进来（或状态切换瞬间），关闭/待机时也绝不碰事件。
    -- **还要按引擎设一道闸**（2026-10-18 修）：从 eventtap 切回 hidutil 时，
    -- 旧 tap 不会自己停（tick 的清理只在切换那一轮生效，手动改 M.engine 的
    -- 窗口期内 tap 还活着）。onEvent 只查 M.active 的话，这段时间里内置键盘
    -- 会被 eventtap 全局交换 —— 而状态行显示的是 hidutil 模式，用户完全
    -- 看不出叠加。M.engine 是运行时改的（兜底试用场景），这道闸必须常在。
    if M.engine ~= "eventtap" then return false end
    if not M.active then return false end

    -- eventtap 最怕写坏了把键盘吞掉：一旦出错就放行原事件，宁可交换失效
    local ok, newEvent = pcall(swapModifiers, e)
    if not ok or newEvent == nil then return false end

    return false, newEvent
end

--- eventtap 只在真要用的时候才建 —— 它会占用辅助功能权限，hidutil 引擎用不着。
local function ensureTap()
    if not M.tap then M.tap = hs.eventtap.new(WATCHED, onEvent) end
    return M.tap
end

--------------------------------------------------------------------------------
-- 六、状态机与轮询
--------------------------------------------------------------------------------

local function statusLine()
    local mode = (MODE_LABEL[M.engine] or {})[M.mode] or M.mode
    local state

    if M.mode == "off" then
        state = "已停用"
    elseif M.active then
        state = "已交换" .. (M.lastDevice and ("：" .. M.lastDevice) or "")
    elseif M.lastError then
        -- 有设备却挂不上时，状态行必须说「失败」。旧版一律写「待机（无蓝牙键盘）」，
        -- 于是真出问题那天，图标看着正常、tooltip 却谎报没键盘 —— 排查时等于没有线索。
        state = "下发失败：" .. M.lastError
    elseif M.engine == "hidutil" then
        state = "待机（无蓝牙键盘）"
    else
        state = "待机"
    end

    return "⌘ ⇄ ⌥ " .. state .. "（" .. mode .. "）"
end

--------------------------------------------------------------------------------
-- 六·五、菜单栏图标（蓝牙键盘连接状态）
--------------------------------------------------------------------------------

-- 菜单栏图标：实心键盘 = 已连接，线框 = 未连接。
-- 生成脚本 .workbuddy/tools/make_kbswap_icons.py（纯标准库，改完几何重跑即可）。
-- 用 PNG 而不是 hs.image.imageFromASCII：后者是 ASCIImage（网格 = 像素数），
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

local ICONS = { on = loadIcon("kbswap-on.png"), off = loadIcon("kbswap-off.png") }
local GLYPH_ON, GLYPH_OFF = "⌨", "⌥⌘" -- PNG 加载失败时的兜底字形

local lastIconState = nil

--- 当前是否有「真键盘」在线。两个引擎的信息源不同：
--- hidutil 直接看 HID 枚举（5 秒一轮，准）；eventtap 只能靠 system_profiler
--- 的异步分类结果，最多滞后一轮轮询。
--- ⚠️ hidutil 侧**只认「分类明确是 Keyboard」的目标**（Lin 2026-10-20 报）：
--- V3 小键盘 Free3-P 在 HID 里带键盘 usage，分类滞后期会被 filterTargets 的
--- 保守策略（「分类未知时保留」）短暂收进 targets，直接数 #targets 会在它
--- 一连上时弹「Keyboard connected」、分类到达后又弹 disconnected —— 全是噪声。
--- 图标同理：只为真键盘亮。断开方向不受影响：目标从 targets 消失 ⇒ 立即 false，
--- 不吃 profilerTTL 的缓存滞后。
local function keyboardConnected()
    if M.engine == "hidutil" then
        -- 兜底：分类 task 失败过且缓存一直空着 ⇒ 退回老判据
        --（宁可误报一次，也不在系统拿不到分类时永远静默）。
        if (profilerCache.failed or 0) > 0 and next(profilerCache.byName) == nil then
            return #M.targets > 0
        end
        for _, t in ipairs(M.targets) do
            if profilerCache.byName[norm(t.name)] == "Keyboard" then return true end
        end
        return false
    end
    return #profilerCache.keyboardNames > 0
end

local function refreshMenubar()
    if not M.menubarItem then return end

    local connected = keyboardConnected()
    -- 连接状态 + 完整状态行一起做指纹：mode 切换后 tooltip 才会跟着更新
    local sig = tostring(connected) .. "|" .. statusLine()
    if sig == lastIconState then return end
    lastIconState = sig

    local icon = connected and ICONS.on or ICONS.off
    if icon then
        M.menubarItem:setIcon(icon)
    else
        M.menubarItem:setTitle(connected and GLYPH_ON or GLYPH_OFF)
    end

    local tip
    if connected then
        tip = "蓝牙键盘已连接" .. (M.lastDevice and ("：" .. M.lastDevice) or "")
    else
        tip = "蓝牙键盘未连接"
    end
    M.menubarItem:setTooltip(tip .. "\n" .. statusLine() .. "\n点击打开/关闭屏幕键盘（切换模式用 ⌃⌥⌘K）")
end

--- 蓝牙键盘上下线时的提示。
--- 触发点是「连接状态翻转」，与「交换是否生效」解耦：旧版把它挂在 M.active 上，
--- 于是模式切换、下发失败也会弹「已交换/已还原」——那是跟键盘上下线无关的噪声。
--- 两种场景的措辞由 M.msgConnected / M.msgDisconnected 决定（%s = 设备名）。
local lastConn = nil
local function notifyConn()
    local connected = keyboardConnected()

    if not M.notify then
        lastConn = connected          -- 关掉提示期间也要跟踪，免得打开时补弹一条旧的
        return
    end
    if lastConn == nil then
        lastConn = connected          -- 加载首轮不弹：重载配置不该报「已连接」
        return
    end
    if connected == lastConn then return end
    lastConn = connected

    if connected then
        local msg = M.msgConnected
        if msg:find("%%s") then
            msg = string.format(msg, M.lastDevice or "")
            msg = msg:gsub("%s*$", "")   -- 名字拿不到时不留尾随空格
        end
        hs.alert.show(msg, 1.0)
    else
        hs.alert.show(M.msgDisconnected, 1.0)
    end
end

--- @return boolean 当前模式下是否应该处于「已交换」
local function shouldApply()
    if M.mode == "off" then return false end
    if M.engine == "eventtap" then
        -- 注意：不能用 M.lastDevice 当判据 —— 它是「最近一次见到」的展示信息，
        -- 键盘断开时仍保留旧值，拿来判断会让交换永远撤不掉。
        -- 直接看 system_profiler 的分类缓存（每轮都强制刷新，够新鲜）。
        if M.mode == "on" then return true end
        return #profilerCache.keyboardNames > 0
    end
    return #M.targets > 0
end

--- 上一轮出现过的目标 key 集合。
--- 设备从 HID 列表里消失 = 它的 HID 服务被移除过 = 映射必然丢失。所以下次出现时
--- 无论 regid 变没变，都必须重挂——这一条和时间无关，是 HID 层的物理事实。
local lastTargetKeys = {}

--- hidutil 引擎的一轮：发现设备 -> 下发/撤销 -> 广播状态变化。
local function tickHidutil()
    local listOut = hs.execute(HIDUTIL .. " list --ndjson 2>&1")
    M.targets = filterTargets(aggregate(parseHidList(listOut)))

    -- **分类缓存未就绪时，本轮只观察、不下结论**（2026-10-18 修）。
    -- system_profiler 是**异步** task（约 0.2s 后才回调），而 tick 是同步的：
    -- 冷启动那一轮 byName 还是空的，filterTargets「分类未知时保留设备」的
    -- 保守策略就会把**蓝牙鼠标**也当键盘（罗技鼠标的 HID 里带 keyboard
    -- usage，这是该策略存在的全部原因）。后果链：弹「Keyboard connected:
    -- MX Anywhere 2S」错提示、给鼠标下发映射、M.lastDevice 显示鼠标名。
    -- 等缓存到达的下一轮再决策，最多晚一个轮询周期（2 秒）。
    -- ⚠️ 但不能无限等：task 真的失败过（failed>0）就得按老逻辑走 ——
    -- 「宁可多认几个设备，也不漏掉真键盘」是既定的取舍。
    if profilerCache.at == 0 and (profilerCache.failed or 0) == 0 then
        plog("分类缓存未就绪（system_profiler 首次回调中）→ 本轮只观察不动作")
        return
    end

    -- ① 差集：上一轮在、本轮不在 ⇒ 这台设备的映射已经随服务移除而没了
    -- （2026-10-19 审查：原来还维护了一个 goneKeys 集合做去重，但它每轮末尾
    -- 就被清空、跨轮根本去不了重，同轮内 lastTargetKeys 的 key 又天然唯一
    -- ——纯死代码，删了。「目标离开」本来也只会打一行。）
    local nowKeys = {}
    for _, t in ipairs(M.targets) do nowKeys[t.key] = true end
    for key in pairs(lastTargetKeys) do
        if not nowKeys[key] then
            plog("目标离开：%s（HID 服务被移除，映射随之丢失）", key)
        end
    end

    -- ② 「重新出现」的强制重挂**不需要单独写**：下一段的读回验证会自动发现
    -- 映射没了（HID 服务重建后属性就是空的）并重挂。2026-10-17 反向验证时发现，
    -- 专门记账再清 applied 的那段是冗余的——注回它测试照样全绿。
    lastTargetKeys = nowKeys

    if shouldApply() then
        local okCount = 0
        for _, t in ipairs(M.targets) do
            if applyTarget(t) then okCount = okCount + 1 end
        end
        M.active = okCount > 0
        M.lastDevice = M.targets[1] and M.targets[1].name or nil
        if M.active then M.lastError = nil; M.lastFailDetail = nil end   -- 至少一把挂上了就别再顶着旧错误
    else
        clearAll()
        M.active = false
        M.lastError = nil                        -- 设备都没了，失败原因也该跟着清
        M.lastFailDetail = nil
    end
end

--- tap 自己的运行状态。不能拿 M.active 当判据 —— 两个引擎切换时它会串味。
local tapRunning = false

--- eventtap 引擎的一轮：只关心 system_profiler 的结论。
local function tickEventtap()
    local want = shouldApply()
    if want == tapRunning then return end

    local tap = ensureTap()
    if want then tap:start() else tap:stop() end
    tapRunning, M.active = want, want
end

local function tick()
    -- **引擎切换后的残留清理**（2026-10-18 修）：从 eventtap 切回 hidutil 时，
    -- 旧 tap 不会自己停。onEvent 里的引擎闸能挡住交换，但 tap 本身还挂在
    -- 系统上（每个事件都跑一趟 Lua 回调）—— 这里补上「不是 eventtap 就不该
    -- 有 tap 在跑」的不变量。tapRunning 就是为这个准备的（见它的定义处注释）。
    if M.engine ~= "eventtap" and tapRunning then
        if M.tap then pcall(function() M.tap:stop() end) end
        tapRunning = false
        if M.debug then print("[kbswap] 引擎已切走，停掉残留的 eventtap") end
    end
    if M.engine == "eventtap" then
        refreshProfiler(true)   -- eventtap 的开关完全靠它，每轮都刷
        tickEventtap()
    else
        refreshProfiler(false)  -- hidutil 的开关靠 hidutil list，这个只用来分类
        tickHidutil()
    end
    notifyConn()     -- 键盘上下线提示（内部去重，只在状态翻转时弹一次）
    refreshMenubar() -- 图标状态跟设备连接情况走，每轮校对一次（内部有去重）
end

--------------------------------------------------------------------------------
-- 七、对外接口
--------------------------------------------------------------------------------

M.status  = statusLine
M.refresh = function()
    if M.engine == "hidutil" then refreshProfiler(true) end
    tick()
end

--- 收回交换并停用。
--- 顺带把 mode 置成 "off" —— 否则清完 5 秒后轮询又把它挂回来了，等于没清。
--- 想重新开启：`hsKbSwap.mode = "auto"` 或按一次热键。
function M.clear()
    M.mode = "off"
    if M.engine == "hidutil" then
        clearAll()
        clearStale()
    else
        if M.tap then M.tap:stop() end
        tapRunning = false
        -- **eventtap 模式下也可能挂着 hidutil 的映射**（从 hidutil 切过来的
        -- 残留）：「收回交换并停用」就该全收，否则键盘上的映射永远留着，
        -- 而用户以为已经停用了（2026-10-18 修）。clearAll 幂等，无设备时
        -- 只是两次空操作。
        clearAll()
        clearStale()
    end
    M.active = false
    refreshMenubar() -- mode 变了 tooltip 也要跟着变
    print("[kbswap] 已停用并清除 ⌘/⌥ 映射")
end

--- 排查用：把候选设备、分类结果、当前挂载状态都打出来。
function M.list()
    print("[kbswap] 引擎 = " .. M.engine .. "，模式 = " .. M.mode)
    print("[kbswap] —— HID 里带键盘 usage 的蓝牙设备 ——")
    local listOut = hs.execute(HIDUTIL .. " list --ndjson 2>&1")
    local items = parseHidList(listOut)
    if #items == 0 then print("  （无）") end
    for _, d in ipairs(items) do
        print(string.format("  %-28s VID=%-6s PID=%-6s %s", tostring(d.name),
            tostring(d.vid), tostring(d.pid), tostring(d.transport)))
    end

    print("[kbswap] —— system_profiler 的已连接设备分类 ——")
    if not next(profilerCache.byName) then print("  （还没刷新，稍后再试）") end
    for name, minor in pairs(profilerCache.byName) do
        print(string.format("  %-28s %s", name, minor))
    end

    print("[kbswap] —— 实际下发目标 ——")
    if #M.targets == 0 then print("  （无）") end
    for _, t in ipairs(M.targets) do
        print(string.format("  %-28s regid=%s", tostring(t.name), t.sig))
    end

    print("[kbswap] —— 已挂载 ——")
    if not next(applied) then print("  （无）") end
    for key, rec in pairs(applied) do
        print(string.format("  %s  via  %s", key, rec.matcher))
    end
    if M.lastError then print("[kbswap] 最近一次失败：" .. M.lastError) end
end

hs.hotkey.bind(M.hotkeyMods, M.hotkeyKey, function()
    local cycle = CYCLE[M.engine] or CYCLE.hidutil
    M.mode = cycle[M.mode] or "auto"
    tick()
    -- 状态没变（比如已经是停用再按一次）也给个反馈
    hs.alert.show(statusLine(), 1.0)
end)

_G.hsKbSwap = M

-- 起步：先看看有没有上一轮配置留下的残留映射（只在我们确认是自己下的才清）。
if M.mode == "off" then clearStale() end

-- 菜单栏图标。必须持有 menubarItem 引用：对象被 Lua 回收时 __gc 会调用
-- removeStatusItem() 把图标摘掉（scroll.lua 踩过的坑），别把它置 nil。
-- 放在 tick() 之前创建，首轮 tick 就会把图标画上去。
if M.showMenubar then
    M.menubarItem = hs.menubar.new(true, M.menubarAutosaveName)
    if M.menubarItem then
        -- 点击 = 开/关自绘屏幕键盘（osk.lua 经 _G.hsOnScreenKeyboard 暴露，
        -- 解耦：kbswap 不 require osk，加载顺序无关）。备用方案 axkeyboard.lua
        -- （系统无障碍键盘）保留在盘上但不加载。
        -- ⌘/⌥ 交换模式的切换仍只走 ⌃⌥⌘K。
        M.menubarItem:setClickCallback(function()
            local kb = _G.hsOnScreenKeyboard
            if kb and kb.toggle then kb.toggle() end
        end)
    end
end

tick()
M.timer = hs.timer.doEvery(M.pollInterval, tick)

return M
