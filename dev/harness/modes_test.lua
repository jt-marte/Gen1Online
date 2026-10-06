-- The randomizer's pure parts, with no engine and no ROM: the seeded RNG,
-- the species shuffle, the placement logic and apply/undo, on a synthetic
-- Gen 1 world whose maps carry the logic table's own map ids.
--   luajit dev/harness/modes_test.lua        (from the repo or gen1recomp)
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/dev/harness/") or "."
local function load(rel) return assert(loadfile(here .. "/" .. rel))() end
local Rng = load("modes/rng.lua")
local L = load("modes/logic.lua")
local R = load("modes/randomizer.lua")

local fails = 0
local function check(cond, label)
  print((cond and "PASS " or "FAIL ") .. label)
  if not cond then fails = fails + 1 end
end

-- ---- the RNG: same numbers everywhere, forever ------------------------------------------
do
  local a, b = Rng.new(4242), Rng.new(4242)
  local same, inRange = true, true
  for _ = 1, 1000 do
    local x, y = a:int(1, 6), b:int(1, 6)
    if x ~= y then same = false end
    if x < 1 or x > 6 then inRange = false end
  end
  check(same and inRange, "the RNG is repeatable and stays in range")
  -- pinned: 16807^5 mod (2^31 - 1), the stream's fifth draw; a change here
  -- reshuffles every server's world
  local r = Rng.new(1)
  check(r:next() == 1144108930 and Rng.new(2147483646):int(1, 100) >= 1,
    "the RNG's numbers are pinned (" .. tostring(Rng.new(1):next()) .. ")")
  check(Rng.new(5, 1):next() ~= Rng.new(5, 2):next(), "salts give separate streams")
end

-- ---- a synthetic world ----------------------------------------------------------------
local items = { POTION = { name = "POTION" }, RARE_CANDY = { name = "RARE CANDY" } }
for _, id in ipairs(L.PROGRESSION) do items[id] = { name = id:gsub("_", " "), keyItem = true } end
for id in pairs(L.GIFTS) do items[id] = items[id] or { name = id } end
local maps, n = {}, 0
local vanillaKey = { -- where vanilla keeps the key items that sit in balls
  SILPH_CO_5F = "CARD_KEY", ROCKET_HIDEOUT_B4F = "LIFT_KEY", POKEMON_MANSION_B1F = "SECRET_KEY",
  SAFARI_ZONE_WEST = "GOLD_TEETH",
}
for mapId in pairs(L.MAPS) do
  n = n + 1
  maps[mapId] = { objects = {
    { index = 1, item = vanillaKey[mapId] or "POTION", x = 1, y = 1 },
    { index = 2, item = (n % 3 == 0) and "RARE_CANDY" or "POTION", x = 2, y = 1 },
    { index = 3, sprite = "SPRITE_GIRL" },               -- not an item
    { index = 4, item = "0" },                            -- ITEM_NONE: not an item
  } }
end
maps.ROCKET_HIDEOUT_B4F.objects[3] = { index = 3, item = "SILPH_SCOPE", hidden = true }
maps.CERULEAN_CAVE_1F = { objects = { { index = 1, item = "RARE_CANDY" } } }   -- NEVER
local hidden = { ROUTE_9 = { { item = "POTION", x = 4, y = 4 } },
                 CERULEAN_CITY = { { item = "RARE_CANDY", x = 1, y = 1 } } }
local victories, gymKeys = {}, {}
for badge in pairs(L.GYMS) do
  local key = "OPP_" .. badge .. "#1"
  victories[key] = { badge = badge, item = "TM_X", dialogue = { "_VANILLA" } }
  gymKeys[badge] = key
end
victories.badgeSoundFor = function() end                  -- a function in the table, like the real one
local pokemon = {}
for i = 1, 151 do
  local id = (i == 144 and "ARTICUNO") or (i == 150 and "MEWTWO") or (i == 151 and "MEW") or ("MON" .. i)
  pokemon[id] = { dex = i, baseStats = { hp = i, attack = 10, defense = 10, speed = 10, special = 10 } }
end
local data = { maps = maps, field = { hiddenItems = hidden }, items = items, pokemon = pokemon,
               text = { _CeruleanCityRocketReceivedTM28Text = "{PLAYER} recovered TM28!" } }

local function build(seed, opts)
  opts = opts or {}
  return R.build({ seed = seed, data = data, victories = victories, logic = L, Rng = Rng,
                   encounters = opts.encounters ~= false, items = opts.items ~= false,
                   badges = opts.badges ~= false })
end

-- replay a plan the way a player would: collect everything reachable
local function playable(plan)
  local have, got = {}, {}
  local changed = true
  while changed do
    changed = false
    for _, loc in ipairs(plan.locations) do
      local c = plan.content[loc.key] or (not loc.shuffled and loc.vanilla)
      if c and not got[loc.key] and L.satisfied(loc.reqSet, have) then
        got[loc.key], have[c.item], changed = true, true, true
      end
    end
  end
  return L.satisfied(L.expand(L.GOAL), have), have
end

