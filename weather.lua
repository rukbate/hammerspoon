local urlApi = 'https://www.tianqiapi.com/api/?version=v1&appid=1001&appsecret=5578&dummy='
local menubar = hs.menubar.new()
local menuData = {}

local weaEmoji = {
   lei = '⚡️',
   qing = '☀️',
   shachen = '😷',
   wu = '🌫',
   xue = '❄️',
   yu = '🌧',
   yujiaxue = '🌨',
   yun = '⛅️',
   zhenyu = '🌧',
   yin = '☁️',
   default = ''
}

function updateMenubar()
	 menubar:setTooltip("Weather Info")
    menubar:setMenu(menuData)
end

function getWeather()
   hs.http.doAsyncRequest(urlApi .. os.time(), "GET", nil, nil, function(code, body, htable)
      if code ~= 200 then
         print('get weather error:' .. code)
         return
      end
      rawjson = hs.json.decode(body)
      city = rawjson.city
      menuData = {}
      for k, v in pairs(rawjson.data) do
         if k == 1 then
            menubar:setTitle(weaEmoji[v.wea_img])
            titlestr = string.format("%s  %s  %s  🌡️%s  💧%s  💨%s  🌬%s  %s", city, v.day, weaEmoji[v.wea_img], v.tem, v.humidity, v.air, v.win_speed, v.wea)
            item = { title = titlestr }
            table.insert(menuData, item)
            table.insert(menuData, {title = '-'})
         else
            -- titlestr = string.format("%s %s %s %s", v.day, v.wea, v.tem, v.win_speed)
            titlestr = string.format("%s  %s  %s  🌡️%s  🌬%s  %s", city, v.day, weaEmoji[v.wea_img], v.tem, v.win_speed, v.wea)
            item = { title = titlestr }
            table.insert(menuData, item)
         end
      end
      updateMenubar()
      -- hs.notify.new({title="Weather", informativeText="Weather updated ..."}):send()
   end)
end

menubar:setTitle('⌛')
getWeather()
updateMenubar()
hs.timer.doEvery(720, getWeather)

function weatherWifiCallback()
   ssid = hs.wifi.currentNetwork()
   if (ssid ~= nil) then
      getWeather()
   end
end
weatherWifiWatcher = hs.wifi.watcher.new(weatherWifiCallback)
weatherWifiWatcher:start()
