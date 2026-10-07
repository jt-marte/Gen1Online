-- Real Yellow boot against a Gen 1 server with every game mode on
-- (server_config: nuzlocke = hardcore, randomizer = on, seed = 4242):
-- connect as a new character, then check the co-op randomizer (wild species,
-- an item ball, an NPC gift row, a gym leader's badge slot), the team's
-- shared key items in both directions (this player's find reaches BUDDY, a
-- raw-HTTP teammate; BUDDY's find reaches this player), the hardcore Nuzlocke
-- rules (SET style, level cap, no battle items, first encounter per area,
-- no dupes clause, fainted Pokemon gone), and both ways a run ends: this
-- player's party wiping out, and a teammate's.  Disconnecting puts the
-- vanilla world back.  dev/run_tests.sh runs it when the Yellow cache is there.
local U = require("tests.drivers.util")
local Json = require("src.link.Json")
local ModRuntime = require("src.mods.Runtime")

return function(game)
  local out = os.getenv("SHOTS") or "/tmp/gen1online-shots/gen1_modes"
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
  local g1o = (game.mods and game.mods.exports or {})["gen1online-plus"]
  local Modes = g1o and g1o.modes
  if not check(Modes ~= nil, "the game modes module is loaded") then return finish() end

  local http, ltn12 = package.loaded["socket.http"], package.loaded["ltn12"]
  local function post(payload)
    payload.modVersion, payload.gameVersion, payload.generation = "0.5.1", "Pokemon Yellow", 1
    payload.modesVersion = payload.modesVersion or (g1o and g1o.ui and g1o.ui.MODES_VERSION)
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
  local function said(p)
    for i = #seen, 1, -1 do if seen[i]:find(p) then return seen[i] end end
  end
  local function clearTexts(frames)
    for _ = 1, frames or 600 do
      local s = top()
      if isText(s) then
        local t = textOf(s)
        if seen[#seen] ~= t then seen[#seen + 1] = t; say("  text: " .. t:gsub("[\n\f]", " ")) end
        U.tap(game, "a"); U.wait(3)
      elseif s == game.overworld then
        U.wait(2)
        if not isText(top()) then return end
      else
        U.wait(2)
      end
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
    for i, it in ipairs(s.items) do
      if tostring(it.label):find(pattern) then
        if s.list then s.list.index = i else s.index = i end
        U.tap(game, "a"); U.wait(6)
        return true
      end
    end
    return check(false, "no '" .. pattern .. "' in " .. menuItems(s))
  end
  local function settled()
    for _ = 1, 600 do
      local ow = game.overworld
      if ow and ow.map and top() == ow and not ow.player.moving then return true end
      U.wait(1)
    end
    return false
  end
  local function inv(id) return (game.save.inventory or {})[id] or 0 end
  -- the modes queue their boxes until the overworld is free: let them all show
  local function drain()
    for _ = 1, 40 do U.wait(3); clearTexts(20) end
  end
  local function itemName(id) return (game.data.items[id] or {}).name or id end

  -- ---- soft locks: the logic table against the real maps, and many seeds ------------------
  -- (on the vanilla data: nothing is applied before CONNECT)
  local lib = Modes.lib
  local L, R, Rng = lib.logic, lib.randomizer, lib.Rng
  do
    -- every ball the logic says is open, walked to within its map from the
    -- map's warps and edges: Cut trees, water and boulders are walls unless
    -- the map's requirement has the HM, locked Silph doors unless the Card Key
    local Map = require("src.world.Map")
    local Collision = require("src.world.Collision")
    local field = game.data.field
    local ledge, tree = {}, {}
    for _, l in ipairs(field.ledges or {}) do ledge[l.standingTile .. ":" .. l.ledgeTile .. ":" .. l.input] = true end
    for _, sw in ipairs(field.cutTreeSwaps or {}) do tree[sw.before] = true end
    local ck = field.cardKeyDoors or { closedDoors = {}, maps = {} }
    local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
    local function reach(mapId, cap)
      local vanilla = game.data.maps[mapId]
      local def = setmetatable({ blocks = { unpack(vanilla.blocks) } }, { __index = vanilla })
      local map = Map.new(def, game.data.tilesets[def.tileset])
      local silph = false
      for _, m in ipairs(ck.maps or {}) do if m == mapId then silph = true end end
      for _, door in ipairs(silph and not cap.cardkey and ck.closedDoors[mapId] or {}) do
        map:setBlock(door.bx, door.by, door.block)
      end
      local boulder = {}
      for _, o in ipairs(def.objects or {}) do
        if Map.isPushable(o) and not cap.strength then boulder[o.y * 1000 + o.x] = true end
      end
      local function isTree(x, y)
        local t, ts = map:cellTile(x, y), def.tileset
        return ((ts == "OVERWORLD" and t == 0x3d) or (ts == "GYM" and t == 0x50))
          and tree[map:blockAt(math.floor(x / 2), math.floor(y / 2))] or false
      end
      local function open(x, y)
        if not map:inBounds(x, y) or boulder[y * 1000 + x] then return false end
        return map:isWalkableCell(x, y) or (cap.surf and map:isWaterCell(x, y))
          or (cap.cut and isTree(x, y)) or false
      end
      local seen, queue = {}, {}
      local function push(x, y, force)
        local k = y * 1000 + x
        if not seen[k] and (force or open(x, y)) then seen[k] = true; queue[#queue + 1] = { x, y } end
      end
      for _, w in ipairs(def.warps or {}) do if map:inBounds(w.x, w.y) then push(w.x, w.y, true) end end
      local W, H = map.widthCells, map.heightCells
      for dir in pairs(def.connections or {}) do
        for i = 0, ((dir == "north" or dir == "south") and W or H) - 1 do
          if dir == "north" then push(i, 0) elseif dir == "south" then push(i, H - 1)
          elseif dir == "west" then push(0, i) else push(W - 1, i) end
        end
      end
      local i = 1
      while i <= #queue do
        local x, y = queue[i][1], queue[i][2]
        i = i + 1
        for name, d in pairs(DIRS) do
          local tx, ty = x + d[1], y + d[2]
          local t = map:inBounds(tx, ty) and map:cellTile(tx, ty)
          if t and ledge[map:cellTile(x, y) .. ":" .. t .. ":" .. name] then
            push(tx + d[1], ty + d[2])
          elseif open(tx, ty) then
            local mover = { cellX = x, cellY = y, surfing = cap.surf and map:isWaterCell(x, y) }
            if Collision.canMove(map, {}, mover, name) or (cap.surf and map:isWaterCell(tx, ty))
                or (cap.cut and isTree(tx, ty)) then
              push(tx, ty)
            end
          end
        end
      end
      return seen
    end
    local function besideBall(seen, o)
      for _, d in pairs(DIRS) do if seen[(o.y + d[2]) * 1000 + (o.x + d[1])] then return true end end
      return false
    end
    local wrong, total = {}, 0
    for mapId, req in pairs(L.MAPS) do
      local def = game.data.maps[mapId]
      if def and def.blocks then
        local need = L.expand(req)
        local seen = reach(mapId, { cut = need.HM_CUT, surf = need.HM_SURF,
                                    strength = need.HM_STRENGTH, cardkey = need.CARD_KEY })
        for _, o in ipairs(def.objects or {}) do
          if type(o.item) == "string" and game.data.items[o.item] then
            total = total + 1
            if not besideBall(seen, o) then wrong[#wrong + 1] = ("%s %s (%d,%d)"):format(mapId, o.item, o.x, o.y) end
          end
        end
      end
    end
    table.sort(wrong)
    check(total > 80 and #wrong == 0, ("each of the %d item balls is reachable with what the logic "
      .. "says its map needs%s"):format(total, #wrong > 0 and (": NOT " .. table.concat(wrong, ", ")) or ""))

    -- many seeds, 1 to 3 worlds, replayed as the team with every world's finds
    local okV, victories = pcall(require, "data.scripts.victories")
    local isProg = {}
    for _, id in ipairs(L.PROGRESSION) do isProg[id] = true end
    local function replay(plans)
      local have, got, changed = {}, {}, true
      while changed do
        changed = false
        for w, p in ipairs(plans) do
          for _, loc in ipairs(p.locations) do
            local c = p.content[loc.key] or (not loc.shuffled and loc.vanilla)
            if c and not got[w .. loc.key] and L.satisfied(loc.reqSet, have) then
              got[w .. loc.key], have[c.item], changed = true, true, true
            end
          end
        end
      end
      return L.satisfied(L.expand(L.GOAL), have)
    end
    local function cutAreas(species)
      local n = 0
      for _, mapId in ipairs(L.FIELD_MOVES[1].maps) do
        local any = false
        local t = (game.data.encounters[mapId] or {}).grass      -- water needs Surf
        for _, slot in ipairs(t and t.slots or {}) do
          for _, m in ipairs((game.data.pokemon[species[slot.species] or slot.species] or {}).tmhm or {}) do
            if m == "CUT" then any = true end
          end
        end
        if any then n = n + 1 end
      end
      return n
    end
    local built, stuck, lost, ship, noCut, rerolls = 0, {}, 0, 0, 0, 0
    for _, worlds in ipairs({ 1, 2, 3 }) do
      for seed = 1, 150 do
        local plans = {}
        for w = 1, worlds do
          local p = R.build({ seed = seed, data = game.data, victories = okV and victories or {},
                              logic = L, Rng = Rng, encounters = true, items = true, badges = true,
                              worlds = worlds, world = w })
          built, plans[w] = built + 1, p
          if (p.speciesTries or 1) > 1 then rerolls = rerolls + 1 end
          if cutAreas(p.species) < 3 then noCut = noCut + 1 end
          for _, loc in ipairs(p.locations) do
            local c = p.content[loc.key]
            if c and isProg[c.item] then
              if loc.kind == "hidden" or loc.reqSet.__NEVER__ then lost = lost + 1 end
              if (loc.map or ""):find("^SS_ANNE") then ship = ship + 1 end
            end
          end
        end
        if not (plans[1].ok and replay(plans)) then stuck[#stuck + 1] = seed .. "/" .. worlds end
      end
    end
    check(#stuck == 0, ("%d real worlds (150 seeds x 1-3 worlds): the team can always finish%s")
      :format(built, #stuck > 0 and (": NOT " .. table.concat(stuck, " ")) or ""))
    check(lost == 0 and ship == 0,
      "nothing the way on needs is hidden, post-game, or aboard the S.S. Anne (she sails)")
    check(noCut == 0, ("every world has wild Pokemon that learn Cut in 3+ early areas (%d reshuffled)")
      :format(rerolls))
  end

  local vanillaForest = {}
  for _, obj in ipairs(game.data.maps.VIRIDIAN_FOREST.objects or {}) do
    vanillaForest[#vanillaForest + 1] = obj.item or false
  end

  -- ---- connect as a new character on the modes server --------------------------------
  U.teleport(game, "PALLET_TOWN", 5, 6, "down")
  settled()
  U.tap(game, "start"); U.wait(10)
  choose("CONNECT")
  choose("^JOIN")
  choose("CREATE NEW PLAYER")
  local naming = top()
  if check(naming and naming.onDone, "the naming screen opens") then
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
  clearTexts()
  local r = Modes.rules
  if not check(r and r.nuzlocke == "hardcore" and r.randomizer and r.runId == 1 and r.seed == 4242,
      "the server's rules arrived: " .. tostring(r and Modes.describe())) then
    return finish()
  end
  check(Modes.state(game.save).run == 1, "the new character's save starts run 1")
  -- nuzlocke_trades = 1 (run_tests.sh): one trade per gym leader beaten
  check(r.tradesPerGym == 1 and Modes.tradesLeft(game.save) == 1,
    "the trade limit: 1 per gym leader, 1 left (" .. tostring(Modes.tradesLeft(game.save)) .. ")")
  local plan = Modes.plan()
  if not check(plan and plan.ok and plan.species, "the seed built a finishable world") then
    return finish()
  end

  -- ---- the starters ---------------------------------------------------------------------
  -- basic Pokémon that evolve twice: Red and Blue's three balls and Yellow's
  -- PIKACHU each get a different one
  local starters = plan.starters or {}
  local pool, okAll, distinct = {}, true, {}
  for _, id in ipairs(lib.randomizer.starterPool(game.data.pokemon)) do pool[id] = true end
  for _, v in ipairs(lib.randomizer.STARTERS) do
    if not (starters[v] and pool[starters[v]] and not distinct[starters[v]]) then okAll = false end
    distinct[starters[v] or "?"] = true
  end
  check(okAll, ("the starters: %s, %s, %s; Yellow's PIKACHU is %s"):format(tostring(starters.BULBASAUR),
    tostring(starters.CHARMANDER), tostring(starters.SQUIRTLE), tostring(starters.PIKACHU)))
  U.teleport(game, "OAKS_LAB", 5, 10, "up")
  settled()
  -- Red and Blue's ball rows through the mod's script hook (no Red/Blue data
  -- here): the Pokédex entry, the question, the received line and the gift
  local function through(name, ...)
    local got = nil
    ModRuntime.call("script.command", function(_, _, a) got = a end,
      { overworld = game.overworld, game = game, save = game.save }, name, { ... })
    return got
  end
  local newB = starters.BULBASAUR
  local nameB = (game.data.pokemon[newB] or {}).name or tostring(newB)
  local ask = through("ask", "_OaksLabYouWantBulbasaurText")
  check(ask and type(ask[1]) == "string" and ask[1]:find(nameB, 1, true) and ask[1]:find("POKéMON", 1, true),
    "Red's BULBASAUR ball asks about " .. nameB .. ": " .. tostring(ask and ask[1]):gsub("[\n\v\f]", " "))
  local dex = through("push_screen", "DexEntryMenu", { species = "BULBASAUR", forceOwned = true })
  check(dex and dex[2].species == newB and dex[2].forceOwned, "and shows its Pokédex entry")
  local got = through("show_text", "_OaksLabReceivedMonText", { RAM = "BULBASAUR" })
  check(got and got[2].RAM == newB, "the received line names it")
  local give = through("give_pokemon", "BULBASAUR", 5)
  check(give and give[1] == newB, "and it is the one given")
  local rival = through("show_text", "_OaksLabRivalReceivedMonText", { RAM = "CHARMANDER" })
  check(rival and rival[2].RAM == "CHARMANDER", "the rival's own line (and team) stay vanilla")
  check(through("show_text", "_OaksLabPikachuDislikesPokeballsText1") == nil
    and through("spawn_pikachu_follower") == nil, "Yellow's PIKACHU scene is left out")
  -- Yellow's own gift for real: Oak's rows through the overworld's runner
  local newP = starters.PIKACHU
  local nameP = (game.data.pokemon[newP] or {}).name or tostring(newP)
  local dexSeen, dexOwned = game.save.pokedex.seen[newP], game.save.pokedex.owned[newP]
  local partyBefore = #game.save.party
  game.overworld.runner:run({ { "show_text", "_OaksLabReceivedText", { RAM = "PIKACHU" } },
                              { "give_pokemon", "PIKACHU", 5 },
                              { "set_flag", "EVENT_CHOSE_PIKACHU" },
                              { "play_cry", "PIKACHU" },
                              { "show_text", "_OaksLabPikachuDislikesPokeballsText1" } })
  for _ = 1, 600 do
    local s = top()
    if isText(s) then clearTexts(1)
    elseif s ~= game.overworld then U.tap(game, "b"); U.wait(3)   -- no nickname
    elseif not (game.overworld.runner and game.overworld.runner:isRunning()) then break
    else U.wait(2) end
  end
  local mon = game.save.party[#game.save.party]
  check(#game.save.party == partyBefore + 1 and mon and mon.species == newP,
    "Oak hands over " .. nameP .. " instead of PIKACHU (" .. tostring(mon and mon.species) .. ")")
  check(said("received") ~= nil and said(nameP) ~= nil and said("OAK: What%?") == nil,
    "the received line names it; the PIKACHU scene (OAK: What?) is skipped")
  game.overworld.runner:run({ { "load_player_starter_name" } })
  U.wait(10)
  check(game.stringBuffer == nameP, "the Champion's room names it too (" .. tostring(game.stringBuffer) .. ")")
  -- the run's other checks start from where they were
  if #game.save.party > partyBefore then table.remove(game.save.party) end
  game.save.flags.EVENT_CHOSE_PIKACHU = nil
  game.save.pokedex.seen[newP], game.save.pokedex.owned[newP] = dexSeen, dexOwned

  -- ---- the randomizer -------------------------------------------------------------------
  U.teleport(game, "ROUTE_1", 9, 20, "down")
  settled()
  local ow = game.overworld
  local enc = ow:rollEncounter({ grass = { rate = 255, slots = (function()
    local s = {}
    for i = 1, 10 do s[i] = { level = 4, species = "PIDGEY" } end
    return s
  end)() } }, "grass")
  check(enc and enc.species == plan.species.PIDGEY and enc.level == 4,
    ("a wild PIDGEY roll comes out as %s (level kept)"):format(tostring(enc and enc.species)))
  -- wild_legendaries (off on this server): at 100% every roll is a legendary
  -- at its level (pinned across syncs, which bring the server's rules again)
  check(not Modes.rules.wildLegendaries or Modes.rules.wildLegendaries == 0, "wild legendaries are off here")
  local origSynced = Modes.synced
  Modes.synced = function(...)
    origSynced(...)
    if Modes.rules then Modes.rules.wildLegendaries = 100 end
  end
  Modes.rules.wildLegendaries = 100
  local legendRolls = {}
  local legendOk = true
  for _ = 1, 5 do
    local e = ow:rollEncounter({ grass = { rate = 255, slots = (function()
      local s = {}
      for i = 1, 10 do s[i] = { level = 4, species = "PIDGEY" } end
      return s
    end)() } }, "grass")
    if not (e and lib.randomizer.LEGENDARY[e.species] and e.level == 4) then legendOk = false end
    legendRolls[#legendRolls + 1] = tostring(e and e.species)
  end
  check(legendOk, "at 100%, Route 1's rolls are legendaries at level 4: " .. table.concat(legendRolls, ", "))
  -- randomize_trainers (off on this server), pinned the same way
  local pinnedTrainers = "off"
  Modes.synced = function(...)
    origSynced(...)
    if Modes.rules then Modes.rules.wildLegendaries, Modes.rules.trainers = 0, pinnedTrainers end
  end
  Modes.rules.wildLegendaries = 0
  local function types(list)
    local out = {}
    for i, sp in ipairs(list or {}) do out[i] = tostring(sp) .. ":" .. table.concat(game.data.pokemon[sp].types, "/") end
    return table.concat(out, " ")
  end
  local function allOf(list, kind)
    for _, sp in ipairs(list or { "?" }) do
      local t = (game.data.pokemon[sp] or {}).types or {}
      if t[1] ~= kind and t[2] ~= kind then return false end
    end
    return list ~= nil
  end
  pinnedTrainers = "gyms"
  Modes.rules.trainers = "gyms"
  local brockTeam = Modes.trainerTeam("OPP_BROCK", 1, { "GEODUDE", "ONIX" }, "PEWTER_GYM")
  check(allOf(brockTeam, "ROCK"), "trainers (gyms): Brock's team is Rock types: " .. types(brockTeam))
  check(table.concat(Modes.trainerTeam("OPP_BROCK", 1, { "GEODUDE", "ONIX" }, "PEWTER_GYM"), ",")
    == table.concat(brockTeam, ","), "the same every time")
  local lorelei = ModRuntime.call("trainer.party", function(_, _, party) return party end, "OPP_LORELEI", 1,
    { { species = "DEWGONG", level = 54 }, { species = "CLOYSTER", level = 53 },
      { species = "SLOWBRO", level = 54 }, { species = "JYNX", level = 56 }, { species = "LAPRAS", level = 56 } })
  local loreleiSpecies, levels = {}, true
  for i, slot in ipairs(lorelei or {}) do
    loreleiSpecies[i] = slot.species
    if slot.moves ~= nil or slot.level ~= ({ 54, 53, 54, 56, 56 })[i] then levels = false end
  end
  check(allOf(loreleiSpecies, "ICE") and levels,
    "through the game's trainer.party hook, Lorelei's are Ice types at her levels: " .. types(loreleiSpecies))
  check(Modes.trainerTeam("OPP_BUG_CATCHER", 1, { "CATERPIE", "WEEDLE" }, "ROUTE_3") == nil,
    "gyms: a route trainer keeps his team")
  pinnedTrainers = "on"
  Modes.rules.trainers = "on"
  local bug = Modes.trainerTeam("OPP_BUG_CATCHER", 1, { "CATERPIE", "WEEDLE" }, "ROUTE_3")
  check(bug and #bug == 2, "on: every trainer, at the same strength: " .. types(bug))
  Modes.synced = origSynced
  Modes.rules.trainers = "off"
  local changed = 0
  for i, obj in ipairs(game.data.maps.VIRIDIAN_FOREST.objects or {}) do
    if obj.item and obj.item ~= vanillaForest[i] then changed = changed + 1 end
  end
  check(changed > 0, "Viridian Forest's item balls are shuffled (" .. changed .. " changed)")

  -- an item ball: the first visible one in an early map
  local ball
  for _, loc in ipairs(plan.locations) do
    if loc.kind == "ball" and not loc.ref.hidden
        and (loc.map == "VIRIDIAN_FOREST" or loc.map == "MT_MOON_1F" or loc.map == "ROUTE_24") then
      ball = loc break
    end
  end
  if check(ball ~= nil, "found an item ball to pick up") then
    U.teleport(game, ball.map, ball.ref.x, ball.ref.y + 1, "up")
    settled()
    local npc
    for _, e in ipairs(game.overworld.entities or {}) do
      if e.def == ball.ref then npc = e break end
    end
    local want = plan.content[ball.key].item
    local before = inv(want)
    if check(npc ~= nil, "the ball is on the map") then
      game.overworld:talkTo(npc)
      clearTexts()
      check(inv(want) > before or (Modes.isShared(want) and inv(want) > 0),
        ("the ball at %s held %s (vanilla: %s)"):format(ball.key, want, ball.vanilla.item))
      check(said(itemName(want)) ~= nil, "and the text names it")
    end
  end

  -- an NPC gift row: the S.S. Anne captain's HM01 is something else now
  local gift = plan.gifts.HM_CUT
  game.overworld.runner:run({ { "give_item", "HM_CUT", 1, false },
                              { "show_text", "_SSAnneCaptainsRoomCaptainReceivedHM01Text" } })
  clearTexts()
  check(gift and inv(gift.item) > 0, "the captain's gift is " .. tostring(gift and gift.item))
  check(said("got " .. itemName(gift.item)) ~= nil or said(itemName(gift.item)) ~= nil,
    "and the received line names it")
  check(gift.item == "HM_CUT" or inv("HM_CUT") == 0, "HM01 itself isn't handed over there")

  -- a gym leader: Brock's badge slot
  local slot = plan.gyms["OPP_BROCK#1"]
  local hadBoulder = inv("BOULDERBADGE")
  game.overworld:checkVictoryRewards("OPP_BROCK", 1, true)
  clearTexts()
  check(game.save.flags.EVENT_BEAT_BROCK, "beating Brock still counts")
  check(slot and inv(slot.item) > 0, "Brock's reward is " .. tostring(slot and slot.item))
  if slot and slot.item ~= "BOULDERBADGE" then
    check(inv("BOULDERBADGE") == hadBoulder, "and not the BOULDERBADGE")
  end
  check(inv("TM_BIDE") > 0, "his TM34 is unchanged")
  check(game.data.text["_G1O_GYM_OPP_BROCK_1"] ~= nil
    and game.data.text["_G1O_GYM_OPP_BROCK_1"]:find(itemName(slot.item), 1, true) ~= nil,
    "his badge line names the new reward")
  -- a leader beaten opens a new trade allowance (no trades made yet)
  check(Modes.gymsBeaten(game.save) == 1 and Modes.tradesLeft(game.save) == 1,
    "after Brock: 1 leader beaten, 1 trade left (" .. tostring(Modes.tradesLeft(game.save)) .. ")")
  check((Modes.infoText(game.save) or ""):find("TRADES: 1 OF 1", 1, true) ~= nil,
    "RUN INFO's text has the trades left: " .. tostring(Modes.infoText(game.save)))

  -- ---- the team's shared key items --------------------------------------------------------
  local function teamItems()
    local res = post({ action = "team_status" })
    local set = {}
    for _, id in ipairs(res and res.team and res.team.items or {}) do set[id] = true end
    return set
  end
  local mine = {}
  for id in pairs(Modes.state(game.save).got) do mine[#mine + 1] = id end
  for _ = 1, 60 do
    U.wait(5)
    local team = teamItems()
    local all = #mine > 0
    for _, id in ipairs(mine) do if not team[id] then all = false end end
    if all then break end
  end
  local team = teamItems()
  local reached = #mine > 0
  for _, id in ipairs(mine) do reached = reached and team[id] == true end
  check(reached, "this player's finds reached the team: " .. table.concat(mine, ", "))

  -- a find whose report never reached the server (out of reach, or the game
  -- closed before it went) is kept in the save and sent with the next team update
  local team0, lostFind = teamItems(), nil
  for _, id in ipairs({ "POKE_FLUTE", "BIKE_VOUCHER", "GOLD_TEETH", "S_S_TICKET" }) do
    if not team0[id] and not Modes.state(game.save).got[id] then lostFind = id break end
  end
  local st0 = Modes.state(game.save)
  st0.found = st0.found or {}
  st0.found[lostFind], st0.got[lostFind] = true, true

  -- BUDDY joins and finds something; it reaches this player over sync_pos
  local buddy = post({ action = "register_player", isNewCharacter = true, name = "BUDDY",
                       spriteId = "SPRITE_BLUE", title = "TRAINER", badges = 0, pokedexCount = 0 })
  local gave
  for _, id in ipairs({ "SECRET_KEY", "CARD_KEY", "LIFT_KEY", "SILPH_SCOPE" }) do
    if inv(id) == 0 then gave = id break end
  end
  local res = post({ action = "team_found", trainerId = buddy.account.trainerId,
                     token = buddy.account.token, runId = 1, item = gave, itemName = gave })
  check(res and res.success and res.first, "BUDDY finds " .. gave .. " for the team")
  for _ = 1, 120 do
    U.wait(5)
    if inv(gave) > 0 then break end
  end
  check(inv(gave) > 0, "the team's " .. gave .. " is in this player's bag")
  clearTexts()
  check(said("YOUR TEAM FOUND") ~= nil, "with a 'your team found' box")
  local resent = false
  for _ = 1, 60 do
    if teamItems()[lostFind] then resent = true break end
    U.wait(5)
  end
  check(resent, "a find the server never heard of (" .. tostring(lostFind) .. ") is sent again")

  -- a full bag: the team's next find goes to the item PC, and the box says so;
  -- with no room at all it is not counted as received, and comes once there is
  local Bag = require("src.inventory.Bag")
  local realAddTo = Bag.addTo
  local full = { bag = true, pc = false }
  Bag.addTo = function(store, ...)
    if store ~= nil and ((full.bag and store == game.save.inventory)
        or (full.pc and store == game.save.pcItems)) then
      return false
    end
    return realAddTo(store, ...)
  end
  local spare = {}
  local teamNow = teamItems()
  for _, id in ipairs({ "EXP_ALL", "COIN_CASE", "ITEMFINDER", "HM_FLASH", "HM_FLY", "GOLD_TEETH",
                        "BIKE_VOUCHER", "S_S_TICKET" }) do
    if game.data.items[id] and Modes.isShared(id) and inv(id) == 0 and not teamNow[id] then
      spare[#spare + 1] = id
    end
  end
  local function teammateFinds(id)
    local res = post({ action = "team_found", trainerId = buddy.account.trainerId, token = buddy.account.token,
                       runId = Modes.rules.runId, item = id, itemName = id })
    return res and res.success
  end
  local toPc, nowhere = spare[1], spare[2]
  local function inPc(id) return ((game.save.pcItems or {})[id] or 0) > 0 end
  if check(toPc and nowhere and teammateFinds(toPc), "BUDDY finds " .. tostring(toPc) .. " while this bag is full") then
    for _ = 1, 120 do
      U.wait(5)
      if inPc(toPc) then break end
    end
    drain()
    check(inPc(toPc) and inv(toPc) == 0, "it went to the item PC")
    check(said("IN YOUR PC") ~= nil, "and the box says so")
    full.pc = true
    teammateFinds(nowhere)
    for _ = 1, 40 do U.wait(5) end
    check(inv(nowhere) == 0 and not inPc(nowhere) and not Modes.state(game.save).got[nowhere],
      "no room in the bag or the PC: " .. nowhere .. " is not counted as received")
    full.bag, full.pc = false, false
    for _ = 1, 120 do
      U.wait(5)
      if inv(nowhere) > 0 then break end
    end
    drain()
    check(inv(nowhere) > 0, "with room again, it arrives on a later sync")
  end

  -- a gym leader's prize with no room anywhere is owed, then handed over
  local owedKey
  for _, key in ipairs({ "OPP_MISTY#1", "OPP_LT_SURGE#1", "OPP_ERIKA#1", "OPP_KOGA#1", "OPP_SABRINA#1",
                         "OPP_BLAINE#1" }) do
    local c = plan.gyms[key]
    if c and not c.item:find("BADGE") and inv(c.item) == 0 then owedKey = key break end
  end
  if owedKey then
    local owedItem = plan.gyms[owedKey].item
    local cls, idx = owedKey:match("^(.-)#(%d+)$")
    full.bag, full.pc = true, true
    game.overworld:checkVictoryRewards(cls, tonumber(idx), true)
    clearTexts()
    full.bag, full.pc = false, false
    local owed = Modes.state(game.save).owed or {}
    check(owed[1] and owed[1].item == owedItem, ("%s's prize (%s) found no room: it is owed"):format(cls, owedItem))
    for _ = 1, 120 do
      U.wait(5)
      clearTexts(20)
      if inv(owedItem) > 0 or inPc(owedItem) then break end
    end
    drain()
    check((inv(owedItem) > 0 or inPc(owedItem)) and #(Modes.state(game.save).owed or {}) == 0
      and said("NO ROOM FOR") ~= nil, "and handed over once there is room")
  else
    say("  (every gym slot holds a badge this seed: the owed prize is not exercised)")
  end
  Bag.addTo = realAddTo

  -- RUN INFO in the ONLINE menu
  U.tap(game, "start"); U.wait(10)
  choose("ONLINE")
  if choose("RUN INFO") then
    U.wait(10)
    U.shot(game, out .. "/10_run_info.png")
    clearTexts()
    check(said("HARDCORE NUZLOCKE") and said("TEAM ITEMS") ~= nil, "RUN INFO shows the modes and the team's items")
  end
  while top() and top() ~= game.overworld do game.stack:pop() end

  -- ---- hardcore Nuzlocke -------------------------------------------------------------------
  local Pokemon = require("src.pokemon.Pokemon")
  local Party = require("src.pokemon.Party")
  game.save.party = game.save.party or {}
  for _, sp in ipairs({ "PIKACHU", "RATTATA", "PIDGEY" }) do
    Party.add(game.save.party, Pokemon.new(game.data, sp, 10))
  end
  game.save.inventory.POKE_BALL = 5
  game.save.pokedex = game.save.pokedex or { seen = {}, owned = {} }
  game.save.pokedex.owned = game.save.pokedex.owned or {}
  game.save.pokedex.owned.PIKACHU = true

  check(ModRuntime.call("battle.style", function() return "shift" end, {}) == "set",
    "battle style is SET")
  local cap = Modes.levelCap()
  check(ModRuntime.call("exp.gain", function() return 300 end, { mon = { level = cap } }) == 0
    and ModRuntime.call("exp.gain", function() return 300 end, { mon = { level = 5 } }) == 300,
    "no EXP at the level cap (" .. cap .. ")")
  check(Modes.levelCap({ inventory = {}, flags = {} }) == 12
    and Modes.levelCap({ inventory = { BOULDERBADGE = 1 }, flags = { EVENT_BEAT_BROCK = true } }) == 21,
    "in gym order the cap is the next leader's (Brock 12, then Misty 21)")
  check(Modes.levelCap({ inventory = { HM_SURF = 1, SOULBADGE = 1, SECRET_KEY = 1 },
                         flags = { EVENT_BEAT_BROCK = true, EVENT_BEAT_MISTY = true } }) == 54,
    "Blaine open first (shuffled badges, Surf before Cut): the cap is his 54")
  check(Modes.levelCap({ inventory = { CASCADEBADGE = 1 }, flags = { EVENT_BEAT_BROCK = true,
      EVENT_BEAT_MISTY = true, EVENT_BEAT_LT_SURGE = true, EVENT_BEAT_ERIKA = true } }) == 50,
    "four leaders beaten, one badge held: the cap is the fifth leader's (50)")

  local used = {}
  local function useItem(id, battle)
    ModRuntime.call("item.use", function() used[#used + 1] = id end, game, battle, id)
    U.wait(2)
    local refused = isText(top())
    clearTexts()
    return refused
  end
  local wild = { kind = "wild" }
  U.teleport(game, "ROUTE_1", 9, 20, "down")
  settled()
  ModRuntime.emit("battle.started", { battle = wild, kind = "wild", species = "RATTATA", level = 3 })
  check(not useItem("POKE_BALL", wild) and used[#used] == "POKE_BALL",
    "Route 1's first encounter can be caught")
  check(useItem("POTION", wild), "no items in battle")
  ModRuntime.emit("battle.ended", { battle = wild, result = "run" })
  ModRuntime.emit("battle.started", { battle = wild, kind = "wild", species = "SPEAROW", level = 3 })
  check(useItem("POKE_BALL", wild) and said("ALREADY HAD"), "Route 1's second encounter can't")
  ModRuntime.emit("battle.ended", { battle = wild, result = "run" })
  U.teleport(game, "ROUTE_2", 3, 60, "down")
  settled()
  -- no dupes clause: the first Pokémon met is the one, even an owned species
  ModRuntime.emit("battle.started", { battle = wild, kind = "wild", species = "PIKACHU", level = 3 })
  check(not useItem("POKE_BALL", wild) and Modes.state(game.save).areas.ROUTE_2 == "PIKACHU",
    "an owned species met first can be caught, and uses Route 2 up")
  ModRuntime.emit("battle.ended", { battle = wild, result = "run" })
  ModRuntime.emit("battle.started", { battle = wild, kind = "wild", species = "WEEDLE", level = 3 })
  check(useItem("POKE_BALL", wild) and said("ALREADY HAD"), "so Route 2's next one can't be")
  ModRuntime.emit("battle.ended", { battle = wild, result = "run" })

  -- a link battle (PVP) is friendly: nobody dies there
  game.save.party[2].hp = 0
  ModRuntime.emit("battle.ended", { battle = { kind = "link" }, result = "win" })
  check(#game.save.party == 3, "a PVP faint is not a death")
  ModRuntime.emit("battle.ended", { battle = wild, result = "win" })
  U.wait(4)
  clearTexts()
  check(#game.save.party == 2 and game.save.party[2].species == "PIDGEY",
    "a fainted Pokemon leaves the party for good")
  check(Modes.state(game.save).graveyard[1] and Modes.state(game.save).graveyard[1].species == "RATTATA",
    "and is remembered")
  check(said("GONE FOR GOOD") ~= nil, "with a goodbye")

  -- ---- a wipe ends the run for everyone ----------------------------------------------------
  local runBefore = Modes.rules.runId
  for _, m in ipairs(game.save.party) do m.hp = 0 end
  ModRuntime.emit("battle.ended", { battle = wild, result = "lose" })
  for _ = 1, 200 do
    U.wait(5)
    clearTexts(20)
    if Modes.state(game.save).run == runBefore + 1 then break end
  end
  drain()
  local st = Modes.state(game.save)
  check(Modes.rules.runId == runBefore + 1 and st.run == runBefore + 1,
    "the wipe started run " .. (runBefore + 1) .. " on the server and here")
  check(#(game.save.party or {}) == 0 and game.overworld.map.id == "REDS_HOUSE_2F",
    "everyone starts over in their bedroom with no Pokemon")
  check(game.save.onlineAccount and game.save.onlineAccount.name == "ASH", "as the same online character")
  check(inv(gave) == 0 and inv("BOULDERBADGE") == 0, "the team's items are gone with the run")
  check(Modes.plan() ~= plan and Modes.plan().seed ~= 4242, "the new run is a new world")
  check(said("RUN " .. (runBefore + 1) .. " BEGINS") ~= nil, "with a 'new run' box")
  U.shot(game, out .. "/20_new_run.png")

  -- a teammate's wipe ends this player's run too
  local run3 = post({ action = "run_wipe", trainerId = buddy.account.trainerId,
                      token = buddy.account.token, runId = runBefore + 1 })
  check(run3 and run3.run and run3.run.runId == runBefore + 2, "BUDDY's party wipes out")
  for _ = 1, 200 do
    U.wait(5)
    clearTexts(20)
    if Modes.state(game.save).run == runBefore + 2 then break end
  end
  drain()
  check(Modes.state(game.save).run == runBefore + 2, "this player follows into run " .. (runBefore + 2))
  check(said("A TEAMMATE'S PARTY WIPED OUT") ~= nil, "and is told why")

  -- a wipe the server never heard of (out of reach, then the game closed) is
  -- sent when the player connects again
  local runNow = Modes.rules.runId
  Modes.state(game.save).wiped = true
  Modes.connected(game, Modes.rules, false)
  for _ = 1, 200 do
    U.wait(5)
    clearTexts(20)
    if Modes.state(game.save).run == runNow + 1 then break end
  end
  drain()
  check(Modes.rules.runId == runNow + 1 and Modes.state(game.save).run == runNow + 1,
    "a wipe the server never heard of is sent on the next connect")

  -- ---- offline, the vanilla world is back ----------------------------------------------------
  local ashToken = game.save.onlineAccount.token
  U.tap(game, "start"); U.wait(10)
  choose("ONLINE")
  choose("DISCONNECT")
  clearTexts()
  U.wait(5)
  local restored = true
  for i, obj in ipairs(game.data.maps.VIRIDIAN_FOREST.objects or {}) do
    if (obj.item or false) ~= vanillaForest[i] then restored = false end
  end
  check(restored, "disconnected: Viridian Forest's items are vanilla again")
  local enc2 = game.overworld:rollEncounter({ grass = { rate = 255, slots = { { level = 4, species = "PIDGEY" },
    { level = 4, species = "PIDGEY" }, { level = 4, species = "PIDGEY" }, { level = 4, species = "PIDGEY" },
    { level = 4, species = "PIDGEY" }, { level = 4, species = "PIDGEY" }, { level = 4, species = "PIDGEY" },
    { level = 4, species = "PIDGEY" }, { level = 4, species = "PIDGEY" }, { level = 4, species = "PIDGEY" } } } }, "grass")
  check(enc2 and enc2.species == "PIDGEY", "and wild Pokemon are vanilla")
  check(ModRuntime.call("battle.style", function() return "shift" end, {}) == "shift",
    "and the battle style is the player's own")

  -- ---- a new device: the recovery token joins the run -----------------------------------------
  local runNow2 = runNow + 1
  local dir = love.filesystem.getSaveDirectory() .. "/mod_compat/gen1online-plus/"
  os.remove(dir .. "gen1online_online_account_yellow.lua")
  os.remove(dir .. "save_online_yellow.lua")
  settled()
  U.tap(game, "start"); U.wait(10)
  choose("CONNECT")
  choose("^JOIN")
  choose("REDEEM RECOVERY TOKEN")
  naming = top()
  if check(naming and naming.onDone, "a new device: REDEEM RECOVERY TOKEN asks for the token") then
    game.stack:pop()
    naming.onDone(ashToken, true)
    U.wait(6)
  end
  for _ = 1, 300 do
    clearTexts(40)
    if said("TOKEN REDEEMED") then break end
    U.wait(2)
  end
  drain()
  check(game.save.onlineAccount and game.save.onlineAccount.name == "ASH", "ASH is back")
  check(Modes.rules and Modes.rules.runId == runNow2 and Modes.state(game.save).run == runNow2,
    "in the team's run " .. runNow2 .. " (" .. tostring(Modes.state(game.save).run) .. ")")
  local shuffled = false
  for i, obj in ipairs(game.data.maps.VIRIDIAN_FOREST.objects or {}) do
    if (obj.item or false) ~= vanillaForest[i] then shuffled = true end
  end
  check(shuffled and Modes.plan() ~= nil, "and the shuffled world")

  return finish()
end
