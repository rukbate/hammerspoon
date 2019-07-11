function activateKb()
    os.execute("blueutil --connect 'RK-Bluetooth keyboard'")
end

hs.timer.doEvery(300, activateKb)