-- Real Crystal boot, offline: the mod loads, no Pokemon follows the player
-- (Crystal has no follower, and the mod adds none), and no wild Pokemon roam
-- the overworld.
local U = require("tests.drivers.util")
local Mon = require("src.battle.gen2.Mon")
local ModRuntime = require("src.mods.Runtime")

return function(game)
  local out = os.getenv("SHOTS") or "/tmp/gen1online-shots"
  local fails = 0
  local function say(...) print("[g1o]", ...) end
  local function check(cond, label)
    say((cond and "PASS " or "FAIL ") .. label)
    if not cond then fails = fails + 1 end
  end
  local Game2 = require("src.core.Game2")
  local realUpdate = Game2.update
  game.update = function(self, dt)
    return ModRuntime.call("core.update", function(g, d) return realUpdate(g, d) end, self, dt)
  end

  U.wait(60)
  local world = game.world
  check(game.mods and game.mods.exports and game.mods.exports["gen1online-plus"] ~= nil, "gen1online-plus loaded")
  game.save.party = { Mon.new(game.data, "CYNDAQUIL", 12) }
  U.wait(60)
  for _ = 1, 2 do U.hold(game, "down", 18); U.wait(6) end
  local Follower = require("src.world.gen2.Follower")
  local followers = 0
  for _, n in ipairs(world.npcs or {}) do if n.follower then followers = followers + 1 end end
  check(Follower.current(world) == nil and followers == 0, "no follower behind the player")
  U.shot(game, out .. "/50_no_follower.png")

  world:setMap("ROUTE_29", 50, 8, "left")
  U.wait(240)
  local wild = 0
  for _, n in ipairs(world.npcs or {}) do if n.isWildMon then wild = wild + 1 end end
  check(wild == 0, "no wild Pokemon roam the overworld")
  check(Follower.current(world) == nil, "still no follower after a map change")
  U.shot(game, out .. "/51_route29.png")

  say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
  love.event.quit(fails == 0 and 0 or 1)
  U.wait(5)
end
