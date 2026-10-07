-- The server's game modes on FireRed and LeafGreen: the co-op randomizer
-- (every wild Pokémon may be any of the 386; item balls, hidden items, some
-- gifts and the gym badges shuffled with progression logic), the team's
-- shared key items and badges, and the hardcore Nuzlocke.  The same interface as
-- modes/init.lua (Gen 1), so main.lua drives both alike:
--   M.precheck(game, rules), M.connected(game, rules, fresh),
--   M.synced(game, res), M.describe(), M.infoText(save), M.rules
-- Built by main.lua with ctx = { mod, requireLocal, G3, isOnline(), post(),
-- trainerId(save), writeOnlineSave(), storageWrite(), storedAccount(),
-- wrapText() }.  Everything is online-only and put back offline.
return function(ctx)
  local mod, G3 = ctx.mod, ctx.G3
  local Rng = ctx.requireLocal("modes/rng.lua")
  local L = ctx.requireLocal("modes/logic_frlg.lua")
  local Randomizer = ctx.requireLocal("modes/randomizer.lua")
  local Gen3Compat = require("src.mods.Gen3Compat")
  local Pokemon = require("src.core.game3.pokemon")
  local ItemsData = require("src.core.game3.items_data")
  local Items = require("src.core.game3.items")
  local Bag = require("src.core.game3.bag")
  local Flags = require("src.core.game3.scripting.flags")
  local ITEMS = require("src.core.game3.constants.firered.items")
  local Game = G3.game

  local M = { rules = nil, world = nil, lib = { Rng = Rng, logic = L, randomizer = Randomizer } }
  local plan, planKey, undo = nil, nil, nil
  local reports, retryAt = {}, 0
  local notes = {}
  local granting = false
  local lastTeamRev = nil
  local pendingRestart = false
  local wipeQueued, wipeRetryAt = false, 0
  local battleInfo, currentBattle = nil, nil
  local owedAt = 0

  local function online() return ctx.isOnline() and M.rules ~= nil end
  local function rules() return online() and M.rules or nil end
  function M.hardcore() local r = rules(); return r ~= nil and r.nuzlocke == "hardcore" end
  local function sharing() local r = rules(); return r ~= nil and r.sharedKeyItems == true end
  local function note(text) notes[#notes + 1] = text end
  local function session() return G3.session() end

  -- this player's mode state, in the online save (the session's modData)
  local function state()
    local d = G3.modData()
    local st = d.modes
    if type(st) ~= "table" then st = {}; d.modes = st end
    st.got = st.got or {}
    st.areas = st.areas or {}
    st.graveyard = st.graveyard or {}
    st.trades = st.trades or {}      -- { [leaders beaten] = Pokémon received }
    return st
  end
  M.state = state

  -- ---- names ----------------------------------------------------------------

  -- pret's item names without ITEM_ (TEA, HM01), and the badges.  A badge
  -- the shuffle puts in an item ball or a gift travels there as one of
  -- FireRed's unused item ids (ITEM_034..ITEM_03B), read as the badge.
  local BADGE_FLAG = 0x820          -- FLAG_BADGE01_GET .. +7
  local BADGE_ITEM = 52             -- ITEM_034: BADGE1 .. ITEM_03B: BADGE8
  local function isBadge(key) return type(key) == "string" and key:match("^BADGE%d$") ~= nil end
  local function badgeIndex(key) return tonumber(key:match("^BADGE(%d)$")) end
  local function badgeOfItem(id)
    local n = tonumber(id)
    return n and n >= BADGE_ITEM and n < BADGE_ITEM + 8 and (n - BADGE_ITEM + 1) or nil
  end
  local function itemKey(id)
    local b = badgeOfItem(id)
    if b then return "BADGE" .. b end
    local name = ITEMS.byId and ITEMS.byId.ITEM_ and ITEMS.byId.ITEM_[tonumber(id)]
    if not name then
      for k, v in pairs(ITEMS.byName or {}) do if v == tonumber(id) then name = k break end end
    end
    return name and name:gsub("^ITEM_", "") or nil
  end
  local function itemIdOf(key)
    if isBadge(key) then return BADGE_ITEM + badgeIndex(key) - 1 end
    local n = ITEMS.byName and ITEMS.byName["ITEM_" .. tostring(key)]
    return n
  end
  local function itemName(key)
    if isBadge(key) then
      local names = { "BOULDER", "CASCADE", "THUNDER", "RAINBOW", "SOUL", "MARSH", "VOLCANO", "EARTH" }
      return (names[badgeIndex(key)] or "?") .. "BADGE"
    end
    local id = itemIdOf(key)
    return (id and Items.displayName(id)) or tostring(key)
  end
  M.itemName = itemName
  local LEADER = { "BROCK", "MISTY", "LT. SURGE", "ERIKA", "KOGA", "SABRINA", "BLAINE", "GIOVANNI" }

  -- shared: badges, key items and HMs, but not the quest items one player's
  -- script consumes (Oak's Parcel, the fossils, the Bike Voucher...).  The
  -- TEA is shared: it is progression (L.PROGRESSION, the SAFFRON macro), and a
  -- multiworld keeps one copy for the whole team, so every player's own gate
  -- guards need the team's copy (st.got stops it arriving twice).
  -- dev/harness/modes_test.lua mirrors this list (FRLG_NOT_SHARED).
  local NOT_SHARED = { OAKS_PARCEL = true, BIKE_VOUCHER = true, DOME_FOSSIL = true,
    HELIX_FOSSIL = true, OLD_AMBER = true, GOLD_TEETH = true, RUBY = true,
    SAPPHIRE = true, METEORITE = true, FAME_CHECKER = true, TEACHY_TV = true }
  function M.isShared(key)
    if type(key) ~= "string" or NOT_SHARED[key] then return false end
    if isBadge(key) then return true end
    if key:match("^HM0%d$") then return true end
    local id = itemIdOf(key)
    return id ~= nil and ItemsData.pocketOf(id) == "KEY_ITEMS"
  end

  -- ---- the world's places (vanilla data) -----------------------------------

  local function bundle()
    local Space = require("src.core.game3.scripting.space")
    return Space.ensureBundle(), Space
  end

  -- the standard call: setorcopyvar 0x8000 ITEM, setorcopyvar 0x8001 COUNT,
  -- callstd (1 = find an item ball, 0 = obtain a gift)
  local function giveRow(rows, std)
    for i, row in ipairs(rows or {}) do
      local q, c = rows[i + 1], rows[i + 2]
      if row.op == "setorcopyvar" and row[1] == 0x8000 and type(row[2]) == "number" and row[2] < 0x4000
          and q and q.op == "setorcopyvar" and q[1] == 0x8001 and type(q[2]) == "number"
          and c and c.op == "callstd" and (c.std or c[1]) == std then
        return i
      end
    end
    return nil
  end

  local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
  end

  -- every place in a fixed order (the same on FireRed and LeafGreen: keyed by
  -- map and object, never by script address)
  local locsCache, locsBundle
  function M.locations()
    if locsCache and locsBundle == bundle() then return locsCache end
    locsBundle = bundle()
    local raw = G3.raw()
    local maps = raw and raw.data and raw.data.maps or {}
    local b = bundle()
    local scripts = b and b.scripts or {}
    local never = L.expand(L.MACROS.NEVER)
    local locs = {}
    local function add(loc, req)
      loc.reqSet = req and L.expand(req) or never
      locs[#locs + 1] = loc
    end
    for _, mapId in ipairs(sortedKeys(maps)) do
      local def = maps[mapId]
      for i, obj in ipairs(type(def) == "table" and def.objects or {}) do
        local rows = obj.scriptKey and scripts[obj.scriptKey]
        local at = rows and giveRow(rows, 1)
        if at then
          local key = itemKey(rows[at][2])
          if key then
            local spot = L.SPOTS[mapId] and L.SPOTS[mapId][key]
            add({ key = mapId .. "#" .. tostring(obj.localId or obj.index or i), kind = "ball", map = mapId,
                  vanilla = { item = key, count = math.max(1, rows[at + 1][2]) },
                  ref = { rows = rows, i = at }, x = obj.x, y = obj.y, shuffled = true },
                spot or L.MAPS[mapId])
          end
        end
      end
      for _, e in ipairs(type(def) == "table" and def.bgEvents or {}) do
        local key = e.type == "hidden_item" and (tonumber(e.item) or 0) > 0 and itemKey(e.item)
        if key then
          add({ key = ("hidden:%s:%d:%d"):format(mapId, e.x or 0, e.y or 0), kind = "hidden", map = mapId,
                vanilla = { item = key, count = math.max(1, tonumber(e.quantity) or 1) }, ref = e,
                shuffled = true }, L.MAPS[mapId])
        end
      end
    end
    -- gifts: the first script anywhere giving each listed item
    local found = {}
    for _, skey in ipairs(sortedKeys(scripts)) do
      local rows = scripts[skey]
      local at = giveRow(rows, 0)
      local key = at and itemKey(rows[at][2])
      if key and L.GIFTS[key] and not found[key] then
        found[key] = true
        add({ key = "gift:" .. key, kind = "gift", gift = key, vanilla = { item = key, count = 1 },
              ref = { rows = rows, i = at }, shuffled = true }, L.GIFTS[key])
      end
    end
    -- what never moves but the logic counts on
    for _, key in ipairs(sortedKeys(L.FIXED)) do
      add({ key = "fixed:" .. key, kind = "fixed", vanilla = { item = key, count = 1 }, shuffled = false },
        L.FIXED[key])
    end
    for _, key in ipairs(sortedKeys(L.GYMS)) do
      add({ key = "gym:" .. key, kind = "gym", victoryKey = key, vanilla = { item = key, count = 1 },
            shuffled = false }, L.GYMS[key])
    end
    locsCache = locs
    return locs
  end

  -- the places as a run shuffles them: items (balls, hidden items, gifts)
  -- and badges (the gym leaders' slots) each by their own rule
  function M.places(items, badges)
    local out = {}
    for i, loc in ipairs(M.locations()) do
      local shuffled = false
      if loc.kind == "gym" then shuffled = badges and true or false
      elseif loc.kind ~= "fixed" then shuffled = items and true or false end
      out[i] = setmetatable({ shuffled = shuffled }, { __index = loc })
    end
    return out
  end

  -- the shuffle's Pokémon: all 386, by internal number, with their strength
  local LEGENDARY_DEX = { 144, 145, 146, 150, 151, 243, 244, 245, 249, 250, 251,
    377, 378, 379, 380, 381, 382, 383, 384, 385, 386 }
  local speciesCache, legendCache
  function M.speciesData()
    if speciesCache then return speciesCache, legendCache end
    speciesCache, legendCache = {}, {}
    for nat = 1, 386 do
      local sp = Pokemon.speciesFromNational(nat)
      local st = sp and Pokemon.stats(sp)
      if st then
        -- evolutions too: the starters are basic Pokémon that evolve twice
        local evolutions = {}
        for _, e in ipairs(Pokemon.evolutions(sp) or {}) do
          local into = tonumber(e.target or e[3])
          if into and into > 0 then evolutions[#evolutions + 1] = { species = into } end
        end
        speciesCache[sp] = { baseStats = { st.hp, st.atk, st.def, st.spa, st.spd, st.spe }, dex = nat,
                             evolutions = evolutions, types = Pokemon.types(sp) }
      end
    end
    for _, nat in ipairs(LEGENDARY_DEX) do
      local sp = Pokemon.speciesFromNational(nat)
      if sp then legendCache[sp] = true end
    end
    return speciesCache, legendCache
  end

  -- a Pokémon that learns Cut in enough of the areas open before it
  local function fieldMovesOk(species)
    local Encounters = require("src.core.game3.encounters")
    pcall(Encounters.ensureLoaded)
    for _, need in ipairs(L.FIELD_MOVES) do
      local vanilla, now = 0, 0
      for _, mapId in ipairs(need.maps) do
        local t = Encounters.tableFor(mapId)
        local v, n = false, false
        for _, slot in ipairs(type(t) == "table" and t.land and t.land.slots or {}) do
          local sp = tonumber(slot.species)
          if sp then
            v = v or Pokemon.canLearnTmIndex(sp, need.tmIndex)
            n = n or Pokemon.canLearnTmIndex(species[sp] or sp, need.tmIndex)
          end
        end
        if v then vanilla = vanilla + 1 end
        if n then now = now + 1 end
      end
      if now < math.min(need.areas, vanilla) then return false end
    end
    return true
  end

  local function worlds(r)
    return (r and r.multiworld and tonumber(r.players)) or 1
  end

  -- Oak's three balls: BULBASAUR, CHARMANDER, SQUIRTLE (internal numbers are
  -- the national ones up to 251)
  local STARTERS = { 1, 4, 7 }

  local function buildPlan(r, world)
    local pokemon, legendary = M.speciesData()
    return Randomizer.build({ seed = r.seed, locations = M.places(r.items, r.badges), logic = L, Rng = Rng,
      encounters = r.encounters, items = r.items, badges = r.badges, worlds = worlds(r),
      world = world, pokemon = pokemon, legendary = legendary, fieldMovesOk = fieldMovesOk,
      fallbackItem = "POTION", starters = r.starters, starterIds = STARTERS })
  end

  -- ---- the starters -----------------------------------------------------------

  -- Each of Oak's balls puts its species in VAR_TEMP_2 (after its index in
  -- VAR_TEMP_1); the picture, the question and givemon read the variable.
  -- The question itself names the vanilla species and its type.
  local LAB = "FR_OAKS_LAB"
  local VAR_TEMP_1, VAR_TEMP_2 = 0x4001, 0x4002
  local TYPE_NAMES = { [0] = "NORMAL", "FIGHTING", "FLYING", "POISON", "GROUND", "ROCK", "BUG", "GHOST",
    "STEEL", "???", "FIRE", "WATER", "GRASS", "ELECTRIC", "PSYCHIC", "ICE", "DRAGON", "DARK" }
  local function typeName(species)
    local t = Pokemon.types(species)
    return TYPE_NAMES[t and t[1] or 0] or "NORMAL"
  end
  function M.starterRows()
    local raw = G3.raw()
    local def = raw and raw.data and raw.data.maps and raw.data.maps[LAB]
    local scripts = (bundle() or {}).scripts or {}
    local out = {}
    -- found by place, not value: once applied they hold the new species
    for _, obj in ipairs(type(def) == "table" and def.objects or {}) do
      local rows = obj.scriptKey and scripts[obj.scriptKey]
      for i, row in ipairs(rows or {}) do
        local prev = rows[i - 1]
        if row.op == "setvar" and row[1] == VAR_TEMP_2 and type(row[2]) == "number"
            and prev and prev.op == "setvar" and prev[1] == VAR_TEMP_1 then
          out[#out + 1] = row
        end
      end
    end
    return out
  end
  local function replacePlain(s, old, new)
    local at = s:find(old, 1, true)
    if not at then return s end
    return s:sub(1, at - 1) .. new .. replacePlain(s:sub(at + #old), old, new)
  end
  -- the text key of the question for a vanilla starter ("... X is your choice.").
  -- Only unambiguous on the vanilla texts: apply() looks up all three before
  -- rewriting any (a rewritten question may name another ball's species).
  function M.starterQuestion(vanilla)
    local text = (bundle() or {}).text or {}
    local mark = " " .. G3.speciesName(vanilla) .. " is your choice."
    for key, ir in pairs(text) do
      local first = type(ir) == "table" and ir[1]
      if type(first) == "table" and type(first.s) == "string" and first.s:find(mark, 1, true) then
        return key, ir
      end
    end
  end
  local function starterQuestionFor(ir, vanilla, species)
    local oldName, newName = G3.speciesName(vanilla), G3.speciesName(species)
    local oldKind, newKind = typeName(vanilla) .. " POKéMON", typeName(species) .. " POKéMON"
    local out = {}
    for i, tok in ipairs(ir) do
      local copy = {}
      for k, v in pairs(tok) do copy[k] = v end
      if type(copy.s) == "string" then
        copy.s = replacePlain(replacePlain(copy.s, oldName, newName), oldKind, newKind)
      end
      out[i] = copy
    end
    return out
  end

  -- balls and gifts: the item in the script's setorcopyvar rows; hidden
  -- items: the map event.  Returns undo().
  local function apply(p)
    local undoList = {}
    local function set(t, k, v)
      undoList[#undoList + 1] = { t, k, t[k] }
      t[k] = v
    end
    if p.starters then
      -- Every ball's question is looked up (by its vanilla name) BEFORE any
      -- is rewritten: the pool holds the vanilla three, so once one question
      -- names another ball's vanilla species, a lookup would find two texts
      -- and pairs() order would pick which one to rewrite.
      local text = (bundle() or {}).text
      local todo = {}
      for _, row in ipairs(M.starterRows()) do
        local from = row[2]
        local to = p.starters[from]
        if to then
          local key, ir = M.starterQuestion(from)
          todo[#todo + 1] = { row = row, from = from, to = to, key = key, ir = ir }
        end
      end
      for _, t in ipairs(todo) do
        set(t.row, 2, t.to)
        if t.row.value ~= nil then set(t.row, "value", t.to) end
        if text and t.key then set(text, t.key, starterQuestionFor(t.ir, t.from, t.to)) end
      end
    end
    for _, loc in ipairs(p.locations or {}) do
      local c = p.content[loc.key]
      local id = c and itemIdOf(c.item)
      if id then
        if loc.kind == "ball" or loc.kind == "gift" then
          set(loc.ref.rows[loc.ref.i], 2, id)
          set(loc.ref.rows[loc.ref.i + 1], 2, c.count or 1)
        elseif loc.kind == "hidden" then
          set(loc.ref, "item", id)
          set(loc.ref, "quantity", c.count or 1)
        end
      end
    end
    return function()
      for i = #undoList, 1, -1 do
        local u = undoList[i]
        u[1][u[2]] = u[3]
      end
    end
  end

  function M.refresh()
    local r = rules()
    local key = nil
    if r and r.randomizer and r.seed and G3.raw() and (worlds(r) == 1 or M.world) then
      key = ("%s/%s%s%s%s/%d:%d"):format(tostring(r.seed), tostring(r.encounters), tostring(r.items),
                                         tostring(r.badges), tostring(r.starters), worlds(r),
                                         worlds(r) > 1 and M.world or 1)
    end
    -- a new script bundle (the engine reloaded it) holds vanilla items again
    if key and planKey == key and locsBundle ~= bundle() then planKey = nil end
    if key == planKey then return end
    if undo then undo(); undo = nil end
    plan, planKey = nil, key
    if not key then return end
    plan = buildPlan(r, M.world)
    undo = apply(plan)
    if not plan.ok then
      note("THE RANDOMIZER COULDN'T SHUFFLE THIS GAME'S ITEMS. THEY STAY WHERE THEY ARE.")
    end
  end
  function M.plan() return plan end

  local function withVanilla(fn)
    if not undo then return fn() end
    undo()
    local ok, res = pcall(fn)
    undo = apply(plan)
    if not ok then error(res, 0) end
    return res
  end

  function M.planFor(world)
    local r = M.rules
    if not (r and r.randomizer and r.seed) then return nil end
    return withVanilla(function() return buildPlan(r, world) end)
  end

  -- ---- wild Pokémon -----------------------------------------------------------

  -- every wild battle (grass, water, fishing, Rock Smash, the scripted ones)
  -- starts here; a roamer and the Pokémon Tower's ghost keep their species
  local BattleBridge = require("src.core.game3.battle_bridge")
  local origStartWild = BattleBridge.startWild
  -- wild_legendaries: an ordinary wild encounter is now and then a legendary
  -- at its own level.  The field starts those (grass, water, caves, fishing,
  -- Rock Smash, Sweet Scent) with no options; a scripted battle always has
  -- some (its done callback at least) and keeps its Pokémon.
  local legendaryList = nil
  local function random() return ((love and love.math and love.math.random) or math.random)() end
  function M.wildLegendary(enc, opts)
    local r = rules()
    local chance = r and r.randomizer and tonumber(r.wildLegendaries) or 0
    if chance <= 0 or type(enc) ~= "table" or enc.roamer then return nil end
    if type(opts) == "table" and next(opts) ~= nil then return nil end
    if G3.currentMap() == "FR_POKEMON_TOWER_6F" then return nil end
    if not legendaryList then
      local pokemon, legendary = M.speciesData()
      legendaryList = Randomizer.legendaryList(legendary, pokemon)
    end
    return Randomizer.rollLegendary(chance, random, legendaryList)
  end

  BattleBridge.startWild = function(m, game, enc, opts, ...)
    local to = M.wildLegendary(enc, opts)
    local species = plan and plan.species
    if not to and species and type(enc) == "table" and not enc.roamer
        and G3.currentMap() ~= "FR_POKEMON_TOWER_6F" then
      local sp = tonumber(enc.species) or Pokemon.speciesFromName(enc.species)
      to = sp and species[sp]
    end
    if to then
      local copy = {}
      for k, v in pairs(enc) do copy[k] = v end
      copy.species, copy.speciesId = to, to
      -- the vanilla moves or personality belong to the vanilla species
      copy.moves, copy.personality = nil, nil
      enc = copy
    end
    return origStartWild(m, game, enc, opts, ...)
  end

  -- ---- trainers -----------------------------------------------------------------

  -- randomize_trainers: gym leaders, their gyms' trainers and the Elite Four
  -- keep their type; the Champion (and with "on" every other trainer) gets
  -- Pokémon of the same strength.  Each team comes from the run's seed and
  -- the trainer's number: the same every time, for every player.  Levels and
  -- held items stay; moves are the new Pokémon's own.
  local TYPE = { FIGHTING = 1, POISON = 3, GROUND = 4, ROCK = 5, GHOST = 7, FIRE = 10, WATER = 11,
    GRASS = 12, ELECTRIC = 13, PSYCHIC = 14, ICE = 15, DRAGON = 16 }
  local TRAINER_TYPE = { [414] = TYPE.ROCK, [415] = TYPE.WATER, [416] = TYPE.ELECTRIC,
    [417] = TYPE.GRASS, [418] = TYPE.POISON, [419] = TYPE.FIRE, [420] = TYPE.PSYCHIC,
    [350] = TYPE.GROUND,
    [410] = TYPE.ICE, [411] = TYPE.FIGHTING, [412] = TYPE.GHOST, [413] = TYPE.DRAGON,
    [735] = TYPE.ICE, [736] = TYPE.FIGHTING, [737] = TYPE.GHOST, [738] = TYPE.DRAGON }
  local CHAMPION = { [438] = true, [439] = true, [440] = true, [739] = true, [740] = true, [741] = true }
  local GYM_TYPE = { FR_PEWTER_CITY_GYM = TYPE.ROCK, FR_CERULEAN_CITY_GYM = TYPE.WATER,
    FR_VERMILION_CITY_GYM = TYPE.ELECTRIC, FR_CELADON_CITY_GYM = TYPE.GRASS,
    FR_FUCHSIA_CITY_GYM = TYPE.POISON, FR_SAFFRON_CITY_GYM = TYPE.PSYCHIC,
    FR_CINNABAR_ISLAND_GYM = TYPE.FIRE, FR_VIRIDIAN_CITY_GYM = TYPE.GROUND }
  M.TRAINER_TYPE, M.GYM_TYPE = TRAINER_TYPE, GYM_TYPE

  -- the new species for a trainer's team (species numbers), or nil to keep it
  function M.trainerTeam(trainerId, species, mapId)
    local r = rules()
    local mode = r and r.randomizer and r.trainers
    if mode ~= "gyms" and mode ~= "on" then return nil end
    local id = tonumber(trainerId)
    local theme = (id and TRAINER_TYPE[id]) or GYM_TYPE[mapId or G3.currentMap()]
    if not theme and not (id and CHAMPION[id]) and mode ~= "on" then return nil end
    local pokemon, legendary = M.speciesData()
    local salt = 30000 + Randomizer.saltOf(id or tostring(trainerId))
      + ((worlds(r) > 1 and M.world) or 0) * 1000
    return Randomizer.trainerTeam(Rng.new(r.seed, salt), species, pokemon, legendary, theme)
  end

  mod.hooks:wrap("trainer.party", function(nextFn, trainerClass, trainerId, party)
    local out = nextFn(trainerClass, trainerId, party)
    if type(out) ~= "table" or #out == 0 then return out end
    local species = {}
    for i, mon in ipairs(out) do
      species[i] = tonumber(mon.speciesId) or Pokemon.speciesFromName(mon.species) or 0
    end
    local new = M.trainerTeam(trainerId, species)
    if not new then return out end
    local copy = {}
    for i, mon in ipairs(out) do
      local row = {}
      for k, v in pairs(mon) do row[k] = v end
      row.species, row.speciesId = Gen3Compat.speciesName(new[i]) or new[i], new[i]
      -- the vanilla moves belong to the vanilla Pokémon
      row.moves, row.moveIds = nil, nil
      copy[i] = row
    end
    return copy
  end)

  -- a Johto or Hoenn Pokémon evolves before the National Pokédex: the shuffle
  -- hands them out from the first route
  local Evolution = require("src.core.game3.evolution")
  local origNational = Evolution.nationalAllows
  Evolution.nationalAllows = function(target, sess, ...)
    if plan and (plan.species or plan.starters) then return true end
    return origNational(target, sess, ...)
  end

  -- ---- the team's shared key items and badges --------------------------------

  local function report(key)
    local st = state()
    st.got[key] = true
    if sharing() then
      st.found = st.found or {}
      st.found[key] = true
      reports[#reports + 1] = key
    end
  end

  local function resend(team)
    local st = state()
    if not (M.rules and st.run == M.rules.runId and st.found) then return end
    local known = {}
    for _, id in ipairs(team.items or {}) do known[id] = true end
    for _, id in ipairs(reports) do known[id] = true end
    for id in pairs(st.found) do
      if not known[id] then reports[#reports + 1] = id end
    end
  end

  local function store()
    local Space = require("src.core.game3.scripting.space")
    return Space.store
  end

  -- a badge won, whoever hands it over (the flag.changed listener below
  -- reports it to the team)
  local origSetFlag = Flags.setFlag
  local function setBadge(i) origSetFlag(store(), nil, BADGE_FLAG + i - 1, true) end

  -- a badge in a ball or a gift is a marker item: named and pocketed as the
  -- badge (the find's text, "put away in the KEY ITEMS POCKET"), never full
  local origInfo = ItemsData.info
  ItemsData.info = function(id, ...)
    local b = plan and badgeOfItem(id)
    if not b then return origInfo(id, ...) end
    local info = {}
    for k, v in pairs(origInfo(id, ...) or {}) do info[k] = v end
    info.id, info.name, info.pocket = tonumber(id), itemName("BADGE" .. b), "KEY_ITEMS"
    return info
  end
  local origCanAdd = Bag.canAdd
  Bag.canAdd = function(bag, id, ...)
    if plan and badgeOfItem(id) then return true end
    return origCanAdd(bag, id, ...)
  end

  -- every find reaches the bag through Bag.add (balls, hidden items, gifts)
  local origAdd = Bag.add
  Bag.add = function(bag, id, qty, ...)
    local s = session()
    local b = plan and badgeOfItem(id)
    if b then
      -- the marker never lands in the bag: the badge is won instead
      if s and bag == s.bag then setBadge(b) end
      return true
    end
    local key = itemKey(id)
    if granting or not sharing() or not (s and bag == s.bag) or not M.isShared(key) then
      return origAdd(bag, id, qty, ...)
    end
    if Bag.get(bag, id) > 0 then
      report(key)       -- the team gave it already: this find is the team's
      return true
    end
    local ok = origAdd(bag, id, qty, ...)
    if ok then report(key) end
    return ok
  end

  -- badges are flags: a gym won reports its badge
  mod.events:on("flag.changed", function(ev)
    local id = type(ev) == "table" and tonumber(ev.id)
    if not (id and ev.value and id >= BADGE_FLAG and id < BADGE_FLAG + 8) then return end
    if granting or not sharing() then return end
    report("BADGE" .. (id - BADGE_FLAG + 1))
  end)

  -- "bag", "pc" or nil (no room)
  local function give(key, count)
    local s = session()
    if not s then return nil end
    if isBadge(key) then
      granting = true
      Flags.setFlag(store(), nil, BADGE_FLAG + badgeIndex(key) - 1, true)
      granting = false
      return "bag"
    end
    local id = itemIdOf(key)
    if not id then return nil end
    granting = true
    local ok = Bag.add(s.bag, id, count or 1)
    granting = false
    if ok then return "bag" end
    local Storage = require("src.core.game3.storage")
    if Storage.addPcItem and Storage.addPcItem(s, id, count or 1) then return "pc" end
    return nil
  end

  -- this player's own find handed over by the mod (a gym leader's slot):
  -- "bag", "pc" or nil (no room at all)
  local function receive(key, count)
    local s = session()
    if not s then return nil end
    if isBadge(key) then setBadge(badgeIndex(key)) return "bag" end
    local id = itemIdOf(key)
    if not id then return nil end
    -- Bag.add reports a shared find itself; the item PC doesn't
    if Bag.add(s.bag, id, count or 1) then return "bag" end
    local Storage = require("src.core.game3.storage")
    if Storage.addPcItem and Storage.addPcItem(s, id, count or 1) then
      if M.isShared(key) then report(key) end
      return "pc"
    end
    return nil
  end

  local function owe(key, count)
    local st = state()
    st.owed = st.owed or {}
    table.insert(st.owed, { item = key, count = count or 1 })
    note("NO ROOM FOR " .. itemName(key) .. "!\fMAKE ROOM IN YOUR BAG OR PC TO GET IT.")
  end

  -- A gym leader's script sets its badge's flag: with the badges shuffled,
  -- the slot hands over what the seed put there instead.
  Flags.setFlag = function(st, sctx, id, on, ...)
    local n = tonumber(id) or (type(id) == "string" and Flags.IDS and Flags.IDS[id]) or nil
    if on and sctx ~= nil and not granting and n and n >= BADGE_FLAG and n < BADGE_FLAG + 8
        and online() and plan and plan.gyms then
      local i = n - BADGE_FLAG + 1
      local c = plan.gyms["BADGE" .. i]
      if c and c.item ~= "BADGE" .. i then
        local where = receive(c.item, c.count)
        if not where then
          owe(c.item, c.count)
        else
          note(("%s'S BADGE WAS SHUFFLED!\fYOU GOT %s INSTEAD%s."):format(LEADER[i], itemName(c.item),
            where == "pc" and " (SENT TO YOUR PC)" or ""))
        end
        return
      end
    end
    return origSetFlag(st, sctx, id, on, ...)
  end

  function M.applyTeam(team)
    if not (type(team) == "table" and sharing() and session()) then return end
    if team.rev ~= nil and team.rev == lastTeamRev then return end
    lastTeamRev = team.rev
    local st = state()
    local names = {}
    for _, key in ipairs(team.items or {}) do
      if M.isShared(key) and not st.got[key] then
        local have = isBadge(key) and Flags.getFlag(store(), nil, BADGE_FLAG + badgeIndex(key) - 1)
          or (not isBadge(key) and itemIdOf(key) and Bag.get(session().bag, itemIdOf(key)) > 0)
        local where = have and "bag" or give(key, 1)
        if where then
          st.got[key] = true
          if not have then names[#names + 1] = itemName(key) .. (where == "pc" and " (IN YOUR PC)" or "") end
        else
          lastTeamRev = nil
        end
      end
    end
    resend(team)
    if #names > 0 then
      ctx.writeOnlineSave()
      note("YOUR TEAM FOUND " .. table.concat(names, ", ") .. "!")
    end
  end

  local function trainerId() return ctx.trainerId(Game.save) end
  local function token()
    local acc = G3.modData().onlineAccount
    return acc and acc.token or nil
  end

  local function postReports(now)
    local key = reports[1]
    if not key or now < retryAt then return end
    local res = ctx.post({ action = "team_found", trainerId = trainerId(), token = token(),
                           runId = state().run, item = key, itemName = itemName(key),
                           location = Gen3Compat.gen1MapId(G3.currentMap()) }, 3.0)
    if res == nil then retryAt = now + 3 return end
    table.remove(reports, 1)
    if res.success and res.team then M.applyTeam(res.team) end
  end

  -- ---- hardcore Nuzlocke --------------------------------------------------------

  -- the next gym leader's ace, by badges held, by leaders beaten, and the
  -- weakest leader this player can reach and hasn't beaten
  local CAPS = { 14, 21, 24, 29, 43, 43, 47, 50, 63 }
  local LEADERS = { "FLAG_DEFEATED_BROCK", "FLAG_DEFEATED_MISTY", "FLAG_DEFEATED_LT_SURGE",
    "FLAG_DEFEATED_ERIKA", "FLAG_DEFEATED_KOGA", "FLAG_DEFEATED_SABRINA", "FLAG_DEFEATED_BLAINE",
    "FLAG_DEFEATED_LEADER_GIOVANNI" }

  -- gym leaders this player has beaten: their defeat flags, never the badges
  -- held (the randomizer moves the badges).  The save argument is Gen 1's
  -- (one interface); here it is the live session's.
  function M.gymsBeaten()
    local beaten = 0
    for i = 1, #LEADERS do
      if Gen3Compat.getFlag(LEADERS[i]) then beaten = beaten + 1 end
    end
    return beaten
  end

  function M.levelCap()
    local s = session()
    local have = {}
    for _, pocket in pairs(s and s.bag and s.bag.pockets or {}) do
      for _, slot in ipairs(type(pocket) == "table" and pocket or {}) do
        local key = type(slot) == "table" and itemKey(slot.id)
        if key and (tonumber(slot.qty or slot.count) or 1) > 0 then have[key] = true end
      end
    end
    local held, beaten, weakest = 0, M.gymsBeaten(), 0
    for i = 1, 8 do
      if Flags.getFlag(store(), nil, BADGE_FLAG + i - 1) then held = held + 1; have["BADGE" .. i] = true end
    end
    for i = 1, 8 do
      if not Gen3Compat.getFlag(LEADERS[i])
          and L.satisfied(L.expand(L.GYMS["BADGE" .. i]), have) and (weakest == 0 or CAPS[i] < weakest) then
        weakest = CAPS[i]
      end
    end
    return math.max(CAPS[held + 1] or 100, CAPS[beaten + 1] or 100, weakest)
  end

  -- Trades (hardcore, tradesPerGym > 0): the Pokémon this player may receive
  -- online (a GTS buy or claim, a Wonder Trade, a link trade) between two gym
  -- leaders.  A stretch is the number of leaders beaten, so beating one opens
  -- a fresh allowance, and a new run (a new state) starts over.  0: no limit.
  function M.tradeLimit()
    if not M.hardcore() then return 0 end
    return math.max(0, tonumber(rules().tradesPerGym) or 0)
  end

  local function tradesUsed()
    return tonumber(state().trades[tostring(M.gymsBeaten())]) or 0
  end

  -- nil: no limit
  function M.tradesLeft()
    local limit = M.tradeLimit()
    if limit <= 0 then return nil end
    return math.max(0, limit - tradesUsed())
  end

  -- nil when a trade may go ahead, else why not
  function M.tradeRefusal()
    local left = M.tradesLeft()
    if left == nil or left > 0 then return nil end
    if M.gymsBeaten() >= #LEADERS then
      return "HARDCORE NUZLOCKE: NO TRADES LEFT!\fNO GYM LEADERS ARE LEFT TO BEAT."
    end
    local limit = M.tradeLimit()
    return ("HARDCORE NUZLOCKE: %s SINCE YOUR LAST GYM LEADER!\fBEAT THE NEXT ONE TO TRADE AGAIN.")
      :format(limit > 1 and ("YOU ALREADY MADE YOUR %d TRADES"):format(limit) or "YOU ALREADY TRADED")
  end

  local function leftText(left)
    return (M.gymsBeaten() >= #LEADERS and "%d LEFT." or "%d LEFT UNTIL THE NEXT GYM LEADER."):format(left)
  end

  -- A trade made: counted in this stretch.  Returns the trades left.  `what`
  -- names it for the note (a GTS buy, a link trade...).  The first argument
  -- is Gen 1's save (one interface); the state here is the session's.
  function M.tradeDone(_, what)
    if M.tradeLimit() <= 0 or not session() then return nil end
    local st, key = state(), tostring(M.gymsBeaten())
    st.trades[key] = (tonumber(st.trades[key]) or 0) + 1
    ctx.writeOnlineSave()
    local left = M.tradesLeft()
    note(("%s USED A TRADE: %s"):format(what or "THAT", leftText(left)))
    return left
  end

  -- A GTS or Wonder Trade deposit is the trade: it uses the allowance when it
  -- goes in, so whatever comes back for it is always the player's to claim
  -- (nothing is ever stuck in a claim box or the pool).  Taking the deposit
  -- back in the same stretch gives the trade back.
  function M.tradeReserve(_, id, what)
    local left = M.tradeDone(nil, what)
    if left == nil then return nil end
    local st, key = state(), tostring(M.gymsBeaten())
    -- only this stretch's deposits can be taken back for a refund: older
    -- entries are spent, so they go (the save doesn't grow with every deposit)
    local reserved = {}
    for k, v in pairs(st.reserved or {}) do if v == key then reserved[k] = v end end
    reserved[tostring(id)] = key
    st.reserved = reserved
    ctx.writeOnlineSave()
    return left
  end

  function M.tradeRelease(_, id)
    if M.tradeLimit() <= 0 or not session() then return nil end
    local st, key = state(), tostring(M.gymsBeaten())
    local stretch = st.reserved and st.reserved[tostring(id)]
    if st.reserved then st.reserved[tostring(id)] = nil end
    if stretch ~= key then return M.tradesLeft() end   -- an older stretch's trade: spent
    st.trades[key] = math.max(0, (tonumber(st.trades[key]) or 0) - 1)
    ctx.writeOnlineSave()
    local left = M.tradesLeft()
    note("TRADE TAKEN BACK: " .. leftText(left))
    return left
  end

  -- a leader beaten opens a new stretch.  His defeat flag is the game's own
  -- (the mod never grants one, so granting doesn't matter); the event names
  -- it, or gives its number, resolved through Flags.IDS once it is filled.
  local LEADER_NAME, leaderIds = {}, nil
  for _, name in ipairs(LEADERS) do LEADER_NAME[name] = true end
  local function isLeaderFlag(ev)
    if LEADER_NAME[ev.name] then return true end
    local n = tonumber(ev.id)
    if not n then return false end
    local ids = leaderIds
    if not ids then
      ids = {}
      local found = 0
      for _, name in ipairs(LEADERS) do
        local v = Flags.IDS and Flags.IDS[name]
        if v then ids[v] = true; found = found + 1 end
      end
      if found == #LEADERS then leaderIds = ids end   -- else ask again next time
    end
    return ids[n] == true
  end
  mod.events:on("flag.changed", function(ev)
    if not (type(ev) == "table" and ev.value and isLeaderFlag(ev)) then return end
    local limit = M.tradeLimit()
    if limit > 0 then
      note(("GYM LEADER BEATEN! YOU MAY TRADE %d MORE TIME%s."):format(limit, limit == 1 and "" or "S"))
    end
  end)

  -- SET: no switching after a knockout
  local Options = require("src.core.game3.options")
  local origStyle = Options.battleStyle
  Options.battleStyle = function(...)
    if M.hardcore() then return "set" end
    return origStyle(...)
  end

  -- No EXP at the cap, and none past it below: one battle's EXP stops just
  -- short of cap + 1, so a Pokémon a level under the cap can't jump over it.
  -- src.core.game3.battle.experience: apply() first resets an exp outside
  -- the level's span to the level's threshold (syncExpToLevel), then adds
  -- the gain on the mon's growth curve (expForLevel); the clamp does alike.
  local okX, Exp3 = pcall(require, "src.core.game3.battle.experience")
  if not (okX and type(Exp3) == "table" and Exp3.expForLevel) then Exp3 = nil end
  mod.hooks:wrap("exp.gain", function(nextFn, c)
    local gained = nextFn(c)
    if M.hardcore() and type(c) == "table" and type(c.mon) == "table" then
      local mon, cap = c.mon, M.levelCap()
      local level = tonumber(mon.level) or 0
      if level >= cap then return 0 end
      if Exp3 and level >= 1 and cap < (Exp3.MAX_LEVEL or 100) and tonumber(gained) then
        local at, nxt = Exp3.expForLevel(mon, level), Exp3.expForLevel(mon, level + 1)
        local exp = tonumber(mon.exp)
        if not exp or exp < at or exp >= nxt then exp = at end
        local limit = Exp3.expForLevel(mon, cap + 1) - 1
        gained = math.max(0, math.min(math.floor(tonumber(gained)), limit - exp))
      end
    end
    return gained
  end)

  -- no items in battle: the bag offers CANCEL only, as for a key item
  local BattleItems = require("src.core.game3.battle.items")
  local origUsable = BattleItems.isBattleUsable
  BattleItems.isBattleUsable = function(id, ...)
    if currentBattle and currentBattle.kind ~= "link" and M.hardcore() and not BattleItems.isBall(id) then
      return false
    end
    return origUsable(id, ...)
  end

  -- a ball the catch rules refuse: the game's own "box is full" stop (bag
  -- and the Safari Zone's BALL alike), saying why instead
  local refusal = nil
  local BagMenu = require("src.ui.game3.bag_menu")
  local origFull = BagMenu.partyAndStorageFull
  BagMenu.partyAndStorageFull = function(...)
    if M.hardcore() and battleInfo and not battleInfo.catchable then
      refusal = battleInfo.why
      return true
    end
    return origFull(...)
  end
  local RomText = require("src.core.game3.rom_text")
  local origBox = RomText.box
  RomText.box = function(key, ...)
    if refusal and (key == "gText_BoxFull" or key == "gOtherText_BoxIsFull") then
      local why = refusal
      refusal = nil
      return why
    end
    return origBox(key, ...)
  end
  local BattleText = require("src.core.game3.battle.battle_text")
  local origText = BattleText.get
  BattleText.get = function(key, ...)
    if refusal and key == "STRINGID_BOXISFULL" then
      local why = refusal
      refusal = nil
      return why
    end
    return origText(key, ...)
  end

  local function hasBalls()
    local s = session()
    for _, pocket in pairs(s and s.bag and s.bag.pockets or {}) do
      for _, slot in ipairs(type(pocket) == "table" and pocket or {}) do
        if type(slot) == "table" and BattleItems.isBall(slot.id) and (tonumber(slot.qty or slot.count) or 1) > 0 then
          return true
        end
      end
    end
    return false
  end

  -- The first wild Pokémon in each area (map) is the only one that may be
  -- caught, whatever it is.  Until the player first has Poké Balls (Route 1
  -- and 22 before Oak's parcel) nothing counts; from then on every area's
  -- first encounter does, even with no ball in the bag.
  mod.events:on("battle.started", function(ev)
    battleInfo = nil
    currentBattle = type(ev) == "table" and ev or nil
    if not (M.hardcore() and type(ev) == "table" and ev.kind == "wild") then return end
    -- nothing to catch: the old man's demo, the POKé DUDE, a ghost
    local b = type(ev.battle) == "table" and ev.battle or {}
    if b.oldManTutorial or b.pokedude or b.ghost or b.noCatch then return end
    local st = state()
    -- (a save from before this rule: an area already used means it had balls)
    if not st.hadBalls and (hasBalls() or b.safari or next(st.areas)) then st.hadBalls = true end
    if not st.hadBalls then return end
    local area = G3.currentMap() or "?"
    if st.areas[area] then
      battleInfo = { catchable = false, why = "NUZLOCKE: YOU ALREADY HAD YOUR ENCOUNTER HERE!" }
    else
      st.areas[area] = tonumber(ev.speciesId) or true
      battleInfo = { catchable = true }
    end
  end)

  function M.wipe()
    local st = state()
    if st.wiped then return end
    st.wiped = true
    ctx.writeOnlineSave()
    wipeQueued = true
    note("YOUR WHOLE PARTY FAINTED!\fTHE RUN IS OVER FOR THE WHOLE TEAM.")
  end

  function M.bury(lost)
    local s = session()
    if not (s and type(s.party) == "table") then return end
    local st = state()
    if st.wiped or #s.party == 0 then return end
    local alive, names = 0, {}
    for _, m in ipairs(s.party) do
      if (tonumber(m.hp) or 0) > 0 and not m.isEgg then alive = alive + 1 end
    end
    if lost or alive == 0 then return M.wipe() end
    for i = #s.party, 1, -1 do
      local m = s.party[i]
      if (tonumber(m.hp) or 0) <= 0 and not m.isEgg then
        table.remove(s.party, i)
        local name = G3.monName(m)
        table.insert(st.graveyard, { species = m.species, name = name, level = m.level,
                                     map = G3.currentMap(), time = os.time() })
        table.insert(names, 1, name)
      end
    end
    if #names > 0 then
      ctx.writeOnlineSave()
      note(table.concat(names, ", ") .. (#names > 1 and " ARE" or " IS") .. " GONE FOR GOOD...")
    end
  end

  mod.events:on("battle.ended", function(ev)
    local battle = currentBattle
    battleInfo, currentBattle = nil, nil
    if not M.hardcore() then return end
    -- link battles are friendly; the first rival fight in Oak's lab never costs
    if battle and battle.kind == "link" then return end
    if G3.currentMap() == "FR_OAKS_LAB" then return end
    local result = type(ev) == "table" and ev.result
    M.bury(result == "lose" or result == "whiteout" or result == "blackout")
  end)

  mod.events:on("world.blacked_out", function()
    if M.hardcore() then M.wipe() end
  end)

  -- ---- the run --------------------------------------------------------------

  -- A new run: the old online game is kept as a backup and the player starts
  -- a new game in the bedroom, with the same online character.
  function M.restart(game)
    pendingRestart = false
    local r = M.rules
    local s = session()
    if not (r and s) then return end
    local old = G3.snapshot()
    local oldRun = tonumber(state().run) or 0
    pcall(ctx.storageWrite, ("online_save_%s_run%d_backup"):format(G3.version, oldRun), old)
    local acc = G3.modData().onlineAccount
    local save = G3.newGameSave(s.name, s.gender, acc and acc.trainerId)
    G3.enter(save)
    local d = G3.modData()
    d.onlineAccount = acc
    d.modes = { run = r.runId, seed = r.seed, world = M.world }
    lastTeamRev, battleInfo, reports = nil, nil, {}
    M.refresh()
    ctx.writeOnlineSave()
    local res = ctx.post({ action = "team_status", trainerId = trainerId() }, 3.0)
    if res and res.success then M.applyTeam(res.team) end
    note(("RUN %d BEGINS!\f%s"):format(r.runId, M.describe()))
  end

  local wipeWarned = false
  local function postWipe(now)
    if now < wipeRetryAt then return end
    local res = ctx.post({ action = "run_wipe", trainerId = trainerId(), token = token(),
                           runId = state().run }, 3.0)
    if res == nil then wipeRetryAt = now + 3 return end
    if not res.success and res.error ~= "NOT_NUZLOCKE" then
      -- refused (an account problem): never dropped in silence
      if not wipeWarned then
        wipeWarned = true
        note(("THE SERVER WOULDN'T TAKE YOUR TEAM WIPE (%s).\fIT WILL KEEP TRYING."):format(tostring(res.error)))
      end
      wipeRetryAt = now + 30
      return
    end
    wipeQueued, wipeWarned = false, false
    if res.success and res.run then
      M.rules = res.run
      pendingRestart = true
    end
  end

  -- ---- the multiworld ----------------------------------------------------------

  local function gameName() return G3.version:upper() end

  -- the item places, as the server compares them between players (FireRed
  -- and LeafGreen share them: keys are maps and objects, not addresses)
  local function fingerprint()
    return withVanilla(function() return Randomizer.fingerprint(M.locations()) end)
  end

  local function join(r, account)
    local res = ctx.post({ action = "run_join", trainerId = account and account.trainerId,
                           token = account and account.token, fingerprint = fingerprint(),
                           gameName = gameName() }, 3.0)
    if res and not res.success
        and (res.error == "UNKNOWN_TRAINER" or res.error == "INVALID_TOKEN") and account then
      return join(r, nil)
    end
    return res
  end

  local function refusalText(res, r)
    if not res then return "COULDN'T JOIN THE RUN: THE SERVER DIDN'T ANSWER." end
    if res.error == "RUN_FULL" then
      return ("THIS RUN IS FULL: ALL %d WORLDS ARE TAKEN. ASK THE HOST FOR A SPOT.")
        :format(tonumber(res.players) or worlds(r))
    elseif res.error == "WRONG_WORLD_DATA" then
      return ("THIS RUN IS PLAYED ON POKéMON %s. YOUR GAME'S WORLD IS DIFFERENT, SO IT CAN'T JOIN.")
        :format(tostring(res.gameName or "ANOTHER GAME"))
    end
    return "COULDN'T JOIN THE RUN: " .. tostring(res.error or "UNKNOWN ERROR") .. "."
  end

  function M.precheck(game, serverRules)
    local r = type(serverRules) == "table" and serverRules or nil
    if not (r and r.active and r.multiworld and worlds(r) > 1) then return nil end
    local acc = ctx.storedAccount and ctx.storedAccount()
    local res = join(r, type(acc) == "table" and acc.token and acc or nil)
    if res and res.success then return nil end
    return refusalText(res, r)
  end

  function M.describe()
    local r = M.rules
    if not (r and r.active) then return "" end
    local parts = {}
    if r.nuzlocke == "hardcore" then
      local n = tonumber(r.tradesPerGym) or 0
      parts[#parts + 1] = "HARDCORE NUZLOCKE"
        .. (n > 0 and (" (%d TRADE%s PER GYM LEADER)"):format(n, n == 1 and "" or "S") or "")
    end
    if r.randomizer then parts[#parts + 1] = "RANDOMIZER" end
    if r.multiworld then
      parts[#parts + 1] = ("MULTIWORLD (YOU ARE WORLD %s OF %d)"):format(tostring(M.world or "?"), worlds(r))
    end
    if r.sharedKeyItems then parts[#parts + 1] = "SHARED KEY ITEMS" end
    return ("MODES: %s. RUN %s."):format(table.concat(parts, ", "), tostring(r.runId))
  end

  function M.infoText()
    local st = state()
    local lines = { M.describe() }
    if M.hardcore() then
      lines[#lines + 1] = ("LEVEL CAP: %d."):format(M.levelCap())
      local limit = M.tradeLimit()
      if limit > 0 then
        lines[#lines + 1] = (M.gymsBeaten() >= #LEADERS and "TRADES: %d OF %d LEFT."
          or "TRADES: %d OF %d LEFT UNTIL THE NEXT GYM LEADER."):format(M.tradesLeft(), limit)
      end
      local dead = {}
      for _, g in ipairs(st.graveyard) do dead[#dead + 1] = tostring(g.name) end
      lines[#lines + 1] = #dead > 0 and ("FALLEN: " .. table.concat(dead, ", ") .. ".") or "NO POKéMON LOST YET."
    end
    if M.rules and M.rules.multiworld and plan and plan.ok then
      lines[#lines + 1] = ("YOUR WORLD HOLDS %d OF THE TEAM'S %d KEY ITEMS AND BADGES."):format(
        plan.myProgression or 0, plan.totalProgression or 0)
    end
    if sharing() then
      local got = {}
      for key in pairs(st.got) do got[#got + 1] = itemName(key) end
      table.sort(got)
      lines[#lines + 1] = #got > 0 and ("TEAM ITEMS: " .. table.concat(got, ", ") .. ".")
        or "THE TEAM HASN'T FOUND ANY KEY ITEMS YET."
    end
    return table.concat(lines, "\f")
  end

  -- ---- main.lua's calls ------------------------------------------------------

  local refusedRun = nil      -- the run whose world was refused (M.synced asks once)
  function M.connected(game, serverRules, fresh)
    M.rules = (type(serverRules) == "table" and serverRules.active) and serverRules or nil
    M.world = nil
    lastTeamRev, reports, wipeQueued, pendingRestart = nil, {}, false, false
    if not M.rules or not session() then return end
    if M.rules.multiworld and worlds(M.rules) > 1 then
      local res = join(M.rules, G3.modData().onlineAccount)
      if not (res and res.success and res.world) then
        game.stack:push(G3.TextBox.new(game, ctx.wrapText(refusalText(res, M.rules))))
        refusedRun, M.rules = M.rules.runId, nil
        return
      end
      M.world = res.world
    end
    local st = state()
    st.world = M.world
    if fresh then
      st.run, st.seed = M.rules.runId, M.rules.seed
      ctx.writeOnlineSave()
    end
    M.refresh()
    local res = ctx.post({ action = "team_status", trainerId = trainerId() }, 3.0)
    if res and res.success then
      if res.run then M.rules = res.run end
      M.applyTeam(res.team)
    end
    if st.wiped and st.run == M.rules.runId and M.rules.nuzlocke == "hardcore" then
      wipeQueued = true
    end
  end

  -- every sync_pos answer.  A game online with a mode on that never set the
  -- modes up (a way in that missed M.connected, or modes turned on while it
  -- played) does it now: without them it would play no rules and never hear
  -- that a teammate's wipe ended the run.  Once per run when refused.
  function M.synced(game, res)
    if not (type(res) == "table" and type(res.run) == "table") then return end
    if not M.rules then
      if res.run.active and refusedRun ~= res.run.runId then M.connected(game, res.run, false) end
      return
    end
    M.rules = res.run.active and res.run or nil
    if M.rules then M.applyTeam(res.team) end
  end

  function M.tick(game)
    M.refresh()
    if not (rules() and session()) then return end
    local st = state()
    if st.run ~= M.rules.runId and not pendingRestart and not wipeQueued then
      if st.run ~= nil then
        -- why the server began a run: a team wipe, the host's changed settings
        -- (config), or --new-run (manual)
        local why = M.rules.runReason
        if why == "config" or why == "manual" then
          note(("RUN %d IS OVER! THE SERVER STARTED A NEW RUN%s.\fEVERYONE STARTS OVER."):format(
            st.run, why == "config" and " WITH NEW SETTINGS" or ""))
        else
          note(("RUN %d IS OVER! A TEAMMATE'S PARTY WIPED OUT.\fEVERYONE STARTS OVER."):format(st.run))
        end
      end
      pendingRestart = true
    end
    local now = love and love.timer and love.timer.getTime() or os.time()
    if wipeQueued then postWipe(now) end
    if #reports > 0 then postReports(now) end
    -- a new run or a text box never lands mid-script, mid-battle or mid-warp
    if G3.busy() then return end
    if pendingRestart and not wipeQueued then return M.restart(game) end
    if st.owed and st.owed[1] and now >= owedAt then
      owedAt = now + 2
      local c = st.owed[1]
      if receive(c.item, c.count) then
        table.remove(st.owed, 1)
        ctx.writeOnlineSave()
        note(("%s GOT %s!"):format(tostring(session().name or "YOU"), itemName(c.item)))
      end
    end
    if M.hardcore() and not st.wiped then
      for _, m in ipairs(session().party or {}) do
        if (tonumber(m.hp) or 0) <= 0 and not m.isEgg then M.bury(false) break end
      end
    end
    local text = table.remove(notes, 1)
    if text then game.stack:push(G3.TextBox.new(game, ctx.wrapText(text))) end
  end

  mod.hooks:wrap("core.update", function(nextFn, game, dt, ...)
    local res = nextFn(game, dt, ...)
    pcall(M.tick, G3.game)
    return res
  end)

  return M
end
