-- Real FireRed / LeafGreen on a server whose server_config.txt turns the
-- optional modes on (randomizer, wild_legendaries = 100, randomize_trainers
-- = on, crazy_randomizer = on, seed 4242; no Nuzlocke) and game_speed = 1.5:
-- the settings travel from the server's file to the game, not pinned in the
-- driver.
--   offline a level-5 HO-OH knows WHIRLWIND alone -> the rules view has the
--   options, the game runs at 1.5X with the player's own GAME SPEED locked,
--   a text page shows whole at once -> the crazy movesets: HO-OH at level 5
--   gets four of its whole level-up list, and a gift CHARIZARD too -> a wild
--   Pokémon on Route 1 is a legendary at its own level, with four of its
--   level-up moves -> a real Viridian Forest trainer, talked to, sends out
--   the seed's team for his (vanilla levels) with the seed's moves, and is
--   beaten, the battle at 1.5X -> DISCONNECT: the player's own speed again,
--   the text still instant, HO-OH's vanilla moves again.
local U = require("tests.drivers.util")

return function(game)
  local H = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_util.lua")(game, "gen3_options")
  local say, check, finish, shot = H.say, H.check, H.finish, H.shot
  if not H.boot() then return finish() end
  local G3, GtsUI = H.G3, H.GtsUI
  local Runtime = require("src.core.game3.runtime")
  local Party = require("src.core.game3.party")
  local Pokemon = require("src.core.game3.pokemon")
  local Battle = require("src.core.game3.battle")
  local BattleBridge = require("src.core.game3.battle_bridge")
  local BattleAPI = require("src.battle.game3.BattleAPI")
  local Trainers = require("src.core.game3.scripting.trainers")
  local Space = require("src.core.game3.scripting.space")
  local Choice = require("src.ui.game3.choice")
  local Message = require("src.ui.game3.message")
  local Modes = GtsUI.Modes

  local function moveNames(list)
    local out = {}
    for i, m in ipairs(list or {}) do out[i] = Pokemon.moveName(m) end
    return table.concat(out, ", ")
  end
  -- the crazy randomizer's moves: four (or the whole pool), distinct, all
  -- from the Pokémon's level-up list
  local function crazyMoves(species, moves)
    local pool, inPool, seen = Modes.movePool(species), {}, {}
    for _, m in ipairs(pool) do inPool[m] = true end
    local ok = #pool > 0 and #(moves or {}) == math.min(4, #pool)
    for _, m in ipairs(moves or {}) do
      m = tonumber(m)
      if not inPool[m] or seen[m] then ok = false end
      if m then seen[m] = true end
    end
    return ok
  end
  local HO_OH = 250

  H.newOffline("OFFLINE")
  local vanillaHoOh = { Pokemon.movesAtLevel(HO_OH, 5) }
  vanillaHoOh = vanillaHoOh[1] or {}
  check(#vanillaHoOh == 1 and vanillaHoOh[1] == 18, "offline a level-5 HO-OH knows " .. moveNames(vanillaHoOh))
  if not check(H.createPlayer("ASH", "^RED$"), "online as a new character") then return finish() end
  H.clearTexts()
  H.closeAll()
  local r = Modes.rules or {}
  local info = H.get("/server/info") or {}
  check(r.randomizer and r.wildLegendaries == 100 and r.trainers == "on" and r.starters
    and r.crazy == true and r.nuzlocke == "off",
    ("the server's file reached the game: legendaries %s%%, trainers %s, starters %s, crazy %s")
      :format(tostring(r.wildLegendaries), tostring(r.trainers), tostring(r.starters), tostring(r.crazy)))
  check(info.rules and info.rules.wildLegendaries == 100 and info.rules.trainers == "on",
    "and /server/info says the same")

  -- the host's game_speed: the whole game at 1.5X, the player's own GAME
  -- SPEED rows and hotkeys locked
  check(info.gameSpeed == 1.5 and GtsUI.onlineSpeed == 1.5,
    ("the server's game speed reached the game: %sX"):format(tostring(GtsUI.onlineSpeed)))
  check(game:logicSpeed() == 1.5 and game:speedLocked() == true,
    ("the game runs at %sX online, the player's own speed locked"):format(tostring(game:logicSpeed())))
  -- instant text (other/instant_text.lua): a page shows whole on its first tick
  local function instantPage(text)
    Message.show(text)
    Message.tick()
    local whole = Message._total > 0 and Message._revealed == Message._total and Message.isWaiting()
    Message.close()
    return whole
  end
  check(instantPage("THIS WHOLE LINE SHOWS AT ONCE.\nAND THIS ONE TOO."), "a text page shows whole at once")

  -- the crazy movesets: a new Pokémon gets four of its whole level-up list
  local pool = Modes.movePool(HO_OH)
  local drawsOk, ppOk, union, unionCount = true, true, {}, 0
  for _ = 1, 40 do
    local moves, pp, maxPp = Pokemon.movesAtLevel(HO_OH, 5)
    if not crazyMoves(HO_OH, moves) then drawsOk = false end
    for i, m in ipairs(moves or {}) do
      if pp[i] ~= Pokemon.movePp(m) or maxPp[i] ~= pp[i] then ppOk = false end
      if not union[m] then union[m], unionCount = true, unionCount + 1 end
    end
  end
  say("HO-OH's level-up list (HMs out): " .. moveNames(pool))
  check(drawsOk and ppOk, "online a level-5 HO-OH gets four of them, with their PP: "
    .. moveNames((Pokemon.movesAtLevel(HO_OH, 5))))
  check(unionCount == #pool, ("and 40 draws use the whole list (%d of %d moves)"):format(unionCount, #pool))
  local s = Runtime.getSession()
  local _, _, zard = Party.giveMon(s, 6, 60)      -- CHARIZARD, to win with
  check(zard and crazyMoves(6, zard.moves), "a gift CHARIZARD gets four of its level-up moves: "
    .. moveNames(zard and zard.moves))
  if zard then  -- FLAMETHROWER first, for the fights below
    zard.moves[1], zard.pp[1], zard.maxPp[1] = 53, 15, 15
  end

  -- a wild Pokémon on Route 1: a legendary, at its own level
  G3.warpTo("ROUTE_1", 10, 20, "down")
  for _ = 1, 300 do if G3.currentMap() == "FR_ROUTE_1" and H.fieldFree() then break end U.wait(2) end
  local legends = select(2, Modes.speciesData())
  BattleBridge.startWild(nil, game, { species = 16, level = 4 }, {})
  local st
  for _ = 1, 600 do
    st = Battle.isActive() and Battle.getState()
    if st and st.enemy and st.enemy.mon then break end
    U.wait(2)
  end
  local wildMon = st and st.enemy and st.enemy.mon
  local wsp = wildMon and tonumber(wildMon.species)
  check(wsp and legends[wsp] and wildMon.level == 4, "a wild PIDGEY roll on Route 1 is a legendary: "
    .. tostring(wsp and Pokemon.name(wsp)) .. " LV" .. tostring(wildMon and wildMon.level))
  check(wsp and crazyMoves(wsp, wildMon.moves), "with four of its level-up moves: "
    .. moveNames(wildMon and wildMon.moves))
  U.wait(150)
  shot("wild_legendary")
  Battle.abort("run")
  for _ = 1, 600 do if not Battle.isActive() then break end U.wait(2) end
  H.fieldFree()

  -- a real trainer in Viridian Forest, talked to
  local MAP = "FR_VIRIDIAN_FOREST"
  local scripts = Space.ensureBundle().scripts
  local trainerObj, tid
  for _, o in ipairs(G3.raw().data.maps[MAP].objects or {}) do
    local rows = o.scriptKey and scripts[o.scriptKey]
    local first = rows and rows[1]
    if first and first.op == "trainerbattle" and tonumber(first.type) == 0 and not tid then
      trainerObj, tid = o, tonumber(first.trainer)
    end
  end
  if not check(trainerObj ~= nil, "a single-battle trainer in Viridian Forest (#" .. tostring(tid) .. ")") then
    return finish()
  end
  local vanilla, levels = {}, {}
  for i, m in ipairs((Trainers.get(tid) or {}).party or {}) do
    vanilla[i], levels[i] = tonumber(m.species), tonumber(m.level)
  end
  local want = Modes.trainerTeam(tid, vanilla, MAP)
  check(H.talkTo(MAP, trainerObj.x, trainerObj.y), "walked up to him and pressed A")
  for _ = 1, 900 do
    if Battle.isActive() then break end
    if Message.isOpen() then U.tap(game, "a") end
    U.wait(2)
  end
  check(Battle.isActive(), "his battle began")
  local foe = (Battle.getState() or {}).foeParty or {}
  local got, names, sameLevels = {}, {}, #foe == #vanilla
  for i, m in ipairs(foe) do
    got[i] = tonumber(m.species or m.speciesId)
    names[i] = (got[i] and Pokemon.name(got[i]) or "?") .. " LV" .. tostring(m.level)
    if tonumber(m.level) ~= levels[i] then sameLevels = false end
  end
  local vanillaNames = {}
  for i, sp in ipairs(vanilla) do vanillaNames[i] = Pokemon.name(sp) end
  check(want and table.concat(got, ",") == table.concat(want, ","),
    ("his team is the seed's draw: %s (vanilla %s)"):format(table.concat(names, ", "), table.concat(vanillaNames, ", ")))
  check(sameLevels, "at his own levels")
  local movesOk, moveText = #foe > 0, {}
  for i, m in ipairs(foe) do
    local seeded = Modes.trainerMoves(tid, i, got[i])
    if not (crazyMoves(got[i], m.moves) and table.concat(m.moves or {}, ",") == table.concat(seeded or {}, ",")) then
      movesOk = false
    end
    moveText[i] = moveNames(m.moves)
  end
  check(movesOk, "with the seed's moves, four of each one's level-up list: " .. table.concat(moveText, " / "))
  local api0 = BattleAPI.new(game)
  for _ = 1, 600 do
    local snap = api0:snapshot()
    if snap and snap.prompt == "menu" then break end
    if snap and snap.prompt == "advance" then U.tap(game, "a") end
    U.wait(2)
  end
  shot("route_trainer")
  local api, intent = BattleAPI.new(game), 0
  local speeds = {}
  for _ = 1, 6000 do
    if not Battle.isActive() then break end
    speeds[tostring(game:logicSpeed())] = true
    local snap = api:snapshot()
    if snap and (snap.prompt == "menu" or snap.prompt == "moves") then
      intent = intent + 1
      api:submit({ id = intent, revision = snap.revision, kind = snap.prompt == "menu" and "menu" or "move",
        choice = "fight", slot = 1 })
    elseif Choice.active then U.tap(game, "b")
    else U.tap(game, "a") end
    U.wait(2)
  end
  check(not Battle.isActive(), "and beaten")
  local seen = {}
  for k in pairs(speeds) do seen[#seen + 1] = k end
  check(#seen == 1 and seen[1] == "1.5", "the whole battle ran at 1.5X: " .. table.concat(seen, ", "))
  H.clearTexts()
  check(H.fieldFree(), "back in the forest")

  -- offline again: the player's own GAME SPEED, and the text still instant
  H.closeAll()
  H.startItem("gen1online")
  H.choose("DISCONNECT")
  H.clearTexts()
  check(not H.online(), "disconnected")
  check(game:logicSpeed() == 1 and not game:speedLocked(),
    ("offline: the player's own speed again (%sX), unlocked"):format(tostring(game:logicSpeed())))
  check(instantPage("OFFLINE TOO, A PAGE\nSHOWS WHOLE AT ONCE."), "and offline a text page still shows whole")
  local after = (Pokemon.movesAtLevel(HO_OH, 5))
  check(table.concat(after or {}, ",") == table.concat(vanillaHoOh, ","),
    "and a level-5 HO-OH knows " .. moveNames(after) .. " again")
  return finish()
end
