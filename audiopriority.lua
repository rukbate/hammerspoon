--- audiopriority.lua —— 按优先级自动挑系统默认输入设备；无线麦靠「电平」判断真麦在不在线
---
--- 为什么需要这个模块（2026-10-21）：
---   「Wireless Mic Rx」是大疆无线麦的 USB 接收器。发射器关机、没配对、没开机，
---   接收器都照样插在机器上 —— Core Audio 里设备始终存在、始终可选。任何基于
---   「设备在不在列表里」的判断（包括 AudioPriority 那个 App）都会把它当成在线，
---   永远不会 fallback 到别的麦。
---   实测区分手段：发射器关机 → 纯数字静音，astats 读出 -inf dB；发射器开着 →
---   有底噪（安静房间实测 RMS -51 ~ -74.5 dB，Peak -29 ~ -62 dB）。
---   所以用 ffmpeg 周期性采样电平，超阈值才算「真麦在线」。
---
--- 行为：
---   按 M.rules 从上到下找第一个「合格」的设备，设为系统默认输入：
---     · mode="signal"    设备在 + 电平采样在有效期内且高于阈值
---     · mode="presence"  设备在就行
---   一条都不合格时保持现状（不瞎切）。只有合格性变化时才切换，不会来回跳。
---
--- 与 AudioPriority App 的关系：二选一。那个 App 只认「设备存在」，会把关着机的
---   接收器一直当默认输入，和本模块互相打架。用本模块就退出 AudioPriority
---   （登录项里也移除），或至少在它设置里关掉「输入设备守护」、只留输出。
---
--- 依赖：/opt/homebrew/bin/ffmpeg（avfoundation 采样）。ffmpeg 采音需要 macOS 的
---   麦克风权限，第一次采样可能弹「ffmpeg 想访问麦克风」，去
---   系统设置 → 隐私与安全性 → 麦克风 放行。放行后日志才会出现电平读数。
---
--- 日志（~/.hammerspoon/.workbuddy/audiopriority.log）即诊断面板：
---   · level 行：每次采样的电平（校准阈值用）
---   · mic LIVE / silent 行：发射器开 / 关的状态翻转
---   · policy 行：每轮策略裁决（选谁、为什么、当前是谁）——「保持」也记账
---   · switch input 行：实际发生默认输入切换
---   · tick skip 行：异常路径（找不到设备 / 索引失效），附当前全部输入设备名
---   · heartbeat 行：每 12 tick 一条（双链叠加，实测约 25s），带 tick 数 / 测量状态 / 输入设备列表。
---     **没有 heartbeat = 定时器死了**；有 heartbeat 且 measuring=true 不动 =
---     采样卡死（看门狗兜底）；有 tick skip = 设备列表视角丢了。
---   · tick error / cb error 行：Lua 异常（pcall 兜底，不会带走定时器）
---
--- ⚠️ 血的教训（2026-10-21，本模块连踩三次）：hs.timer 是 C 侧对象，Lua 侧不持有
---   引用会被 GC 回收、NSTimer 被 invalidate —— 症状是「加载后采一两次就静默
---   停摆、无任何日志」。所有 hs.timer 创建后必须存进 M.timer / M.nextTimer。
---   （kbswap.lua:1175 的 `M.timer = hs.timer.doEvery(...)` 就是正确姿势。）

local M = {}

--------------------------------------------------------------------------------
-- 配置
--------------------------------------------------------------------------------

M.ffmpeg           = "/opt/homebrew/bin/ffmpeg"
M.sampleSeconds    = 2     -- 每次电平采样录多少秒。太短底噪估不准，太长反应慢
M.interval         = 5     -- 轮询间隔（秒）。发射器开关机的感知延迟 ≈ interval + sampleSeconds
M.silenceThreshold = -80   -- dB：采样电平低于它视为「麦没开」。发射器关机是精确 -inf，
                            -- 在线最弱实测也有 -62，取 -80 两头都留 18dB 余量。
                            -- 校准：看日志 level 行对比开 / 关时的读数，取中间值
M.freshWindow      = 15    -- 电平采样有效期（秒）。超期视为未知，该规则作废
M.hangTimeout      = 20    -- 看门狗：单次采样超过这么多秒还没回调，判定卡死，杀任务重试

--- 优先级表，从上到下，第一个合格的胜出。
--- mode = "signal"    需电平在线（适合「常驻但时开时关」的无线麦接收器）
--- mode = "presence"  只要设备在（适合插着就用的声卡 / 音箱麦）
M.rules = {
  { name = "Wireless Mic Rx",  mode = "signal"   },
  { name = "HP S1X sound bar", mode = "presence" },
}

