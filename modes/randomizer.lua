-- The co-op randomizer's world, built from the run's seed.  Pure functions
-- over the game's own data: every client on a server builds the same world
-- from the same seed (each from its own game's data, so a Yellow player and
-- a Red player each get a world their game can finish).
--
--   plan = Randomizer.build{ seed=, data=, victories=, logic=, Rng=,
--                            encounters=, items=, badges=, starters=,
--                            worlds=, world= }
--   plan.species[VANILLA] = REPLACEMENT          (wild, fishing, static)
--   plan.starters[VANILLA_STARTER] = REPLACEMENT (Oak's gifts)
--   plan.content[key] = { item=, count= }        (every shuffled place)
--   plan.gifts[VANILLA_ITEM], plan.gyms[VICTORY_KEY] -> content
--   local undo = Randomizer.apply(plan, data, victories); undo()
--
-- Multiworld (worlds = N > 1): the team plays N worlds, and every badge, HM
-- and key item exists in exactly one of them.  The fill places all N worlds
-- at once against the team's one shared inventory (finds are shared), so
-- the team can always finish, and each client keeps only its own world k.
-- Wild Pokémon get one shuffle per world.  Every client must hold the same
-- item data for this (R.fingerprint), which the server checks.
local R = {}

-- ---- Pokémon ------------------------------------------------------------------

-- Never mixed into the wild pool; they shuffle among themselves.
R.LEGENDARY = { ARTICUNO = true, ZAPDOS = true, MOLTRES = true, MEWTWO = true, MEW = true }
-- Gen 1's starters: Red and Blue's three balls, then Yellow's PIKACHU
R.STARTERS = { "BULBASAUR", "CHARMANDER", "SQUIRTLE", "PIKACHU" }
R.TIERS = 6

local function statTotal(def)
  local t = 0
  for _, v in pairs(def.baseStats or {}) do t = t + (tonumber(v) or 0) end
  return t
end

-- Each species swaps with another of similar strength: the 146 others are
-- cut into tiers by base-stat total and shuffled within their tier, so
-- Route 1 still holds early-game Pokémon and a Nuzlocke stays fair.
-- `pokemon` is keyed by species id (names on Gen 1, numbers on FireRed);
-- `legendary` is the set kept apart (R.LEGENDARY by default).
function R.speciesMap(rng, pokemon, legendary)
  legendary = legendary or R.LEGENDARY
  local plain, legends = {}, {}
  for id, def in pairs(pokemon or {}) do
    if type(def) == "table" and def.baseStats then
      local list = legendary[id] and legends or plain
      list[#list + 1] = { id = id, total = statTotal(def), dex = tonumber(def.dex) or 999 }
    end
  end
  local function byStrength(a, b)
    if a.total ~= b.total then return a.total < b.total end
    if a.dex ~= b.dex then return a.dex < b.dex end
    return tostring(a.id) < tostring(b.id)
  end
  table.sort(plain, byStrength)
  table.sort(legends, byStrength)
  local map = {}
  local function shuffleGroup(group)
    local ids = {}
    for i, e in ipairs(group) do ids[i] = e.id end
    local shuffled = rng:shuffle({ unpack(ids) })
    for i, id in ipairs(ids) do map[id] = shuffled[i] end
  end
  local per = math.ceil(#plain / R.TIERS)
  for t = 0, R.TIERS - 1 do
    local group = {}
    for i = t * per + 1, math.min(#plain, (t + 1) * per) do group[#group + 1] = plain[i] end
    shuffleGroup(group)
  end
  shuffleGroup(legends)
  return map
end

-- ---- wild legendaries ---------------------------------------------------------

-- With wild_legendaries on, a wild encounter is now and then a legendary.
-- The game's legendaries, sorted (numbers on FireRed, names on Gen 1);
-- `pokemon`, when given, drops any the game has no data for.
function R.legendaryList(legendary, pokemon)
  local list = {}
  for id in pairs(legendary or R.LEGENDARY) do
    if not pokemon or pokemon[id] then list[#list + 1] = id end
  end
  table.sort(list, function(a, b)
    if type(a) == "number" and type(b) == "number" then return a < b end
    return tostring(a) < tostring(b)
  end)
  return list
end

-- `chance` in percent, `rand()` in [0, 1): a legendary from `list`, or nil
function R.rollLegendary(chance, rand, list)
  chance = tonumber(chance) or 0
  if chance <= 0 or #list == 0 or rand() * 100 >= chance then return nil end
  return list[math.min(#list, math.floor(rand() * #list) + 1)]
end

-- ---- trainers -----------------------------------------------------------------

-- randomize_trainers: each Pokémon of a trainer's team becomes one of the few
-- closest to it in strength (base-stat total), of the trainer's type when it
-- has one (a gym leader, his gym, the Elite Four), never a legendary; a team
-- doesn't repeat a Pokémon while it has others to pick.  `team` is a list of
-- species ids; `pokemon[id]` has baseStats and `types` (names on Gen 1,
-- numbers on FireRed).  Returns the new list, or nil when nothing fits.
R.TRAINER_NEAR, R.TRAINER_NEAR_THEMED = 10, 6

local function hasType(def, theme)
  for _, t in ipairs(def.types or {}) do if t == theme then return true end end
  return false
end

function R.trainerTeam(rng, team, pokemon, legendary, theme)
  legendary = legendary or R.LEGENDARY
  local pool = {}
  for id, def in pairs(pokemon or {}) do
    if type(def) == "table" and def.baseStats and not legendary[id] and (theme == nil or hasType(def, theme)) then
      pool[#pool + 1] = { id = id, total = statTotal(def), dex = tonumber(def.dex) or 999 }
    end
  end
  if #pool == 0 then return nil end
  local out, used = {}, {}
  for i, sp in ipairs(team) do
    local def = pokemon[sp]
    local total = (type(def) == "table" and def.baseStats) and statTotal(def) or 300
    table.sort(pool, function(a, b)
      local da, db = math.abs(a.total - total), math.abs(b.total - total)
      if da ~= db then return da < db end
      if a.dex ~= b.dex then return a.dex < b.dex end
      return tostring(a.id) < tostring(b.id)
    end)
    local k = math.min(#pool, theme and R.TRAINER_NEAR_THEMED or R.TRAINER_NEAR)
    local choices = {}
    for j = 1, k do if not used[pool[j].id] then choices[#choices + 1] = pool[j].id end end
    if #choices == 0 then for j = 1, k do choices[#choices + 1] = pool[j].id end end
    out[i] = choices[rng:int(1, #choices)]
    used[out[i]] = true
  end
  return out
end

-- a number from a name, for a trainer's own draw (Gen 1 names its trainers
-- by class and party, FireRed by number)
function R.saltOf(key)
  if type(key) == "number" then return key end
  local h = 0
  for i = 1, #tostring(key) do h = (h * 31 + tostring(key):byte(i)) % 1000003 end
  return h
end

-- ---- starters -----------------------------------------------------------------

-- The starters become basic Pokémon that evolve twice, as the real ones do:
-- species nothing evolves into, whose evolution evolves again (a def's
-- `evolutions` lists { species = INTO }), never a legendary.  Sorted, so
-- every client draws from the same list.
function R.starterPool(pokemon, legendary)
  legendary = legendary or R.LEGENDARY
  local evolved = {}
  for _, def in pairs(pokemon or {}) do
    for _, e in ipairs(type(def) == "table" and def.evolutions or {}) do evolved[e.species] = true end
  end
  local pool = {}
  for id, def in pairs(pokemon or {}) do
    if type(def) == "table" and not evolved[id] and not legendary[id] then
      for _, e in ipairs(def.evolutions or {}) do
        local mid = pokemon[e.species]
        if type(mid) == "table" and mid.evolutions and #mid.evolutions > 0 then
          pool[#pool + 1] = { id = id, dex = tonumber(def.dex) or 999 }
          break
        end
      end
    end
  end
  table.sort(pool, function(a, b)
    if a.dex ~= b.dex then return a.dex < b.dex end
    return tostring(a.id) < tostring(b.id)
  end)
  for i, e in ipairs(pool) do pool[i] = e.id end
  return pool
end

-- vanilla[i] -> a different pool species each (distinct while the pool lasts)
function R.starterMap(rng, vanilla, pool)
  if #pool == 0 then return nil end
  local drawn = rng:shuffle({ unpack(pool) })
  local map = {}
  for i, id in ipairs(vanilla) do map[id] = drawn[(i - 1) % #drawn + 1] end
  return map
end

local function teaches(pokemon, species, move)
  local def = pokemon[species]
  for _, m in ipairs(type(def) == "table" and def.tmhm or {}) do
    if m == move then return true end
  end
  return false
end

-- Whether a species map leaves each of the logic's field moves (L.FIELD_MOVES)
-- a wild Pokémon that learns it in enough of the areas open before the move
-- is needed.  Only the walking table counts (grass, and every tile of a
-- cave): water encounters need Surf.  Without encounter data (or areas the
-- data does not know) there is nothing to check.
function R.fieldMovesOk(species, data, L)
  local enc, pokemon = data and data.encounters, data and data.pokemon
  if type(enc) ~= "table" or type(pokemon) ~= "table" then return true end
  for _, need in ipairs(L.FIELD_MOVES or {}) do
    local vanilla, now = 0, 0
    for _, mapId in ipairs(need.maps) do
      local v, n = false, false
      local t = type(enc[mapId]) == "table" and enc[mapId].grass
      for _, slot in ipairs(type(t) == "table" and t.slots or {}) do
        v = v or teaches(pokemon, slot.species, need.move)
        n = n or teaches(pokemon, species[slot.species] or slot.species, need.move)
      end
      if v then vanilla = vanilla + 1 end
      if n then now = now + 1 end
    end
    if now < math.min(need.areas, vanilla) then return false end
  end
  return true
end
R.SPECIES_TRIES = 50

-- ---- where items are --------------------------------------------------------------

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function realItem(data, id)
  return type(id) == "string" and id ~= "0" and data.items and data.items[id] ~= nil
end

-- Every place an item can come from, in one fixed order:
-- { key, kind = "ball"|"hidden"|"gift"|"gym", vanilla = {item,count},
--   reqSet = {ITEM=true}, shuffled = bool, ref = <the data record> }
function R.locations(data, victories, L, opts)
  local locs = {}
  local never = L.expand(L.MACROS.NEVER)
  local function add(loc, req, shuffled)
    loc.reqSet = req and L.expand(req) or never
    loc.shuffled = shuffled and true or false
    locs[#locs + 1] = loc
  end
  for _, mapId in ipairs(sortedKeys(data.maps)) do
    local map = data.maps[mapId]
    for i, obj in ipairs(type(map) == "table" and map.objects or {}) do
      if realItem(data, obj.item) then
        local spot = L.SPOTS[mapId] and L.SPOTS[mapId][obj.item]
        add({ key = mapId .. "#" .. tostring(obj.index or i), kind = "ball", map = mapId,
              vanilla = { item = obj.item, count = 1 }, ref = obj }, spot or L.MAPS[mapId], opts.items)
      end
    end
  end
  local hidden = data.field and data.field.hiddenItems or {}
  for _, mapId in ipairs(sortedKeys(hidden)) do
    for _, h in ipairs(hidden[mapId] or {}) do
      if realItem(data, h.item) then
        add({ key = ("hidden:%s:%s:%s"):format(mapId, tostring(h.x), tostring(h.y)),
              kind = "hidden", map = mapId, vanilla = { item = h.item, count = 1 }, ref = h },
            L.MAPS[mapId], opts.items)
      end
    end
  end
  for _, item in ipairs(sortedKeys(L.GIFTS)) do
    if realItem(data, item) then
      add({ key = "gift:" .. item, kind = "gift", gift = item,
            vanilla = { item = item, count = 1 } }, L.GIFTS[item], opts.items)
    end
  end
  local seenBadge = {}
  for _, vkey in ipairs(sortedKeys(victories)) do
    local reward = victories[vkey]
    local badge = type(reward) == "table" and reward.badge
    if badge and L.GYMS[badge] and not seenBadge[badge] and realItem(data, badge) then
      seenBadge[badge] = true
      add({ key = "gym:" .. vkey, kind = "gym", victoryKey = vkey,
            vanilla = { item = badge, count = 1 } }, L.GYMS[badge], opts.badges)
    end
  end
  return locs
end

-- ---- placement ------------------------------------------------------------------------

-- What the player can collect with this placement, starting from nothing.
local function reachable(locs, contents, L)
  local have, got = {}, {}
  local changed = true
  while changed do
    changed = false
    for i, loc in ipairs(locs) do
      local c = contents[i]
      if c and not got[i] and L.satisfied(loc.reqSet, have) then
        got[i] = true
        have[c.item] = true
        changed = true
      end
    end
  end
  return have
end

local function weightOf(loc)
  local n = 0
  for _ in pairs(loc.reqSet) do n = n + 1 end
  return 1 + 2 * n          -- deeper spots are likelier: spreads progression out
end

local function weightedPick(rng, list, locs)
  local total = 0
  for _, i in ipairs(list) do total = total + weightOf(locs[i]) end
  local roll = rng:int(1, total)
  for _, i in ipairs(list) do
    roll = roll - weightOf(locs[i])
    if roll <= 0 then return i end
  end
  return list[#list]
end

-- One forward fill: progression first, each item into a spot the items
-- placed before it already reach, then everything else at random.  nil when
-- the fill painted itself into a corner (the caller retries).
local function fill(rng, locs, L, worlds, fallback)
  local contents, pool = {}, {}
  for i, loc in ipairs(locs) do
    if loc.shuffled then pool[#pool + 1] = loc.vanilla else contents[i] = loc.vanilla end
  end
  local isProg = {}
  for _, id in ipairs(L.PROGRESSION) do isProg[id] = true end
  local prog, filler, seen, spare = {}, {}, {}, 0
  for _, entry in ipairs(pool) do
    if isProg[entry.item] and seen[entry.item] then
      spare = spare + 1           -- a multiworld keeps one copy for the team
    elseif isProg[entry.item] then
      seen[entry.item] = true
      prog[#prog + 1] = entry
    else
      filler[#filler + 1] = entry
    end
  end
  -- the other worlds' copies become filler: more of the worlds' own items
  -- (a POTION when the shuffle holds nothing but badges)
  local fillerCount = #filler
  for _ = 1, spare do
    filler[#filler + 1] = fillerCount > 0 and filler[rng:int(1, fillerCount)] or fallback
  end
  local placed = {}
  local balance = (worlds or 1) > 1
  rng:shuffle(prog)
  for _, entry in ipairs(prog) do
    local have = reachable(locs, contents, L)
    local open = {}
    for i, loc in ipairs(locs) do
      -- never on an invisible tile: a badge has to be something you can find
      if loc.shuffled and not contents[i] and loc.kind ~= "hidden"
          and L.satisfied(loc.reqSet, have) then
        open[#open + 1] = i
      end
    end
    if #open == 0 then return nil end
    if balance then
      -- a multiworld fills the worlds evenly: the next item goes to a world
      -- holding the least progression among those with a spot open for it
      local least = math.huge
      for _, i in ipairs(open) do least = math.min(least, placed[locs[i].world] or 0) end
      local even = {}
      for _, i in ipairs(open) do
        if (placed[locs[i].world] or 0) == least then even[#even + 1] = i end
      end
      open = even
    end
    local at = weightedPick(rng, open, locs)
    contents[at] = entry
    local w = locs[at].world or 1
    placed[w] = (placed[w] or 0) + 1
  end
  local have = reachable(locs, contents, L)
  if not L.satisfied(L.expand(L.GOAL), have) then return nil end
  for _, entry in ipairs(prog) do
    if not have[entry.item] then return nil end
  end
  rng:shuffle(filler)
  local f = 1
  for i, loc in ipairs(locs) do
    if loc.shuffled and not contents[i] then
      contents[i] = filler[f]
      f = f + 1
    end
  end
  return contents
end

-- Each attempt has its own RNG stream, so a seed that succeeds early builds
-- the same world whatever the cap.  Strict chains need many: with only the
-- badges shuffled, the second gym's badge must come out among the first two
-- and the last gym's last, a few percent per attempt.
R.ATTEMPTS = 500
R.fill = fill
R.reachable = reachable

-- A checksum of a world's item places and what vanilla puts there: equal
-- fingerprints mean every client computes the same multiworld.  Pure
-- arithmetic, like the RNG, so every client agrees on it.
function R.fingerprint(locs)
  local h = 5381
  for _, loc in ipairs(locs or {}) do
    local s = loc.key .. "=" .. loc.vanilla.item .. ";"
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
  end
  return h
end

function R.build(opts)
  local L, Rng = opts.logic, opts.Rng
  local worlds = math.max(1, math.floor(tonumber(opts.worlds) or 1))
  local world = math.min(worlds, math.max(1, math.floor(tonumber(opts.world) or 1)))
  local plan = { seed = opts.seed, species = nil, content = {}, gifts = {}, gyms = {},
                 locations = {}, ok = true, worlds = worlds, world = world,
                 myProgression = 0, totalProgression = 0 }
  if opts.encounters then
    -- one shuffle per world in a multiworld (a single world keeps salt 1)
    local salt = worlds > 1 and (1000 + world) or 1
    -- shuffled again (the same way on every client) until Cut has learners
    -- (opts.pokemon / opts.legendary / opts.fieldMovesOk: another game's data)
    local fieldOk = opts.fieldMovesOk or function(species) return R.fieldMovesOk(species, opts.data, L) end
    for try = 1, R.SPECIES_TRIES do
      plan.species = R.speciesMap(Rng.new(opts.seed, salt + 10000 * (try - 1)),
        opts.pokemon or opts.data.pokemon, opts.legendary)
      plan.speciesTries = try
      if fieldOk(plan.species) then break end
    end
  end
  if opts.starters then
    -- opts.starterIds: the game's own starters, in a fixed order (Gen 1's
    -- three balls and Yellow's PIKACHU by default); one draw per world
    local salt = 20000 + (worlds > 1 and world or 0)
    plan.starters = R.starterMap(Rng.new(opts.seed, salt), opts.starterIds or R.STARTERS,
      R.starterPool(opts.pokemon or opts.data.pokemon, opts.legendary))
  end
  -- opts.locations: places another game built (FireRed's, modes/frlg.lua)
  local base = opts.locations or R.locations(opts.data, opts.victories or {}, L, opts)
  plan.fingerprint = R.fingerprint(base)
  if not (opts.items or opts.badges) then return plan end
  plan.locations = base
  -- every world's places, world 1 first: the same list on every client
  local locs = base
  if worlds > 1 then
    locs = {}
    for w = 1, worlds do
      for _, loc in ipairs(base) do
        locs[#locs + 1] = setmetatable({ world = w }, { __index = loc })
      end
    end
  end
  local fallback = { item = opts.fallbackItem
                       or ((opts.data and opts.data.items or {}).POTION and "POTION")
                       or base[1] and base[1].vanilla.item, count = 1 }
  local contents
  for attempt = 1, R.ATTEMPTS do
    contents = fill(Rng.new(opts.seed, 100 + attempt), locs, L, worlds, fallback)
    if contents then plan.attempts = attempt break end
  end
  if not contents then
    -- a world this logic cannot finish (a data set it does not know): play
    -- the items vanilla rather than risk a dead end
    plan.ok = false
    return plan
  end
  local isProg = {}
  for _, id in ipairs(L.PROGRESSION) do isProg[id] = true end
  local counted = {}
  for i, loc in ipairs(locs) do
    local c = contents[i]
    if loc.shuffled and c and isProg[c.item] and not counted[c.item] then
      counted[c.item] = true
      plan.totalProgression = plan.totalProgression + 1
    end
    if loc.shuffled and (loc.world or 1) == world then
      plan.content[loc.key] = c
      if isProg[c.item] then plan.myProgression = plan.myProgression + 1 end
      if loc.kind == "gift" then plan.gifts[loc.gift] = c end
      if loc.kind == "gym" then plan.gyms[loc.victoryKey] = c end
    end
  end
  return plan
end

-- ---- applying it to the game ------------------------------------------------------------

-- Item balls and hidden items are swapped in the game's data (the map
-- objects ARE the records spawned balls point at); gym leaders get a reward
-- line naming their new item.  Gifts, gym rewards themselves and encounters
-- are swapped as they happen, by hooks (modes/init.lua).  Returns undo().
function R.apply(plan, data, victories)
  local undo = {}
  local function set(t, k, v)
    undo[#undo + 1] = { t, k, t[k] }
    t[k] = v
  end
  local text = data.text or {}
  for _, loc in ipairs(plan.locations or {}) do
    local c = plan.content[loc.key]
    if c and (loc.kind == "ball" or loc.kind == "hidden") then
      set(loc.ref, "item", c.item)
    elseif c and loc.kind == "gym" and victories[loc.victoryKey] then
      local label = "_G1O_GYM_" .. loc.victoryKey:gsub("%W", "_")
      local def = data.items[c.item]
      local name = def and def.name or c.item
      set(text, label, ("{PLAYER} received\n%s%s!"):format(c.count > 1 and (c.count .. " ") or "", name))
      set(victories[loc.victoryKey], "dialogue", { label })
    end
  end
  -- the one gift text that names its item instead of reading it back
  if plan.gifts.TM_DIG and text._CeruleanCityRocketReceivedTM28Text then
    set(text, "_CeruleanCityRocketReceivedTM28Text", "{PLAYER} recovered\n{RAM:wStringBuffer}!")
  end
  return function()
    for i = #undo, 1, -1 do
      local u = undo[i]
      u[1][u[2]] = u[3]
    end
  end
end

return R
