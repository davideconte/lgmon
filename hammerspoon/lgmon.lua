-- lgmon for Hammerspoon: brightness and volume keys for LG webOS monitors.
-- Talks to the local daemon (lgmond.py) on http://127.0.0.1:8765.
--
--   local lgmon = require("lgmon")
--   lgmon.start()                       -- defaults below
--   lgmon.start({ volumeKeys = false })  -- override what you like

local M = {}

M.defaults = {
  url = "http://127.0.0.1:8765/",
  brightnessStep = 5,
  volumeStep = 2,
  -- extra brightness shortcuts, for keyboards without brightness keys
  brightnessUp = { { "ctrl", "alt" }, "up" },
  brightnessDown = { { "ctrl", "alt" }, "down" },
  -- option + volume keys = brightness
  optionVolumeForBrightness = true,
  -- volume keys drive the monitor speakers when the Mac outputs audio to it
  -- (macOS cannot change the volume of an HDMI/DisplayPort output)
  volumeKeys = true,
  menubar = true,
  -- back to the Mac's input after switching input or opening a monitor app
  -- (once the Mac is off screen you cannot click the menu any more)
  backToMac = { { "ctrl", "alt" }, "return" },
  -- name match for the monitor screen / audio device
  match = "LG",
  -- UI language: "en", "it", or nil to follow the system
  lang = nil,
}

local cfg
local state = nil -- { brightness, volume, muted } as known by the daemon
local busy, queued = false, nil

local T
local STRINGS = {}
STRINGS.it = {
  unreachable = "Monitor LG non raggiungibile",
  tooltip = "Monitor LG",
  brightness = "Luminosità",
  input = "Ingresso",
  apps = "App del monitor",
  back = "Torna al Mac",
  screenOff = "Spegni schermo",
  screenOffHint = "Si riaccende con i tasti luminosità",
  standby = "Standby",
  notConnected = "non collegato",
}
STRINGS.en = {
  unreachable = "LG monitor not reachable",
  tooltip = "LG monitor",
  brightness = "Brightness",
  input = "Input",
  apps = "Monitor apps",
  back = "Back to this Mac",
  screenOff = "Turn screen off",
  screenOffHint = "Brightness keys turn it back on",
  standby = "Standby",
  notConnected = "not connected",
}

local function isLG(name) return name and name:find(cfg.match, 1, true) ~= nil end

-- on-screen indicator, styled after the macOS 26+ brightness/volume panel ---

local hud, hudTimer

local function sun(cx, cy, r, ray, color)
  local el = { { type = "circle", action = "fill", center = { x = cx, y = cy }, radius = r, fillColor = color } }
  for i = 0, 7 do
    local a = i * math.pi / 4
    local r1, r2 = r + ray * 0.55, r + ray * 1.55
    table.insert(el, { type = "segments", action = "stroke", strokeColor = color, strokeWidth = 1.4,
      strokeCapStyle = "round", coordinates = {
        { x = cx + math.cos(a) * r1, y = cy + math.sin(a) * r1 },
        { x = cx + math.cos(a) * r2, y = cy + math.sin(a) * r2 } } })
  end
  return el
end

