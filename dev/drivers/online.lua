-- Real Crystal boot, Gen1Online online end to end against the local test
-- server.  BUDDY, the second trainer, is played by this driver over HTTP.
-- Run it twice in a row (dev/run_tests.sh does): the first run creates the
-- online character, the second logs back in with it.
local U = require("tests.drivers.util")
local Mon = require("src.battle.gen2.Mon")
local Json = require("src.link.Json")
local Protocol = require("src.link.Protocol")
local ModRuntime = require("src.mods.Runtime")

return function(game)
  local out = os.getenv("SHOTS") or "/tmp/gen1online-shots"
  local BASE = "http://127.0.0.1:" .. (os.getenv("GTS_PORT") or "17781")
  local fails = 0
  local function say(...) print("[g1o]", ...) end
  local function check(cond, label)
    say((cond and "PASS " or "FAIL ") .. label)
    if not cond then fails = fails + 1 end
    return cond
  end

  -- Driver runs call Game:update directly; a real launch goes through
  -- PlatformHooks.update, which raises core.update.  Route the same way.
  local Game2 = require("src.core.Game2")
  local realUpdate = Game2.update
  game.update = function(self, dt)
    return ModRuntime.call("core.update", function(g, d) return realUpdate(g, d) end, self, dt)
  end

  -- the engine's require shim treats a driver like a mod, so borrow the HTTP
  -- client the mod itself loaded at boot
  local http, ltn12 = package.loaded["socket.http"], package.loaded["ltn12"]
  local function post(payload)
    payload.modVersion = payload.modVersion or "0.5.0"
    payload.gameVersion = payload.gameVersion or "Pokemon Crystal"
    local body = Json.encode(payload)
    local res = {}
    http.request({ url = BASE .. "/gts", method = "POST", source = ltn12.source.string(body),
      headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#body),
        ["X-Mod-Version"] = "0.5.0" }, sink = ltn12.sink.table(res) })
    local ok, decoded = pcall(Json.decode, table.concat(res))
    return ok and decoded or nil
  end

  local TextBox = require("src.render.TextBox")
  local function top() return game.stack:top() end
  local function isText(s) return s and getmetatable(s) == TextBox end
  local function textOf(s)
    local t = {}
    local function walk(v)
      if type(v) == "string" then t[#t + 1] = v
      elseif type(v) == "table" then for _, x in ipairs(v) do walk(x) end end
    end
    walk(s and s.pages)
    return table.concat(t, " ")
  end
  local seenText = {}
  local function noteTop()
    local s = top()
    if isText(s) then
      local t = textOf(s)
      if seenText[#seenText] ~= t then seenText[#seenText + 1] = t; say("  text: " .. t) end
    end
  end
  local function said(p)
    for _, t in ipairs(seenText) do if t:find(p) then return t end end
  end
  local function clearTexts(limit)
    for _ = 1, limit or 600 do
      noteTop()
      if not isText(top()) then return end
      U.tap(game, "a"); U.wait(3)
    end
  end
  local function menuItems(s)
    local l = {}
    for _, it in ipairs((s and s.items) or {}) do l[#l + 1] = tostring(it.label) end
    return table.concat(l, " | ")
  end
  -- pick a menu row with real input: move the cursor, then A
  local function choose(pattern)
    local s = top()
    if not (s and s.items) then return check(false, "expected a menu for '" .. pattern .. "'") end
    local target
    for i, it in ipairs(s.items) do if tostring(it.label):find(pattern) then target = i break end end
    if not target then return check(false, "no '" .. pattern .. "' in " .. menuItems(s)) end
    for _ = 1, 40 do
      if (s.index or 1) == target then break end
      U.tap(game, (s.index or 1) < target and "down" or "up"); U.wait(2)
    end
    U.tap(game, "a"); U.wait(4)
    return true
  end
  local function waitFor(label, pred, frames)
    for _ = 1, frames or 900 do
      noteTop()
      if pred() then return true end
      U.wait(1)
    end
    return check(false, "timed out waiting for " .. label)
  end
  -- on Crystal the overworld is an EMPTY screen stack
  local function inOverworld() return top() == nil or top() == game.world end
  local function toWorld()
    for _ = 1, 30 do
      clearTexts(60)
      if inOverworld() then return end
      local s = top()
      if s and s.items then U.tap(game, "b"); U.wait(4) elseif s then game.stack:pop(); U.wait(2) end
    end
  end
  local function moveName(id)
    local def = game.data.moves and game.data.moves[id]
    return tostring(def and def.name or id)
  end

  -- ---- boot, offline hygiene ------------------------------------------------------
  U.wait(60)
  local world = game.world
  check(world and world.map ~= nil, "Crystal world is up")
  local exports = game.mods and game.mods.exports and game.mods.exports["gen1online-plus"]
  check(exports ~= nil, "gen1online-plus loaded")
  U.wait(240) -- flag changes etc. fire the mod's event handlers offline
  check(game.save.onlineAccount == nil, "offline save carries no online account")
  check(game.save.player.name ~= "ETHAN", "offline player keeps its own name")
  game.save.party = { Mon.new(game.data, "CYNDAQUIL", 30), Mon.new(game.data, "PIDGEY", 8) }
  local offlineName = game.save.player.name

  -- ---- CONNECT through the real START menu ---------------------------------------
  U.tap(game, "start"); U.wait(10)
  local sm, idx = top(), nil
  for i, it in ipairs((sm and sm.items) or {}) do if it.label == "CONNECT" then idx = i end end
  check(idx ~= nil, "START menu shows CONNECT")
  sm.list.index = idx
  U.tap(game, "a"); U.wait(10)
  local returning = not menuItems(top()):find("CREATE NEW PLAYER")
  say("  " .. (returning and "returning player: logging back in" or "fresh install: creating a character"))
  if returning then
    waitFor("CONNECTED", function() return said("CONNECTED TO SERVER") ~= nil end, 300)
  else
    choose("CREATE NEW PLAYER"); U.wait(10)
    check(getmetatable(top()) == require("src.ui.gen2.NamingScreen"), "Crystal's own naming screen opens")
    top().onDone("ETHAN") -- END pressed with the name typed
    U.wait(10)
    check(menuItems(top()):find("CRYSTAL"), "avatar menu after the name")
    choose("CRYSTAL")
    waitFor("PLAYER CREATED", function() return said("PLAYER CREATED") ~= nil end, 600)
  end
  U.shot(game, out .. "/10_connected.png")
  clearTexts(); toWorld()
  check(game.save.player.name == "ETHAN", "online character is live")
  local myId = tostring(game.save.player.id)
  check(game:speedLocked() == true, "1x speed lock while online")
  -- a close fight so both sides attack
  game.save.party = { Mon.new(game.data, "CYNDAQUIL", 16), Mon.new(game.data, "PIDGEY", 8) }

  -- ---- BUDDY appears next to us -------------------------------------------------------
  local p = world.player
  local function buddySync()
    return post({ action = "sync_pos", trainerId = "777777", sessionId = "buddy",
      name = "BUDDY", spriteId = "SPRITE_FALKNER", map = world.map.id,
      x = p.cellX, y = p.cellY + 1, px = p.cellX * 16, py = (p.cellY + 1) * 16,
      facing = "up", moving = false })
  end
  local buddy
  for _ = 1, 40 do
    buddySync(); U.wait(15)
    buddy = exports.netNpcs and exports.netNpcs["777777"]
    if buddy and buddy.sprite then break end
  end
  check(buddy and buddy.sprite, "BUDDY shows up with a sprite")
  U.wait(30)
  U.shot(game, out .. "/20_remote_player.png")

  -- ---- PVP: each side uses a move that is NOT slot 1 ------------------------------
  world.player.facing = "down"; U.wait(2)
  U.tap(game, "a"); U.wait(8)
  check(menuItems(top()):find("PVP"), "A on BUDDY opens the trainer menu")
  choose("PVP"); clearTexts(30)
  local challenge
  for _ = 1, 20 do
    local r = buddySync()
    if r and r.challenge then challenge = r.challenge break end
    U.wait(5)
  end
  check(challenge and challenge.type == "PVP", "BUDDY receives the challenge")
  local room = challenge and challenge.roomId or ""
  check(room:sub(-3) == "_L2", "room offers the native battle")
  local buddyMon = Mon.new(game.data, "SENTRET", 10)
  local buddySlot = math.max(1, #(buddyMon.moves or {}))
  local buddyMove = moveName(buddyMon.moves[buddySlot].id)
  post({ action = "send_challenge", targetId = myId, fromId = "777777", fromName = "BUDDY",
    challengeType = "ACCEPT_PVP", party = Protocol.packParty2({ buddyMon }),
    seed = challenge and challenge.seed or 7, roomId = room .. "K" })
  local battle
  waitFor("the link battle", function()
    buddySync()
    local s = top()
    if s and s.linkRole then battle = s return true end
    if isText(s) then U.tap(game, "a") end
  end, 1200)
  check(battle and battle.linkRole == "host", "native LinkBattle2 battle started")
  U.wait(60)
  U.shot(game, out .. "/21_pvp_battle.png")
  local function preferredSlot(mon)
    local best, power = nil, -1
    for i, mv in ipairs((mon and mon.moves) or {}) do
      local def = game.data.moves and game.data.moves[mv.id]
      local pw = def and tonumber(def.power) or 0
      if i > 1 and (mv.pp or 1) > 0 and pw > power then best, power = i, pw end
    end
    return best or 1
  end
  local myMove
  local battleText, last = {}, nil
  local answered, turns = {}, 0
  for _ = 1, 6000 do
    -- battle lines live in the event queue and, once shown, in .message
    for _, ev in ipairs(battle.queue or {}) do
      if type(ev.text) == "string" and ev.text ~= last then last = ev.text; battleText[#battleText + 1] = ev.text end
    end
    if type(battle.message) == "string" and battle.message ~= last then
      last = battle.message; battleText[#battleText + 1] = battle.message
    end
    if top() ~= battle then break end
    if battle.phase == "moves" then
      local mon = battle.battle and battle.battle.player
      local target = preferredSlot(mon)
      myMove = moveName(mon.moves[target].id)
      for _ = 1, 8 do
        if battle.moveIndex == target then break end
        U.tap(game, "down"); U.wait(2)
      end
      U.tap(game, "a"); U.wait(3)
    elseif battle.phase == "link-wait" then
      local n = 0
      for _ in pairs(battle.localHashes or {}) do n = n + 1 end
      if not answered[n] then
        answered[n] = true; turns = turns + 1
        post({ action = "send_battle_msg", roomId = room .. "K", targetId = myId,
          msg = { type = "action", kind = "move", slot = buddySlot } })
      end
      U.wait(5)
    else
      U.tap(game, "a"); U.wait(3)
    end
  end
  local all = table.concat(battleText, "\n"):upper()
  check(myMove and all:find(("used " .. myMove):upper(), 1, true), "player's chosen move resolved (" .. tostring(myMove) .. ")")
  check(all:find(("used " .. buddyMove):upper(), 1, true), "BUDDY's chosen move resolved (" .. buddyMove .. ")")
  check(battle.result == "win", "won the battle in " .. turns .. " turns")
  clearTexts(); toWorld()
  check(game.linkNet == nil and inOverworld(), "back in the overworld, link released")

  -- ---- GTS trade with a trade evolution ---------------------------------------------
  local kadabra = Mon.new(game.data, "KADABRA", 22)
  local dep = post({ action = "deposit", trainerId = "777777", trainerName = "BUDDY",
    offeredMon = Protocol.packMon2(kadabra), wanted = { "PIDGEY" } })
  check(dep and dep.success, "BUDDY deposited a KADABRA")
  local gts
  for _, it in ipairs(ModRuntime.call("ui.pc.items", function(g, l) return l end, game,
      { { id = "items", label = "ITEM STORAGE" }, { id = "decoration", label = "DECORATION" } })) do
    if it.id == "gts" then gts = it end
  end
  check(gts ~= nil, "PC offers GTS")
  gts.onSelect(); U.wait(10)
  choose("BROWSE"); choose("ALL ACTIVE"); U.wait(6)
  choose("KADABRA"); U.wait(10)
  U.tap(game, "a"); U.wait(10)
  choose("GIVE PIDGEY")
  local TradeView, EvoView = require("src.ui.gen2.TradeAnim"), require("src.ui.gen2.EvolutionAnim")
  local sawTrade, sawEvo = false, false
  for _ = 1, 9000 do
    local s = top()
    if getmetatable(s) == TradeView and not sawTrade then sawTrade = true; U.wait(90); U.shot(game, out .. "/31_trade.png") end
    if getmetatable(s) == EvoView and not sawEvo then sawEvo = true; U.wait(60); U.shot(game, out .. "/32_evolution.png") end
    noteTop()
    if said("GTS TRADE COMPLETE") then break end
    U.tap(game, "a"); U.wait(2)
  end
  check(sawTrade and sawEvo, "trade animation and trade evolution played")
  clearTexts(); toWorld()
  local got
  for _, m in ipairs(game.save.party) do if m.species == "ALAKAZAM" then got = m end end
  check(got and got.experience and got.ot == "BUDDY", "ALAKAZAM arrived as a proper Gen 2 mon, OT BUDDY")

  -- ---- saving and disconnecting ---------------------------------------------------
  local fsys = love.filesystem
  local onlinePath = "mod_compat/gen1online-plus/save_online_crystal.lua"
  check(game:writeSave() == true, "SAVE while online succeeds")
  local onlineBody = fsys.getInfo(onlinePath) and fsys.read(onlinePath)
  check(onlineBody and onlineBody:find("ALAKAZAM"), "online save on disk has the ALAKAZAM")
  U.tap(game, "start"); U.wait(10)
  sm, idx = top(), nil
  local hasSave = false
  for i, it in ipairs((sm and sm.items) or {}) do
    if it.label == "ONLINE" then idx = i end
    if tostring(it.label):upper() == "SAVE" then hasSave = true end
  end
  check(idx ~= nil and not hasSave, "ONLINE shown and SAVE hidden while connected")
  sm.list.index = idx
  U.tap(game, "a"); U.wait(8)
  choose("DISCONNECT")
  clearTexts(); toWorld()
  check(game.save.player.name == offlineName and game.save.onlineAccount == nil, "offline save restored")
  check(not game:speedLocked(), "speed lock released")
  check(game:writeSave() == true, "offline SAVE succeeds")
  local onDisk = require("src.core.gen2.Save").load("crystal")
  check(onDisk and onDisk.player and onDisk.player.name == offlineName, "normal save on disk holds the offline character")
  local after = fsys.read(onlinePath)
  check(after and after:find("ETHAN"), "online save still holds the online character")

  say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
  love.event.quit(fails == 0 and 0 or 1)
  U.wait(5)
end
