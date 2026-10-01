--[[
   From https://github.com/victorso/.hammerspoon/blob/master/tools/clipboard.lua
   Modified by Diego Zamboni
   This is my attempt to implement a jumpcut replacement in Lua/Hammerspoon.
   It monitors the clipboard/pasteboard for changes, and stores the strings you copy to the transfer area.
   You can access this history on the menu (Unicode scissors icon).
   Clicking on any item will add it to your transfer area.
   If you open the menu while pressing option/alt, you will enter the Direct Paste Mode. This means that the selected item will be
   "typed" instead of copied to the active clipboard.
   The clipboard persists across launches.
   -> Ng irc suggestion: hs.settings.set("jumpCutReplacementHistory", clipboard_history)

   2026-10-01 整理：所有函数/状态收进 local 并 return M 模块表，不再往 _G 里撒全局
   （原来 subStringUTF8 / setTitle / putOnPaste / clearAll / populateMenu /
     storeCopy / clearLastItem / pasteboardToClipboard / timer / menuData /
     now / current_clipboard 全是全局，会和其他模块打架）。
]]

-- Feel free to change those settings
local frequency = 0.8 -- Speed in seconds to check for clipboard changes. If you check too frequently, you will loose performance, if you check sparsely you will loose copies
local hist_size = 100 -- How many items to keep on history
local label_length = 70 -- How wide (in characters) the dropdown menu should be. Copies larger than this will have their label truncated and end with "…" (unicode for elipsis ...)
local honor_clearcontent = true --asmagill request. If any application clears the pasteboard, we also remove it from the history https://groups.google.com/d/msg/hammerspoon/skEeypZHOmM/Tg8QnEj_N68J
local pasteOnSelect = false -- Auto-type on click

local M = {}

-- Don't change anything bellow this line
local jumpcut = hs.menubar.new()
jumpcut:setTooltip("Clipboard history")
local pasteboard = require("hs.pasteboard") -- http://www.hammerspoon.org/docs/hs.pasteboard.html
local settings = require("hs.settings") -- http://www.hammerspoon.org/docs/hs.settings.html
local last_change = pasteboard.changeCount() -- displays how many times the pasteboard owner has changed // Indicates a new copy has been made

--Array to store the clipboard history
local clipboard_history = settings.get("so.victor.hs.jumpcut") or {} --If no history is saved on the system, create an empty history

--返回当前字符实际占用的字符数
local function subStringGetByteCount(str, index)
    local curByte = string.byte(str, index)
    local byteCount = 1
    if curByte == nil then
        byteCount = 0
    elseif curByte > 0 and curByte <= 127 then
        byteCount = 1
    elseif curByte>=192 and curByte<=223 then
        byteCount = 2
    elseif curByte>=224 and curByte<=239 then
        byteCount = 3
    elseif curByte>=240 and curByte<=247 then
        byteCount = 4
    end
    return byteCount
end

--返回当前截取字符串正确下标
local function subStringGetTrueIndex(str, index)
    local curIndex = 0
    local i = 1
    local lastCount = 1
    repeat
        lastCount = subStringGetByteCount(str, i)
        i = i + lastCount
        curIndex = curIndex + 1
    until(curIndex >= index)
    return i - lastCount
end

local function subStringGetTotalIndex(str)
    local _, count = string.gsub(str, "[^\128-\191]", "")
    return count
end

local function subStringUTF8(str, startIndex, endIndex)
    if startIndex < 0 then
        startIndex = subStringGetTotalIndex(str) + startIndex + 1
    end

    if endIndex ~= nil and endIndex < 0 then
        endIndex = subStringGetTotalIndex(str) + endIndex + 1
    end

    if endIndex == nil then
        return string.sub(str, subStringGetTrueIndex(str, startIndex))
    else
        return string.sub(str, subStringGetTrueIndex(str, startIndex), subStringGetTrueIndex(str, endIndex + 1) - 1)
    end
