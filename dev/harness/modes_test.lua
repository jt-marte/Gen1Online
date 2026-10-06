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

-- ---- multiworld: every progression item in exactly one world -----------------------
do
  local isProg = {}
  for _, id in ipairs(L.PROGRESSION) do isProg[id] = true end
  local function team(seed, n, opts)
    opts = opts or {}
    local plans = {}
    for w = 1, n do
      plans[w] = R.build({ seed = seed, data = data, victories = victories, logic = L, Rng = Rng,
                           encounters = true, items = opts.items ~= false, badges = true,
                           worlds = n, world = w })
    end
    return plans
  end
  -- the team collects from every world into one shared inventory
  local function teamFinishes(plans)
    local have, got = {}, {}
    local changed = true
    while changed do
      changed = false
      for w, plan in ipairs(plans) do
        for _, loc in ipairs(plan.locations) do
          local c = plan.content[loc.key] or (not loc.shuffled and loc.vanilla)
          local k = w .. "|" .. loc.key
          if c and not got[k] and L.satisfied(loc.reqSet, have) then
            got[k], have[c.item], changed = true, true, true
          end
        end
      end
    end
    return L.satisfied(L.expand(L.GOAL), have)
  end
  local once, finish, sizes, balanced, ok = true, true, true, true, true
  for n = 2, 4 do
    for seed = 1, 40 do
      local plans = team(seed, n)
      local count = {}
      local lo, hi = math.huge, 0
      for _, plan in ipairs(plans) do
        if not plan.ok then ok = false end
        local k = 0
        for _ in pairs(plan.content) do k = k + 1 end
        if k ~= #plan.locations then sizes = false end
        for _, c in pairs(plan.content) do
          if isProg[c.item] then count[c.item] = (count[c.item] or 0) + 1 end
        end
        lo, hi = math.min(lo, plan.myProgression), math.max(hi, plan.myProgression)
      end
      for _, id in ipairs(L.PROGRESSION) do if count[id] ~= 1 then once = false end end
      if hi - lo > 3 then balanced = false end
      if not teamFinishes(plans) then finish = false end
    end
  end
  check(ok, "multiworld: every plan builds (2 to 4 worlds, 40 seeds each)")
  check(once, "each badge, HM and key item is in exactly one world")
  check(sizes, "every world still fills every item place")
  check(finish, "the team can always finish with its shared finds")
  check(balanced, "the worlds hold about as much progression as each other")

  local a, b = team(5, 2), team(5, 2)
  local same, differs = true, false
  for k, c in pairs(a[1].content) do
    if b[1].content[k].item ~= c.item then same = false end
    if a[2].content[k].item ~= c.item then differs = true end
  end
  check(same and differs, "a world is the same on every client, and differs from the next")
  check(a[1].species.MON10 ~= nil and a[1].species ~= a[2].species
    and (function()
      for k, v in pairs(a[1].species) do if a[2].species[k] ~= v then return true end end
    end)(), "wild Pokémon are shuffled per world")
  check(a[1].totalProgression == #L.PROGRESSION, "the team's total is every progression item once")

  local solo = R.build({ seed = 77, data = data, victories = victories, logic = L, Rng = Rng,
                         encounters = true, items = true, badges = true })
  local one = R.build({ seed = 77, data = data, victories = victories, logic = L, Rng = Rng,
                        encounters = true, items = true, badges = true, worlds = 1, world = 1 })
  local equal = true
  for k, c in pairs(solo.content) do if one.content[k].item ~= c.item then equal = false end end
  for k, v in pairs(solo.species) do if one.species[k] ~= v then equal = false end end
  check(equal, "one world is exactly the plain randomizer")

  local badgesOnly = team(3, 3, { items = false })
  local gymsWithBadges = 0
  for _, plan in ipairs(badgesOnly) do
    for _, c in pairs(plan.gyms) do if c.item:find("BADGE") then gymsWithBadges = gymsWithBadges + 1 end end
  end
  check(gymsWithBadges == 8 and teamFinishes(badgesOnly),
    "badges only: 8 badges across 3 worlds' gyms, the other leaders hand out filler")

  local fp = R.fingerprint(R.locations(data, victories, L, { items = true, badges = true }))
  maps.ROUTE_9.objects[1].item = "RARE_CANDY"
  local fp2 = R.fingerprint(R.locations(data, victories, L, { items = true, badges = true }))
  maps.ROUTE_9.objects[1].item = "POTION"
  check(fp == R.fingerprint(R.locations(data, victories, L, { items = true, badges = true }))
    and fp ~= fp2, "the fingerprint is stable, and changes with the item data")
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
