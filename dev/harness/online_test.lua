-- Online, against the local test server (dev/server.sh): connect, create a
-- character, sync, a second player appears, chat, speed lock, save routing,
-- PVP room negotiation, disconnect, reconnect.  "BUDDY" is raw HTTP.
local Rig = dofile(os.getenv("G1O_DEV") .. "/harness/rig.lua")
local PORT = os.getenv("GTS_PORT") or "17781"
local BASE = "http://127.0.0.1:" .. PORT
Rig.overrides["gts_config.txt"] = "server_url=" .. BASE .. "\n"

local fails = 0
local function check(cond, label)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then fails = fails + 1 end
  return cond
end

local Json = require("src.link.Json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")

local function post(payload)
  payload.modVersion = payload.modVersion or "0.5.0"
  payload.gameVersion = payload.gameVersion or "Pokemon Crystal"
  local body = Json.encode(payload)
  local out = {}
  http.request({ url = BASE .. "/gts", method = "POST", source = ltn12.source.string(body),
    headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#body),
      ["X-Mod-Version"] = "0.5.0" }, sink = ltn12.sink.table(out) })
  local ok, res = pcall(Json.decode, table.concat(out))
  return ok and res or nil
end
local function get(path)
  local out = {}
  http.request({ url = BASE .. path, headers = { ["X-Mod-Version"] = "0.5.0" },
    sink = ltn12.sink.table(out) })
  local ok, res = pcall(Json.decode, table.concat(out))
  return ok and res or nil
end

-- the game, with sprite records so remote players can be built
local game = Rig.newGame()
local world = game.world
for _, id in ipairs({ "SPRITE_CHRIS", "SPRITE_KRIS", "SPRITE_RED", "SPRITE_PIKACHU" }) do
  game.data.gen2Sprites[id] = { id = id, image = "assets/none.png", frames = 6,
    frameWidth = 16, frameHeight = 16 }
end
world.sprites = game.data.gen2Sprites

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

local ok, err = Rig.load(game)
check(ok, "loader:load completes (" .. tostring(err) .. ")")
local exports = Rig.loader.exports["gen1online-plus"]

