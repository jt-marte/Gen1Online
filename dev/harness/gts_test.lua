-- GTS against the local server (dev/server.sh, fresh database), with the
-- races the client used to lose: every buy, withdraw, claim and deposit now
-- waits for the server, and a refused one leaves the player's Pokémon where
-- it was.  Other trainers are played over raw HTTP.
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

-- the game, with just enough species data for packMon2/unpackMon2 and the
-- wanted-species picker
local game = Rig.newGame()
local world = game.world
for _, id in ipairs({ "SPRITE_CHRIS", "SPRITE_KRIS", "SPRITE_RED" }) do
  game.data.gen2Sprites[id] = { id = id, image = "assets/none.png", frames = 6,
    frameWidth = 16, frameHeight = 16 }
end
world.sprites = game.data.gen2Sprites
for dex, sp in ipairs({ "CYNDAQUIL", "SENTRET", "PIDGEY", "HOOTHOOT", "ABRA", "KADABRA", "ZUBAT" }) do
  game.data.pokemon[sp] = { name = sp, dex = dex, types = { "NORMAL" },
    baseStats = { hp = 45, attack = 45, defense = 45, speed = 45,
      specialAttack = 45, specialDefense = 45 } }
end
game.data.moves = { TACKLE = { pp = 35 } }

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
local function item(list, label)
  for _, it in ipairs(list) do if it.label == label then return it end end
end
local function partySpecies()
  local out = {}
  for _, m in ipairs(game.save.party or {}) do out[#out + 1] = m.species end
  return table.concat(out, ",")
end
local function openGts(entry)
  popTo(world)
  messages = {}
  local pcItems = Rig.hook("ui.pc.items", function(g, l) return l end, game, {})
  item(pcItems, "GTS").onSelect()
  pick(entry)
  return describe(top())
end
local function finishTradeAnim()
  if not tradeAnim then return false end
  local anim = tradeAnim
  tradeAnim = nil
  popTo(anim)
  anim.opts.onDone()
  closeTexts()
  return true
end
local function mon(species, level)
  return { species = species, level = level or 5, nickname = species,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 8, defense = 8, speed = 8, special = 8 } }
end
local function partyMon(species, level)
  return { species = species, nickname = species, level = level, hp = 20, maxHp = 20,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 9, defense = 8, speed = 7, special = 6 } }
end
-- the client's deposit flow: FROM PARTY, the mon, then KADABRA as wanted
local function depositFromParty(species, beforeConfirm)
  openGts("DEPOSIT MON")
  pick("FROM PARTY")
  pick(species)
  pick("ADD")
  pick("J %- L")
  pick("KADABRA")
  if beforeConfirm then beforeConfirm() end
  pick("CONFIRM")
  closeTexts()
