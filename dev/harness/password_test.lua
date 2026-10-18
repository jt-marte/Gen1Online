-- The server password in the address (START > CONNECT > SERVER ADDRESS,
-- 1.2.3.4/PASSWORD), on Crystal (the default) and on Gen 1
-- (G1O_GAME=yellow), against dev/server.sh started with GTS_PASSWORD
-- (run_tests.sh uses ZQXW42).  gts_config.txt holds the address the way a
-- player types it, in lower case.  Menus show the password hidden; no
-- password, a wrong one and a malformed one are each explained; the right
-- one connects.  On Crystal a character is then created, and the server
-- restarting with another password disconnects the client with a note.
local Rig = dofile(os.getenv("G1O_DEV") .. "/harness/rig.lua")
local PORT = os.getenv("GTS_PORT") or "17781"
local KEY = (os.getenv("GTS_PASSWORD") or "ZQXW42"):upper()
Rig.overrides["gts_config.txt"] = "server_url=127.0.0.1:" .. PORT .. "/" .. KEY:lower() .. "\n"

local fails = 0
local function check(cond, label)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then fails = fails + 1 end
  return cond
end

local socket = require("socket")
local game = Rig.newGame()
if Rig.generation == 1 then
  -- the Gen 1 naming screen pops itself, then calls onDone
  require("src.ui.NamingScreen").new = function(g, opts)
    local stub = { naming = true, opts = opts }
    function stub.finish(name) g.stack:pop(); opts.onDone(name, true) end
    return stub
  end
