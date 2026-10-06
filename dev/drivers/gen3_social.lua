-- Real FireRed / LeafGreen: the rest of the online side, through the real
-- START menu and the mod's FireRed screens.  gts_config.txt points at a dead
-- port, as an untouched install's would (dev/run_tests.sh writes it).
--
--   CONNECT > JOIN can't reach the server and opens SERVER ADDRESS: typed
--   through love.textinput, the keyboard and the D-pad, bad addresses
--   refused, the real one connects -> a new player -> MY PROFILE (the
--   trainer card) and EXP -> ONLINE SETTINGS: title, avatar (our field
--   sprite and what BUDDY sees), favorite Pokémon, the token, live chat ->
--   BUDDY's trainer card through A -> parties: BUDDY's invite accepted,
--   MEMBERS & HUD, WARP TO MEMBER (BUDDY in Pallet Town), LEAVE PARTY; our
--   own party, BUDDY invited and joining -> DISCONNECT, the online files
--   gone (a new device): a wrong token refused, then REDEEM RECOVERY TOKEN
--   brings ASH back, and DISCONNECT still restores the offline game.
--
-- Screenshots in $SHOTS.
local U = require("tests.drivers.util")

return function(game)
  local H = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_util.lua")(game, "gen3_social")
  local say, check, finish, shot = H.say, H.check, H.finish, H.shot
  local post, get = H.post, H.get
  if not H.boot() then return finish() end
  local GtsUI, G3, online = H.GtsUI, H.G3, H.online
  local top, isText, isMenu, textOf = H.top, H.isText, H.isMenu, H.textOf
  local clearTexts, labels, choose, closeAll = H.clearTexts, H.labels, H.choose, H.closeAll
  local fieldFree, startItem, naming = H.fieldFree, H.startItem, H.naming
  local PORT = os.getenv("GTS_PORT") or "17781"

  local Runtime = require("src.core.game3.runtime")
  local Player = require("src.core.game3.player")
  local Map = require("src.core.game3.map")
  local Party = require("src.core.game3.party")
  local Gen3Compat = require("src.mods.Gen3Compat")
  local GFX = require("src.core.game3.constants.firered.event_objects").byName

  -- what the mod's full-screen screens draw, read off its font
  local drawn
  local fontDraw = G3.Font.draw
  G3.Font.draw = function(text, ...)
    if drawn then drawn[#drawn + 1] = tostring(text) end
    return fontDraw(text, ...)
  end
  local function screenText()
    drawn = {}
    U.wait(3)
    local t = table.concat(drawn, " | ")
    drawn = nil
    return t
  end
  -- a text seen, line breaks read as spaces
  local function saw(p)
    for _, t in ipairs(H.seen) do
      if t:gsub("%s+", " "):find(p, 1, true) then return true end
    end
    return false
  end
  local function waitFor(cond, frames)
    for _ = 1, frames or 600 do
      if cond() then return true end
      U.wait(2)
    end
    return false
  end

  -- ---------------------------------------------------------- offline game
  local s = H.newOffline("OFFLINE")
  if not s then return finish() end
  Party.giveMon(s, 1, 8)     -- BULBASAUR
  check(fieldFree(), "the field is free")
  local offlineTid = s.trainerId

  -- --------------------------------------- the server address, typed in
  -- one frame first, so the mod knows the live game (typed text goes there)
  U.wait(2)
  startItem("gen1online")
  check(isMenu(top()) and labels(top()):find("^JOIN 127%.0%.0%.1:1 | SERVER ADDRESS | CANCEL$") ~= nil,
    "CONNECT: JOIN / SERVER ADDRESS / CANCEL: " .. labels(top()))
  choose("^JOIN")
  waitFor(function() return isText(top()) end)
  clearTexts()
  check(saw("COULDN'T REACH THE SERVER AT 127.0.0.1:1."), "the dead server in gts_config.txt is reported")
  local screen = top()
  if not check(screen and screen.gtsTextInput and screen.buffer == "", "the address screen opens after it") then
    return finish()
  end
  check(not online(), "still offline")
  -- a keyboard: characters through love.textinput, keys through the engine's
  -- input.key hook (Game3:keypressed)
  love.textinput("192.168.1.2x3")
  check(screen.buffer == "192.168.1.2X3", "typed text arrives, uppercased (" .. screen.buffer .. ")")
  game:keypressed("backspace"); game:keypressed("backspace")
  check(screen.buffer == "192.168.1.2", "BACKSPACE deletes")
  game:keypressed("z")
  U.wait(2)
  check(screen.buffer == "192.168.1.2" and top() == screen, "a letter key is swallowed, never pressing A or B")
  -- a controller, through the game's input
  U.tap(game, "right")
  check(screen.buffer == "192.168.1.20", "RIGHT adds a character (" .. screen.buffer .. ")")
  U.tap(game, "up"); U.wait(1); U.tap(game, "up"); U.wait(1); U.tap(game, "up")
  check(screen.buffer == "192.168.1.23", "UP steps the last character (" .. screen.buffer .. ")")
  U.tap(game, "down")
  check(screen.buffer == "192.168.1.22", "DOWN steps it back")
  U.tap(game, "b")
  check(screen.buffer == "192.168.1.2", "B deletes")
  shot("address")
  for _, bad in ipairs({ "300.1.1.1", "10..0.1", "HOST:99999" }) do
    screen.buffer, screen.message = bad, nil
    game:keypressed("return")
    U.wait(2)
    check(top() == screen and (screen.message or "") ~= "", ("'%s' is refused: %s"):format(bad, tostring(screen.message)))
  end
  shot("address_refused")
  screen.buffer, screen.message = "127.0.0.1:" .. PORT, nil
  U.tap(game, "a")
  waitFor(function() return isMenu(top()) end)
  check(GtsUI.serverUrlTyped and isMenu(top()) and labels(top()):find("CREATE NEW PLAYER", 1, true),
    "the typed server answers: " .. labels(top()))

  -- -------------------------------------------------------- a new player
  choose("CREATE NEW PLAYER")
  if not naming("ASH") then return finish() end
  choose("^RED$")
  waitFor(function() return online() and Runtime.isActive() and isText(top()) end)
  if not check(online(), "connected as a new online character") then return finish() end
  clearTexts()
  check(saw("PLAYER CREATED"), "PLAYER CREATED")
  closeAll()
  check(fieldFree(), "back in the field")
  local acc = H.account()
  local myTid, token = tostring(acc.trainerId), tostring(acc.token)
  s = Runtime.getSession()
  Party.giveMon(s, 4, 6)     -- CHARMANDER, for FAVORITE MON
  local function profile()
    local r = get("/gts/profile?trainerId=" .. myTid)
    return (r and r.profile) or {}
  end

  -- BUDDY beside the player, syncing over raw HTTP
  local buddy = post({ action = "register_player", isNewCharacter = true, name = "BUDDY",
    spriteId = "OBJ_EVENT_GFX_BROCK", title = "ACE TRAINER", badges = 3, pokedexCount = 40 })
  check(buddy and buddy.success, "BUDDY registered over HTTP")
  local bTid = tostring(buddy.account.trainerId)
  local bMap, bx, by = Gen3Compat.gen1MapId(Map.current), Player.cellX + 1, Player.cellY
  local function buddySync()
    return post({ action = "sync_pos", trainerId = bTid, sessionId = "buddy", name = "BUDDY",
      spriteId = "OBJ_EVENT_GFX_BROCK", title = "ACE TRAINER", level = 3, map = bMap,
      x = bx, y = by, px = bx * 16, py = by * 16, facing = "down", moving = false })
  end
  local function seenByBuddy()
    local r = buddySync()
    for _, p in ipairs((r and r.players) or {}) do if tostring(p.trainerId) == myTid then return p, r end end
    return nil, r
  end
  local netNpcs = GtsUI.G3env.netNpcs
  check(waitFor(function() buddySync(); return netNpcs()[bTid] ~= nil end, 300), "BUDDY arrived in the client")

  -- ------------------------------------------------- profile and settings
  startItem("gen1online")
  choose("MY PROFILE")
  local card = screenText()
  check(card:find("TRAINER CARD", 1, true) and card:find("NAME: ASH", 1, true)
    and card:find("ID:" .. myTid, 1, true), "MY PROFILE: the trainer card (" .. card .. ")")
  shot("trainer_card")
  U.tap(game, "b"); U.wait(4)
  check(G3.UI.Stack:size() == 0 and fieldFree(), "B closes it (the menu closed when MY PROFILE was picked)")
  startItem("gen1online")
  choose("^EXP")
  local exp = screenText()
  check(exp:find("EXP & LEVEL INFO", 1, true) and exp:find("PLAYER: ASH", 1, true), "the EXP screen (" .. exp .. ")")
  shot("exp")
  U.tap(game, "b"); U.wait(4)
  closeAll()

  local function settings(item)
    closeAll()
    startItem("gen1online")
    choose("ONLINE SETTINGS")
    return choose(item)
  end
  settings("CHANGE TITLE")
  choose("^CHAMPION$")
  clearTexts()
  check(saw("TITLE UPDATED TO: CHAMPION"), "CHANGE TITLE")
  check(waitFor(function() return profile().title == "CHAMPION" end, 300), "the server has the title")

  settings("CHANGE AVATAR")
  shot("avatar_list")
  choose("^BROCK$")
  clearTexts()
  check(G3.avatar == "OBJ_EVENT_GFX_BROCK", "CHANGE AVATAR: BROCK")
  local OwSprites = require("src.core.game3.ow_sprites")
  check(OwSprites.playerGraphicsId(G3.raw(), Player) == GFX.OBJ_EVENT_GFX_BROCK, "the player walks as BROCK")
  check(waitFor(function()
    local me = seenByBuddy()
    return me and me.spriteId == "OBJ_EVENT_GFX_BROCK"
  end, 300), "BUDDY sees BROCK")
  closeAll()
  shot("avatar_brock")

  settings("FAVORITE MON")
  choose("^CHARMANDER")
  clearTexts()
  check(waitFor(function() return profile().favoriteMon == "CHARMANDER" end, 300), "FAVORITE MON: CHARMANDER")

  settings("VIEW TOKEN")
  clearTexts()
  check(saw("RECOVERY TOKEN") and saw(token), "VIEW TOKEN shows " .. token)

  settings("LIVE CHAT: ON")
  clearTexts()
  check(saw("LIVE CHAT DISABLED"), "LIVE CHAT off")
  settings("LIVE CHAT: OFF")
  clearTexts()
  check(saw("LIVE CHAT ENABLED"), "and back on")
  closeAll()

  -- a chat line typed on a keyboard: three lines in the box, Enter sends it
  startItem("gen1online")
  choose("GLOBAL CHAT")
  choose("TYPE CUSTOM MESSAGE")
  local box = top()
  if check(box and box.gtsTextInput and box.maxLen, "TYPE CUSTOM MESSAGE opens the chat box") then
    local line = "HELLO FROM PALLET TOWN! ANYONE UP FOR A BATTLE LATER TONIGHT? BRING YOUR BEST TEAM"
    love.textinput(line)
    check(box.buffer == line, "typed through love.textinput")
    local shown = screenText()
    check(not shown:find("\f", 1, true) and shown:find("HELLO FROM", 1, true) ~= nil,
      "drawn in lines, no page break inside one (" .. shown:gsub("\f", "<FF>") .. ")")
    shot("chat_box")
    game:keypressed("return")
    U.wait(6)
    clearTexts()
    local hist = get("/chat/history")
    local last = hist and hist.messages and hist.messages[#hist.messages]
    check(last and last.name == "ASH" and tostring(last.text):upper():find("HELLO FROM PALLET TOWN", 1, true),
      "Enter sent it: " .. tostring(last and last.text))
  end
  closeAll()

  -- the trainer card again, with what changed
  startItem("gen1online")
  choose("MY PROFILE")
  card = screenText()
  check(card:find("FAVORITE: CHARMAND", 1, true), "the card shows the favorite (" .. card .. ")")
  U.tap(game, "b"); U.wait(4)
  closeAll()

  -- A on BUDDY: his trainer card
  fieldFree()
  Player.facing = "right"
  U.wait(5)
  U.tap(game, "a"); U.wait(10)
  check(isMenu(top()) and labels(top()):find("VIEW TRAINER CARD", 1, true), "A on BUDDY: " .. labels(top()))
  choose("VIEW TRAINER CARD")
  card = screenText()
  check(card:find("NAME: BUDDY", 1, true) and card:find("BADGES:3/8", 1, true), "BUDDY's card (" .. card .. ")")
  shot("buddy_card")
  U.tap(game, "b"); U.wait(4)
  closeAll()

  -- ------------------------------------------------------------- parties
  -- BUDDY invites ASH; the invite arrives with the next sync
  local res = post({ action = "party_invite", trainerId = bTid, name = "BUDDY", targetId = myTid,
    level = 3, map = bMap })
  check(res and res.success, "BUDDY invited ASH")
  check(waitFor(function()
    buddySync()
    return isText(top()) and textOf(top()):find("BUDDY INVITED YOU", 1, true) ~= nil
  end, 600), "the invite pops up")
  shot("invite")
  choose("ACCEPT INVITE")
  clearTexts()
  check(saw("JOINED CO-OP PARTY"), "ASH accepted")
  local _, r = seenByBuddy()
  check(r and r.party and r.party.members and r.party.members[myTid] ~= nil, "BUDDY's party has ASH")
  closeAll()
  startItem("gen1online")
  check(isMenu(top()) and labels(top()):find("PARTY (ACTIVE)", 1, true), "the ONLINE menu shows the party")
  choose("PARTY %(ACTIVE%)")
  choose("MEMBERS")
  check(labels(top()):find("BUDDY*", 1, true) and labels(top()):find("ASH", 1, true),
    "MEMBERS & HUD: " .. labels(top()))
  shot("members")
  closeAll()

  -- BUDDY goes to Pallet Town; WARP TO MEMBER takes ASH beside him (one
  -- cell east), in front of the player's house
  local pallet = G3.raw().data.maps.FR_PALLET_TOWN
  local door
  for _, w in ipairs((pallet and pallet.warps) or {}) do
    if tostring(w.destMap or w.map or w.mapId or ""):find("PLAYERS_HOUSE_1F", 1, true) then door = w end
  end
  if not check(door ~= nil, "Pallet Town's door to the player's house") then return finish() end
  bMap, bx, by = "PALLET_TOWN", door.x - 1, door.y + 1
  buddySync()
  startItem("gen1online")
  choose("PARTY %(ACTIVE%)")
  choose("WARP TO MEMBER")
  choose("WARP: BUDDY")
  clearTexts()
  check(saw("WARPED TO BUDDY"), "WARP TO MEMBER")
  closeAll()
  check(waitFor(function() return G3.currentMap() == "FR_PALLET_TOWN" and fieldFree() end, 300),
    "ASH is in Pallet Town (" .. tostring(G3.currentMap()) .. ")")
  check(Player.cellX == bx + 1 and Player.cellY == by, ("beside BUDDY: %s,%s (BUDDY %d,%d)")
    :format(tostring(Player.cellX), tostring(Player.cellY), bx, by))
  check(waitFor(function() buddySync(); return netNpcs()[bTid] ~= nil end, 300), "and sees him there")
  U.wait(30)
  shot("warped")
  startItem("gen1online")
  choose("PARTY %(ACTIVE%)")
  choose("LEAVE PARTY")
  clearTexts()
  check(saw("LEFT THE PARTY"), "LEAVE PARTY")
  _, r = seenByBuddy()
  check(r and r.party and r.party.members and r.party.members[myTid] == nil, "BUDDY's party lost ASH")
  closeAll()
  -- a sync answered before the leave may still hold the party: the next
  -- one puts it right
  for _ = 1, 12 do buddySync(); U.wait(10) end
  startItem("gen1online")
  check(isMenu(top()) and labels(top()):find("^CO%-OP PARTY") ~= nil, "the ONLINE menu has no party: " .. labels(top()))
  closeAll()

  -- ASH's own party, BUDDY invited
  startItem("gen1online")
  choose("CO%-OP PARTY")
  choose("CREATE PARTY")
  clearTexts()
  check(saw("PARTY CREATED"), "CREATE PARTY")
  check(isMenu(top()) and labels(top()):find("INVITE PLAYER", 1, true), "then the party menu: " .. labels(top()))
  choose("INVITE PLAYER")
  choose("^BUDDY")
  clearTexts()
  check(saw("INVITATION SENT TO BUDDY"), "BUDDY invited")
  local invite
  waitFor(function()
    local _, rr = seenByBuddy()
    invite = rr and rr.partyInvite
    return invite ~= nil
  end, 100)
  check(invite and invite.fromName == "ASH", "BUDDY got ASH's invite")
  res = post({ action = "party_accept", trainerId = bTid, name = "BUDDY", level = 3, map = bMap })
  check(res and res.success, "BUDDY accepted")
  closeAll()
  -- the client hears of it with its next sync
  for _ = 1, 30 do buddySync(); U.wait(10) end
  startItem("gen1online")
  choose("PARTY %(ACTIVE%)")
  choose("MEMBERS")
  check(labels(top()):find("BUDDY (", 1, true) and labels(top()):find("ASH* (", 1, true),
    "ASH's party has BUDDY, ASH leading: " .. labels(top()))
  closeAll()

  -- ------------------------------------------- a new device: the token
  startItem("gen1online")
  choose("DISCONNECT")
  clearTexts()
  check(not online(), "disconnected")
  closeAll()
  local dir = love.filesystem.getSaveDirectory() .. "/mod_compat/gen1online-plus/"
  os.remove(dir .. "gen1online_online_account_" .. H.version .. ".lua")
  os.remove(dir .. "save_online_" .. H.version .. ".lua")
  fieldFree()
  startItem("gen1online")
  check(labels(top()) == "JOIN SERVER | SERVER ADDRESS | USE CONFIG FILE | CANCEL",
    "CONNECT remembers the typed server: " .. labels(top()))
  choose("^JOIN")
  choose("REDEEM RECOVERY TOKEN")
  if not naming("ABCD1234") then return finish() end
  clearTexts()
  check(saw("COULD NOT RESTORE") and not online(), "a wrong token is refused")
  closeAll()
  fieldFree()
  startItem("gen1online")
  choose("^JOIN")
  choose("REDEEM RECOVERY TOKEN")
  if not naming(token:lower(), "token") then return finish() end
  waitFor(function() return online() and Runtime.isActive() and isText(top()) end)
  if not check(online(), "REDEEM RECOVERY TOKEN (typed in lower case) connects") then return finish() end
  clearTexts()
  check(saw("WELCOME BACK, ASH"), "welcomed back")
  closeAll()
  s = Runtime.getSession()
  acc = H.account()
  check(s.name == "ASH" and acc and tostring(acc.trainerId) == myTid,
    "the same online character: " .. tostring(s.name) .. " #" .. tostring(acc and acc.trainerId))
  check(s.map == "FR_PLAYERS_HOUSE_2F" and #(s.party or {}) == 0,
    "nothing to restore on this device: a new game in the bedroom (" .. tostring(s.map) .. ")")
  check(G3.avatar == "OBJ_EVENT_GFX_BROCK" and profile().title == "CHAMPION", "with BROCK's look and the title")
  shot("redeemed")
  startItem("gen1online")
  choose("DISCONNECT")
  clearTexts()
  s = Runtime.getSession()
  check(not online() and s.name == "OFFLINE" and s.trainerId == offlineTid,
    "DISCONNECT restores the offline game: " .. tostring(s.name))
  closeAll()

  G3.Font.draw = fontDraw
  return finish()
end