M.logPath     = (os.getenv("HOME") or ".") .. "/.hammerspoon/.workbuddy/audiopriority.log"
M.logMaxBytes = 512 * 1024    -- 超了整份重写。诊断日志不需要跨天历史
M.enabled     = true          -- 菜单栏可切「自动切换」开关

--------------------------------------------------------------------------------
-- 内部状态
--------------------------------------------------------------------------------

local log = hs.logger.new("audiopriority", "info")
M._levels          = {}   -- name -> { db, peak, ts, err? }
M._avIndex         = nil  -- name -> avfoundation 编号（缓存；取不到就重查）
M._measuring       = false
M._measureTask     = nil  -- 当前采样任务（看门狗 terminate 用；同时防 GC）
M._listTask        = nil  -- 当前查设备列表任务（同上）
M._measureStartedAt = nil
M._lastWhy         = {}   -- name -> 上一次「为什么不合格」，只记变化，防止每轮刷屏
M._tickCount       = 0
M._skipCount       = 0    -- 因上一轮还没采完而跳过的 tick 数（看门狗诊断用）
M._lastPolicy      = nil  -- 上一次策略裁决摘要（去重用）

--- 菜单栏标题用的短名
local SHORT = { ["Wireless Mic Rx"] = "Rx", ["HP S1X sound bar"] = "S1X" }

--------------------------------------------------------------------------------
-- 工具
--------------------------------------------------------------------------------

--- 写日志。**绝不能抛**（2026-10-05 osk diag() 的教训）：诊断函数把功能搞挂是最讽刺的死法
local function plog(fmt, ...)
  if not M.logPath then return end
  local msg = string.format(fmt, ...) -- 格式化放 pcall 外：... 在非 vararg 闭包里不可用
  pcall(function()
    local f = io.open(M.logPath, "a")
    if not f then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    f:close()
    local attr = hs.fs.attributes(M.logPath)
    if attr and attr.size and attr.size > M.logMaxBytes then
      local fw = io.open(M.logPath, "w")
      if fw then fw:close() end
    end
  end)
end

