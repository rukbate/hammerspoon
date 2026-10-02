# Hammerspoon 配置

Lin 的 macOS Hammerspoon 配置。围绕「蓝牙键盘 / 鼠标 / 触控板」的输入体验定制，附带窗口、截屏等常用工具。

## 模块一览

### init.lua — 加载入口

按依赖顺序 require 各模块（`osk` 必须在 `kbswap` 之前，因为 kbswap 的图标点击回调要调 osk 暴露的开关）。

当前停用（文件保留、取消注释即可启用）：

| 模块 | 停用原因 |
| --- | --- |
| `scroll` | Lin 于 2026-10-01 手动注释停用（与反转滚动的使用习惯冲突） |
| `clipboard` | 2026-10-01 已整理掉全局变量污染，待重新启用 |
| `weather` | 2026-10-01 已改为读环境变量，**需先配置 `TIANQI_APPID` / `TIANQI_APPSECRET`** |
| `axkeyboard` | 备用方案，功能正常但每次要经过系统设置 |

### kbswap.lua — 蓝牙键盘 ⌘/⌥ 对调 + 菜单栏键盘图标

- **为什么不用系统「键盘 → 修饰键」**：macOS 那个设置按键盘记录，但被识别成 BLE 的键盘（MX Keys、Lofree 等）根本不在下拉列表里。
- 引擎一 `hidutil`（默认）：向蓝牙键盘自己的 HID 服务下发映射表，只对调这一把键盘的 ⌘ 与 ⌥，内置键盘不受影响。
- 引擎二 `eventtap`（兜底）：事件流层面全局交换，蓝牙键盘连着时内置键盘也会一起换；仅在 hidutil 不灵时用。
- 热键 `⌃⌥⌘K` 切换模式；菜单栏显示键盘图标（实心 = 蓝牙键盘在线，斜杠 = 离线），**点击图标 = 开关屏幕键盘**（osk.lua），键盘上下线时弹提示。

### osk.lua — 屏幕键盘（现行方案）

蓝牙键盘不在手边时，用鼠标 / 触控板 / 触摸屏给前台 App 打字的全功能键盘：

- ANSI 布局 6 行 76 键：F 功能键排（esc 在第一排最左）+ 主键区；⌫ / 方向键按住连发；修饰键 sticky（点一下上膛、作用于下一键）；caps 为纯内部状态。
- **点击不抢焦点**（v3 根治版）：键盘显示期间挂 session 级 eventtap，凡落在面板内的鼠标事件一律在上游截获丢弃——AppKit 看不见点击，焦点始终留在目标 App，合成按键直达输入框。
- 面板可拖动（按住顶部把手条 / 键位缝隙拖），`M.scale`（默认 1.4）统一缩放整体尺寸，触摸屏使用友好。拖动越界会被钳制在主屏内，避免面板被拖丢找不回来。
- **显示时躲开输入焦点**（`M.avoidInput = true`）：打开前用 AX 读当前插入光标的位置（拿不到就退化成整个输入框），输入区压在下半屏就把键盘翻到顶部，免得挡住正在打的那一行。AX 读不到时静默退回默认贴底，不影响显示；光标在另一块屏幕上时不做避让（两套屏幕坐标混用会算错）。
- 层级 `M.level = "assistiveTechHigh"`，并挂了 application watcher：任何 App 被激活就把面板重新 raise 一次（否则会被 Docker 等全屏窗口盖住）。

### axkeyboard.lua — 系统「无障碍键盘」开关（备用，未加载）

点击 kbswap 图标开关 macOS 自带的辅助功能键盘：deep link 打开系统设置对应窗格 → AX API 找到并按压开关 → 成功后自动关掉设置窗口。功能正常，但每次都要经过系统设置，故降级为备用；`init.lua` 里注释着，要启用取消注释即可。

### scroll.lua — 滚动方向反转 + 平滑滚动（**当前停用**）

- 反转：macOS「自然滚动」是全局开关，这里拦 scrollWheel 事件只对外接鼠标反向，触控板保持自然。
- 平滑（`M.smooth = true`）：滚轮的行级离散事件先攒进缓冲区，按 1/125 秒的节奏做指数衰减式发放，合成像素级连续滚动。关键参数 `M.smoothPixelsPerLine = 33`（整体速度）、`M.smoothDecay = 0.30`、`M.smoothMaxBuffer = 240`。
- 防死循环：合成事件带自己的 PID + 连续/相位全零指纹，识别为自造后不再二次处理。
- 菜单栏图标（assets 里的 scroll-on/off）随时开关。
- **2026-10-01 被 Lin 手动注释停用**，`init.lua` 里取消注释即可恢复。

