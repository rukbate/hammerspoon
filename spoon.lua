--- spoon.lua —— 加载 Spoons
---
--- 2026-10-01 整理：原来 `caffeine` 是全局变量；且 Spoons 目录不存在或 spoon
--- 加载失败时 hs.loadSpoon 返回 nil，直接 :start() 会报错。加 nil 保护。
---
--- 想临时防咖啡因：关掉这行，或在控制台执行 hs.caffeine.setDefaultMute()。

local ok, caffeine = pcall(hs.loadSpoon, "Caffeine")
if ok and caffeine then
    caffeine:start()
    _G.caffeine = caffeine   -- 保留原来的全局名，控制台里 hs.caffeine 还能用
else
    print("[spoon] 加载 Caffeine 失败（检查 ~/.hammerspoon/Spoons/ 是否存在），已跳过")
end