--- 当前输入设备名列表（诊断用：设备视角丢了的时候，一眼看见 CoreAudio 里到底有什么）
local function inputNames()
  local names = {}
  for _, d in ipairs(hs.audiodevice.allInputDevices() or {}) do
    names[#names + 1] = d:name()
  end
  if #names == 0 then return "(empty)" end
  return table.concat(names, " | ")
end

--- 找输入设备（精确匹配名字）。返回 hs.audiodevice 或 nil
local function findInput(name)
  for _, d in ipairs(hs.audiodevice.allInputDevices() or {}) do
    if d:name() == name then return d end
  end
  return nil
end

--- avfoundation 音频设备编号表（名字 -> 编号）。ffmpeg 的设备列表打在 stderr
local function refreshAvIndex(cb)
  M._listTask = hs.task.new(M.ffmpeg, function(_, _, stderr)
    M._listTask = nil
    local map, inAudio = {}, false
    for line in (stderr or ""):gmatch("[^\n]+") do
      if line:find("AVFoundation audio devices:", 1, true) then
        inAudio = true
      elseif inAudio then
        local idx, nm = line:match("%]%s*%[(%d+)%]%s*(.-)%s*$")
        if idx and nm and nm ~= "" then map[nm] = tonumber(idx) end
      end
    end
    cb(map)
  end, { "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", "" })
  M._listTask:start()
end

--- 采样设备电平。回调 cb(db, peak, errText)。db = RMS dB；-inf（数字静音）= -math.huge
--- 任务对象存进 M._measureTask（看门狗 terminate + 防 GC 双用途）
local function measureLevel(idx, cb)
  local task
  task = hs.task.new(M.ffmpeg, function(_, stdout, stderr)
    M._measureTask = nil
    local out = (stderr or "") .. (stdout or "")
    local rms, peak
    -- astats 会按声道分段打印，最后一段是 Overall；gmatch 取最后一次匹配
    for v in out:gmatch("RMS level dB:%s*([%-%d%.inf]+)")  do rms  = v end
    for v in out:gmatch("Peak level dB:%s*([%-%d%.inf]+)") do peak = v end
    local function todb(s)
      if not s then return nil end
      if s == "-inf" then return -math.huge end
      return tonumber(s)
    end
    local rdb, pdb = todb(rms), todb(peak)
    if rdb then cb(rdb, pdb) else cb(nil, nil, out) end
  end, {
    "-hide_banner", "-nostdin",
    "-f", "avfoundation", "-i", ":" .. idx,
    "-t", tostring(M.sampleSeconds),
    "-af", "astats=metadata=1:reset=0",
    "-f", "null", "-",
  })
  M._measureTask = task
  task:start()
end

--------------------------------------------------------------------------------
-- 菜单栏
--------------------------------------------------------------------------------

local menu = hs.menubar.new()

local function updateMenubar(name, why)
  if not menu then return end
  menu:setTitle("🎙 " .. (SHORT[name] or (name or "?")))
  local lv = name and M._levels[name]
  menu:setMenu({
    { title = "当前输入: " .. (name or "无"), disabled = true },
    { title = "生效原因: " .. (why or "-"), disabled = true },
    { title = lv and lv.db and string.format("最近电平: %.1f dB", lv.db) or "最近电平: 无采样", disabled = true },
    { title = "-" },
    { title = "立即重新采样", fn = function() safeTick() end },
    { title = M.enabled and "暂停自动切换" or "恢复自动切换", fn = function()
      M.enabled = not M.enabled
      plog("auto-switch %s", M.enabled and "ON" or "OFF")
      local cur = hs.audiodevice.defaultInputDevice()
      updateMenubar(cur and cur:name(), "手动")
    end },
    { title = "打开日志", fn = function() hs.execute("open -R '" .. M.logPath .. "'") end },
  })
end

--------------------------------------------------------------------------------
-- 核心策略
--------------------------------------------------------------------------------

--- 按优先级表选设备并设为默认输入。每轮裁决都落日志（去重），「保持」也记账
local function applyPolicy()
  local cur = hs.audiodevice.defaultInputDevice()
  local curName = cur and cur:name() or nil
  local now = os.time()
  for _, rule in ipairs(M.rules) do
    local dev = findInput(rule.name)
    if dev then
      local ok, why = false, nil
      if rule.mode == "presence" then
        ok, why = true, "presence"
      else -- signal：电平必须在有效期内且超阈值
        local lv = M._levels[rule.name]
        if lv and lv.db and (now - lv.ts) <= M.freshWindow then
          if lv.db > M.silenceThreshold then
            ok, why = true, string.format("signal %.1fdB", lv.db)
          else
            why = "silent"
          end
        elseif lv and lv.err then
          why = "capture failed"
        else
          why = "level stale"
        end
      end
      if ok then
        local summary = string.format("chosen=%s (%s) current=%s", dev:name(), why, curName or "none")
        if M._lastPolicy ~= summary then
          plog("policy: %s", summary)
          M._lastPolicy = summary
        end
        if curName ~= dev:name() then
          -- hs.audiodevice 1.1.1 实测：defaultInputDevice 是纯 getter（0 参），
          -- 传设备对象进去直接抛 "incorrect number of arguments. Expected 0, got 1"
          -- 2026-10-21 踩过。设置默认输入必须用设备方法 setDefaultInputDevice()，返回 true/false
          local setOk = dev:setDefaultInputDevice()
          plog("switch input -> %s (%s) [set %s]", dev:name(), why, setOk and "ok" or "FAILED")
          log.i("input switched to %s (%s)", dev:name(), why)
          updateMenubar(dev:name(), why)
        end
        return dev
      end
      -- 不合格：只在原因变化时记一行
      if M._lastWhy[rule.name] ~= why then
        plog("rule skip: %s (%s)", rule.name, why)
        M._lastWhy[rule.name] = why
      end
    end
  end
  -- 没有合格设备：保持现状（也记账，去重）
  local summary = string.format("no eligible device, keep current=%s", curName or "none")
  if M._lastPolicy ~= summary then
    plog("policy: %s", summary)
    M._lastPolicy = summary
  end
  return cur
end

--------------------------------------------------------------------------------
-- 轮询主循环
--------------------------------------------------------------------------------

local safeTick -- 前向声明：updateMenubar / tickFn 的闭包都要引用它

--- 每轮：测「在场且优先级最高的 signal 设备」的电平，采完立即执行策略。
--- 所有静默 return 分支都有日志；pcall 兜底防异常带走定时器。
local function tickFn()
  M._tickCount = M._tickCount + 1
  if not M.enabled then return end

  -- 心跳：无论走哪条路径，每 12 tick 报一次行踪 + 关键状态
  if M._tickCount % 12 == 0 then
    plog("heartbeat: tick=%d measuring=%s avIndex=%s inputs=[%s]",
         M._tickCount, tostring(M._measuring), M._avIndex and "ok" or "nil", inputNames())
  end

  -- 看门狗：上一轮采样卡死（任务不回调）→ 杀任务，让轮询恢复
  if M._measuring then
    local age = M._measureStartedAt and (os.time() - M._measureStartedAt) or 0
    if age > M.hangTimeout then
      plog("watchdog: measurement hung %ds (>%ds), terminating task; inputs=[%s]",
           age, M.hangTimeout, inputNames())
      if M._measureTask then pcall(function() M._measureTask:terminate() end) end
      M._measuring = false
      M._measureStartedAt = nil
    end
  end
  if M._measuring then
    M._skipCount = M._skipCount + 1
    return
  end
  M._skipCount = 0

  if not M._avIndex then
    refreshAvIndex(function(map)
      M._avIndex = map
      local n = 0; for _ in pairs(map) do n = n + 1 end
      plog("avfoundation index refreshed: %d audio device(s)", n)
      if n == 0 then
        plog("avfoundation index EMPTY; ffmpeg -list_devices 异常？")
      end
      safeTick()
    end)
    return
  end

  -- 找优先级最高的、在场的 signal 设备
  local target
  for _, rule in ipairs(M.rules) do
    if rule.mode == "signal" and findInput(rule.name) then target = rule; break end
  end
  if not target then
    -- 静默失败头号嫌疑：设备从 hs.audiodevice 的视角里消失了。落日志 + 列名字
    plog("tick skip: signal device 不在输入列表; inputs=[%s]", inputNames())
    applyPolicy()
    return
  end
  local idx = M._avIndex[target.name]
  if not idx then
    -- 编号对不上：设备重枚举过（重插、重启）。丢掉缓存下轮重查
    M._avIndex = nil
    plog("avfoundation index missing for %s; refresh next tick", target.name)
    return
  end

  M._measuring = true
  M._measureStartedAt = os.time()
  measureLevel(idx, function(db, peak, errText)
    -- 整个回调体 pcall：applyPolicy 抛异常也不能吃掉后面的 re-arm
    local ok, err = pcall(function()
      M._measuring = false
      M._measureStartedAt = nil
      local now = os.time()
      if not db then
        M._levels[target.name] = { db = nil, ts = now, err = "capture failed" }
        plog("level capture FAILED for %s: %s", target.name,
             ((errText or "?"):gsub("\n", " ")):sub(1, 120))
      else
        local dbEff = math.max(db, peak or db) -- 底噪看 RMS，瞬态看 Peak，取狠的
        local prev = M._levels[target.name]
        local prevDb = prev and prev.db
        M._levels[target.name] = { db = dbEff, peak = peak, ts = now }
        plog("level %s = %.1f dB (rms %.1f / peak %s)", target.name, dbEff, db,
             peak and string.format("%.1f", peak) or "n/a")
        -- 状态翻转才记一行：mic LIVE = 发射器开了；mic silent = 关了
        local wasLive = prevDb ~= nil and prevDb > M.silenceThreshold
        local isLive = dbEff > M.silenceThreshold
        if prevDb == nil or wasLive ~= isLive then
          plog("mic %s: %s (dbEff %.1f, threshold %.0f)", target.name,
               isLive and "LIVE" or "silent", dbEff, M.silenceThreshold)
        end
      end
      applyPolicy()
    end)
    if not ok then plog("cb error: %s", tostring(err)) end
    -- 双保险：测量完成后再自挂一发（doEvery 万一死了，这条链还能续）。
    -- 同样必须持有引用，否则会被 GC 回收重蹈覆辙
    M.nextTimer = hs.timer.doAfter(M.interval, safeTick)
  end)
end

--- 带 pcall 的调度包装：tick 里抛异常也不会把定时器带走
safeTick = function()
  local ok, err = pcall(tickFn)
  if not ok then plog("tick error: %s", tostring(err)) end
end

--------------------------------------------------------------------------------
-- 启动
--------------------------------------------------------------------------------

updateMenubar(hs.audiodevice.defaultInputDevice() and hs.audiodevice.defaultInputDevice():name(), "init")
-- ⚠️ 以下三个 timer 创建后全部持有引用（M.timer / M.nextTimer / M.startTimer）。
-- 裸调 hs.timer.doEvery/doAfter 不存引用 = 定时器被 GC 回收 = 静默停摆（2026-10-21 连踩三次）
M.timer      = hs.timer.doEvery(M.interval, safeTick)
M.startTimer = hs.timer.doAfter(1, safeTick) -- 启动后尽快来一发，别等一个 interval
plog("audiopriority loaded (interval=%ds sample=%ds threshold=%.0fdB hangTimeout=%ds rules=%d)",
     M.interval, M.sampleSeconds, M.silenceThreshold, M.hangTimeout, #M.rules)
log.i("audiopriority loaded")

return M