-- ---- UI driver: mimics Menu (pop unless keepOpen, then onSelect) and
-- TextBox (pop, then onDone)
local TextBox = require("src.render.TextBox")
local messages = {}
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
local function describe(s)
  if not s then return "nil" end
  if s.items then
    local l = {}
    for _, it in ipairs(s.items) do l[#l + 1] = tostring(it.label) end
    return "Menu{" .. table.concat(l, " | ") .. "}"
  end
  if getmetatable(s) == TextBox then return "TextBox{" .. textOf(s) .. "}" end
  if s == world then return "World" end
  if s.naming then return "Naming{" .. tostring(s.opts.prompt) .. "}" end
  return tostring(s)
end
local function pick(pattern)
  local s = top()
  if not (s and s.items) then error("expected a menu, top is " .. describe(s), 2) end
  for _, it in ipairs(s.items) do
    if tostring(it.label):find(pattern) then
      if not it.keepOpen then game.stack:pop() end
      if it.onSelect then it.onSelect() end
      return true
    end
  end
  error("no item '" .. pattern .. "' in " .. describe(s), 2)
end
local function closeTexts()
  for _ = 1, 20 do
    local s = top()
    if not (s and getmetatable(s) == TextBox) then return end
    messages[#messages + 1] = textOf(s)
    game.stack:pop()
    if s.onDone then s.onDone() end
  end
end
local function popTo(state) while top() and top() ~= state do game.stack:pop() end end
local function frames(n)
  for _ = 1, n do
    local okF, e = pcall(Rig.hook, "core.update", function(g) g.world:step() end, game, 1 / 60)
    if not okF then Rig.record("frame", e) end
    socket.sleep(0.004)
  end
end
-- idle players sync every 2s and chat polls every 5s: wait on conditions
local function waitUntil(cond, seconds)
  local deadline = socket.gettime() + (seconds or 8)
  while socket.gettime() < deadline do
    frames(10)
    if cond() then return true end
  end
  return cond() and true or false
end
local function said(pattern)
  for _, m in ipairs(messages) do if m:find(pattern) then return m end end
  return nil
end
local function startMenu(list)
  return Rig.hook("ui.start_menu.items", function(g, l) return l end, game, list or {})
end
local function item(list, label)
  for _, it in ipairs(list) do if it.label == label then return it end end
end

-- ---- 1. CONNECT, create a character ------------------------------------------
local offlineName = game.save.player.name
item(startMenu(), "CONNECT").onSelect()
check(top() and top().items, "no online save yet -> create/redeem menu")
pick("CREATE NEW PLAYER")
check(top() and top().naming, "CREATE NEW PLAYER opens Crystal's naming screen")
check(top().opts.type == "player" and top().opts.maxLength == 7, "player keyboard, 7 chars")
top().onDone("ETHAN")
check(not (top() and top().naming), "the naming screen is popped by its onDone")
pick("CRYSTAL")
closeTexts()
check(said("PLAYER CREATED") ~= nil, "server registered the character")
popTo(world)
Rig.dump("create")

local onlinePath, accountPath
for path in pairs(Rig.writes) do
  if path:match("save_online_crystal%.lua$") then onlinePath = path end
  if path:match("gen1online_online_account%.lua$") then accountPath = path end
end
check(onlinePath ~= nil, "online save written")
check(accountPath ~= nil, "online account written")
check(game.save.player.name == "ETHAN", "game now runs the online character")
local myId = tostring(game.save.player.id)
game.save.party = { { species = "CYNDAQUIL", nickname = "CYNDAQUIL", level = 7, hp = 24,
  maxHp = 24, moves = { { id = "TACKLE", pp = 35 } }, dvs = { attack = 9, defense = 8, speed = 7, special = 6 } } }

-- ---- 2. sync ---------------------------------------------------------------------
waitUntil(function()
  local players = get("/gts/players")
  for tid in pairs((players and players.players) or {}) do if tostring(tid) == myId then return true end end
end, 6)
local listed = false
for tid in pairs((get("/gts/players") or {}).players or {}) do if tostring(tid) == myId then listed = true end end
check(listed, "server lists this client in /gts/players")

-- ---- 3. a second player on the same map -----------------------------------------
local function buddySync(extra)
  local p = { action = "sync_pos", trainerId = "777777", sessionId = "buddy-session",
    name = "BUDDY", spriteId = "SPRITE_RED", map = world.map.id, x = 6, y = 8,
    px = 96, py = 128, facing = "up", moving = false }
  for k, v in pairs(extra or {}) do p[k] = v end
  return post(p)
end
waitUntil(function() buddySync(); return exports.netNpcs["777777"] ~= nil end, 10)
local buddy = exports.netNpcs["777777"]
check(buddy ~= nil and buddy.sprite ~= nil, "remote player BUDDY spawned with a sprite")
local okDraw, drawErr = pcall(world.drawPeople, world, 2)
check(okDraw, "drawPeople with a remote player and name tags (" .. tostring(drawErr) .. ")")
Rig.dump("remote player")

-- ---- 4. chat ---------------------------------------------------------------------
post({ action = "send_chat", trainerId = "777777", name = "BUDDY", text = "HELLO FROM ROUTE", scope = "global" })
waitUntil(function() buddySync(); closeTexts(); return said("HELLO FROM ROUTE") ~= nil end, 12)
check(said("HELLO FROM ROUTE") ~= nil, "live chat notification shows the message")
popTo(world)

-- ---- 5. speed lock + save routing ------------------------------------------------
local Game2 = require("src.core.Game2")
local locked, why = Game2.speedLocked({ stack = { states = {} } })
check(locked == true and why == "online", "Game2:speedLocked is true while online")
check(game.options.speed == 3, "player's GAME SPEED option untouched while online")
local Gen2Save = require("src.core.gen2.Save")
game.save.money = 4242
check(Gen2Save.save(game.save) == true, "SAVE while online reports success")
local SaveSerializer = require("src.core.SaveSerializer")
local stored = SaveSerializer.decode(Rig.writes[onlinePath])
check(stored and stored.money == 4242 and stored.onlineAccount and stored.onlineAccount.token,
  "online save holds the progress and the account token")

-- ---- 6. PVP challenge offers the native room ---------------------------------------
buddySync({ x = 6, y = 7 })
frames(60)
world.player.cellX, world.player.cellY, world.player.facing = 6, 6, "down"
buddy = exports.netNpcs["777777"]
if buddy then buddy.cellX, buddy.cellY = 6, 7 end
check(pcall(world.interact, world), "A press facing the remote player")
check(top() and top().items and describe(top()):find("PVP"), "trainer menu offers PVP")
pick("PVP")
closeTexts()
local challenge = (buddySync() or {}).challenge
check(challenge and challenge.type == "PVP", "BUDDY receives the PVP challenge")
local room = challenge and challenge.roomId or ""
check(room:sub(-3) == "_L2", "challenger tags the room for the native battle (" .. room .. ")")
local Protocol = require("src.link.Protocol")
post({ action = "send_challenge", targetId = myId, fromId = "777777", fromName = "BUDDY",
  challengeType = "ACCEPT_PVP", seed = challenge and challenge.seed or 1, roomId = room .. "K",
  party = { Protocol.packMon2({ species = "CHIKORITA", level = 7, hp = 24,
    moves = { { id = "TACKLE", pp = 35 } }, dvs = {} }) } })
-- the rig has no species data, so LinkBattle2 refuses the parties by name,
-- which is what proves the native backend was chosen
waitUntil(function()
  buddySync(); closeTexts()
  return said("can't") or said("isn't in this game") or (top() and top().linkRole ~= nil)
end, 10)
check(said("can't") or said("isn't in this game") or (top() and top().linkRole),
  "ACCEPT on the K room takes the native LinkBattle2 path")
popTo(world)

-- ---- 7. disconnect / reconnect ------------------------------------------------
local list = startMenu({ { label = "SAVE", value = "save" } })
check(item(list, "ONLINE") ~= nil and item(list, "SAVE") == nil, "ONLINE shown, SAVE hidden while connected")
item(list, "ONLINE").onSelect()
pick("DISCONNECT")
closeTexts()
check(game.save.player.name == offlineName, "offline save restored on disconnect")
check(game.save.onlineAccount == nil, "restored offline save carries no online account")
check(not Game2.speedLocked({ stack = { states = {} } }), "speed lock released")
popTo(world)
frames(120)
check(game.save.player.name == offlineName, "offline events do not rename the offline player")
item(startMenu(), "CONNECT").onSelect()
closeTexts()
check(game.save.player.name == "ETHAN" and game.save.money == 4242, "reconnect restores the online character")
popTo(world)
Rig.dump("disconnect/reconnect")

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
