function setProxy()
    os.execute("networksetup -setautoproxystate 'Wi-Fi' off")
    os.execute("echo 1234 | networksetup -setwebproxy 'Wi-Fi' 127.0.0.1 8080 on 1604692")
    os.execute("networksetup -setwebproxystate 'Wi-Fi' on")
    os.execute("echo 1234 | networksetup -setsecurewebproxy 'Wi-Fi' 127.0.0.1 8080 on 1604692")
    os.execute("networksetup -setsecurewebproxystate 'Wi-Fi' on")
end

function unsetProxy()
    os.execute("networksetup -setwebproxystate 'Wi-Fi' off")
    os.execute("networksetup -setsecurewebproxystate 'Wi-Fi' off")
    os.execute("networksetup -setautoproxyurl 'Wi-Fi' 'http://127.0.0.1:8090/proxy.pac'")
    os.execute("networksetup -setautoproxystate 'Wi-Fi' on")
end

function ssidChangedCallback()
    ssid = hs.wifi.currentNetwork()
    if (ssid ~= nil) then
        hs.notify.new({title="Wifi", informativeText="Wifi connected to " .. ssid}):send()
        if (ssid == "DevNet") then
            setProxy()
        else
            unsetProxy()
        end
    else
        hs.notify.new({title="Wifi", informativeText="Wifi disconnected"}):send()
    end
end

wifiWatcher = hs.wifi.watcher.new(ssidChangedCallback)
wifiWatcher:start()