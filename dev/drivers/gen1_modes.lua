-- Real Yellow boot against a Gen 1 server with every game mode on
-- (server_config: nuzlocke = hardcore, randomizer = on, seed = 4242):
-- connect as a new character, then check the co-op randomizer (wild species,
-- an item ball, an NPC gift row, a gym leader's badge slot), the team's
-- shared key items in both directions (this player's find reaches BUDDY, a
-- raw-HTTP teammate; BUDDY's find reaches this player), the hardcore Nuzlocke
-- rules (SET style, level cap, no battle items, first encounter per area,
-- dupes clause, fainted Pokemon gone), and both ways a run ends: this
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
  local plan = Modes.plan()
  if not check(plan and plan.ok and plan.species, "the seed built a finishable world") then
    return finish()
  end

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
  ModRuntime.emit("battle.started", { battle = wild, kind = "wild", species = "PIKACHU", level = 3 })
  check(useItem("POKE_BALL", wild) and said("DUPES"), "an owned species is a dupe")
  check(Modes.state(game.save).areas.ROUTE_2 == nil, "and doesn't use Route 2 up")
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

  -- ---- offline, the vanilla world is back ----------------------------------------------------
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

  return finish()
end
