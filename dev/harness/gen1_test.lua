-- Gen 1 (G1O_GAME=red, blue or yellow) against a Gen 1 server (dev/server.sh
-- with GTS_GENERATION=1): the mod on the engine's real Gen 1 Game, StateStack
-- and overworld modules (rig.lua stands in for their ROM-bound methods).
-- Connect, create a character, sync, a second Gen 1 trainer appears, chat,
-- the speed lock, save routing, a PVP challenge, the GTS, Wonder Trade,
-- disconnect and reconnect.  BUDDY and the other trainers are raw HTTP.
local Rig = dofile(os.getenv("G1O_DEV") .. "/harness/rig.lua")
assert(Rig.generation == 1, "run with G1O_GAME=red, blue or yellow")
local PORT = os.getenv("GTS_PORT") or "17781"
local BASE = "http://127.0.0.1:" .. PORT
Rig.overrides["gts_config.txt"] = "server_url=" .. BASE .. "\n"

local fails = 0
local function check(cond, label)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then fails = fails + 1 end
  return cond
end

local Json = require("src.link.Json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")

local function post(payload)
  payload.modVersion = payload.modVersion or "1.0.0"
  payload.gameVersion = payload.gameVersion or "Pokemon Blue"
  local body = Json.encode(payload)
  local out = {}
  http.request({ url = BASE .. "/gts", method = "POST", source = ltn12.source.string(body),
    headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#body),
      ["X-Mod-Version"] = "1.0.0" }, sink = ltn12.sink.table(out) })
  local ok, res = pcall(Json.decode, table.concat(out))
  return ok and res or nil
end
local function get(path)
  local out = {}
  http.request({ url = BASE .. path .. (path:find("?", 1, true) and "&" or "?") .. "version=1.0.0",
    sink = ltn12.sink.table(out) })
  local ok, res = pcall(Json.decode, table.concat(out))
  return ok and res or nil
end

-- ---- the game: Gen 1 data just big enough for the mod's paths ----------------
local game = Rig.newGame()
local world = game.overworld
local SPECIES = { PIKACHU = 25, BULBASAUR = 1, PIDGEY = 16, RATTATA = 19, ABRA = 63,
  KADABRA = 64, ZUBAT = 41, SPEAROW = 21, EKANS = 23, MEOWTH = 52 }
for sp, dex in pairs(SPECIES) do
  game.data.pokemon[sp] = { name = sp, dex = dex, types = { "NORMAL" }, growthRate = "MEDIUM_FAST",
    baseStats = { hp = 45, attack = 45, defense = 45, speed = 45, special = 45 },
    level1Moves = { "TACKLE" }, learnset = {} }
end
game.data.moves = { TACKLE = { id = "TACKLE", pp = 35, power = 35, type = "NORMAL" } }
for _, id in ipairs({ "SPRITE_RED", "SPRITE_BLUE" }) do
  game.data.sprites[id] = { id = id, image = "assets/none.png", frames = 6,
    frameWidth = 16, frameHeight = 16 }
end
game.save.party = {
  { species = "PIKACHU", nickname = "PIKACHU", level = 7, hp = 24, maxHp = 24,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 9, defense = 8, speed = 7, special = 6 } },
}
local offlineName = game.save.player.name

-- screens the rig cannot draw keep their callbacks: the Gen 1 naming screen
-- (it pops itself, then calls onDone) and the Gen 1 trade animation
local NamingScreen = require("src.ui.NamingScreen")
NamingScreen.new = function(g, opts)
  local stub = { naming = true, opts = opts }
  function stub.finish(name) g.stack:pop(); opts.onDone(name, true) end
  return stub
end
local tradeAnim
local TradeAnim = require("src.ui.TradeAnim")
TradeAnim.new = function(g, opts)
  tradeAnim = { tradeAnim = true, opts = opts }
  return tradeAnim
end

local ok, err = Rig.load(game)
check(ok, "loader:load completes on " .. Rig.gameId .. " (" .. tostring(err) .. ")")
local exports = Rig.loader.exports["gen1online-plus"]
check(exports ~= nil, "the mod is loaded on " .. Rig.gameId .. ", not skipped")

