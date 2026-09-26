# Hammerspoon 配置

Lin 的 macOS Hammerspoon 配置。围绕「蓝牙键盘 / 鼠标 / 触控板」的输入体验定制，附带窗口、截屏等常用工具。

## 模块一览

### init.lua — 加载入口

按依赖顺序 require 各模块。被注释掉的是当前停用的模块（`clipboard`、`weather`、`wifi`），文件保留、随时可开。

### kbswap.lua — 蓝牙键盘 ⌘/⌥ 对调 + 菜单栏键盘图标

- **为什么不用系统「键盘 → 修饰键」**：macOS 那个设置按键盘记录，但被识别成 BLE 的键盘（MX Keys、Lofree 等）根本不在下拉列表里。
- 引擎一 `hidutil`（默认）：向蓝牙键盘自己的 HID 服务下发映射表，只对调这一把键盘的 ⌘ 与 ⌥，内置键盘不受影响。
- 引擎二 `eventtap`（兜底）：事件流层面全局交换，蓝牙键盘连着时内置键盘也会一起换；仅在 hidutil 不灵时用。
- 热键 `⌃⌥⌘K` 切换模式；菜单栏显示键盘图标（实心 = 蓝牙键盘在线，斜杠 = 离线），**点击图标 = 开关屏幕键盘**（osk.lua），键盘上下线时弹提示。

### osk.lua — 屏幕键盘（现行方案）

蓝牙键盘不在手边时，用鼠标 / 触控板 / 触摸屏给前台 App 打字的全功能键盘：

- ANSI 布局 6 行 76 键：F 功能键排（esc 在第一排最左）+ 主键区；⌫ / 方向键按住连发；修饰键 sticky（点一下上膛、作用于下一键）；caps 为纯内部状态。
- **点击不抢焦点**（v3 根治版）：键盘显示期间挂 session 级 eventtap，凡落在面板内的鼠标事件一律在上游截获丢弃——AppKit 看不见点击，焦点始终留在目标 App，合成按键直达输入框。
- 面板可拖动（按住顶部把手条 / 键位缝隙拖），`M.scale`（默认 1.4）统一缩放整体尺寸，触摸屏使用友好。

### axkeyboard.lua — 系统「无障碍键盘」开关（备用，未加载）

点击 kbswap 图标开关 macOS 自带的辅助功能键盘：deep link 打开系统设置对应窗格 → AX API 找到并按压开关 → 成功后自动关掉设置窗口。功能正常，但每次都要经过系统设置，故降级为备用；`init.lua` 里注释着，要启用取消注释即可。

### scroll.lua — 滚动方向反转 + 平滑滚动

- 反转：macOS「自然滚动」是全局开关，这里拦 scrollWheel 事件只对外接鼠标反向，触控板保持自然。
- 平滑（可选，`M.smooth = true`）：滚轮的行级离散事件先攒进缓冲区，按 1/125 秒的节奏做指数衰减式发放，合成像素级连续滚动（类似 Mos 的效果）。关键参数 `M.smoothPixelsPerLine = 33`（整体速度）。
- 菜单栏图标（assets 里的 scroll-on/off）随时开关。

### window.lua — 窗口管理热键

`⌘⌥⌃F` 最大化当前窗口等几个基础窗口操作。

### screen.lua — 截屏工具

`⌘⇧S` 触发 macOS 自带的截屏 / 录屏面板（`⌘⇧5`）。

### spoon.lua — Spoon 加载器

加载并启动 `Spoons/Caffeine`（菜单栏咖啡杯，防止休眠）。

### weather.lua — 天气（未加载）

菜单栏天气，tianqiapi 接口。已停用。

### clipboard.lua — 剪贴板历史（未加载）

Jumpcut 风格的剪贴板管理（基于 victorso 的实现改）。已停用。

## 目录

| 路径 | 说明 |
| --- | --- |
| `Spoons/` | 第三方 Spoon（Caffeine） |
| `assets/` | 菜单栏图标（kbswap / scroll 的 on-off 状态图） |
| `.workbuddy/` | 工作区数据（gitignore）：模块开发笔记、离线测试套件 |

## 开发约定

- 改完配置在 Hammerspoon 菜单栏手动 **Reload Config**，不自动重启。
- 模块改动配套离线测试（lupa 驱动的 Lua 断言），改前跑一遍防回归。
- 涉及权限的功能先想 TCC / 代码签名；不要动 `/Applications/Hammerspoon.app` 的 Info.plist（会破坏签名与已有授权）。