local function showHud()
  if not state then return end
  local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local f = scr:frame()
  local w, h = 292, 64
  local dark = hs.host.interfaceStyle() == "Dark"
  local fg = dark and { white = 1, alpha = 0.95 } or { white = 0, alpha = 0.85 }
  local dim = dark and { white = 1, alpha = 0.6 } or { white = 0, alpha = 0.5 }
  local x0, x1, yb = 42, w - 42, 43
  local el = {
    { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 20, yRadius = 20 },
      fillColor = dark and { red = 0.17, green = 0.17, blue = 0.2, alpha = 0.86 } or { white = 0.97, alpha = 0.9 } },
    { type = "rectangle", action = "stroke", roundedRectRadii = { xRadius = 20, yRadius = 20 },
      strokeColor = { white = 1, alpha = dark and 0.16 or 0.6 }, strokeWidth = 1,
      frame = { x = 0.5, y = 0.5, w = w - 1, h = h - 1 } },
    { type = "text", text = scr:name(), frame = { x = 16, y = 10, w = w - 32, h = 18 },
      textFont = ".AppleSystemUIFontBold", textSize = 13, textColor = fg },
    { type = "rectangle", action = "fill", frame = { x = x0, y = yb - 2, w = x1 - x0, h = 4 },
      roundedRectRadii = { xRadius = 2, yRadius = 2 }, fillColor = { white = dark and 1 or 0, alpha = 0.18 } },
    { type = "rectangle", action = "fill",
      frame = { x = x0, y = yb - 2, w = math.max((x1 - x0) * state.brightness / 100, 4), h = 4 },
      roundedRectRadii = { xRadius = 2, yRadius = 2 }, fillColor = fg },
  }
  for i = 0, 16 do
    table.insert(el, { type = "circle", action = "fill", radius = 0.9,
      center = { x = x0 + (x1 - x0) * i / 16, y = yb + 9 }, fillColor = dim })
  end
  for _, e in ipairs(sun(24, yb, 2.6, 2.4, dim)) do table.insert(el, e) end
  for _, e in ipairs(sun(w - 24, yb, 3.4, 3.2, dim)) do table.insert(el, e) end

  if not hud then
    hud = hs.canvas.new({ x = 0, y = 0, w = w, h = h })
    hud:level(hs.canvas.windowLevels.overlay)
    hud:behavior({ "canJoinAllSpaces", "stationary" })
  end
  hud:frame({ x = f.x + f.w - w - 10, y = f.y + 8, w = w, h = h })
  hud:replaceElements(el)
  if not hud:isShowing() then hud:show(0.12) end
  if hudTimer then hudTimer:stop() end
  hudTimer = hs.timer.doAfter(1.5, function() hud:hide(0.35) end)
end

-- daemon calls: one in flight at a time, the latest value wins -------------

local menu, fetchLists, buildMenu
local function refreshMenu()
  if menu and state then menu:setTitle("☀︎ " .. state.brightness) end
end

local function send(path, after)
  if busy then queued = { path, after }; return end
  busy = true
  hs.http.asyncGet(cfg.url .. path, nil, function(code, body)
    busy = false
    if code == 200 then
      local ok, s = pcall(hs.json.decode, body)
      if ok and s then
        -- with commands queued our local value is already ahead of the daemon
        if not queued then state = s end
        refreshMenu()
        if after then after() end
      end
    elseif after then
      hs.alert.closeAll()
      hs.alert.show(T.unreachable, 1.5)
    end
    if queued then
      local q = queued; queued = nil
      send(q[1], q[2])
    end
  end)
end

function M.adjust(what, dir, fine)
  local function apply()
    local step = fine and 1 or (what == "brightness" and cfg.brightnessStep or cfg.volumeStep)
    state[what] = math.max(0, math.min(100, state[what] + dir * step))
    if what == "brightness" then showHud() else state.muted = false end
    refreshMenu()
    send(what .. "/" .. state[what])
  end
  if state then apply() else send("status", apply) end
end

function M.setBrightness(v)
  if state then state.brightness = v end
  send("brightness/" .. v, showHud)
end

local function toggleMute()
  if state then state.muted = not state.muted end
  send("mute")
end

-- keys ----------------------------------------------------------------------

local function bindBrightness(spec, dir)
  if not spec then return end
  local mods, key = spec[1], spec[2]
  local fine = { table.unpack(mods) }
  table.insert(fine, "shift")
  for _, m in ipairs({ { mods, false }, { fine, true } }) do
    local fn = function() M.adjust("brightness", dir, m[2]) end
    table.insert(M.hotkeys, hs.hotkey.bind(m[1], key, fn, nil, fn))
  end
end

local function outputIsLG()
  local out = hs.audiodevice.defaultOutputDevice()
  return out and isLG(out:name())
end

local function onSystemKey(e)
  local k = e:systemKey()
  local flags = e:getFlags()
  local fine = flags.shift and flags.alt

  if k.key == "BRIGHTNESS_UP" or k.key == "BRIGHTNESS_DOWN" then
    local scr = hs.mouse.getCurrentScreen()
    if not (scr and isLG(scr:name())) then return false end
    if k.down then M.adjust("brightness", k.key == "BRIGHTNESS_UP" and 1 or -1, fine) end
    return true
  end

  if k.key == "SOUND_UP" or k.key == "SOUND_DOWN" then
    local dir = k.key == "SOUND_UP" and 1 or -1
    if cfg.optionVolumeForBrightness and flags.alt and not flags.shift then
      if k.down then M.adjust("brightness", dir) end
      return true
    end
    if not (cfg.volumeKeys and outputIsLG()) then return false end
    if k.down then M.adjust("volume", dir, fine) end
    return true
  end

  if k.key == "MUTE" then
    if not (cfg.volumeKeys and outputIsLG()) then return false end
    if k.down and not k["repeat"] then toggleMute() end
    return true
  end
  return false
