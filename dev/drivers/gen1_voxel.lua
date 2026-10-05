-- Real Gen 1 boot (Yellow by default) with DramaticShapeVoxelMod
-- (DRAMATIC_SHAPE; BATTLE_ART_VOXEL_FORK in older releases) installed
-- unmodified next to Gen1Online: connect to a Gen 1 test server through the
-- real START menu, put BUDDY next to the player over HTTP, and check the
-- voxel scene draws him on the orbit rungs and in the free cameras (1ST and
-- 3RD): his card, his name tag over it, free walking reaching the server,
-- a remote player moving off the grid, and A and START from the free walk.
-- Screenshots of the flat view and of every voxel view.  dev/run_tests.sh
-- runs it when the Yellow cache and the voxel mod are there.
local U = require("tests.drivers.util")
local Json = require("src.link.Json")
local ModRuntime = require("src.mods.Runtime")
local Pipelines = require("src.render.Pipelines")
local Font = require("src.render.Font")

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
  local voxel = exports["DRAMATIC_SHAPE"] or exports["BATTLE_ART_VOXEL_FORK"]
  check(g1o ~= nil, "gen1online-plus loaded")
  if not check(voxel ~= nil and voxel.lib and Pipelines.get("voxel") ~= nil,
      "the voxel mod loaded and registered its pipeline (" .. tostring(voxel and voxel.version) .. ")") then
    return finish()
  end
  -- the voxel mod's own modules, read through its public lib export
  local V = voxel.lib
  local VoxelState, Voxel3D = V.require("VoxelState"), V.require("Voxel3D")
  local FirstPerson, ThirdPerson = V.require("FirstPerson"), V.require("ThirdPerson")

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
  local ow = game.overworld
  local p = ow.player
  local bx, by = p.cellX + 2, p.cellY            -- BUDDY's cell (moved later)
  local function buddySync(px, py)
    px, py = px or bx * 16, py or by * 16
    return post({ action = "sync_pos", trainerId = "777777", sessionId = "buddy",
      name = "BUDDY", spriteId = "SPRITE_BLUE", map = game.overworld.map.id,
      x = math.floor((px + 8) / 16), y = math.floor((py + 8) / 16), px = px, py = py,
      facing = "left", moving = false })
  end
  local buddy
  for _ = 1, 60 do
    buddySync(); U.wait(10)
    buddy = g1o and g1o.netNpcs and g1o.netNpcs["777777"]
    if buddy and buddy.sprite then break end
  end
  if not check(buddy and buddy.sprite, "BUDDY shows up with a sprite") then return finish() end
  U.wait(30)
  Pipelines.setLevel("voxel", 0)
  U.wait(10)
  U.shot(game, out .. "/10_flat.png")

  -- ---- probes (read-only: they record and pass every call through) -------------------
  -- The voxel scene poses every character it draws (VoxelScene's posesOf
  -- calls e:pose() once per entity per frame); count BUDDY's and the
  -- player's.  A teleport builds a new overworld (and player), and a map
  -- change may rebuild BUDDY, so rewire() re-reads both.
  local posed = { buddy = 0, me = 0 }
  local wrapped = setmetatable({}, { __mode = "k" })
  local function countPoses(e, key)
    if not e or wrapped[e] then return end
    local orig = e.pose
    wrapped[e] = orig
    e.pose = function(self, ...) posed[key] = posed[key] + 1 return orig(self, ...) end
  end
  local function rewire()
    ow = game.overworld
    p = ow.player
    buddy = g1o.netNpcs["777777"] or buddy
    countPoses(buddy, "buddy")
    countPoses(p, "me")
  end
  rewire()
  -- Name tags: where each name lands on the scene canvas, next to where the
  -- voxel camera puts BUDDY's card at that same moment.
  local tags = {}
  local realFontDraw = Font.draw
  Font.draw = function(text, x, y, ...)
    if text == "BUDDY" or text == "ASH" then
      local w = Font.width(text)
      local sx, sy = love.graphics.transformPoint(x + w / 2, y + 8)
      local cw, ch = love.graphics.getDimensions()
      local cv = love.graphics.getCanvas()
      if cv then cw, ch = cv:getDimensions() end
      local rec = { x = sx, y = sy, w = cw, h = ch }
      if text == "BUDDY" and Voxel3D.project then
        -- the card stands upright on the cell centre in the free cameras
        rec.feetX, rec.feetY = Voxel3D.project(buddy.px + 8, 0, buddy.py + 8)
        rec.headX, rec.headY = Voxel3D.project(buddy.px + 8, 16, buddy.py + 8)
      end
      tags[text] = rec
    end
    return realFontDraw(text, x, y, ...)
  end
  local function frames(n)
    rewire()
    tags, posed.buddy, posed.me = {}, 0, 0
    for _ = 1, n do U.wait(1) end
  end

  -- ---- the orbit rungs ------------------------------------------------------------------
  local labels = Pipelines.levelLabels("voxel") or {}
  local function labelOf(level) return tostring(labels[level + 1] or level) end
  for _, level in ipairs({ 4, 2, 1, 5 }) do
    Pipelines.setLevel("voxel", level)
    local label = labelOf(level)
    local inScene = false
    for _ = 1, 40 do
      frames(15)
      buddySync()
      if posed.buddy > 0 then inScene = true break end
    end
    check(inScene, "voxel " .. label .. ": BUDDY is drawn in the 3D scene")
    check(posed.me > 0, "voxel " .. label .. ": so is the player")
    check(tags.BUDDY ~= nil, "voxel " .. label .. ": BUDDY's name tag is drawn")
    U.shot(game, out .. ("/2%d_voxel_%s.png"):format(level, label:gsub("%W", "")))
  end

  -- ---- the free cameras: 1ST (in the head) and 3RD (on the boom) ----------------------
  -- The player stays on (5, 6); BUDDY is moved around them over HTTP.
  local function lookAt(wx, wz)
    local dx, dz = wx - (p.px + 8), wz - (p.py + 8)
    FirstPerson.yaw = math.atan2(dx, dz)
    FirstPerson.pitch = 0
  end
  local function placeBuddy(cx, cy)
    bx, by = cx, cy
    for _ = 1, 8 do
      buddySync(); U.wait(8)
      rewire()
      if math.abs(buddy.px - bx * 16) < 0.5 and math.abs(buddy.py - by * 16) < 0.5 then break end
    end
    lookAt(bx * 16 + 8, by * 16 + 8)
    for _ = 1, 6 do buddySync(); frames(6) end
  end
  -- BUDDY's tag over BUDDY: centred on his card (within a quarter of its
  -- width) and above his head (within a card and a half)
  local function tagOverBuddy(label)
    local t = tags.BUDDY
    if not check(t ~= nil, label .. ": BUDDY's name tag is drawn") then return end
    if not (t.feetX and t.headX) then return check(false, label .. ": BUDDY projects on screen") end
    local cardW = math.abs(t.feetY - t.headY)   -- an upright 16x16 card: as wide as it is tall
    say(("  %s: tag at (%.0f, %.0f), card feet (%.0f, %.0f) head (%.0f, %.0f), canvas %dx%d")
      :format(label, t.x, t.y, t.feetX, t.feetY, t.headX, t.headY, t.w, t.h))
    check(t.headX > 0 and t.headX < t.w and t.headY > 0 and t.headY < t.h,
      label .. ": BUDDY's card is on screen")
    check(math.abs(t.x - t.headX) <= cardW * 0.25,
      ("%s: the tag is centred over BUDDY (off by %.0f px, card %.0f px)"):format(label, t.x - t.headX, cardW))
    check(t.y < t.headY and t.y > t.headY - cardW * 1.5,
      ("%s: the tag sits just above his head (%.0f px above, card %.0f px)"):format(label, t.headY - t.y, cardW))
  end
  local function engage(level)
    Pipelines.setLevel("voxel", level)
    for _ = 1, 300 do
      U.wait(1)
      if FirstPerson.driving() and FirstPerson.blendEased() > 0.999
          and (level ~= VoxelState.TP_LEVEL or ThirdPerson.extended()) then
        return true
      end
    end
    return false
  end

  U.teleport(game, "PALLET_TOWN", 5, 6, "down")
  settled()
  rewire()
  local homeX, homeY = p.cellX, p.cellY
  for _, level in ipairs({ VoxelState.FP_LEVEL, VoxelState.TP_LEVEL }) do
    local label = "voxel " .. labelOf(level)
    local tag = level == VoxelState.FP_LEVEL and "1st" or "3rd"
    local isFirst = level == VoxelState.FP_LEVEL
    if not check(engage(level), label .. ": the free camera takes over") then break end
    check(p.cellX == homeX and p.cellY == homeY, label .. ": the player is still on their cell")

    placeBuddy(homeX + 2, homeY)
    check(posed.buddy > 0, label .. ": BUDDY is drawn in the 3D scene")
    if isFirst then
      check(FirstPerson.hidePlayer(), label .. ": the player's own card is left out (the eye is in it)")
      check(tags.ASH == nil, label .. ": no name tag for the player's own head")
    else
      check(not FirstPerson.hidePlayer(), label .. ": the player's card is on screen")
    end
    tagOverBuddy(label)
    U.shot(game, out .. ("/3%d_%s_ahead.png"):format(level, tag))

    -- seen diagonally, so the camera is neither along a row nor a column
    placeBuddy(homeX + 3, homeY + 2)
    tagOverBuddy(label .. " (diagonal)")
    U.shot(game, out .. ("/3%d_%s_diagonal.png"):format(level, tag))

    -- turn away: BUDDY is behind the eye, so no tag floats on screen for him
    lookAt(p.px + 8 - 3 * (bx * 16 - p.px), p.py + 8 - 3 * (by * 16 - p.py))
    for _ = 1, 6 do buddySync(); frames(6) end
    if isFirst then
      check(tags.BUDDY == nil, label .. ": looking away, BUDDY's tag is not drawn")
    end
    U.shot(game, out .. ("/3%d_%s_away.png"):format(level, tag))

    -- A on BUDDY from the free walk opens his trainer menu
    placeBuddy(homeX + 1, homeY)
    U.tap(game, "a"); U.wait(8)
    check(menuItems(top()):find("VIEW TRAINER CARD") ~= nil,
      label .. ": A on BUDDY opens his menu: " .. menuItems(top()))
    local m = top()
    check(m and m.th and m.items and m.th >= #m.items * (m.rowStep or 2) + 2,
      label .. ": the menu box fits its rows (none on the border)")
    U.shot(game, out .. ("/3%d_%s_menu.png"):format(level, tag))
    while top() and top() ~= game.overworld do game.stack:pop() end
    U.wait(5)
    U.tap(game, "start"); U.wait(10)
    check(menuItems(top()):find("ONLINE") ~= nil,
      label .. ": START opens the start menu with ONLINE: " .. menuItems(top()))
    while top() and top() ~= game.overworld do game.stack:pop() end
    U.wait(5)
  end

  -- ---- free walking reaches the server, and a free-walking remote moves smoothly ------
  local label = "voxel " .. labelOf(VoxelState.FP_LEVEL)
  placeBuddy(homeX + 3, homeY + 3)
  if engage(VoxelState.FP_LEVEL) then
    -- walk diagonally (south-east), sampling what BUDDY's sync answer says
    -- about this player every few frames
    FirstPerson.yaw, FirstPerson.pitch = math.atan2(1, 1), 0
    local startPx, startPy = p.px, p.py
    local seenAt, samples = {}, 0
    local function mine(res)
      for _, e in ipairs((res and res.players) or {}) do
        if e.name == "ASH" then return e end
      end
    end
    for _ = 1, 10 do
      U.hold(game, "up", 6)
      local e = mine(buddySync())
      samples = samples + 1
      if e and e.px then seenAt[("%.1f,%.1f"):format(e.px, e.py)] = true end
    end
    local distinct = 0
    for _ in pairs(seenAt) do distinct = distinct + 1 end
    local moved = math.sqrt((p.px - startPx) ^ 2 + (p.py - startPy) ^ 2)
    say(("  walked %.1f px to (%.2f, %.2f); the server saw %d positions in %d samples")
      :format(moved, p.px, p.py, distinct, samples))
    check(moved > 20 and p.px ~= startPx and p.py ~= startPy,
      label .. ": the free walk moves the player off the grid")
    check(distinct >= 4, label .. ": the server follows the free walk (" .. distinct .. " positions in 1 s)")
    U.wait(30)
    local e = mine(buddySync())
    check(e and math.abs((e.px or -99) - p.px) < 1 and math.abs((e.py or -99) - p.py) < 1,
      ("%s: standing still, the server has the exact position (%s, %s) vs (%.2f, %.2f)")
        :format(label, tostring(e and e.px), tostring(e and e.py), p.px, p.py))
    U.shot(game, out .. "/40_1st_walked.png")

    -- BUDDY free-walks too: off-grid positions, glided to, never snapped.
    -- Three cells past where the walk stopped, so his tag is not too close
    -- to draw.
    local tx = math.floor((p.px + 8) / 16 + 3) * 16 + 5.5
    local ty = math.floor((p.py + 8) / 16 + 2) * 16 - 7.25
    buddySync(tx, ty)
    U.wait(1)
    rewire()
    local jumps, last = 0, { buddy.px, buddy.py }
    for _ = 1, 40 do
      U.wait(1)
      local step = math.sqrt((buddy.px - last[1]) ^ 2 + (buddy.py - last[2]) ^ 2)
      if step > 4 then jumps = jumps + 1 end
      last = { buddy.px, buddy.py }
    end
    check(math.abs(buddy.px - tx) < 0.6 and math.abs(buddy.py - ty) < 0.6,
      ("%s: BUDDY reaches his off-grid spot (%.2f, %.2f) vs (%.2f, %.2f)"):format(label, buddy.px, buddy.py, tx, ty))
    check(jumps == 0, label .. ": BUDDY glides there without jumps")
    lookAt(buddy.px + 8, buddy.py + 8)
    for _ = 1, 6 do buddySync(tx, ty); frames(6) end
    tagOverBuddy(label .. " (BUDDY off the grid)")
    U.shot(game, out .. "/41_1st_offgrid_buddy.png")
  else
    check(false, label .. ": the free camera takes over for the walk")
  end

  Font.draw = realFontDraw
  for e, orig in pairs(wrapped) do e.pose = orig end
  Pipelines.setLevel("voxel", 0)
  U.wait(10)
  check(not (function() for _, e in ipairs(game.overworld.entities or {}) do if e == buddy then return true end end end)(),
    "BUDDY never stays in the overworld's entity list")

  return finish()
end
