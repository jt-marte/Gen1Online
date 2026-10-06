-- Two real FireRed / LeafGreen games on one hardcore Nuzlocke server
-- (hardcore, randomizer, seed 4242): you (G1O_ROLE=host, ASH) and a friend
-- (G1O_ROLE=guest, MISTY), run at the same time as two LÖVE processes.
--
--   both connect as new characters, the rules reach both, and each sees the
--   other on Route 1 -> ASH catches Route 1's first wild Pokémon and says so
--   in the chat -> then MISTY catches hers (the area is each player's own)
--   -> for both, the next one on Route 1 is refused in the bag, the ball
--   kept -> both say DONE and wait for the other.
--
-- dev/run_tests.sh runs it on FireRed (both profiles need the cache).
local U = require("tests.drivers.util")

return function(game)
  local role = os.getenv("G1O_ROLE") or "host"
  local H = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_util.lua")(game, "gen3_friend_" .. role)
  local say, check, finish, shot = H.say, H.check, H.finish, H.shot
  if not H.boot() then return finish() end
  local G3, GtsUI = H.G3, H.GtsUI
  local Runtime = require("src.core.game3.runtime")
  local Bag = require("src.core.game3.bag")
  local Battle = require("src.core.game3.battle")
  local BattleBridge = require("src.core.game3.battle_bridge")
  local BattleAPI = require("src.battle.game3.BattleAPI")
  local BagMenu = require("src.ui.game3.bag_menu")
  local Message = require("src.ui.game3.message")
  local ItemsData = require("src.core.game3.items_data")
  local Pokemon = require("src.core.game3.pokemon")
  local Choice = require("src.ui.game3.choice")
  local Naming = require("src.ui.game3.naming")
  local ITEMS = require("src.core.game3.constants.firered.items").byName
  local Modes = GtsUI.Modes
  local me, friend = "ASH", "MISTY"
  if role == "guest" then me, friend = "MISTY", "ASH" end

  H.newOffline("OFFLINE")
  if not check(H.createPlayer(me, role == "guest" and "^LEAF$" or "^RED$"), me .. " online as a new character") then
    return finish()
  end
  H.clearTexts()
  H.closeAll()
  check(Modes.hardcore() and Modes.rules.randomizer, "the server's hardcore Nuzlocke reaches " .. me
    .. ": " .. tostring(Modes.describe()))
  local acc = H.account()
  local myTid = tostring(acc.trainerId)

  -- chat lines as signals between the two games
  local function say2(text)
    H.post({ action = "send_chat", trainerId = myTid, name = me, text = text, scope = "global" })
  end
  local function heard(text, frames)
    for _ = 1, frames or 3000 do
      local hist = H.get("/chat/history")
      for _, m in ipairs((hist and hist.messages) or {}) do
        if m.text == text then return true end
      end
      H.clearTexts(1)
      U.wait(10)
    end
    return false
  end

  -- both on Route 1, side by side
  G3.warpTo("ROUTE_1", role == "guest" and 11 or 10, 20, "down")
  for _ = 1, 300 do if G3.currentMap() == "FR_ROUTE_1" and H.fieldFree() then break end U.wait(2) end
  check(G3.currentMap() == "FR_ROUTE_1", "on Route 1")
  local friendTid
  local netNpcs = GtsUI.G3env.netNpcs
  for _ = 1, 600 do
    local players = (H.get("/gts/players") or {}).players or {}
    for tid, p in pairs(players) do if p.name == friend then friendTid = tostring(tid) end end
    if friendTid and netNpcs()[friendTid] then break end
    H.clearTexts(1)
    U.wait(10)
  end
  check(friendTid and netNpcs()[friendTid] ~= nil, me .. " sees " .. friend .. " on Route 1")
  U.wait(30)
  shot("together")

  -- the battle kit (as in gen3_nuzlocke.lua)
  local api = BattleAPI.new(game)
  local intent = 0
  local function submit(kind, choice)
    for _ = 1, 600 do
      local snap = api:snapshot()
      if snap and snap.prompt == "menu" then
        intent = intent + 1
        if api:submit({ id = intent, revision = snap.revision, kind = kind, choice = choice }) then return true end
      elseif snap and snap.prompt == "advance" then
        U.tap(game, "a")
      end
      U.wait(2)
    end
    return false
  end
  local function waitEnd()
    for _ = 1, 6000 do
      if not Battle.isActive() and not Naming.isOpen() and not Choice.active then break end
      if Naming.isOpen() then Naming.close("")
      elseif Choice.active then U.tap(game, "b")
      elseif Message.isOpen() or Battle.isActive() then U.tap(game, "a") end
      U.wait(2)
    end
    for _ = 1, 600 do if H.fieldFree() then break end U.wait(2) end
    return not Battle.isActive()
  end
  local function wild(species, level)
    BattleBridge.startWild(nil, game, { species = species, level = level }, {})
    for _ = 1, 900 do
      local st = Battle.isActive() and Battle.getState()
      if st and st.enemy and st.enemy.mon then return st end
      U.wait(2)
    end
  end
  local function leave()
    local Engine = package.loaded["src.core.game3.battle.engine"]
    local bst = Battle.getState and Battle.getState()
    if Engine and Engine.canRun and Battle._adapter and bst
        and not Engine.canRun(bst, Battle._adapter, bst.player) then
      Battle.abort("run")
    else
      submit("menu", "run")
    end
    return waitEnd()
  end
  local function throwBall()
    if not submit("menu", "item") then return false end
    for _ = 1, 300 do if BagMenu.isOpen() then break end U.wait(2) end
    if not BagMenu.isOpen() then return false end
    U.wait(30)
    for i, p in ipairs(ItemsData.BAG_POCKET_ORDER) do
      if p == "POKE_BALLS" then BagMenu.pocketIdx = i end
    end
    BagMenu.cursor, BagMenu.scroll = 1, 0
    U.wait(5)
    U.tap(game, "a"); U.wait(10)
    U.tap(game, "a"); U.wait(10)
    return true
  end
  local s = Runtime.getSession()
  local function masterBalls() return Bag.get(s.bag, ITEMS.ITEM_MASTER_BALL) end
  -- a new character has no Pokémon yet: one to battle with, and balls
  require("src.core.game3.party").giveMon(s, 6, 50)     -- CHARIZARD
  Bag.add(s.bag, ITEMS.ITEM_MASTER_BALL, 3)

  -- the friend goes second: ASH's catch must not use up MISTY's Route 1
  if role == "guest" then
    check(heard("ASH CAUGHT ON ROUTE 1"), "ASH says he caught his Route 1 Pokémon")
  end
  local before = #s.party
  local st = wild(19, 3)
  local species = st and tonumber(st.enemy.mon.species)
  check(throwBall() and waitEnd(), me .. " threw a MASTER BALL at Route 1's first Pokémon")
  s = Runtime.getSession()
  check(#s.party == before + 1 and tonumber(s.party[#s.party].species) == species,
    me .. " caught it: " .. tostring(species and Pokemon.name(species)))
  check(Modes.state().areas.FR_ROUTE_1 ~= nil, "Route 1 is used, in " .. me .. "'s own save")
  if role == "host" then say2("ASH CAUGHT ON ROUTE 1") end

  -- the next one on Route 1: refused, the ball kept
  local balls = masterBalls()
  st = wild(16, 3)
  check(st ~= nil and throwBall(), me .. " tries a second Route 1 Pokémon")
  U.wait(20)
  shot("refused")
  local text = tostring(BagMenu.messageText or "")
  check(BagMenu.mode == "message" and text:find("ENCOUNTER HERE", 1, true) ~= nil,
    "refused for " .. me .. ": " .. text:gsub("\n", " "))
  for _ = 1, 120 do
    if not BagMenu.isOpen() then break end
    if BagMenu.mode == "message" then U.tap(game, "a") else U.tap(game, "b") end
    U.wait(5)
  end
  check(masterBalls() == balls and #Runtime.getSession().party == before + 1, "the ball kept, nothing caught")
  check(leave(), me .. " ran")

  -- done when both are
  say2(me .. " DONE")
  check(heard(friend .. " DONE"), friend .. " finished too")
  return finish()
end
