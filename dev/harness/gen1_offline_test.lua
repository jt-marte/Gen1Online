-- Gen 1 offline (G1O_GAME=red, blue or yellow): the mod installed, never
-- connected.  Vanilla Red/Blue/Yellow must keep working, nothing online may
-- run, and the parts that would change the vanilla game stay off: the
-- casino (Game Corner clerks, coin cap) and Yellow's own Pikachu follower.
local Rig = dofile(os.getenv("G1O_DEV") .. "/harness/rig.lua")
assert(Rig.generation == 1, "run with G1O_GAME=red, blue or yellow")
local fails = 0
local function check(cond, label)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then fails = fails + 1 end
end

local game = Rig.newGame()
local world = game.overworld
local Pikachu = require("src.world.PikachuFollower")
local pikachuBefore = { talk = Pikachu.talk, SPRITE = Pikachu.SPRITE, current = Pikachu.current }
local spawnRule
local origSetShouldSpawn = Pikachu.setShouldSpawn
Pikachu.setShouldSpawn = function(fn) spawnRule = fn; return origSetShouldSpawn(fn) end

local ok, err = Rig.load(game)
check(ok, "loader:load completes on " .. Rig.gameId .. " (" .. tostring(err) .. ")")
check(Rig.loader.exports["gen1online-plus"] ~= nil, "the mod is loaded on " .. Rig.gameId)
for _, e in ipairs(Rig.loader:status().errors or {}) do
  check(false, "load error: " .. tostring(type(e) == "table" and (e.reason or e.message) or e))
end
check(#Rig.errors == 0, "no Crystal-only engine module is touched on Gen 1 (" .. #Rig.errors .. " errors)")
Rig.dump("load")

local stepErr
for _ = 1, 180 do
  local okF, e = pcall(Rig.hook, "core.update", function(g, dt)
    local t = g.stack:top()
    if t and t.update then t:update(dt) end
  end, game, 1 / 60)
  if not okF then stepErr = stepErr or e end
end
check(stepErr == nil, "180 offline frames through the overworld wrapper (" .. tostring(stepErr) .. ")")
check(world.vanillaUpdates == 180, "every frame reached the vanilla overworld update")
check(not game:speedLocked(), "no speed lock offline")
check(game.save.onlineAccount == nil, "offline save carries no online account")
Rig.dump("frames")

local items = Rig.hook("ui.start_menu.items", function(g, list) return list end, game,
  { { label = "POKEMON" }, { label = "SAVE", value = "save" }, { label = "OPTION" } })
local hasConnect, hasSave = false, false
for _, it in ipairs(items or {}) do
  if it.label == "CONNECT" then hasConnect = true end
  if it.label == "SAVE" then hasSave = true end
end
check(hasConnect, "start menu offers CONNECT")
check(hasSave, "offline start menu keeps SAVE")
local pc = Rig.hook("ui.pc.items", function(g, list) return list end, game, { { label = "WITHDRAW ITEM" } })
local hasGts = false
for _, it in ipairs(pc or {}) do if it.id == "gts" then hasGts = true end end
check(hasGts, "the PC offers GTS")

-- an A press with nobody online in front still reaches the engine
world.player.facing = "down"
check(pcall(world.interact, world) and world.vanillaInteracts == 1, "A press reaches the vanilla overworld interact")
-- talking to an NPC goes through the mod's talkTo wrapper to the game's own
local okTalk, eTalk = pcall(world.talkTo, world, { index = 1, sprite = "SPRITE_OAK" })
check(okTalk and world.vanillaTalks == 1, "talking to an NPC reaches the vanilla talkTo (" .. tostring(eTalk) .. ")")

local SaveData = require("src.core.SaveData")
local wrote = SaveData.save(game.save)
local online = false
for path in pairs(Rig.writes) do if path:match("save_online") then online = true end end
check(wrote ~= false, "offline SAVE goes through the normal save")
check(not online, "nothing was written to an online save")
Rig.dump("save")

-- the casino stays off: Celadon's Game Corner and the coin cap are vanilla
local scripts = game.data.map_scripts or {}
check(scripts.GAME_CORNER == nil, "no Game Corner scripts registered (the clerks stay vanilla)")
check((game.data.constants or {}).coinCap == nil, "the coin cap is not raised")
for _, id in ipairs({ "BlackjackCornerCrash", "BlackjackCornerTubeFlyer", "BlackjackCornerPrizeCase" }) do
  check(not (game.data.screens and game.data.screens[id]), "no casino screen " .. id)
end

-- Yellow's Pikachu follower is the game's own
check(Pikachu.talk == pikachuBefore.talk and Pikachu.SPRITE == pikachuBefore.SPRITE,
  "PikachuFollower's talk and sprite are untouched")
check(spawnRule == nil, "the mod sets no follower spawn rule on Gen 1")

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
