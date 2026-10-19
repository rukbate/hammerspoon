--- osk.lua —— 屏幕键盘（蓝牙键盘断开时的应急输入设备）
---
--- 模块世代令牌（2026-10-18 加）：`hs.timer`/`hs.eventtap`/canvas 都是 C 侧对象，
--- **Reload Config 不会停掉它们**。旧模块的闭包链（timer → fn → M）不会被 GC，
--- 于是开着键盘时 reload：旧画布、旧 tap、旧看门狗、旧采样器全部继续运行，
--- 新模块再建一套 → 两个面板并存，每 reload 还静默漏一个 0.12s 永久采样 timer。
--- 对策：每次加载递增 `_G.oskGen`，本模块闭包记下自己那代的 GEN；所有周期性
--- 回调第一行检查「我还是不是最新一代」，不是就停掉自己（看门狗还会捎带停旧 tap）。
--- show() 则负责删掉上一代遗留的画布。
local GEN = (_G.oskGen or 0) + 1
_G.oskGen = GEN
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

--- 修饰键 armed 状态（sticky）。下一次普通按键生效后全部清空。
--- fn 也在里面（2026-10-05）：`hs.eventtap.keyStroke` 的 modifiers 表原生
--- 接受 "fn"（docs.json 原文列举了 "fn", "ctrl", "alt", "cmd", "shift"），
--- 不需要手工用 newKeyEvent 拼 flag，直接塞进 mods 表即可。
M.armed = { shift = false, ctrl = false, alt = false, cmd = false, fn = false }
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
M.mouseAnchorHold = 0.25   -- 鼠标在**同一个点**静止这么久（秒），才把那个点
                         -- 记成「候选输入区」记账（M._anchorBest）。
                         --
                         -- **为什么改成记账而不是「打开那一刻看一眼」**
                         -- （2026-10-03 真机日志）：触发键盘的入口是菜单栏图标，
                         -- 点它时鼠标必然在屏幕顶部（实测 y=14）。而用户真实动作
                         -- 是「点输入框 →（停顿）→ 移到菜单栏 → 点图标」——
                         -- 输入区对应的是**那个停顿的位置**，不是最后的位置。
                         -- 拿打开瞬间的位置当输入区代理，在主路径下永远错。
                         --
                         -- 所以改成后台常驻采样（见 M.mousePollInterval），
                         -- 记住「鼠标在哪儿停得最久」。这还顺带修掉上一版那个
                         -- 荒唐前提：要「先show 一次、再过 0.4s 后第二次 show」
                         -- 才生效 —— 等于**要连按两次键盘**。现在不需要了。
M.mousePollInterval = 0.12 -- 后台鼠标采样间隔（秒）。必须明显小于
                         -- mouseAnchorHold，否则「停了多久」记得不准。
                         -- 0.12s 足够（AX 那边每层都是 IPC 级的开销，
                         -- 鼠标读一次只是取当前值，很便宜）。
M.mouseAnchorHeight = 120 -- 鼠标位置只是个**点**，没有高度，直接拿来跟面板比重叠
                        -- 毫无意义（点高 0）。所以在它**上方**造一个这么高的
                        -- 「假想输入区」，只取它的**下缘**：面板停在鼠标上方，
                        -- 就不会压住用户刚点击的那个位置。
M.mouseAnchorMaxStill = 30 -- 「静置多久」的累积上限（秒）。
                        -- 为什么必须有上限：still 在鼠标不动期间每 0.12s 一跳
                        -- 无界增长，而锚点候选只跟「史上最久」竞争。不起这个
                        -- 帽，鼠标静置半小时后 still=1800，之后在任何输入框前
                        -- 的真实停顿（1~2 秒）都永远竞争不过它 —— 锚点锁死在
                        -- 半小时前那个位置，避让慢性失效（2026-10-18 修）。
                        -- 30 秒远大于真实停顿，不会误伤主路径。
M.mouseAnchorMaxAge = 60  -- 锚点候选的保质期（秒）。超过这个年龄就弃用，
                        -- 退回「当前鼠标位置」。主路径「停顿→移菜单栏→点图标」
                        -- 全程 1~2 秒，远小于 60；而起身半小时回来时，旧锚点
                        -- 早就不代表输入区了。和 MaxStill 是两道独立的保险。
M.opacity     = 0.88    -- 面板不透明度（1 = 全实心）。Lin 要求半透明
                        -- （2026-10-02）：避让总有兜不住的时候（输入区可能占满
                        -- 整页、或根本探测不到），半透明是最后一道保险——
                        -- 挡不死，至少能透出下面的输入框。
                        -- 0.6~0.8 比较合适；< 0.5 键帽会太透、看不清字。
                        -- 2026-10-05 Lin 说「稍微不透明一点点」：0.78 → 0.88
                        -- （仍留一点透光，但基本是实心的手感）。
                        -- 改完立即生效（不用重载），下一次 M.show() 时应用。
                        -- 想临时完全不透明：hs.osk.opacity = 1
M._repeat = nil         -- 按住连发的定时器

--- **听写（语音输入）键发的组合键**。
---
--- 屏幕键盘**触发不了 macOS 的「按 Fn 键两次」**（2026-10-05 四轮真机实测）：
--- 实体 FN 走 `systemDefined`、原样回放的合成事件也发得出去，但系统的听写检测
--- 在 HID 层认事件来源，合成事件不认。这条路别再钻了。
--- ⇒ 改发**普通组合键**：把「系统设置 → 键盘 → 听写 → 快捷键」设成这里的组合
--- （默认 ⌃⌥Space），屏幕键盘点「听写」键即可，实体键盘用同一组合也能唤出。
--- 想换成别的组合，**只改这一行**（布局里那个键直接引用它）。
M.dictationCombo = { mods = { "ctrl", "alt" }, k = "space" }
M._tap = nil            -- 事件拦截 tap
M._watchdog = nil       -- tap 看门狗（系统禁用后自动重启）
M._capturing = false    -- 正在按（mouseDown 起到 mouseUp 止，期间事件全吞）
M._pressing = nil       -- 当前按住的键记录
M._targetApp = nil      -- show 时记录的目标 App（还原 show 抢走的焦点用）
M._axTimeoutSet = false -- AX 全局超时是否已设（只设一次，见 focusedInputRect）

--- 布局（洛菲小顺 75% 配列：主键区 + 右侧导航列 Home/End/PgUp/PgDn +
--- 顶排右端 ⌘C/⌘V/⌦；每行宽度恒为 16 单位）。
---
--- 每个键：t=显示文字 k=hs.keycodes 键名 s=shift 层文字 w=宽度(默认1)
---         mod=修饰键(sticky) rep=按住连发 special="caps"
---         combo={mods={...}, k="..."} 组合键（整组直发，见 sendKey）
--- 留白：spacer(w) —— 只把行内 x 往前推，不画键、不可点。
---
--- **每行必须等宽**：panelSize() 按「最宽的一行」算面板宽度，行与行之间只是
--- 从上往下依次排，哪一行短了右边就缺一块。加/删键后务必核对下面的宽度表。
---
--- **顶排右端为什么是 ⌘C/⌘V 而不是 PrtSc/Ins**（2026-10-05 查实）：
--- `hs.keycodes.map` 里压根没有 print/scrolllock/pause/insert 这几个名字 ——
--- 不是文档漏写，是在 `libkeycodes.dylib` 的键名表里也搜不到，因为 **Mac 键盘
--- 物理上就没这三个键位**（它们的活儿在 macOS 上归 F13/F14/F15）。写进布局
--- 只会让 keyStroke 静默打空。Lin 拍板：这两个键位改成 Mac 的拷贝/粘贴
--- （combo 直发 ⌘C/⌘V）。**别再往布局里加不存在的键名**——它不会报错，
--- 只会没反应。
---
--- 宽度核对（改动后请重跑测试里那组「每行右缘像素对齐」断言）：
---   行1  1 + 12×1 + 0.75×4（⌘C/⌘V/⌦ 缩窄给「听写」腾位）= 16
---   行2  13  + 2    + 1                                = 16
---   行3  1.5 + 10+2 + 1.5 + 1                          = 16
---   行4  1.75+ 9+2  + 2.25 + 1                         = 16
---   行5  2.25+ 7+3  + 1.75 + 1 + 1                     = 16
---   行6  1+1+1.25 + 5.5 + 1.25+1+1+1 + 1+1+1           = 16
---
--- **对齐的唯一判据是「累计单位位置」，不是「每行键宽合计」**（2026-10-05 推导）：
--- build() 里键宽是 `w*unit+(w-1)*gap`、每个键后面再补 1 个 gap，展开后第 i 个键
---   x_i   = pad + P_i*(unit+gap)          P_i = 它前面所有键宽度之和
---   右缘  = pad + (P_i+w_i)*(unit+gap) - gap
--- ⇒ **两个键只要累计单位位置相同就必然像素对齐**，跟各自那一行有几个键无关。
--- 反过来「每行键宽合计相等」在各行键数不同时**并不等于**对齐——别拿单位数
--- 当对齐判据，直接测像素右缘（测试 13.1 就是这么断言的）。
---
--- **行5 的右 ⇧ 是 1.75，不是常见的 2.75**（2026-10-05 Lin 反馈「右 ⇧ 跟 ↑
--- 之间空隙太大」）：原先是「右⇧ 1.5 + 留白 0.25」，留白那 0.25 单位在面板上
--- 就是一条显眼的空缝。把 0.25 并进右⇧、撤掉留白，↑ 的累计位置**不变**
--- （仍是 2.25+10+1.75 = 14.0，与 ↓ 的 14.0 像素对齐），行宽也仍是 16，
--- 而 ⇧ 与 ↑ 之间只剩标准的 1 个 gap。**动行5/行6 任何宽度都会破坏 ↑↓ 对齐**。
local function key(t, k, s, w, extra)
    local def = { t = t, k = k, s = s, w = w or 1 }
    if extra then for kk, vv in pairs(extra) do def[kk] = vv end end
    return def
end

--- 行内留白：只把行内 x 往前推，不画键、不可点。
--- **当前布局已经不用它了**（2026-10-05 把 ↑ 前那 0.25 的留白并进了右⇧ 的键宽，
--- 见布局头注释），留着是因为改布局顶位时还会用到——比如要让某个键落在
--- 上一行某个键正下方、又不能改键宽的时候。
local function spacer(w)
    return { spacer = true, w = w or 1, t = "", k = "" }
end

