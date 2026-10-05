-- One generation per server: a game's CONNECT to a server hosting the other
-- generation's world is turned away before anything changes.  Run it as
-- Crystal against a Gen 1 server (GTS_GENERATION=1 dev/server.sh), and as a
-- Gen 1 game (G1O_GAME=red) against a Crystal one (GTS_GENERATION=2).
local Rig = dofile(os.getenv("G1O_DEV") .. "/harness/rig.lua")
local PORT = os.getenv("GTS_PORT") or "17781"
Rig.overrides["gts_config.txt"] = "server_url=http://127.0.0.1:" .. PORT .. "\n"
local fails = 0
local function check(cond, label)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then fails = fails + 1 end
end

local game = Rig.newGame()
local offlineName = game.save.player.name
local ok, err = Rig.load(game)
check(ok, "loader:load completes on " .. Rig.gameId .. " (" .. tostring(err) .. ")")

local TextBox = require("src.render.TextBox")
local function textOf(s)
  local out = {}
  local function walk(v)
    if type(v) == "string" then out[#out + 1] = v
    elseif type(v) == "table" then for _, x in ipairs(v) do walk(x) end end
  end
  walk(s and (s.pages or s.text))
  return table.concat(out, " ")
end

local items = Rig.hook("ui.start_menu.items", function(g, l) return l end, game, {})
for _, it in ipairs(items) do if it.label == "CONNECT" then it.onSelect() end end
-- CONNECT opens the server menu; JOIN connects
for _, it in ipairs((game.stack:top() or {}).items or {}) do
  if tostring(it.label):find("^JOIN") then game.stack:pop(); it.onSelect() break end
end
local top = game.stack:top()
local text = (top and getmetatable(top) == TextBox) and textOf(top) or tostring(top)
local other = Rig.generation == 1 and "GEN 2 %(CRYSTAL%)" or "GEN 1 %(RED, BLUE AND YELLOW%)"
check(text:find("THIS SERVER IS A " .. other .. " WORLD") ~= nil, "CONNECT is turned away: " .. text)
check(game.save.player.name == offlineName and game.save.onlineAccount == nil, "the offline game is untouched")
local wrote = false
for path in pairs(Rig.writes) do if path:match("save_online") or path:match("online_account") then wrote = true end end
check(not wrote, "no online save or account was written")
Rig.dump("wrong world")
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
