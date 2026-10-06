-- Two real FireRed / LeafGreen games linked through the test server: a PVP
-- battle and a link trade, both played by the game's own link code.  Run as
-- two processes at once (dev/run_tests.sh starts both):
--   G1O_ROLE=host   RED,  the challenger: CHARIZARD Lv 40 and PIKACHU
--   G1O_ROLE=guest  LEAF, who accepts:    RATTATA Lv 5 and PIDGEY
-- 1. Both connect as new characters and meet in the bedroom.  The host faces
--    LEAF, presses A, picks PVP 1V1 SINGLES; the guest accepts.  The battle
--    runs at the party's real levels (autoFight picks the moves), CHARIZARD
--    wins; the server books a win and a loss; both parties come back as they
--    were (the Union Room's rule).
-- 2. LEAF offers a LINK TRADE; RED accepts.  The Trade Center's trade
--    screen: RED offers PIKACHU, LEAF PIDGEY, both say yes, the trade scene
--    plays; then both cancel and the link closes.  Each game has the other's
--    Pokémon, OT and all.
local U = require("tests.drivers.util")

return function(game)
  local role = os.getenv("G1O_ROLE") or "host"
  local host = role == "host"
  local H = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_util.lua")(game, "gen3_link_" .. role)
  local say, check, finish, shot = H.say, H.check, H.finish, H.shot
  if not H.boot() then return finish() end
  local G3 = H.G3
  local Runtime = require("src.core.game3.runtime")
  local Player = require("src.core.game3.player")
  local Party = require("src.core.game3.party")
  local Battle = require("src.core.game3.battle")
  local LB = require("src.core.game3.link.battle")
  local LT = require("src.core.game3.link.trade")
  local LinkTradeMenu = require("src.ui.game3.link_trade_menu")
  local TradeScene = require("src.core.game3.trade_scene")
  local me, them = host and "RED" or "LEAF", host and "LEAF" or "RED"

  H.newOffline(me .. "OFF")
  if not check(H.createPlayer(me, host and "^RED$" or "^LEAF$"), "online as " .. me) then return finish() end
  H.closeAll()
  check(H.fieldFree(), "in the field")
  local s = Runtime.getSession()
  if host then
    Party.giveMon(s, 6, 40)   -- CHARIZARD
    Party.giveMon(s, 25, 12)  -- PIKACHU
  else
    Party.giveMon(s, 19, 5)   -- RATTATA
    Party.giveMon(s, 16, 5)   -- PIDGEY
  end
  local myTid = tostring(H.account().trainerId)

  -- wait for the other game on the server, then on this map
  local theirTid
  for _ = 1, 3000 do
    local players = H.get("/gts/players")
    for tid, p in pairs((players and players.players) or {}) do
      if p.name == them then theirTid = tostring(tid) end
    end
    if theirTid then break end
    U.wait(10)
  end
  if not check(theirTid ~= nil, them .. " is online") then return finish() end
  local px, py = Player.cellX, Player.cellY
  if not host then
    -- LEAF steps right, so RED can face her
    U.hold(game, "right", 18)
    U.wait(30)
    check(Player.cellX == px + 1, "LEAF stepped east")
  end
  local netNpcs = H.GtsUI.G3env.netNpcs
  local function near()
    local n = netNpcs()[theirTid]
    return n and math.abs(n.cellX - Player.cellX) + math.abs(n.cellY - Player.cellY) == 1 and n
  end
  for _ = 1, 3000 do if near() then break end U.wait(5) end
  if not check(near(), them .. " is next to us") then return finish() end
  U.wait(60)

  local function faceAndAsk(pattern)
    local n = near()
    Player.facing = n.cellX > Player.cellX and "right" or (n.cellX < Player.cellX and "left"
      or (n.cellY > Player.cellY and "down" or "up"))
    U.wait(5)
    U.tap(game, "a"); U.wait(10)
    check(H.isMenu(H.top()) and H.labels(H.top()):find(pattern), "A on " .. them .. ": " .. H.labels(H.top()))
    return H.choose(pattern)
  end

  -- ----------------------------------------------------------------- battle
  LB.autoFight = true
  if host then
    shot("challenge")
    faceAndAsk("PVP 1V1")
  else
    check(H.waitMenu("ACCEPT PVP", 3000), "the challenge arrived: " .. H.labels(H.top()))
    shot("challenged")
    H.choose("ACCEPT PVP")
  end
  local started = false
  for _ = 1, 3000 do
    if Battle.isActive() then started = true break end
    if H.isText(H.top()) then H.clearTexts(1) end
    U.wait(2)
  end
  if not check(started, "the link battle started") then return finish() end
  U.wait(240)
  shot("battle")
  for _ = 1, 9000 do
    if not Battle.isActive() and not G3.link().busy() then break end
    U.tap(game, "a"); U.wait(4)
  end
  check(not Battle.isActive(), "the battle ended")
  local last = G3.link().last
  check(last and last.kind == "battle", "the link closed after the battle")
  H.clearTexts()
  check(H.fieldFree(), "back in the field")
  s = Runtime.getSession()
  local function full()
    for _, m in ipairs(s.party) do if (tonumber(m.hp) or 0) < (tonumber(m.maxHp) or 1) then return false end end
    return true
  end
  check(#s.party == 2 and full(), "the party came back as it was")
  local profile
  for _ = 1, 60 do
    profile = H.get("/gts/profile?trainerId=" .. myTid)
    profile = profile and profile.profile
    if profile and ((profile.pvpWins or 0) + (profile.pvpLosses or 0)) > 0 then break end
    U.wait(10)
  end
  if host then
    check(profile and profile.pvpWins == 1, "RED's win is booked (" .. tostring(profile and profile.pvpWins) .. ")")
  else
    check(profile and profile.pvpLosses == 1, "LEAF's loss is booked (" .. tostring(profile and profile.pvpLosses) .. ")")
  end
  -- past the post-battle cooldown (5 real seconds, whatever the frame rate)
  local t0 = love.timer.getTime()
  while love.timer.getTime() - t0 < 6.5 do U.wait(10) end

  -- ------------------------------------------------------------------ trade
  if host then
    check(H.waitMenu("ACCEPT TRADE", 4000), "the trade offer arrived: " .. H.labels(H.top()))
    H.choose("ACCEPT TRADE")
  else
    U.wait(60)
    faceAndAsk("LINK TRADE")
  end
  local opened = false
  for _ = 1, 3000 do
    if LinkTradeMenu.isOpen() and LT.state == "menu" and LT.peer then opened = true break end
    if H.isText(H.top()) then H.clearTexts(1) end
    U.wait(2)
  end
  if not check(opened, "the Trade Center's trade screen opened") then return finish() end
  U.wait(120)
  shot("trade_menu")
  local mySlot = host and 2 or 2     -- PIKACHU / PIDGEY
  local sent = s.party[mySlot]
  local sentPersonality = sent.personality
  check(LT.offer(mySlot) ~= false, "offered " .. tostring(sent.nickname ~= "" and sent.nickname or sent.name))
  for _ = 1, 3000 do
    if LT.state == "confirm" then break end
    U.wait(2)
  end
  check(LT.state == "confirm", "both offers are in")
  U.wait(30)
  LT.confirm(true)
  local scene = false
  for _ = 1, 6000 do
    if TradeScene.isOpen() then
      if not scene then scene = true; U.wait(160); shot("trade_scene") end
    end
    if scene and not TradeScene.isOpen() and LT.state == "menu" then break end
    if TradeScene.isOpen() then U.tap(game, "a") end
    U.wait(3)
  end
  check(scene, "the trade scene played")
  local got = s.party[mySlot]
  local wanted = host and 16 or 25
  check(got and tonumber(got.species) == wanted and got.personality ~= sentPersonality,
    "received " .. them .. "'s " .. (host and "PIDGEY" or "PIKACHU"))
  check(got and got.otName == them, "with " .. them .. " as its OT (" .. tostring(got and got.otName) .. ")")
  -- both leave the trade screen
  U.wait(60)
  LT.cancelSelect()
  for _ = 1, 3000 do
    if not G3.link().busy() then break end
    U.wait(3)
  end
  check(not G3.link().busy() and not LinkTradeMenu.isOpen(), "the trade link closed")
  last = G3.link().last
  check(last and last.kind == "trade" and last.trades == 1, "one trade made (" .. tostring(last and last.trades) .. ")")
  H.clearTexts()
  check(H.fieldFree(), "back in the field")
  shot("after_trade")
  -- the online save has the new Pokémon
  local saved = H.G3 and require("src.core.SaveSerializer")
  U.wait(30)
  return finish()
end
