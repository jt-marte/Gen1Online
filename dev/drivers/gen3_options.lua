-- Real FireRed / LeafGreen on a server whose server_config.txt turns the
-- optional modes on (randomizer, wild_legendaries = 100, randomize_trainers
-- = on, seed 4242; no Nuzlocke): the settings travel from the server's file
-- to the game, not pinned in the driver.
--   the rules view has them -> a wild Pokémon on Route 1 is a legendary at
--   its own level -> a real Viridian Forest trainer, talked to, sends out the
--   seed's team for his (vanilla levels) and is beaten.
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

  H.newOffline("OFFLINE")
  if not check(H.createPlayer("ASH", "^RED$"), "online as a new character") then return finish() end
  H.clearTexts()
  H.closeAll()
  local r = Modes.rules or {}
  local info = H.get("/server/info") or {}
  check(r.randomizer and r.wildLegendaries == 100 and r.trainers == "on" and r.starters
    and r.nuzlocke == "off", ("the server's file reached the game: legendaries %s%%, trainers %s, starters %s")
      :format(tostring(r.wildLegendaries), tostring(r.trainers), tostring(r.starters)))
  check(info.rules and info.rules.wildLegendaries == 100 and info.rules.trainers == "on",
    "and /server/info says the same")
  local s = Runtime.getSession()
  Party.giveMon(s, 6, 60)      -- CHARIZARD, to win with

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
  local api0 = BattleAPI.new(game)
  for _ = 1, 600 do
    local snap = api0:snapshot()
    if snap and snap.prompt == "menu" then break end
    if snap and snap.prompt == "advance" then U.tap(game, "a") end
    U.wait(2)
  end
  shot("route_trainer")
  local api, intent = BattleAPI.new(game), 0
  for _ = 1, 6000 do
    if not Battle.isActive() then break end
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
  H.clearTexts()
  check(H.fieldFree(), "back in the forest")
  return finish()
end