-- ---- placement --------------------------------------------------------------------
do
  local okAll, hiddenProg, neverProg, kinds = true, 0, 0, {}
  local isProg = {}
  for _, id in ipairs(L.PROGRESSION) do isProg[id] = true end
  for seed = 1, 200 do
    local plan = build(seed)
    local done = plan.ok and playable(plan)
    if not done then okAll = false end
    for _, loc in ipairs(plan.locations) do
      local c = plan.content[loc.key]
      if c and isProg[c.item] then
        kinds[loc.kind] = true
        if loc.kind == "hidden" then hiddenProg = hiddenProg + 1 end
        if loc.reqSet.__NEVER__ then neverProg = neverProg + 1 end
      end
    end
  end
  check(okAll, "200 seeds: every world can be finished")
  check(hiddenProg == 0, "no badge or key item on an invisible tile")
  check(neverProg == 0, "none in a post-game map")
  check(kinds.ball and kinds.gift and kinds.gym, "progression lands in balls, gifts and gyms")

  local plan = build(77)
  local pool, placed = {}, {}
  for _, loc in ipairs(plan.locations) do
    local v = loc.vanilla.item
    pool[v] = (pool[v] or 0) + 1
    local c = plan.content[loc.key].item
    placed[c] = (placed[c] or 0) + 1
  end
  local same = true
  for id, k in pairs(pool) do if placed[id] ~= k then same = false end end
  check(same, "the shuffle moves items, it never adds or loses one")
  local keys = {}
  for _, loc in ipairs(plan.locations) do keys[loc.key] = (keys[loc.key] or 0) + 1 end
  local unique = true
  for _, k in pairs(keys) do if k > 1 then unique = false end end
  check(unique and keys["ROCKET_HIDEOUT_B4F#3"] and keys["CERULEAN_CAVE_1F#1"]
        and not keys["ROUTE_9#4"] and keys["hidden:ROUTE_9:4:4"],
    "every item place once, ITEM_NONE and plain NPCs left out")

  local again = build(77)
  local same2 = true
  for k, c in pairs(plan.content) do if again.content[k].item ~= c.item then same2 = false end end
  for k, s in pairs(plan.species) do if again.species[k] ~= s then same2 = false end end
  check(same2, "the same seed builds the same world")
  local other, differs = build(78), false
  for k, c in pairs(plan.content) do if other.content[k].item ~= c.item then differs = true end end
  check(differs, "another seed builds another world")
end

do
  local plan = build(9, { items = false })
  local moved, onlyGyms = 0, true
  for _, loc in ipairs(plan.locations) do
    local c = plan.content[loc.key]
    if c then
      if loc.kind ~= "gym" then onlyGyms = false end
      if c.item ~= loc.vanilla.item then moved = moved + 1 end
    end
  end
  check(plan.ok and onlyGyms and moved > 0 and playable(plan), "badges only: the gyms trade badges, the world is still finishable")
  local plan2 = build(9, { badges = false })
  local gymsTouched = false
  for _, loc in ipairs(plan2.locations) do
    if loc.kind == "gym" and plan2.content[loc.key] then gymsTouched = true end
  end
  check(plan2.ok and not gymsTouched and playable(plan2), "items only: gym leaders keep their badges")
  local plan3 = build(9, { items = false, badges = false })
  check(next(plan3.content) == nil and plan3.species ~= nil, "encounters only: no items move")
end

-- ---- species -----------------------------------------------------------------------
do
  local map = R.speciesMap(Rng.new(3, 1), pokemon)
  local hit, perm, legendsStay = {}, true, true
  for from, to in pairs(map) do
    if hit[to] then perm = false end
    hit[to] = true
    if (R.LEGENDARY[from] ~= nil) ~= (R.LEGENDARY[to] ~= nil) then legendsStay = false end
  end
  local count = 0
  for _ in pairs(map) do count = count + 1 end
  check(perm and count == 151, "the species shuffle is a one-to-one swap of all 151")
  check(legendsStay, "legendaries only trade places with legendaries")
  local maxJump = 0
  for from, to in pairs(map) do
    if not R.LEGENDARY[from] then
      maxJump = math.max(maxJump, math.abs(pokemon[from].dex - pokemon[to].dex))
    end
  end
  check(maxJump <= math.ceil(148 / R.TIERS), "a species swaps with one of similar strength (max gap " .. maxJump .. ")")
end

-- ---- apply / undo --------------------------------------------------------------------
do
  local plan = build(31)
  local before = {}
  for mapId, m in pairs(maps) do
    for i, o in ipairs(m.objects) do before[mapId .. i] = o.item end
  end
  local hiddenBefore = hidden.ROUTE_9[1].item
  local undo = R.apply(plan, data, victories)
  local changed = 0
  for mapId, m in pairs(maps) do
    for i, o in ipairs(m.objects) do if o.item ~= before[mapId .. i] then changed = changed + 1 end end
  end
  local brock = victories[gymKeys.BOULDERBADGE]
  local label = brock.dialogue[1]
  check(changed > 0 and hidden.ROUTE_9[1].item == plan.content["hidden:ROUTE_9:4:4"].item,
    "apply puts the shuffle into the map data")
  check(label ~= "_VANILLA" and data.text[label]:find(items[plan.gyms[gymKeys.BOULDERBADGE].item].name, 1, true),
    "the gym leader's line names the new reward")
  undo()
  local back = true
  for mapId, m in pairs(maps) do
    for i, o in ipairs(m.objects) do if o.item ~= before[mapId .. i] then back = false end end
  end
  check(back and hidden.ROUTE_9[1].item == hiddenBefore and brock.dialogue[1] == "_VANILLA"
        and data.text[label] == nil and data.text._CeruleanCityRocketReceivedTM28Text == "{PLAYER} recovered TM28!",
    "undo puts every item, line and text back")
end

-- ---- a world the logic does not know --------------------------------------------------
do
  local strange = { maps = { NOWHERE = { objects = { { index = 1, item = "HM_CUT" } } } },
                    field = {}, items = items, pokemon = pokemon, text = {} }
  local plan = R.build({ seed = 1, data = strange, victories = {}, logic = L, Rng = Rng,
                         items = true, badges = true })
  check(not plan.ok and next(plan.content) == nil, "an unfinishable world keeps its items where they are")
end

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
