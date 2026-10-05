-- Wonder Trade against the local server (dev/server.sh, fresh database): the
-- real client deposits, reads the pool, withdraws, loses a deposit race (the
-- mon must come back), deposits again and is matched with trainers played
-- over raw HTTP.  Nobody gets their own Pokémon, CLAIM_PENDING holds while a
-- claim waits, and the client claims with its own Pokémon seen leaving.
local Rig = dofile(os.getenv("G1O_DEV") .. "/harness/rig.lua")
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
  payload.modVersion = payload.modVersion or "0.5.1"
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
  http.request({ url = BASE .. path .. (path:find("?", 1, true) and "&" or "?") .. "version=0.5.1",
    sink = ltn12.sink.table(out) })
  local ok, res = pcall(Json.decode, table.concat(out))
  return ok and res or nil
end

-- the game, with just enough species data for packMon2/unpackMon2
local game = Rig.newGame()
local world = game.world
for _, id in ipairs({ "SPRITE_CHRIS", "SPRITE_KRIS", "SPRITE_RED" }) do
  game.data.gen2Sprites[id] = { id = id, image = "assets/none.png", frames = 6,
    frameWidth = 16, frameHeight = 16 }
end
world.sprites = game.data.gen2Sprites
local SPECIES = { "CYNDAQUIL", "SENTRET", "HOOTHOOT", "PIDGEY", "RATTATA", "SPEAROW",
  "ZUBAT", "LEDYBA" }
for dex, sp in ipairs(SPECIES) do
  game.data.pokemon[sp] = { name = sp, dex = dex, types = { "NORMAL" },
    baseStats = { hp = 45, attack = 45, defense = 45, speed = 45,
      specialAttack = 45, specialDefense = 45 } }
end
game.data.moves = { TACKLE = { pp = 35 } }

-- Screens the rig cannot draw: the naming screen and the trade animation
-- stand in as plain states that keep their callbacks
local Screens = require("src.ui.Screens")
local realPush = Screens.push
local tradeAnim
Screens.push = function(g, id, opts, ...)
  if id == "Gen2NamingScreen" then
    local stub = { naming = true, opts = opts, onDone = opts.onDone }
    g.stack:push(stub)
    return stub
  end
  if id == "Gen2TradeAnim" then
    tradeAnim = { tradeAnim = true, opts = opts }
    g.stack:push(tradeAnim)
    return tradeAnim
  end
  return realPush(g, id, opts, ...)
end

local ok, err = Rig.load(game)
check(ok, "loader:load completes (" .. tostring(err) .. ")")

-- ---- UI driver (as online_test.lua) ---------------------------------------
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
  if s == world then return "World" end
  if s.naming then return "Naming" end
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
local function lastSaid() return messages[#messages] or "" end
local function said(pattern)
  for _, m in ipairs(messages) do if m:find(pattern) then return m end end
  return nil
end
local function popTo(state) while top() and top() ~= state do game.stack:pop() end end
local function startMenu(list)
  return Rig.hook("ui.start_menu.items", function(g, l) return l end, game, list or {})
end
local function item(list, label)
  for _, it in ipairs(list) do if it.label == label then return it end end
end
local function partySpecies()
  local out = {}
  for _, m in ipairs(game.save.party or {}) do out[#out + 1] = m.species end
  return table.concat(out, ",")
end
-- the GTS from a PC, then its WONDER TRADE menu
local function openWonder()
  popTo(world)
  local pcItems = Rig.hook("ui.pc.items", function(g, l) return l end, game, {})
  item(pcItems, "GTS").onSelect()
  pick("WONDER TRADE")
  return describe(top())
end
local function mon(species, level)
  return { species = species, level = level or 5, nickname = species,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 8, defense = 8, speed = 8, special = 8 } }
end

-- ---- 1. connect with a fresh character ------------------------------------
item(startMenu(), "CONNECT").onSelect()
pick("^JOIN")
pick("CREATE NEW PLAYER")
top().onDone("WENDY")
pick("CRYSTAL")
closeTexts()
check(lastSaid():find("PLAYER CREATED") ~= nil, "server registered the character")
popTo(world)
local myId = tostring(game.save.player.id)
check(myId:match("^%d%d%d%d%d%d$") ~= nil, "a 6-digit trainer id (" .. myId .. ")")
game.save.party = {
  { species = "CYNDAQUIL", nickname = "CYNDAQUIL", level = 7, hp = 24, maxHp = 24,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 9, defense = 8, speed = 7, special = 6 } },
  { species = "SENTRET", nickname = "SENTRET", level = 4, hp = 17, maxHp = 17,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 5, defense = 5, speed = 5, special = 5 } },
}

