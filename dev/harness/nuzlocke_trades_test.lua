-- The hardcore Nuzlocke's trade limit on Gen 1 (G1O_GAME=yellow) against a
-- Gen 1 server with `nuzlocke = hardcore` and `nuzlocke_trades = 1`
-- (dev/server.sh with GTS_CONFIG): one trade per stretch of gym leaders
-- beaten.  A GTS or Wonder Trade deposit is the trade (taken back in the same
-- stretch, it is given back; from an earlier stretch, it stays spent), a GTS
-- buy is a trade, and claims never count.  With no trades left, a buy, a
-- deposit, a Wonder Trade deposit, a LINK TRADE offer and an accepted TRADE
-- challenge are refused.  The counts survive DISCONNECT and JOIN, and with
-- no limit in the rules nothing counts.  BUDDY and the others are raw HTTP.
local Rig = dofile(os.getenv("G1O_DEV") .. "/harness/rig.lua")
assert(Rig.generation == 1, "run with G1O_GAME=yellow")
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

local exports   -- the mod's exports, once loaded (modesVersion comes from them)
local function post(payload)
  payload.modVersion = payload.modVersion or "0.5.1"
  payload.gameVersion = payload.gameVersion or "Pokemon Yellow"
  payload.generation = payload.generation or 1
  -- a hardcore server turns away POSTs below its rules version
  payload.modesVersion = payload.modesVersion or (exports and exports.ui and exports.ui.MODES_VERSION)
  local body = Json.encode(payload)
  local out = {}
  http.request({ url = BASE .. "/gts", method = "POST", source = ltn12.source.string(body),
    headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#body),
      ["X-Mod-Version"] = "0.5.1" }, sink = ltn12.sink.table(out) })
  local ok, res = pcall(Json.decode, table.concat(out))
  return ok and res or nil
