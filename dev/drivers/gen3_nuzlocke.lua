-- Real FireRed / LeafGreen battles under the hardcore Nuzlocke (the same
-- server config as gen3_modes.lua: hardcore, randomizer, seed 4242):
--   1. the first wild Pokémon on Route 1 (a shuffled RATTATA) is caught with
--      a MASTER BALL thrown from the battle bag
--   2. the next one on Route 1: the bag's ball is refused, with the reason,
--      and the ball is kept; the player runs.  The Safari Zone's own BALL
--      command is refused the same way, with no SAFARI BALL spent
--   3. a MAGIKARP lead faints in a real battle (the battle plays itself):
--      buried after it, the others stay
--   4. a party that can't win blacks out: the run ends, run 2 starts in the
--      bedroom
local U = require("tests.drivers.util")

return function(game)
  local H = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_util.lua")(game, "gen3_nuzlocke")
  local say, check, finish, shot = H.say, H.check, H.finish, H.shot
  if not H.boot() then return finish() end
  local G3, GtsUI = H.G3, H.GtsUI
  local Runtime = require("src.core.game3.runtime")
  local Party = require("src.core.game3.party")
  local Pokemon = require("src.core.game3.pokemon")
  local Bag = require("src.core.game3.bag")
  local Battle = require("src.core.game3.battle")
  local BattleBridge = require("src.core.game3.battle_bridge")
  local BattleAPI = require("src.battle.game3.BattleAPI")
  local BagMenu = require("src.ui.game3.bag_menu")
  local Message = require("src.ui.game3.message")
  local ItemsData = require("src.core.game3.items_data")
  local ITEMS = require("src.core.game3.constants.firered.items").byName
  local Modes = GtsUI.Modes

  H.newOffline("OFFLINE")
  if not check(H.createPlayer("MISTY", "^LEAF$"), "online as a new character") then return finish() end
  H.clearTexts()
  H.closeAll()
  check(Modes.hardcore(), "hardcore is on")
  local s = Runtime.getSession()
  Party.giveMon(s, 129, 2)    -- MAGIKARP: faints first
  Party.giveMon(s, 6, 60)     -- CHARIZARD
  Bag.add(s.bag, ITEMS.ITEM_MASTER_BALL, 3)
  G3.warpTo("ROUTE_1", 10, 20, "down")
  for _ = 1, 300 do if G3.currentMap() == "FR_ROUTE_1" and H.fieldFree() then break end U.wait(2) end
  check(G3.currentMap() == "FR_ROUTE_1", "on Route 1")

  local api = BattleAPI.new(game)
  local intent = 0
  local function submit(kind, choice, extra)
    for _ = 1, 600 do
      local snap = api:snapshot()
      if snap and snap.prompt == "menu" then
        intent = intent + 1
        local t = { id = intent, revision = snap.revision, kind = kind, choice = choice }
        for k, v in pairs(extra or {}) do t[k] = v end
        local ok, why = api:submit(t)
        if ok then return true end
      elseif snap and snap.prompt == "advance" then
        U.tap(game, "a")
      end
      U.wait(2)
    end
    return false
  end
  local Choice = require("src.ui.game3.choice")
  local Naming = require("src.ui.game3.naming")
  local function waitEnd(frames)
    for f = 1, frames or 6000 do
      if not Battle.isActive() and not Naming.isOpen() and not Choice.active then break end
      if Naming.isOpen() then
        Naming.close("")                  -- no nickname
      elseif Choice.active then
        U.tap(game, "b")                  -- NO (a nickname, a new move...)
      elseif Message.isOpen() or Battle.isActive() then
        U.tap(game, "a")                  -- the battle's own text waits for A too
      end
      if f % 60 == 0 then
        local snap = api:snapshot()
        local Ui = require("src.core.game3.battle.ui")
        say(("  battle %d: active %s bag %s/%s phase %s prompt %s ui %s choice %s naming %s msg %s"):format(f,
          tostring(Battle.isActive()), tostring(BagMenu.isOpen()), tostring(BagMenu.mode),
          tostring(Battle._phase), tostring(snap and snap.prompt),
          tostring(Ui._mode), tostring(Choice.active), tostring(Naming.isOpen()),
          tostring(Message.isOpen() and Message.currentPage and Message.currentPage())))
      end
      U.wait(2)
    end
    for _ = 1, 600 do
      if H.fieldFree() then break end
      U.wait(2)
    end
    return not Battle.isActive()
  end
  local function wild(species, level, opts)
    BattleBridge.startWild(nil, game, { species = species, level = level }, opts or {})
    for _ = 1, 900 do
      local st = Battle.isActive() and Battle.getState()
      if st and st.enemy and st.enemy.mon then return st end
      U.wait(2)
    end
  end
  local function masterBalls() return Bag.get(s.bag, ITEMS.ITEM_MASTER_BALL) end
  -- RUN, unless the shuffled Pokémon traps the player (Arena Trap or
  -- Shadow Tag, by its personality): then the battle is ended for the test
  local function leave()
    local Engine = package.loaded["src.core.game3.battle.engine"]
    local bst = Battle.getState and Battle.getState()
    local free = true
    if Engine and Engine.canRun and Battle._adapter and bst then
      free = Engine.canRun(bst, Battle._adapter, bst.player) and true or false
    end
    if free then
      submit("menu", "run")
    else
      say("  (the wild Pokémon traps the player: the battle is ended)")
      Battle.abort("run")
    end
    return waitEnd()
  end
  -- the battle bag: the Poké Balls pocket, the ball, A then USE
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

  -- 1. the area's first encounter, caught
  local partyBefore = #s.party
  local st = wild(19, 3)
  local species = st and tonumber(st.enemy.mon.species)
  check(species == Modes.plan().species[19], "Route 1's RATTATA is a " .. tostring(species and Pokemon.name(species)))
  check(throwBall(), "a MASTER BALL thrown from the bag")
  shot("catch")
  check(waitEnd(), "the battle ended")
  s = Runtime.getSession()
  check(#s.party == partyBefore + 1 and tonumber(s.party[#s.party].species) == species,
    "caught: " .. tostring(species and Pokemon.name(species)))
  check(Modes.state().areas.FR_ROUTE_1 ~= nil, "Route 1's encounter is used")

  -- 2. the next encounter here: the ball is refused and kept
  local balls = masterBalls()
  st = wild(16, 3)
  throwBall()
  U.wait(20)
  shot("refused")
  -- the bag's own message line (BagMenu.showMessage)
  local text = tostring(BagMenu.messageText or "")
  check(BagMenu.mode == "message" and text:find("ENCOUNTER HERE", 1, true) ~= nil,
    "the bag says why: " .. text:gsub("\n", " "):sub(1, 80))
  for _ = 1, 20 do if BagMenu.mode ~= "message" then break end U.tap(game, "a"); U.wait(5) end
  -- B until the bag is shut (a press during its slide-in does nothing)
  for _ = 1, 120 do
    if not BagMenu.isOpen() then break end
    if BagMenu.mode == "message" then U.tap(game, "a") else U.tap(game, "b") end
    U.wait(5)
  end
  check(not BagMenu.isOpen(), "the bag closed")
  check(masterBalls() == balls, "the MASTER BALL was kept")
  check(leave(), "ran away")

  -- 2b. the Safari Zone's own BALL command: refused the same way, and no
  --     SAFARI BALL spent
  local Safari = require("src.core.game3.safari")
  Safari.enter(s)
  local safariBalls = Safari.balls(s)
  st = wild(16, 3, { safari = true })
  check(st and st.safari, "a Safari Zone battle")
  submit("menu", "fight")           -- the Safari menu's first command is BALL
  local safariText = ""
  for _ = 1, 120 do
    if Message.isOpen() and Message.currentPage then safariText = tostring(Message.currentPage()) break end
    U.wait(2)
  end
  shot("safari_refused")
  check(safariText:find("ENCOUNTER HERE", 1, true) ~= nil, "the Safari BALL says why: " .. safariText:gsub("\n", " "))
  check(Safari.balls(s) == safariBalls, "no SAFARI BALL was spent (" .. Safari.balls(s) .. ")")
  check(leave(), "left the Safari battle")
  Safari.exit(s)

  -- 3. the MAGIKARP lead faints in a real battle and is buried
  G3.warpTo("ROUTE_22", 10, 10, "down")
  for _ = 1, 300 do if G3.currentMap() == "FR_ROUTE_22" and H.fieldFree() then break end U.wait(2) end
  s = Runtime.getSession()
  local karp = s.party[1]
  check(tonumber(karp.species) == 129, "MAGIKARP leads")
  -- a GEODUDE (shuffled) that outclasses it; at 1 HP any hit will do, but a
  -- wild Pokémon may TELEPORT away first, so it goes again until one lands
  karp.hp = 1
  local stillThere = true
  for try = 1, 5 do
    st = wild(74, 30, { autoFight = true })
    if try == 1 then shot("faint_battle") end
    check(waitEnd(9000), "the battle played out (try " .. try .. ")")
    s = Runtime.getSession()
    stillThere = false
    for _, m in ipairs(s.party) do if m == karp or tonumber(m.species) == 129 then stillThere = true end end
    if not stillThere then break end
    H.clearTexts()
  end
  check(not stillThere, "MAGIKARP fainted and is gone for good")
  H.clearTexts()
  local fallen = Modes.state().graveyard
  check(fallen[1] and tonumber(fallen[1].species) == 129, "it is in the graveyard")
  H.closeAll()

  -- 4. a party that can't win: the blackout ends the run
  local runId = Modes.rules.runId
  for i = #s.party, 1, -1 do table.remove(s.party, i) end
  Party.giveMon(s, 10, 2)      -- CATERPIE
  st = wild(150, 70, { autoFight = true })
  check(waitEnd(12000), "the hopeless battle ended")
  local newRun = false
  for f = 1, 2000 do
    H.clearTexts(1)
    if Message.isOpen() or H.screenUp() then U.tap(game, "a") end
    if f % 100 == 0 then
      local Hud = require("src.ui.game3.hud")
      say(("  after the blackout: busy %s (mod stack %d, hud %s, world %s) msg %s wiped %s run %s/%s map %s"):format(
        tostring(G3.busy()), H.Stack:size(), tostring(Hud.busy and Hud.busy()),
        tostring(require("src.mods.Gen3Compat").worldBusy()), tostring(Message.isOpen()),
        tostring(Modes.state().wiped), tostring(Modes.state().run), tostring(Modes.rules and Modes.rules.runId),
        tostring(G3.currentMap())))
      if f == 300 then shot("after_blackout") end
    end
    if Modes.rules and Modes.rules.runId == runId + 1 and Modes.state().run == runId + 1 then newRun = true break end
    U.wait(3)
  end
  check(newRun, "the blackout ended run " .. runId .. "; run " .. (runId + 1) .. " began")
  s = Runtime.getSession()
  check(s.map == "FR_PLAYERS_HOUSE_2F" and #s.party == 0, "a new game in the bedroom")
  return finish()
end