-- ---- 2. deposit from the client --------------------------------------------
local menu = openWonder()
check(menu:find("DEPOSIT %(0/5 POOL%)") ~= nil, "empty pool offers DEPOSIT (0/5): " .. menu)
pick("DEPOSIT")
pick("SENTRET")
closeTexts()
check(lastSaid():find("SENTRET DEPOSITED INTO WONDER TRADE") and lastSaid():find("1/5"),
  "deposit confirmed with the pool count: " .. lastSaid())
check(partySpecies() == "CYNDAQUIL", "the deposited mon left the party")
local status = post({ action = "wonder_trade_status", trainerId = myId })
check(status and status.poolCount == 1 and status.mine and status.mine.offeredMon.species == "SENTRET",
  "server holds the client's SENTRET in its pool")

-- ---- 3. three raw trainers join; the client sees the server's count ---------------
local raw = { "300001", "300002", "300003", "300004", "300005" }
local rawMon = { ["300001"] = "PIDGEY", ["300002"] = "RATTATA", ["300003"] = "SPEAROW",
  ["300004"] = "ZUBAT", ["300005"] = "LEDYBA" }
local function rawDeposit(tid)
  return post({ action = "wonder_trade_deposit", trainerId = tid, trainerName = "T" .. tid:sub(-1),
    offeredMon = mon(rawMon[tid]) })
end
for i = 1, 3 do
  local res = rawDeposit(raw[i])
  check(res and res.success and res.poolCount == i + 1 and res.matched == false,
    "raw trainer " .. raw[i] .. " deposits (pool " .. (i + 1) .. ")")
end
menu = openWonder()
check(menu:find("STATUS: %(4/5 POOL%)") and menu:find("WITHDRAW FROM POOL") and not menu:find("DEPOSIT"),
  "in the pool: STATUS (4/5) and WITHDRAW, no DEPOSIT: " .. menu)
pick("STATUS")
closeTexts()
check(lastSaid():find("4/5") and lastSaid():find("SENTRET"), "status names the offer and the count")

-- ---- 4. withdraw -------------------------------------------------------------------
openWonder()
pick("WITHDRAW FROM POOL")
closeTexts()
check(lastSaid():find("WITHDREW SENTRET"), "withdraw confirmed: " .. lastSaid())
check(partySpecies() == "CYNDAQUIL,SENTRET", "SENTRET is back in the party")
status = post({ action = "wonder_trade_status", trainerId = myId })
check(status and status.poolCount == 3 and status.mine == nil, "server pool is back to 3")

-- ---- 5. a deposit the server refuses gives the mon back ---------------------------
menu = openWonder()
check(menu:find("DEPOSIT %(3/5 POOL%)") ~= nil, "DEPOSIT (3/5): " .. menu)
pick("DEPOSIT")
-- another device of this trainer gets there first
local other = post({ action = "wonder_trade_deposit", trainerId = myId, trainerName = "WENDY",
  offeredMon = mon("HOOTHOOT") })
check(other and other.success, "a second device deposits for the same trainer")
pick("SENTRET")
closeTexts()
check(lastSaid():find("ALREADY HAVE A POKéMON"), "ALREADY_IN_POOL is shown: " .. lastSaid())
check(partySpecies() == "CYNDAQUIL,SENTRET", "the refused SENTRET stayed in the party")
check(post({ action = "wonder_trade_withdraw", trainerId = myId }).success, "the other device withdraws")

-- ---- 6. deposit again; the fifth raw deposit matches everyone ------------------------
openWonder()
pick("DEPOSIT")
pick("SENTRET")
closeTexts()
check(lastSaid():find("4/5"), "re-deposit: pool 4/5: " .. lastSaid())
local res = rawDeposit(raw[4])
check(res and res.success and res.matched == true and res.poolCount == 0, "the 5th deposit matches the pool")

