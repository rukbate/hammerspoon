--- weather.lua —— 菜单栏天气（天天气 API）
---
--- 2026-10-01 重写。原版的问题：
---   1. appid / appsecret 硬编码在源码里，而且已经进了 git 历史 —— 密钥等于公开。
---      现在改成从环境变量读，读不到就不加载（不再回落到明文）。
---      ⚠️ 原密钥已在 git 历史里，若在意请去天天气后台重置一次。
---   2. rawjson / city / titlestr / item / menuData / ssid / weatherWifiWatcher
---      以及三个 function 全是全局，会污染 _G 和别的模块。
---   3. print('get weather error:' .. code) —— code 是数字，Lua 会尝试拼字符串，报错。
---
--- 环境变量（写进 ~/.zshrc 或 Hammerspoon 的 launchd 环境）：
---   export TIANQI_APPID=xxxxx
---   export TIANQI_APPSECRET=xxxxx

local M = {}

--------------------------------------------------------------------------------
-- 配置
--------------------------------------------------------------------------------

M.appid     = os.getenv("TIANQI_APPID")
M.appsecret = os.getenv("TIANQI_APPSECRET")
M.interval  = 720      -- 刷新间隔（秒）
M.apiBase   = "https://www.tianqiapi.com/api/?version=v1&appid="
M.cacheBust = "&dummy="   -- 加个时间戳绕缓存

M.weaEmoji = {
    lei = "⚡️", qing = "☀️", shachen = "😷", wu = "🌫", xue = "❄️",
    yu = "🌧", yujiaxue = "🌨", yun = "⛅️", zhenyu = "🌧",
    yin = "☁️", default = "",
}

--------------------------------------------------------------------------------
-- 内部状态
--------------------------------------------------------------------------------

local menubar = nil
local menuData = {}
local lastCity = nil

local function emojiOf(name)
    return M.weaEmoji[name] or M.weaEmoji.default
end

local function refreshMenubar()
    menubar:setTooltip("Weather Info")
    menubar:setMenu(menuData)
end

local function getWeather()
    local url = M.apiBase .. M.appid .. "&appsecret=" .. M.appsecret
        .. M.cacheBust .. tostring(os.time())
    hs.http.doAsyncRequest(url, "GET", nil, nil, function(code, body)
        if code ~= 200 or not body then
            print("[weather] 请求失败，HTTP " .. tostring(code))
            return
        end

        local ok, raw = pcall(hs.json.decode, body)
        if not ok or type(raw) ~= "table" or type(raw.data) ~= "table" then
            print("[weather] 返回内容不是合法 JSON")
            return
        end

        -- 天天气把城市名放在 city，日均/历史数据在 data
        local city = raw.city or lastCity or ""
        lastCity = city

        local rows = {}
        for _, v in ipairs(raw.data) do
            local e = emojiOf(v.wea_img)
            local line
            if v.day == "今天" then
                line = string.format("%s  %s  %s  🌡️%s  💧%s  💨%s  🌬%s  %s",
                    city, v.day, e, v.tem, v.humidity, v.air, v.win_speed, v.wea)
                menubar:setTitle(e)
            else
                line = string.format("%s  %s  %s  🌡️%s  🌬%s  %s",
                    city, v.day, e, v.tem, v.win_speed, v.wea)
            end
            table.insert(rows, { title = line })
            if v.day == "今天" then table.insert(rows, { title = "-" }) end
        end

        if #rows == 0 then
            print("[weather] 返回里没有天气数据")
            return
        end
        menuData = rows
        refreshMenubar()
    end)
end

--------------------------------------------------------------------------------
-- 启动
--------------------------------------------------------------------------------

if not (M.appid and M.appsecret and M.appsecret ~= "") then
    print("[weather] 未设置 TIANQI_APPID / TIANQI_APPSECRET 环境变量，模块不加载")
    return M
end

menubar = hs.menubar.new()
menubar:setTitle("⌛")
getWeather()
refreshMenubar()

M.timer = hs.timer.doEvery(M.interval, getWeather)

-- 换 Wi-Fi 就刷新（原来的 ssid 只是判断"有没有连"，不显示）
M.wifiWatcher = hs.wifi.watcher.new(function()
    getWeather()
end)
M.wifiWatcher:start()

M.refresh = getWeather

return M