end

-- menu bar ------------------------------------------------------------------

local inputs, apps = {}, {}

-- inputs and apps change rarely: fetched in the background, shown from cache
fetchLists = function()
  for _, what in ipairs({ "inputs", "apps" }) do
    hs.http.asyncGet(cfg.url .. what, nil, function(code, body)
      if code ~= 200 then return end
      local ok, list = pcall(hs.json.decode, body)
      if ok and list then
        if what == "inputs" then inputs = list else apps = list end
      end
    end)
  end
end

local function shortcut(spec)
  if not spec then return "" end
  local sym = { cmd = "⌘", alt = "⌥", ctrl = "⌃", shift = "⇧" }
  local keys = { ["return"] = "↩", up = "↑", down = "↓" }
  local out = ""
  for _, m in ipairs(spec[1]) do out = out .. (sym[m] or m) end
  return "   " .. out .. (keys[spec[2]] or spec[2]:upper())
end

buildMenu = function()
  send("status")
  fetchLists()
  local items = { { title = T.brightness .. (state and ("   " .. state.brightness) or ""), disabled = true } }
  for _, v in ipairs({ 0, 20, 40, 60, 80, 100 }) do
    table.insert(items, { title = "    " .. v, checked = state and state.brightness == v,
      fn = function() M.setBrightness(v) end })
  end
  table.insert(items, { title = "-" })

  local inputMenu = {}
  for _, i in ipairs(inputs) do
    local name = i.id:gsub("_1$", ""):gsub("_", " ")
    if i.label ~= "" then name = name .. "  (" .. i.label .. ")" end
    if not i.connected then name = name .. "  · " .. T.notConnected end
    table.insert(inputMenu, { title = name, checked = i.current,
      fn = function() send("input/" .. i.id, fetchLists) end })
  end
  table.insert(items, { title = T.input, menu = inputMenu, disabled = #inputMenu == 0 })

  local appMenu = {}
  for _, a in ipairs(apps) do
    if not a.id:find("^com%.webos%.app%.") then   -- skip system apps (settings, inputs...)
      table.insert(appMenu, { title = a.title, fn = function() send("app/" .. a.id) end })
    end
  end
  table.insert(items, { title = T.apps, menu = appMenu, disabled = #appMenu == 0 })
  table.insert(items, { title = T.back .. shortcut(cfg.backToMac), fn = function() send("back") end })
  table.insert(items, { title = "-" })
  table.insert(items, { title = T.screenOff, tooltip = T.screenOffHint, fn = function() send("screen/off") end })
  table.insert(items, { title = T.standby, fn = function() send("standby") end })
  return items
end

-- setup ---------------------------------------------------------------------

function M.start(opts)
  M.stop()
  cfg = {}
  for k, v in pairs(M.defaults) do cfg[k] = v end
  for k, v in pairs(opts or {}) do cfg[k] = v end
  local lang = cfg.lang or (hs.host.locale.preferredLanguages()[1] or ""):sub(1, 2)
  T = STRINGS[lang] or STRINGS.en

  M.hotkeys = {}
  bindBrightness(cfg.brightnessUp, 1)
  bindBrightness(cfg.brightnessDown, -1)
  M.tap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, onSystemKey):start()

  if cfg.backToMac then
    table.insert(M.hotkeys, hs.hotkey.bind(cfg.backToMac[1], cfg.backToMac[2], function() send("back") end))
  end

  if cfg.menubar then
    menu = hs.menubar.new()
    M.menu = menu
    menu:setTitle("☀︎")
    menu:setTooltip(T.tooltip)
    menu:setMenu(buildMenu)
    fetchLists()
  end

  send("status")
  -- keep the menu title in sync with changes made from the monitor's own joystick
  M.timer = hs.timer.doEvery(60, function() if not busy then send("status") end end)
  return M
end

function M.stop()
  for _, h in ipairs(M.hotkeys or {}) do h:delete() end
  M.hotkeys = {}
  if M.tap then M.tap:stop(); M.tap = nil end
  if M.timer then M.timer:stop(); M.timer = nil end
  if menu then menu:delete(); menu = nil end
end

return M
