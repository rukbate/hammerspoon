function ssidChangedCallback()
    ssid = hs.wifi.currentNetwork()
    if (ssid ~= nil) then
        print("ssid = "..(ssid))
        hs.notify.new({title="Wifi", informativeText="Wifi connected to " .. ssid}):send()
    else
        hs.notify.new({title="Wifi", informativeText="Wifi disconnected"}):send()
    end
end

wifiWatcher = hs.wifi.watcher.new(ssidChangedCallback)
wifiWatcher:start()