local LAYOUT = {
    { -- 顶排：esc + F1~F12 + ⌘C/⌘V/⌦（洛菲小顺的 PrtSc/Ins 位，
      -- Mac 没有这两个键名，按 Lin 的要求改成拷贝/粘贴组合键）
        key("esc", "escape", nil, 1),
        key("F1", "f1"), key("F2", "f2"), key("F3", "f3"),
        key("F4", "f4"), key("F5", "f5"), key("F6", "f6"),
        key("F7", "f7"), key("F8", "f8"), key("F9", "f9"),
        key("F10", "f10"), key("F11", "f11"), key("F12", "f12"),
        -- 顶排右端四键各 0.75：**总和必须正好是 3**（1 + 12 + 3 = 16）。
        -- 别用 0.667 这种无限小数：0.667×3 = 2.001，多出的 0.001 单位会让顶排
        -- 比其它行宽 0.1px，跨行右缘立刻对不齐（2026-10-05 加听写键时踩到）。
        key("⌘C", nil, nil, 0.75, { combo = { mods = { "cmd" }, k = "c" } }),
        key("⌘V", nil, nil, 0.75, { combo = { mods = { "cmd" }, k = "v" } }),
        key("Del", "forwarddelete", nil, 0.75, { rep = true }),
        -- 听写键：发 M.dictationCombo（默认 ⌃⌥Space）。**为什么不能直接发 FN**
        -- 见 M.dictationCombo 处的注释——系统的 FN 双击检测不认合成事件。
        key("听写", nil, nil, 0.75, { combo = M.dictationCombo }),
    },
    { -- 数字行 + 导航列 Home
        key("`", "`", "~"), key("1", "1", "!"), key("2", "2", "@"),
        key("3", "3", "#"), key("4", "4", "$"), key("5", "5", "%"),
        key("6", "6", "^"), key("7", "7", "&"), key("8", "8", "*"),
        key("9", "9", "("), key("0", "0", ")"), key("-", "-", "_"),
        key("=", "=", "+"), key("Backspace", "delete", nil, 2, { rep = true }),
        key("home", "home"),
    },
    { -- Tab 行 + 导航列 End
        key("⇥", "tab", nil, 1.5),
        key("q", "q"), key("w", "w"), key("e", "e"), key("r", "r"),
        key("t", "t"), key("y", "y"), key("u", "u"), key("i", "i"),
        key("o", "o"), key("p", "p"),
        key("[", "[", "{"), key("]", "]", "}"), key("\\", "\\", "|", 1.5),
        key("end", "end"),
    },
    { -- Caps 行 + 导航列 PgUp
        key("⇪", "capslock", nil, 1.75, { special = "caps" }),
        key("a", "a"), key("s", "s"), key("d", "d"), key("f", "f"),
        key("g", "g"), key("h", "h"), key("j", "j"), key("k", "k"),
        key("l", "l"), key(";", ";", ":"), key("'", "'", '"'),
        key("⏎", "return", nil, 2.25),
        key("pgup", "pageup"),
    },
    { -- Shift 行 + ↑ + 导航列 PgDn。
      -- 右⇧ 1.75 是解出来的对齐参数（见布局头注释），别乱动。
        key("⇧", "shift", nil, 2.25, { mod = "shift" }),
        key("z", "z"), key("x", "x"), key("c", "c"), key("v", "v"),
        key("b", "b"), key("n", "n"), key("m", "m"),
        key(",", ",", "<"), key(".", ".", ">"), key("/", "/", "?"),
        key("⇧", "shift", nil, 1.75, { mod = "shift" }),
        key("↑", "up", nil, 1, { rep = true }),
        key("pgdn", "pagedown"),
    },
    { -- 底排：空格右侧 ⌘/fn/⌥/⌃（洛菲小顺顺序）+ ←↓→
        key("⌃", "ctrl", nil, 1, { mod = "ctrl" }),
        key("⌥", "alt", nil, 1, { mod = "alt" }),
        key("⌘", "cmd", nil, 1.25, { mod = "cmd" }),
        key("", "space", nil, 5.5),
        key("⌘", "cmd", nil, 1.25, { mod = "cmd" }),
        key("fn", "fn", nil, 1, { mod = "fn" }),
        key("⌥", "alt", nil, 1, { mod = "alt" }),
        key("⌃", "ctrl", nil, 1, { mod = "ctrl" }),
        key("←", "left", nil, 1, { rep = true }),
        key("↓", "down", nil, 1, { rep = true }),
        key("→", "right", nil, 1, { rep = true }),
    },
}

--- 面板总宽高（取**最宽的一行**算）。
---
--- ⚠️ 宽度公式必须按「实际排出来的像素」算，不能想当然：
--- 键宽是 `w*unit + (w-1)*gap`（2 单位的键内部自带 1 个 gap），键与键之间再
--- 加 1 个 gap。整行排完 = `units*unit + (units-1)*gap`，**与这一行有几个键
--- 无关**。旧公式写成 `units*unit + (#row-1)*gap`，把「键数」当成了「单位
--- 数」，两者只要不相等就少算 `units - #row` 个 gap —— 旧布局 F 排
--- units=15/#row=13，面板比内容窄 2×gap，最右一列键（F12/⌫/\ /⏎/⇧/→）
--- 全都戳出面板背景之外。
local function panelSize()
    local w = 0
    for _, row in ipairs(LAYOUT) do
        local units = 0
        for _, k in ipairs(row) do units = units + k.w end
        w = math.max(w, units * M.unit + (units - 1) * M.gap)
    end
    local h = M.handleH + M.gap
        + #LAYOUT * M.keyH + (#LAYOUT - 1) * M.gap + M.pad * 2
    return w + M.pad * 2, h
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

--- FN 换键层：FN 上膛后按这些键，发出的**不是**「fn+原键」而是换掉的键。
---
--- **为什么必须这样**（2026-10-05）：实体键盘上的 FN 是**固件层**的东西——
--- 按下 FN+F1 时键盘自己就换了一个 HID usage 码发给电脑（F1 → 亮度减），
--- macOS 从头到尾**没收到过「fn 修饰键」**，`fn` 只是系统事后补出来的一个
--- 标志。而我们这种软件键盘只能发 CGEvent：给事件挂 `fn` 标志位，绝大多数
--- App 直接忽略它（它们本来就没打算处理 fn），于是不管怎么点都没反应。
--- 要让 FN 真有用，只能**在发送端就把键换掉**，模拟固件干的那件事。
---
--- 换键表照 Apple 的实际映射：F1/F2 亮度，F7~F9 媒体播放，F10~F12 音量，
--- 以及 Mac 上 fn+方向键 = Home/End/PgUp/PgDn、fn+delete = 向前删除。
--- F3~F6（调度中心/启动台/听写等）没有对应的系统键事件，只能原样透传。
---
--- `sys` = `hs.eventtap.event.newSystemKeyEvent` 的名字（媒体/亮度这类
--- 特殊键只能走这条路，keyStroke 打不出它们）；`k` = 换成另一个普通键。
local FN_MAP = {
    f1 = { sys = "BRIGHTNESS_DOWN" }, f2 = { sys = "BRIGHTNESS_UP" },
    f7 = { sys = "PREVIOUS" }, f8 = { sys = "PLAY" }, f9 = { sys = "NEXT" },
    f10 = { sys = "MUTE" }, f11 = { sys = "SOUND_DOWN" },
    f12 = { sys = "SOUND_UP" },
    delete = { k = "forwarddelete" },   -- fn+Backspace = 向前删除（Mac 惯例）
    left   = { k = "home" },  right  = { k = "end" },
    up     = { k = "pageup" }, down  = { k = "pagedown" },
}

