-- Real Yellow on a multiworld server (randomizer = on, multiworld = on,
-- players = 2, seed = 4242): this client joins as world 1, BUDDY (raw HTTP)
-- takes world 2 and a third trainer is turned away.  Every badge, HM and key
-- item is in exactly one of the two worlds; this player's find in its own
-- world reaches the team, and BUDDY's find of an item that only world 2 holds
-- reaches this player.  Last, a new player on this device is refused on
-- CONNECT because the run is full, and stays offline.
-- dev/run_tests.sh runs it when the Yellow cache is there.
local U = require("tests.drivers.util")
local Json = require("src.link.Json")
local ModRuntime = require("src.mods.Runtime")

return function(game)
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

  local realUpdate = game.update
  game.update = function(self, dt)
    return ModRuntime.call("core.update", function(g, d) return realUpdate(g, d) end, self, dt)
  end
  for _ = 1, 600 do
    if game.data and game.stack and game.renderer and game.save and game.input then break end
    U.wait(1)
  end
  local Modes = ((game.mods and game.mods.exports or {})["gen1online-plus"] or {}).modes
  if not check(Modes ~= nil, "the game modes module is loaded") then return finish() end

  local http, ltn12 = package.loaded["socket.http"], package.loaded["ltn12"]
  local function post(payload)
    payload.modVersion, payload.gameVersion, payload.generation = "0.5.1", "Pokemon Yellow", 1
    payload.modesVersion = payload.modesVersion or 2   -- the game modes' rules (GtsUI.MODES_VERSION)
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
  local function said(p, from)
    for i = #seen, from or 1, -1 do if seen[i]:find(p, 1, true) then return seen[i] end end
  end
  local function clearTexts(frames)
    for _ = 1, frames or 600 do
      local s = top()
      if isText(s) then
        local t = textOf(s):gsub("[\n\f]", " ")
        if seen[#seen] ~= t then seen[#seen + 1] = t; say("  text: " .. t) end
        U.tap(game, "a"); U.wait(3)
      elseif s == game.overworld then
        U.wait(2)
        if not isText(top()) then return end
      else
        U.wait(2)
      end
    end
  end
  local function choose(pattern)
    local s = top()
    if not (s and s.items) then return check(false, "expected a menu for '" .. pattern .. "'") end
    for i, it in ipairs(s.items) do
      if tostring(it.label):find(pattern) then
        if s.list then s.list.index = i else s.index = i end
        U.tap(game, "a"); U.wait(6)
        return true
      end
    end
    return check(false, "no '" .. pattern .. "' in the menu")
  end
  local function settled()
    for _ = 1, 600 do
      local ow = game.overworld
      if ow and ow.map and top() == ow and not ow.player.moving then return true end
      if isText(top()) then clearTexts(20) end
      U.wait(1)
    end
    return false
  end
  local function inv(id) return (game.save.inventory or {})[id] or 0 end
  local function drain() for _ = 1, 40 do U.wait(3); clearTexts(20) end end

  -- ---- world 1: this player ---------------------------------------------------------------
  U.teleport(game, "PALLET_TOWN", 5, 6, "down")
  settled()
  U.tap(game, "start"); U.wait(10)
  choose("CONNECT")
  choose("^JOIN")
  choose("CREATE NEW PLAYER")
  local naming = top()
  if naming and naming.onDone then
    game.stack:pop()
    naming.onDone("ASH", true)
    U.wait(6)
  end
  choose("RED")
  for _ = 1, 300 do
    clearTexts(40)
    if said("PLAYER CREATED") then break end
    U.wait(2)
  end
  drain()
  local r = Modes.rules
  if not check(r and r.multiworld and r.players == 2 and Modes.world == 1,
      "joined the multiworld run as world " .. tostring(Modes.world) .. ": " .. Modes.describe()) then
    return finish()
  end
  check(Modes.state(game.save).world == 1, "the world is in the online save")
  local mine, theirs = Modes.plan(), Modes.planFor(2)
  check(mine and mine.ok and theirs and theirs.ok and mine.fingerprint == theirs.fingerprint,
    "both worlds build from the seed")

  -- ---- world 2: BUDDY; a third trainer is turned away -------------------------------------
  local buddy = post({ action = "register_player", isNewCharacter = true, name = "BUDDY",
                       spriteId = "SPRITE_BLUE", title = "TRAINER", badges = 0, pokedexCount = 0 }).account
  local res = post({ action = "run_join", trainerId = buddy.trainerId, token = buddy.token,
                     fingerprint = mine.fingerprint, gameName = "YELLOW" })
  check(res and res.success and res.world == 2, "BUDDY joins as world 2")
  local third = post({ action = "register_player", isNewCharacter = true, name = "MISTY",
                       spriteId = "SPRITE_BLUE", title = "TRAINER", badges = 0, pokedexCount = 0 }).account
  res = post({ action = "run_join", trainerId = third.trainerId, token = third.token,
               fingerprint = mine.fingerprint, gameName = "YELLOW" })
  check(res and res.error == "RUN_FULL", "a third trainer is turned away: " .. tostring(res and res.error))

  -- ---- the split ------------------------------------------------------------------------------
  local isProg = {}
  for _, id in ipairs({ "BOULDERBADGE", "CASCADEBADGE", "THUNDERBADGE", "RAINBOWBADGE", "SOULBADGE",
      "MARSHBADGE", "VOLCANOBADGE", "EARTHBADGE", "HM_CUT", "HM_SURF", "HM_STRENGTH", "S_S_TICKET",
      "SILPH_SCOPE", "POKE_FLUTE", "CARD_KEY", "LIFT_KEY", "SECRET_KEY", "GOLD_TEETH", "BIKE_VOUCHER" }) do
    isProg[id] = true
  end
  local where = {}
  for w, plan in ipairs({ mine, theirs }) do
    for key, c in pairs(plan.content) do
      if isProg[c.item] then
        where[c.item] = where[c.item] or {}
        table.insert(where[c.item], w .. ":" .. key)
      end
    end
  end
  local once = true
  for id in pairs(isProg) do if not where[id] or #where[id] ~= 1 then once = false end end
  check(once, "every badge, HM and key item is in exactly one of the two worlds")
  check(mine.myProgression + theirs.myProgression == mine.totalProgression
    and math.abs(mine.myProgression - theirs.myProgression) <= 1,
    ("split evenly: world 1 holds %d, world 2 holds %d"):format(mine.myProgression, theirs.myProgression))
  local function inWorld(plan, item)
    for _, c in pairs(plan.content) do if c.item == item then return true end end
  end
  check(not inWorld(mine, "BOULDERBADGE") or not inWorld(theirs, "BOULDERBADGE"),
    "the BOULDERBADGE is only in world " .. tostring(where.BOULDERBADGE and where.BOULDERBADGE[1]))
  local differ = 0
  for k, v in pairs(mine.species) do if theirs.species[k] ~= v then differ = differ + 1 end end
  check(differ > 0, "each world has its own wild Pokémon (" .. differ .. " species differ)")

  -- this player's find in world 1 reaches the team
  local ball
  for _, loc in ipairs(mine.locations) do
    local c = mine.content[loc.key]
    if loc.kind == "ball" and not loc.ref.hidden and c and isProg[c.item]
        and (loc.map == "VIRIDIAN_FOREST" or loc.map == "MT_MOON_1F" or loc.map == "MT_MOON_B2F"
             or loc.map == "ROUTE_24" or loc.map == "ROUTE_4" or loc.map == "ROUTE_25") then
      ball = loc
      break
    end
  end
  if ball then
    local want = mine.content[ball.key].item
    U.teleport(game, ball.map, ball.ref.x, ball.ref.y + 1, "up")
    settled()
    for _, e in ipairs(game.overworld.entities or {}) do
      if e.def == ball.ref then game.overworld:talkTo(e) break end
    end
    clearTexts()
    check(inv(want) > 0, ("world 1's %s holds %s, and this player has it"):format(ball.key, want))
    local got = false
    for _ = 1, 60 do
      U.wait(5)
      local st = post({ action = "team_status" })
      for _, id in ipairs(st and st.team and st.team.items or {}) do if id == want then got = true end end
      if got then break end
    end
    check(got, "and it reached the team (so BUDDY gets it in world 2)")
  else
    say("  (no progression item in an early world-1 ball for this seed; the find is checked by gen1_modes)")
  end

  -- BUDDY's find of an item only world 2 holds reaches this player
  local onlyTheirs
  for id, list in pairs(where) do
    if list[1]:sub(1, 2) == "2:" and inv(id) == 0 and not id:find("^HM_") then onlyTheirs = id break end
  end
  if check(onlyTheirs ~= nil, "world 2 holds key items world 1 doesn't: " .. tostring(onlyTheirs)) then
    local found = post({ action = "team_found", trainerId = buddy.trainerId, token = buddy.token,
                         runId = Modes.rules.runId, item = onlyTheirs, itemName = onlyTheirs })
    check(found and found.success, "BUDDY finds it in world 2")
    for _ = 1, 120 do
      U.wait(5)
      if inv(onlyTheirs) > 0 then break end
    end
    check(inv(onlyTheirs) > 0, "and this player has " .. onlyTheirs .. " too")
    drain()
  end

  -- RUN INFO
  U.tap(game, "start"); U.wait(10)
  choose("ONLINE")
  local mark = #seen
  if choose("RUN INFO") then
    clearTexts()
    check(said("WORLD 1 OF 2", mark) and said("YOUR WORLD HOLDS", mark) ~= nil,
      "RUN INFO names the world and what it holds")
  end
  while top() and top() ~= game.overworld do game.stack:pop() end

  -- ---- a newcomer on this device: the run is full -----------------------------------------
  U.tap(game, "start"); U.wait(10)
  choose("ONLINE")
  choose("DISCONNECT")
  drain()
  -- forget this device's online character, as a brand-new player would be
  local dir = love.filesystem.getSaveDirectory() .. "/mod_compat/gen1online-plus/"
  os.remove(dir .. "gen1online_online_account_yellow.lua")
  os.remove(dir .. "save_online_yellow.lua")
  local offline = game.save
  mark = #seen
  U.tap(game, "start"); U.wait(10)
  choose("CONNECT")
  choose("^JOIN")
  clearTexts()
  check(said("THIS RUN IS FULL", mark) ~= nil, "a new player is told the run is full")
  check(game.save == offline and not game.save.onlineAccount and Modes.plan() == nil,
    "and stays offline, with the offline save and a vanilla world")

  return finish()
end
