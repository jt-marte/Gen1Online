-- Real Gen 1 boot (Yellow by default) with DramaticShapeVoxelMod
-- (BATTLE_ART_VOXEL_FORK) installed unmodified next to Gen1Online: connect to
-- a Gen 1 test server through the real START menu, put BUDDY next to the
-- player over HTTP, and check the voxel scene draws him, with screenshots of
-- the flat view and of several voxel views.  dev/run_tests.sh runs it when
-- the Yellow cache and the voxel mod are there.
local U = require("tests.drivers.util")
local Json = require("src.link.Json")
local ModRuntime = require("src.mods.Runtime")
local Pipelines = require("src.render.Pipelines")

return function(game)
  local out = os.getenv("SHOTS") or "/tmp/gen1online-shots/gen1_voxel"
  local BASE = "http://127.0.0.1:" .. (os.getenv("GTS_PORT") or "17781")
  local fails = 0
  local function say(...) print("[g1o]", ...) end
  local function check(cond, label)
    say((cond and "PASS " or "FAIL ") .. label)
    if not cond then fails = fails + 1 end
    return cond
  end
  local function finish()
    say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
    love.event.quit(fails == 0 and 0 or 1)
    while true do coroutine.yield() end
  end

  -- driver runs call Game:update directly; route it through core.update the
  -- way a real launch does
  local realUpdate = game.update
  game.update = function(self, dt)
    return ModRuntime.call("core.update", function(g, d) return realUpdate(g, d) end, self, dt)
  end

  local ready = false
  for _ = 1, 600 do
    if game.data and game.stack and game.renderer and game.save and game.input then ready = true break end
    U.wait(1)
  end
  if not check(ready, "Gen 1 game is up") then return finish() end
  local exports = game.mods and game.mods.exports or {}
  local g1o = exports["gen1online-plus"]
  local voxel = exports["BATTLE_ART_VOXEL_FORK"]
  check(g1o ~= nil, "gen1online-plus loaded")
  if not check(voxel ~= nil and Pipelines.get("voxel") ~= nil, "the voxel mod loaded and registered its pipeline") then
    return finish()
  end

  local http, ltn12 = package.loaded["socket.http"], package.loaded["ltn12"]
  local function post(payload)
    payload.modVersion = payload.modVersion or "0.5.1"
    payload.gameVersion = payload.gameVersion or "Pokemon Yellow"
    payload.generation = 1
    local body = Json.encode(payload)
    local res = {}
    http.request({ url = BASE .. "/gts", method = "POST", source = ltn12.source.string(body),
      headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#body),
        ["X-Mod-Version"] = "0.5.1" }, sink = ltn12.sink.table(res) })
    local ok, decoded = pcall(Json.decode, table.concat(res))
    return ok and decoded or nil
  end

  local TextBox = require("src.render.TextBox")
  local function top() return game.stack:top() end
  local function isText(s) return s and getmetatable(s) == TextBox end
  local function textOf(s)
    local t = {}
    local function walk(v)
      if type(v) == "string" then t[#t + 1] = v
      elseif type(v) == "table" then for _, x in ipairs(v) do walk(x) end end
    end
    walk(s and (s.pages or s.text))
    return table.concat(t, " ")
  end
  local seen = {}
  local function said(p) for _, t in ipairs(seen) do if t:find(p) then return t end end end
  local function clearTexts()
    for _ = 1, 600 do
      local s = top()
      if not isText(s) then return end
      local t = textOf(s)
      if seen[#seen] ~= t then seen[#seen + 1] = t; say("  text: " .. t) end
      U.tap(game, "a"); U.wait(3)
    end
  end
  local function menuItems(s)
    local l = {}
    for _, it in ipairs((s and s.items) or {}) do l[#l + 1] = tostring(it.label) end
    return table.concat(l, " | ")
  end
  local function choose(pattern)
    local s = top()
    if not (s and s.items) then return check(false, "expected a menu for '" .. pattern .. "'") end
    local target
    for i, it in ipairs(s.items) do if tostring(it.label):find(pattern) then target = i break end end
    if not target then return check(false, "no '" .. pattern .. "' in " .. menuItems(s)) end
    if s.list then s.list.index = target else s.index = target end
    U.tap(game, "a"); U.wait(6)
    return true
  end
  local function settled()
    for _ = 1, 600 do
      local ow = game.overworld
      if ow and ow.map and game.stack:top() == ow and not ow.player.moving then return true end
      U.wait(1)
    end
    return false
  end

  U.teleport(game, "PALLET_TOWN", 5, 6, "down")
  check(settled(), "standing in Pallet Town")

  -- ---- CONNECT > SERVER ADDRESS: the typing screen on the real game ------------------
  U.tap(game, "start"); U.wait(10)
  if not choose("CONNECT") then return finish() end
  choose("SERVER ADDRESS")
  local screen = top()
  if check(screen and screen.gtsTextInput, "SERVER ADDRESS opens the address screen") then
    love.textinput("192.168.1.2")
    U.tap(game, "right"); U.tap(game, "up"); U.tap(game, "up"); U.tap(game, "up")
    U.wait(5)
    check(screen.buffer == "192.168.1.23", "typed and D-pad edited: " .. tostring(screen.buffer))
    U.shot(game, out .. "/05_server_address.png")
    ModRuntime.call("input.key", function() end, game, { phase = "pressed", key = "escape" })
    U.wait(5)
    check(top() ~= screen, "ESC closes it")
  end
  while top() and top() ~= game.overworld do game.stack:pop() end
  U.wait(5)

  -- ---- CONNECT > JOIN, create a character -----------------------------------------
  U.tap(game, "start"); U.wait(10)
  if not choose("CONNECT") then return finish() end
  check(menuItems(top()):find("^JOIN") and menuItems(top()):find("SERVER ADDRESS"),
    "CONNECT offers JOIN and SERVER ADDRESS: " .. menuItems(top()))
  choose("^JOIN")
  choose("CREATE NEW PLAYER")
  local naming = top()
  if check(naming and naming.onDone, "the Gen 1 naming screen opens") then
    game.stack:pop()
    naming.onDone("ASH", true)
    U.wait(6)
  end
  choose("RED")
  for _ = 1, 600 do
    clearTexts()
    if said("PLAYER CREATED") then break end
    U.wait(2)
  end
  check(said("PLAYER CREATED") ~= nil, "connected as a new character")
  clearTexts()
  U.teleport(game, "PALLET_TOWN", 5, 6, "down")
  check(settled(), "back in Pallet Town, online")

  -- ---- BUDDY two tiles to the right ---------------------------------------------------
  local p = game.overworld.player
  local function buddySync()
    return post({ action = "sync_pos", trainerId = "777777", sessionId = "buddy",
      name = "BUDDY", spriteId = "SPRITE_BLUE", map = game.overworld.map.id,
      x = p.cellX + 2, y = p.cellY, px = (p.cellX + 2) * 16, py = p.cellY * 16,
      facing = "left", moving = false })
  end
  local buddy
  for _ = 1, 60 do
    buddySync(); U.wait(10)
    buddy = g1o and g1o.netNpcs and g1o.netNpcs["777777"]
    if buddy and buddy.sprite then break end
  end
  check(buddy and buddy.sprite, "BUDDY shows up with a sprite")
  U.wait(30)
  Pipelines.setLevel("voxel", 0)
  U.wait(10)
  U.shot(game, out .. "/10_flat.png")

  -- ---- voxel: a read-only probe through the voxel mod's public renderer API
  -- notes every actor its scene draws, and claims none of them
  local drawnActors = {}
  local probe = voxel.characterRenderers and voxel.characterRenderers.register({
    id = "g1o-test-probe", apiVersion = 1,
    drawEntity = function(ctx)
      if ctx and ctx.entity then drawnActors[ctx.entity] = true end
      return false
    end,
  })
  check(probe ~= nil, "probe registered with the voxel mod's character renderer API")
  local labels = Pipelines.levelLabels("voxel") or {}
  for _, level in ipairs({ 4, 2, 1, 7, 6 }) do
    Pipelines.setLevel("voxel", level)
    local label = tostring(labels[level + 1] or level)
    local inScene = false
    for _ = 1, 40 do
      drawnActors = {}
      U.wait(15)
      buddySync()
      if drawnActors[buddy] then inScene = true break end
    end
    check(inScene, "voxel " .. label .. ": BUDDY is drawn in the 3D scene")
    if level ~= 6 then check(drawnActors[p] == true, "voxel " .. label .. ": so is the player") end
    U.shot(game, out .. ("/2%d_voxel_%s.png"):format(level, label:gsub("%W", "")))
  end
  if probe and probe.release then probe:release() end
  Pipelines.setLevel("voxel", 0)
  U.wait(10)
  check(not (function() for _, e in ipairs(game.overworld.entities or {}) do if e == buddy then return true end end end)(),
    "BUDDY never stays in the overworld's entity list")

  return finish()
end
