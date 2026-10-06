-- FireRed and LeafGreen for main.lua.
--
-- main.lua's online code was written for Gen 1's engine, and the engine's
-- FireRed adapter (src/mods/Gen3Compat.lua) already answers most of it: the
-- overworld controller (map, player, update, interact), Collision.DELTA and
-- game.data's name- and number-keyed Pokémon records.  What it can't answer,
-- this module does:
--
--   G3.game        the game main.lua passes around.  The engine hands mods
--                  the raw Game3, whose `save` is a snapshot rebuilt at every
--                  save and which has no `stack`; G3.game reads through to it
--                  except for `stack` (the mod's screens, gen3/ui.lua),
--                  `save` (a live view of the FireRed session), `data` (the
--                  adapter's view) and `overworld` (the adapter's).
--   saves          the online save is a FireRed save table (Schema
--                  toSaveTable); connecting, disconnecting and a new online
--                  character swap the live session with G3.enter, the
--                  engine's own title-screen teardown and CONTINUE.
--   Pokémon        GTS and Wonder Trade mons travel as Protocol.packMon3
--                  (everything a Gen 3 box mon has).  Party and PC (14 boxes
--                  of 30) helpers, the trade scene and trade evolutions.
--   presence       other players are drawn as field actors (the same pass as
--                  NPCs, so they sort and layer like them) with their name
--                  tags; avatars are FireRed overworld sprites.
--
-- env = { mod, requireLocal, diag, netNpcs(), netPlayerMap(), online() }
return function(env)
  local G3 = {}
  local mod = env.mod
  local Gen3Compat = require("src.mods.Gen3Compat")
  local GameVersion = require("src.core.GameVersion")

  -- engine modules by name (the sandbox's package.loaded doesn't list them;
  -- require answers from the engine's cache)
  local modCache = {}
  local function loaded(name)
    local m = modCache[name]
    if m then return m end
    local ok, res = pcall(require, name)
    if ok and type(res) == "table" then modCache[name] = res return res end
    return nil
  end
  local function g3(name)
    local ok, m = pcall(require, "src.core.game3." .. name)
    return ok and m or nil
  end

  -- the raw Game3: the last one a hook handed us, else the mod's own
  function G3.raw() return G3._raw or (mod and mod.game) or nil end
  local function session()
    local R = loaded("src.core.game3.runtime")
    local s = R and R.getSession and R.getSession()
    if s then return s end
    local raw = G3.raw()
    return raw and raw.session or nil
  end
  G3.session = session

  G3.version = tostring(GameVersion.get and GameVersion.get() or "firered")
  G3.isLeafGreen = G3.version == "leafgreen"

  local UI = env.requireLocal("gen3/ui.lua")({ session = session })
  G3.UI = UI
  G3.Font, G3.Menu, G3.TextBox, G3.wrapText = UI.Font, UI.Menu, UI.TextBox, UI.wrapText
  G3.nameEntry = UI.nameEntry

  -- -------------------------------------------------------- save view

  local function modData()
    local s = session()
    if not s then return {} end
    if type(s.modData) ~= "table" then s.modData = {} end
    local d = s.modData["gen1online-plus"]
    if type(d) ~= "table" then d = {}; s.modData["gen1online-plus"] = d end
    return d
  end
  G3.modData = modData

  local function player() return loaded("src.core.game3.player") end
  local function currentMap()
    local M = loaded("src.core.game3.map")
    local s = session()
    return (M and M.current) or (s and s.map)
  end
  G3.currentMap = currentMap

  local PlayerView = setmetatable({}, {
    __index = function(_, k)
      local s = session()
      if not s then return nil end
      if k == "name" then return s.name end
      if k == "id" then
        local acc = modData().onlineAccount
        return (acc and acc.trainerId) or modData().trainerId or s.trainerId
      end
      if k == "gender" then return s.gender end
      if k == "money" then return s.money end
      if k == "map" then return Gen3Compat.gen1MapId(currentMap()) end
      local P = player()
      if k == "x" then return P and P.cellX or s.x end
      if k == "y" then return P and P.cellY or s.y end
      if k == "facing" then return P and P.facing or s.facing end
      return nil
    end,
    __newindex = function(_, k, v)
      local s = session()
      if not s then return end
      if k == "name" then s.name = v
      elseif k == "id" then modData().trainerId = v end
      -- the position belongs to the field: warps move the player
    end,
  })

  local function dex()
    local s = session()
    if not s then return {} end
    s.dex = s.dex or {}
    s.dex.seen = s.dex.seen or {}
    s.dex.owned = s.dex.owned or {}
    s.dex.caught = s.dex.caught or s.dex.owned
    return s.dex
  end

  local MODDATA_KEYS = { onlineAccount = true, blackoutCount = true, g1oModes = true }

  G3.save = setmetatable({}, {
    __index = function(_, k)
      local s = session()
      if not s then return nil end
      if k == "party" then return s.party end
      if k == "player" then return PlayerView end
      if k == "pokedex" then local d = dex(); return { seen = d.seen, owned = d.owned, caught = d.owned } end
      if MODDATA_KEYS[k] then return modData()[k] end
      if k == "gen3" then return s end
      if k == "boxes" or k == "position" or k == "events" or k == "badges" then return nil end
      return s[k]
    end,
    __newindex = function(_, k, v)
      local s = session()
      if not s then return end
      if MODDATA_KEYS[k] then modData()[k] = v return end
      if k == "party" or k == "player" or k == "pokedex" then return end
      s[k] = v
    end,
  })

  -- ------------------------------------------------------------ game

  local Compat = require("src.core.Game")    -- the adapter's Game facade
  G3.game = setmetatable({ isG3 = true }, {
    __index = function(t, k)
      if k == "stack" then return UI.Stack end
      if k == "save" then return session() and G3.save or nil end
      local raw = G3.raw()
      if k == "raw" then return raw end
      if not raw then return nil end
      if k == "data" then return Gen3Compat.dataView(raw.data) end
      if k == "overworld" then return Compat.overworld end
      if k == "world" then return nil end
      local v = raw[k]
      if type(v) == "function" then
        return function(first, ...)
          if first == t then return v(raw, ...) end
          return v(first, ...)
        end
      end
      return v
    end,
    __newindex = function(_, k, v)
      -- the save is swapped with G3.enter; the field owns the overworld
      if k == "save" or k == "overworld" or k == "world" or k == "stack" then return end
      local raw = G3.raw()
      if raw then raw[k] = v end
    end,
  })

  -- what a hook hands main.lua, as main.lua's game
  function G3.wrap(game)
    if game == G3.game then return game end
    if type(game) == "table" and game.generation == 3 then G3._raw = game end
    return G3.game
  end

  -- busy: a FireRed screen, text, script, battle or warp is up
  function G3.busy()
    if UI.Stack:size() > 0 then return true end
    local Hud = loaded("src.ui.game3.hud")
    if Hud and Hud.busy and Hud.busy() then return true end
    local busy = Gen3Compat.worldBusy()
    return busy and true or false
  end

  -- ---------------------------------------------------------- counts

  function G3.badgeCount()
    local n = 0
    for i = 1, 8 do
      if Gen3Compat.getFlag(string.format("FLAG_BADGE%02d_GET", i)) then n = n + 1 end
    end
    return n
  end

  function G3.dexCount()
    local n = 0
    for _, owned in pairs(dex().owned or {}) do if owned then n = n + 1 end end
    return n
  end

  -- ---------------------------------------------------------- avatars

  local GFX = require("src.core.game3.constants.firered.event_objects").byName
  G3.DEFAULT_AVATAR = "OBJ_EVENT_GFX_RED_NORMAL"
  G3.AVATARS = {
    { id = "OBJ_EVENT_GFX_RED_NORMAL", label = "RED" },
    { id = "OBJ_EVENT_GFX_GREEN_NORMAL", label = "LEAF" },
    { id = "OBJ_EVENT_GFX_BLUE", label = "BLUE / RIVAL" },
    { id = "OBJ_EVENT_GFX_PROF_OAK", label = "PROF. OAK" },
    { id = "OBJ_EVENT_GFX_BILL", label = "BILL" },
    { id = "OBJ_EVENT_GFX_BROCK", label = "BROCK" },
    { id = "OBJ_EVENT_GFX_MISTY", label = "MISTY" },
    { id = "OBJ_EVENT_GFX_LT_SURGE", label = "LT. SURGE" },
    { id = "OBJ_EVENT_GFX_ERIKA", label = "ERIKA" },
    { id = "OBJ_EVENT_GFX_KOGA", label = "KOGA" },
    { id = "OBJ_EVENT_GFX_SABRINA", label = "SABRINA" },
    { id = "OBJ_EVENT_GFX_BLAINE", label = "BLAINE" },
    { id = "OBJ_EVENT_GFX_GIOVANNI", label = "GIOVANNI" },
    { id = "OBJ_EVENT_GFX_LORELEI", label = "LORELEI" },
    { id = "OBJ_EVENT_GFX_BRUNO", label = "BRUNO" },
    { id = "OBJ_EVENT_GFX_AGATHA", label = "AGATHA" },
    { id = "OBJ_EVENT_GFX_LANCE", label = "LANCE" },
    { id = "OBJ_EVENT_GFX_DAISY", label = "DAISY" },
    { id = "OBJ_EVENT_GFX_COOLTRAINER_M", label = "COOLTRAINER M" },
    { id = "OBJ_EVENT_GFX_COOLTRAINER_F", label = "COOLTRAINER F" },
    { id = "OBJ_EVENT_GFX_YOUNGSTER", label = "YOUNGSTER" },
    { id = "OBJ_EVENT_GFX_BUG_CATCHER", label = "BUG CATCHER" },
    { id = "OBJ_EVENT_GFX_LASS", label = "LASS" },
    { id = "OBJ_EVENT_GFX_BEAUTY", label = "BEAUTY" },
    { id = "OBJ_EVENT_GFX_CAMPER", label = "CAMPER" },
    { id = "OBJ_EVENT_GFX_PICNICKER", label = "PICNICKER" },
    { id = "OBJ_EVENT_GFX_HIKER", label = "HIKER" },
    { id = "OBJ_EVENT_GFX_BIKER", label = "BIKER" },
    { id = "OBJ_EVENT_GFX_SAILOR", label = "SAILOR" },
    { id = "OBJ_EVENT_GFX_ROCKER", label = "ROCKER" },
    { id = "OBJ_EVENT_GFX_FISHER", label = "FISHER" },
    { id = "OBJ_EVENT_GFX_SCIENTIST", label = "SCIENTIST" },
    { id = "OBJ_EVENT_GFX_POKE_MANIAC", label = "POKEMANIAC" },
    { id = "OBJ_EVENT_GFX_CHANNELER", label = "CHANNELER" },
    { id = "OBJ_EVENT_GFX_BLACK_BELT", label = "BLACK BELT" },
    { id = "OBJ_EVENT_GFX_GENTLEMAN", label = "GENTLEMAN" },
    { id = "OBJ_EVENT_GFX_ROCKET_M", label = "TEAM ROCKET" },
    { id = "OBJ_EVENT_GFX_ROCKET_F", label = "ROCKET GIRL" },
    { id = "OBJ_EVENT_GFX_GBA_KID", label = "GBA KID" },
    { id = "OBJ_EVENT_GFX_MR_FUJI", label = "MR. FUJI" },
  }

  -- the player a new online character plays: a girl for the female avatars
  local FEMALE = { OBJ_EVENT_GFX_GREEN_NORMAL = true, OBJ_EVENT_GFX_MISTY = true,
    OBJ_EVENT_GFX_ERIKA = true, OBJ_EVENT_GFX_SABRINA = true, OBJ_EVENT_GFX_LORELEI = true,
    OBJ_EVENT_GFX_AGATHA = true, OBJ_EVENT_GFX_DAISY = true, OBJ_EVENT_GFX_COOLTRAINER_F = true,
    OBJ_EVENT_GFX_LASS = true, OBJ_EVENT_GFX_BEAUTY = true, OBJ_EVENT_GFX_PICNICKER = true,
    OBJ_EVENT_GFX_ROCKET_F = true }
  function G3.genderOf(spriteId) return FEMALE[spriteId] and 1 or 0 end

  -- a sync's spriteId (and riding state) as a FireRed graphics id
  function G3.graphicsIdFor(spriteId, state, gender)
    local female = gender == 1 or gender == "female"
    if state == "BIKE" then return GFX[female and "OBJ_EVENT_GFX_GREEN_BIKE" or "OBJ_EVENT_GFX_RED_BIKE"] end
    if state == "SURF" then return GFX[female and "OBJ_EVENT_GFX_GREEN_SURF" or "OBJ_EVENT_GFX_RED_SURF"] end
    local id = type(spriteId) == "string" and GFX[spriteId]
    if id then return id end
    return GFX[female and "OBJ_EVENT_GFX_GREEN_NORMAL" or G3.DEFAULT_AVATAR]
  end

  -- this player's own look online: the avatar on foot; bike, surf, fishing
  -- and the field-move pose keep the game's own sheets
  G3.avatar = nil
  local OwSprites = g3("ow_sprites")
  if OwSprites and OwSprites.playerGraphicsId then
    local orig = OwSprites.playerGraphicsId
    OwSprites.playerGraphicsId = function(game, p, ...)
      local id = orig(game, p, ...)
      if G3.avatar and env.online() then
        local P = p or player()
        if OwSprites.avatarState(P) == "NORMAL" and GFX[G3.avatar] then return GFX[G3.avatar] end
      end
      return id
    end
  end
  function G3.applyAvatar(spriteId)
    local s = session()
    local default = (s and (s.gender == 1 or s.gender == "female")) and "OBJ_EVENT_GFX_GREEN_NORMAL"
      or G3.DEFAULT_AVATAR
    G3.avatar = (spriteId and spriteId ~= default and GFX[spriteId]) and spriteId or nil
  end

  -- the extra presence fields a FireRed client sends
  function G3.presence(payload)
    local P = player()
    local s = session()
    if not (P and payload) then return payload end
    local state = "NORMAL"
    if P.surfing or P.dismounting then state = "SURF" elseif P.biking then state = "BIKE" end
    payload.state = state
    payload.gender = s and ((s.gender == 1 or s.gender == "female") and 1 or 0) or 0
    payload.elevation = P.elevation or 3
    return payload
  end

  -- ------------------------------------------- other players on the map

  local FrlgFont = require("src.ui.game3.frlg_font")

  local TAG_OPTS = { small = true, maxWidth = 120, colors = FrlgFont.COLOR.NORMAL }
  local tagWidths = {}
  local function tagWidth(name)
    local w = tagWidths[name]
    if not w then w = FrlgFont.measure(name, TAG_OPTS); tagWidths[name] = w end
    return w
  end
  -- lift = how many tag rows up (tags of trainers side by side stack)
  local function drawTag(name, px, py, camX, camY, lift)
    local opts = TAG_OPTS
    local w = tagWidth(name)
    local x = math.floor(px + 8 - camX - w / 2)
    local y = math.floor(py - 14 - camY - (lift or 0) * 12)
    local G = love.graphics
    G.setColor(1, 1, 1, 0.8)
    G.rectangle("fill", x - 2, y + 1, w + 4, 11)
    G.setColor(1, 1, 1, 1)
    FrlgFont.draw(name, x, y - 1, opts)
  end

  -- remote players (and every tag) join the field's actor list each frame
  local tagPool = {}
  function G3.addActors(actors)
    if not env.online() then return end
    local mapId = Gen3Compat.gen1MapId(currentMap())
    local netNpcs, meta = env.netNpcs(), env.netPlayerMap()
    local n = 0
    local placed = {}
    local function tag(name, px, py)
      name = UI.clean(name):upper()
      -- the first free row over this trainer, so neighbours' tags don't overlap
      local w = tagWidth(name)
      local x0, x1 = px + 8 - w / 2, px + 8 + w / 2
      local lift = 0
      local moved = true
      while moved and lift < 4 do
        moved = false
        for _, r in ipairs(placed) do
          if r.lift == lift and math.abs(r.py - py) < 12 and x0 < r.x1 + 2 and r.x0 < x1 + 2 then
            lift, moved = lift + 1, true
            break
          end
        end
      end
      placed[#placed + 1] = { x0 = x0, x1 = x1, py = py, lift = lift }
      n = n + 1
      local a = tagPool[n] or {}
      tagPool[n] = a
      a.kind, a.i, a.oamPriority, a.elevation = "g1o_tag", 95000 + n, 0, 15
      a.x, a.y, a.sortY = px, py, py + 64
      a.name, a.lift = name, lift
      a.draw = function(self, camX, camY) drawTag(self.name, self.x, self.y, camX, camY, self.lift) end
      actors[#actors + 1] = a
    end
    for tid, pNpc in pairs(netNpcs) do
      local data = meta[tid] or {}
      if pNpc.px and pNpc.py and tostring(data.map or ""):upper() == tostring(mapId or ""):upper() then
        n = n + 1
        local a = tagPool[n] or {}
        tagPool[n] = a
        a.kind, a.i, a.oamPriority = "npc", 90000 + n, nil
        a.draw, a.obj, a.eventObject = nil, nil, nil
        a.elevation = tonumber(data.elevation) or 3
        a.x, a.y, a.sortY = pNpc.px, pNpc.py, pNpc.py
        a.facing = pNpc.facing or "down"
        a.walkPhase = pNpc:walkPhase()
        a.stepFlip = pNpc.stepFlip and true or false
        a.graphicsId = G3.graphicsIdFor(data.spriteId, data.state, data.gender)
        actors[#actors + 1] = a
        tag(data.name or pNpc.name or "TRAINER", pNpc.px, pNpc.py)
      end
    end
    local P = player()
    if P and P.isVisible and P.isVisible() then
      local acc = modData().onlineAccount
      local s = session()
      tag((acc and acc.name) or (s and s.name) or "YOU", P.px or 0, P.py or 0)
    end
  end

  local FieldEffects = g3("field_effects")
  if FieldEffects and FieldEffects.collectActors then
    local origCollect = FieldEffects.collectActors
    FieldEffects.collectActors = function(actors)
      local res = origCollect(actors)
      local ok, err = pcall(G3.addActors, actors)
      if not ok and not G3._actorErr then G3._actorErr = true; print("[Gen1Online+] remote actors: " .. tostring(err)) end
      return res
    end
  end

  -- ------------------------------------------------------ Pokémon

  local Protocol = require("src.link.Protocol")
  local function pokemon() return require("src.core.game3.pokemon") end
  local function storage() return require("src.core.game3.storage") end

  function G3.packMon(mon)
    local packed = Protocol.packMon3(mon)
    -- no nickname travels as none, so the wire reads like Gen 1's
    if packed.nickname == "" then packed.nickname = nil end
    -- the name beside the number, for the server's history and old clients
    packed.speciesName = G3.speciesName(packed.species)
    return packed
  end
  -- a mon off the wire, or nil (another generation's, or damaged)
  function G3.unpackMon(packed)
    if type(packed) ~= "table" then return nil end
    local ok, mon = pcall(Protocol.unpackMon3, nil, packed, { strict = false })
    return ok and mon or nil
  end

  function G3.speciesName(species)
    local P = pokemon()
    local sp = tonumber(species)
    local ok, name = pcall(P.name, sp)
    return (ok and name) or tostring(species or "?")
  end
  function G3.monName(mon)
    if type(mon) ~= "table" then return "?" end
    if mon.isEgg then return "EGG" end
    local nick = mon.nickname
    if type(nick) == "string" and nick ~= "" then return nick end
    return G3.speciesName(mon.species)
  end

  -- every species the game has, by name (1..386 in national order)
  function G3.allSpecies()
    local P = pokemon()
    local out = {}
    for nat = 1, 386 do
      local ok, sp = pcall(P.speciesFromNational, nat)
      if ok and sp then
        out[#out + 1] = { id = sp, name = G3.speciesName(sp), dex = nat }
      end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end

  -- held MAIL keeps its letter in the party (src/core/game3/mail.lua), so a
  -- mon holding it can't leave, the way the PC refuses it
  local function holdsMail(mon)
    local item = tonumber(mon.heldItem or mon.item) or 0
    return item >= 121 and item <= 132
  end
  local function tradeable(mon)
    return type(mon) == "table" and not mon.isEgg and not holdsMail(mon)
  end

  local function label(mon, where)
    return string.format("%s LV%d (%s)", G3.monName(mon):sub(1, 10), mon.level or 1, where)
  end

  -- party then PC, as main.lua's GTS menus list them
  function G3.allMons()
    local s = session()
    local list = {}
    if not s then return list end
    for i, mon in ipairs(s.party or {}) do
      if tradeable(mon) then
        list[#list + 1] = { source = "party", slotIndex = i, mon = mon, label = label(mon, "PARTY") }
      end
    end
    local st = storage().ensure(s)
    for b = 1, storage().TOTAL_BOXES_COUNT do
      local box = st.boxes[b]
      for slot = 1, storage().IN_BOX_COUNT do
        local mon = box and box.mons[slot]
        if tradeable(mon) then
          list[#list + 1] = { source = "box", boxIndex = b, slotIndex = slot, mon = mon,
            label = label(mon, "BOX " .. b) }
        end
      end
    end
    return list
  end

  function G3.removeMon(item)
    local s = session()
    if not (s and item) then return nil end
    if item.source == "party" then
      local mon = s.party[item.slotIndex]
      if mon ~= item.mon then return nil end
      table.remove(s.party, item.slotIndex)
      return mon
    end
    local box = storage().ensure(s).boxes[item.boxIndex]
    local mon = box and box.mons[item.slotIndex]
    if not mon or mon ~= item.mon then return nil end
    box.mons[item.slotIndex] = nil
    return mon
  end

  function G3.hasRoom()
    local s = session()
    if not s then return false end
    if #(s.party or {}) < 6 then return true end
    return storage().findOpenSlot(storage().ensure(s)) ~= nil
  end

  -- "party", slot | "box", boxId | nil (no room anywhere)
  function G3.addMon(mon)
    local s = session()
    if not (s and mon) then return nil end
    s.party = s.party or {}
    if #s.party < 6 then
      s.party[#s.party + 1] = mon
      return "party", #s.party
    end
    local ok, b = storage().sendMonToPC(s, mon)
    if ok then return "box", b end
    return nil
  end

  function G3.restoreMon(item, mon)
    local s = session()
    if not (s and item and mon) then return end
    if item.source == "box" then
      local box = storage().ensure(s).boxes[item.boxIndex]
      if box and box.mons[item.slotIndex] == nil then
        box.mons[item.slotIndex] = mon
        return
      end
    end
    if item.source == "party" and #s.party < 6 then
      table.insert(s.party, math.min(item.slotIndex or (#s.party + 1), #s.party + 1), mon)
      return
    end
    G3.addMon(mon)
  end

  local function markDex(species)
    local d = dex()
    local sp = tonumber(species)
    if not sp then return end
    d.seen[sp], d.owned[sp] = true, true
    if d.caught then d.caught[sp] = true end
  end
  G3.markDex = markDex

  -- A GTS or Wonder Trade arrival: into the party or PC, the trade scene,
  -- then a trade evolution, the way the cartridge plays an in-game trade.
  -- saveNow() runs as soon as the mon is in (the server already let go of
  -- it); done(receivedMon) after the scene.  Returns false (and says why)
  -- when the mon can't be read.
  function G3.receive(game, sentMon, packed, otName, saveNow, done)
    local mon = G3.unpackMon(packed)
    if not mon then return false end
    local where = G3.addMon(mon)
    if not where then return false end
    markDex(mon.species)
    if saveNow then pcall(saveNow) end
    local function evolve()
      local Evolution = g3("evolution")
      local okT, target = pcall(function() return Evolution and Evolution.tradeTarget(mon, session()) end)
      local okS, Scene = pcall(require, "src.ui.game3.evolution_scene")
      if okT and target and okS and Scene and Scene.start then
        Scene.start(mon, target, { canStop = false, session = session(), via = "trade",
          onDone = function()
            markDex(mon.species)
            UI.Stack:ensureLayer()
            if done then done(mon) end
          end })
        return
      end
      UI.Stack:ensureLayer()
      if done then done(mon) end
    end
    local TradeScene = g3("trade_scene")
    -- a claim has no outgoing mon to show (the listing left long ago)
    local sent = type(sentMon) == "table" and tonumber(sentMon.species) and sentMon or nil
    if TradeScene and TradeScene.play and sent then
      local ok = pcall(TradeScene.play, sent, mon, function() evolve() end,
        { otName = otName, uiDriven = true })
      if ok then return true end
    end
    evolve()
    return true
  end

  -- -------------------------------------------------- the save swap

  local Schema = require("src.core.game3.save_schema_firered")
  local Serializer = require("src.core.SaveSerializer")

  local function deepCopy(t)
    local ok, copy = pcall(function() return Serializer.decode(Serializer.encode(t)) end)
    return ok and copy or nil
  end

  -- the live session as a FireRed save table (what SAVE writes)
  function G3.snapshot()
    local s = session()
    if not s then return nil end
    pcall(function() require("src.core.game3.scripting.space").persistSession(nil, G3.raw()) end)
    local P = player()
    if P and not P.moving then s.x, s.y, s.facing = P.cellX, P.cellY, P.facing end
    local ok, save = pcall(Schema.toSaveTable, s)
    if not ok then env.diag("snapshot failed: %s", tostring(save)) return nil end
    return deepCopy(save)
  end

  -- a fresh FireRed game for a new online character, in the bedroom
  function G3.newGameSave(name, gender, trainerId)
    local MapIds = require("src.core.game3.map_ids")
    local s = Schema.newGame({ name = name, gender = gender or 0, start = MapIds.newGameStart() })
    s.modData = s.modData or {}
    s.modData["gen1online-plus"] = { trainerId = trainerId, fresh = true }
    return Schema.toSaveTable(s)
  end

  -- Swap the live game to `save` (a FireRed save table): the engine's own
  -- teardown (the one QUIT runs, which also clears every FireRed screen),
  -- then CONTINUE on the new session.  A fresh character comes in the way a
  -- new game does.
  G3.switching = false
  function G3.enter(save)
    local raw = G3.raw()
    if not (raw and type(save) == "table") then return false end
    local copy = deepCopy(save) or save
    local fresh = type(copy.modData) == "table" and type(copy.modData["gen1online-plus"]) == "table"
      and copy.modData["gen1online-plus"].fresh
    local states = UI.Stack.states
    G3.switching = true
    local ok, err = pcall(function()
      raw:returnToTitle({ skipIntro = true })
      local s = Schema.fromSaveTable(copy)
      if fresh then s.modData["gen1online-plus"].fresh = nil end
      raw:adoptSave(s, false)
      raw.sessionStartedAt = os.time()
      raw:_enterField(s, fresh and "new_game" or "continue")
    end)
    G3.switching = false
    UI.Stack.states = states
    UI.Stack:ensureLayer()
    if not ok then env.diag("session swap failed: %s", tostring(err)) end
    return ok
  end

  -- -------------------------------------------------------- warps

  function G3.warpTo(mapId, x, y, facing)
    local raw = G3.raw()
    local W = g3("warp")
    local id = Gen3Compat.gen3MapId(mapId)
    if not (raw and W and id and x and y) then return false end
    local ok, res = pcall(W.request, nil, raw, id, x, y, facing or "down", {})
    return ok and res ~= false
  end

  -- ------------------------------------------------- the Pokémon Center PC

  -- GTS joins the PC's first menu (above LOG OFF), as on Gen 1 and Crystal
  function G3.installPc(openGts)
    local ok, PcMenu = pcall(require, "src.ui.game3.pc_menu")
    if not (ok and type(PcMenu) == "table" and PcMenu._rootEntries) then return end
    local origRoot = PcMenu._rootEntries
    PcMenu._rootEntries = function(...)
      local rows = origRoot(...)
      if PcMenu._select or type(rows) ~= "table" then return rows end
      for _, row in ipairs(rows) do if row.id == "gts" then return rows end end
      table.insert(rows, math.max(1, #rows), { id = "gts", label = "GTS" })
      return rows
    end
    local origInput = PcMenu.handleInput
    PcMenu.handleInput = function(input, ...)
      if PcMenu.open and PcMenu.mode == "root" and not PcMenu._select
          and input and input:wasPressed("a") then
        local row = PcMenu._rootEntries()[PcMenu.cursor]
        if row and row.id == "gts" then
          UI.se("SE_SELECT")
          openGts()
          return
        end
      end
      return origInput(input, ...)
    end
  end

  -- ----------------------------------------------------- the engine

  -- Game3: QUIT logs out first (not during a session swap), and the game
  -- runs at 1x while connected, like Gen 1 and Crystal
  function G3.installGame(onQuit)
    local okG, Game3 = pcall(require, "src.core.Game3")
    if not (okG and type(Game3) == "table") then return end
    local origTitle = Game3.returnToTitle
    Game3.returnToTitle = function(self, ...)
      if not G3.switching then
        G3._raw = self
        pcall(onQuit, G3.game)
        UI.Stack.states = {}
      end
      return origTitle(self, ...)
    end
    local origLocked = Game3.speedLocked
    Game3.speedLocked = function(self, ...)
      if env.online() then return true, "online" end
      return origLocked(self, ...)
    end
  end

  -- ------------------------------------------- PVP and link trades

  -- gen3/link.lua, built on first use: env.send (the async battle-message
  -- engine) and env.post are filled in by main.lua once they exist
  local Link3
  local function link3()
    if not Link3 then
      Link3 = env.requireLocal("gen3/link.lua")({ G3 = G3, raw = G3.raw,
        send = function(...) return env.send(...) end,
        post = function(...) return env.post(...) end })
    end
    return Link3
  end
  G3.link = link3

  local function myId() return tostring(G3.save.player.id) end

  -- onDone(result, why): "win" | "lose" | "draw", or nil when the link never
  -- came up ("no_answer", "cancelled", or the game's own refusal)
  function G3.startPvp(game, peerName, peerId, isHost, roomId, onDone)
    return link3().start("battle", { game = game, myId = myId(), theirId = peerId, roomId = roomId,
      isHost = isHost, peerName = peerName, onDone = onDone })
  end
  function G3.startTrade(game, peerName, peerId, isHost, roomId, onDone)
    return link3().start("trade", { game = game, myId = myId(), theirId = peerId, roomId = roomId,
      isHost = isHost, peerName = peerName, onDone = onDone })
  end
  function G3.tick(dt)
    if Link3 then Link3.tick(dt) end
  end

  return G3
end
