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
--- 点击 = 打开/关闭系统「辅助功能键盘」（axkeyboard.lua，蓝牙键盘断开时的应急输入）。
--- 切换 ⌘/⌥ 交换模式只走 ⌃⌥⌘K。
--- 提示：蓝牙键盘连上/断开时弹 "Keyboard connected / disconnected"（措辞见
---       M.msgConnected / M.msgDisconnected）。

local M = {}

--------------------------------------------------------------------------------
-- 配置
--------------------------------------------------------------------------------

M.engine       = "hidutil"  -- "hidutil" 只换蓝牙键盘 | "eventtap" 全局交换（旧方案，兜底）
M.mode         = "auto"     -- "auto" 跟随蓝牙键盘 | "off" 停用（eventtap 另有 "on" 强制交换）
M.pollInterval = 5          -- 检测间隔（秒）
M.profilerTTL  = 30         -- system_profiler 结果的缓存时间（秒），它是唯一慢的一环
M.reassert     = 60         -- 每隔多久重挂一次映射（秒）。防休眠唤醒后映射悄悄失效
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

    local flat = " " .. out:gsub("%s+", " ") .. " "
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
--- @type table
local profilerCache = { at = 0, byName = {}, keyboardNames = {}, pending = false }

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

--- key -> { target, matcher, sig, at }
local applied = {}

--- 给一把键盘挂上交换。已经挂过且设备没有重新枚举就直接返回，不重复下发。
--- @param t table 设备描述
--- @return boolean 是否处于「已挂上」状态
local function applyTarget(t)
    local rec = applied[t.key]
    if rec and rec.sig == t.sig and (os.time() - rec.at) < M.reassert then
        return true
    end

    local payload = mappingPayload()
    local want = expectedDecimals()

    for _, m in ipairs(matchersFor(t)) do
        local out, ok = runHidutil(m, payload)
        local valueOK, deviceOK = hasAll(out, want), hitDevice(out, t)

        -- hidutil 的 --set 会把设置后的属性打印出来，直接拿它当读回校验，省一次进程。
        -- 两层都要过：值里有我们那套 src/dst，且命中的是这台设备自己的 RegistryID。
        if ok and valueOK and deviceOK then
            applied[t.key] = { target = t, matcher = m, sig = t.sig, at = os.time() }
            M.lastError = nil
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
    print("[kbswap] " .. M.lastError)
    return false
end

--- 撤销我们自己的映射。只清 applied 里记着的那些 —— 不碰设备上其它来源的映射。
local function clearAll()
    for _, rec in pairs(applied) do
        local out, ok = runHidutil(rec.matcher, EMPTY_MAP)
        if M.debug then
            print(string.format("[kbswap] 已撤销 %s（ok=%s）", tostring(rec.target.name), tostring(ok)))
        end
        if not ok then M.lastError = "撤销失败：" .. tostring(rec.target.name) end
    end
    applied = {}
end

--- 清掉「我们自己下的」残留映射。
--- 场景：改了配置重载 Hammerspoon，上一个实例的 applied 记录没了，但设备上还挂着映射。
--- 先读回、逐条确认那是我们这套配对才清 —— 免得把用户自己用 hidutil 设的映射误删。
local function clearStale()
    for _, m in ipairs(transportMatchers()) do
        local out = runHidutil(m, nil, "UserKeyMapping")
        if isOurMapping(out) then
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

--- 当前是否有蓝牙键盘在线。两个引擎的信息源不同：
--- hidutil 直接看 HID 枚举（5 秒一轮，准）；eventtap 只能靠 system_profiler
--- 的异步分类结果，最多滞后一轮轮询。
local function keyboardConnected()
    if M.engine == "hidutil" then return #M.targets > 0 end
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

--- hidutil 引擎的一轮：发现设备 -> 下发/撤销 -> 广播状态变化。
local function tickHidutil()
    local listOut = hs.execute(HIDUTIL .. " list --ndjson 2>&1")
    M.targets = filterTargets(aggregate(parseHidList(listOut)))

    if shouldApply() then
        local okCount = 0
        for _, t in ipairs(M.targets) do
            if applyTarget(t) then okCount = okCount + 1 end
        end
        M.active = okCount > 0
        M.lastDevice = M.targets[1] and M.targets[1].name or nil
    else
        clearAll()
        M.active = false
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