else
  -- sprite records, so the avatar list has Crystal's own
  for _, id in ipairs({ "SPRITE_CHRIS", "SPRITE_KRIS", "SPRITE_RED", "SPRITE_PIKACHU" }) do
    game.data.gen2Sprites[id] = { id = id, image = "assets/none.png", frames = 6,
      frameWidth = 16, frameHeight = 16 }
  end
  Rig.world(game).sprites = game.data.gen2Sprites
  -- Gen2NamingScreen needs the imported menu art: stand in, keep the callbacks
  local Screens = require("src.ui.Screens")
  local realPush = Screens.push
  Screens.push = function(g, id, opts, ...)
    if id == "Gen2NamingScreen" then
      local stub = { naming = true, opts = opts, onDone = opts.onDone, onCancel = opts.onCancel }
      g.stack:push(stub)
      return stub
    end
    return realPush(g, id, opts, ...)
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
-- every text box on top, closed; their text joined
local function closeTexts()
  local said = {}
  for _ = 1, 20 do
    local s = top()
    if not (s and getmetatable(s) == TextBox) then break end
    said[#said + 1] = textOf(s)
    game.stack:pop()
    if s.onDone then s.onDone() end
  end
  return table.concat(said, " / ")
end
local function startMenu()
  return Rig.hook("ui.start_menu.items", function(g, l) return l end, game, {})
end
local function connectMenu()
  while top() and top() ~= Rig.world(game) do game.stack:pop() end
  for _, it in ipairs(startMenu()) do if it.label == "CONNECT" then it.onSelect() end end
  return top()
end
local function key(k)
  Rig.hook("input.key", function() end, game, { phase = "pressed", key = k })
end
local function button(b)
  game.input:press(b)
  top():update(1 / 60)
end
local function storedUrl()
  for path, contents in pairs(Rig.writes) do
    if path:match("gts_server_url") then return contents end
  end
end
-- the stored address is exactly `url` (a serialized { __value = url })
local function stored(url)
  return (storedUrl() or ""):find('"' .. url .. '"', 1, true) ~= nil
end
local function frames(n)
  for _ = 1, n do
    pcall(Rig.hook, "core.update", function(g) local w = Rig.world(g); if w and w.step then w:step() end end,
      game, 1 / 60)
    socket.sleep(0.004)
  end
end

frames(1)   -- the mod learns the live game

-- ---- the config file's address: shown without its password ------------------------
local menu = connectMenu()
check(labels(menu) == "JOIN SERVER | SERVER ADDRESS | CANCEL" and not labels(menu):find(KEY, 1, true),
  "CONNECT doesn't show the password: " .. labels(menu))
pick("SERVER ADDRESS")
local screen = top()
check(screen and screen.gtsTextInput and screen.current == "127.0.0.1:" .. PORT .. " (PASSWORD)",
  "the address screen hides it: NOW " .. tostring(screen and screen.current))
check(getmetatable(screen).CHARS:find("/", 1, true) ~= nil, "the D-pad's characters include /")
screen.buffer = "1.2.3.4-"
button("up")
check(screen.buffer == "1.2.3.4/", "UP steps from - to / (" .. screen.buffer .. ")")

-- ---- malformed passwords stay on the screen ----------------------------------------
local function try(text)
  screen.buffer, screen.message = text, nil
  key("return")
  return top() == screen, screen.message or ""
end
for _, bad in ipairs({ "1.2.3.4/AB", "1.2.3.4/A-B", "1.2.3.4//" .. KEY, "1.2.3.4/" .. string.rep("A", 17), "/" .. KEY }) do
  local stays, why = try(bad)
  check(stays and why ~= "", ("'%s' is refused: %s"):format(bad, why))
end
check(storedUrl() == nil, "nothing stored yet")

-- ---- no password, then a wrong one: the server says which ----------------------------
screen.buffer = "127.0.0.1:" .. PORT
button("a")
check(stored("http://127.0.0.1:" .. PORT), "an address without a password is stored as is")
local said = closeTexts()
check(said:find("NEEDS A PASSWORD", 1, true) ~= nil, "no password: " .. said)
screen = top()
check(screen and screen.gtsTextInput, "and the address screen is back")
screen.buffer = "127.0.0.1:" .. PORT .. "/WRONG1"
button("a")
said = closeTexts()
check(said:find("WRONG PASSWORD", 1, true) ~= nil, "a wrong password: " .. said)
check(game.save.onlineAccount == nil, "nothing changed in the offline game")

-- ---- the right one, typed in lower case on a keyboard --------------------------------
screen = top()
screen.buffer = ""
love.textinput("127.0.0.1:" .. PORT .. "/" .. KEY:lower())
check(screen.buffer == ("127.0.0.1:" .. PORT .. "/" .. KEY), "/ and the password type through love.textinput ("
  .. screen.buffer .. ")")
key("return")
check(stored("http://127.0.0.1:" .. PORT .. "/" .. KEY),
  "stored with the password in capitals (" .. tostring(storedUrl()):gsub("%s+", " ") .. ")")
check(labels(top()):find("CREATE NEW PLAYER", 1, true) ~= nil, "and it connects: " .. labels(top()))

-- ---- the config file's form works too --------------------------------------------------
menu = connectMenu()
pick("USE CONFIG FILE")
said = closeTexts()
check(said:find("(PASSWORD)", 1, true) and not said:find(KEY, 1, true), "USE CONFIG FILE: " .. said)
menu = connectMenu()
pick("^JOIN")
check(labels(top()):find("CREATE NEW PLAYER", 1, true) ~= nil,
  "gts_config.txt's 127.0.0.1:" .. PORT .. "/" .. KEY:lower() .. " connects: " .. labels(top()))

-- ---- connected, the server's password changes: disconnected with a note ---------------
if Rig.generation == 2 then
  pick("CREATE NEW PLAYER")
  top().onDone("ETHAN")
  pick("CRYSTAL")
  said = closeTexts()
  check(said:find("PLAYER CREATED", 1, true) ~= nil, "a character on the password server: " .. said)
  while top() and top() ~= Rig.world(game) do game.stack:pop() end
  local online = false
  for _, it in ipairs(startMenu()) do if it.label == "ONLINE" then online = true end end
  check(online, "online")
  os.execute("GTS_PASSWORD=OTHER9 '" .. os.getenv("G1O_DEV") .. "/server.sh' >/dev/null")
  local note = ""
  local deadline = socket.gettime() + 15
  while socket.gettime() < deadline and not note:find("PASSWORD CHANGED", 1, true) do
    frames(10)
    note = note .. " " .. closeTexts()
  end
  check(note:find("PASSWORD CHANGED", 1, true) ~= nil, "the server's new password disconnects:" .. note)
  local back = false
  for _, it in ipairs(startMenu()) do if it.label == "CONNECT" then back = true end end
  check(back, "offline again (START shows CONNECT)")
  os.execute("GTS_PASSWORD=" .. KEY .. " '" .. os.getenv("G1O_DEV") .. "/server.sh' >/dev/null")
end

Rig.dump("server password")
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
