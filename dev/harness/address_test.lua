-- Typing the server address in-game (START > CONNECT > SERVER ADDRESS), on
-- Crystal (the default) and on Gen 1 (G1O_GAME=yellow).  gts_config.txt
-- points at a dead port, as a friend's untouched install would; the player
-- types the real server, connects, and the typed address outlives the
-- config file until USE CONFIG FILE.  Run against dev/server.sh.
local Rig = dofile(os.getenv("G1O_DEV") .. "/harness/rig.lua")
local PORT = os.getenv("GTS_PORT") or "17781"
Rig.overrides["gts_config.txt"] = "server_url=http://127.0.0.1:1\n"

local fails = 0
local function check(cond, label)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then fails = fails + 1 end
  return cond
end

local game = Rig.newGame()
if Rig.generation == 1 then
  -- the Gen 1 naming screen pops itself, then calls onDone
  require("src.ui.NamingScreen").new = function(g, opts)
    local stub = { naming = true, opts = opts }
    function stub.finish(name) g.stack:pop(); opts.onDone(name, true) end
    return stub
  end
end
local ok, err = Rig.load(game)
check(ok, "loader:load completes on " .. Rig.gameId .. " (" .. tostring(err) .. ")")

local TextBox = require("src.render.TextBox")
local function top() return game.stack:top() end
local function textOf(s)
  local out = {}
  local function walk(v)
    if type(v) == "string" then out[#out + 1] = v
    elseif type(v) == "table" then for _, x in ipairs(v) do walk(x) end end
  end
  walk(s and (s.pages or s.text))
  return table.concat(out, " ")
end
local function labels(s)
  local l = {}
  for _, it in ipairs((s and s.items) or {}) do l[#l + 1] = tostring(it.label) end
  return table.concat(l, " | ")
end
local function pick(pattern)
  for _, it in ipairs((top() and top().items) or {}) do
    if tostring(it.label):find(pattern) then
      game.stack:pop()
      if it.onSelect then it.onSelect() end
      return true
    end
  end
  error("no item '" .. pattern .. "' in " .. labels(top()), 2)
end
local function closeText()
  local s = top()
  if not (s and getmetatable(s) == TextBox) then return nil end
  game.stack:pop()
  if s.onDone then s.onDone() end
  return textOf(s)
end
local function connectMenu()
  while top() and top() ~= Rig.world(game) do game.stack:pop() end
  local list = Rig.hook("ui.start_menu.items", function(g, l) return l end, game, {})
  for _, it in ipairs(list) do if it.label == "CONNECT" then it.onSelect() end end
  return top()
end
-- a key through the engine's input.key hook, the way a keyboard reaches it
local function key(k)
  Rig.hook("input.key", function() end, game, { phase = "pressed", key = k })
end
-- a controller button through the game's input, seen on the next update
local function button(b)
  game.input:press(b)
  top():update(1 / 60)
end
local function storedUrl()
  for path, contents in pairs(Rig.writes) do
    if path:match("gts_server_url") then return contents end
  end
end

-- one frame, so the mod knows the live game (typed text is routed through it)
Rig.hook("core.update", function() end, game, 1 / 60)

-- ---- the CONNECT menu ------------------------------------------------------------
local menu = connectMenu()
check(labels(menu):find("^JOIN 127%.0%.0%.1:1 | SERVER ADDRESS | CANCEL$") ~= nil,
  "CONNECT opens JOIN / SERVER ADDRESS / CANCEL: " .. labels(menu))

-- JOIN with the config file's dead server: say so and offer the address
pick("^JOIN")
local said = closeText() or ""
check(said:find("COULDN'T REACH THE SERVER AT 127%.0%.0%.1:1") ~= nil, "unreachable server is reported: " .. said)
local screen = top()
check(screen and screen.gtsTextInput and screen.buffer == "", "the address screen opens after it")
check(game.save.onlineAccount == nil, "nothing changed in the offline game")

-- ---- typing: keyboard and controller ---------------------------------------------
love.textinput("192.168.1.2x3")
check(screen.buffer == "192.168.1.2X3", "typed text arrives through love.textinput, uppercased (" .. screen.buffer .. ")")
key("backspace"); key("backspace")
check(screen.buffer == "192.168.1.2", "BACKSPACE deletes")
key("z")
check(screen.buffer == "192.168.1.2" and top() == screen, "a letter key is swallowed (it types via textinput, never presses A)")
button("right")
check(screen.buffer == "192.168.1.20", "RIGHT adds a character")
button("up"); button("up"); button("up")
check(screen.buffer == "192.168.1.23", "UP steps the last character (" .. screen.buffer .. ")")
button("down")
check(screen.buffer == "192.168.1.22", "DOWN steps it back")
button("b")
check(screen.buffer == "192.168.1.2", "B deletes")

-- bad addresses keep the screen open with a reason
local function try(text)
  screen.buffer, screen.message = text, nil
  key("return")
  return top() == screen, screen.message or ""
end
for _, bad in ipairs({ "300.1.1.1", "10.0.1", "10..0.1", "HOST:99999", "" }) do
  local stays, why = try(bad)
  check(stays and why ~= "", ("'%s' is refused: %s"):format(bad, why))
end
check(storedUrl() == nil, "nothing stored yet")

-- the real server: stored, then CONNECT goes there (a fresh player is offered)
screen.buffer = "127.0.0.1:" .. PORT
button("a")
check(storedUrl() and storedUrl():find("http://127%.0%.0%.1:" .. PORT, 1) ~= nil,
  "the typed address is stored as a full URL (" .. tostring(storedUrl()) .. ")")
check(labels(top()):find("CREATE NEW PLAYER") ~= nil, "OK connects to it: " .. labels(top()))

-- ---- the typed server wins over gts_config.txt, until USE CONFIG FILE ---------------
menu = connectMenu()
check(labels(menu):find("^JOIN SERVER | SERVER ADDRESS | USE CONFIG FILE | CANCEL$") ~= nil,
  "the menu now joins the typed server and offers the config file: " .. labels(menu))
pick("SERVER ADDRESS")
check(top() and top().gtsTextInput and (top().current or ""):find("127.0.0.1:" .. PORT, 1, true),
  "the address screen shows the current server (" .. tostring(top() and top().current) .. ")")
key("escape")
check(not (top() and top().gtsTextInput), "ESC leaves the screen")
menu = connectMenu()
pick("USE CONFIG FILE")
local back = closeText() or ""
check(back:find("127%.0%.0%.1:1") ~= nil and storedUrl() == nil, "USE CONFIG FILE forgets the typed one: " .. back)
menu = connectMenu()
check(labels(menu):find("^JOIN 127%.0%.0%.1:1 |") ~= nil and not labels(menu):find("CONFIG"),
  "and the menu is back to the config file's server")

Rig.dump("server address")
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