end
local function get(path)
  local out = {}
  http.request({ url = BASE .. path .. (path:find("?", 1, true) and "&" or "?") .. "version=0.5.1&gen=1",
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
exports = Rig.loader.exports["gen1online-plus"]
check(exports ~= nil and exports.modes ~= nil and exports.ui ~= nil, "the mod and its game modes are loaded")
local Modes = exports.modes
check(tonumber(exports.ui.MODES_VERSION) ~= nil, "the client's rules version: " .. tostring(exports.ui.MODES_VERSION))
-- the leaders' defeat flags come from the engine's victories table
check(Modes.gymsBeaten({ flags = { EVENT_BEAT_BROCK = true } }) == 1
  and Modes.gymsBeaten({ flags = { EVENT_BEAT_BROCK = true, EVENT_BEAT_MISTY = true } }) == 2
  and Modes.gymsBeaten({ flags = {} }) == 0, "gymsBeaten counts the leaders' defeat flags")
check(Modes.tradesLeft(game.save) == nil and not Modes.tradeRefusal(game.save),
  "offline: no trade limit")

-- swallowed mod errors fail the test
local function dump(label)
  check(#Rig.errors == 0, label .. ": no swallowed mod errors (" .. #Rig.errors .. ")")
  Rig.dump(label)
end

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
local function hasSpecies(species)
  for _, m in ipairs(game.save.party or {}) do if m.species == species then return true end end
  return false
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
-- every Pokémon alive: the hardcore rules bury a fainted one on idle frames
local function mon(species, level)
  return { species = species, level = level or 5, nickname = species, hp = 20, maxHp = 20,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 8, defense = 8, speed = 8, special = 8 } }
end
-- the notes the modes show once the overworld is free
local function notes()
  popTo(world)
  for _ = 1, 4 do frames(10); closeTexts() end
  popTo(world)
end
local function runInfo()
  popTo(world)
  messages = {}
  local online = item(startMenu(), "ONLINE")
  if not online then return nil end
  online.onSelect()
  pick("RUN INFO")
  closeTexts()
  popTo(world)
  return table.concat(messages, " / ")
end
local function listingOf(tid, species)
  for lid, l in pairs((get("/gts/browse") or {}).listings or {}) do
    if tostring(l.trainerId) == tid and (not species or (l.offeredMon or {}).species == species) then
      return lid, l
    end
  end
end
local function buddySync(extra)
  local p = { action = "sync_pos", trainerId = "777777", sessionId = "buddy-session",
    name = "BUDDY", spriteId = "SPRITE_RED", map = world.map.id, x = 5, y = 7,
    px = 80, py = 112, facing = "up", moving = false }
  for k, v in pairs(extra or {}) do p[k] = v end
  return post(p)
end
local REFUSED = "ALREADY TRADED"

-- ---- 1. CONNECT, create a character on the hardcore server ------------------------
local info = get("/server/info") or {}
check(info.rules and info.rules.nuzlocke == "hardcore" and info.rules.tradesPerGym == 1,
  "/server/info: hardcore, tradesPerGym = 1 (" .. tostring(info.rules and info.rules.tradesPerGym) .. ")")
item(startMenu(), "CONNECT").onSelect()
pick("^JOIN")
check(top() and top().items, "no online save yet -> create/redeem menu")
pick("CREATE NEW PLAYER")
check(top() and top().naming, "CREATE NEW PLAYER opens the Gen 1 naming screen")
top().finish("ASH")
pick("BLUE / RIVAL")
closeTexts()
check(said("PLAYER CREATED") ~= nil, "server registered the character: " .. table.concat(messages, " / "))
-- a new character's PLAYER CREATED box has no modes line (the returning
-- player's CONNECTED box does: section 7)
check(tostring(Modes.describe()):find("1 TRADE PER GYM LEADER", 1, true) ~= nil,
  "the modes name the limit: " .. tostring(Modes.describe()))
popTo(world)
local myId = tostring(game.save.player.id)
check(game.save.player.name == "ASH", "game now runs the online character")
check(Modes.rules and Modes.rules.tradesPerGym == 1, "the client plays tradesPerGym = 1")
game.save.flags = game.save.flags or {}
game.save.party = {
  { species = "PIKACHU", nickname = "PIKACHU", level = 7, hp = 24, maxHp = 24,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 9, defense = 8, speed = 7, special = 6 } },
  { species = "PIDGEY", nickname = "PIDGEY", level = 5, hp = 19, maxHp = 19,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 5, defense = 5, speed = 5, special = 5 } },
  { species = "RATTATA", nickname = "RATTATA", level = 4, hp = 17, maxHp = 17,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 4, defense = 4, speed = 4, special = 4 } },
  { species = "SPEAROW", nickname = "SPEAROW", level = 4, hp = 17, maxHp = 17,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 4, defense = 4, speed = 4, special = 4 } },
}
check(Modes.gymsBeaten(game.save) == 0, "no gym leader beaten yet")
check(Modes.tradesLeft(game.save) == 1 and not Modes.tradeRefusal(game.save), "1 trade left, none refused")
local ri = runInfo() or ""
check(ri:find("TRADES: 1 OF 1", 1, true) ~= nil, "RUN INFO: " .. ri)
dump("connect")

-- ---- 2. a GTS deposit is the trade ---------------------------------------------------------
openGts("DEPOSIT MON")
pick("FROM PARTY")
pick("RATTATA")
pick("ADD")
pick("J %- L")
pick("KADABRA")
pick("CONFIRM")
closeTexts()
check(said("RATTATA WAS DEPOSITED") ~= nil, "the deposit goes in: " .. table.concat(messages, " / "))
check(listingOf(myId, "RATTATA") ~= nil, "the server holds the RATTATA listing")
check(partySpecies() == "PIKACHU,PIDGEY,SPEAROW", "RATTATA left the party (" .. partySpecies() .. ")")
check(Modes.tradesLeft(game.save) == 0, "the deposit used the trade: 0 left (" .. tostring(Modes.tradesLeft(game.save)) .. ")")
messages = {}
notes()
check(said("YOUR GTS DEPOSIT USED A TRADE: 0 LEFT") ~= nil, "the note says so: " .. table.concat(messages, " / "))
ri = runInfo() or ""
check(ri:find("TRADES: 0 OF 1", 1, true) ~= nil, "RUN INFO: " .. ri)
dump("deposit")

