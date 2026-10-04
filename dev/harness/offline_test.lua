-- Offline: the mod installed, never connected.  Vanilla Crystal must keep
-- working and nothing online may run.
local Rig = dofile(os.getenv("G1O_DEV") .. "/harness/rig.lua")
local fails = 0
local function check(cond, label)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then fails = fails + 1 end
end

local game = Rig.newGame()
local world = game.world
local ok, err = Rig.load(game)
check(ok, "loader:load completes (" .. tostring(err) .. ")")
for _, e in ipairs(Rig.loader:status().errors or {}) do
  check(false, "load error: " .. tostring(type(e) == "table" and (e.reason or e.message) or e))
end
Rig.dump("load")

local stepErr
for _ = 1, 180 do
  local okF, e = pcall(Rig.hook, "core.update", function(g) g.world:step() end, game, 1 / 60)
  if not okF then stepErr = stepErr or e end
end
check(stepErr == nil, "180 offline frames of core.update + World:step (" .. tostring(stepErr) .. ")")
check(game.options.speed == 3, "player's GAME SPEED option untouched offline")
check(game.save.onlineAccount == nil, "offline save carries no online account")
Rig.dump("frames")

local items = Rig.hook("ui.start_menu.items", function(g, list) return list end, game,
  { { label = "POKEDEX" }, { label = "SAVE", value = "save" }, { label = "OPTION" } })
local hasConnect, hasSave = false, false
for _, it in ipairs(items or {}) do
  if it.label == "CONNECT" then hasConnect = true end
  if it.label == "SAVE" then hasSave = true end
end
check(hasConnect, "start menu offers CONNECT")
check(hasSave, "offline start menu keeps SAVE")

local pc = Rig.hook("ui.pc.items", function(g, list) return list end, game,
  { { id = "items", label = "ITEM STORAGE" }, { id = "decoration", label = "DECORATION" } })
local hasGts = false
for _, it in ipairs(pc or {}) do if it.id == "gts" then hasGts = true end end
check(hasGts, "bedroom PC offers GTS")

local Gen2Save = require("src.core.gen2.Save")
local wrote, werr = Gen2Save.save(game.save)
check(wrote == true, "offline Save.save writes the normal save (" .. tostring(werr) .. ")")
local normal, online = false, false
for path in pairs(Rig.writes) do
  if path:match("crystal") and not path:match("mod_compat") then normal = true end
  if path:match("save_online") then online = true end
end
check(normal, "the normal crystal save landed on disk")
check(not online, "nothing was written to the online save")
Rig.dump("save")

-- an A press on a vanilla NPC still reaches the engine
do
  local NPC = require("src.world.gen2.Npc")
  local Vm = require("src.script.gen2.Vm")
  local log = {}
  world.vm = Vm.new({ ["00:1"] = { { op = "jumptextfaceplayer", text = "00:2" } } },
    { ["00:2"] = "Hello there." }, world.events, {
      showText = function(body, onDone) log[#log + 1] = body; if onDone then onDone() end end,
      facePlayer = function() end, showEmote = function() end,
    })
  local npc = setmetatable({
    def = { index = 3, sprite = "SPRITE_TEACHER", movement = 6, scriptKey = "00:1" },
    id = "npc_3", cellX = 6, cellY = 7, homeX = 6, homeY = 7, px = 96, py = 112,
    facing = "up", moving = false, progress = 0, stepFlip = false, frozen = false,
    kind = "stand", roamDirs = { "up" }, radiusX = 0, radiusY = 0, spinLo = 1,
    spinHi = 1, timer = 1,
  }, NPC)
  world.npcs, world.entities = { npc }, { world.player, npc }
  world.player.facing = "down"
  local okI, eI = pcall(world.interact, world)
  check(okI, "World:interact with the mod's patches (" .. tostring(eI) .. ")")
  check(log[1] == "Hello there.", "vanilla NPC text still prints")
  Rig.dump("interact")
end

-- no overworld wild Pokemon: encounters stay in the tall grass
do
  world.npcs, world.entities = {}, { world.player }
  world.map = Rig.fakeMap("ROUTE_29")
  world.maps = { ROUTE_29 = world.map.def }
  for _ = 1, 240 do
    pcall(Rig.hook, "core.update", function(g) g.world:step() end, game, 1 / 60)
  end
  local wild = 0
  for _, n in ipairs(world.npcs) do if n.isWildMon then wild = wild + 1 end end
  check(wild == 0, "no wild Pokemon roam the overworld")
  local okD, eD = pcall(world.drawPeople, world, 2)
  check(okD, "World:drawPeople with the mod's wrapper (" .. tostring(eD) .. ")")
  Rig.dump("route")
end

print("---- legacy calls (sandbox compat paths the mod still takes)")
for _, row in ipairs(Rig.loader:legacyReport("gen1online-plus")) do
  print(("  %s x%d"):format(row.call, row.count))
end
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
