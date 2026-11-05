-- 登录/开机后自动启动。为什么必须有：kbswap 的 ⌘⇄⌥ 挂在 HID 层，键盘一重连、
-- 机器一唤醒映射就丢，全靠这个进程每 2 秒核对读回（2026-10-17 起，轮询 2 秒）。
-- **进程不在 = 功能不在**
-- （2026-10-06 实锤：进程 12:21 退出后一整天没起来，交换就没了）。
-- 不想自启就删掉这一行（或在「系统设置 → 通用 → 登录项」里移除 Hammerspoon）。
hs.autoLaunch(true)

-- 模块加载隔离（2026-11-04）：任何一个模块出错都不许拖垮别的模块。
-- 此前只有 micswitch 包了 pcall —— osk（2400 行）一出错，排它后面的
-- kbswap 就永远加载不上；而 kbswap 不在 = 键盘上残留的 ⌘⇄⌥ 映射没人
-- 撤、菜单栏图标没了、每 2 秒的核对也没了 —— 正是「修饰键是反的而且
-- 关不掉」这种最难自查的状态。
-- 失败时写 .workbuddy/load.log（时间戳 + 错误原文），并在 HS 控制台打一条。
local function loadModule(name)
    local ok, err = pcall(require, name)
    if not ok then
        local line = os.date("%Y-%m-%d %H:%M:%S") .. " !! require " .. name
            .. " 失败: " .. tostring(err) .. "\n"
        print(line)
        local f = io.open(hs.configdir .. ".workbuddy/load.log", "a")
        if f then f:write(line); f:close() end
    end
    return ok
end

loadModule("spoon")
-- 未启用的模块（保留文件，暂不加载）：
-- clipboard —— 剪贴板历史（2026-10-01 已整理掉全局变量污染，可按需启用）
-- weather   —— 天气菜单（2026-10-01 已改为读环境变量，需先设 TIANQI_APPID / TIANQI_APPSECRET）
loadModule("window")
loadModule("screen")
-- loadModule("scroll")   -- 反转滚动方向 + 平滑滚动（2026-10-01 暂时停用）
loadModule("osk")      -- 自绘屏幕键盘（v3 事件拦截版；kbswap 图标点击开关，先于 kbswap 加载）
-- loadModule("axkeyboard") -- 备用：系统「无障碍键盘」开关（能用但每次要开系统设置）
loadModule("kbswap")
-- loadModule("audiopriority") -- 自动默认输入优先级（已停用 2026-10-24）：ffmpeg 每 15s 采样电平的
--                               开销不值得，改为手动切换。文件保留，要恢复换回这行即可。
loadModule("micswitch")  -- 手动切换默认输入：菜单栏 🎙 图标，点选即切，零采样