end
local function myListings(id)
  local out = {}
  for lid, l in pairs((get("/gts/browse") or {}).listings or {}) do
    if tostring(l.trainerId) == id then out[#out + 1] = lid end
  end
  return out
end

-- ---- 1. connect -------------------------------------------------------------
item(Rig.hook("ui.start_menu.items", function(g, l) return l end, game, {}), "CONNECT").onSelect()
pick("^JOIN")
pick("CREATE NEW PLAYER")
top().onDone("SILVER")
pick("CRYSTAL")
closeTexts()
check(said("PLAYER CREATED") ~= nil, "server registered the character")
popTo(world)
local myId = tostring(game.save.player.id)
game.save.party = { partyMon("CYNDAQUIL", 7), partyMon("PIDGEY", 8), partyMon("SENTRET", 4) }

-- ---- 2. deposit ----------------------------------------------------------------
depositFromParty("SENTRET")
check(said("SENTRET WAS DEPOSITED") ~= nil, "deposit confirmed: " .. table.concat(messages, " / "))
check(partySpecies() == "CYNDAQUIL,PIDGEY", "SENTRET left the party")
local mine = myListings(myId)
check(#mine == 1, "the server holds the listing")
local sentretListing = mine[1]

-- ---- 3. withdraw loses to a buyer: the mon must not come back --------------------
local menu = openGts("MY LISTINGS")
check(menu:find("TAKE SENTRET") ~= nil, "MY LISTINGS offers the SENTRET: " .. menu)
local bought = post({ action = "trade", listingId = sentretListing, buyerId = "400001",
  buyerName = "BUYER", sentMon = mon("KADABRA", 20) })
check(bought and bought.success and bought.receivedMon.species == "SENTRET", "a buyer takes the SENTRET first")
pick("TAKE SENTRET")
closeTexts()
check(said("COULD NOT WITHDRAW") ~= nil, "withdraw refused: " .. table.concat(messages, " / "))
check(partySpecies() == "CYNDAQUIL,PIDGEY", "no SENTRET came back (the buyer has it)")

-- ---- 4. claim what the buyer sent ------------------------------------------------
menu = openGts("MY LISTINGS")
check(menu:find("GET KADABRA") ~= nil and not menu:find("TAKE"), "the claim box shows the KADABRA: " .. menu)
pick("GET KADABRA")
check(finishTradeAnim(), "the claim plays the trade")
check(partySpecies() == "CYNDAQUIL,PIDGEY,KADABRA", "KADABRA claimed into the party")
check(#((get("/gts/claims?trainerId=" .. myId) or {}).claims or { 1 }) == 0, "the server's claim box is empty")

-- ---- 5. a claim someone else already took (another device) -----------------------
post({ action = "deposit", trainerId = myId, trainerName = "SILVER", offeredMon = mon("ZUBAT"), wanted = {} })
local zubat = myListings(myId)[1]
post({ action = "trade", listingId = zubat, buyerId = "400002", buyerName = "B2", sentMon = mon("ABRA", 9) })
menu = openGts("MY LISTINGS")
check(menu:find("GET ABRA") ~= nil, "a second claim is listed")
check(post({ action = "claim", trainerId = myId, index = 0 }).success, "another device claims it first")
pick("GET ABRA")
closeTexts()
check(said("COULD NOT CLAIM") ~= nil and tradeAnim == nil, "the stale claim is refused, no trade plays")
check(partySpecies() == "CYNDAQUIL,PIDGEY,KADABRA", "nothing was added")

-- ---- 6. withdraw that the server allows ------------------------------------------
post({ action = "deposit", trainerId = myId, trainerName = "SILVER", offeredMon = mon("HOOTHOOT", 6), wanted = {} })
openGts("MY LISTINGS")
pick("TAKE HOOTHOO")   -- labels cut names to 7 letters
closeTexts()
check(said("WITHDREW HOOTHOO") ~= nil, "withdraw confirmed: " .. table.concat(messages, " / "))
check(partySpecies() == "CYNDAQUIL,PIDGEY,KADABRA,HOOTHOOT", "HOOTHOOT is back")
check(#myListings(myId) == 0, "the server dropped the listing")

-- ---- 7. the 10-listing cap: counted from the server, and a refused deposit ---------
for i = 1, 9 do
  post({ action = "deposit", trainerId = myId, trainerName = "SILVER", offeredMon = mon("ZUBAT", i), wanted = {} })
end
depositFromParty("HOOTHOOT", function()
  -- the 10th listing lands from elsewhere while the wanted list is being picked
  post({ action = "deposit", trainerId = myId, trainerName = "SILVER", offeredMon = mon("ZUBAT", 10), wanted = {} })
end)
check(said("MAXIMUM OF 10") ~= nil, "LISTING_LIMIT is shown: " .. table.concat(messages, " / "))
check(partySpecies() == "CYNDAQUIL,PIDGEY,KADABRA,HOOTHOOT", "the refused HOOTHOOT stayed in the party")
openGts("DEPOSIT MON")
closeTexts()
check(said("MAXIMUM OF 10") ~= nil, "the next deposit is stopped up front (count read from the server): "
  .. table.concat(messages, " / ") .. " " .. describe(top()) .. " listings=" .. #myListings(myId))
for _, lid in ipairs(myListings(myId)) do post({ action = "withdraw", listingId = lid, trainerId = myId }) end
check(#myListings(myId) == 0, "the raw listings are withdrawn")

-- ---- 8. buying a listing that just went away ---------------------------------------
local function sellerDeposit()
  local res = post({ action = "deposit", trainerId = "500001", trainerName = "SELLER",
    offeredMon = mon("ABRA", 12), wanted = { "PIDGEY" } })
  return res and res.listing and res.listing.id
end
local abra = sellerDeposit()
openGts("BROWSE TRADES")
pick("ALL ACTIVE")
pick("ABRA")
game.input:press("a")
top():update(1 / 60)
check(describe(top()):find("GIVE PIDGEY") ~= nil, "the card offers GIVE PIDGEY: " .. describe(top()))
check(post({ action = "withdraw", listingId = abra, trainerId = "500001" }).success, "the seller withdraws first")
pick("GIVE PIDGEY")
closeTexts()
check(said("LISTING IS GONE") ~= nil and tradeAnim == nil, "buy refused: " .. table.concat(messages, " / "))
check(partySpecies() == "CYNDAQUIL,KADABRA,HOOTHOOT,PIDGEY", "PIDGEY stayed with the player")
check(#((get("/gts/claims?trainerId=500001") or {}).claims or { 1 }) == 0, "the seller got nothing")

-- ---- 9. buying for real ---------------------------------------------------------------
abra = sellerDeposit()
openGts("BROWSE TRADES")
pick("ALL ACTIVE")
pick("ABRA")
game.input:press("a")
top():update(1 / 60)
pick("GIVE PIDGEY")
local given = tradeAnim and tradeAnim.opts.given and tradeAnim.opts.given.species
local received = tradeAnim and tradeAnim.opts.received and tradeAnim.opts.received.species
check(given == "PIDGEY" and received == "ABRA", "trade shows PIDGEY leaving, ABRA arriving")
-- the server has handed the ABRA over: it is saved before the animation ends
do
  local SaveSerializer = require("src.core.SaveSerializer")
  local onlinePath
  for path in pairs(Rig.writes) do
    if path:match("save_online_crystal%.lua$") then onlinePath = path end
  end
  local midTrade = SaveSerializer.decode(onlinePath and Rig.writes[onlinePath] or "") or {}
  local savedAbra = false
  for _, m in ipairs(midTrade.party or {}) do if m.species == "ABRA" then savedAbra = true end end
  check(savedAbra, "the ABRA is in the online save while the trade animation still plays")
end
check(finishTradeAnim(), "the trade plays")
check(said("GTS TRADE COMPLETE") ~= nil, "trade completes")
check(partySpecies() == "CYNDAQUIL,KADABRA,HOOTHOOT,ABRA", "ABRA arrived, PIDGEY left")
local sellerClaims = (get("/gts/claims?trainerId=500001") or {}).claims or {}
check(#sellerClaims == 1 and sellerClaims[1].mon.species == "PIDGEY"
  and tostring(sellerClaims[1].fromId) == myId, "the seller's claim box has the PIDGEY")
check(next((get("/gts/browse") or {}).listings or { x = 1 }) == nil, "the listing is gone")

-- XP: every award above landed on the server too
local profile = get("/gts/profile?trainerId=" .. myId)
local clientXp = tonumber(game.save.onlineAccount and game.save.onlineAccount.xp) or -1
check(clientXp > 0 and profile and profile.profile and profile.profile.xp == clientXp,
  "server XP matches the client's (" .. clientXp .. ")")
check(profile and profile.profile and profile.profile.gtsTrades == 3, "three GTS trades counted (two sold, one bought)")

popTo(world)
Rig.dump("gts")
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
