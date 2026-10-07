-- Real FireRed / LeafGreen on a server with every game mode on
-- (nuzlocke = hardcore, randomizer = on, seed = 4242; dev/run_tests.sh
-- writes that config).  A new character connects, then:
--   - the soft-lock checks: every ball and hidden item on a logic map is
--     walked to (a BFS from the map's warps and edges on FireRed's own
--     collision: elevation, water, one-way ledges, and Cut trees, Rock Smash
--     rocks and boulders as walls unless the map's requirement has the HM);
--     200 seeds of placement (items and badges) are all finishable, never put
--     progression on a hidden tile or a post-game map, and keep Cut learners
--     early; 1-3 worlds x 50 seeds replayed as the team; badges only: the
--     gyms trade badges among themselves
--   - the species shuffle covers all 386 and puts Johto and Hoenn Pokémon
--     on the early routes; a wild battle meets the shuffled species, and a
--     shuffled Hoenn Pokémon may evolve before the National Pokédex
--   - an item ball and a hidden item give what the seed put there
--   - a badge in an item ball, picked up for real, is won; Brock, fought
--     for real, hands over what the seed put in his badge slot
--   - shared key items and badges both ways (BUDDY over raw HTTP)
--   - the Nuzlocke: the level cap, items refused in battle, a second
--     encounter's ball refused, a fainted Pokémon buried, a wipe starting
--     run 2 in the bedroom
--   - DISCONNECT puts the vanilla world back; JOIN again reloads run 2 from
--     the online save, and after BUDDY's wipe ends run 2 while ASH is
--     offline, JOIN starts run 3 in the bedroom (run 2's save kept)
local U = require("tests.drivers.util")

return function(game)
  local H = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_util.lua")(game, "gen3_modes")
  local say, check, finish, shot = H.say, H.check, H.finish, H.shot
  if not H.boot() then return finish() end
  local G3, GtsUI = H.G3, H.GtsUI
  local Runtime = require("src.core.game3.runtime")
  local Party = require("src.core.game3.party")
  local Pokemon = require("src.core.game3.pokemon")
  local Bag = require("src.core.game3.bag")
  local Flags = require("src.core.game3.scripting.flags")
  local Space = require("src.core.game3.scripting.space")
  local Battle = require("src.core.game3.battle")
  local BattleBridge = require("src.core.game3.battle_bridge")
  local BattleItems = require("src.core.game3.battle.items")
  local BagMenu = require("src.ui.game3.bag_menu")
  local Evolution = require("src.core.game3.evolution")
  local BattleAPI = require("src.battle.game3.BattleAPI")
  local Message = require("src.ui.game3.message")
  local Choice = require("src.ui.game3.choice")
  local ITEMS = require("src.core.game3.constants.firered.items").byName
  local Modes = GtsUI.Modes
  local Gen3Compat = require("src.mods.Gen3Compat")

  H.newOffline("OFFLINE")
  if not check(H.createPlayer("ASH", "^RED$"), "online as a new character") then return finish() end
  local ashToken = H.account().token
  H.clearTexts()
  H.closeAll()
  check(Modes and Modes.rules and Modes.rules.nuzlocke == "hardcore" and Modes.rules.randomizer,
    "the server's modes are on: " .. tostring(Modes and Modes.describe()))
  local s = Runtime.getSession()
  check(Modes.state().run == Modes.rules.runId, "the new save is this run's (" .. tostring(Modes.state().run) .. ")")

  -- --------------------------------------------------------------- logic
  local L, R, Rng = Modes.lib.logic, Modes.lib.randomizer, Modes.lib.Rng
  local locs = Modes.locations()
  local counts = {}
  for _, loc in ipairs(locs) do counts[loc.kind] = (counts[loc.kind] or 0) + 1 end
  check((counts.ball or 0) > 150 and (counts.hidden or 0) > 150 and (counts.gift or 0) >= 4,
    ("the places: %d balls, %d hidden, %d gifts, %d fixed, %d gyms"):format(counts.ball or 0,
      counts.hidden or 0, counts.gift or 0, counts.fixed or 0, counts.gym or 0))
  local prog = {}
  for _, id in ipairs(L.PROGRESSION) do prog[id] = true end
  local bad, unfinished = {}, 0
  local pokemon, legendary = Modes.speciesData()
  local places = Modes.places(true, true)
  for seed = 1, 200 do
    local p = R.build({ seed = seed, locations = places, logic = L, Rng = Rng, items = true, badges = true,
      worlds = 1, world = 1, fallbackItem = "POTION" })
    if not p.ok then unfinished = unfinished + 1 end
    for _, loc in ipairs(p.locations or {}) do
      local c = p.content[loc.key]
      if c and prog[c.item] then
        if loc.kind == "hidden" then bad[#bad + 1] = seed .. ": " .. c.item .. " hidden at " .. loc.key end
        if loc.reqSet.__NEVER__ then bad[#bad + 1] = seed .. ": " .. c.item .. " post-game at " .. loc.key end
      end
    end
  end
  check(unfinished == 0, "200 seeds with items and badges, all finishable (" .. unfinished .. " not)")
  check(#bad == 0, "progression never hidden or post-game" .. (bad[1] and (": " .. bad[1]) or ""))

  -- the maps, walked: each item the logic says a map's requirement reaches
  do
    local walk = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_walk.lua")
    local wrong, total = walk(H.G3.raw(), L, locs)
    local here = H.G3.currentMap()
    require("src.core.game3.collision").bindMap(H.G3.raw(), here, H.G3.raw().data.maps[here])
    check(total > 250 and #wrong == 0, ("each of the %d balls and hidden items on a logic map is reachable "
      .. "with what the logic says it needs%s"):format(total, #wrong > 0 and (": NOT " .. table.concat(wrong, ", ")) or ""))
  end

  -- 1 to 3 worlds, 50 seeds each, replayed as the team with every world's finds
  do
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
    local runs, stuck = 0, {}
    for worlds = 1, 3 do
      for seed = 1, 50 do
        local plans = {}
        for w = 1, worlds do
          plans[w] = R.build({ seed = seed, locations = places, logic = L, Rng = Rng, items = true,
            badges = true, worlds = worlds, world = w, fallbackItem = "POTION" })
        end
        runs = runs + 1
        if not replay(plans) then stuck[#stuck + 1] = worlds .. "x" .. seed end
      end
    end
    check(#stuck == 0, ("%d runs of 1-3 worlds replayed as the team, all finishable%s"):format(runs,
      stuck[1] and (": NOT " .. table.concat(stuck, " ")) or ""))
  end
  -- badges only: the eight leaders trade badges among themselves
  local onlyGyms, badgeRuns = true, 0
  for seed = 1, 50 do
    local p = R.build({ seed = seed, locations = Modes.places(false, true), logic = L, Rng = Rng,
      badges = true, worlds = 1, world = 1, fallbackItem = "POTION" })
    if p.ok then badgeRuns = badgeRuns + 1 end
    for key in pairs(p.content) do if not key:match("^gym:") then onlyGyms = false end end
  end
  check(badgeRuns == 50 and onlyGyms, ("badges only: %d of 50 seeds finishable, nothing else moved"):format(badgeRuns))

  -- ------------------------------------------------------------ species
  local plan = Modes.plan()
  check(plan and plan.ok and plan.species, "this run's world is built (attempts " .. tostring(plan and plan.attempts) .. ")")
  -- dev/run_tests.sh compares this between FireRed and LeafGreen
  say("  item places fingerprint " .. tostring(plan and plan.fingerprint))
  local n, nonKanto, image = 0, 0, {}
  for from, to in pairs(plan.species) do
    n = n + 1
    image[to] = (image[to] or 0) + 1
  end
  local perm = true
  for _, c in pairs(image) do if c ~= 1 then perm = false end end
  check(n == 386 and perm, "the shuffle is a permutation of all 386 (" .. n .. ")")
  local Encounters = require("src.core.game3.encounters")
  local early = {}
  for _, mapId in ipairs({ "FR_ROUTE_1", "FR_ROUTE_2", "FR_ROUTE_22", "FR_VIRIDIAN_FOREST", "FR_ROUTE_3" }) do
    local t = Encounters.tableFor(mapId)
    for _, slot in ipairs(t and t.land and t.land.slots or {}) do
      local to = plan.species[tonumber(slot.species)]
      local nat = to and Pokemon.national(to)
      if nat and nat > 151 then nonKanto = nonKanto + 1; early[#early + 1] = Pokemon.name(to) end
    end
  end
  check(nonKanto > 0, "Johto and Hoenn Pokémon on the early routes: " .. table.concat(early, ", "):sub(1, 120))
  -- legendaries only among themselves
  local legendOk = true
  for sp in pairs(legendary) do if not legendary[plan.species[sp]] then legendOk = false end end
  check(legendOk, "legendaries shuffle among themselves")

  -- a wild battle meets the shuffled species
  Party.giveMon(s, 4, 10)      -- CHARMANDER
  Party.giveMon(s, 16, 8)      -- PIDGEY
  Bag.add(s.bag, ITEMS.ITEM_POKE_BALL, 5)
  Bag.add(s.bag, ITEMS.ITEM_POTION, 3)
  local enemy
  local function wild(species, level)
    BattleBridge.startWild(nil, game, { species = species, level = level }, {})
    for _ = 1, 600 do
      local st = Battle.isActive() and Battle.getState and Battle.getState()
      if st and st.enemy and st.enemy.mon then return st end
      U.wait(2)
    end
  end
  local st = wild(19, 3)        -- a vanilla RATTATA
  enemy = st and tonumber(st.enemy.mon.species)
  check(enemy == plan.species[19], "a wild RATTATA is now " .. tostring(enemy and Pokemon.name(enemy)))
  shot("wild")
  -- hardcore: this first encounter counts, items are refused, balls aren't
  check(not BattleItems.isBattleUsable(ITEMS.ITEM_POTION), "hardcore: no POTION in battle")
  check(BattleItems.isBattleUsable(ITEMS.ITEM_POKE_BALL), "but Poké Balls work")
  check(not BagMenu.partyAndStorageFull(s), "the area's first encounter may be caught")
  Battle.abort("run")
  for _ = 1, 600 do if not Battle.isActive() then break end U.wait(2) end
  check(H.fieldFree(), "the battle ended")
  st = wild(16, 3)
  check(BagMenu.partyAndStorageFull(s), "the second encounter in the same area is refused")
  local RomText = require("src.core.game3.rom_text")
  check(tostring(RomText.box("gText_BoxFull")):find("ENCOUNTER HERE", 1, true), "and says why")
  Battle.abort("run")
  for _ = 1, 600 do if not Battle.isActive() then break end U.wait(2) end
  H.fieldFree()

  -- Treecko's line evolves before the National Pokédex
  local grovyle = Pokemon.speciesFromNational(253)
  check(Evolution.nationalAllows(grovyle, s), "a Hoenn Pokémon may evolve before the National Pokédex")

  -- wild_legendaries (off on this server): at 100% every ordinary wild
  -- Pokémon is a legendary at its own level; a scripted battle keeps its own
  local legends = {}
  for sp in pairs(select(2, Modes.speciesData())) do legends[sp] = true end
  check(not Modes.rules.wildLegendaries or Modes.rules.wildLegendaries == 0, "wild legendaries are off here")
  -- as if the server said 100: every sync answer brings the rules again
  local origSynced = Modes.synced
  Modes.synced = function(...)
    origSynced(...)
    if Modes.rules then Modes.rules.wildLegendaries = 100 end
  end
  Modes.rules.wildLegendaries = 100
  local seenLegends, allLegends = {}, true
  for i = 1, 3 do
    st = wild(16, 7 + i)
    local mon = st and st.enemy.mon
    local sp = mon and tonumber(mon.species)
    if not (sp and legends[sp] and mon.level == 7 + i) then allLegends = false end
    if sp then seenLegends[#seenLegends + 1] = Pokemon.name(sp) .. " LV" .. tostring(mon.level) end
    if i == 1 then U.wait(150); shot("wild_legendary") end
    Battle.abort("run")
    for _ = 1, 600 do if not Battle.isActive() then break end U.wait(2) end
    H.fieldFree()
  end
  check(allLegends, "at 100%, Route 1's wild Pokémon are legendaries at their level: " .. table.concat(seenLegends, ", "))
  local scripted
  BattleBridge.startWild(nil, game, { species = 143, level = 30 }, { wildScripted = true, done = function() end })
  for _ = 1, 600 do
    scripted = Battle.isActive() and Battle.getState and Battle.getState()
    if scripted and scripted.enemy and scripted.enemy.mon then break end
    U.wait(2)
  end
  local ssp = scripted and scripted.enemy and tonumber(scripted.enemy.mon.species)
  check(ssp == plan.species[143] and not legends[ssp],
    "a scripted battle (SNORLAX) keeps its own shuffled Pokémon: " .. tostring(ssp and Pokemon.name(ssp)))
  Battle.abort("run")
  for _ = 1, 600 do if not Battle.isActive() then break end U.wait(2) end
  H.fieldFree()
  Modes.synced = origSynced
  Modes.rules.wildLegendaries = 0
  st = wild(16, 3)
  check(st and tonumber(st.enemy.mon.species) == plan.species[16], "off again: the shuffled PIDGEY")
  Battle.abort("run")
  for _ = 1, 600 do if not Battle.isActive() then break end U.wait(2) end
  H.fieldFree()

  -- ------------------------------------------------------------- starters
  -- Oak's three balls hold basic Pokémon that evolve twice, from all 386
  local starters = plan.starters or {}
  local name = G3.speciesName
  local pool = {}
  for _, sp in ipairs(Modes.lib.randomizer.starterPool(Modes.speciesData())) do pool[sp] = true end
  local a, b, c = starters[1], starters[4], starters[7]
  check(a and b and c and pool[a] and pool[b] and pool[c] and a ~= b and b ~= c and a ~= c,
    ("the starters: BULBASAUR's ball %s, CHARMANDER's %s, SQUIRTLE's %s"):format(name(a), name(b), name(c)))
  local rows = Modes.starterRows()
  local held = {}
  for _, r in ipairs(rows) do held[#held + 1] = r[2] end
  table.sort(held)
  local want = { a, b, c }
  table.sort(want)
  check(#rows == 3 and table.concat(held, ",") == table.concat(want, ","), "the three ball scripts hold them")
  -- picked for real: the ball, Oak's question, YES, no nickname
  local LAB = "FR_OAKS_LAB"
  local ball
  local labScripts = Space.ensureBundle().scripts
  for _, obj in ipairs(G3.raw().data.maps[LAB].objects or {}) do
    for _, r in ipairs(obj.scriptKey and labScripts[obj.scriptKey] or {}) do
      if r.op == "setvar" and r[1] == 0x4002 and r[2] == b then ball = obj end
    end
  end
  local function snap(t) local out = {} for k, v in pairs(t or {}) do out[k] = v end return out end
  local function restore(t, saved)
    if not t then return end
    for k in pairs(t) do t[k] = nil end
    for k, v in pairs(saved) do t[k] = v end
  end
  local dexSeen, dexOwned = snap(s.dex and s.dex.seen), snap(s.dex and s.dex.owned)
  local partyBefore = #s.party
  -- the lab's scene: Oak waits for a choice (VAR_MAP_SCENE_..._OAKS_LAB = 2)
  Flags.setVar(s, nil, 0x4055, 2)
  Flags.setVar(Space.store, nil, 0x4055, 2)
  local seen = {}
  if check(ball and H.talkTo(LAB, ball.x, ball.y), "walked up to CHARMANDER's ball in Oak's lab") then
    local yes = false
    for _ = 1, 1500 do
      if Message.isOpen() and Message.currentPage then
        local t = tostring(Message.currentPage()):gsub("%s+", " ")
        if seen[#seen] ~= t then seen[#seen + 1] = t; say("  lab: " .. t) end
      end
      if Choice.active then
        if not yes then yes = true; shot("starter_question"); U.tap(game, "a")   -- YES, this one
        else U.tap(game, "b") end                                                 -- no nickname
      elseif require("src.ui.game3.naming").isOpen() then require("src.ui.game3.naming").close("")
      elseif Message.isOpen() or G3.busy() then U.tap(game, "a")
      else break end
      U.wait(3)
    end
  end
  local all = table.concat(seen, " / ")
  check(all:find(name(b) .. " is your choice", 1, true) ~= nil and all:find(" POKéMON " .. name(b) .. "?", 1, true) ~= nil,
    "Oak asks about " .. name(b))
  check(all:find("received the " .. name(b), 1, true) ~= nil, "and hands it over")
  local got = s.party[#s.party]
  check(#s.party == partyBefore + 1 and got and tonumber(got.species) == b,
    "the party has " .. name(b) .. " (" .. tostring(got and name(got.species)) .. ")")
  -- the rest of the run's checks start from where they were
  if #s.party > partyBefore then table.remove(s.party) end
  if s.dex then restore(s.dex.seen, dexSeen); restore(s.dex.owned, dexOwned) end
  H.closeAll()
  H.fieldFree()

  -- --------------------------------------------------------------- items
  local function contentOf(kind, pred)
    for _, loc in ipairs(plan.locations or {}) do
      if loc.kind == kind and (not pred or pred(loc)) then return loc, plan.content[loc.key] end
    end
  end
  local ballLoc, ballC = contentOf("ball", function(loc) return loc.map == "FR_VIRIDIAN_FOREST" end)
  local ITEMS_BYID = require("src.core.game3.constants.firered.items").byId.ITEM_
  local ballId = ballLoc and ballLoc.ref.rows[ballLoc.ref.i][2]
  check(ballC and ITEMS_BYID[ballId] == "ITEM_" .. ballC.item,
    "a Viridian Forest ball now holds " .. tostring(ballC and ballC.item) .. " (was " .. tostring(ballLoc and ballLoc.vanilla.item) .. ")")
  local hidLoc, hidC = contentOf("hidden")
  check(hidC and ITEMS_BYID[hidLoc.ref.item] == "ITEM_" .. hidC.item, "a hidden item holds " .. tostring(hidC and hidC.item))
  -- picking the hidden one up gives that item
  local id = hidLoc.ref.item
  local before = Bag.get(s.bag, id)
  require("src.core.game3.field").pickUpHiddenItem(game, hidLoc.ref)
  for _ = 1, 200 do H.clearTexts(1); if not require("src.ui.game3.message").isOpen() then break end U.tap(game, "a"); U.wait(3) end
  check(Bag.get(s.bag, id) > before, "picking up the hidden item gave " .. hidC.item)

  local giftLoc, giftC = contentOf("gift", function(loc) return loc.gift == "TEA" end)
  check(giftC and ITEMS_BYID[giftLoc.ref.rows[giftLoc.ref.i][2]] == "ITEM_" .. giftC.item,
    "the Celadon lady's TEA is now " .. tostring(giftC and giftC.item))

  -- a two-world multiworld: every key item in exactly one world, split evenly
  local w1 = R.build({ seed = 4242, locations = places, logic = L, Rng = Rng, items = true, badges = true,
    worlds = 2, world = 1, fallbackItem = "POTION" })
  local w2 = R.build({ seed = 4242, locations = places, logic = L, Rng = Rng, items = true, badges = true,
    worlds = 2, world = 2, fallbackItem = "POTION" })
  local where = {}
  for w, p in ipairs({ w1, w2 }) do
    for _, c in pairs(p.content) do
      if prog[c.item] then where[c.item] = (where[c.item] or 0) + 1 end
    end
  end
  local once = w1.ok and w2.ok
  for _, id in ipairs(L.PROGRESSION) do if where[id] ~= 1 then once = false end end
  check(once and math.abs(w1.myProgression - w2.myProgression) <= 1,
    ("multiworld: each key item and badge in one world (%d + %d of %d)"):format(w1.myProgression or 0,
      w2.myProgression or 0, #L.PROGRESSION))

  -- ---------------------------------------------------------- shared items
  local buddy = H.post({ action = "register_player", isNewCharacter = true, name = "BUDDY",
    spriteId = "OBJ_EVENT_GFX_BROCK", title = "X", badges = 0, pokedexCount = 0 })
  local bTid, bTok = buddy.account.trainerId, buddy.account.token
  local runId = Modes.rules.runId
  local res = H.post({ action = "team_found", trainerId = bTid, token = bTok, runId = runId,
    item = "SILPH_SCOPE", itemName = "SILPH SCOPE", location = "ROCKET_HIDEOUT_B4F" })
  H.post({ action = "team_found", trainerId = bTid, token = bTok, runId = runId,
    item = "BADGE1", itemName = "BOULDERBADGE", location = "PEWTER_CITY_GYM" })
  check(res and res.success, "BUDDY found the SILPH SCOPE and the BOULDERBADGE")
  local got = false
  for _ = 1, 600 do
    if Bag.get(s.bag, ITEMS.ITEM_SILPH_SCOPE) > 0 and Flags.getFlag(Space.store, nil, 0x820) then got = true break end
    U.wait(5)
  end
  check(got, "they reached this game: SILPH SCOPE in the bag, BOULDERBADGE won")
  H.clearTexts()
  check(H.said("YOUR TEAM FOUND"), "and it was told")
  -- this player's own find reaches the team
  Bag.add(s.bag, ITEMS.ITEM_CARD_KEY, 1)
  local team
  for _ = 1, 600 do
    local t = H.post({ action = "team_status", trainerId = bTid })
    team = t and t.team
    local has = false
    for _, it in ipairs(team and team.items or {}) do if it == "CARD_KEY" then has = true end end
    if has then break end
    team = nil
    U.wait(5)
  end
  check(team ~= nil, "our CARD KEY reached the team")

  -- ----------------------------------------------------------- Nuzlocke
  check(Modes.levelCap() == 21, "the level cap with BOULDERBADGE held: " .. Modes.levelCap())

  -- ------------------------------------------------------------- badges
  local function badgeFlag(i) return Flags.getFlag(Space.store, nil, 0x820 + i - 1) end
  local gymList = {}
  for i = 1, 8 do
    local c = plan.gyms and plan.gyms["BADGE" .. i]
    gymList[#gymList + 1] = c and c.item or "?"
  end
  check(Modes.rules.badges and #gymList == 8 and not table.concat(gymList, " "):find("?", 1, true),
    "the badge slots hold: " .. table.concat(gymList, " "))
  local function closeMessages()
    for _ = 1, 600 do
      if H.isText(H.top()) then H.clearTexts(1)
      elseif Choice.active then U.tap(game, "b")
      elseif Message.isOpen() or H.G3.busy() then U.tap(game, "a")
      else return true end
      U.wait(3)
    end
  end
  -- a badge in an item ball: picked up the way a player does
  local bLoc, bC = contentOf("ball", function(loc)
    local c = plan.content[loc.key]
    return c and c.item:match("^BADGE%d$") and loc.x ~= nil
  end)
  if bLoc then
    local i = tonumber(bC.item:match("%d"))
    local had = badgeFlag(i)
    check(H.talkTo(bLoc.map, bLoc.x, bLoc.y), "walked up to the ball on " .. bLoc.map .. " and pressed A")
    local text = Message.isOpen() and Message.currentPage and tostring(Message.currentPage()) or ""
    shot("badge_ball")
    closeMessages()
    check(badgeFlag(i) and (had or text:find("BADGE", 1, true)),
      ("it held the %s and it's won (%s)"):format(Modes.itemName(bC.item), text:gsub("\n", " ")))
    check(Bag.get(s.bag, 51 + i) == 0, "no marker item left in the bag")
  else
    say("  (this seed puts no badge in an item ball)")
  end
  -- Brock, fought for real: his slot hands over what the seed put there
  local maps = H.G3.raw().data.maps
  local brock
  local GFX = require("src.core.game3.constants.firered.event_objects")
  for _, o in ipairs(maps.FR_PEWTER_CITY_GYM.objects or {}) do
    local g = o.graphicsId or o.graphics
    if (tonumber(g) and GFX.byId and GFX.byId.OBJ_EVENT_GFX_ and GFX.byId.OBJ_EVENT_GFX_[tonumber(g)] or tostring(g)):find("BROCK") then
      brock = o
    end
  end
  Party.giveMon(s, 6, 60)      -- a CHARIZARD leads for this one
  local zard = table.remove(s.party)
  table.insert(s.party, 1, zard)
  local slot1 = plan.gyms.BADGE1
  local slotId = not slot1.item:match("^BADGE") and ITEMS["ITEM_" .. slot1.item]
  local before = slotId and Bag.get(s.bag, slotId) or 0
  -- randomize_trainers = gyms (off on this server; pinned across syncs as
  -- for the legendaries): BROCK's team is Rock types of his own team's strength
  local origSyncedT = Modes.synced
  Modes.synced = function(...)
    origSyncedT(...)
    if Modes.rules then Modes.rules.trainers = "gyms" end
  end
  Modes.rules.trainers = "gyms"
  check(Modes.trainerTeam(4321, { 16, 19 }, "FR_ROUTE_3") == nil, "gyms: a route trainer keeps his team")
  local champ = Modes.trainerTeam(438, { 18, 65, 112, 130, 59, 9 }, "FR_INDIGO_PLATEAU_CHAMPIONS_ROOM")
  check(champ and #champ == 6, "but the Champion's is randomized")
  check(brock and H.talkTo("FR_PEWTER_CITY_GYM", brock.x, brock.y), "talked to BROCK")
  for _ = 1, 600 do
    if Battle.isActive() then break end
    if Message.isOpen() then U.tap(game, "a") end
    U.wait(2)
  end
  check(Battle.isActive(), "BROCK's battle began")
  local foe = (Battle.getState() or {}).foeParty or {}
  local foeNames, rocks, foeSpecies, hasMoves = {}, #foe > 0, {}, true
  for i, m in ipairs(foe) do
    local sp = tonumber(m.species or m.speciesId)
    local t = sp and Pokemon.types(sp) or {}
    if not (t[1] == 5 or t[2] == 5) then rocks = false end
    if not (type(m.moves) == "table" and (tonumber(m.moves[1]) or (type(m.moves[1]) == "table" and m.moves[1].id))) then
      hasMoves = false
    end
    foeSpecies[i] = sp
    foeNames[i] = (sp and Pokemon.name(sp) or "?") .. " LV" .. tostring(m.level)
  end
  check(rocks, "randomized trainers: BROCK's team is all Rock types: " .. table.concat(foeNames, ", "))
  check(hasMoves, "with moves of their own")
  check(table.concat(Modes.trainerTeam(414, { 74, 95 }, "FR_PEWTER_CITY_GYM") or {}, ",")
    == table.concat(foeSpecies, ","), "the seed's draw for his GEODUDE and ONIX, the same every time")
  -- his first Pokémon out, at the battle menu
  local api0 = BattleAPI.new(game)
  for _ = 1, 600 do
    local snap = api0:snapshot()
    if snap and snap.prompt == "menu" then break end
    if snap and snap.prompt == "advance" then U.tap(game, "a") end
    U.wait(2)
  end
  shot("brock_team")
  Modes.synced = origSyncedT
  Modes.rules.trainers = "off"
  check(require("src.core.game3.options").battleStyle(s) == "set", "hardcore: the battle style is SET")
  local zardExp = tonumber(zard.exp) or 0
  local api, intent = BattleAPI.new(game), 0
  for _ = 1, 6000 do
    if not Battle.isActive() then break end
    local snap = api:snapshot()
    if snap and (snap.prompt == "menu" or snap.prompt == "moves") then
      intent = intent + 1
      api:submit({ id = intent, revision = snap.revision, kind = snap.prompt == "menu" and "menu" or "move",
        choice = "fight", slot = 1 })
    elseif Choice.active then U.tap(game, "b")
    else U.tap(game, "a") end
    U.wait(2)
  end
  check(not Battle.isActive(), "BROCK was beaten")
  check((tonumber(zard.exp) or 0) == zardExp, ("the Lv. %d CHARIZARD, over the level cap (%d), gained no EXP")
    :format(tonumber(zard.level) or 0, Modes.levelCap()))
  closeMessages()
  H.clearTexts()
  shot("brock")
  if slot1.item == "BADGE1" then
    check(badgeFlag(1), "BROCK's slot held his own BOULDERBADGE")
  elseif slot1.item:match("^BADGE%d$") then
    local i = tonumber(slot1.item:match("%d"))
    check(badgeFlag(i), "BROCK's slot gave the " .. Modes.itemName(slot1.item))
  else
    check(Bag.get(s.bag, slotId) > before, "BROCK's slot gave " .. slot1.item)
  end
  if slot1.item ~= "BADGE1" then
    check(H.said("BADGE WAS SHUFFLED"), "and said BROCK's badge was shuffled")
  end
  check(Gen3Compat.getFlag("FLAG_DEFEATED_BROCK"), "BROCK counts as beaten")
  for i = #s.party, 1, -1 do if s.party[i] == zard then table.remove(s.party, i) end end
  -- a Pokémon fainting is buried
  s.party[2].hp = 0
  for _ = 1, 300 do if #s.party == 1 then break end U.wait(2) end
  check(#s.party == 1 and tonumber(s.party[1].species) == 4, "the fainted PIDGEY is gone for good")
  H.clearTexts()
  check(H.said("GONE FOR GOOD"), "and it was told")
  -- a wipe ends the run for the team; the next one starts in the bedroom
  require("src.mods.Runtime").emit("world.blacked_out", {})
  local newRun = false
  for _ = 1, 1200 do
    H.clearTexts(1)
    local st2 = Modes.state()
    if Modes.rules and Modes.rules.runId == runId + 1 and st2.run == runId + 1 then newRun = true break end
    U.wait(5)
  end
  check(newRun, "a wipe started run " .. (runId + 1))
  s = Runtime.getSession()
  check(s.map == "FR_PLAYERS_HOUSE_2F" and #(s.party or {}) == 0 and s.name == "ASH",
    "a new game in the bedroom for ASH (" .. tostring(s.map) .. ")")
  -- the run's messages come up once the field is free
  for _ = 1, 400 do H.clearTexts(1); U.wait(1) end
  check(H.said("RUN 2 BEGINS"), "RUN 2 BEGINS was told")
  H.closeAll()

  -- -------------------------------------------------------- back offline
  local vanillaBall = ballLoc.vanilla.item
  H.startItem("gen1online")
  H.choose("DISCONNECT")
  H.clearTexts()
  check(not H.online(), "disconnected")
  local now = ballLoc.ref.rows[ballLoc.ref.i][2]
  check(ITEMS_BYID[now] == "ITEM_" .. vanillaBall, "the ball holds its vanilla " .. vanillaBall .. " again")
  check(not Evolution.nationalAllows(grovyle, Runtime.getSession()), "the National Pokédex rule is back")
  check(not BagMenu.partyAndStorageFull(Runtime.getSession()), "no Nuzlocke offline")
  H.closeAll()

  -- ----------------------------------------------------------- JOIN again
  local function join()
    H.fieldFree()
    H.startItem("gen1online")
    H.choose("^JOIN")
    for _ = 1, 300 do if H.online() and Runtime.isActive() then break end U.wait(2) end
    -- the CONNECTED box, then the ONLINE menu: closed, as a player would
    H.clearTexts()
    H.closeAll()
    H.fieldFree()
  end
  -- the run comes back from the online save: run 2, the world shuffled again
  local mark = #H.seen
  join()
  check(H.online() and Modes.state().run == runId + 1 and Modes.rules.runId == runId + 1,
    "JOIN again: run " .. (runId + 1) .. " reloaded from the online save")
  check(Modes.plan() ~= nil and ITEMS_BYID[ballLoc.ref.rows[ballLoc.ref.i][2]] ~= nil
    and Modes.plan().species ~= nil, "and the world is shuffled again")
  local restarted = false
  for i = mark + 1, #H.seen do if H.seen[i]:find("BEGINS", 1, true) then restarted = true end end
  check(not restarted, "without starting over")
  -- a teammate's wipe while this player is offline: the save is from an
  -- older run, so JOIN starts the next one (the old save kept as a backup)
  H.startItem("gen1online")
  H.choose("DISCONNECT")
  H.clearTexts()
  H.closeAll()
  local wiped = H.post({ action = "run_wipe", trainerId = bTid, token = bTok, runId = runId + 1 })
  check(wiped and wiped.success and wiped.run and wiped.run.runId == runId + 2,
    "BUDDY's party wiped out while ASH was offline: run " .. tostring(wiped and wiped.run and wiped.run.runId))
  mark = #H.seen
  join()
  local over = false
  for _ = 1, 600 do
    H.clearTexts(1)
    if Modes.state().run == runId + 2 then over = true break end
    U.wait(2)
  end
  for _ = 1, 400 do H.clearTexts(1); U.wait(1) end
  local overText, beginText = false, false
  for i = mark + 1, #H.seen do
    if H.seen[i]:find("RUN " .. (runId + 1) .. " IS OVER", 1, true) then overText = true end
    if H.seen[i]:find("RUN " .. (runId + 2) .. " BEGINS", 1, true) then beginText = true end
  end
  check(over and overText and beginText, ("JOIN with the old run's save: told run %d is over, run %d begins")
    :format(runId + 1, runId + 2))
  s = Runtime.getSession()
  check(s.map == "FR_PLAYERS_HOUSE_2F" and #(s.party or {}) == 0, "a new game in the bedroom")
  local backup = love.filesystem.getInfo("mod_compat/gen1online-plus/gen1online_online_save_"
    .. H.version .. "_run" .. (runId + 1) .. "_backup.lua")
  check(backup ~= nil, "run " .. (runId + 1) .. "'s save is kept as a backup")
  H.closeAll()

  -- --------------------------------------- a new device: the recovery token
  -- REDEEM RECOVERY TOKEN joins the run like any CONNECT: the new game in
  -- the bedroom is the team's current run, in the shuffled world
  H.startItem("gen1online")
  H.choose("DISCONNECT")
  H.clearTexts()
  H.closeAll()
  local dir = love.filesystem.getSaveDirectory() .. "/mod_compat/gen1online-plus/"
  os.remove(dir .. "gen1online_online_account_" .. H.version .. ".lua")
  os.remove(dir .. "save_online_" .. H.version .. ".lua")
  H.fieldFree()
  H.startItem("gen1online")
  H.choose("^JOIN")
  H.choose("REDEEM RECOVERY TOKEN")
  if not H.naming(ashToken) then return finish() end
  for _ = 1, 300 do if H.online() and Runtime.isActive() then break end U.wait(2) end
  mark = #H.seen
  for _ = 1, 400 do H.clearTexts(1); U.wait(1) end
  H.closeAll()
  check(H.online() and Modes.rules and Modes.rules.runId == runId + 2 and Modes.state().run == runId + 2,
    "a new device: REDEEM RECOVERY TOKEN joins run " .. (runId + 2) .. " (" .. tostring(Modes.state().run) .. ")")
  check(Modes.plan() ~= nil and Evolution.nationalAllows(grovyle, Runtime.getSession()),
    "in the shuffled world")
  local again = false
  for i = mark + 1, #H.seen do if H.seen[i]:find("BEGINS", 1, true) then again = true end end
  check(not again, "without starting another run")
  return finish()
end
