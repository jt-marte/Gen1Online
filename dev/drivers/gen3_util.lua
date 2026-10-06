-- Helpers shared by the FireRed / LeafGreen drivers (gen3_online.lua,
-- gen3_link.lua): checks, raw HTTP to the test server, the mod's screens,
-- the START menu, and a new online character.  Loaded with
--   local H = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_util.lua")(game, "label")
local U = require("tests.drivers.util")
local Json = require("src.link.Json")
local ModRuntime = require("src.mods.Runtime")

return function(game, label)
  local H = { U = U }
  local out = os.getenv("SHOTS") or ("/tmp/gen1online-shots/" .. label)
  H.BASE = "http://127.0.0.1:" .. (os.getenv("GTS_PORT") or "17781")
  H.version = require("src.core.GameVersion").get()
  H.GAME_NAME = H.version == "leafgreen" and "Pokemon LeafGreen" or "Pokemon FireRed"
  local fails = 0
  local tag = os.getenv("G1O_ROLE") and ("[" .. os.getenv("G1O_ROLE") .. "]") or ""
  function H.say(...) print("[g1o]" .. tag, ...) end
  function H.check(cond, text)
    H.say((cond and "PASS " or "FAIL ") .. text)
    if not cond then fails = fails + 1 end
    return cond
  end
  function H.finish()
    H.say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
    love.event.quit(fails == 0 and 0 or 1)
    while true do coroutine.yield() end
  end
  local shotN = 0
  function H.shot(name)
    shotN = shotN + 1
    U.shot(game, string.format("%s/%02d_%s.png", out, shotN, name))
  end

  -- driver runs call Game:update directly; route it through core.update
  local realUpdate = game.update
  game.update = function(self, dt)
    return ModRuntime.call("core.update", function(g, d) return realUpdate(g, d) end, self, dt)
  end

  function H.boot()
    for _ = 1, 900 do
      if game.phase == "boot" and game.boot then break end
      U.wait(1)
    end
    local exports = game.mods and game.mods.exports and game.mods.exports["gen1online-plus"] or {}
    H.GtsUI, H.G3 = exports.ui, exports.gen3
    if not H.check(H.GtsUI and H.G3, "gen1online-plus loaded with its FireRed layer on " .. H.version) then
      return false
    end
    H.online = H.GtsUI.G3env.online
    H.Stack = H.G3.UI.Stack
    return true
  end

  local http, ltn12 = package.loaded["socket.http"], package.loaded["ltn12"]
  function H.post(payload)
    payload.modVersion = payload.modVersion or "0.5.1"
    payload.gameVersion = payload.gameVersion or H.GAME_NAME
    payload.generation = 3
    local body = Json.encode(payload)
    local res = {}
    http.request({ url = H.BASE .. "/gts", method = "POST", source = ltn12.source.string(body),
      headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#body),
        ["X-Mod-Version"] = "0.5.1" }, sink = ltn12.sink.table(res) })
    local ok, decoded = pcall(Json.decode, table.concat(res))
    return ok and decoded or nil
  end
  function H.get(path)
    local res = {}
    http.request({ url = H.BASE .. path .. (path:find("?", 1, true) and "&" or "?")
      .. "gen=3&version=0.5.1&modVersion=0.5.1", sink = ltn12.sink.table(res) })
    local ok, decoded = pcall(Json.decode, table.concat(res))
    return ok and decoded or nil
  end

  local Runtime = require("src.core.game3.runtime")
  local StartMenu = require("src.ui.game3.start_menu")
  local Message = require("src.ui.game3.message")
  local Naming = require("src.ui.game3.naming")

  function H.top() return H.Stack:top() end
  function H.isText(s) return s and getmetatable(s) == H.G3.TextBox end
  function H.isMenu(s) return s and getmetatable(s) == H.G3.Menu end
  function H.textOf(s) return table.concat(s.pages or {}, " / ") end
  local seen = {}
  H.seen = seen
  function H.said(p)
    for _, t in ipairs(seen) do if t:find(p, 1, true) then return t end end
  end
  function H.clearTexts(max)
    for _ = 1, max or 600 do
      local s = H.top()
      if not H.isText(s) then return end
      local t = H.textOf(s)
      if seen[#seen] ~= t then seen[#seen + 1] = t; H.say("  text: " .. t:gsub("\n", " ")) end
      U.tap(game, "a"); U.wait(2)
    end
  end
  function H.labels(s)
    local l = {}
    for _, it in ipairs((s and s.items) or {}) do l[#l + 1] = tostring(it.label) end
    return table.concat(l, " | ")
  end
  function H.choose(pattern)
    H.clearTexts()
    local s = H.top()
    if not H.isMenu(s) then return H.check(false, "expected a menu for '" .. pattern .. "'") end
    local target
    for i, it in ipairs(s.items) do if tostring(it.label):find(pattern) then target = i break end end
    if not target then return H.check(false, "no '" .. pattern .. "' in " .. H.labels(s)) end
    s.index = target
    s:clampScroll()
    U.tap(game, "a"); U.wait(4)
    return true
  end
  function H.waitMenu(pattern, frames)
    for _ = 1, frames or 900 do
      local s = H.top()
      if H.isMenu(s) and H.labels(s):find(pattern) then return true end
      if H.isText(s) then H.clearTexts(1) end
      U.wait(1)
    end
    return false
  end
  function H.closeAll()
    for _ = 1, 60 do
      H.clearTexts()
      if H.Stack:size() == 0 then break end
      U.tap(game, "b"); U.wait(3)
    end
    for _ = 1, 30 do
      if not StartMenu.isOpen() then break end
      U.tap(game, "b"); U.wait(4)
    end
  end
  function H.fieldFree()
    for _ = 1, 600 do
      if Runtime.isActive() and not H.G3.busy() then return true end
      if Message.isOpen() then U.tap(game, "a") end
      U.wait(2)
    end
    return false
  end
  function H.openStart()
    for _ = 1, 40 do
      if StartMenu.isOpen() then return true end
      U.tap(game, "start")
      for _ = 1, 20 do if StartMenu.isOpen() then return true end U.wait(1) end
    end
    return false
  end
  function H.startItem(id)
    if not H.openStart() then return H.check(false, "START menu opened") end
    for i, e in ipairs(StartMenu.ENTRIES or {}) do
      if e.id == id then
        StartMenu.cursor = i
        StartMenu.clampScroll()
        U.tap(game, "a"); U.wait(4)
        return true
      end
    end
    return H.check(false, "START menu has " .. id)
  end
  function H.naming(text, shotName)
    for _ = 1, 120 do if Naming.isOpen() then break end U.wait(1) end
    if not H.check(Naming.isOpen(), "FireRed's naming screen opened") then return false end
    if shotName then H.shot(shotName) end
    Naming.close(text)
    U.wait(4)
    return true
  end

  -- a new offline game, then CONNECT > JOIN > CREATE NEW PLAYER
  function H.newOffline(name)
    game:_handleBootAction({ action = "new_game", name = name or "OFFLINE" })
    U.wait(240)
    local s = Runtime.getSession()
    H.check(s and s.map == "FR_PLAYERS_HOUSE_2F", "a new offline game in the bedroom")
    return s
  end
  function H.createPlayer(name, avatar, shots)
    H.startItem("gen1online")
    if shots then H.shot("connect_menu") end
    H.choose("^JOIN")
    H.choose("CREATE NEW PLAYER")
    if not H.naming(name, shots and "naming") then return false end
    if shots then H.shot("avatars") end
    H.choose(avatar)
    for _ = 1, 300 do
      if H.online() and Runtime.isActive() and H.isText(H.top()) then break end
      U.wait(2)
    end
    return H.online()
  end
  function H.account()
    local s = Runtime.getSession()
    return s and s.modData and s.modData["gen1online-plus"] and s.modData["gen1online-plus"].onlineAccount
  end

  return H
end