local everyone = { myId, raw[1], raw[2], raw[3], raw[4] }
local offeredBy = { [myId] = "SENTRET" }
for i = 1, 4 do offeredBy[raw[i]] = rawMon[raw[i]] end
local givers, own = {}, false
for _, tid in ipairs(everyone) do
  local st = post({ action = "wonder_trade_status", trainerId = tid })
  local claim = st and st.claim
  if check(claim ~= nil and claim.mon ~= nil, tid .. " has a claim") then
    if tostring(claim.fromId) == tid then own = true end
    givers[#givers + 1] = tostring(claim.fromId)
    check(claim.mon.species == offeredBy[tostring(claim.fromId)], tid .. " gets the giver's own mon")
    check(claim.sentMon and claim.sentMon.species == offeredBy[tid], tid .. "'s claim records what it sent")
  end
end
check(not own, "nobody gets their own Pokémon")
table.sort(givers)
local expected = { myId, raw[1], raw[2], raw[3], raw[4] }
table.sort(expected)
check(table.concat(givers, ",") == table.concat(expected, ","), "every mon went to exactly one trainer")

-- ---- 7. CLAIM_PENDING, NOT_IN_POOL --------------------------------------------------
res = rawDeposit(raw[5])
check(res and res.success and res.poolCount == 1 and res.matched == false, "a new pool starts at 1")
res = post({ action = "wonder_trade_deposit", trainerId = raw[1], trainerName = "T1", offeredMon = mon("PIDGEY") })
check(res and res.error == "CLAIM_PENDING", "a trainer with an unclaimed match cannot deposit (CLAIM_PENDING)")
res = post({ action = "wonder_trade_withdraw", trainerId = raw[2] })
check(res and res.error == "NOT_IN_POOL", "a matched trainer cannot withdraw (NOT_IN_POOL)")
menu = openWonder()
check(menu:find("CLAIM ") and not menu:find("DEPOSIT") and menu:find("%(1/5") == nil,
  "the client is offered its claim and no deposit: " .. menu)

-- ---- 8. the client claims ------------------------------------------------------------
local myClaim = post({ action = "wonder_trade_status", trainerId = myId }).claim
local xpBefore = tonumber(game.save.onlineAccount and game.save.onlineAccount.xp) or 0
tradeAnim = nil
messages = {}
pick("CLAIM ")
check(tradeAnim ~= nil, "the trade animation runs")
if tradeAnim then
  check(tradeAnim.opts.given and tradeAnim.opts.given.species == "SENTRET",
    "the client's own SENTRET is the one leaving")
  check(tradeAnim.opts.received and tradeAnim.opts.received.species == myClaim.mon.species,
    "the claimed " .. tostring(myClaim.mon.species) .. " arrives")
  popTo(tradeAnim)
  tradeAnim.opts.onDone()
end
closeTexts()
check(said("WONDER TRADE COMPLETE") ~= nil, "claim completes: " .. table.concat(messages, " / "))
check(partySpecies() == "CYNDAQUIL," .. myClaim.mon.species, "the received mon joined the party")
status = post({ action = "wonder_trade_status", trainerId = myId })
check(status and status.claim == nil, "the server's claim is gone")
res = post({ action = "wonder_trade_claim", trainerId = myId })
check(res and res.error == "NO_CLAIM", "a second claim answers NO_CLAIM")

-- XP: the claim's awards (the trade's own gts_trade 100, then wonder_trade
-- 75) leave the client and the server on the same total
local profile = get("/gts/profile?trainerId=" .. myId)
local clientXp = tonumber(game.save.onlineAccount and game.save.onlineAccount.xp) or -1
check(clientXp == xpBefore + 175, "client awarded the claim's XP (" .. xpBefore .. " -> " .. clientXp .. ")")
check(profile and profile.profile and profile.profile.xp == clientXp,
  "server XP matches the client's (" .. tostring(profile and profile.profile and profile.profile.xp) .. ")")

-- ---- 9. a raw claim, then that trainer may deposit again; the leftover withdraws ---
res = post({ action = "wonder_trade_claim", trainerId = raw[1] })
check(res and res.success and res.claim and res.claim.mon, "raw trainer claims")
res = rawDeposit(raw[1])
check(res and res.success and res.poolCount == 2, "after claiming, a trainer deposits again")
res = post({ action = "wonder_trade_withdraw", trainerId = raw[5] })
check(res and res.success and res.mon and res.mon.species == "LEDYBA", "withdraw hands back the exact mon")

popTo(world)
Rig.dump("wonder trade")
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