-- ---- 3. with no trade left, every other way in is refused -----------------------------------
-- a buy
local abra = post({ action = "deposit", trainerId = "777777", trainerName = "BUDDY",
  offeredMon = mon("ABRA", 12), wanted = { "PIDGEY" } })
check(abra and abra.success, "BUDDY lists an ABRA for a PIDGEY (" .. tostring(abra and abra.error) .. ")")
openGts("BROWSE TRADES")
pick("ALL ACTIVE")
pick("ABRA")
game.input:press("a")
top():update(1 / 60)
pick("GIVE PIDGEY")
closeTexts()
check(said(REFUSED) ~= nil and tradeAnim == nil, "a buy is refused: " .. table.concat(messages, " / "))
check(partySpecies() == "PIKACHU,PIDGEY,SPEAROW", "the party is unchanged (" .. partySpecies() .. ")")
check(listingOf("777777", "ABRA") ~= nil, "the ABRA listing is still on the server")
-- a second GTS deposit
openGts("DEPOSIT MON")
pick("FROM PARTY")
pick("SPEAROW")
closeTexts()
check(said(REFUSED) ~= nil, "a second GTS deposit is refused: " .. table.concat(messages, " / "))
popTo(world)
check(partySpecies() == "PIKACHU,PIDGEY,SPEAROW" and listingOf(myId, "SPEAROW") == nil,
  "the SPEAROW stays in the party (" .. partySpecies() .. ")")
-- a Wonder Trade deposit
openGts("WONDER TRADE")
pick("DEPOSIT")
pick("SPEAROW")
closeTexts()
check(said(REFUSED) ~= nil, "a Wonder Trade deposit is refused: " .. table.concat(messages, " / "))
popTo(world)
local wt = post({ action = "wonder_trade_status", trainerId = myId }) or {}
check(partySpecies() == "PIKACHU,PIDGEY,SPEAROW" and wt.success and wt.mine == nil and wt.poolCount == 0,
  "nothing went into the pool (" .. tostring(wt.poolCount) .. ")")
-- a LINK TRADE offer to BUDDY on the map
waitUntil(function() buddySync(); return exports.netNpcs["777777"] ~= nil end, 10)
local buddy = exports.netNpcs["777777"]
check(buddy ~= nil, "BUDDY is on the map")
world.player.cellX, world.player.cellY, world.player.facing = 5, 6, "down"
if buddy then buddy.cellX, buddy.cellY = 5, 7 end
messages = {}
check(pcall(world.interact, world), "A press facing BUDDY")
check(top() and top().items and describe(top()):find("LINK TRADE"), "BUDDY's menu offers LINK TRADE: " .. describe(top()))
pick("LINK TRADE")
closeTexts()
check(said(REFUSED) ~= nil, "a LINK TRADE offer is refused: " .. table.concat(messages, " / "))
check((buddySync() or {}).challenge == nil, "BUDDY receives no offer")
popTo(world)
-- a TRADE challenge from BUDDY, accepted: turned down with a DECLINE
local sent = post({ action = "send_challenge", targetId = myId, fromId = "777777", fromName = "BUDDY",
  challengeType = "TRADE", roomId = "TRADE_test" })
check(sent and sent.success, "BUDDY offers a link trade")
local prompt = waitUntil(function()
  buddySync()
  local t = top()
  return t and t.items and describe(t):find("ACCEPT TRADE", 1, true) ~= nil
end, 10)
check(prompt, "the client is asked: " .. describe(top()))
messages = {}
if prompt then pick("ACCEPT TRADE") end
closeTexts()
check(said(REFUSED) ~= nil, "accepting is refused: " .. table.concat(messages, " / "))
local answer
waitUntil(function()
  answer = (buddySync() or {}).challenge
  return answer ~= nil
end, 5)
check(answer and answer.type == "DECLINE", "BUDDY gets a DECLINE (" .. tostring(answer and answer.type) .. ")")
post({ action = "clear_challenge", trainerId = "777777" })
popTo(world)
frames(20)
popTo(world)
check(Modes.tradesLeft(game.save) == 0 and partySpecies() == "PIKACHU,PIDGEY,SPEAROW", "still 0 trades left")
dump("refusals")

