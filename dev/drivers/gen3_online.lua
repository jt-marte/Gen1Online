-- Real FireRed / LeafGreen boot (POKEPORT_VERSION=firered|leafgreen) on a
-- Gen 3 test server: the whole online flow through the real START menu and
-- the mod's FireRed screens.
--
--   offline game -> CONNECT > JOIN -> a new online character (FireRed's
--   naming screen, a LEAF avatar: a girl's game) -> BUDDY (raw HTTP) on the
--   same map, drawn as a field actor with his name tag -> presence carries
--   the riding state -> GTS: deposit, BUDDY buys it, the claim comes back;
--   BUDDY's KADABRA bought, the trade scene and the trade evolution ->
--   Wonder Trade -> chat -> DISCONNECT restores the offline game -> CONNECT
--   again restores the online one.
--
-- Screenshots in $SHOTS.  dev/run_tests.sh runs it for both games when their
-- caches are there (G1O_FIRERED_ROM / G1O_LEAFGREEN_ROM to dev/setup.sh).
local U = require("tests.drivers.util")
local Protocol = require("src.link.Protocol")

return function(game)
  local H = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_util.lua")(game, "gen3_online")
  local say, check, finish, shot = H.say, H.check, H.finish, H.shot
  local post, get = H.post, H.get
  if not H.boot() then return finish() end
  local GtsUI, G3, online, Stack = H.GtsUI, H.G3, H.online, H.Stack
  local top, isText, isMenu, textOf, said = H.top, H.isText, H.isMenu, H.textOf, H.said
  local clearTexts, labels, choose, closeAll = H.clearTexts, H.labels, H.choose, H.closeAll
  local fieldFree, startItem, naming = H.fieldFree, H.startItem, H.naming

  local Runtime = require("src.core.game3.runtime")
  local Player = require("src.core.game3.player")
  local Map = require("src.core.game3.map")
  local Party = require("src.core.game3.party")
  local TradeScene = require("src.core.game3.trade_scene")
  local EvolutionScene = require("src.ui.game3.evolution_scene")

  -- ---------------------------------------------------------- offline game
  game:_handleBootAction({ action = "new_game", name = "OFFLINE" })
  U.wait(240)
  local s = Runtime.getSession()
  if not check(s and s.map == "FR_PLAYERS_HOUSE_2F", "a new offline game in the bedroom") then return finish() end
  Party.giveMon(s, 1, 8)     -- BULBASAUR
  Party.giveMon(s, 16, 6)    -- PIDGEY
  check(fieldFree(), "the field is free")
  check(game:saveGame() ~= false, "the offline game saved")
  local offlineTid = s.trainerId

  -- ------------------------------------------------- connect, new player
  startItem("gen1online")
  check(isMenu(top()), "CONNECT opens the mod's menu: " .. labels(top()))
  shot("connect_menu")
  choose("^JOIN")
  choose("CREATE NEW PLAYER")
  if not naming("ASH") then return finish() end
  check(isMenu(top()), "the avatar list: " .. labels(top()))
  shot("avatars")
  choose("^LEAF$")
  for _ = 1, 300 do
    if online() and Runtime.isActive() and isText(top()) then break end
    U.wait(2)
  end
  check(online(), "connected as a new online character")
  s = Runtime.getSession()
  check(s and s.name == "ASH" and s.gender == 1, "the online game is a girl named ASH ("
    .. tostring(s and s.name) .. ", gender " .. tostring(s and s.gender) .. ")")
  check(s and s.map == "FR_PLAYERS_HOUSE_2F" and #(s.party or {}) == 0,
    "a fresh game: the bedroom, no Pokémon (" .. tostring(s and s.map) .. ")")
  check(s.trainerId ~= nil and s.modData["gen1online-plus"].onlineAccount ~= nil,
    "the account rides in the save")
  shot("created")
  clearTexts()
  check(isMenu(top()) and labels(top()):find("GLOBAL CHAT", 1, true), "then the ONLINE menu: " .. labels(top()))
  shot("online_menu")
  closeAll()
  check(fieldFree(), "back in the field")
  local acc = s.modData["gen1online-plus"].onlineAccount
  local myTid = tostring(acc.trainerId)

  -- ---------------------------------------------- BUDDY on the same map
  local buddy = post({ action = "register_player", isNewCharacter = true, name = "BUDDY",
    spriteId = "OBJ_EVENT_GFX_BROCK", title = "ACE TRAINER", badges = 0, pokedexCount = 0 })
  check(buddy and buddy.success, "BUDDY registered over HTTP")
  local bTid = buddy.account.trainerId
  local mapId = require("src.mods.Gen3Compat").gen1MapId(Map.current)
  local function buddySync(x, y, extra)
    local p = { action = "sync_pos", trainerId = bTid, sessionId = "buddy", name = "BUDDY",
      spriteId = "OBJ_EVENT_GFX_BROCK", title = "ACE TRAINER", level = 3, map = mapId,
      x = x, y = y, px = x * 16, py = y * 16, facing = "down", moving = false }
    for k, v in pairs(extra or {}) do p[k] = v end
    return post(p)
  end
  local px, py = Player.cellX, Player.cellY
  local res = buddySync(px + 1, py)
  check(res and res.success, "BUDDY synced next to the player")
  local netNpcs = GtsUI.G3env.netNpcs
  for _ = 1, 300 do
    buddySync(px + 1, py)
    if netNpcs()[tostring(bTid)] then break end
    U.wait(10)
  end
  local bNpc = netNpcs()[tostring(bTid)]
  check(bNpc ~= nil, "BUDDY arrived in the client")
  U.wait(30)
  -- he is in the field's actor list, as an NPC with his sprite, and tagged
  local FieldView = require("src.core.game3.field_view")
  local actors = {}
  require("src.core.game3.field_effects").collectActors(actors)
  local sprite, tags = nil, {}
  for _, a in ipairs(actors) do
    if a.kind == "npc" and a.graphicsId then sprite = a end
    if a.kind == "g1o_tag" then tags[#tags + 1] = a.name end
  end
  local GFX = require("src.core.game3.constants.firered.event_objects").byName
  check(sprite and sprite.graphicsId == GFX.OBJ_EVENT_GFX_BROCK and sprite.x == (px + 1) * 16,
    "BUDDY is a field actor in BROCK's sprite, one cell east")
  table.sort(tags)
  check(table.concat(tags, ",") == "ASH,BUDDY", "name tags: " .. table.concat(tags, ","))
  shot("buddy")

  -- this player's presence carries the avatar's state and gender
  for _ = 1, 60 do
    local r = buddySync(px + 1, py)
    local mine
    for _, p in ipairs((r and r.players) or {}) do if tostring(p.trainerId) == myTid then mine = p end end
    if mine and mine.gender ~= nil then
      check(mine.state == "NORMAL" and mine.gender == 1 and mine.spriteId == "OBJ_EVENT_GFX_GREEN_NORMAL",
        "our presence: state " .. tostring(mine.state) .. ", gender " .. tostring(mine.gender)
          .. ", sprite " .. tostring(mine.spriteId))
      break
    end
    U.wait(10)
  end

  -- A on BUDDY opens his menu (the field's A press goes to the mod first)
  check(require("src.mods.Gen3Compat").interactWrapper() ~= nil, "the mod owns the field's A press")
  Player.facing = "right"
  U.wait(5)
  U.tap(game, "a"); U.wait(10)
  check(isMenu(top()) and labels(top()):find("PVP 1V1", 1, true), "A on BUDDY: " .. labels(top()))
  shot("buddy_menu")
  closeAll()

  -- BUDDY on a bike shows FireRed's bike sheet
  buddySync(px + 1, py, { state = "BIKE", gender = 0 })
  U.wait(40)
  actors = {}
  require("src.core.game3.field_effects").collectActors(actors)
  local biking
  for _, a in ipairs(actors) do if a.kind == "npc" and a.graphicsId then biking = a.graphicsId end end
  check(biking == GFX.OBJ_EVENT_GFX_RED_BIKE, "BUDDY on a bike: the bike sheet")
  buddySync(px + 1, py)

  -- a scratch trainer's mon, the way BUDDY's game would pack it
  local function mon(species, level, nick)
    local scratch = { party = {}, name = "BUDDY", trainerId = 4321, secretId = 99 }
    Party.giveMon(scratch, species, level, nick)
    return Protocol.packMon3(scratch.party[1])
  end
  local function partySpecies()
    local l = {}
    for _, m in ipairs(Runtime.getSession().party or {}) do l[#l + 1] = tonumber(m.species) end
    return l
  end
  local function hasSpecies(sp)
    for _, x in ipairs(partySpecies()) do if x == sp then return true end end
    return false
  end
  local function waitScenes(label)
    local sawTrade, sawEvo = false, false
    for _ = 1, 4000 do
      local trading = TradeScene.isOpen and TradeScene.isOpen()
      local evolving = EvolutionScene.isOpen and EvolutionScene.isOpen()
      if trading and not sawTrade then sawTrade = true; U.wait(200); shot(label .. "_trade") end
      if evolving and not sawEvo then sawEvo = true; U.wait(120); shot(label .. "_evolution") end
      if not trading and not evolving and isText(top()) then break end
      U.tap(game, "a"); U.wait(3)
    end
    return sawTrade, sawEvo
  end

  -- ------------------------------------------------------------------ GTS
  s = Runtime.getSession()
  Party.giveMon(s, 1, 10)      -- BULBASAUR
  Party.giveMon(s, 19, 7)      -- RATTATA
  Party.giveMon(s, 129, 5)     -- MAGIKARP
  -- the Pokémon Center PC has GTS above LOG OFF
  local PcMenu = require("src.ui.game3.pc_menu")
  PcMenu.show({ session = s })
  U.wait(10)
  local rows = {}
  for i, r in ipairs(PcMenu._rootEntries()) do rows[#rows + 1] = r.id; if r.id == "gts" then PcMenu.cursor = i end end
  check(table.concat(rows, ","):find("gts,quit", 1, true) ~= nil, "the PC lists GTS: " .. table.concat(rows, ","))
  shot("pc_gts")
  U.tap(game, "a"); U.wait(30)
  check(isMenu(top()) and labels(top()):find("BROWSE TRADES", 1, true), "GTS opened from the PC: " .. labels(top()))
  shot("gts_menu")
  choose("DEPOSIT MON")
  choose("FROM PARTY")
  choose("^RATTATA")
  choose("ADD")
  choose("^P %- R$")
  choose("^PIKACHU$")
  shot("wanted")
  choose("CONFIRM")
  clearTexts()
  check(said("WAS DEPOSITED"), "RATTATA deposited")
  check(not hasSpecies(19), "RATTATA left the party")
  local browse = get("/gts/browse")
  local listing
  for _, l in pairs((browse and browse.listings) or {}) do if tostring(l.trainerId) == myTid then listing = l end end
  check(listing and listing.offeredMon.species == 19 and listing.offeredMon.personality
    and listing.wanted[1] == 25, "the listing: a whole Gen 3 RATTATA, PIKACHU wanted")
  closeAll()
  -- BUDDY buys it with a PIKACHU
  res = post({ action = "trade", listingId = listing.id, buyerId = bTid, buyerName = "BUDDY",
    sentMon = mon(25, 12, "SPARKY") })
  check(res and res.success and res.receivedMon.species == 19, "BUDDY bought RATTATA")
  GtsUI.openGtsMainMenu(G3.game)
  U.wait(4)
  choose("MY LISTINGS")
  check(isMenu(top()) and labels(top()):find("SPARKY", 1, true), "the claim is listed: " .. labels(top()))
  choose("SPARKY")
  clearTexts()
  check(said("CLAIMED SPARKY"), "claimed SPARKY")
  check(hasSpecies(25), "PIKACHU joined the party")
  closeAll()

  -- BUDDY's KADABRA for a BULBASAUR: the trade scene, then ALAKAZAM
  res = post({ action = "deposit", trainerId = bTid, trainerName = "BUDDY",
    offeredMon = mon(64, 30), wanted = { 1 } })
  check(res and res.success, "BUDDY listed a KADABRA for a BULBASAUR")
  GtsUI.openGtsMainMenu(G3.game)
  U.wait(4)
  choose("BROWSE TRADES")
  choose("ALL ACTIVE TRADES")
  choose("KADABRA")
  shot("listing_card")
  U.tap(game, "a"); U.wait(6)
  choose("BULBASAUR")
  local sawTrade, sawEvo = waitScenes("kadabra")
  check(sawTrade, "FireRed's trade scene played")
  check(sawEvo, "the trade evolution played")
  clearTexts()
  check(said("GTS TRADE COMPLETE"), "the trade completed")
  check(hasSpecies(65) and not hasSpecies(1), "ALAKAZAM in the party, BULBASAUR gone: "
    .. table.concat(partySpecies(), ","))
  check(Runtime.getSession().dex.owned[65], "ALAKAZAM is in the Pokédex")
  closeAll()

  -- ----------------------------------------------------------- Wonder Trade
  for i = 1, 4 do
    local t = post({ action = "register_player", isNewCharacter = true, name = "WT" .. i,
      spriteId = "OBJ_EVENT_GFX_LASS", title = "X", badges = 0, pokedexCount = 0 })
    post({ action = "wonder_trade_deposit", trainerId = t.account.trainerId, trainerName = "WT" .. i,
      offeredMon = mon(10 + i, 5) })
  end
  GtsUI.openGtsMainMenu(G3.game)
  U.wait(4)
  choose("WONDER TRADE")
  choose("DEPOSIT")
  choose("^MAGIKARP")
  clearTexts()
  check(said("A MATCH WAS FOUND"), "the fifth deposit matched the pool")
  closeAll()
  GtsUI.openGtsMainMenu(G3.game)
  U.wait(4)
  choose("WONDER TRADE")
  choose("^CLAIM")
  sawTrade = waitScenes("wonder")
  check(sawTrade, "Wonder Trade played the trade scene with our MAGIKARP leaving")
  clearTexts()
  check(said("WONDER TRADE COMPLETE"), "Wonder Trade claimed")
  closeAll()

  -- ------------------------------------------------------------------- chat
  startItem("gen1online")
  choose("GLOBAL CHAT")
  choose("SEND PRESET")
  choose("HELLO EVERYONE")
  clearTexts()
  local hist = get("/chat/history")
  local last = hist and hist.messages and hist.messages[#hist.messages]
  check(last and last.text == "HELLO EVERYONE!" and last.name == "ASH", "chat reached the server")
  closeAll()
  post({ action = "send_chat", trainerId = bTid, name = "BUDDY", text = "HI ASH!", scope = "global" })
  for _ = 1, 600 do
    if isText(top()) and textOf(top()):find("HI ASH", 1, true) then break end
    U.wait(5)
  end
  check(isText(top()) and textOf(top()):find("BUDDY: HI ASH!", 1, true), "BUDDY's chat popped up")
  shot("chat_notification")
  closeAll()

  -- ------------------------------------------------ disconnect, reconnect
  local onlineParty = #Runtime.getSession().party
  startItem("gen1online")
  choose("DISCONNECT")
  clearTexts()
  check(not online(), "disconnected")
  s = Runtime.getSession()
  check(s.name == "OFFLINE" and s.trainerId == offlineTid and #s.party == 2,
    "the offline game is back: " .. tostring(s.name) .. ", " .. #s.party .. " Pokémon")
  check(s.map == "FR_PLAYERS_HOUSE_2F", "where it was left")
  closeAll()
  check(fieldFree(), "the offline field is free")
  startItem("gen1online")
  choose("^JOIN")
  for _ = 1, 300 do if online() and isText(top()) then break end U.wait(2) end
  check(online(), "connected again")
  s = Runtime.getSession()
  check(s.name == "ASH" and #s.party == onlineParty and hasSpecies(65),
    "the online game came back: " .. tostring(s.name) .. ", " .. #s.party .. " Pokémon")
  clearTexts()
  shot("reconnected")
  closeAll()

  return finish()
end
