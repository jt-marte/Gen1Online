-- Real Yellow, real battles, on a server with every game mode on
-- (nuzlocke = hardcore, randomizer = on, seed = 4242).  Where gen1_modes.lua
-- checks the modes' hooks one by one, this one plays them: wild encounters
-- rolled by the engine's own step handler in real grass, items picked from
-- the real in-battle bag, a real catch, a real faint that buries a Pokémon,
-- Brock fought for his shuffled badge slot, and a real blackout that ends
-- the run.  dev/run_tests.sh runs it when the Yellow cache is there.
local U = require("tests.drivers.util")
local ModRuntime = require("src.mods.Runtime")
local BattleAPI = require("src.battle.BattleAPI")
local BattleState = require("src.battle.BattleState")
local ChoiceBox = require("src.ui.ChoiceBox")

return function(game)
  local fails = 0
  local function say(...) print("[g1o]", ...) end
  local function check(cond, label)
    say((cond and "PASS " or "FAIL ") .. label)
    if not cond then fails = fails + 1 end
    return cond
  end
  local function finish()
    say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
    love.event.quit(fails == 0 and 0 or 1)
    while true do coroutine.yield() end
  end

  local realUpdate = game.update
  game.update = function(self, dt)
    return ModRuntime.call("core.update", function(g, d) return realUpdate(g, d) end, self, dt)
  end
  for _ = 1, 600 do
    if game.data and game.stack and game.renderer and game.save and game.input then break end
    U.wait(1)
  end
  local g1o = (game.mods and game.mods.exports or {})["gen1online-plus"]
  local Modes = g1o and g1o.modes
  if not check(Modes ~= nil, "the game modes module is loaded") then return finish() end

  local TextBox = require("src.render.TextBox")
  local function top() return game.stack:top() end
  local function isText(s) return s and getmetatable(s) == TextBox end
  local function textOf(s)
    local t = {}
    local function walk(v)
      if type(v) == "string" then t[#t + 1] = v
      elseif type(v) == "table" then for _, x in ipairs(v) do walk(x) end end
    end
    walk(s and (s.pages or s.text))
    return table.concat(t, " ")
  end
  local seen = {}
  local function flat(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for _, x in pairs(v) do
      if type(x) == "string" or type(x) == "table" then parts[#parts + 1] = flat(x) end
    end
    return table.concat(parts, " ")
  end
  local function record(t)
    t = flat(t):gsub("[\n\f]", " ")
    if t == "" then return end
    if seen[#seen] ~= t then seen[#seen + 1] = t; say("  " .. t) end
  end
  local function said(p, from)
    for i = #seen, from or 1, -1 do if seen[i]:find(p, 1, true) then return seen[i] end end
  end
  local function clearTexts(frames)
    for _ = 1, frames or 600 do
      local s = top()
      if isText(s) then
        record(textOf(s))
        U.tap(game, "a"); U.wait(3)
      elseif s == game.overworld then
        U.wait(2)
        if not isText(top()) then return end
      else
        U.wait(2)
      end
    end
  end
  local function choose(pattern)
    local s = top()
    if not (s and s.items) then return check(false, "expected a menu for '" .. pattern .. "'") end
    for i, it in ipairs(s.items) do
      if tostring(it.label):find(pattern) then
        if s.list then s.list.index = i else s.index = i end
        U.tap(game, "a"); U.wait(6)
        return true
      end
    end
    return check(false, "no '" .. pattern .. "' in the menu")
  end
  local function settled()
    for _ = 1, 900 do
      local ow = game.overworld
      if ow and ow.map and top() == ow and not ow.player.moving and not ow.transitioning then return true end
      if isText(top()) then record(textOf(top())); U.tap(game, "a") end
      U.wait(1)
    end
    return false
  end
  local function inv(id) return (game.save.inventory or {})[id] or 0 end

  -- ---- connect as a new character ----------------------------------------------------
  U.teleport(game, "PALLET_TOWN", 5, 6, "down")
  settled()
  U.tap(game, "start"); U.wait(10)
  choose("CONNECT")
  choose("^JOIN")
  choose("CREATE NEW PLAYER")
  local naming = top()
  if naming and naming.onDone then
    game.stack:pop()
    naming.onDone("ASH", true)
    U.wait(6)
  end
  choose("RED")
  for _ = 1, 300 do
    clearTexts(40)
    if said("PLAYER CREATED") then break end
    U.wait(2)
  end
  clearTexts()
  local plan = Modes.plan()
  if not check(Modes.hardcore() and plan and plan.ok, "connected to a hardcore randomizer run") then
    return finish()
  end

  -- ---- a team ------------------------------------------------------------------------
  local Pokemon = require("src.pokemon.Pokemon")
  local function mon(species, level, moves)
    local m = Pokemon.new(game.data, species, level)
    if moves then
      m.moves = {}
      for i, id in ipairs(moves) do m.moves[i] = { id = id, pp = game.data.moves[id].pp } end
    end
    return m
  end
  local function setParty(list) game.save.party = list end
  game.save.inventory.MASTER_BALL = 5
  game.save.inventory.POTION = 3
  game.save.inventory.POKE_BALL = 5
  game.save.bagOrder = nil
  local mewtwo = mon("MEWTWO", 70, { "PSYCHIC_M", "GROWL" })
  setParty({ mewtwo })

  -- ---- battles -------------------------------------------------------------------------
  local api = BattleAPI.new(game)
  local intentId = 0
  local function submit(intent)
    local s = api:snapshot()
    if not s then return nil end
    intentId = intentId + 1
    intent.id, intent.revision = intentId, s.revision
    return api:submit(intent)
  end
  local function inBattle()
    for _, st in ipairs(game.stack.states or {}) do
      if getmetatable(st) == BattleState or (type(st) == "table" and st.isBattle) then return true end
    end
    return api:snapshot() ~= nil
  end

  -- one battle, start to finish; `policy` decides menus, moves, the bag and
  -- yes/no boxes.  Returns the battle's result as battle.ended reported it.
  local lastResult
  local partyPickers = 0
  local realEmit = ModRuntime.emit
  ModRuntime.emit = function(name, payload, ...)
    if name == "battle.ended" then lastResult = payload and payload.result end
    return realEmit(name, payload, ...)
  end
  local function play(policy, maxFrames)
    lastResult = nil
    local idle, lastQuestion = 0, nil
    for _ = 1, maxFrames or 6000 do
      local s = api:snapshot()
      local t = top()
      if s and s.message then record(s.message) end
      if s and s.message then lastQuestion = flat(s.message) end
      local isChoice = t and getmetatable(t) == ChoiceBox
      local states = game.stack.states or {}
      local under = states[#states - 1]
      local switchMenu
      for _, st in ipairs(states) do
        if type(st) == "table" and st.isPartyMenu and st.forceSwitch then switchMenu = st end
      end
      if t and not isText(t) and isText(under) and under.choice then
        -- a YES/NO box over its question
        local q = textOf(under)
        record(q)
        U.tap(game, (policy.yes and policy.yes(q)) and "a" or "b")
        U.wait(3)
      elseif isText(t) then
        record(textOf(t))
        if t.choice then
          U.tap(game, (policy.yes and policy.yes(textOf(t))) and "a" or "b")
        else
          U.tap(game, "a")
        end
        U.wait(2)
      elseif isChoice then
        -- the battle's own YES/NO ("Use next POKéMON?") over its question
        U.tap(game, (policy.yes and policy.yes(lastQuestion or "")) and "a" or "b")
        U.wait(20)
      elseif s and s.prompt == "advance" then
        U.tap(game, "a"); U.wait(1)
      elseif s and (s.prompt == "menu" or s.prompt == "safari") then
        policy.menu(s); U.wait(2)
      elseif s and s.prompt == "moves" then
        submit({ kind = "move", slot = policy.move and policy.move(s) or 1 }); U.wait(2)
      elseif switchMenu then
        switchMenu.index = policy.switchTo and policy.switchTo(s) or 2
        U.tap(game, "a"); U.wait(4)
      elseif t and t.isPartyMenu then
        if t.forceSwitch then
          t.index = policy.switchTo and policy.switchTo(s) or 2
        else
          -- a target picker: the hardcore rules should have refused before it
          partyPickers = partyPickers + 1
        end
        U.tap(game, "a"); U.wait(4)
      elseif t and t.items and t.items[1] and t.items[1].value ~= nil and policy.bag then
        policy.bag(t); U.wait(2)
      elseif not s and t == game.overworld and not inBattle() then
        if lastResult then return lastResult end
        U.wait(1)
      else
        -- another screen (the Pokédex entry after a catch, a transition):
        -- A moves it along
        idle = idle + 1
        if idle % 20 == 0 then U.tap(game, "a") end
        U.wait(1)
      end
    end
    return lastResult
  end
  local function pickItem(list, id)
    for i, it in ipairs(list.items) do
      if it.value == id then list.index = i; U.tap(game, "a"); return true end
    end
    U.tap(game, "b")
    return false
  end

  -- the engine's own step handler in real grass, until it starts a battle
  local function encounter(mapId)
    U.teleport(game, mapId, 1, 1, "down")
    settled()
    local ow = game.overworld
    local cell
    for y = 0, (ow.map.def.height or 0) * 2 do
      for x = 0, (ow.map.def.width or 0) * 2 do
        if ow.map:isGrassCell(x, y) then cell = { x, y } break end
      end
      if cell then break end
    end
    say(("  %s: grass at %s"):format(mapId, cell and (cell[1] .. "," .. cell[2]) or "none"))
    if not cell then return nil end
    U.teleport(game, mapId, cell[1], cell[2], "down")
    settled()
    ow = game.overworld
    do
      local p, r = ow.player, ow.runner
      local hits = 0
      for _ = 1, 50 do if ow:rollEncounter(game.data.encounters[mapId], "grass") then hits = hits + 1 end end
      say(("  at %s,%s grass=%s running=%s moves=%s engaging=%s emote=%s tp=%s rolls=%d/50 top=%s"):format(
        p.cellX, p.cellY, tostring(ow.map:isGrassCell(p.cellX, p.cellY)), tostring(r and r:isRunning()),
        tostring(#(ow.scriptMoves or {})), tostring(ow.engaging), tostring(ow.emote), tostring(ow.teleportOut),
        hits, tostring(top() == ow)))
    end
    for _ = 1, 400 do
      ow.wildEncounterGraceSteps = 0
      ow:onStepComplete()
      U.wait(1)
      local s = api:snapshot()
      if s or inBattle() or top() ~= ow then
        for _ = 1, 600 do
          s = api:snapshot()
          if s and s.enemy and s.enemy.species then return s.enemy.species end
          U.wait(1)
        end
      end
    end
    return nil
  end

  -- 1. Route 1's first encounter: no items, but the ball catches it
  local vanillaRoute1 = {}
  for _, slot in ipairs(game.data.encounters.ROUTE_1.grass.slots) do
    vanillaRoute1[plan.species[slot.species]] = slot.species
  end
  local foe = encounter("ROUTE_1")
  if not check(foe ~= nil, "a real Route 1 encounter starts") then return finish() end
  check(vanillaRoute1[foe] ~= nil, ("it is a randomized Route 1 species: %s (vanilla %s)")
    :format(tostring(foe), tostring(vanillaRoute1[foe])))
  local step, mark = "potion", #seen
  local result = play({
    menu = function()
      submit({ kind = "menu", choice = "item" })
    end,
    bag = function(list)
      if step == "potion" then
        step = "ball"
        pickItem(list, "POTION")
      elseif step == "ball" then
        step = "done"
        pickItem(list, "MASTER_BALL")
      else
        U.tap(game, "b")
      end
    end,
    yes = function() return false end,     -- no nickname
  })
  check(said("NO ITEMS IN BATTLE", mark) ~= nil and inv("POTION") == 3, "the POTION is refused in battle")
  check(partyPickers == 0, "at once, without asking for a target first")
  check(result == "caught" and #game.save.party == 2 and game.save.party[2].species == foe,
    "the MASTER BALL catches it: " .. tostring(result))
  check(Modes.state(game.save).areas.ROUTE_1 == foe, "Route 1 is used up")

  -- 2. Route 1 again: the ball is refused; run
  local foe2 = encounter("ROUTE_1")
  mark = #seen
  step = "ball"
  local before = inv("MASTER_BALL")
  result = play({
    menu = function()
      if step == "ball" then submit({ kind = "menu", choice = "item" })
      else submit({ kind = "menu", choice = "run" }) end
    end,
    bag = function(list)
      if step == "ball" then step = "run"; pickItem(list, "MASTER_BALL")
      else U.tap(game, "b") end
    end,
  })
  check(foe2 and said("ALREADY HAD YOUR ENCOUNTER", mark) ~= nil and inv("MASTER_BALL") == before,
    "a second Route 1 encounter (" .. tostring(foe2) .. ") can't be caught; the ball is kept")
  check(result == "run" and #game.save.party == 2, "the player runs: " .. tostring(result))

  -- 3. a death that isn't a wipe: the caught Pokémon leads with 1 HP and only GROWL,
  -- faints, and the player runs instead of sending MEWTWO out
  local caught = game.save.party[2]
  caught.hp = 1
  caught.moves = { { id = "GROWL", pp = 40 } }
  setParty({ caught, mewtwo })
  local expBefore = mewtwo.exp
  local foe3 = encounter("ROUTE_22")
  mark = #seen
  result = play({
    menu = function(s)
      submit({ kind = "menu", choice = "fight" })
    end,
    move = function(s)
      return (s.player and s.player.species == "MEWTWO") and 1 or 1
    end,
    switchTo = function() return 2 end,
    -- "Use next POKéMON?" NO: in a wild battle that runs (MEWTWO stays fit)
    yes = function() return false end,
  }, 12000)
  -- NO runs; a failed run forces the switch to MEWTWO, who wins
  check(foe3 ~= nil and (result == "run" or result == "win") and said("fainted", mark) ~= nil,
    "Route 22: the lead faints, the battle goes on to its end: " .. tostring(result))
  clearTexts()
  check(#game.save.party == 1 and game.save.party[1] == mewtwo,
    "the fainted Pokémon is gone from the party")
  local grave = Modes.state(game.save).graveyard
  check(grave[#grave] and grave[#grave].species == caught.species, "and is in the graveyard")
  check(said("GONE FOR GOOD", mark) ~= nil, "with a goodbye")

  -- 3b. the Safari Zone: its own ball menu follows the same rule
  game.save.safari = { balls = 30, steps = 500 }
  mewtwo.hp = mewtwo.stats.hp
  setParty({ mewtwo })
  local function safariBattle(throw)
    local foe = encounter("SAFARI_ZONE_CENTER")
    local m = #seen
    local balls = game.save.safari and game.save.safari.balls
    local thrown = false
    local r = play({
      menu = function(s)
        if s.prompt == "safari" then
          if throw and not thrown then thrown = true; submit({ kind = "safari", action = "ball" })
          else submit({ kind = "safari", action = "run" }) end
        end
      end,
      yes = function() return false end,
    }, 8000)
    return foe, r, m, balls
  end
  -- the play loop sends the safari prompt to policy.menu
  local foeS, resS, markS = safariBattle(true)
  check(foeS ~= nil and Modes.state(game.save).areas.SAFARI_ZONE_CENTER ~= nil,
    "a Safari Zone encounter uses the area up: " .. tostring(foeS) .. " (" .. tostring(resS) .. ")")
  local foeS2, resS2, markS2, ballsBefore = safariBattle(true)
  check(foeS2 ~= nil and said("ALREADY HAD", markS2) ~= nil,
    "the next one there refuses the SAFARI BALL")
  check(game.save.safari == nil or game.save.safari.balls == ballsBefore,
    "without spending it")
  game.save.safari = nil

  -- 3c. a static Pokémon (Snorlax's script row) and a fishing bite are shuffled too
  U.teleport(game, "ROUTE_12", 10, 60, "down")
  settled()
  game.overworld.runner:run({ { "static_battle", "SNORLAX", 30, "EVENT_G1O_TEST_STATIC" } })
  local static
  for _ = 1, 600 do
    local snap = api:snapshot()
    if snap and snap.enemy and snap.enemy.species then static = snap.enemy.species break end
    U.wait(1)
  end
  check(static ~= nil and static == plan.species.SNORLAX,
    ("Snorlax's static battle is a %s (the seed says %s)"):format(tostring(static), tostring(plan.species.SNORLAX)))
  play({ menu = function() submit({ kind = "menu", choice = "run" }) end }, 6000)
  clearTexts()
  local bite = ModRuntime.call("encounter.fishing", function() return { species = "MAGIKARP", level = 5 } end,
    "OLD_ROD", "ROUTE_12", nil)
  check(bite and bite.species == plan.species.MAGIKARP and bite.level == 5,
    "an OLD ROD bite is a " .. tostring(bite and bite.species))

  -- 4. Brock, fought for real: SET style, his shuffled badge slot
  U.teleport(game, "PEWTER_GYM", 4, 3, "up")
  settled()
  local brock
  for _, e in ipairs(game.overworld.entities or {}) do
    if e.def and e.def.trainerClass == "OPP_BROCK" then brock = e end
  end
  local slot = plan.gyms["OPP_BROCK#1"]
  if check(brock ~= nil and slot ~= nil, "Brock is in his gym") then
    mark = #seen
    mewtwo.hp = mewtwo.stats.hp
    game.overworld:talkTo(brock)
    result = play({
      menu = function() submit({ kind = "menu", choice = "fight" }) end,
      move = function() return 1 end,
      yes = function() return false end,
    }, 12000)
    clearTexts()
    check(result == "win" and game.save.flags.EVENT_BEAT_BROCK, "Brock is beaten: " .. tostring(result))
    local name = game.data.items[slot.item].name
    check(said("received " .. name, mark) ~= nil or said(name, mark) ~= nil,
      "the badge line names his reward: " .. slot.item)
    check(inv(slot.item) > 0, "and the player has it")
    if slot.item ~= "BOULDERBADGE" then
      check(inv("BOULDERBADGE") == 0, "and no BOULDERBADGE")
    end
    check(not said("change POKéMON", mark) and not said("change POK", mark), "SET style: no switch offer")
    check(mewtwo.exp == expBefore and mewtwo.level == 70,
      "MEWTWO is over the level cap: no EXP from Brock (cap " .. Modes.levelCap() .. ")")
  end

  -- 5. a real blackout: MEWTWO alone, 1 HP, only GROWL
  mewtwo.hp = 1
  mewtwo.moves = { { id = "GROWL", pp = 40 } }
  setParty({ mewtwo })
  local runBefore = Modes.rules.runId
  local foe5 = encounter("ROUTE_2")
  mark = #seen
  result = play({
    menu = function() submit({ kind = "menu", choice = "fight" }) end,
    move = function() return 1 end,
  }, 12000)
  check(foe5 ~= nil and result == "lose", "Route 2: MEWTWO faints, the player blacks out: " .. tostring(result))
  for _ = 1, 200 do
    U.wait(5)
    clearTexts(20)
    if Modes.state(game.save).run == runBefore + 1 then break end
  end
  for _ = 1, 40 do U.wait(3); clearTexts(20) end
  check(Modes.rules.runId == runBefore + 1 and Modes.state(game.save).run == runBefore + 1,
    "the blackout ended the run: run " .. tostring(Modes.state(game.save).run))
  check(#(game.save.party or {}) == 0 and game.overworld.map.id == "REDS_HOUSE_2F",
    "a fresh start in the bedroom")
  check(said("THE RUN IS OVER", mark) ~= nil and said("BEGINS", mark) ~= nil, "with the run-over and new-run boxes")

  -- 6. a returning player: DISCONNECT, then JOIN again from the save on disk
  local run = Modes.rules.runId
  local seed = Modes.rules.seed
  game.save.party = { mon("PIKACHU", 5) }
  Modes.state(game.save).areas.ROUTE_1 = "PIDGEY"
  table.insert(Modes.state(game.save).graveyard, { species = "RATTATA", name = "RATTY", level = 3 })
  local function menuPath(...)
    U.tap(game, "start"); U.wait(10)
    for _, p in ipairs({ ... }) do choose(p) end
    clearTexts()
    for _ = 1, 20 do U.wait(3); clearTexts(10) end
    while top() and top() ~= game.overworld do game.stack:pop() end
  end
  menuPath("ONLINE", "DISCONNECT")
  check(Modes.plan() == nil and game.save.g1oModes == nil, "offline: no shuffled world, the offline save")
  mark = #seen
  menuPath("CONNECT", "^JOIN")
  local st = Modes.state(game.save)
  check(st.run == run and Modes.rules.runId == run, "back online in run " .. run .. " without a restart")
  check(not said("BEGINS", mark), "no new-run box")
  check(#game.save.party == 1 and game.save.party[1].species == "PIKACHU", "the party came back from disk")
  check(st.areas.ROUTE_1 == "PIDGEY" and #st.graveyard >= 1 and st.graveyard[#st.graveyard].name == "RATTY",
    "and so did the used areas and the fallen")
  check(Modes.plan() and Modes.plan().seed == seed, "the run's world is shuffled again")

  -- 7. a save from an older run (a server that just turned the modes on) restarts
  st.run = run - 1
  menuPath("ONLINE", "DISCONNECT")
  mark = #seen
  menuPath("CONNECT", "^JOIN")
  for _ = 1, 40 do U.wait(3); clearTexts(20) end
  check(Modes.state(game.save).run == run and #(game.save.party or {}) == 0,
    "an online save from another run starts this one over")
  check(said("BEGINS", mark) ~= nil, "with the new-run box")

  return finish()
end
