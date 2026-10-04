-- Real Crystal boot, offline: the mod loads, the true-color follower walks
-- behind the player and talks on A, and no wild Pokemon roam the overworld.
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
  local f = Follower.current(world)
  check(f and f.sprite and Follower.SPRITE == "FOLLOWER_CYNDAQUIL", "Cyndaquil follower present")
  local p = world.player
  local dir = (f.cellY < p.cellY and "up") or (f.cellY > p.cellY and "down")
    or (f.cellX < p.cellX and "left") or "right"
  U.tap(game, dir); U.wait(8)
  U.tap(game, "a"); U.wait(20)
  local TextBox = require("src.render.TextBox")
  local s = game.stack:top()
  local text = ""
  if s and getmetatable(s) == TextBox then
    local function walk(v)
      if type(v) == "string" then text = text .. " " .. v
      elseif type(v) == "table" then for _, x in ipairs(v) do walk(x) end end
    end
    walk(s.pages)
  end
  check(text:find("CYNDAQUIL") ~= nil, "follower talks:" .. text)
  U.shot(game, out .. "/50_follower_talk.png")
  local closed = false
  for _ = 1, 60 do
    U.tap(game, "a"); U.wait(6)
    if game.stack:top() == nil then closed = true break end
  end
  check(closed and not f.frozen, "text closes and the follower is released")

  world:setMap("ROUTE_29", 50, 8, "left")
  U.wait(240)
  local wild = 0
  for _, n in ipairs(world.npcs or {}) do if n.isWildMon then wild = wild + 1 end end
  check(wild == 0, "no wild Pokemon roam the overworld")
  U.shot(game, out .. "/51_route29.png")

  say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
  love.event.quit(fails == 0 and 0 or 1)
  U.wait(5)
end