-- ---- 4. taking the deposit back gives the trade back ------------------------------------------
openGts("MY LISTINGS")
pick("TAKE RATTATA")
closeTexts()
check(said("WITHDREW RATTATA") ~= nil, "the RATTATA is taken back: " .. table.concat(messages, " / "))
check(partySpecies() == "PIKACHU,PIDGEY,SPEAROW,RATTATA" and listingOf(myId, "RATTATA") == nil,
  "back in the party, gone from the server (" .. partySpecies() .. ")")
check(Modes.tradesLeft(game.save) == 1, "the trade is given back: 1 left (" .. tostring(Modes.tradesLeft(game.save)) .. ")")
messages = {}
notes()
check(said("TRADE TAKEN BACK: 1 LEFT") ~= nil, "the note says so: " .. table.concat(messages, " / "))
dump("withdraw")

-- ---- 5. deposited again and bought: the claim is free ----------------------------------------
openGts("DEPOSIT MON")
pick("FROM PARTY")
pick("RATTATA")
pick("ADD")
pick("J %- L")
pick("KADABRA")
pick("CONFIRM")
closeTexts()
local myListing = listingOf(myId, "RATTATA")
check(said("RATTATA WAS DEPOSITED") ~= nil and myListing ~= nil, "deposited again: " .. table.concat(messages, " / "))
check(Modes.tradesLeft(game.save) == 0, "0 trades left again")
notes()
local bought = post({ action = "trade", listingId = myListing, buyerId = "777777", buyerName = "BUDDY",
  sentMon = mon("KADABRA", 20) })