--- 发一个键。修饰键用 sticky 状态拼 mods 表，发完清空。
---
--- **M.armed 的初始化与这里的清空是同一份「修饰键清单」的两处副本**，
--- 新增修饰键必须两处一起改（2026-10-05 加 fn 时就是这么做的）。
---
--- **为什么坚持整表重建、不用逐项置 false**：反向验证实测过——把 fn 从清空
--- 表里漏掉，结果是 `M.armed.fn` 变成 **nil 而不是残留 true**，Lua 里 nil 是
--- 假值，所以**并不会**「永久上膛粘住后面每个键」（我一开始在注释里这么写，
--- 是错的）。整表重建把漏项的后果从「永久卡住」降级成「这个键用不了」，
--- 这是它比逐项置 false 更稳的真正原因。代价是 `M.armed.fn == false` 这类
--- 严格比较会失败（nil ~= false），测试里那条断言正是靠这个抓到漏项的。
local function sendKey(def)
    -- 组合键（⌘C/⌘V）：整组直发，**不掺 sticky 状态**——用户上着 ⇧ 时点
    -- ⌘C，期望的仍然是拷贝而不是别的快捷键；发完照例清空 armed。
    if def.combo then
        hs.eventtap.keyStroke(def.combo.mods, def.combo.k, 0)
        M.armed = { shift = false, ctrl = false, alt = false, cmd = false, fn = false }
        return
    end
    local mods = {}
    local shift = M.armed.shift
    if isLetter(def) and M.caps then shift = not shift end
    if shift            then mods[#mods + 1] = "shift" end
    if M.armed.ctrl     then mods[#mods + 1] = "ctrl" end
    if M.armed.alt      then mods[#mods + 1] = "alt" end
    if M.armed.cmd      then mods[#mods + 1] = "cmd" end

    -- FN 换键层：命中换键表就整组替换掉（见 FN_MAP 头注释里「为什么」）。
    -- 其它 sticky 修饰键**保留**：真 Mac 上 fn+⇧+← 就是「选到行首」，
    -- 换键不该把 ⇧ 吃掉。
    if M.armed.fn and def.k and FN_MAP[def.k] then
        local m = FN_MAP[def.k]
        if m.sys then
            hs.eventtap.event.newSystemKeyEvent(m.sys, true):post()
            hs.eventtap.event.newSystemKeyEvent(m.sys, false):post()
        else
            hs.eventtap.keyStroke(mods, m.k, 0)
        end
        M.armed = { shift = false, ctrl = false, alt = false, cmd = false, fn = false }
        return
    end

    -- 没命中换键表：仍然挂 fn 标志位发出去（原样透传，App 认不认看它自己）。
    if M.armed.fn       then mods[#mods + 1] = "fn" end
    hs.eventtap.keyStroke(mods, def.k, 0)
    M.armed = { shift = false, ctrl = false, alt = false, cmd = false, fn = false }
end

--- **实体 FN 事件的原始存档**（2026-10-05 探针实测拿到数据后才有的做法）。
---
--- 探针实测（`/tmp/hs-fn-probe.log`，Lin 用洛菲小顺按的）：
---   keyDown       keyCode=0  key=a   flags=0x100              ← 普通键
---   flagsChanged  keyCode=55 key=cmd flags=cmd  0x100108       ← ⌘ 走 flagsChanged
---   systemDefined keyCode=0  key=a   flags=fn   0x800100       ← ★ 实体 FN
---
--- **实体 FN 走的是 `systemDefined`（NSEventTypeSystemDefined = 14）**，
--- flags 里带 0x800000（NX_SECONDARYFNMASK）—— 光用 `flagsChanged` 造不出来，
--- 而我们此前合成的 `newKeyEvent({"fn"}, "fn", …)` 是 keyDown + keyUp，
--- **形态对不上**，这就是「点了没反应」的真正原因。
--- （2026-10-05 第三轮补正：实体 FN **不是只有** systemDefined，它是「系统通道
---  + 修饰键通道」两条一起来 —— 详见下面「一次实体 FN 敲击 = 一串事件」。）
---
--- `asData()` / `newEventFromData()` 让这件事有正解：**把实体事件原样录下来，
--- 回放时原样重建**。好处是不必搞清楚 subtype / data1 / data2 到底是什么——
--- 那几个值 Hammerspoon 的 `getRawEventData()` 根本没暴露。
---
--- 采集：设 `M.fnCaptureOn = true` 后 Reload，**慢慢按实体 FN 一下**（按下、停顿
--- 一下、再松开）即自动存档。采完把 `M.fnCaptureOn` 设回 false（免得误覆盖）。
M.fnDataPath  = os.getenv("HOME") .. "/.hammerspoon/fn-event.dat"
--- **默认关闭**（2026-10-18 修）。这个开关曾经长期是 true，而它开着的时候：
--- ① 每次 reload 后 `M.probeSeconds` 会自动开录 120 秒，期间每次按键都同步
--- 落盘（打字直接背上文件 I/O）；② 这 120 秒内第一次实体 FN 会**覆盖**
--- fn-event.dat（saveFnData 无备份）——辛苦录的存档可能被一次误触替换。
--- 「诊断完就关」不能靠记性，默认值就必须是关。要采集时控制台手动开：
---   hs.osk.fnCaptureOn = true → Reload → 慢慢按一下实体 FN
M.fnCaptureOn = false    -- 采集期手动打开；拿到存档后设回 false

--- **一次实体 FN 敲击 = 一串事件，不是「一个 down + 一个 up」**（2026-10-05 实测）。
---
--- 日志里一次「按下 → 松开」实际连发 4 条：
---   ① systemDefined kc=0   flags=0x20800000   按下
---   ② flagsChanged  kc=63  flags=0x20800000   按下（伴随，0.5ms 后）
---   ③ systemDefined kc=0   flags=0x20000100   **抬起**（约 70ms 后）
---   ④ flagsChanged  kc=63  flags=0x20000100   抬起（伴随）
---
--- 旧写法「一条按下一条抬起交替落位」，把 ② 当成了抬起 —— 存档是 down+down，
--- 回放等于把 FN 按下去**再也不松手**，听写当然不理。破绽藏在间隔里：
--- 存下来的 down→up 只有 **0.2ms**，人手做不到。
--- ⇒ 判据改为只看 fn 标志位：**为 1 全归按下组、为 0 全归抬起组**，整串按原
---   顺序原间隔回放。见 `record()` 里的采集段。
local fnSeq = nil                        -- { {dir="D"/"U", data=<bytes>, ms=<距上一条>}, … }
local fnSeqBase, fnSeqPrev, fnSeqClosing = nil, nil, nil   -- 仅采集期用

--- **标记「接下来 0.3 秒内是自己发的」**。
---
--- 探针会把我们自己 post 出去的事件也录进去，而它跟实体按键长得几乎一样——
--- 光看日志**根本分不清哪条是实体的、哪条是合成的**，这样 A/B 对照就废了
--- （2026-10-05 第一次看日志就差点搞反）。发之前打这个戳，探针据此标注。
local synthFnUntil = 0
local function markSynthFn()
    synthFnUntil = hs.timer.absoluteTime() + 3e8
end

local function hexOf(s)
    return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end
local function unhex(h)
    return (h:gsub("%x%x", function(p) return string.char(tonumber(p, 16)) end))
end

--- 存档格式（v2，文本可读）：一行 `#v2` 头，之后每行一条事件
---   `D <hex> <距上一条毫秒>`  按下组
---   `U <hex> <距上一条毫秒>`  抬起组
--- 间隔照抄实体实测值：①~② 只有 0.x ms，①~③ 是真实按压时长（70ms 上下），
--- 回放时一并还原才像真的。
local function saveFnData()
    if not (fnSeq and #fnSeq >= 2) then return end
    local f = io.open(M.fnDataPath, "w")
    if not f then return end
    f:write("#v2 实体 FN 一次敲击的事件序列：D=按下 U=抬起，数字=距上一条毫秒\n")
    for _, e in ipairs(fnSeq) do
        f:write(string.format("%s %s %.1f\n", e.dir, hexOf(e.data), e.ms or 0))
    end
    f:close()
end

local function loadFnData()
    local f = io.open(M.fnDataPath, "r")
    if not f then return end
    local seq = {}
    for line in f:lines() do
        local dir, hex, ms = line:match("^(%a) (%x+) ([%d%.]+)$")
        if dir and hex then
            local d = unhex(hex)
            if d and #d > 0 then
                seq[#seq + 1] = { dir = dir, data = d, ms = tonumber(ms) or 0 }
            end
        end
    end
    f:close()
    -- **必须按下组、抬起组都有**：只有一半的存档（down+down / up+up）用起来
    -- 等于「按住不松」或「空抬」，比没有存档更糟 —— 宁可退回手工合成。
    local hasD, hasU = false, false
    for _, e in ipairs(seq) do
        if e.dir == "D" then hasD = true elseif e.dir == "U" then hasU = true end
    end
    if hasD and hasU then fnSeq = seq end
end
pcall(loadFnData)

--- 有没有拿到实体 FN 的存档（诊断用，控制台 `hs.osk.fnDataStatus()`）
function M.fnDataStatus()
    local nD, nU = 0, 0
    for _, e in ipairs(fnSeq or {}) do
        if e.dir == "D" then nD = nD + 1 elseif e.dir == "U" then nU = nU + 1 end
    end
    return string.format("capture=%s 序列=%d条(按下%d/抬起%d) path=%s",
        tostring(M.fnCaptureOn), fnSeq and #fnSeq or 0, nD, nU, M.fnDataPath)
end

--- 重读存档（换键盘、或刚录完不想 Reload 整个 config 时用）。
--- 先清再加：坏档（只有按下没有抬起的那种）不会被采纳，FN 退回手工合成，
--- 不会因为有半个档就变成死键。
function M.fnReload()
    fnSeq = nil
    pcall(loadFnData)
    return M.fnDataStatus()
end

--- **真按一次 fn 键**（按下 + 抬起）。
---
--- **为什么 FN 光「上膛」还不够**：上膛只是改了我们自己的 `M.armed`，一个键也
--- 没发出去。那些「连按两次 Fn」类的系统快捷键（macOS 听写默认就有这一项：
--- 系统设置 → 键盘 → 听写 → 快捷键 →「按 Fn 键两次」）因此永远触发不了——
--- 用户点两下 FN，系统一次 fn 按下都没收到。实体键盘每按一次 Fn 都是一次
--- 真实的「fn 按下 + 抬起」，所以这里照做：**点一下 = 真按一次，连点两下 =
--- 真按两次 = 双击 Fn**，听写那类快捷键就能触发了。
---
--- **为什么不用 `hs.eventtap.keyStroke({"fn"}, "fn")`**：keyStroke 会把同一份
--- mods 同时用在按下和抬起两个事件上（见 eventtap.lua 源码 275/277 行），
--- 拿它发修饰键的话，**抬起事件里 fn 标志位仍然是 1**，系统认为 fn 一直按着没松。
--- 所以必须手工发：按下带 fn 标志位、抬起清空标志位。
---
--- **有实体存档时整串原样回放**（形态一致，这是唯一能对上系统检测的做法）；
--- 没有存档才退回手工合成的合成事件（形态不对，但至少不是死键）。
---
--- pcall 包住是因为 posting 在 tap 回调里，抛异常会让系统禁用整个 tap。
---
--- FN 回放的状态：令牌 + 待执行的定时器句柄。
--- 为什么需要：回放是「发一条 → 等 70ms → 发下一条」的异步序列。快速连点
--- 屏幕 FN 时，两串回放会通过 doAfter 交错（D,D,D,U,U,U 或更乱），系统侧
--- 「按 Fn 两次」的检测可能误判；hide() 之后 doAfter 仍会把 FN 事件打到
--- 任意前台 App。令牌 + 句柄表让「新点击」和「hide」都能作废未完成的序列。
local fnPlayToken = 0
local fnPlayTimers = {}

--- 作废正在进行中的 FN 回放：令牌 +1（旧 step 闭包发现自己过期就静默返回），
--- 停掉所有待执行的 doAfter。**对任何状态都可调用**（幂等）。
local function cancelFnSeq()
    fnPlayToken = fnPlayToken + 1
    for _, t in ipairs(fnPlayTimers) do
        pcall(function() t:stop() end)
    end
    fnPlayTimers = {}
end

--- 回放按存档里的实测间隔走：组内 0.x ms 的连发**直接接着发**（排 doAfter 反而
--- 被定时器的几毫秒粒度拉歪），组间 70ms 那种才真的等一下。
local function playFnSeq()
    if not (fnSeq and #fnSeq > 0) then return false end
    -- 先作废上一次没回放完的（快速连点场景），再开始新的一串
    cancelFnSeq()
    -- 先造第一条：造不出来说明存档跟这台机器对不上（换过键盘/系统升级过），
    -- 立刻返回 false 让 tapFnKey 退回手工合成，别让 FN 变死键。
    -- **造出来就留着用**：拿它探完再扔、回放时又造一遍，等于同一条事件造两次。
    local okFirst, first = pcall(function()
        return hs.eventtap.event.newEventFromData(fnSeq[1].data)
    end)
    if not okFirst or not first then return false end
    local myToken = fnPlayToken
    local i = 0
    local step
    step = function()
        if myToken ~= fnPlayToken then return end   -- 被取消/被新一轮取代
        i = i + 1
        local e = fnSeq[i]
        if not e then return end
        pcall(function()
            markSynthFn()
            local ev = (i == 1) and first or hs.eventtap.event.newEventFromData(e.data)
            if ev then ev:post() end
        end)
        if i < #fnSeq then
            local d = fnSeq[i + 1].ms or 0
            if d >= 5 then
                -- 句柄记账：cancelFnSeq 靠这个表把「还没发生」的步骤停掉
                fnPlayTimers[#fnPlayTimers + 1] = hs.timer.doAfter(d / 1000, step)
            else step() end
        end
    end
    step()
    return true
end

local function tapFnKey()
    -- 有存档且回放成功就完事；存档缺失/不可用（playFnSeq 返回 false）或回放
    -- 本身抛错，都退回手工合成，别让 FN 变成死键。
    local ok, played = pcall(playFnSeq)
    if ok and played then return end
    pcall(function()
        markSynthFn()
        hs.eventtap.event.newKeyEvent({ "fn" }, "fn", true):post()
        hs.eventtap.event.newKeyEvent({}, "fn", false):post()
    end)
end

--- 键帽当前该显示什么：字母看 caps/shift，其它看 shift 层定义。
local function labelFor(def)
    -- combo 键的 k 是 nil（防止误当普通键发出去），必须先挡掉，
    -- 否则下面 isLetter 的 def.k:find 会崩。
    if def.combo or def.mod or def.special then return def.t end
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
    -- **任何新键按下都先停掉连发**（2026-10-18 修）。旧逻辑只在「松开的键
    -- 自己是 rep」时停，于是「按住 ⌫ 连发 → 中途按一下别的键 → 松开」这条
    -- 序列里没有任何一环碰那个定时器：⌫ 的连发会永远跑下去，只能收起键盘
    -- 才能救。触控板多指操作很容易触发；reload 时正按住 rep 键还会跨 reload
    -- 永久连发。startRepeat 内部也有 stopRepeat，这里不冲突。
    stopRepeat()
    if def.mod then
        -- FN 除了上膛还要**真的发一次 fn 键**：只上膛不发键的话，「连按两次
        -- Fn」这类系统快捷键（听写）永远触发不了。见 tapFnKey 头注释。
        if def.mod == "fn" then tapFnKey() end
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
    if ok and isHammerspoon(front) then
        -- activate() 也包一层（2026-10-18 修）：它在 timer 回调里，
        -- 目标 App 刚退出时会抛；虽然 timer 抛错只损失这一次还焦点，
        -- 但四个时间点少一个就多一分「焦点留在 Hammerspoon」的概率。
        pcall(function() M._targetApp:activate() end)
    end
end

--------------------------------------------------------------------------------
-- 位置：躲开输入焦点（光标 / 输入框）
--------------------------------------------------------------------------------

--- 诊断日志：/tmp/osk-ax.log。
--- 「键盘为什么没躲开」在屏幕上完全看不出来（不报错、也没提示），不看日志
--- 只能猜：到底是 AX 没给出焦点、还是给了但取不到光标矩形、还是矩形太大
--- 没法避让。所以每次 show 都把探测链路逐条落盘，排查时先看这个文件。
--- 文件超过 256KB 自动截断，避免长期运行把 /tmp 撑爆。
---
--- **路径可注入（`M.logPath`）**，因为测试和真机共用同一个文件会互相污染：
--- 2026-10-03 我把 23:35 的测试输出当成真机日志读了好一会儿——日志里
--- `候选 focus/range 光标 (300,480 2x18)` 一看就是桩件的假坐标，
--- 而真机记录被埋在后面。**诊断日志被测试污染 = 诊断日志失效**。
--- 测试里设成 `/tmp/osk-ax-test.log` 之类，真机保持默认。
---
--- **本函数必须对任何参数都绝不抛异常**（2026-10-02 踩到）：
--- 它原来直接 `string.format(fmt, ...)`，而调用点传进来的坐标**可能带小数**
--- （`hs.mouse.absolutePosition()` 返回 CGFloat，x/y 可能是 700.5），
--- `%d` 遇到非整数就报 "number has no integer representation"。
--- 更糟的是 `mouseAnchor` 是在 `focusedInputInfo` 的 pcall **之外**调用的，
--- 于是这个「日志用错了格式」直接把 `M.show()` 打断 —— **日志成了故障源**：
--- 点菜单栏图标打开键盘都失败（2026-10-02 23:12 真机报错，堆栈见日志）。
---
--- 现在做两层保护：① 整段 pcall，格式化失败退回「原样拼 fmt + 参数」，
--- 保证这条诊断信息不丢；② 调用点一律改用 `%.0f` 这类能安全处理浮点的格式符。
--- 两层都要有——只做①会丢信息，只做②则下次有人再传个奇怪参数又会炸。
local function diag(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    if not ok then
        local raw = {}
        for i = 1, select("#", ...) do
            raw[#raw + 1] = tostring((select(i, ...)))
        end
        line = tostring(fmt) .. " (格式化失败, 参数: "
            .. table.concat(raw, ", ") .. ")"
    end
    local path = M.logPath or "/tmp/osk-ax.log"
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
    out:write(os.date("%F %T"), "  ", line, "\n")
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
--- **必须后台持续采样，不能只在 show() 时采一次**（2026-10-03 真机日志逼出来的）。
--- 上一版只在 `mouseAnchor()` 里采样，而它**只在打开键盘那一刻被调一次**，
--- 于是「停够了 0.4s」这个前提几乎永远不成立：用户点完输入框、移到菜单栏
--- 点图标（1~2s），这期间**一次都没采样过**，等 show() 第一次采样时账本
--- 还是空的。真机日志就是这么废掉的：
---   鼠标在动（或刚移动）(1136.0,14.0) → 不用它定位
--- y=14 是**菜单栏** —— 触发入口就在菜单栏，点它时鼠标必然在屏幕顶部。
--- 这不是「鼠标在动」的噪声，是**结构性失效**：拿「打开那一刻的鼠标位置」
--- 当输入区代理，在「点菜单栏图标打开」这条主路径下**永远错**。
---
--- 而真实动作序列是：**点输入框 →（停顿）→ 移到菜单栏 → 点图标**。
--- 输入区对应的是**那个停顿的位置**，不是最后的位置。
--- 所以改成常驻 timer 采样（`M.mousePollInterval`，默认 0.12s），
--- 记账「鼠标在这个点待了多久」，把**静置最久**的位置存成 `M._anchorBest`，
--- show 时用它。这样「刚才那一瞬间鼠标不在输入框」不再等于
--- 「没有输入框信息」，也不需要「连按两次键盘才生效」。
---
--- 用法上有一条重要限制（因为它只是个点，不是矩形）：
--- * **它只是个点，没有高度**，所以不能直接当容器用（点的高度是 0，
---   拿去跟面板比重叠毫无意义）。做法是把它当成「输入区的上沿提示」：
---   在鼠标位置**上方**加一个合理高度，得到一个「假想输入区」矩形，
---   让它只提供**下缘**这个信息——面板停在鼠标上方就不会压住点击处。
---   标记为 `precise`（它比整页容器精确得多，比真光标粗但足够用）。
--- 当前时间（秒）。优先单调时钟 `hs.timer.absoluteTime()`（纳秒，除 1e9 得秒），
--- 没有才退回 `os.time()`。
--- ⚠️ 两者量纲不同（前者是 Mach uptime 秒、后者是 epoch 秒，差着几十年），
--- 但**同一模块内只用这一个来源算差值**，所以 age 比较是一致的。别混着算。
--- @return number
local function nowSeconds()
    if hs.timer and hs.timer.absoluteTime then
        local ok, t = pcall(hs.timer.absoluteTime)
        if ok and t then return t / 1e9 end
    end
    return os.time()
end

--- 把一次采样记进「鼠标在哪儿停了多久」的账本。
---
--- **必须是后台持续调用，不能只在 show() 时调一次**（2026-10-03 真机日志逼出来的）：
--- 只在 show() 里采样的话，「停够了 mouseAnchorHold 秒」这个前提几乎永远
--- 不成立 —— 用户点完输入框、移到菜单栏点图标（1~2s），这期间**一次都没采样**，
--- 等 show() 第一次采样时账本还是空的。
local function sampleMouse(x, y)
    local now = nowSeconds()
    local last = M._mouse
    local still = 0
    if last and last.x == x and last.y == y then
        still = (last.still or 0) + math.max(0, now - (last.t or now))
    end
    -- **累积必须封顶**：不起这个帽，「史上最久」判据会被一次长时间不动永久
    -- 夺走（见 M.mouseAnchorMaxStill 注释）。真实停顿 1~2 秒，30 秒够不着。
    still = math.min(still, M.mouseAnchorMaxStill or 30)
    M._mouse = { x = x, y = y, t = now, still = still }
    -- 静置够久就存成「候选输入区」。取**静置最久**的那个，不是最新那个：
    -- 最新那个大概率是菜单栏（点图标那一刻鼠标在屏幕顶部）。
    -- 候选同时存 `t`（记录时刻）—— mouseAnchor 靠它做陈旧判据，
    -- 只靠 still 分高下的判据在没有时间轴的情况下会被旧点永久霸榜。
    local best = M._anchorBest
    local hold = M.mouseAnchorHold or 0.25
    if still >= hold and (not best or still > best.still) then
        M._anchorBest = { x = x, y = y, still = still, t = now }
    end
end

--- 后台鼠标采样器。间隔比hold 小得多，保证「停了多久」记得准。
---
--- **必须由 `M.ensureMousePoll()` 在模块加载时就启动，不能等show()**。
--- 2026-10-03 10:40 真机日志给出的教训：
---   鼠标在 (1134,14 停了0.00s) → 假想输入区下缘 14
---   候选 mouse 光标 (1133,-106 2x120)
---   剔除屏幕外候选 mouse
--- `still=0.00s` 说明账本里**只有 show() 那一刻的一次采样**。
--- 原因：采样器原来是在 `mouseAnchor()` 里启动的，而 `mouseAnchor()`
--- 只在 `show()` 时才被调用 —— 于是「点输入框 → 停顿 → 移到菜单栏 → 点图标」
--- 这个**真实动作序列全程都没人记账**。计时器是「打开键盘那一刻」才上线的，
--- 而它要记的东西恰恰发生在**打开之前**。
--- 这就是「要连按两次键盘才生效」的残留：上一版把停驻判定修好了，
--- 却漏了「采样器何时上线」这个更底层的前提。
local function startMousePoll()
    if M._mouseTimer then return end
    if M.useMouse == false then return end
    local iv = M.mousePollInterval or 0.12
    local function tick()
        -- **整回调包 pcall**（2026-10-18 加固）：`hs.timer.doEvery` 的回调抛一次
        -- 异常，定时器就**永久停止且不恢复**（Hammerspoon 默认行为）。采样器是
        -- 整条鼠标避让链的源头，它静默死亡 = 避让功能静默没有了，而屏幕上
        -- 看不出任何异常。包住之后单次出错只损失一次采样。
        local ok, err = pcall(function()
            -- **世代检查**（2026-10-18 加）：被更新的模块取代了就停掉自己。
            -- reload 不会停 C 侧 timer，没有这道闸的话每次 reload 都静默多一个
            -- 0.12s 采样器永久在跑（旧闭包链持有旧 M，GC 收不走）。
            if _G.oskGen ~= GEN then
                if M._mouseTimer then pcall(function() M._mouseTimer:stop() end) end
                M._mouseTimer = nil
                return
            end
            if M.useMouse == false then return end
            local okP, pos = pcall(hs.mouse.absolutePosition)
            -- **函数名是 absolutePosition，不是 getAbsolutePosition**（查本机
            -- docs.json 确认）。写错会被 pcall 静默吞掉、整条路永不生效——
            -- 跟 A3 那次 pcall(app) 一模一样的坑。
            if okP and type(pos) == "table" and pos.x and pos.y then
                -- **取整再比较**：CGFloat 带小数时，同一物理位置两次读回可能差 0.5，
                -- 会被误判成「鼠标在动」，静置时间永远累积不起来。
                sampleMouse(math.floor(pos.x + 0.5), math.floor(pos.y + 0.5))
            end
        end)
        if not ok then
            diag("鼠标采样 tick 出错（已拦下，采样器继续跑）: %s", tostring(err))
        end
    end
    -- 把回调挂出来给测试驱动（测试里没有真timer，只能手动喂）。
    -- 这也顺带让「后台采样器到底有没有在跑」变成**可断言的**，
    -- 而不是只能靠真机看效果。
    M._mousePollTick = tick
    -- **API 名字必须查本机 docs.json 确认，别凭印象写**（2026-10-03 踩过）：
    -- 这里原来写的是 `hs.timer.doInterval` —— 真机报
    --   attempt to call a nil value (field 'doInterval')
    -- 周期定时器的真名是 **`doEvery`**（`hs.timer.doEvery(interval, fn)`）。
    --
    -- 为什么会查错：`docs.json` 里模块条目按类别分开，周期定时器全在
    -- **Constructor** 类别里（doAfter / doAt / doEvery / doUntil / doWhile /
    -- new / waitUntil / waitWhile），而 Function 类别只有 absoluteTime、
    -- days、usleep 这些**纯函数**。只 grep Function 就得出「hs.timer 没有
    -- 周期定时器」的错结论。查文档要**把所有类别都列一遍**。
    --
    -- 另外这里**不能裸调**：timer 建不起来（未来 API 改名、测试桩件缺失）
    -- 时异常会一路冒到 focusedInputInfo 的 pcall，把整条避让关掉。
    -- 建不起来就降级成「只在 show 时采样一次」，功能弱但不会更糟。
    local okT, res = pcall(hs.timer.doEvery, iv, tick)
    if okT and res then
        M._mouseTimer = res
    else
        M._mouseTimer = nil
        diag("后台鼠标采样器启动失败（%.2fs 一次）：%s —— 降级为只在 show 时采样",
            iv, tostring(res))
    end
end

--- 启动采样器的对外入口。**在模块加载末尾就调一次**（见文件末尾），
--- 这样「点输入框 → 停顿 → 点菜单栏图标」这段真实动作会被完整记账。
--- 重复调用安全（startMousePoll 内部有timer 去重）。
function M.ensureMousePoll()
    if M.avoidInput ~= true then return end
    if M.useMouse == false then return end
    startMousePoll()
end

--- 账本是否「有内容」。测试要能断言「采样器确实在跑」，
--- 否则会出现「真机从没记过账、测试却全绿」的情况（2026-10-03 踩过）。
function M._mousePollActive()
    return M._mouseTimer ~= nil
end

local function mouseAnchor()
    if M.avoidInput ~= true then return nil end
    if M.useMouse == false then return nil end
    startMousePoll()
    -- **这里刻意不再采样**（2026-10-03 10:40 真机教训）。
    --
    -- 原来有一句「读一次当前鼠标位置兜底」，看着无害，实际有两个害处：
    -- ① show() 这一刻鼠标在**菜单栏**（点图标打开的必然结果），这次采样
    --    会把菜单栏位置塞进账本。show() 后面往往紧接着还有第二次调用
    --    （拖动、focus 变化触发重定位），那时 `_anchorBest` 已经是菜单栏了。
    -- ② 它让「show 时钟」参与记账，破坏账本的时间语义 —— 账本应该只由
    --    后台采样器匀速写入，才能代表「鼠标在哪儿待了多久」。
    --
    -- 后台采样器现在从**模块加载时**就上线（见 M.ensureMousePoll），
    -- 到show 时账本早已有内容，这里只读、不写。
    local cur = M._mouse
    if not cur then
        -- 账本空：只有「采样器刚启动、还没跑过一次」才会这样。
        -- 兜底读一次当前位置**只用于返回**，绝不写进 _mouse/_anchorBest。
        local ok, pos = pcall(hs.mouse.absolutePosition)
        if ok and type(pos) == "table" and pos.x and pos.y then
            local x, y = math.floor(pos.x + 0.5), math.floor(pos.y + 0.5)
            local h0 = M.mouseAnchorHeight or 120
            diag("鼠标账本还是空的（采样器刚上线？）→ 兜底用当前位置 (%.0f,%.0f)", x, y)
            return { x = x - 1, y = y - h0, w = 2, h = h0 }
        end
        diag("鼠标位置读不到（pcall 失败且账本为空）")
        return nil
    end

    -- **优先用「静置最久的历史位置」**，不是当前这一瞬间。
    --
    -- 2026-10-03 09:58 / 10:40 真机日志：
    --   鼠标在 (1136.0,14.0) / 鼠标在 (1134,14 停了0.00s)
    -- y=14 是**菜单栏** —— 触发入口就在菜单栏，点它时鼠标必然在屏幕顶部。
    -- 这不是「鼠标在动」的噪声，而是**结构性失效**：拿「打开那一刻的鼠标
    -- 位置」当输入区代理，在「点菜单栏图标打开」这条主路径下**永远错**。
    --
    -- 真实动作序列是：**点输入框 →（停顿）→ 移到菜单栏 → 点图标**。
    -- 输入区对应的是**那个停顿的位置**，不是最后的位置。
    local best = M._anchorBest
    local h = M.mouseAnchorHeight or 120
    local px, py
    if best then
        -- **陈旧判据（2026-10-18 修）**：锚点只代表「不久前鼠标在哪儿停了最久」。
        -- 没有这道判据时，「史上最久」是一个永久霸榜的位子：起身半小时回来，
        -- 旧点（still 已封顶 30s）照样压得住输入框前的真实停顿 —— 键盘会盖住
        -- 真正的输入框，而且这个状态**不自愈**（新点必须超过史上记录才能翻身）。
        -- 主路径「停顿→移菜单栏→点图标」全程 1~2 秒，远小于保质期，不受影响。
        local age = best.t and (nowSeconds() - best.t) or 0
        if age > (M.mouseAnchorMaxAge or 60) then
            diag("鼠标静置点 (%.0f,%.0f) 已陈旧（%.0fs 前）→ 弃用，退回当前位置",
                best.x, best.y, age)
            M._anchorBest = nil
            best = nil
        end
    end
    if best then
        px, py = best.x, best.y
        diag("用鼠标历史静置点 (%.0f,%.0f 停了%.2fs) → 假想输入区下缘 %.0f",
            px, py, best.still, py)
    else
        px, py = cur.x, cur.y
        diag("鼠标在 (%.0f,%.0f 停了%.2fs) → 假想输入区下缘 %.0f",
            px, py, cur.still or 0, py)
    end
    -- 点→矩形：在鼠标**上方**造一个「假想输入区」，只提供下缘。
    -- 高度取 120 是经验值：够覆盖常见输入框（单行/多行几行）的高度，
    -- 又不会像整页容器那样让避让判断失效。
    --
    -- **这个假想区必须整个落在屏幕内才有意义**（2026-10-03 10:40 真机）。
    -- 账本里若只有菜单栏那个停顿点（py≈14），造出来的矩形是
    --   (1133,-106 2x120) —— 挂在屏幕**顶部之外**，代表「输入区在屏幕外」，
    -- 这不是信息，是噪声：它必然被后面的「剔除屏幕外候选」干掉，
    -- 结果等于白跑一圈再回到贴底（真机日志实测）。
    -- 与其造一个假矩形去影响落位，不如**在这里就认输**，
    -- 让日志明确写出「放弃鼠标避让」而不是「剔除屏幕外候选」——
    -- 后者会让人误以为「探测到了但位置不对」，前者才说得清真相。
    --
    -- 判据用「假想区上沿是否在主屏内」，**不是「best 是否等于 cur」**：
    -- 用快捷键（非菜单栏）触发时，唯一的停顿点恰好就是当前点，
    -- 那完全合法，不该被这条判据毙掉。
    local f = hs.screen.mainScreen():frame()
    if py - h < f.y then
        diag("鼠标停顿点 (%.0f,%.0f) 太高，造出的假想输入区上沿 %.0f 在屏幕 %.0f 之外"
            .. " → 放弃鼠标避让（这条线索对菜单栏触发没有意义）",
            px, py, py - h, f.y)
        return nil
    end
    -- **坐标已取整**：几何量带小数一路传到 M._frame.y，会让「点是否落在
    -- 面板内」的边界判断出现 0.5px 模糊带；取整也让日志里的 %d 安全。
    return { x = px - 1, y = py - h, w = 2, h = h }
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

--- 矩形是否**真的可用**（x/y 必须是数字，w/h 缺省当 0）。
---
--- 2026-10-02 真机踩坑：这里原来只检查「是数字」，于是
--- `AXBoundsForRange` 返回的 **`0x0` 空矩形**（x=0 y=1000 w=0 h=0）被当成有效
--- 候选——而它在屏幕外，紧接着「输入区不在主屏上」把**整个避让关掉**，
--- 键盘照样压住输入框。日志原文：
---   候选 d1.Group/range 光标 (0,1000 0x0)
---   输入区不在主屏上 → 不做避让
--- 所以必须要求**有面积**。但「有面积」的判据要说准：
--- * **w>0 且 h>0** —— 正常情况（含细光标 h=0 那种，见下）
--- * **w 和 h 不能同时为 0** —— 这才是真正没用的空矩形
---
--- 注意**不能要求 h>0**：有些 App 给的插入点就是零高度（一条线），
--- `choosePosition` 里本来就为此做了「高度 0 按一行估高 18」的处理。
--- 一开始我写成 `w > 0 and h > 0`，把零高度光标也毙了，导致本来能用的
--- 候选降级掉、面板退回贴底（测试当场抓到）。
---
--- **这个函数必须定义在 dumpAXTree 之前**（2026-10-03 真机 bug）：
--- 它原本在 dumpAXTree **后面**，而 Lua 里后面 local 的函数在前面不可见
--- → dump 走到判据 2 就抛
---   attempt to call a nil value (global 'rectOf')
--- 子节点 pcall 把它记成一行 `!! walk 失败`，**dump 报告里的
--- 「可编辑文本区」于是永远是「一个都没有」**——也就是说这个诊断工具
--- 从上线起就没显示过一个可编辑区，我据此得出的「Electron 不暴露 AX」
--- 结论一直是错的。修之前先给它补了测试。
---
--- 2026-10-02 真机踩坑：这里原来只检查「是数字」，于是
--- `AXBoundsForRange` 返回的 **`0x0` 空矩形**（x=0 y=1000 w=0 h=0）被当成有效
--- 候选——而它在屏幕外，紧接着「输入区不在主屏上」把**整个避让关掉**，
local function validRect(r)
    if type(r) ~= "table" then return false end
    local x, y = tonumber(r.x), tonumber(r.y)
    local w, h = tonumber(r.w or 0), tonumber(r.h or 0)
    if x == nil or y == nil or w == nil or h == nil then return false end
    if w < 0 or h < 0 then return false end
    return (w > 0 and h > 0) or (w > 0 or h > 0)   -- 即：不是 0x0
end

local function rectOf(b)
    if not validRect(b) then return nil end
    return { x = b.x, y = b.y, w = b.w or 0, h = b.h or 0 }
end

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

    -- 路径跟着 diag 走（测试注入到别处，避免覆盖真机的诊断文件）
    local path = (M.logPath and M.logPath:gsub("osk%-ax", "osk-axtree"))
        or "/tmp/osk-axtree.log"
    local f = io.open(path, "w")
    if not f then diag("dumpAXTree: 写不了 %s", path); return end
    f:write(string.format("=== %s  窗口「%s」  %s ===\n",
        os.date("%F %T"), win:title(), app:name()))

-- **counts.total 必须在这里初始化成 0**（2026-10-03 真机 bug）：
-- walk 第一行要判 `counts.total > 400`，而 nil 与数字比较会**直接抛错**
-- （"attempt to compare nil with number"）。于是 walk 在**第一个节点**
-- 就死掉、根层 pcall 又把错误吞了 → dump 只剩一行标题，报告写的是
-- 「共 0 个节点；walk 失败 0 个」，看起来像「WorkBuddy 一个 AX 节点都没有」，
-- 实际是**一个都没走成**。真相被工具自己掩盖了。
local counts, layers = { total = 0 }, {}
    -- 「能对选区给出有面积的矩形」的节点清单（= 真正的可编辑文本区）。
    -- A2 的判据 2 就是这个口径，这里用同样口径才能直接对照。
    local selHits = {}
    local emptyHits = {}
    -- 2026-10-03 09:58 真机踩坑：dump 跑完只剩一行标题、树是空的。
    -- 原因是 walk 内部**任何一个节点读AX 抛异常**，整个 walk 就被中断，
    -- 而 dumpAXTree 是被 `pcall(M.dumpAXTree)` 调用的 → 异常被静默吞掉，
    -- 什么也没写出来。**自动诊断工具自己崩了却一声不吭**，比不 dump 更糟：
    -- 它让人以为「树里真的什么都没有」，实际是没写出来。
    -- 所以每个节点都包一层 pcall，坏节点跳过、其余照常写。
    local walkErrors = 0
    local function walk(el, depth, pathStr)
      if depth > 8 or counts.total > 400 then return end
      counts.total = (counts.total or 0) + 1
      local role = axAttr(el, "AXRole") or "?"
      counts[role] = (counts[role] or 0) + 1
      layers[depth] = layers[depth] or 0
      layers[depth] = layers[depth] + 1

      -- 能不能**对选区给出有面积的矩形**？能 → 它就是可编辑文本区。
      -- 注意这里跟 A2 的判据 2 是**同一个口径**：只判「选区非 nil」会把
      -- Chromium 那堆返回 {location=0,length=0} 空选区的 AXGroup 全算进来
      -- （真机日志就是这么把一个 0x0 的屏外矩形当成唯一候选的）。
      local flag = ""
      if TEXT_ROLE_SET[role] then
          flag = "  <<< 文本 role"
      else
          local sel = axAttr(el, "AXSelectedTextRange")
          if sel == nil then sel = axAttr(el, "AXSelectedTextRanges") end
          if type(sel) == "table" then
              local one = sel.location and sel or sel[1]
              if type(one) == "table" and tonumber(one.location) then
                  local b = rectOf(axParam(el, "AXBoundsForRange", one))
                  if b then
                      flag = "  <<< 可编辑(有面积的选区)"
                      selHits[#selHits + 1] = string.format(
                          "%s%s  depth=%d  (%.0f,%.0f %.0fx%.0f)",
                          pathStr, role, depth, b.x, b.y, b.w, b.h)
                  else
                      flag = "  (空选区，无矩形 → 不是可编辑区)"
                      emptyHits[#emptyHits + 1] = string.format(
                          "%s%s  depth=%d", pathStr, role, depth)
                  end
              end
          end
      end

      -- 有矩形的节点才可能是输入区，记下来。
      -- **坐标一律用 %.0f 并取整**：AX 返回的是 CGFloat（可能 700.5），
      -- `%d` 遇到非整数直接抛 "number has no integer representation"
      -- （2026-10-02 已经在 diag 上踩过一次，见上面diag 的注释）。
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
              -- **每个子节点单独包 pcall**：一个坏节点不能毁掉整棵树的输出。
              -- （2026-10-03：dump 只剩一行标题就是这个原因）
              local okW, err = pcall(walk, kids[i], depth + 1, pathStr .. "  ")
              if not okW then
                  walkErrors = walkErrors + 1
                  f:write(string.format("%s  !! walk 失败: %s\n",
                      pathStr, tostring(err)))
              end
          end
      end
    end
    -- 根层 pcall 的返回值**必须记下来**。子节点的 pcall 记了，根层没记，
    -- 于是「walk 第一个节点就抛」这件事在报告里完全看不见（只显示
    -- 「0 个节点」，像是 App 没暴露任何东西）。诊断工具的失败路径
    -- 自己不能没有诊断。
    local okRoot, rootErr = pcall(walk, winEl, 0, "")
    if not okRoot then
        walkErrors = walkErrors + 1
        f:write(string.format("!! walk 根调用失败: %s\n", tostring(rootErr)))
    end

    if #selHits > 0 then
        f:write("\n--- 可编辑文本区（能对选区给出有面积的矩形）---\n")
        for _, l in ipairs(selHits) do f:write(l .. "\n") end
    else
        f:write("\n--- 可编辑文本区（能对选区给出有面积的矩形）：**一个都没有**---\n")
        f:write("(这个 App/窗口没把可编辑区暴露给 AX，或选区全是空的)\n")
    end
    if #emptyHits > 0 then
        f:write(string.format(
            "\n--- 有选区但拿不到矩形（判据2 已排除，共 %d 个）---\n",
            #emptyHits))
        for i = 1, math.min(#emptyHits, 15) do
            f:write(emptyHits[i] .. "\n")
        end
    end

    f:write("\n--- 各深度节点数 ---\n")
    for d = 0, 8 do
        if layers[d] then f:write(string.format("深度 %d: %d\n", d, layers[d])) end
    end
    f:write(string.format("\n共 %d 个节点；walk 失败 %d 个\n",
        counts.total or 0, walkErrors))
    if (counts.total or 0) == 0 then
        -- 这个分支是「诊断工具自己废了」的信号，必须显式写出来，
        -- 否则下次看到空文件会误判成「App 没暴露任何节点」。
        f:write("!! 一个节点都没walk 到 —— winEl 可能读不出 AXRole/AXChildren，\n")
        f:write("!! 或者 walk 在第一个节点就抛了（读 AX 失败会抛，不是返回 nil）。\n")
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
        -- **这两行必须在 pcall 里**（2026-10-18 修）：`:name()` / `:title()`
        -- 是裸调，而本函数被 show() 直接调（不在任何 pcall 里）。前台 App 在
        -- 「取 frontmostApplication」和「调 :name()」之间退出时，异常会一路冒到
        -- 菜单栏回调 —— 现象是「点图标打不开键盘」且一行日志都没有。
        -- 这正是 2026-10-02「diag 把 show() 打断」同一类事故的残留结构。
        pcall(function()
            diag("前台 App=%s 焦点窗口=%s",
                frontApp and frontApp:name() or "?",
                (win and win:title()) or "nil")
        end)
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
                        --
                        -- 判据2：**能对选区给出有面积的矩形**。
                        --
                        -- 关键在「有面积」这三个字。2026-10-02 真机踩过：Chromium 里
                        -- 很多 `AXGroup` 都会返回 `{location=0, length=0}` 这种**空选区**，
                        -- 只判「AXSelectedTextRange 不是 nil」会把它们全当成可编辑区——
                        -- 日志原文「A2 第 1 层命中 1 个文本元素」命中的是
                        -- `d1.Group/range 光标 (0,1000 0x0)`，0x0 且在屏幕外，
                        -- 紧接着「输入区不在主屏上」把整个避让关掉了。
                        --
                        -- 所以判据 2 必须**真的去问 AXBoundsForRange 要矩形**，
                        -- 并且要求矩形有面积（见 validRect）。空选区拿不到有效矩形，
                        -- 就当不是可编辑区——继续往下降找真正的输入框。
                        local byRole = (role and TEXT_ROLE_SET[role]) or false
                        local bySel = false
                        if not byRole then
                            local sel = axAttr(el, "AXSelectedTextRange")
                            if sel == nil then
                                sel = axAttr(el, "AXSelectedTextRanges")
                            end
                            if type(sel) == "table" then
                                -- 单数 {location=,length=}；复数是 {{location=,length=},...}
                                local one = sel.location and sel or sel[1]
                                if type(one) == "table" and tonumber(one.location) then
                                    local b = rectOf(axParam(el, "AXBoundsForRange", one))
                                    bySel = (b ~= nil)
                                end
                            end
                        end
                        if byRole or bySel then
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
                    -- **WorkBuddy 的 AX 树已实测确认**（2026-10-03 10:40，dump 工具
                    -- 修好之后拿到的真实数据）：整棵树**只有 9 个节点**，
                    -- role 分布是 AXWindow×1 / AXGroup×5 / AXButton×3，
                    -- **一个 AXTextField / AXTextArea 都没有**；那 5 个 AXGroup
                    -- 全是 `(0,30 1600x885)` 整窗大小 + 空选区。
                    --
                    -- 也就是说：**不是我们没找对 role，是 Electron 根本没把
                    -- 输入框暴露给 AX**。A2 这条路对 Electron/Chromium 类 App
                    -- 结构性无效，继续调深度/调白名单都是白费。
                    -- 保留它是因为它对**原生 App**（备忘录、Safari、终端…）
                    -- 仍然有效 —— 那里A1/A2 都好使。
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
    -- **外面再包一层 pcall**：定位失败顶多是「不避让」，绝不该让键盘显示不出来。
    -- （2026-10-02 真机踩过：这里原先直接调 mouseAnchor，而它内部一条 diag
    --  因为 %d 收到带小数的 CGFloat 抛了异常，一路上抛到 M.show() 外面，
    --  结果点菜单栏图标打开键盘直接失效——日志成了故障源。）
    local okM, mrect = pcall(mouseAnchor)
    if not okM then
        diag("mouseAnchor 抛异常（已忽略，改为不避让）: %s", tostring(mrect))
        mrect = nil
    end
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

    -- **剔除屏幕外的候选**（2026-10-02 真机踩坑）：原来这里只有一个「不在主屏上
    -- → 整个不做避让」的判断，于是**唯一那个坏候选会把避让整体关掉**——
    -- 键盘照样压住输入框。日志原文：
    --   候选 d1.Group/range 光标 (0,1000 0x0)
    --   输入区不在主屏上 → 不做避让
    -- 正确做法是**把坏的剔掉、拿剩下的**（鼠标位置那条路往往还在）。
    local f = hs.screen.mainScreen():frame()
    local kept = {}
    for _, c in ipairs(out) do
        local r = c.rect
        local cx, cy = r.x + (r.w or 0) / 2, r.y + (r.h or 0) / 2
        -- 中心点在屏幕内才算。留一点余量：输入框贴着屏幕边时中心可能刚好越界。
        if cx >= f.x - 1 and cx <= f.x + f.w + 1
           and cy >= f.y - 1 and cy <= f.y + f.h + 1 then
            kept[#kept + 1] = c
        else
            diag("剔除屏幕外候选 %s (%.0f,%.0f %.0fx%.0f)",
                c.src, r.x, r.y, r.w or 0, r.h or 0)
        end
    end
    out = kept
    if #out == 0 then
        diag("所有候选都在主屏外 → 不做避让")
        return nil
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
            local kw = def.w * M.unit + (def.w - 1) * M.gap
            -- 留白：只把 x 往前推，不画键、不进命中表
            if not def.spacer then
                def.id = "k" .. row .. "_" .. ci
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
            end
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
            -- 包 pcall（2026-10-18 加固）：watcher 回调抛错的后果没有文档保证，
            -- 而它整段都在「让面板保持最前」这条关键路径上。
            pcall(function()
                if event == hs.application.watcher.activated and M.isShowing() then
                    hs.timer.doAfter(0.05, M.raise)
                end
            end)
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
    cancelFnSeq()               -- 上一次没回放完的 FN 序列作废（见 playFnSeq）
    M._capturing = false
    M._drag = nil
    M._pressing = nil

    -- **清掉上一代遗留的画布**（2026-10-18 加）。reload 时旧画布是 C 侧对象、
    -- 不会跟着旧模块一起消失：旧 tap/看门狗/采样器靠世代令牌停，画布没人管。
    -- 上一代 show() 时把自己的 canvas 记在 _G.oskLastCanvas，这里认领后删掉。
    -- （记账在下面 build 之后做——此刻 M._canvas 还是上一代的残引用或 nil。）
    local lastCanvas = _G.oskLastCanvas
    if lastCanvas then
        pcall(function() lastCanvas:delete() end)
        diag("删掉了上一代模块遗留的画布（reload 前键盘开着）")
    end

    -- 记下打开前的输入目标（点击 kbswap 菜单栏图标不会改变前台，
    -- 所以这里拿到的就是用户正在打字的 App）
    M._targetApp = nil
    local ok, front = pcall(hs.window.frontmostApplication)
    if ok and front and not isHammerspoon(front) then M._targetApp = front end

    -- **mainScreen()/frame() 都要当可能抛的调用对待**（2026-10-18 修）：
    -- 所有屏幕都断开时 mainScreen() 返回 nil，`:frame()` 就是「index a nil
    -- value」，而这条路径整段在 pcall 之外 —— 异常会一路冒到调用 M.show()
    -- 的菜单栏回调，现象是「点图标打不开键盘」且没有任何日志。
    local okS, f = pcall(function() return hs.screen.mainScreen():frame() end)
    if not okS or not f then
        diag("mainScreen():frame() 拿不到（%s）→ 用全 0 兜底，面板会贴在 (0,0)",
            tostring(f))
        f = { x = 0, y = 0, w = 1440, h = 900 }
    end
    local w, h = panelSize()

    -- 躲开输入区：优先用光标所在的细条，拿不到就用整个输入框/输入区，
    -- 再拿不到就在焦点窗口里按 role 找（Electron/Chromium 类 App）。
    -- 输入区不在键盘这块屏幕上时不做避让 —— 两套屏幕坐标混用会算错位置。
    local info = nil
    if M.avoidInput then
        -- 屏幕外的候选已在 focusedInputInfo 里剔除（不剔除的话，
        -- **唯一一个坏候选会把避让整体关掉**，2026-10-02 真机踩过）。
        -- 这里不再重复判断，免得同一份坏逻辑二次否决。
        info = focusedInputInfo(M._targetApp)
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
    -- 记账给下一代：reload 前的画布只有这个全局引用能看到（见 show 开头的清理）。
    _G.oskLastCanvas = M._canvas

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
    M._watchdog = hs.timer.doEvery(5, function(t)
        -- 整回调包 pcall（2026-10-18 加固）：doEvery 回调抛一次定时器就永久停。
        -- 看门狗是 tap 被系统禁用后的最后保险，它死了没人知道。
        local ok, err = pcall(function()
            -- **世代检查**（2026-10-18 加）：本模块已被 reload 取代时，看门狗是
            -- 唯一还握着旧 tap 引用的周期回调——停下来之前顺手把旧 tap 也停掉，
            -- 否则旧 tap 跟着旧画布一起活在系统里（新模块无权停它）。
            if _G.oskGen ~= GEN then
                if M._tap then pcall(function() M._tap:stop() end) end
                pcall(function() t:stop() end)
                M._watchdog = nil
                return
            end
            if M.isShowing() and M._tap and not M._tap:isEnabled() then
                M._tap:start()
            end
        end)
        if not ok then
            diag("tap 看门狗出错（已拦下，看门狗继续跑）: %s", tostring(err))
        end
    end)
end

function M.hide()
    stopRepeat()
    cancelFnSeq()               -- 没回放完的 FN 序列作废，别把事件打到别的 App
    M._capturing = false
    M._drag = nil
    M._pressing = nil
    if M._canvas then M._canvas:hide() end
    if M._tap then M._tap:stop() end
    stopRaiseWatcher()
    if M._watchdog then M._watchdog:stop() end
    M._watchdog = nil
    -- 画布已隐藏，别再让下一代「清理」时去 delete 一个只是藏起来的对象
    _G.oskLastCanvas = nil
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

--- **模块一加载就让后台鼠标采样器上线**（2026-10-03 10:40 真机教训）。
---
--- 为什么必须放在这里、而不是等到 show()：采样器记的是「鼠标在哪儿停了
--- 多久」，而它要记的那段动作——「点输入框 → 停顿 → 移到菜单栏 → 点图标」
--- ——**发生在键盘被打开之前**。如果采样器在 show() 里才启动，它记的第一笔
--- 就是「鼠标此刻在菜单栏」，账本里永远只有那个无用的点
--- （真机日志实测：`鼠标在 (1134,14 停了0.00s)`，
---   接着 `候选 mouse 光标 (1133,-106 2x120)` 被当屏外剔除）。
---
--- 也就是说：**要让记账生效，就必须让它一直在跑**，而不是「用的时候才开」。
--- 这和「要连按两次键盘才生效」是同一个病根的最后一层。
pcall(M.ensureMousePoll)

-- ============================================================================
-- FN 真机探针（2026-10-05）
--
-- 存在的理由：实体键盘的 FN 是**固件层换键**——按 FN 时键盘自己换 HID usage
-- 码，macOS 可能只收到一条 flagsChanged、也可能**一条都收不到**。在没有实测
-- 数据之前，屏幕上这个 FN 按钮该怎么实现只能靠猜（我已经猜错两次了）。
--
-- 这个探针就是把猜测换成数据：录下按键时系统实际收到的事件类型、keyCode、
-- flags（含原始数值）。**只记 keyCode 和 flags，不记字符**——避免把密码写进日志。
--
-- 用法：设 M.probeSeconds > 0 后 Reload Config，探针在模块加载时自动启动；
--       或在控制台手动 `hs.osk.fnProbe(120)` / `hs.osk.fnProbeStop()`。
-- 日志落在 M.probeLog。**放在仓库里而不是 /tmp**：诊断日志的第一读者是人，
-- 藏在 /tmp 里等于没写（2026-10-05 Lin 找不着它）。
-- ============================================================================
M.probeLog     = os.getenv("HOME") .. "/.hammerspoon/.workbuddy/hs-fn-probe.log"
--- **默认 0 = 不自动开录**（2026-10-18 修）。曾经默认 120，于是每次 reload
--- 都自动录 2 分钟全键程。要录时控制台手动 `hs.osk.fnProbe(120)`，
--- 或临时把这个数改大——**别让诊断工具默认常开**（见 fnCaptureOn 的注释）。
M.probeSeconds = 0

do
    local tap, lastMs, nRec = nil, nil, 0
    local MAXREC = 500    -- 到量自动停，别把日志写爆

    --- keyCode -> 键名 的反查表（hs.keycodes.map 是 名字->keyCode，要反过来）
    local codeName = nil
    local function nameOf(code)
        if code == nil then return "-" end
        if not codeName then
            codeName = {}
            local ok, m = pcall(function() return hs.keycodes.map end)
            if ok and type(m) == "table" then
                for k, v in pairs(m) do
                    if type(v) == "number" then
                        codeName[v] = tostring(k)
                    elseif type(k) == "number" then
                        codeName[k] = tostring(v)
                    end
                end
            end
        end
        return codeName[code] or ("?" .. tostring(code))
    end

    local typeNames = nil
    local function typeOf(t)
        if not typeNames then
            typeNames = {}
            local ok, ts = pcall(function() return hs.eventtap.event.types end)
            if ok and type(ts) == "table" then
                for k, v in pairs(ts) do
                    if type(v) == "number" then typeNames[v] = tostring(k) end
                end
            end
        end
        return typeNames[t] or tostring(t)
    end

    local function dumpTbl(t, maxKeys)
        if type(t) ~= "table" then return tostring(t) end
        local parts, n = {}, 0
        for k, v in pairs(t) do
            n = n + 1
            if n > maxKeys then parts[#parts + 1] = "…"; break end
            local vs
            if type(v) == "table" then
                vs = "{tbl}"
            elseif type(v) == "number" then
                vs = string.format("0x%x", math.floor(v))
            else
                vs = tostring(v)
            end
            parts[#parts + 1] = tostring(k) .. "=" .. vs
        end
        table.sort(parts)
        return table.concat(parts, " ")
    end

    local function plog(fmt, ...)
        local ok, msg = pcall(string.format, fmt, ...)
        if not ok then msg = fmt end
        local f = io.open(M.probeLog, "a")
        if f then
            f:write(os.date("%F %T ") .. tostring(msg) .. "\n")
            f:close()
        end
    end

    --- 回调里**任何异常都会让整个 tap 静默停掉**，所以每一步都包 pcall。
    local function record(ev)
        local ok, err = pcall(function()
            local ms = hs.timer.absoluteTime() / 1e6
            local dt = lastMs and string.format("+%6.1fms", ms - lastMs) or "    首条"
            lastMs = ms

            local tName = typeOf(ev:getType())
            local kc    = ev:getKeyCode()
            local flags, flagsTbl = "?", nil
            pcall(function()
                local f = ev:getFlags()
                if type(f) == "table" then
                    flagsTbl = f
                    local p = {}
                    for _, nm in ipairs({ "cmd", "ctrl", "alt", "shift", "fn" }) do
                        if f[nm] then p[#p + 1] = nm end
                    end
                    flags = #p == 0 and "-" or table.concat(p, "+")
                end
            end)

            -- 原始 CGEventData：键名不确定，整表 dump 出来看全貌
            local raw, rawFlags = "-", nil
            pcall(function()
                local d = ev:getRawEventData()
                if type(d) == "table" and type(d.CGEventData) == "table" then
                    -- **flags 的原始数值**，采集判据要用：`flagsTbl` 只能看出
                    -- 「fn 位在不在」，看不出「整条 flags 是不是 0」——而背景
                    -- 噪声（不按键时也在发的 systemDefined flags=0x0）和被
                    -- 抬起的 FN（systemDefined 0x20000100）在 flagsTbl 里长得
                    -- 一模一样，只能靠原始数值分开。
                    local f = d.CGEventData.flags
                    if type(f) == "number" then rawFlags = f end
                    raw = dumpTbl(d.CGEventData, 14)
                end
            end)

            local isSynth = hs.timer.absoluteTime() < synthFnUntil
            local tag = ""
            if flagsTbl and flagsTbl.fn then
                tag = isSynth and "  ← 我们自己发的" or "  ← 实体键盘"
            end
            plog("%-14s %-13s keyCode=%-4s key=%-12s flags=%-18s%s | %s",
                tName, dt, tostring(kc), nameOf(kc), flags, tag, raw)

            -- **FN 采集**：按 **fn 标志位**分组，不是「一条按下一条抬起交替」。
            --
            -- 实体一次敲击连发 4 条（按下 2 条 + 抬起 2 条，见 fnSeq 处注释），
            -- 交替落位会把第 2 条按下当成抬起，存出 down+down 的废档
            -- （2026-10-05 第三轮就栽在这，破绽是 down→up 只有 0.2ms）。
            -- fn 位为 1 → 按下组；为 0 且在一次敲击之中 → 抬起组。抬起来过之后
            -- 等 0.4 秒收尾存档，期间不再收新按下（免得把下一敲混进这一串）。
            --
            -- 只采实体的：合成的事件自己也看得到，采它等于自我循环。
            if M.fnCaptureOn and not isSynth and flagsTbl
                and (tName == "systemDefined" or tName == "flagsChanged") then
                -- **flags 原始值为 0 = 背景噪声，一律不收**：那种 systemDefined
                -- 全程都在发（约 1~3 秒一对，不按键也有），混进存档等于在「按下」
                -- 和「抬起」之间插几条无关事件，回放就不是实体那串了。
                local noise = (type(rawFlags) == "number" and rawFlags == 0)
                local isFnDown = (flagsTbl.fn == true) and not fnSeqClosing
                -- 抬起也要查 fnSeqClosing（2026-10-18 修）：第一个 U 之后进入
                -- 0.4s 收尾期，期间不再收任何事件。旧判据漏了这一条，收尾期
                -- 内每个「kc=63 / systemDefined kc=0」都会被 splice 进存档
                -- —— 实测数据里一次 FN 敲击的抬起是 2 条（systemDefined kc=0
                -- + flagsChanged kc=63），多收的会在回放时误发出去。
                -- ⚠️ 已知限制：「按住 FN 期间按媒体键」（systemDefined、kc=0、
                -- flags 非 0 且无 fn 位）与抬起①的形态无法区分 —— 要加判据得
                -- 先有「FN+媒体键」的真机实录。当前 fn-event.dat 不存在，这条
                -- 路径不激活；采集到那种数据之前不加猜的判据。
                local isFnUp = (not flagsTbl.fn) and (fnSeqBase ~= nil) and not noise
                    and not fnSeqClosing
                    and (kc == 63 or (tName == "systemDefined" and kc == 0))
                if isFnDown or isFnUp then
                    pcall(function()
                        local data = ev:asData()
                        if type(data) == "string" and #data > 0 then
                            local now = hs.timer.absoluteTime() / 1e6
                            if not fnSeqBase then
                                fnSeq, fnSeqBase, fnSeqPrev = {}, now, nil
                            end
                            local ms = fnSeqPrev and (now - fnSeqPrev) or 0
                            local msTxt = fnSeqPrev and string.format("%.1fms", ms) or "—"
                            fnSeq[#fnSeq + 1] = {
                                dir = isFnDown and "D" or "U", data = data, ms = ms,
                            }
                            fnSeqPrev = now
                            plog("★ 捕获实体 FN %s（%d 字节，距上一条 %s）",
                                isFnDown and "按下" or "抬起", #data, msTxt)
                            if isFnUp and not fnSeqClosing then
                                fnSeqClosing = true
                                hs.timer.doAfter(0.4, function()
                                    saveFnData()
                                    local nD, nU = 0, 0
                                    for _, e in ipairs(fnSeq or {}) do
                                        if e.dir == "D" then nD = nD + 1 else nU = nU + 1 end
                                    end
                                    M.fnCaptureOn = false
                                    fnSeqBase, fnSeqPrev, fnSeqClosing = nil, nil, nil
                                    plog("★ 一次敲击采集完成：%d 条（按下%d/抬起%d），"
                                        .. "已存档并自动关闭", #(fnSeq or {}), nD, nU)
                                end)
                            end
                        end
                    end)
                end
            end
        end)
        if not ok then
            plog("!! 探针回调出错（已拦下，不影响按键）: %s", tostring(err))
        end
        nRec = nRec + 1
        if nRec >= MAXREC then
            plog("=== 达到 %d 条上限，自动停止 ===", MAXREC)
            if tap then tap:stop(); tap = nil end
        end
    end

    function M.fnProbeStop()
        if tap then tap:stop(); tap = nil end
        lastMs = nil
        plog("=== 探针手动停止 ===")
    end

    --- 录 seconds 秒。返回是否真的启动成功。
    function M.fnProbe(seconds)
        if tap then M.fnProbeStop() end
        local types = {}
        for _, nm in ipairs({ "flagsChanged", "keyDown", "keyUp", "systemDefined" }) do
            local v = hs.eventtap.event.types[nm]
            if v then types[#types + 1] = v end
        end
        if #types == 0 then
            plog("!! 拿不到事件类型常量，探针未启动")
            return false
        end
        nRec, lastMs = 0, nil
        local ok, t = pcall(function()
            return hs.eventtap.new(types, function(ev)
                record(ev)
                return false    -- 一律不吞事件，探针只观察
            end)
        end)
        if not ok or not t then
            plog("!! hs.eventtap.new 失败：%s（多半是没给「输入监控」权限）", tostring(t))
            return false
        end
        tap = t
        local ok2, err2 = pcall(function() tap:start() end)
        if not ok2 then
            plog("!! tap:start() 抛错：%s", tostring(err2))
            tap = nil
            return false
        end
        plog("=== 探针启动，录 %.0f 秒 ===", tonumber(seconds) or 0)
        hs.timer.doAfter(tonumber(seconds) or 60, function()
            if tap then tap:stop(); tap = nil end
            plog("=== 探针到点停止 ===")
        end)
        return true
    end

    -- 延迟 1 秒再挂 tap：① 避开模块加载瞬间的初始化抖动；
    -- ② **测试环境里 doAfter 桩件不自动跑回调**，于是探针在测试中根本不会
    --    启动，不会往真机日志里写一行「启动失败」把它污染掉
    --    （诊断日志被污染 = 诊断日志失效，这在别处已经栽过一次）。
    if (M.probeSeconds or 0) > 0 then
        pcall(function()
            hs.timer.doAfter(1, function()
                pcall(M.fnProbe, M.probeSeconds)
            end)
        end)
    end
end

return M
