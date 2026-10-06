-- Real FireRed / LeafGreen on a multiworld server (randomizer = on,
-- multiworld = on, players = 2, seed = 4242; dev/run_tests.sh writes that
-- config): this client joins as world 1, BUDDY (raw HTTP) takes world 2 and
-- a third trainer is turned away.  Every badge, HM and key item the logic
-- tracks is in exactly one of the two worlds; this player's find in its own
-- world (a ball picked up for real) reaches the team, and BUDDY's find of
-- one only world 2 holds reaches this player.  Last, a new player on this
-- device is refused on CONNECT because the run is full, and stays offline.
local U = require("tests.drivers.util")

return function(game)
  local H = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_util.lua")(game, "gen3_multiworld")
  local say, check, finish, shot = H.say, H.check, H.finish, H.shot
  if not H.boot() then return finish() end
  local Modes = H.GtsUI.Modes
  local Runtime = require("src.core.game3.runtime")
  local Bag = require("src.core.game3.bag")
  local Flags = require("src.core.game3.scripting.flags")
  local Space = require("src.core.game3.scripting.space")
  local Message = require("src.ui.game3.message")
  local Choice = require("src.ui.game3.choice")
  local ITEMS = require("src.core.game3.constants.firered.items").byName

  local function have(key)
    local i = tostring(key):match("^BADGE(%d)$")
    if i then return Flags.getFlag(Space.store, nil, 0x820 + tonumber(i) - 1) and true or false end
    local id = ITEMS["ITEM_" .. tostring(key)]
    return id ~= nil and Bag.get(Runtime.getSession().bag, id) > 0
  end
  local function saidSince(p, mark)
    for i = #H.seen, (mark or 0) + 1, -1 do if H.seen[i]:find(p, 1, true) then return H.seen[i] end end
  end
  local function closeMessages()
    for _ = 1, 600 do
      if H.isText(H.top()) then H.clearTexts(1)
      elseif Choice.active then U.tap(game, "b")
      elseif Message.isOpen() or H.G3.busy() then U.tap(game, "a")
      else return end
      U.wait(3)
    end
  end

  -- ---- world 1: this player ------------------------------------------------------
  H.newOffline("OFFLINE")
  if not check(H.createPlayer("ASH", "^RED$"), "online as a new character") then return finish() end
  H.clearTexts()
  H.closeAll()
  local r = Modes.rules
  if not check(r and r.multiworld and r.players == 2 and Modes.world == 1,
      "joined the multiworld run as world " .. tostring(Modes.world) .. ": " .. Modes.describe()) then
    return finish()
  end
  check(Modes.state().world == 1, "the world is in the online save")
  local mine, theirs = Modes.plan(), Modes.planFor(2)
  check(mine and mine.ok and theirs and theirs.ok and mine.fingerprint == theirs.fingerprint,
    "both worlds build from the seed")

  -- ---- world 2: BUDDY; a third trainer is turned away -------------------------------
  local gameName = H.version:upper()
  local buddy = H.post({ action = "register_player", isNewCharacter = true, name = "BUDDY",
    spriteId = "OBJ_EVENT_GFX_BROCK", title = "TRAINER", badges = 0, pokedexCount = 0 }).account
  local res = H.post({ action = "run_join", trainerId = buddy.trainerId, token = buddy.token,
    fingerprint = mine.fingerprint, gameName = gameName })
  check(res and res.success and res.world == 2, "BUDDY joins as world 2")
  local third = H.post({ action = "register_player", isNewCharacter = true, name = "MISTY",
    spriteId = "OBJ_EVENT_GFX_BROCK", title = "TRAINER", badges = 0, pokedexCount = 0 }).account
  res = H.post({ action = "run_join", trainerId = third.trainerId, token = third.token,
    fingerprint = mine.fingerprint, gameName = gameName })
  check(res and res.error == "RUN_FULL", "a third trainer is turned away: " .. tostring(res and res.error))
  res = H.post({ action = "run_join", fingerprint = 12345, gameName = "YELLOW" })
  check(res and res.error == "WRONG_WORLD_DATA", "another game's world is refused: " .. tostring(res and res.error))

  -- ---- the split ----------------------------------------------------------------------
  local isProg = {}
  for _, id in ipairs(Modes.lib.logic.PROGRESSION) do isProg[id] = true end
  local where = {}
  for w, plan in ipairs({ mine, theirs }) do
    for key, c in pairs(plan.content) do
      if isProg[c.item] then
        where[c.item] = where[c.item] or {}
        table.insert(where[c.item], w .. ":" .. key)
      end
    end
  end
  local once, missing = true, nil
  for id in pairs(isProg) do if not where[id] or #where[id] ~= 1 then once = false; missing = id end end
  check(once, "every badge and key item is in exactly one of the two worlds" .. (missing and (" (not " .. missing .. ")") or ""))
  check(mine.myProgression + theirs.myProgression == mine.totalProgression
    and math.abs(mine.myProgression - theirs.myProgression) <= 1,
    ("split evenly: world 1 holds %d, world 2 holds %d"):format(mine.myProgression, theirs.myProgression))
  local differ = 0
  for k, v in pairs(mine.species) do if theirs.species[k] ~= v then differ = differ + 1 end end
  check(differ > 0, "each world has its own wild Pokémon (" .. differ .. " species differ)")

  -- this player's find in world 1, picked up for real, reaches the team
  local ball
  for _, loc in ipairs(mine.locations) do
    local c = mine.content[loc.key]
    if loc.kind == "ball" and loc.x and c and isProg[c.item] and not have(c.item) then ball = loc break end
  end
  if check(ball ~= nil, "world 1 has a key item in a ball: " .. tostring(ball and ball.key)) then
    local want = mine.content[ball.key].item
    check(H.talkTo(ball.map, ball.x, ball.y), "walked up to it on " .. ball.map)
    closeMessages()
    shot("world1_ball")
    check(have(want), ("it held %s, and this player has it"):format(want))
    local got = false
    for _ = 1, 120 do
      U.wait(5)
      local st = H.post({ action = "team_status", trainerId = buddy.trainerId })
      for _, id in ipairs(st and st.team and st.team.items or {}) do if id == want then got = true end end
      if got then break end
    end
    check(got, "and it reached the team (so BUDDY gets it in world 2)")
  end

  -- BUDDY's find of one only world 2 holds reaches this player
  local onlyTheirs
  for id, list in pairs(where) do
    if list[1]:sub(1, 2) == "2:" and not have(id) then onlyTheirs = id break end
  end
  if check(onlyTheirs ~= nil, "world 2 holds key items world 1 doesn't: " .. tostring(onlyTheirs)) then
    local found = H.post({ action = "team_found", trainerId = buddy.trainerId, token = buddy.token,
      runId = Modes.rules.runId, item = onlyTheirs, itemName = onlyTheirs })
    check(found and found.success, "BUDDY finds it in world 2")
    for _ = 1, 240 do
      U.wait(5)
      if have(onlyTheirs) then break end
    end
    check(have(onlyTheirs), "and this player has " .. onlyTheirs .. " too")
    H.clearTexts()
  end

  -- RUN INFO
  H.closeAll()
  H.startItem("gen1online")
  local mark = #H.seen
  if H.choose("RUN INFO") then
    H.clearTexts()
    check(saidSince("WORLD 1 OF 2", mark) and saidSince("YOUR WORLD HOLDS", mark) ~= nil,
      "RUN INFO names the world and what it holds")
  end
  H.closeAll()

  -- ---- a newcomer on this device: the run is full ---------------------------------
  H.startItem("gen1online")
  H.choose("DISCONNECT")
  H.clearTexts()
  H.closeAll()
  check(not H.online(), "disconnected")
  -- forget this device's online character, as a brand-new player would be
  local dir = love.filesystem.getSaveDirectory() .. "/mod_compat/gen1online-plus/"
  os.remove(dir .. "gen1online_online_account_" .. H.version .. ".lua")
  os.remove(dir .. "save_online_" .. H.version .. ".lua")
  mark = #H.seen
  H.startItem("gen1online")
  H.choose("^JOIN")
  H.clearTexts()
  check(saidSince("THIS RUN IS FULL", mark) ~= nil, "a new player is told the run is full")
  local s = Runtime.getSession()
  check(not H.online() and s and s.name == "OFFLINE" and Modes.plan() == nil,
    "and stays offline, with the offline save and a vanilla world")
  return finish()
end