check(bought and bought.success, "BUDDY buys the RATTATA with a KADABRA (" .. tostring(bought and bought.error) .. ")")
openGts("MY LISTINGS")
pick("GET KADABRA")
check(finishTradeAnim(), "the claim goes through with no trade left")
check(partySpecies() == "PIKACHU,PIDGEY,SPEAROW,KADABRA", "KADABRA joined the party (" .. partySpecies() .. ")")
check(#(((get("/gts/claims?trainerId=" .. myId) or {}).claims) or {}) == 0, "the claim box is empty")
check(Modes.tradesLeft(game.save) == 0, "the claim counts nothing: still 0 left")
messages = {}
notes()
check(said("USED A TRADE") == nil, "and no trade note: " .. table.concat(messages, " / "))
dump("claim")

-- ---- 6. Brock beaten: a GTS buy is the trade --------------------------------------------------
game.save.flags.EVENT_BEAT_BROCK = true
check(Modes.gymsBeaten(game.save) == 1, "Brock beaten")
check(Modes.tradesLeft(game.save) == 1 and not Modes.tradeRefusal(game.save), "1 trade left again")
ri = runInfo() or ""
check(ri:find("TRADES: 1 OF 1", 1, true) ~= nil, "RUN INFO: " .. ri)
openGts("BROWSE TRADES")
pick("ALL ACTIVE")
pick("ABRA")
game.input:press("a")
top():update(1 / 60)
pick("GIVE PIDGEY")
check(tradeAnim ~= nil and tradeAnim.opts.sent and tradeAnim.opts.sent.species == "PIDGEY", "PIDGEY is the one leaving")
check(finishTradeAnim() and said("GTS TRADE COMPLETE") ~= nil, "the GTS trade completes")
check(partySpecies() == "PIKACHU,SPEAROW,KADABRA,ABRA", "ABRA arrived, PIDGEY left (" .. partySpecies() .. ")")
check(Modes.tradesLeft(game.save) == 0, "the buy used the trade: 0 left")
messages = {}
notes()
check(said("THE GTS TRADE USED A TRADE: 0 LEFT") ~= nil, "the note says so: " .. table.concat(messages, " / "))
dump("buy")

-- ---- 7. Misty beaten: a Wonder Trade deposit is the trade, its withdraw gives it back ---------
game.save.flags.EVENT_BEAT_MISTY = true
check(Modes.gymsBeaten(game.save) == 2 and Modes.tradesLeft(game.save) == 1, "Misty beaten: 1 trade left")
openGts("WONDER TRADE")
pick("DEPOSIT")
pick("SPEAROW")
closeTexts()
check(said("SPEAROW DEPOSITED INTO WONDER TRADE") ~= nil, "SPEAROW goes into the pool: " .. table.concat(messages, " / "))
check(Modes.tradesLeft(game.save) == 0, "the Wonder Trade deposit used the trade")
messages = {}
notes()
check(said("YOUR WONDER TRADE USED A TRADE: 0 LEFT") ~= nil, "the note says so: " .. table.concat(messages, " / "))
openGts("WONDER TRADE")
pick("WITHDRAW")
closeTexts()
check(said("WITHDREW SPEAROW") ~= nil and hasSpecies("SPEAROW"),
  "the SPEAROW is withdrawn: " .. table.concat(messages, " / "))
check(Modes.tradesLeft(game.save) == 1, "the trade is given back: 1 left")
messages = {}
notes()
check(said("TRADE TAKEN BACK: 1 LEFT") ~= nil, "the note says so: " .. table.concat(messages, " / "))
openGts("WONDER TRADE")
pick("DEPOSIT")
pick("SPEAROW")
closeTexts()
check(said("SPEAROW DEPOSITED INTO WONDER TRADE") ~= nil and Modes.tradesLeft(game.save) == 0,
  "deposited again: 0 left")
notes()
local rawMon = { ["400001"] = "ZUBAT", ["400002"] = "EKANS", ["400003"] = "MEOWTH", ["400004"] = "BULBASAUR" }
for _, tid in ipairs({ "400001", "400002", "400003", "400004" }) do
  post({ action = "wonder_trade_deposit", trainerId = tid, trainerName = "T" .. tid:sub(-1), offeredMon = mon(rawMon[tid]) })
end
local myClaim = (post({ action = "wonder_trade_status", trainerId = myId }) or {}).claim
check(myClaim and myClaim.mon and tostring(myClaim.fromId) ~= myId, "matched: a claim from someone else")
openGts("WONDER TRADE")
pick("CLAIM ")
check(finishTradeAnim() and said("WONDER TRADE COMPLETE") ~= nil, "the Wonder Trade claim goes through with no trade left")
check(myClaim and hasSpecies(myClaim.mon.species),
  "the " .. tostring(myClaim and myClaim.mon.species) .. " joined the party (" .. partySpecies() .. ")")
check(Modes.tradesLeft(game.save) == 0, "the claim counts nothing: still 0 left")
messages = {}
notes()
check(said("USED A TRADE") == nil, "and no trade note: " .. table.concat(messages, " / "))
dump("wonder")

-- ---- 8. a deposit from an earlier stretch stays spent ------------------------------------------
game.save.flags.EVENT_BEAT_LT_SURGE = true
check(Modes.gymsBeaten(game.save) == 3 and Modes.tradesLeft(game.save) == 1, "Lt. Surge beaten: 1 trade left")
openGts("DEPOSIT MON")
pick("FROM PARTY")
pick("^ABRA")
pick("ADD")
pick("J %- L")
pick("KADABRA")
pick("CONFIRM")
closeTexts()
check(said("^ABRA WAS DEPOSITED") ~= nil and Modes.tradesLeft(game.save) == 0 and not hasSpecies("ABRA"),
  "ABRA deposited: 0 left (" .. partySpecies() .. ")")
notes()
game.save.flags.EVENT_BEAT_ERIKA = true
check(Modes.gymsBeaten(game.save) == 4 and Modes.tradesLeft(game.save) == 1, "Erika beaten: 1 trade left")
openGts("MY LISTINGS")
pick("TAKE ABRA")
closeTexts()
check(said("WITHDREW ABRA") ~= nil and hasSpecies("ABRA"),
  "the ABRA is taken back: " .. table.concat(messages, " / "))
check(Modes.tradesLeft(game.save) == 1, "the old stretch's trade stays spent: still 1 left, not 2")
messages = {}
notes()
check(said("TAKEN BACK") == nil, "and no note: " .. table.concat(messages, " / "))
dump("old stretch")

-- ---- 9. the counts survive DISCONNECT and JOIN --------------------------------------------------
-- use this stretch's trade first, so a 0 has to come back from the save
game.save.flags.EVENT_BEAT_KOGA = true
openGts("DEPOSIT MON")
pick("FROM PARTY")
pick("PIKACHU")
pick("ADD")
pick("J %- L")
pick("KADABRA")
pick("CONFIRM")
closeTexts()
check(Modes.gymsBeaten(game.save) == 5 and Modes.tradesLeft(game.save) == 0, "Koga beaten, PIKACHU deposited: 0 left")
popTo(world)
messages = {}
item(startMenu(), "ONLINE").onSelect()
pick("DISCONNECT")
closeTexts()
check(game.save.onlineAccount == nil, "offline save restored")
check(Modes.tradesLeft(game.save) == nil, "offline: no limit")
popTo(world)
frames(60)
messages = {}
item(startMenu(), "CONNECT").onSelect()
pick("^JOIN")
closeTexts()
popTo(world)
check(game.save.player.name == "ASH", "reconnect restores the online character")
check(said("1 TRADE PER GYM LEADER") ~= nil, "the CONNECTED text names the limit: " .. table.concat(messages, " / "))
check(Modes.gymsBeaten(game.save) == 5, "5 leaders still beaten (" .. Modes.gymsBeaten(game.save) .. ")")
check(Modes.tradesLeft(game.save) == 0, "and this stretch's trade still used (" .. tostring(Modes.tradesLeft(game.save)) .. ")")
-- the reservation was saved too: taking the PIKACHU back gives the trade back
openGts("MY LISTINGS")
pick("TAKE PIKACHU")
closeTexts()
check(said("WITHDREW PIKACHU") ~= nil and Modes.tradesLeft(game.save) == 1,
  "the PIKACHU taken back after JOIN gives the trade back (" .. tostring(Modes.tradesLeft(game.save)) .. ")")
popTo(world)
notes()
dump("reconnect")

-- ---- 10. no limit: nothing counts ---------------------------------------------------------------
local synced = Modes.synced
Modes.synced = function(g, res)
  if type(res) == "table" and type(res.run) == "table" then res.run.tradesPerGym = 0 end
  return synced(g, res)
end
Modes.rules.tradesPerGym = 0
check(Modes.tradesLeft(game.save) == nil and not Modes.tradeRefusal(game.save), "tradesPerGym = 0: no limit")
local free = post({ action = "deposit", trainerId = "777777", trainerName = "BUDDY",
  offeredMon = mon("ZUBAT", 8), wanted = { "ABRA" } })
check(free and free.success, "BUDDY lists a ZUBAT for an ABRA")
local before = partySpecies()
openGts("BROWSE TRADES")
pick("ALL ACTIVE")
pick("ZUBAT")
game.input:press("a")
top():update(1 / 60)
pick("GIVE ABRA")
check(finishTradeAnim() and said("GTS TRADE COMPLETE") ~= nil, "the buy goes through")
check(not hasSpecies("ABRA") and hasSpecies("ZUBAT"), "ABRA left, ZUBAT arrived (" .. before .. " -> " .. partySpecies() .. ")")
messages = {}
notes()
check(said("USED A TRADE") == nil, "no trade note: " .. table.concat(messages, " / "))
ri = runInfo() or ""
check(ri ~= "" and ri:find("TRADES:", 1, true) == nil, "RUN INFO has no TRADES line: " .. ri)
check(Modes.rules and Modes.rules.tradesPerGym == 0, "the next syncs keep the pin")
Modes.synced = synced
local st = Modes.state(game.save)
check(#(st.graveyard or {}) == 0 and not st.wiped, "nobody was buried along the way")
dump("unlimited")

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
