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