### window.lua — 窗口管理热键

9 个 `⌘⌥⌃` 组合键，全部作用于当前焦点窗口；焦点不在任何窗口上（Finder 桌面等）时静默退出。

| 键 | 动作 |
| --- | --- |
| `F` | 铺满当前屏幕（`usableFrame`） |
| `←` `→` `↑` `↓` | 贴到对应半边，**只挪位置不改窗口尺寸** |
| `M` | 左右各留 12%（窗口居中，左右等宽） |
| `N` | 四边各留 20%（窗口居中） |
| `[` `]` | 窗口移到上/ 下一块屏幕，到头后环绕 |

### screen.lua — 截屏工具

| 键 | 动作 |
| --- | --- |
| `⌘⇧S` | 打开系统截屏 / 录屏面板（`⌘⇧5`，面板没有命令行等价物） |
| `⌃⌥⌘A` | 交互式截屏（拖拽选区 / 点选窗口，可复制到剪贴板） |
| `⌃⌥⌘W` | 同上，但只能点选窗口 |

后两条走 `/usr/sbin/screencapture -i` / `-i -w`。2026-10-01 重写：旧版是「模拟按 ⌘⇧4 → 硬等 0.1 秒 → 模拟按空格」，面板没起来就什么都不会发生，面板起得慢还会误吞紧接着的按键。

### spoon.lua — Spoon 加载器

加载并启动 `Spoons/Caffeine`（菜单栏咖啡杯，防止休眠）。`hs.loadSpoon` 返回 nil 时只打印提示、不崩。

### weather.lua — 天气（未加载）

菜单栏天气，天天气 API。2026-10-01 重写：**API 密钥改为从环境变量读**（原来硬编码在源码里、且已进 git 历史，等于公开），未配置就不加载；全局变量全部收进模块表；HTTP/JSON 错误路径不再崩。启用前先设置：

```sh
export TIANQI_APPID=xxxxx
export TIANQI_APPSECRET=xxxxx
```

> 原密钥 `55364454 / ey8L74Yp` 仍在 git 历史里。若在意，去天天气后台重置一次。

### clipboard.lua — 剪贴板历史（未加载）

Jumpcut 风格的剪贴板管理（基于 victorso 的实现改），`⌘⇧V` 弹出菜单。2026-10-01 整理：所有函数和状态收进 local 并 `return M`（原来 `subStringUTF8` / `setTitle` / `putOnPaste` / `storeCopy` / `timer` 等 14 个名字都是全局）；剪贴板被清空时不再把 `nil` 塞进历史（会导致后续 `string.len` 崩）。

## 目录

| 路径 | 说明 |
| --- | --- |
| `Spoons/` | 第三方 Spoon（Caffeine） |
| `assets/` | 菜单栏图标（kbswap / scroll 的 on-off 状态图） |
| `.workbuddy/` | 工作区数据（gitignore）：模块开发笔记、离线测试套件 |

## 开发约定

- 改完配置在 Hammerspoon 菜单栏手动 **Reload Config**，不自动重启。
- 模块改动配套离线测试（lupa 驱动的 Lua 断言，在 `.workbuddy/skills/hammerspoon-config-test/`），改前跑一遍防回归：

  ```sh
  cd ~/.hammerspoon/.workbuddy/skills/hammerspoon-config-test
  ~/.workbuddy/binaries/python/envs/default/bin/python run-lua-test.py example-<module>-test.lua
  ```

  注意带 `os.exit()` 的测试（clipboard / spoon）要单独跑——`SystemExit` 会终止运行器。
- 涉及权限的功能先想 TCC / 代码签名；不要动 `/Applications/Hammerspoon.app` 的 Info.plist（会破坏签名与已有授权）。
- **写 Hammerspoon 脚本时热键键名一律小写**（`f` / `left` / `right`，不是 `F` / `Left`）。`hs.keycodes.map` 里没有大写项，传大写不可靠。
- 模块不要往 `_G` 里撒全局变量，一律 `local` + `return M`。
- **屏幕坐标全是「左上原点、y 向下」**：`hs.screen:frame()`、`hs.canvas`、
  `hs.window:frame()`、`hs.mouse.getAbsolutePosition()`、`hs.eventtap.event:location()`、
  AX 的 `AXPosition`/`AXBoundsForRange` 都是这一套，彼此直接比较即可。
  **任何一处做 y 翻转都是 bug**（依据：`libcanvas.m` 的 `RectWithFlippedYCoordinate`
  在 Lua 侧 ↔ NS 侧之间做翻转，说明 Lua 侧就是 y 向下那套）。
