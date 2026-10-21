-- 登录/开机后自动启动。为什么必须有：kbswap 的 ⌘⇄⌥ 挂在 HID 层，键盘一重连、
-- 机器一唤醒映射就丢，全靠这个进程每 2 秒核对读回（2026-10-17 起，轮询 2 秒）。
-- **进程不在 = 功能不在**
-- （2026-10-06 实锤：进程 12:21 退出后一整天没起来，交换就没了）。
-- 不想自启就删掉这一行（或在「系统设置 → 通用 → 登录项」里移除 Hammerspoon）。
hs.autoLaunch(true)

require "spoon"
-- 未启用的模块（保留文件，暂不加载）：
-- clipboard —— 剪贴板历史（2026-10-01 已整理掉全局变量污染，可按需启用）
-- weather   —— 天气菜单（2026-10-01 已改为读环境变量，需先设 TIANQI_APPID / TIANQI_APPSECRET）
require "window"
require "screen"
-- require "scroll"   -- 反转滚动方向 + 平滑滚动（2026-10-01 暂时停用）
require "osk"      -- 自绘屏幕键盘（v3 事件拦截版；kbswap 图标点击开关，先于 kbswap 加载）
-- require "axkeyboard" -- 备用：系统「无障碍键盘」开关（能用但每次要开系统设置）
require "kbswap"
require "audiopriority" -- 默认输入设备优先级（2026-10-21）：无线麦靠电平判断真麦在不在线，别只认接收器
