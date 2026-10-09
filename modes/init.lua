-- Server game modes on Gen 1: hardcore Nuzlocke, the co-op randomizer and the
-- team's shared key items.  The server's server_config.txt picks them; the
-- server keeps the run (its number and seed) and the team's finds, and this
-- module plays them out.  Everything here is online-only: offline, or on a
-- server with the modes off, every hook passes straight through and the
-- shuffled world is put back.
--
-- main.lua builds it once (Gen 1 only) with the few things it needs:
--   ctx = { mod, requireLocal, isOnline(), post(payload, timeout),
--           trainerId(save), writeOnlineSave(save), getWorld(game),
--           storageWrite(key, value), storedAccount(), wrapText(text),
--           home = {map, x, y} }
-- and calls M.precheck(game, rules) on CONNECT (before anything changes),
-- M.connected(game, rules, fresh) once connected and M.synced(game, res)
-- with every sync_pos answer.  M.rules is the server's rules view; M.world
-- is this player's world in a multiworld run (multiworld = on).
return function(ctx)
  local mod = ctx.mod
  local Rng = ctx.requireLocal("modes/rng.lua")
  local L = ctx.requireLocal("modes/logic.lua")
  local Randomizer = ctx.requireLocal("modes/randomizer.lua")
  local Game = require("src.core.Game")
  local Bag = require("src.inventory.Bag")
  local ItemEffects = require("src.inventory.ItemEffects")
  local OverworldState = require("src.world.OverworldController")
  local BattleState = require("src.battle.BattleState")
  local TextBox = require("src.render.TextBox")
  local GameVersion = require("src.core.GameVersion")
  local okV, victories = pcall(require, "data.scripts.victories")
  if not (okV and type(victories) == "table") then victories = {} end
  -- the growth curves (Growth.expForLevel), for the level cap's EXP clamp
  local okG, Growth = pcall(require, "src.pokemon.Growth")
  if not (okG and type(Growth) == "table" and Growth.expForLevel) then Growth = nil end

  -- lib: the pure modules, for the dev drivers' checks on real game data
  local M = { rules = nil, world = nil, lib = { Rng = Rng, logic = L, randomizer = Randomizer } }
  local plan, planKey, undo = nil, nil, nil
  local reports, retryAt = {}, 0     -- shared finds waiting to reach the server
  local notes = {}                   -- texts for when the overworld is free
  local granting = false             -- adding the team's items: not a find
  local lastTeamRev = nil
  local pendingRestart = false
  local wipeQueued, wipeRetryAt = false, 0
  local owedAt = 0                   -- next try at a gym prize that found no room
  local battleInfo = nil             -- { catchable, why } for this wild battle
  local currentBattle = nil          -- the battle on screen, any kind

  local BADGES = { "BOULDERBADGE", "CASCADEBADGE", "THUNDERBADGE", "RAINBOWBADGE",
                   "SOULBADGE", "MARSHBADGE", "VOLCANOBADGE", "EARTHBADGE" }
  -- the next gym leader's strongest Pokémon, by badges held, then the Champion
  local CAPS = { red = { 14, 21, 24, 29, 43, 43, 47, 50, 65 },
                 yellow = { 12, 21, 28, 32, 50, 50, 54, 55, 65 } }
  -- key items that stay each player's own: consumed quest items with a
  -- per-player script around them, and the fossil choice
  local NOT_SHARED = { OAKS_PARCEL = true, SAFARI_BALL = true, ITEM_2C = true,
                       DOME_FOSSIL = true, HELIX_FOSSIL = true, OLD_AMBER = true }

  local function online() return ctx.isOnline() and M.rules ~= nil end
  local function rules() return online() and M.rules or nil end
  function M.hardcore() local r = rules(); return r ~= nil and r.nuzlocke == "hardcore" end
  local function sharing() local r = rules(); return r ~= nil and r.sharedKeyItems == true end
  local function note(text) notes[#notes + 1] = text end

  -- this player's mode state, inside the online save
  local function state(save)
    save = save or Game.save
    if type(save) ~= "table" then return {} end
    local st = save.g1oModes
    if type(st) ~= "table" then st = {}; save.g1oModes = st end
    st.got = st.got or {}
    st.areas = st.areas or {}
    st.graveyard = st.graveyard or {}
    st.trades = st.trades or {}      -- { [leaders beaten] = Pokémon received }
    return st
  end
  M.state = state

  local function itemDef(id) return Game.data and Game.data.items and Game.data.items[id] end
  local function itemName(id) local d = itemDef(id); return d and d.name or tostring(id) end
  local function isBadge(id) return type(id) == "string" and id:find("BADGE", 1, true) ~= nil end
  function M.isShared(id)
    if type(id) ~= "string" or NOT_SHARED[id] or not itemDef(id) then return false end
    return isBadge(id) or itemDef(id).keyItem == true or id:match("^HM_") ~= nil
  end

  -- each gym's beaten flag, by the badge vanilla gives there
  local GYM_FLAG = {}
  for _, reward in pairs(victories) do
    if type(reward) == "table" and reward.badge and reward.flag then
      GYM_FLAG[reward.badge] = reward.flag
    end
  end
  local function leaderBeaten(flags, badge) return GYM_FLAG[badge] and flags[GYM_FLAG[badge]] end

  -- gym leaders this player has beaten: their defeat flags, never the badges
  -- held (the randomizer moves the badges)
  function M.gymsBeaten(save)
    save = save or Game.save or {}
    local flags, beaten = save.flags or {}, 0
    for _, b in ipairs(BADGES) do
      if leaderBeaten(flags, b) then beaten = beaten + 1 end
    end
    return beaten
  end

  -- The randomizer opens the gyms in any order (Blaine can come before Lt.
  -- Surge, the badges from anywhere), so the cap is the highest of: the next
  -- leader by badges held, by leaders beaten, and the weakest leader this
  -- player can reach now (the logic's own gym needs) and has not beaten.  A
  -- fight the way on needs is never above the cap.
  function M.levelCap(save)
    save = save or Game.save or {}
    local flags, have = save.flags or {}, {}
    for _, store in ipairs({ save.inventory or {}, save.pcItems or {} }) do
      for id, n in pairs(store) do
        if (tonumber(n) or 1) > 0 then have[id] = true end
      end
    end
    local caps = GameVersion.isYellow and GameVersion.isYellow() and CAPS.yellow or CAPS.red
    local held, beaten, weakest = 0, M.gymsBeaten(save), 0
    for i, b in ipairs(BADGES) do
      if have[b] then held = held + 1 end
      if not leaderBeaten(flags, b) and L.GYMS[b] and L.satisfied(L.expand(L.GYMS[b]), have)
          and (weakest == 0 or caps[i] < weakest) then
        weakest = caps[i]
      end
    end
    return math.max(caps[held + 1] or 100, caps[beaten + 1] or 100, weakest)
  end

  -- Trades (hardcore, tradesPerGym > 0): the Pokémon this player may receive
  -- online (a GTS buy or claim, a Wonder Trade, a link trade) between two gym
  -- leaders.  A stretch is the number of leaders beaten, so beating one opens
  -- a fresh allowance, and a new run (a new state) starts over.  0: no limit.
  function M.tradeLimit()
    if not M.hardcore() then return 0 end
    return math.max(0, tonumber(rules().tradesPerGym) or 0)
  end

  local function tradesUsed(save)
    local trades = state(save).trades or {}
    return tonumber(trades[tostring(M.gymsBeaten(save))]) or 0
  end

  -- nil: no limit
  function M.tradesLeft(save)
    local limit = M.tradeLimit()
    if limit <= 0 then return nil end
    return math.max(0, limit - tradesUsed(save))
  end

  -- nil when a trade may go ahead, else why not
  function M.tradeRefusal(save)
    local left = M.tradesLeft(save)
    if left == nil or left > 0 then return nil end
    if M.gymsBeaten(save) >= #BADGES then
      return "HARDCORE NUZLOCKE: NO TRADES LEFT!\fNO GYM LEADERS ARE LEFT TO BEAT."
    end
    local limit = M.tradeLimit()
    return ("HARDCORE NUZLOCKE: %s SINCE YOUR LAST GYM LEADER!\fBEAT THE NEXT ONE TO TRADE AGAIN.")
      :format(limit > 1 and ("YOU ALREADY MADE YOUR %d TRADES"):format(limit) or "YOU ALREADY TRADED")
  end

  local function leftText(save, left)
    return (M.gymsBeaten(save) >= #BADGES and "%d LEFT." or "%d LEFT UNTIL THE NEXT GYM LEADER."):format(left)
  end

  -- A trade made: counted in this stretch.  Returns the trades left.  `what`
  -- names it for the note (a GTS buy, a link trade...).
  function M.tradeDone(save, what)
    if M.tradeLimit() <= 0 then return nil end
    save = save or Game.save
    if type(save) ~= "table" then return nil end
    local st, key = state(save), tostring(M.gymsBeaten(save))
    st.trades[key] = (tonumber(st.trades[key]) or 0) + 1
    ctx.writeOnlineSave(save)
    local left = M.tradesLeft(save)
    note(("%s USED A TRADE: %s"):format(what or "THAT", leftText(save, left)))
    return left
  end

  -- A GTS or Wonder Trade deposit is the trade: it uses the allowance when it
  -- goes in, so whatever comes back for it is always the player's to claim
  -- (nothing is ever stuck in a claim box or the pool).  Taking the deposit
  -- back in the same stretch gives the trade back.
  function M.tradeReserve(save, id, what)
    local left = M.tradeDone(save, what)
    if left == nil then return nil end
    save = save or Game.save
    local st, key = state(save), tostring(M.gymsBeaten(save))
    -- only this stretch's deposits can be taken back for a refund: older
    -- entries are spent, so they go (the save doesn't grow with every deposit)
    local reserved = {}
    for k, v in pairs(st.reserved or {}) do if v == key then reserved[k] = v end end
    reserved[tostring(id)] = key
    st.reserved = reserved
    ctx.writeOnlineSave(save)
    return left
  end

  function M.tradeRelease(save, id)
    if M.tradeLimit() <= 0 then return nil end
    save = save or Game.save
    if type(save) ~= "table" then return nil end
    local st, key = state(save), tostring(M.gymsBeaten(save))
    local stretch = st.reserved and st.reserved[tostring(id)]
    if st.reserved then st.reserved[tostring(id)] = nil end
    if stretch ~= key then return M.tradesLeft(save) end   -- an older stretch's trade: spent
    st.trades[key] = math.max(0, (tonumber(st.trades[key]) or 0) - 1)
    ctx.writeOnlineSave(save)
    local left = M.tradesLeft(save)
    note("TRADE TAKEN BACK: " .. leftText(save, left))
    return left
  end

  -- ---- the randomized world: built from the seed, put back when it ends ---------

  local function worlds(r)
    return (r and r.multiworld and tonumber(r.players)) or 1
  end

  function M.refresh()
    local r = rules()
    local key = nil
    -- a multiworld player without a world yet (refused, or not joined) plays none
    if r and r.randomizer and r.seed and Game.data and (worlds(r) == 1 or M.world) then
      key = ("%s/%s%s%s%s/%d:%d"):format(tostring(r.seed), tostring(r.encounters), tostring(r.items),
                                         tostring(r.badges), tostring(r.starters), worlds(r),
                                         worlds(r) > 1 and M.world or 1)
    end
    if key == planKey then return end
    if undo then undo(); undo = nil end
    plan, planKey = nil, key
    if not key then return end
    plan = Randomizer.build({ seed = r.seed, data = Game.data, victories = victories,
                              logic = L, Rng = Rng, encounters = r.encounters,
                              items = r.items, badges = r.badges, starters = r.starters,
                              worlds = worlds(r), world = M.world })
    undo = Randomizer.apply(plan, Game.data, victories)
    if not plan.ok then
      note("THE RANDOMIZER COULDN'T SHUFFLE THIS GAME'S ITEMS. THEY STAY WHERE THEY ARE.")
    end
  end
  function M.plan() return plan end

  -- Anything that reads the item data for a build or a fingerprint must see
  -- the vanilla game: while this world's shuffle is applied, the map objects
  -- hold its items, and another world built from those would differ from
  -- the one every other client builds.
  local function withVanilla(fn)
    if not undo then return fn() end
    undo()
    local ok, res = pcall(fn)
    undo = Randomizer.apply(plan, Game.data, victories)
    if not ok then error(res, 0) end
    return res
  end

  -- another world's plan in this run (the same pure build every client does)
  function M.planFor(world)
    local r = M.rules
    if not (r and r.randomizer and r.seed and Game.data) then return nil end
    return withVanilla(function()
      return Randomizer.build({ seed = r.seed, data = Game.data, victories = victories,
                                logic = L, Rng = Rng, encounters = r.encounters,
                                items = r.items, badges = r.badges, starters = r.starters,
                                worlds = worlds(r), world = world })
    end)
  end

  local function mapSpecies(species)
    return plan and plan.species and plan.species[species] or nil
  end

  -- wild_legendaries: a wild encounter is now and then a legendary at its
  -- own level (the static ones, script rows, keep theirs)
  local legendaryList = nil
  local function random() return ((love and love.math and love.math.random) or math.random)() end
  function M.wildLegendary()
    local r = rules()
    local chance = r and r.randomizer and tonumber(r.wildLegendaries) or 0
    if chance <= 0 then return nil end
    legendaryList = legendaryList or Randomizer.legendaryList(Randomizer.LEGENDARY, Game.data and Game.data.pokemon)
    return Randomizer.rollLegendary(chance, random, legendaryList)
  end

  mod.hooks:wrap("encounter.species", function(nextFn, enc, hctx)
    local e = nextFn(enc, hctx)
    local s = e and (M.wildLegendary() or mapSpecies(e.species))
    if s then return { species = s, level = e.level } end
    return e
  end)

  mod.hooks:wrap("encounter.fishing", function(nextFn, rod, mapId, pool)
    local e = nextFn(rod, mapId, pool)
    local s = e and (M.wildLegendary() or mapSpecies(e.species))
    if s then return { species = s, level = e.level } end
    return e
  end)

  -- randomize_trainers: gym leaders and their gyms' trainers keep the gym's
  -- type, the Elite Four theirs; the Champion (and with "on" every other
  -- trainer) gets Pokémon of the same strength.  Each team comes from the
  -- run's seed, the trainer's class and party: the same every time, for every
  -- player.  Levels stay; moves are the new Pokémon's own.
  local GYM_TYPE = { PEWTER_GYM = "ROCK", CERULEAN_GYM = "WATER", VERMILION_GYM = "ELECTRIC",
    CELADON_GYM = "GRASS", FUCHSIA_GYM = "POISON", SAFFRON_GYM = "PSYCHIC_TYPE",
    CINNABAR_GYM = "FIRE", VIRIDIAN_GYM = "GROUND" }
  local ELITE_TYPE = { OPP_LORELEI = "ICE", OPP_BRUNO = "FIGHTING", OPP_AGATHA = "GHOST",
    OPP_LANCE = "DRAGON" }
  M.GYM_TYPE, M.ELITE_TYPE = GYM_TYPE, ELITE_TYPE
  function M.trainerTeam(oppClass, partyIndex, species, mapId)
    local r = rules()
    local mode = r and r.randomizer and r.trainers
    if mode ~= "gyms" and mode ~= "on" then return nil end
    if not mapId then
      local ow = Game.overworld
      mapId = ow and ow.map and ow.map.id
    end
    local theme = ELITE_TYPE[oppClass] or GYM_TYPE[mapId]
    if not theme and oppClass ~= "OPP_RIVAL3" and mode ~= "on" then return nil end
    local salt = 30000 + Randomizer.saltOf(tostring(oppClass) .. "#" .. tostring(partyIndex))
      + ((worlds(r) > 1 and M.world) or 0) * 1000
    return Randomizer.trainerTeam(Rng.new(r.seed, salt), species, Game.data and Game.data.pokemon,
      Randomizer.LEGENDARY, theme)
  end

  mod.hooks:wrap("trainer.party", function(nextFn, oppClass, partyIndex, partyDef)
    local out = nextFn(oppClass, partyIndex, partyDef)
    if type(out) ~= "table" or #out == 0 then return out end
    local species = {}
    for i, slot in ipairs(out) do species[i] = slot.species end
    local new = M.trainerTeam(oppClass, partyIndex, species)
    if not new then return out end
    local copy = {}
    for i, slot in ipairs(out) do
      local row = {}
      for k, v in pairs(slot) do row[k] = v end
      -- the vanilla moves belong to the vanilla Pokémon
      row.species, row.moves = new[i], nil
      copy[i] = row
    end
    return copy
  end)

  -- Oak's lab: the starters (plan.starters) on the rows that show, name and
  -- give one.  Red and Blue ask with a line naming the vanilla species (made
  -- anew here); Yellow's PIKACHU scene after the gift (it hates its ball and
  -- comes out to follow) is left out when the starter is something else.
  -- The rival's own lines and team stay vanilla.  Returns the new args,
  -- false to skip the row, or nil.
  local STARTER_ASK = { _OaksLabYouWantCharmanderText = "CHARMANDER",
    _OaksLabYouWantSquirtleText = "SQUIRTLE", _OaksLabYouWantBulbasaurText = "BULBASAUR" }
  local STARTER_GOT = { _OaksLabReceivedMonText = true, _OaksLabReceivedText = true }
  local PIKACHU_SCENE = { _OaksLabPikachuDislikesPokeballsText1 = true,
    _OaksLabPikachuDislikesPokeballsText2 = true }
  function M.starterQuestion(species)
    local def = Game.data and Game.data.pokemon and Game.data.pokemon[species] or {}
    local kind = tostring((def.types or {})[1] or ""):gsub("_TYPE$", "")
    return ("So! You want the\n%sPOKéMON,\011%s?{DONE}"):format(kind ~= "" and (kind .. " ") or "",
      tostring(def.name or species))
  end
  local function starterRow(sctx, name, args)
    local ow = sctx and sctx.overworld
    local s = plan and plan.starters
    if not (s and ow and ow.map and ow.map.id == "OAKS_LAB") then return nil end
    local a = { unpack(args, 1, table.maxn(args)) }
    if name == "give_pokemon" and s[args[1]] then
      a[1] = s[args[1]]
      return a
    elseif name == "push_screen" and args[1] == "DexEntryMenu" and type(args[2]) == "table"
        and s[args[2].species] then
      local o = {}
      for k, v in pairs(args[2]) do o[k] = v end
      o.species, a[2] = s[args[2].species], o
      return a
    elseif name == "ask" and STARTER_ASK[args[1]] and s[STARTER_ASK[args[1]]] then
      a[1] = M.starterQuestion(s[STARTER_ASK[args[1]]])
      return a
    elseif name == "show_text" and STARTER_GOT[args[1]] and type(args[2]) == "table" and s[args[2].RAM] then
      a[2] = { RAM = s[args[2].RAM] }
      return a
    elseif s.PIKACHU and s.PIKACHU ~= "PIKACHU" and ((name == "show_text" and PIKACHU_SCENE[args[1]])
        or (name == "play_cry" and args[1] == "PIKACHU") or name == "spawn_pikachu_follower") then
      return false
    end
    return nil
  end

  -- script rows: shuffled NPC gifts, static Pokémon (Snorlax, the birds...)
  -- and the starters
  mod.hooks:wrap("script.command", function(nextFn, sctx, name, args)
    if plan and type(args) == "table" then
      local starter = starterRow(sctx, name, args)
      if starter == false then return nil end
      if starter then return nextFn(sctx, name, starter) end
      if name == "load_player_starter_name" and plan.starters then
        -- the Champion's room: Oak names the starter chosen in his lab
        local res = nextFn(sctx, name, args)
        local game = sctx and sctx.game
        local pokemon = game and game.data and game.data.pokemon or {}
        for vanilla, now in pairs(plan.starters) do
          if pokemon[vanilla] and game.stringBuffer == pokemon[vanilla].name then
            game.stringBuffer = (pokemon[now] or {}).name or now
            break
          end
        end
        return res
      end
      if name == "give_item" and plan.gifts[args[1]] then
        local c = plan.gifts[args[1]]
        local a = { unpack(args, 1, math.max(table.maxn(args), 5)) }
        a[1], a[2] = c.item, c.count
        -- a script's own received line may name the vanilla item
        if type(a[3]) == "string" then a[3] = "{PLAYER} got\n{RAM:wStringBuffer}!" end
        local def = itemDef(c.item)
        if a[5] then a[5] = (def and def.keyItem) and "Get_Key_Item" or "Get_Item1" end
        return nextFn(sctx, name, a)
      elseif name == "static_battle" and mapSpecies(args[1]) then
        local a = { unpack(args, 1, table.maxn(args)) }
        a[1] = mapSpecies(args[1])
        return nextFn(sctx, name, a)
      end
    end
    return nextFn(sctx, name, args)
  end)

  -- ---- the team's shared key items ------------------------------------------------

  -- st.found keeps this player's own finds in the save, so one that never
  -- reached the server (out of reach, or the game closed first) goes again
  local function report(id)
    local st = state()
    st.got[id] = true
    if sharing() then
      st.found = st.found or {}
      st.found[id] = true
      reports[#reports + 1] = id
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

  -- every find goes through Bag.add (item balls, hidden items, gifts, gym TMs)
  local origAdd = Bag.add
  Bag.add = function(save, id, qty, data, ...)
    if granting or not sharing() or save ~= Game.save or not M.isShared(id) then
      return origAdd(save, id, qty, data, ...)
    end
    local inv = save.inventory or {}
    if (inv[id] or 0) > 0 then
      -- the team already gave it to us: the find is the team's, not a copy
      report(id)
      return true
    end
    local ok = origAdd(save, id, qty, data, ...)
    if ok then report(id) end
    return ok
  end

  -- "bag", "pc" (a full bag: the item PC takes it) or nil (no room at all)
  local function give(save, id, count)
    if isBadge(id) then
      save.inventory = save.inventory or {}
      if (save.inventory[id] or 0) < 1 then save.inventory[id] = 1 end
      return "bag"
    end
    if Bag.add(save, id, count or 1, Game.data) then return "bag" end
    if Bag.pcAdd and Bag.pcAdd(save, id, count or 1, Game.data) then return "pc" end
    return nil
  end

  -- this player's own find handed over by the mod (a gym leader's slot)
  local function receive(save, id, count)
    local where = give(save, id, count)
    -- Bag.add reported it, but a badge and the item PC skip that
    if where and M.isShared(id) and (isBadge(id) or where == "pc") then report(id) end
    if where == "pc" then note(itemName(id) .. " WAS SENT TO YOUR PC.") end
    return where
  end

  function M.applyTeam(team)
    if not (type(team) == "table" and sharing() and Game.save) then return end
    if team.rev ~= nil and team.rev == lastTeamRev then return end
    lastTeamRev = team.rev
    local st = state()
    local names = {}
    for _, id in ipairs(team.items or {}) do
      if M.isShared(id) and not st.got[id] then
        granting = true
        local where = give(Game.save, id, 1)
        granting = false
        if where then
          st.got[id] = true
          names[#names + 1] = itemName(id) .. (where == "pc" and " (IN YOUR PC)" or "")
        else
          lastTeamRev = nil      -- no room in the bag or the PC: again next sync
        end
      end
    end
    resend(team)
    if #names > 0 then
      ctx.writeOnlineSave(Game.save)
      note("YOUR TEAM FOUND " .. table.concat(names, ", ") .. "!")
    end
  end

  local function trainerId() return ctx.trainerId(Game.save) end
  local function token()
    local acc = Game.save and Game.save.onlineAccount
    return acc and acc.token or nil
  end

  local function postReports(now)
    local id = reports[1]
    if not id or now < retryAt then return end
    local res = ctx.post({ action = "team_found", trainerId = trainerId(), token = token(),
                           runId = state().run, item = id, itemName = itemName(id),
                           location = Game.overworld and Game.overworld.map
                             and Game.overworld.map.id or nil }, 3.0)
    if res == nil then retryAt = now + 3 return end   -- unreachable: try again
    table.remove(reports, 1)
    if res.success and res.team then M.applyTeam(res.team) end
  end

  -- gym leaders: the badge slot hands over whatever the seed put there, and a
  -- vanilla badge (badges not shuffled) still reaches the team
  local origRewards = OverworldState.checkVictoryRewards
  OverworldState.checkVictoryRewards = function(self, trainerClass, partyIndex, shown, ...)
    local key = tostring(trainerClass) .. "#" .. tostring(partyIndex or 1)
    local reward = victories[key]
    local save = Game.save
    if not (online() and type(reward) == "table" and reward.badge and save) then
      return origRewards(self, trainerClass, partyIndex, shown, ...)
    end
    local beaten = reward.flag and save.flags and save.flags[reward.flag]
    local content = plan and plan.gyms[key]
    local badge = reward.badge
    local had = save.inventory and save.inventory[badge]
    if content then reward.badge = nil end
    local ok, err = pcall(origRewards, self, trainerClass, partyIndex, shown, ...)
    reward.badge = badge
    if not beaten then
      if content then
        if not receive(save, content.item, content.count) then
          -- no room in the bag or the PC: owed until there is (M.tick)
          local st = state(save)
          st.owed = st.owed or {}
          table.insert(st.owed, { item = content.item, count = content.count })
          note("NO ROOM FOR " .. itemName(content.item) .. "!\fMAKE ROOM IN YOUR BAG OR PC TO GET IT.")
        end
      elseif not had and save.inventory and save.inventory[badge] and M.isShared(badge) then
        report(badge)
      end
      -- a new stretch: the trade allowance starts over
      local limit = M.tradeLimit()
      if ok and limit > 0 then
        note(("GYM LEADER BEATEN! YOU MAY TRADE %d MORE TIME%s."):format(limit, limit == 1 and "" or "S"))
      end
    end
    if not ok then error(err, 0) end
  end

  -- ---- hardcore Nuzlocke ---------------------------------------------------------

  local function hasBalls(save)
    for id, n in pairs(save and save.inventory or {}) do
      if (n or 0) > 0 and ItemEffects.isBall(id) then return true end
    end
    return false
  end

  mod.hooks:wrap("battle.style", function(nextFn, battle)
    if M.hardcore() then return "set" end
    return nextFn(battle)
  end)

  -- No EXP at the cap, and none past it below: one battle's EXP stops just
  -- short of cap + 1, so a Pokémon a level under the cap can't jump over it
  -- (src.battle.Experience.apply adds the gain to mon.exp, then levels by
  -- Growth.levelForExp on the species' growthRate and data.growth_rates).
  mod.hooks:wrap("exp.gain", function(nextFn, c)
    local gained = nextFn(c)
    if M.hardcore() and type(c) == "table" and type(c.mon) == "table" then
      local mon, cap = c.mon, M.levelCap()
      if (tonumber(mon.level) or 0) >= cap then return 0 end
      local data = Game.data
      local def = data and data.pokemon and data.pokemon[mon.species]
      local exp = tonumber(mon.exp)
      if Growth and def and exp and tonumber(gained) and cap < 100 then
        local limit = Growth.expForLevel(def.growthRate, cap + 1, data.growth_rates) - 1
        gained = math.max(0, math.min(gained, limit - exp))
      end
    end
    return gained
  end)

  -- An item the hardcore rules refuse in battle skips the target picker, so
  -- the refusal comes at once instead of after choosing a Pokémon for it.
  local function refusedInBattle(id)
    return currentBattle ~= nil and currentBattle.kind ~= "link" and M.hardcore()
      and not ItemEffects.isBall(id)
  end
  local origNeedsTarget = ItemEffects.needsTarget
  ItemEffects.needsTarget = function(id, ...)
    if refusedInBattle(id) then return false end
    return origNeedsTarget(id, ...)
  end

  mod.hooks:wrap("item.use", function(nextFn, game, battle, id, target, list, moveIndex, picker)
    if battle and M.hardcore() and battle.kind ~= "link" then
      local why
      if not ItemEffects.isBall(id) then
        why = "HARDCORE NUZLOCKE: NO ITEMS IN BATTLE!"
      elseif battleInfo and not battleInfo.catchable then
        why = battleInfo.why
      end
      if why then
        if picker and picker.close then pcall(picker.close, picker) end
        game.stack:push(TextBox.new(game, ctx.wrapText(why)))
        return
      end
    end
    return nextFn(game, battle, id, target, list, moveIndex, picker)
  end)

  -- The Safari Zone throws its balls from its own BALL/BAIT/ROCK/RUN menu,
  -- not the bag: the same refusal, said in battle, with no Safari Ball spent.
  local origSafari = BattleState.safariAction
  BattleState.safariAction = function(self, choice, ...)
    if choice == "ball" and M.hardcore() and battleInfo and not battleInfo.catchable then
      self.phase = "messages"
      self.afterQueue = "menu"
      self:say(ctx.wrapText(battleInfo.why))
      return
    end
    return origSafari(self, choice, ...)
  end

  -- the first wild Pokémon in each area (map) is the only one that counts
  mod.events:on("battle.started", function(ev)
    battleInfo = nil
    currentBattle = type(ev) == "table" and ev.battle or nil
    if not (M.hardcore() and type(ev) == "table") then return end
    if ev.kind ~= "wild" and ev.kind ~= "safari" then return end
    local save = Game.save
    if not save or (ev.battle and ev.battle.noCatch) then return end
    -- nothing counts until the player first has Poké Balls (Route 1 and 22
    -- before Oak's parcel); from then on every area's first encounter does,
    -- whatever it is, even with no ball in the bag
    local st = state(save)
    if not st.hadBalls and (hasBalls(save) or ev.kind == "safari" or next(st.areas)) then
      st.hadBalls = true
    end
    if not st.hadBalls then return end
    local area = Game.overworld and Game.overworld.map and Game.overworld.map.id or "?"
    if st.areas[area] then
      battleInfo = { catchable = false,
                     why = "NUZLOCKE: YOU ALREADY HAD YOUR ENCOUNTER HERE!" }
    else
      st.areas[area] = ev.species or true
      battleInfo = { catchable = true }
    end
  end)

  -- fainted is dead; a wiped party ends the run for the whole team
  function M.wipe()
    local st = state()
    if st.wiped then return end
    st.wiped = true
    ctx.writeOnlineSave(Game.save)
    wipeQueued = true
    note("YOUR WHOLE PARTY FAINTED!\fTHE RUN IS OVER FOR THE WHOLE TEAM.")
  end

  function M.bury(lost)
    local save = Game.save
    if not (save and type(save.party) == "table") then return end
    local st = state(save)
    -- no Pokémon yet (a new run before the starter) is not a wipe
    if st.wiped or #save.party == 0 then return end
    local alive, names = 0, {}
    for _, m in ipairs(save.party) do
      if (tonumber(m.hp) or 0) > 0 then alive = alive + 1 end
    end
    if lost or alive == 0 then return M.wipe() end
    local area = Game.overworld and Game.overworld.map and Game.overworld.map.id or "?"
    for i = #save.party, 1, -1 do
      local m = save.party[i]
      if (tonumber(m.hp) or 0) <= 0 then
        table.remove(save.party, i)
        local name = m.nickname or (Game.data.pokemon[m.species] or {}).name or m.species
        table.insert(st.graveyard, { species = m.species, name = name, level = m.level,
                                     map = area, time = os.time() })
        table.insert(names, 1, tostring(name))
      end
    end
    if #names > 0 then
      ctx.writeOnlineSave(save)
      note(table.concat(names, ", ") .. (#names > 1 and " ARE" or " IS") .. " GONE FOR GOOD...")
    end
  end

  mod.events:on("battle.ended", function(ev)
    battleInfo = nil
    currentBattle = nil
    if not M.hardcore() then return end
    local battle = type(ev) == "table" and ev.battle or nil
    -- link battles (PVP) are friendly.  The first rival fight in Oak's lab
    -- counts like any other: the game heals and carries on (no blackout),
    -- but losing it ends the run.
    if battle and battle.kind == "link" then return end
    local result = type(ev) == "table" and ev.result
    M.bury(result == "lose" or result == "whiteout" or result == "blackout")
  end)

  mod.events:on("world.blacked_out", function()
    if M.hardcore() then M.wipe() end
  end)

  -- ---- the run ------------------------------------------------------------------

  local function gameId()
    local ok, id = pcall(GameVersion.get)
    return ok and tostring(id or "gen1") or "gen1"
  end

  -- A new run: the old online save is kept as a backup and the player starts
  -- over in their bedroom with the same online character.
  function M.restart(game)
    pendingRestart = false
    local r = M.rules
    if not (r and game and game.save) then return end
    local old = game.save
    local oldRun = tonumber(type(old.g1oModes) == "table" and old.g1oModes.run) or 0
    pcall(ctx.storageWrite, ("online_save_%s_run%d_backup"):format(gameId(), oldRun), old)
    local SaveData = require("src.core.SaveData")
    local new = SaveData.newGame(game.bootConfig and game:bootConfig() or nil) or {}
    local home = ctx.home
    new.player = new.player or {}
    if type(old.player) == "table" then
      new.player.name, new.player.id = old.player.name, old.player.id
      if old.player.rival then new.player.rival = old.player.rival end
    end
    new.player.map, new.player.x, new.player.y = home.map, home.x, home.y
    new.player.facing, new.player.surfing = "down", false
    new.position = { map = home.map, x = home.x, y = home.y, facing = "down" }
    new.spawn = "SPAWN_HOME"
    new.onlineAccount = old.onlineAccount
    new.g1oModes = { run = r.runId, seed = r.seed, world = M.world }
    game.save = new
    if game.adoptSave then game:adoptSave(new) end
    lastTeamRev = nil
    battleInfo = nil
    reports = {}
    local ow = ctx.getWorld(game)
    if ow and ow.setMap then pcall(ow.setMap, ow, home.map, home.x, home.y, "down") end
    M.refresh()
    ctx.writeOnlineSave(new)
    local res = ctx.post({ action = "team_status", trainerId = trainerId() }, 3.0)
    if res and res.success then M.applyTeam(res.team) end
    note(("RUN %d BEGINS!\f%s"):format(r.runId, M.describe()))
  end

  local wipeWarned = false
  local function postWipe(now)
    if now < wipeRetryAt then return end
    local st = state()
    local res = ctx.post({ action = "run_wipe", trainerId = trainerId(), token = token(),
                           runId = st.run }, 3.0)
    if res == nil then wipeRetryAt = now + 3 return end   -- unreachable: try again
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

  -- ---- the multiworld: one world per player ----------------------------------------

  local function gameName()
    local ok, id = pcall(GameVersion.get)
    return ok and tostring(id or "?"):upper() or "?"
  end

  -- this game's item places, as the server compares them between players
  local function fingerprint(r)
    return withVanilla(function()
      return Randomizer.fingerprint(Randomizer.locations(Game.data, victories, L,
                                                         { items = r.items, badges = r.badges }))
    end)
  end

  local function join(r, account)
    local res = ctx.post({ action = "run_join", trainerId = account and account.trainerId,
                           token = account and account.token, fingerprint = fingerprint(r),
                           gameName = gameName() }, 3.0)
    if res and not res.success
        and (res.error == "UNKNOWN_TRAINER" or res.error == "INVALID_TOKEN") and account then
      return join(r, nil)   -- an account this server forgot: ask as a newcomer
    end
    return res
  end

  local function refusal(res, r)
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

  -- On CONNECT, before the offline save is touched: a full multiworld run or
  -- another game's item data turns the player away.  Returns the message.
  function M.precheck(game, serverRules)
    local r = type(serverRules) == "table" and serverRules or nil
    if not (r and r.active and r.multiworld and worlds(r) > 1 and Game.data) then return nil end
    local acc = ctx.storedAccount and ctx.storedAccount()
    local res = join(r, type(acc) == "table" and acc.token and acc or nil)
    if res and res.success then return nil end
    return refusal(res, r)
  end

  -- What the server is playing, in a few words for a text box.
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
      parts[#parts + 1] = ("MULTIWORLD (%s WORLD %s OF %d)"):format("YOU ARE",
        tostring(M.world or "?"), worlds(r))
    end
    if r.sharedKeyItems then parts[#parts + 1] = "SHARED KEY ITEMS" end
    return ("MODES: %s. RUN %s."):format(table.concat(parts, ", "), tostring(r.runId))
  end

  -- The run screen: the modes, the team's finds and this player's fallen.
  function M.infoText(save)
    local st = state(save)
    local lines = { M.describe() }
    if M.hardcore() then
      lines[#lines + 1] = ("LEVEL CAP: %d."):format(M.levelCap(save))
      local limit = M.tradeLimit()
      if limit > 0 then
        lines[#lines + 1] = (M.gymsBeaten(save) >= #BADGES and "TRADES: %d OF %d LEFT."
          or "TRADES: %d OF %d LEFT UNTIL THE NEXT GYM LEADER."):format(M.tradesLeft(save), limit)
      end
      local dead = {}
      for _, g in ipairs(st.graveyard) do dead[#dead + 1] = tostring(g.name) end
      lines[#lines + 1] = #dead > 0 and ("FALLEN: " .. table.concat(dead, ", ") .. ".")
        or "NO POKéMON LOST YET."
    end
    if M.rules and M.rules.multiworld and plan and plan.ok then
      lines[#lines + 1] = ("YOUR WORLD HOLDS %d OF THE TEAM'S %d KEY ITEMS AND BADGES.")
        :format(plan.myProgression or 0, plan.totalProgression or 0)
    end
    if sharing() then
      local got = {}
      for id in pairs(st.got) do got[#got + 1] = itemName(id) end
      table.sort(got)
      lines[#lines + 1] = #got > 0 and ("TEAM ITEMS: " .. table.concat(got, ", ") .. ".")
        or "THE TEAM HASN'T FOUND ANY KEY ITEMS YET."
    end
    return table.concat(lines, "\f")
  end

  -- ---- main.lua's calls ----------------------------------------------------------

  -- After CONNECT: the rules from /server/info (nil on a server with no modes).
  -- `fresh` = a brand-new character, whose new save starts this run.
  local refusedRun = nil      -- the run whose world was refused (M.synced asks once)
  function M.connected(game, serverRules, fresh)
    M.rules = (type(serverRules) == "table" and serverRules.active) and serverRules or nil
    M.world = nil
    lastTeamRev, reports, wipeQueued, pendingRestart = nil, {}, false, false
    if not M.rules or not game or not game.save then return end
    if M.rules.multiworld and worlds(M.rules) > 1 then
      local res = join(M.rules, game.save.onlineAccount)
      if not (res and res.success and res.world) then
        -- someone took the last world between CONNECT and now: no modes
        game.stack:push(TextBox.new(game, ctx.wrapText(refusal(res, M.rules))))
        refusedRun, M.rules = M.rules.runId, nil
        return
      end
      M.world = res.world
    end
    local st = state(game.save)
    st.world = M.world
    if fresh then
      st.run, st.seed = M.rules.runId, M.rules.seed
      ctx.writeOnlineSave(game.save)
    end
    M.refresh()
    local res = ctx.post({ action = "team_status", trainerId = trainerId() }, 3.0)
    if res and res.success then
      if res.run then M.rules = res.run end
      M.applyTeam(res.team)
    end
    -- a wipe the server never heard of (out of reach, then the game closed)
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

  -- every frame (core.update)
  function M.tick(game)
    M.refresh()
    if not (rules() and game and game.save) then return end
    local st = state(game.save)
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
    -- the overworld's own "scripted" test: a new run or a box must never
    -- land in the middle of a cutscene (the S.S. Anne sailing, an escort...)
    local ow = game.overworld
    local idle = ow and ow.player and game.stack and game.stack:top() == ow
      and not ow.player.moving and not ow.transitioning
      and not (ow.runner and ow.runner:isRunning()) and #(ow.scriptMoves or {}) == 0
      and (ow.hopLand or 0) <= 0 and not (ow.engaging or ow.emote or ow.teleportOut
        or ow.flyAnim or ow.flyArrive or ow.spinArrive or ow.holeFall or ow.holeArrive
        or ow.cutAnim or ow.shipAnim)
    if not idle then return end
    if pendingRestart and not wipeQueued then return M.restart(game) end
    if st.owed and st.owed[1] and now >= owedAt then
      owedAt = now + 2
      local c = st.owed[1]
      if receive(game.save, c.item, c.count) then
        table.remove(st.owed, 1)
        note(("%s GOT %s!"):format(tostring(game.save.player and game.save.player.name or "YOU"),
                                   itemName(c.item)))
      end
    end
    -- a poisoned Pokémon fainting on the overworld
    if M.hardcore() and not st.wiped then
      for _, m in ipairs(game.save.party or {}) do
        if (tonumber(m.hp) or 0) <= 0 then M.bury(false) break end
      end
    end
    local text = table.remove(notes, 1)
    if text then game.stack:push(TextBox.new(game, ctx.wrapText(text))) end
  end

  mod.hooks:wrap("core.update", function(nextFn, game, dt, ...)
    local res = nextFn(game, dt, ...)
    M.tick(game or Game)
    return res
  end)

  return M
end