end

-- Append a history counter to the menu
local function setTitle()
   jumpcut:setTitle("✂") -- Unicode magic
end

local function putOnPaste(str, key)
   if (pasteOnSelect) then
      hs.eventtap.keyStrokes(str)
      pasteboard.setContents(str)
      last_change = pasteboard.changeCount()
   else
      if (key.alt == true) then -- If the option/alt key is active when clicking on the menu, perform a "direct paste", without changing the clipboard
         hs.eventtap.keyStrokes(str) -- Defeating paste blocking http://www.hammerspoon.org/go/#pasteblock
      else
         pasteboard.setContents(str)
         last_change = pasteboard.changeCount() -- Updates last_change to prevent item duplication when putting on paste
      end
   end
end

-- Clears the clipboard and history
local function clearAll()
   pasteboard.clearContents()
   clipboard_history = {}
   settings.set("so.victor.hs.jumpcut", clipboard_history)
   last_change = pasteboard.changeCount()
   setTitle()
end

-- Clears the last added to the history
local function clearLastItem()
   table.remove(clipboard_history, #clipboard_history)
   settings.set("so.victor.hs.jumpcut", clipboard_history)
   last_change = pasteboard.changeCount()
   setTitle()
end

local function pasteboardToClipboard(item)
   -- Loop to enforce limit on qty of elements in history. Removes the oldest items
   while (#clipboard_history >= hist_size) do
      table.remove(clipboard_history, 1)
   end
   table.insert(clipboard_history, item)
   settings.set("so.victor.hs.jumpcut", clipboard_history) -- updates the saved history
   setTitle() -- updates the menu counter
end

-- Dynamic menu by cmsj https://github.com/Hammerspoon/hammerspoon/issues/61#issuecomment-64826257
local function populateMenu(key)
   setTitle() -- Update the counter every time the menu is refreshed
   local menuData = {}
   if (#clipboard_history == 0) then
      table.insert(menuData, {title="None", disabled = true}) -- If the history is empty, display "None"
   else
      for _, v in ipairs(clipboard_history) do
         if (string.len(v) > label_length) then
            table.insert(menuData, 1, {title=subStringUTF8(v, 0, label_length).."…", fn = function() putOnPaste(v, key) end }) -- Truncate long strings
         else
            table.insert(menuData, 1, {title=v, fn = function() putOnPaste(v, key) end })
         end -- end if else
      end-- end for
   end-- end if else
   -- footer
   table.insert(menuData, {title="-"})
   table.insert(menuData, {title="Clear All", fn = function() clearAll() end })
   if (key.alt == true or pasteOnSelect) then
      table.insert(menuData, {title="Direct Paste Mode ✍", disabled=true})
   end
   return menuData
end

-- If the pasteboard owner has changed, we add the current item to our history and update the counter.
local function storeCopy()
   local now = pasteboard.changeCount()
   if (now > last_change) then
      local current_clipboard = pasteboard.getContents()
      -- asmagill requested this feature. It prevents the history from keeping items removed by password managers
      if (current_clipboard == nil or current_clipboard == "") then
         -- honor_clearcontent 原来默认 false，等于密码管理器清空剪贴板时会把 nil
         -- 塞进历史（后续 string.len(v) 直接崩）。这里无条件丢弃空内容。
         clearLastItem()
      else
         pasteboardToClipboard(current_clipboard)
      end
      last_change = now
   end
end

--Checks for changes on the pasteboard. Is it possible to replace with eventtap?
M.timer = hs.timer.new(frequency, storeCopy)
M.timer:start()

setTitle() --Avoid wrong title if the user already has something on his saved history
jumpcut:setMenu(populateMenu)

hs.hotkey.bind({"cmd", "shift"}, "v", function() jumpcut:popupMenu(hs.mouse.getAbsolutePosition()) end)

M.menubar = jumpcut
M.clearAll = clearAll

return M