-- ---- UI driver ----------------------------------------------------------------
local TextBox = require("src.render.TextBox")
local messages = {}
local function top() return game.stack:top() end
local function textOf(s)
  local out = {}
  local function walk(v)
    if type(v) == "string" then out[#out + 1] = v
    elseif type(v) == "table" then for _, x in ipairs(v) do walk(x) end end
  end
  walk(s and (s.pages or s.text))
  return table.concat(out, " ")
end
local function describe(s)
  if not s then return "nil" end
  if s.items then
    local l = {}
    for _, it in ipairs(s.items) do l[#l + 1] = tostring(it.label) end
    return "Menu{" .. table.concat(l, " | ") .. "}"
  end
  if getmetatable(s) == TextBox then return "TextBox{" .. textOf(s) .. "}" end
  if s == world then return "Overworld" end
  if s.naming then return "Naming{" .. tostring(s.opts.title) .. "}" end
  if s.tradeAnim then return "TradeStub" end
  return tostring(s)
end
local function pick(pattern)
  local s = top()
  if not (s and s.items) then error("expected a menu, top is " .. describe(s), 2) end
  for _, it in ipairs(s.items) do
    if tostring(it.label):find(pattern) then
      if not it.keepOpen then game.stack:pop() end
      if it.onSelect then it.onSelect() end
      return true
    end
  end
  error("no item '" .. pattern .. "' in " .. describe(s), 2)
end
local function closeTexts()
  for _ = 1, 20 do
    local s = top()
    if not (s and getmetatable(s) == TextBox) then return end
    messages[#messages + 1] = textOf(s)
    game.stack:pop()
    if s.onDone then s.onDone() end
  end
end
local function said(pattern)
  for _, m in ipairs(messages) do if m:find(pattern) then return m end end
  return nil
end
local function popTo(state) while top() and top() ~= state do game.stack:pop() end end
-- a Gen 1 frame: the overworld on top updates (the mod's wrapper around the
-- rig's stand-in), through the core.update hook
local function frames(n)
  for _ = 1, n do
    local okF, e = pcall(Rig.hook, "core.update", function(g, dt)
      local t = g.stack:top()
      if t and t.update then t:update(dt) end
    end, game, 1 / 60)
    if not okF then Rig.record("frame", e) end
    socket.sleep(0.004)
  end
end
local function waitUntil(cond, seconds)
  local deadline = socket.gettime() + (seconds or 8)
  while socket.gettime() < deadline do
    frames(10)
    if cond() then return true end
  end
  return cond() and true or false
end
local function startMenu(list)
  return Rig.hook("ui.start_menu.items", function(g, l) return l end, game, list or {})
end
local function item(list, label)
  for _, it in ipairs(list) do if it.label == label then return it end end
end
local function openGts(entry)
  popTo(world)
  messages = {}
  item(Rig.hook("ui.pc.items", function(g, l) return l end, game, {}), "GTS").onSelect()
  pick(entry)
  return describe(top())
end
local function partySpecies()
  local out = {}
  for _, m in ipairs(game.save.party or {}) do out[#out + 1] = m.species end
  return table.concat(out, ",")
end
local function finishTradeAnim()
  if not tradeAnim then return false end
  local anim = tradeAnim
  tradeAnim = nil
  popTo(anim)
  game.stack:pop()   -- Gen 1's TradeAnim pops itself, then calls onDone
  anim.opts.onDone()
  closeTexts()
  return true
end
local function mon(species, level)
  return { species = species, level = level or 5, nickname = species,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 8, defense = 8, speed = 8, special = 8 } }
end

-- ---- 1. CONNECT, create a character ---------------------------------------------
item(startMenu(), "CONNECT").onSelect()
pick("^JOIN")
check(top() and top().items, "no online save yet -> create/redeem menu")
pick("CREATE NEW PLAYER")
check(top() and top().naming, "CREATE NEW PLAYER opens the Gen 1 naming screen")
top().finish("ASH")
local avatars = describe(top())
check(avatars:find("RED / PROTAGONIST") and avatars:find("BLUE / RIVAL") and not avatars:find("CRYSTAL"),
  "Gen 1 avatars, only ones this game has sprites for: " .. avatars)
pick("BLUE / RIVAL")
closeTexts()
check(said("PLAYER CREATED") ~= nil, "server registered the character: " .. table.concat(messages, " / "))
popTo(world)
Rig.dump("create")
local myId = tostring(game.save.player.id)
check(game.save.player.name == "ASH", "game now runs the online character")
local token = game.save.onlineAccount and game.save.onlineAccount.token or ""
check(token:match("^%u%u%u%u%u%u%u%u$") ~= nil, "the recovery token is 8 letters, typeable on Gen 1 (" .. token .. ")")
check((get("/server/info") or {}).generation == 1, "the server is a Gen 1 world")
local onlinePath, accountPath, crystalPath
for path in pairs(Rig.writes) do
  if path:match("save_online_" .. Rig.gameId .. "%.lua$") then onlinePath = path end
  if path:match("gen1online_online_account_" .. Rig.gameId .. "%.lua$") then accountPath = path end
  if path:match("save_online_crystal") or path:match("gen1online_online_account%.lua$") then crystalPath = path end
end
check(crystalPath == nil, "Crystal's online save and account are untouched (" .. tostring(crystalPath) .. ")")
check(onlinePath ~= nil, "online save written to save_online_" .. Rig.gameId .. ".lua")
check(accountPath ~= nil, "online account written to gen1online_online_account_" .. Rig.gameId .. ".lua")
game.save.party = {
  { species = "PIKACHU", nickname = "PIKACHU", level = 7, hp = 24, maxHp = 24,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 9, defense = 8, speed = 7, special = 6 } },
  { species = "PIDGEY", nickname = "PIDGEY", level = 5, hp = 19, maxHp = 19,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 5, defense = 5, speed = 5, special = 5 } },
  { species = "RATTATA", nickname = "RATTATA", level = 4, hp = 17, maxHp = 17,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 4, defense = 4, speed = 4, special = 4 } },
}

-- ---- 2. sync ------------------------------------------------------------------------
waitUntil(function() return ((get("/gts/players") or {}).players or {})[myId] ~= nil end, 6)
local me = ((get("/gts/players") or {}).players or {})[myId]
check(me ~= nil, "server lists this client in /gts/players")
check(me and me.spriteId == "SPRITE_BLUE" and me.map == world.map.id,
  "the sync carries the avatar and the Gen 1 map (" .. tostring(me and me.spriteId) .. ", "
  .. tostring(me and me.map) .. ")")

-- ---- 3. a second Gen 1 trainer; Crystal trainers are not in this world --------------
local function buddySync(extra)
  local p = { action = "sync_pos", trainerId = "777777", sessionId = "buddy-session",
    name = "BUDDY", spriteId = "SPRITE_RED", map = world.map.id, x = 5, y = 8,
    px = 80, py = 128, facing = "up", moving = false }
  for k, v in pairs(extra or {}) do p[k] = v end
  return post(p)
end
waitUntil(function() buddySync(); return exports.netNpcs["777777"] ~= nil end, 10)
local buddy = exports.netNpcs["777777"]
check(buddy ~= nil and buddy.sprite ~= nil, "remote player BUDDY spawned with a Gen 1 sprite")
check(buddy and buddy.spriteId == "SPRITE_RED", "BUDDY carries its sprite id (" .. tostring(buddy and buddy.spriteId) .. ")")
-- remote players join the overworld's entities for the draw only, so the
-- engine draws them on every path, a render pipeline (the voxel mod) too
local function hasBuddy(list)
  for _, e in ipairs(list or {}) do if e == buddy then return true end end
  return false
end
local during, entitiesBefore = nil, #world.entities
world.drawProbe = function(ow) during = hasBuddy(ow.entities) end
check(pcall(world.drawWorld, world), "drawWorld with a remote player")
world.drawProbe = nil
check(during == true, "BUDDY is in the overworld's entities while the world draws")
check(not hasBuddy(world.entities) and #world.entities == entitiesBefore,
  "and gone from them afterwards (" .. #world.entities .. " entities)")
-- a pipeline's field-effect pass also tags the trainers, anchored through
-- the pipeline's own projection
local Pipelines = require("src.render.Pipelines")
local fxRuns, anchors = 0, {}
local ctx = { state = world, drawFx = function() fxRuns = fxRuns + 1 end }
pcall(Pipelines.drawWorld, "g1o-no-such-pipeline", ctx)
pcall(ctx.drawFx, function(wx, wy) anchors[#anchors + 1] = wx .. "," .. wy; return wx, wy, 1 end, 2)
check(fxRuns == 1, "the engine's own field effects still run in a pipeline")
check(table.concat(anchors, " "):find((buddy.px + 8) .. "," .. (buddy.py + 16), 1, true) ~= nil
  and #anchors >= 4, "name tags projected at BUDDY's and the player's feet (" .. table.concat(anchors, " ") .. ")")
-- the idle player keeps polling while someone else is on the map, so
-- BUDDY's steps arrive within a fraction of a second, not 2-4 s late
buddySync({ x = 6, y = 8, px = 96, py = 128, facing = "right", moving = true })
local t0 = socket.gettime()
waitUntil(function() return buddy.targetPx == 96 end, 3)
local lag = socket.gettime() - t0
check(buddy.targetPx == 96 and lag < 1.0, ("an idle player sees BUDDY's step in %.2fs"):format(lag))
buddySync()
local crystal = buddySync({ trainerId = "888888", gameVersion = "Pokemon Crystal" })
check(crystal and crystal.error == "WRONG_GENERATION" and crystal.serverGeneration == 1,
  "a Crystal trainer is turned away by this Gen 1 server")
frames(30)
check(exports.netNpcs["888888"] == nil, "no Crystal trainer appears in the Gen 1 world")
Rig.dump("remote player")

-- ---- 4. chat ----------------------------------------------------------------------------
post({ action = "send_chat", trainerId = "777777", name = "BUDDY", text = "HELLO FROM PALLET", scope = "global" })
waitUntil(function() buddySync(); closeTexts(); return said("HELLO FROM PALLET") ~= nil end, 12)
check(said("HELLO FROM PALLET") ~= nil, "live chat notification shows the message")
popTo(world)

-- ---- 5. speed lock + save routing ---------------------------------------------------------
local locked, why = game:speedLocked()
check(locked == true and why == "online", "Game:speedLocked holds Gen 1 at 1x while online")
local SaveData = require("src.core.SaveData")
game.save.money = 4242
check(SaveData.save(game.save) == true, "SAVE while online reports success")
local SaveSerializer = require("src.core.SaveSerializer")
local stored = SaveSerializer.decode(Rig.writes[onlinePath] or "")
check(stored and stored.money == 4242 and stored.onlineAccount and stored.onlineAccount.token == token,
  "the online save holds the progress and the account token")

-- ---- 6. a PVP challenge -------------------------------------------------------------------
buddySync({ x = 5, y = 7 })
frames(60)
world.player.cellX, world.player.cellY, world.player.facing = 5, 6, "down"
buddy = exports.netNpcs["777777"]
if buddy then buddy.cellX, buddy.cellY = 5, 7 end
messages = {}
check(pcall(world.interact, world), "A press facing the remote player")
check(top() and top().items and describe(top()):find("PVP"), "trainer menu offers PVP: " .. describe(top()))
pick("PVP")
closeTexts()
local challenge = (buddySync() or {}).challenge
check(challenge and challenge.type == "PVP" and challenge.party and #challenge.party == 3,
  "BUDDY receives the PVP challenge with the Gen 1 party")
local room = challenge and challenge.roomId or ""
check(room ~= "" and room:sub(-3) ~= "_L2", "a Gen 1 room (no native Crystal battle tag): " .. room)
post({ action = "send_challenge", targetId = myId, fromId = "777777", fromName = "BUDDY",
  challengeType = "DECLINE" })
waitUntil(function() buddySync(); closeTexts(); return said("DECLINED") ~= nil end, 8)
check(said("DECLINED") ~= nil, "BUDDY's DECLINE reaches the challenger")
popTo(world)
frames(20)
-- challenged again, BUDDY accepts: the Gen 1 link battle starts over the room
buddySync({ x = 5, y = 7 })
frames(30)
buddy = exports.netNpcs["777777"]
if buddy then buddy.cellX, buddy.cellY = 5, 7 end
world.player.facing = "down"
messages = {}
check(pcall(world.interact, world), "A press facing the remote player again")
pick("PVP")
closeTexts()
challenge = (buddySync({ x = 5, y = 7 }) or {}).challenge
room = challenge and challenge.roomId or ""
post({ action = "send_challenge", targetId = myId, fromId = "777777", fromName = "BUDDY",
  challengeType = "ACCEPT_PVP", seed = challenge and challenge.seed or 1, roomId = room,
  party = { { species = "MEOWTH", level = 6, hp = 22, moves = { { id = "TACKLE", pp = 35 } },
    dvs = { attack = 5, defense = 5, speed = 5, special = 5 } } } })
local battle
waitUntil(function()
  buddySync({ x = 5, y = 7 })
  local t = top()
  if t and getmetatable(t) == TextBox then
    messages[#messages + 1] = textOf(t)
    game.stack:pop()
    local okD, eD = pcall(function() if t.onDone then t.onDone() end end)
    if not okD then Rig.record("battle start", eD) end
  end
  t = top()
  if t and t ~= world and not t.items and getmetatable(t) ~= TextBox then battle = t end
  return battle ~= nil
end, 10)
check(said("CHALLENGE%s+ACCEPTED") ~= nil, "ACCEPT_PVP reaches the challenger: " .. table.concat(messages, " / "))
check(battle ~= nil, "a Gen 1 link battle is on the stack (" .. describe(battle) .. ")")
check(battle and battle.net and battle.net.roomId == room, "it runs over the challenge's room (" .. room .. ")")
-- the battle ends in a win the way the engine ends it: finish() with a result
if battle then
  messages = {}
  battle.result = "win"
  local okFin, eFin = pcall(battle.finish, battle)
  check(okFin, "the battle finishes (" .. tostring(eFin) .. ")")
  -- the engine closes the screen and fades back to the map, then onFinish
  waitUntil(function() closeTexts(); return said("VICTORY") ~= nil end, 5)
  frames(30)
  closeTexts()
  local victories = 0
  for _, m in ipairs(messages) do if m:find("VICTORY") then victories = victories + 1 end end
  check(victories == 1, "the win is announced once: " .. table.concat(messages, " / "))
  local prof = (get("/gts/profile?trainerId=" .. myId) or {}).profile or {}
  check(prof.pvpWins == 1, "the server counts one PVP win (" .. tostring(prof.pvpWins) .. ")")
  check(game.linkNet == nil, "the engine's link lock is released after the battle")
end
Rig.dump("pvp")
popTo(world)
frames(20)

-- a LINK TRADE: on Gen 1 the engine's own cable-club trade (LinkState) opens
-- over the offer's room (the trade itself needs two real games).  For 5 s
-- after a battle the mod drops challenge answers as stale, so wait that out.
waitUntil(function() buddySync({ x = 5, y = 7 }); return false end, 5.5)
buddySync({ x = 5, y = 7 })
frames(30)
buddy = exports.netNpcs["777777"]
if buddy then buddy.cellX, buddy.cellY = 5, 7 end
world.player.facing = "down"
messages = {}
check(pcall(world.interact, world), "A press for a link trade")
pick("LINK TRADE")
closeTexts()
local offer = (buddySync({ x = 5, y = 7 }) or {}).challenge
check(offer and offer.type == "TRADE" and (offer.roomId or ""):match("^TRADE_"), "BUDDY receives the TRADE offer")
post({ action = "send_challenge", targetId = myId, fromId = "777777", fromName = "BUDDY",
  challengeType = "ACCEPT_TRADE", roomId = offer and offer.roomId })
local LinkState = require("src.link.LinkState")
local trade
waitUntil(function()
  buddySync({ x = 5, y = 7 })
  local t = top()
  if t and getmetatable(t) == LinkState then trade = t end
  return trade ~= nil
end, 10)
check(trade ~= nil, "the Gen 1 link trade (LinkState) opens: " .. describe(top()))
check(trade and trade.net and trade.net.roomId == (offer and offer.roomId), "over the offer's room")
Rig.dump("link trade")
-- leave the cable club the engine's own way
if trade then pcall(trade.exitWith, trade, "TRADE CANCELLED.", "cancel") end
closeTexts()
check(not game.linkSession and game.linkNet == nil, "leaving the trade releases the engine's link")
popTo(world)
frames(20)

-- ---- 7. GTS: deposit, a buyer, claim, withdraw, buy ----------------------------------------
openGts("DEPOSIT MON")
pick("FROM PARTY")
pick("RATTATA")
pick("ADD")
pick("J %- L")
pick("KADABRA")
pick("CONFIRM")
closeTexts()
check(said("RATTATA WAS DEPOSITED") ~= nil, "deposit confirmed: " .. table.concat(messages, " / "))
check(partySpecies() == "PIKACHU,PIDGEY", "RATTATA left the party")
local listingId, listing
for lid, l in pairs((get("/gts/browse") or {}).listings or {}) do
  if tostring(l.trainerId) == myId then listingId, listing = lid, l end
end
check(listing and listing.offeredMon.species == "RATTATA" and listing.offeredMon.dvs, "the server holds a Gen 1 packed RATTATA")
local bought = post({ action = "trade", listingId = listingId, buyerId = "300001", buyerName = "BUYER",
  sentMon = mon("KADABRA", 20) })
check(bought and bought.success, "a buyer takes the RATTATA")
openGts("MY LISTINGS")
pick("GET KADABRA")
check(finishTradeAnim(), "the claim plays the Gen 1 trade animation")
check(partySpecies() == "PIKACHU,PIDGEY,KADABRA", "KADABRA claimed into the party (" .. partySpecies() .. ")")
post({ action = "deposit", trainerId = myId, trainerName = "ASH", offeredMon = mon("ZUBAT", 9), wanted = {} })
openGts("MY LISTINGS")
pick("TAKE ZUBAT")
closeTexts()
check(said("WITHDREW ZUBAT") ~= nil and partySpecies() == "PIKACHU,PIDGEY,KADABRA,ZUBAT", "withdraw returns the ZUBAT")
local sold = post({ action = "deposit", trainerId = "500001", trainerName = "SELLER",
  offeredMon = mon("ABRA", 12), wanted = { "PIDGEY" } })
check(sold and sold.success, "a seller lists an ABRA for a PIDGEY")
openGts("BROWSE TRADES")
pick("ALL ACTIVE")
pick("ABRA")
game.input:press("a")
top():update(1 / 60)
pick("GIVE PIDGEY")
local given = tradeAnim and tradeAnim.opts.sent and tradeAnim.opts.sent.species
check(given == "PIDGEY", "PIDGEY is the one leaving")
-- the server has handed the ABRA over: it is saved before the animation ends
local midTrade = SaveSerializer.decode(Rig.writes[onlinePath] or "") or {}
local savedAbra = false
for _, m in ipairs(midTrade.party or {}) do if m.species == "ABRA" then savedAbra = true end end
check(savedAbra, "the ABRA is in the online save while the trade animation still plays")
check(finishTradeAnim() and said("GTS TRADE COMPLETE") ~= nil, "the GTS trade completes")
check(partySpecies() == "PIKACHU,KADABRA,ZUBAT,ABRA", "ABRA arrived, PIDGEY left (" .. partySpecies() .. ")")
local sellerClaims = ((get("/gts/claims?trainerId=500001") or {}).claims) or {}
check(#sellerClaims == 1 and sellerClaims[1].mon.species == "PIDGEY", "the seller's claim box has the PIDGEY")

-- nowhere to put it: with the party and all 12 boxes full, a claim stays on
-- the server until there is room
do
  local Boxes1 = require("src.pokemon.Boxes")
  local party, boxes, current = game.save.party, game.save.boxes, game.save.currentBox
  game.save.party = {}
  for i = 1, 6 do game.save.party[i] = mon("RATTATA", 3) end
  game.save.boxes = nil
  for _, box in ipairs(Boxes1.ensure(game.save)) do
    for j = 1, Boxes1.CAPACITY do box[j] = mon("ZUBAT", 2) end
  end
  local lid = post({ action = "deposit", trainerId = myId, trainerName = "ASH", offeredMon = mon("EKANS", 7),
    wanted = {} }).listing.id
  post({ action = "trade", listingId = lid, buyerId = "300002", buyerName = "B2", sentMon = mon("SPEAROW", 8) })
  openGts("MY LISTINGS")
  pick("GET SPEAROW")
  closeTexts()
  check(said("FULL") ~= nil and tradeAnim == nil, "a full party and full boxes refuse the claim: "
    .. table.concat(messages, " / "))
  check(#(((get("/gts/claims?trainerId=" .. myId) or {}).claims) or {}) == 1, "the SPEAROW waits on the server")
  game.save.party, game.save.boxes, game.save.currentBox = party, boxes, current
  openGts("MY LISTINGS")
  pick("GET SPEAROW")
  check(finishTradeAnim(), "with room again, the claim goes through")
  check(partySpecies():find("SPEAROW", 1, true) ~= nil, "SPEAROW joined the party (" .. partySpecies() .. ")")
end
popTo(world)

-- ---- 8. Wonder Trade ---------------------------------------------------------------------------
local menu = openGts("WONDER TRADE")
check(menu:find("DEPOSIT %(0/5 POOL%)") ~= nil, "empty pool offers DEPOSIT (0/5): " .. menu)
pick("DEPOSIT")
pick("ZUBAT")
closeTexts()
check(said("ZUBAT DEPOSITED INTO WONDER TRADE") ~= nil, "deposited into the pool")
local rawMon = { ["400001"] = "SPEAROW", ["400002"] = "EKANS", ["400003"] = "MEOWTH", ["400004"] = "BULBASAUR" }
for _, tid in ipairs({ "400001", "400002", "400003", "400004" }) do
  post({ action = "wonder_trade_deposit", trainerId = tid, trainerName = "T" .. tid:sub(-1), offeredMon = mon(rawMon[tid]) })
end
local myClaim = (post({ action = "wonder_trade_status", trainerId = myId }) or {}).claim
check(myClaim and myClaim.mon and tostring(myClaim.fromId) ~= myId, "matched: a claim from someone else")
openGts("WONDER TRADE")
pick("CLAIM ")
local leaving = tradeAnim and tradeAnim.opts.sent and tradeAnim.opts.sent.species
check(leaving == "ZUBAT", "the player's own ZUBAT is the one leaving (" .. tostring(leaving) .. ")")
check(finishTradeAnim() and said("WONDER TRADE COMPLETE") ~= nil, "the wonder trade completes")
check(myClaim and partySpecies():find(myClaim.mon.species, 1, true) ~= nil, "the received mon joined the party")

-- XP: every award above landed on the server too
local profile = get("/gts/profile?trainerId=" .. myId)
local clientXp = tonumber(game.save.onlineAccount and game.save.onlineAccount.xp) or -1
check(clientXp > 0 and profile and profile.profile and profile.profile.xp == clientXp,
  "server XP matches the client's (" .. clientXp .. ")")

-- ---- 9. disconnect / reconnect --------------------------------------------------------------------
popTo(world)
messages = {}
local list = startMenu({ { label = "SAVE", value = "save" } })
check(item(list, "ONLINE") ~= nil and item(list, "SAVE") == nil, "ONLINE shown, SAVE hidden while connected")
item(list, "ONLINE").onSelect()
pick("DISCONNECT")
closeTexts()
check(game.save.player.name == offlineName and game.save.onlineAccount == nil, "offline save restored on disconnect")
-- the server hears it at once: no frozen ghost for the others, and
-- coming straight back is not refused as "already active"
check(((get("/gts/players") or {}).players or {})[myId] == nil,
  "DISCONNECT logs out on the server right away")
check(not game:speedLocked(), "speed lock released")
popTo(world)
frames(60)
item(startMenu(), "CONNECT").onSelect()
pick("^JOIN")
closeTexts()
check(game.save.player.name == "ASH" and game.save.money == 4242, "reconnect restores the online character")
popTo(world)
Rig.dump("disconnect/reconnect")

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
