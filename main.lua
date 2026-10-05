  local mod = ...  -- the mod api (vararg from the loader, like PotatoVoxel's entry)
  local currentMod = nil
  print("[Gen1Online+] Initializing Gen1Online+ Asynchronous Threaded 60FPS Multiplayer Mod...")

  -- Resolved before anything else: request headers, the default avatar and
  -- the save paths below all read these.
  local MOD_VERSION = "0.5.1"
  local isGen2 = false
  if mod and mod.generation then
    isGen2 = (mod.generation == 2)
  else
    local okGv, GvMod = pcall(require, "src.core.GameVersion")
    if okGv and GvMod and GvMod.generation then isGen2 = (GvMod.generation() == 2) end
  end

  -- Diagnostics go to the engine log, and only in developer mode.
  local function diag(fmt, ...)
    if not (mod and mod.developer and mod.log) then return end
    pcall(mod.log.info, mod.log, fmt, ...)
  end

  -- (helpers below sit in do-blocks: this chunk is at Lua's 200-local cap)
  local requireLocal, modFileExists
  do
    -- The mod's own Lua files, compiled into this sandbox through mod:read
    -- and cached the way require caches.  require("mods.gen1online-plus.x")
    -- only resolved when the install folder was named exactly
    -- gen1online-plus, and it ran the file outside the sandbox.
    local localModules = {}
    requireLocal = function(relative)
      local cached = localModules[relative]
      if cached ~= nil then return cached end
      local source = mod and mod.read and mod:read(relative)
      if type(source) ~= "string" then error("missing mod file " .. tostring(relative), 2) end
      local chunk, err = (loadstring or load)(source, "@" .. tostring(mod.path or "mod") .. "/" .. relative)
      if not chunk then error(err, 2) end
      local result = chunk()
      localModules[relative] = result
      return result
    end

    -- Whether a file ships inside this mod (mod:info, cached: the follower
    -- and wild-spawn code asks every frame).
    local modFileCache = {}
    modFileExists = function(relative)
      local hit = modFileCache[relative]
      if hit ~= nil then return hit end
      local ok, info = pcall(function() return mod and mod.info and mod:info(relative) end)
      hit = (ok and type(info) == "table" and info.type == "file") and true or false
      modFileCache[relative] = hit
      return hit
    end
  end

  -- Installation-wide persistence for the online character and client
  -- settings.  mod.storage is playthrough-scoped (every call takes the game
  -- whose save picks the scope), but the online character follows the player
  -- across playthroughs, so these stay in this mod's private file store, where
  -- save_online_crystal.lua has always lived.
  local storageRead, storageWrite, storageRemove
  do
    local SaveSerializer = require("src.core.SaveSerializer")
    -- The online character belongs to one game.  Crystal keeps the names it
    -- has always used; a Gen 1 game gets its own pair (save_online_red.lua and
    -- gen1online_online_account_red.lua), so no game loads another's progress.
    local PERSIST_FILES = { online_save = "save_online_crystal.lua" }
    do
      local okGv, Gv = pcall(require, "src.core.GameVersion")
      local gameId = okGv and Gv and Gv.get and tostring(Gv.get() or "") or ""
      if not isGen2 and gameId:match("^%w+$") then
        PERSIST_FILES.online_save = "save_online_" .. gameId .. ".lua"
        PERSIST_FILES.online_account = "gen1online_online_account_" .. gameId .. ".lua"
      end
    end
    local function persistFs()
      local fs = love and love.filesystem
      if fs and fs.read and fs.write and fs.getInfo then return fs end
      return nil
    end
    local function persistPath(key)
      key = tostring(key or ""):gsub("%.lua.*$", ""):gsub("[^%w_%-]", "_")
      return PERSIST_FILES[key] or ("gen1online_" .. key .. ".lua")
    end
    storageRead = function(key)
      local fs = persistFs()
      if not fs then return nil end
      local path = persistPath(key)
      local ok, value = pcall(function()
        if not fs.getInfo(path) then return nil end
        local body = fs.read(path)
        return type(body) == "string" and SaveSerializer.decode(body) or nil
      end)
      if not ok then return nil end
      if type(value) == "table" and value.__value ~= nil then return value.__value end
      return value
    end
    storageWrite = function(key, value)
      local fs = persistFs()
      if not fs then return false end
      if type(value) ~= "table" then value = { __value = value } end
      local ok, written = pcall(function()
        return fs.write(persistPath(key), SaveSerializer.encode(value))
      end)
      return ok and written ~= false
    end
    storageRemove = function(key)
      local fs = persistFs()
      if fs and fs.remove then pcall(fs.remove, persistPath(key)) end
    end
  end

  local function loadLocal(mod, relative)
    local source = nil
    if mod and mod.read then
      pcall(function() source = mod:read(relative) end)
    end
    if not source then
      print("[Gen1Online] Warning: Could not read " .. tostring(relative))
      return function() return {} end
    end
    local loadFn = loadstring or load
    local chunk, err = loadFn(source, "@" .. (mod.path or "mod") .. "/" .. tostring(relative))
    if not chunk then
      print("[Gen1Online] Warning: Failed to parse " .. tostring(relative) .. ": " .. tostring(err))
      return function() return {} end
    end
    local ok, res = pcall(chunk)
    if not ok then
      print("[Gen1Online] Warning: Error executing " .. tostring(relative) .. ": " .. tostring(res))
      return function() return {} end
    end
    if type(res) == "function" then
      return res
    end
    return function() return type(res) == "table" and res or {} end
  end

  -- Quests/NPCs are loaded from their modules later in the factory (see the
  -- module-loading section near the bottom); the empty defaults keep the
  -- overworld hooks from nil-calling anything if a module fails to load.
  local Quests = {}
  local NPCs = {}
  local GtsUI = {}


  local Game, Input, OverworldState, BattleState = require("src.core.Game"), require("src.core.Input"), require("src.world.OverworldController"), require("src.battle.BattleState")
  local LinkBattle, Protocol, Party, Boxes = require("src.link.LinkBattle"), require("src.link.Protocol"), require("src.pokemon.Party"), require("src.pokemon.Boxes")
  local Collision, Font, Menu, TextBox = require("src.world.Collision"), require("src.render.Font"), require("src.ui.Menu"), require("src.render.TextBox")
  local Net, CodeEntry, NPC, SpriteRenderer = require("src.link.Net"), require("src.link.CodeEntry"), require("src.world.NPC"), require("src.render.SpriteRenderer")
  local Pokemon, Json = require("src.pokemon.Pokemon"), require("src.link.Json")
  local Strings = pcall(require, "src.core.Strings") and require("src.core.Strings") or function(s) return s end

  -- Socket HTTP/HTTPS modules for 24/7 GTS REST Server & Cloudflare Tunnel
  local hasSocketHttp, http = pcall(require, "socket.http")
  if not hasSocketHttp then http = nil end

  local hasHttps, https = pcall(require, "ssl.https")
  if not hasHttps then https = nil end

  local hasLtn12, ltn12 = pcall(require, "ltn12")
  if not hasLtn12 then ltn12 = nil end

  -- GTS Server URL: read from gts_config.txt next to main.lua (per-device,
  -- edit without rebuilding). Falls back to a storage value, then a server
  -- on this machine (server/gts_server.py's default port).
  local DEFAULT_SERVER_URL = "http://127.0.0.1:7779"
  local GTS_SERVER_URL = DEFAULT_SERVER_URL
  local function readServerUrlFromConfig()
    local content = nil
    local readErr = "no mod.read"
    if mod and mod.read then
      local ok, res = pcall(function() return mod:read("gts_config.txt") end)
      if ok and type(res) == "string" and #res > 0 then
        content = res
      else
        readErr = tostring(ok and (res and "non-string" or "nil/empty") or res)
      end
    end
    if not content then
      print("[Gen1Online++] gts_config.txt read failed: " .. readErr
        .. (mod and mod.path and (" (path=" .. tostring(mod.path) .. ")") or ""))
    end
    if content then
      for line in tostring(content):gmatch("[^\r\n]+") do
        local key, val = line:match("^%s*([^#=%s]+)%s*=%s*(.-)%s*$")
        if key and val and key:lower() == "server_url" and #val > 0 then
          return val
        end
      end
    end
    return nil
  end
  -- A server typed in-game (START > CONNECT > SERVER ADDRESS) wins; the
  -- config file is the default, for the host and for first-time players.
  local function loadServerUrl()
    local stored = storageRead and storageRead("gts_server_url")
    if not (type(stored) == "string" and #stored > 0) then stored = nil end
    local fromFile = (not stored) and readServerUrlFromConfig() or nil
    GTS_SERVER_URL = stored or fromFile or DEFAULT_SERVER_URL
    GtsUI.serverUrlTyped = stored ~= nil
    _G.GTS_SERVER_URL = GTS_SERVER_URL
    print("[Gen1Online++] server url = " .. tostring(GTS_SERVER_URL)
      .. (stored and " (typed in-game)" or fromFile and " (from gts_config.txt)" or " (DEFAULT)"))
    return GTS_SERVER_URL
  end
  local function getServerUrl()
    return GTS_SERVER_URL
  end
  -- "192.168.1.23", "100.64.0.7:8000" or "http://host:7779/" ->
  -- "http://host:port" (port 7779 when none is given); nil and a reason
  -- when the text isn't an address.
  function GtsUI.normalizeServerAddress(text)
    local s = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^[Hh][Tt][Tt][Pp][Ss]?://", ""):gsub("/+$", "")
    if s == "" then return nil, "TYPE THE HOST'S ADDRESS." end
    local host, port = s:match("^([%w%.%-]+):(%d+)$")
    if not host then host = s:match("^([%w%.%-]+)$") end
    if not host then return nil, "USE ONLY LETTERS, DIGITS, . - AND :PORT." end
    if host:find("..", 1, true) or host:sub(1, 1) == "." or host:sub(-1) == "." then
      return nil, "THAT ADDRESS HAS A STRAY DOT."
    end
    if host:match("^[%d%.]+$") then
      local parts = {}
      for n in host:gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
      if #parts ~= 4 then return nil, "AN IP HAS 4 NUMBERS, LIKE 192.168.1.23." end
      for _, n in ipairs(parts) do
        if n > 255 then return nil, "EACH IP NUMBER IS 0 TO 255." end
      end
    end
    port = tonumber(port or "7779")
    if not port or port < 1 or port > 65535 then return nil, "THE PORT IS 1 TO 65535." end
    return "http://" .. host:lower() .. ":" .. port
  end
  -- what menus show: no scheme, no default port
  function GtsUI.displayAddress(url)
    local s = tostring(url or ""):gsub("^%a+://", ""):gsub("/+$", ""):gsub(":7779$", "")
    return s:upper()
  end
  local isGtsServerConnected = false -- Explicit manual connection required via menu
  -- The live game instance (set every frame in core.update) so writeOnlineSave
  -- can snapshot the world before persisting flags/mapScenes/scriptMem.
  local currentGame = nil

  -- Universal Overworld / World accessor for Gen 1 (overworld) and Gen 2 (world)
  local function getWorld(g)
    g = g or Game
    if not g then return nil end
    return g.world or g.overworld
  end

  -- Networking State
  local netSession, isHost, roomCode, lastSendTime = nil, false, nil, 0
  local lastPlayerX, lastPlayerY, lastPlayerMap, lastPlayerMoving = nil, nil, nil, false
  local activeBattleAdapter, activeParty, pendingPartyInvite, lastPartySyncTime, openPartyMainMenu = nil, nil, nil, 0, nil
  local isWaitingForChallenge, challengeWaitTimer, lastBattleEndTime, inBattle = false, 0, -999, false
  local clientSessionId = string.format("%08x%08x", math.random(10000000, 99999999), os.time())
  local netNpcs, netFollowers, netPlayerMap, gtsSpriteDiagWritten = {}, {}, {}, false
  -- How long a player who isn't moving waits between syncs.  Other players
  -- only arrive in the answer to our own sync, so with someone else on the
  -- map this has to stay short or they move in jumps, seconds late.
  function GtsUI.idleSyncInterval()
    return next(netNpcs) and 0.25 or 1.0
  end

  -- Inter-mod bridge: expose the LIVE remote-player registry (by reference,
  -- not copy) so companion rendering mods -- e.g. PotatoVoxel's 3D voxel
  -- overworld -- can include other players in their scene. mod.exports is
  -- reachable cross-mod through mod.find(id).exports (the loader publishes
  -- this exact table). Every place that replaces the `netNpcs` table
  -- re-points this export so it never dangles.
  if mod then
    mod.exports = mod.exports or {}
    mod.exports.netNpcs = netNpcs
  end

  -- Custom Trainer Profile State & MMO Leveling Engine (1 to 100)
  local localTrainerTitle = "ACE TRAINER"
  local localFavoriteMon = "CHARIZARD"
  local mmoLevel = 1
  local mmoXp = 0
  local mmoToken = nil
  local localSelectedSprite = isGen2 and "SPRITE_CHRIS" or "SPRITE_RED"

  -- Leveling Curve Calculation: starts fast, slows down gradually
  local function calculateXpForLevel(lvl)
    if lvl <= 1 then return 0 end
    return math.floor(50 * ((lvl - 1) ^ 1.8))
  end

  local function calculateLevelFromXp(xp)
    if xp <= 0 then return 1 end
    for lvl = 100, 1, -1 do
      if xp >= calculateXpForLevel(lvl) then
        return lvl
      end
    end
    return 1
  end

  -- Online avatars, per generation (Gen 1 sprite ids are pokered's).
  -- GtsUI.avatarChoices drops any the running game has no sprite for.
  local AVAILABLE_AVATARS = isGen2 and {
    { id = "SPRITE_CHRIS", label = "CRYSTAL / PROTAGONIST" },
    { id = "SPRITE_RIVAL", label = "SILVER / RIVAL" },
    { id = "SPRITE_RED", label = "RED" },
    { id = "SPRITE_BLUE", label = "BLUE" },
    { id = "SPRITE_FALKNER", label = "FALKNER" },
    { id = "SPRITE_BUGSY", label = "BUGSY" },
    { id = "SPRITE_WHITNEY", label = "WHITNEY" },
    { id = "SPRITE_MORTY", label = "MORTY" },
    { id = "SPRITE_JASMINE", label = "JASMINE" },
    { id = "SPRITE_CHUCK", label = "CHUCK" },
    { id = "SPRITE_PRYCE", label = "PRYCE" },
    { id = "SPRITE_CLAIR", label = "CLAIR" },
    { id = "SPRITE_LANCE", label = "LANCE" },
    { id = "SPRITE_BROCK", label = "BROCK" },
    { id = "SPRITE_MISTY", label = "MISTY" },
    { id = "SPRITE_ERIKA", label = "ERIKA" },
    { id = "SPRITE_JANINE", label = "JANINE" },
    { id = "SPRITE_SABRINA", label = "SABRINA" },
    { id = "SPRITE_COOLTRAINER_M", label = "COOLTRAINER M" },
    { id = "SPRITE_COOLTRAINER_F", label = "COOLTRAINER F" },
    { id = "SPRITE_BUG_CATCHER", label = "BUG CATCHER" },
    { id = "SPRITE_LASS", label = "LASS" },
    { id = "SPRITE_YOUNGSTER", label = "YOUNGSTER" },
    { id = "SPRITE_BEAUTY", label = "BEAUTY" },
    { id = "SPRITE_SUPER_NERD", label = "SUPER NERD" },
    { id = "SPRITE_ROCKER", label = "ROCKER" },
    { id = "SPRITE_POKEFAN_M", label = "POKEFAN M" },
    { id = "SPRITE_POKEFAN_F", label = "POKEFAN F" },
    { id = "SPRITE_KIMONO_GIRL", label = "KIMONO GIRL" },
    { id = "SPRITE_SAGE", label = "SAGE" },
    { id = "SPRITE_GENTLEMAN", label = "GENTLEMAN" },
    { id = "SPRITE_BLACK_BELT", label = "BLACK BELT" },
    { id = "SPRITE_OFFICER", label = "OFFICER" },
    { id = "SPRITE_SAILOR", label = "SAILOR" },
    { id = "SPRITE_BIKER", label = "BIKER" },
    { id = "SPRITE_ROCKET", label = "TEAM ROCKET" },
    { id = "SPRITE_ROCKET_GIRL", label = "ROCKET GIRL" },
    { id = "SPRITE_OAK", label = "PROF. OAK" },
    { id = "SPRITE_ELM", label = "PROF. ELM" }
  } or {
    { id = "SPRITE_RED", label = "RED / PROTAGONIST" },
    { id = "SPRITE_BLUE", label = "BLUE / RIVAL" },
    { id = "SPRITE_OAK", label = "PROF. OAK" },
    { id = "SPRITE_GIOVANNI", label = "GIOVANNI" },
    { id = "SPRITE_LANCE", label = "LANCE" },
    { id = "SPRITE_LORELEI", label = "LORELEI" },
    { id = "SPRITE_BRUNO", label = "BRUNO" },
    { id = "SPRITE_AGATHA", label = "AGATHA" },
    { id = "SPRITE_KOGA", label = "KOGA" },
    { id = "SPRITE_DAISY", label = "DAISY" },
    { id = "SPRITE_COOLTRAINER_M", label = "COOLTRAINER M" },
    { id = "SPRITE_COOLTRAINER_F", label = "COOLTRAINER F" },
    { id = "SPRITE_YOUNGSTER", label = "YOUNGSTER" },
    { id = "SPRITE_SUPER_NERD", label = "SUPER NERD" },
    { id = "SPRITE_BEAUTY", label = "BEAUTY" },
    { id = "SPRITE_GENTLEMAN", label = "GENTLEMAN" },
    { id = "SPRITE_HIKER", label = "HIKER" },
    { id = "SPRITE_BIKER", label = "BIKER" },
    { id = "SPRITE_SAILOR", label = "SAILOR" },
    { id = "SPRITE_ROCKER", label = "ROCKER" },
    { id = "SPRITE_FISHER", label = "FISHER" },
    { id = "SPRITE_SWIMMER", label = "SWIMMER" },
    { id = "SPRITE_SCIENTIST", label = "SCIENTIST" },
    { id = "SPRITE_CHANNELER", label = "CHANNELER" },
    { id = "SPRITE_GAMBLER", label = "GAMBLER" },
    { id = "SPRITE_ROCKET", label = "TEAM ROCKET" },
    { id = "SPRITE_GAMEBOY_KID", label = "GAMEBOY KID" },
    { id = "SPRITE_CAPTAIN", label = "CAPTAIN" },
    { id = "SPRITE_MR_FUJI", label = "MR. FUJI" },
  }

  -- The avatars this game can actually draw: a sprite missing from its data
  -- would leave the trainer invisible.
  function GtsUI.avatarChoices(game)
    local sprites = game and game.data and (isGen2 and game.data.gen2Sprites or game.data.sprites)
    if type(sprites) ~= "table" or next(sprites) == nil then return AVAILABLE_AVATARS end
    local out = {}
    for _, av in ipairs(AVAILABLE_AVATARS) do
      if sprites[av.id] then out[#out + 1] = av end
    end
    return #out > 0 and out or AVAILABLE_AVATARS
  end

  -- Shown when the server hosts the other generation's world.
  function GtsUI.wrongWorldText(serverGen)
    local worlds = { [1] = "GEN 1 (RED, BLUE AND YELLOW)", [2] = "GEN 2 (CRYSTAL)" }
    return string.format("THIS SERVER IS A %s WORLD.\nYOUR GAME IS %s.\nASK THE HOST FOR A %s SERVER.",
      worlds[tonumber(serverGen)] or "DIFFERENT", isGen2 and "CRYSTAL" or "GEN 1",
      isGen2 and "CRYSTAL" or "GEN 1")
  end

  -- Global Trade Station (GTS) Database
  _G.GEN1ONLINE_GTS = _G.GEN1ONLINE_GTS or {
    listings = {},       -- listingId -> listing object
    user_counts = {},    -- trainerId -> active deposit count
    history = {},        -- array of last 50 trade receipts
    claim_boxes = {},    -- trainerId -> list of completed traded mons
    next_id = 1001,
  }
  local gtsDb = _G.GEN1ONLINE_GTS

  local function newQueue()
    local q = {}
    return {
      push = function(self, val) table.insert(q, val) end,
      pop = function(self) return table.remove(q, 1) end,
      peek = function(self) return q[1] end,
      getCount = function(self) return #q end,
      clear = function(self) q = {} end
    }
  end

  local netOutChannel = newQueue()
  local netInChannel = newQueue()

  -- Remote NPC count logging timer
  local remoteCountLogTime = 0

  -- Transport diagnostics: records the outcome of every request attempt so a
  -- failing call can report exactly which transport died and why.
  local netDiag = { url = "", method = "", timeout = 0, attempts = {} }
  local function netDiagReset(url, method, timeout)
    netDiag.url = url or ""
    netDiag.method = method or ""
    netDiag.timeout = timeout or 0
    netDiag.attempts = {}
  end
  local function netDiagAdd(which, outcome)
    netDiag.attempts[#netDiag.attempts + 1] = which .. ": " .. outcome
  end
  local function netDiagReport()
    if #netDiag.attempts == 0 then return "NETWORK_ERROR" end
    local lines = { "NETWORK_ERROR" }
    local u = netDiag.url
    if #u > 50 then u = u:sub(1, 47) .. "..." end
    lines[#lines + 1] = "URL: " .. u
    lines[#lines + 1] = string.format("REQ: %s TIMEOUT %gs", netDiag.method, netDiag.timeout)
    for i = 1, math.min(#netDiag.attempts, 4) do
      lines[#lines + 1] = netDiag.attempts[i]
    end
    return table.concat(lines, "\n")
  end

  -- Universal Transport Helper (Supports direct HTTPS via LuaSec, socket.http, and pure luasocket TCP)
  local function makeHttpRequest(reqTable)
    reqTable.timeout = reqTable.timeout or 8.0
    local isHttps = (reqTable.url:sub(1, 5) == "https")
    netDiagReset(reqTable.url, reqTable.method, reqTable.timeout)

    -- If https requested but no SSL module present in the sandbox, rewrite to http so socket.http / pure socket TCP succeed
    if isHttps then
      local okHttps, httpsMod = pcall(require, "ssl.https")
      local okSsl, ssl = pcall(require, "ssl")
      if not (okHttps and httpsMod) and not (okSsl and ssl and ssl.wrap) then
        reqTable.url = reqTable.url:gsub("^https://", "http://")
        isHttps = false
      end
    end

    -- 1. Try ssl.https if https
    if isHttps then
      local okHttps, httpsMod = pcall(require, "ssl.https")
      if okHttps and httpsMod then
        local ok, res, code, headers, status = pcall(httpsMod.request, reqTable)
        if ok and code and code >= 200 and code < 400 then
          netDiagAdd("ssl.https", "OK code=" .. tostring(code))
          return ok, res, code, headers, status
        end
        if not ok then
          netDiagAdd("ssl.https", "THREW: " .. tostring(res))
        elseif not code then
          netDiagAdd("ssl.https", "FAIL: " .. tostring(status or res))
        else
          netDiagAdd("ssl.https", "code=" .. tostring(code))
        end
      else
        netDiagAdd("ssl.https", "unavailable")
      end
    end

    -- 2. Try socket.http
    local okHttp, httpMod = pcall(require, "socket.http")
    if okHttp and httpMod then
      local ok, res, code, headers, status = pcall(httpMod.request, reqTable)
      code = tonumber(code)
      if ok and code and code >= 200 and code < 400 then
        netDiagAdd("socket.http", "OK code=" .. tostring(code))
        return ok, res, code, headers, status
      end
      if not ok then
        netDiagAdd("socket.http", "THREW: " .. tostring(res))
      elseif not code then
        netDiagAdd("socket.http", "FAIL: " .. tostring(status or res))
      else
        netDiagAdd("socket.http", "code=" .. tostring(code))
      end
    else
      netDiagAdd("socket.http", "unavailable")
    end

    -- 3. Pure luasocket TCP client (Permitted by Sandbox with network permission)
    local okSocket, socket = pcall(require, "socket")
    if okSocket and socket and socket.tcp then
      local host, port, path = reqTable.url:match("^https?://([^/:]+):?(%d*)(/?.*)")
      if host then
        port = tonumber(port) or (isHttps and 443 or 80)
        if path == "" then path = "/" end
        local tcp = socket.tcp()
        tcp:settimeout(reqTable.timeout or 8.0)
        local connOk, connErr = tcp:connect(host, port)
        if connOk then
          local hsOk = true
          if isHttps then
            local okSsl, ssl = pcall(require, "ssl")
            if okSsl and ssl and ssl.wrap then
              local params = { mode = "client", protocol = "any", verify = "none" }
              tcp = ssl.wrap(tcp, params)
              if tcp then hsOk = pcall(tcp.dohandshake, tcp) end
            end
          end
          if not hsOk then
            netDiagAdd("raw-tcp", "TLS handshake failed")
            pcall(tcp.close, tcp)
          else
            local bodyStr = ""
            if reqTable.source and type(reqTable.source) == "function" then
              local chunk = reqTable.source()
              while chunk do
                bodyStr = bodyStr .. tostring(chunk)
                chunk = reqTable.source()
              end
            end

            local reqHeader = string.format("%s %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: LuaSocket 2.0.2\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Mod-Version: %s\r\n\r\n%s",
              reqTable.method or (bodyStr ~= "" and "POST" or "GET"),
              path, host, #bodyStr, MOD_VERSION, bodyStr)

            pcall(tcp.send, tcp, reqHeader)
            local respData = {}
            while true do
              local line, err, partial = tcp:receive(4096)
              if line then table.insert(respData, line)
              elseif partial and #partial > 0 then table.insert(respData, partial) end
              if err then break end
            end
            pcall(tcp.close, tcp)

            local fullResp = table.concat(respData)
            local bodyStart = fullResp:find("\r\n\r\n") or fullResp:find("\n\n")
            if bodyStart then
              local realCode = tonumber(fullResp:match("^HTTP/%d%.%d%s+(%d+)")) or 200
              local bodyOnly = fullResp:sub(bodyStart + 4)
              if reqTable.sink and type(reqTable.sink) == "function" then
                reqTable.sink(bodyOnly)
              end
              netDiagAdd("raw-tcp", "code=" .. tostring(realCode) .. " bytes=" .. tostring(#bodyOnly))
              return true, 1, realCode, {}, "OK"
            end
            netDiagAdd("raw-tcp", "conn ok but no HTTP body")
          end
        else
          netDiagAdd("raw-tcp", "connect FAIL: " .. tostring(connErr))
        end
      else
        netDiagAdd("raw-tcp", "bad URL")
      end
    else
      netDiagAdd("raw-tcp", "socket unavailable")
    end

    -- 4. Fallback to local server http://127.0.0.1:7779 if remote failed
    if isHttps and okSocket and socket and socket.tcp then
      local tcp = socket.tcp()
      tcp:settimeout(reqTable.timeout or 8.0)
      if tcp:connect("127.0.0.1", 7779) then
        local bodyStr = ""
        if reqTable.source and type(reqTable.source) == "function" then
          local chunk = reqTable.source()
          while chunk do bodyStr = bodyStr .. tostring(chunk); chunk = reqTable.source() end
        end
        local path = reqTable.url:match("^https?://[^/]+(/?.*)") or "/gts"
        local reqHeader = string.format("%s %s HTTP/1.1\r\nHost: 127.0.0.1:7779\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Mod-Version: %s\r\n\r\n%s",
          reqTable.method or "POST", path, #bodyStr, MOD_VERSION, bodyStr)
        pcall(tcp.send, tcp, reqHeader)
        local respData = {}
        while true do
          local line, err, partial = tcp:receive(4096)
          if line then table.insert(respData, line)
          elseif partial and #partial > 0 then table.insert(respData, partial) end
          if err then break end
        end
        pcall(tcp.close, tcp)
        local fullResp = table.concat(respData)
        local bodyStart = fullResp:find("\r\n\r\n") or fullResp:find("\n\n")
        if bodyStart then
          local bodyOnly = fullResp:sub(bodyStart + 4)
          if reqTable.sink and type(reqTable.sink) == "function" then
            reqTable.sink(bodyOnly)
          end
          netDiagAdd("localhost", "code=200")
          return true, 1, 200, {}, "OK"
        end
      else
        netDiagAdd("localhost", "connect FAIL")
      end
    end

    return false, nil, nil, nil, nil
  end

  -- Generation-aware Starting Spawn Locations (Johto / New Bark Town for Crystal, Kanto / Pallet Town for Gen 1)
  local defaultStartingOutdoor = isGen2 and "NEW_BARK_TOWN" or "PALLET_TOWN"
  local defaultStartingOutdoorX = isGen2 and 13 or 5
  local defaultStartingOutdoorY = isGen2 and 6 or 6
  local defaultStartingIndoor = isGen2 and "PLAYERS_HOUSE_2F" or "REDS_HOUSE_2F"
  local defaultStartingIndoorX = isGen2 and 3 or 3
  local defaultStartingIndoorY = isGen2 and 3 or 6

  -- Client Game Version (Red/Blue/Yellow) & Recomp Engine Version Detector
  local function getClientVersionInfo()
    local gameName = "Pokemon Red"
    local okGv, GvMod = pcall(require, "src.core.GameVersion")
    if okGv and GvMod and GvMod.get then
      local vid = GvMod.get()
      gameName = (GvMod.VERSIONS and GvMod.VERSIONS[vid] and GvMod.VERSIONS[vid].displayName) or (tostring(vid):sub(1,1):upper() .. tostring(vid):sub(2))
    end

    local recompVer = "0.0.0-dev"
    local okVer, VerMod = pcall(require, "src.core.Version")
    if okVer and VerMod and VerMod.engine then
      recompVer = "v" .. tostring(VerMod.engine)
    end
    return gameName, recompVer
  end


  -- Profanity Filter Module Loader
  local Profanity = nil
  local okProf, profMod = pcall(requireLocal, "other/profanity.lua")
  if okProf and type(profMod) == "table" then Profanity = profMod end

  local function gtsApiGet(path, timeout)
    local response_body = {}
    local base = getServerUrl():gsub("/+$", "")
    local rel = (path or ""):gsub("^/+", "")
    local separator = rel:find("?") and "&" or "?"
    local fullUrl = base .. "/" .. rel .. separator .. "version=" .. MOD_VERSION .. "&modVersion=" .. MOD_VERSION
      .. "&gen=" .. (isGen2 and "2" or "1")
    local ok, res, code, headers, status = makeHttpRequest({
      url = fullUrl,
      method = "GET",
      headers = {
        ["X-Mod-Version"] = MOD_VERSION
      },
      sink = function(chunk)
        if chunk then table.insert(response_body, chunk) end
        return 1 -- keep pumping: nil cut answers off at the first 2048 bytes
      end,
      timeout = timeout or 4.0
    })
    if ok and #response_body > 0 then
      local str = table.concat(response_body)
      local okJson, data = pcall(Json.decode, str)
      if okJson and data then return data end
      netDiagAdd("decode", "response not JSON (code=" .. tostring(code) .. ")")
    elseif not ok then
      netDiagAdd("http", "request failed (code=" .. tostring(code) .. ")")
    end
    return nil
  end

  local function gtsApiPost(payload, timeout)
    payload = payload or {}
    local gName, rVer = getClientVersionInfo()
    payload.modVersion = MOD_VERSION
    payload.version = MOD_VERSION
    payload.gameVersion = gName
    payload.recompVersion = rVer
    payload.generation = isGen2 and 2 or 1
    local jsonStr = Json.encode(payload)
    local response_body = {}
    local sent = false
    local base = getServerUrl():gsub("/+$", "")
    local ok, res, code, headers, status = makeHttpRequest({
      url = base .. "/gts",
      method = "POST",
      headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#jsonStr),
        ["X-Mod-Version"] = MOD_VERSION
      },
      source = function()
        if not sent then sent = true; return jsonStr end
        return nil
      end,
      sink = function(chunk)
        if chunk then table.insert(response_body, chunk) end
        return 1 -- keep pumping: nil cut answers off at the first 2048 bytes
      end,
      timeout = timeout or 4.0
    })
    if ok and #response_body > 0 then
      local str = table.concat(response_body)
      local okJson, data = pcall(Json.decode, str)
      if okJson and data then return data end
      netDiagAdd("decode", "response not JSON (code=" .. tostring(code) .. ")")
    elseif not ok then
      netDiagAdd("http", "request failed (code=" .. tostring(code) .. ")")
    end
    return nil
  end
  -- ================================================================
  -- Trainer ID & Name Helper (defined early for all modules)
  -- ================================================================
  local function getTrainerInfo(save)
    local p = save and save.player
    if not p then return 12345, "TRAINER" end
    if not p.id then
      math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000000))
      p.id = math.random(10000, 99999)
    end
    return p.id, p.name or "TRAINER"
  end

  -- ================================================================
  -- Global Chat Live Notifications + Queue + Pokegear state
  -- ================================================================
  CHAT_MAX_LEN = 200
  ChatState = { liveEnabled = true, history = {}, lastId = 0, unread = 0, queue = {}, pollTimer = 0, pollInterval = 5.0, loaded = false }
  -- Compatibility aliases to keep existing code paths working without adding locals
  -- Use ChatState.* everywhere; local aliases below are NOT new locals (upvalues via table)
  function loadChatNotifPref()
    if ChatState.loaded then return ChatState.liveEnabled end
    local stored = storageRead and storageRead("live_chat_notifications")
    if type(stored) == "boolean" then ChatState.liveEnabled = stored
    elseif currentGame and currentGame.save and currentGame.save.modData and currentGame.save.modData["gen1online-plus"] and type(currentGame.save.modData["gen1online-plus"].liveChat) == "boolean" then
      ChatState.liveEnabled = currentGame.save.modData["gen1online-plus"].liveChat
    end
    ChatState.loaded = true
    return ChatState.liveEnabled
  end
  function saveChatNotifPref(val)
    ChatState.liveEnabled = val and true or false
    storageWrite("live_chat_notifications", ChatState.liveEnabled)
    if currentGame and currentGame.save then
      currentGame.save.modData = currentGame.save.modData or {}
      currentGame.save.modData["gen1online-plus"] = currentGame.save.modData["gen1online-plus"] or {}
      currentGame.save.modData["gen1online-plus"].liveChat = ChatState.liveEnabled
    end
  end
  function isPlayerBusy(game)
    if not game or not game.stack then return true end
    if inBattle then return true end
    local top = game.stack:top()
    if not top then return false end
    if top.isTextBox or top.isOpaque == false then
      -- Menu/ChoiceBox/TextBox occupy screen; treat as busy (TextBox has isTextBox)
      -- Menus are opaque but block overworld input
      if top.isTextBox or top.choice or top.isMenu then return true end
    end
    -- Detect battle state via isBattle or BattleState
    if top.isBattle then return true end
    -- Any non-overworld top means busy (menu, naming, battle)
    local ow = getWorld(game)
    if ow and top ~= ow then
      -- If top is Menu/TextBox/ChoiceBox/NamingScreen etc.
      local name = top.screenId or ""
      if top.isTextBox or top.choice or name == "Menu" or name == "ChoiceBox" then return true end
      -- Generic: if stack depth >1 and top not overworld
      if game.stack.states and #game.stack.states > 1 then
        -- Allow pokegear itself to not block queue drain after close, but while open don't popup
        return true
      end
    end
    return false
  end
  function drainChatNotifQueue(game)
    if not ChatState.liveEnabled then return end
    if #ChatState.queue == 0 then return end
    if isPlayerBusy(game) then return end
    local entry = table.remove(ChatState.queue, 1)
    if entry then
      game.stack:push(TextBox.new(game, wrapText(entry)))
    end
  end
  function pushLiveChatNotification(game, name, text)
    if not ChatState.liveEnabled then return end
    if not isGtsServerConnected then return end
    local formatted = string.format("%s: %s", tostring(name or "TRAINER"), tostring(text or ""))
    -- Truncate formatted to fit textbox gracefully via wrapText
    if isPlayerBusy(game) then
      if #ChatState.queue >= 20 then table.remove(ChatState.queue, 1) end
      ChatState.queue[#ChatState.queue+1] = formatted
    else
      game.stack:push(TextBox.new(game, wrapText(formatted)))
    end
  end
  function handleNewChatMessages(game, msgs)
    msgs = msgs or {}

    -- On initial connect / startup, establish baseline without spamming old
    -- messages.  An empty history is a baseline too (lastId 0), so the first
    -- message on a quiet server is not swallowed as "old".
    if not ChatState.connectedBaseline then
      local maxId = 0
      for _, m in ipairs(msgs) do
        local id = tonumber(m.id) or 0
        if id > maxId then maxId = id end
      end
      ChatState.lastId = maxId
      ChatState.history = msgs
      ChatState.unread = 0
      ChatState.connectedBaseline = true
      return
    end
    if #msgs == 0 then return end

    local maxId = ChatState.lastId
    for _, m in ipairs(msgs) do
      local id = tonumber(m.id) or 0
      if id > maxId then maxId = id end
    end
    if maxId <= ChatState.lastId then
      ChatState.history = msgs
      return
    end

    -- Find truly new messages arrived in real-time AFTER baseline
    for _, m in ipairs(msgs) do
      local id = tonumber(m.id) or 0
      if id > ChatState.lastId then
        ChatState.unread = (ChatState.unread or 0) + 1
        -- Only notify for others' messages, not own
        local gSave = (game and game.save) or (currentGame and currentGame.save)
        local myId = gSave and select(1, getTrainerInfo(gSave)) or nil
        if tostring(m.trainerId) ~= tostring(myId) then
          pushLiveChatNotification(game or currentGame, m.name, m.text)
        end
      end
    end
    ChatState.lastId = maxId
    ChatState.history = msgs
  end
  -- The periodic chat poll runs off the main thread through mod.fetch (the
  -- engine's background HTTP, which also speaks real HTTPS) when the build
  -- has it; the blocking GET it replaces stalled a frame every poll on a
  -- remote server.  serviceChatFetch collects the answer each frame.
  function pollGlobalChat(game)
    game = game or currentGame
    if not game or not isGtsServerConnected then return end
    local fetch = mod and mod.fetch
    if fetch and fetch.available and fetch:available() then
      if ChatState.fetchJob then return end -- the last poll is still in flight
      local url = getServerUrl():gsub("/+$", "") .. "/chat/history?version="
        .. MOD_VERSION .. "&modVersion=" .. MOD_VERSION .. "&gen=" .. (isGen2 and "2" or "1")
      ChatState.fetchJob = fetch:get(url, { accept = "application/json", maxSeconds = 5 })
      if ChatState.fetchJob then return end
    end
    local res = gtsApiGet("/chat/history", 2.0)
    if res and res.success and res.messages then
      handleNewChatMessages(game, res.messages)
    end
  end
  function serviceChatFetch(game)
    local job = ChatState.fetchJob
    if not job then return end
    local result = mod.fetch:poll(job)
    if not result or result.status == "pending" then return end
    pcall(mod.fetch.release, mod.fetch, job)
    ChatState.fetchJob = nil
    if result.status == "ok" and isGtsServerConnected then
      local okJson, res = pcall(Json.decode, result.body or "")
      if okJson and type(res) == "table" and res.success and res.messages then
        handleNewChatMessages(game or currentGame, res.messages)
      end
    end
  end
  -- A fresh chat session: the first poll sets the baseline, so history from
  -- before connecting is not replayed as notifications.  Every way of coming
  -- online (login, new character, recovery token) starts one.
  function startChatSession(game)
    ChatState.lastId = 0
    ChatState.connectedBaseline = false
    ChatState.unread = 0
    ChatState.queue = {}
    ChatState.pollTimer = 0
    loadChatNotifPref()
    pcall(pollGlobalChat, game)
    ensureChatTextInputPatch()
  end
  function sendGlobalChat(game, rawText, scope)
    scope = scope or "global"
    game = game or currentGame or (Game and Game.save and Game)
    if not game then return false end
    if not rawText or rawText:match("^%s*$") then
      game.stack:push(TextBox.new(game, wrapText("MESSAGE IS EMPTY!")))
      return false
    end
    if #rawText > CHAT_MAX_LEN then rawText = rawText:sub(1, CHAT_MAX_LEN) end
    local clean = (Profanity and Profanity.censor) and Profanity.censor(rawText) or rawText
    local myId, myName = getTrainerInfo(game.save)
    local res = gtsApiPost({ action = "send_chat", trainerId = tostring(myId), name = tostring(myName), text = clean, scope = scope }, 4.0)
    if res and res.success then
      -- Optimistically update cache: next poll will confirm, but push ourselves without notification
      game.stack:push(TextBox.new(game, wrapText(string.format("SENT:\n%s", clean))))
      -- Refresh history silently
      local hist = gtsApiGet("/chat/history", 2.0)
      if hist and hist.success and hist.messages then
        ChatState.history = hist.messages
        local maxId = ChatState.lastId
        for _, m in ipairs(hist.messages) do maxId = math.max(maxId, tonumber(m.id) or 0) end
        if maxId > ChatState.lastId then ChatState.lastId = maxId end
      end
      return true
    else
      game.stack:push(TextBox.new(game, wrapText("COULD NOT SEND CHAT TO SERVER!")))
      return false
    end
  end

  -- ChatInputScreen: 200-char free typing, vanilla 18-col wrap, profanity filter
  ChatInputScreen = {}
  ChatInputScreen.__index = ChatInputScreen
  ChatInputScreen.isOpaque = true
  ChatInputScreen.gtsTextInput = true
  function ChatInputScreen.new(game, opts)
    opts = opts or {}
    local self = setmetatable({}, ChatInputScreen)
    self.game = game
    self.onDone = opts.onDone
    self.onCancel = opts.onCancel
    self.maxLen = CHAT_MAX_LEN
    self.buffer = opts.default or ""
    if #self.buffer > self.maxLen then self.buffer = self.buffer:sub(1, self.maxLen) end
    self.cursorBlink = 0
    -- Enable OS text input if available
    pcall(function() if love.keyboard and love.keyboard.setTextInput then love.keyboard.setTextInput(true) end end)
    return self
  end
  function ChatInputScreen:textinput(t)
    if not t then return end
    -- Filter newlines/form feeds; allow printable
    t = tostring(t):gsub("[\r\n\f]", "")
    if t == "" then return end
    if #self.buffer + #t > self.maxLen then
      t = t:sub(1, self.maxLen - #self.buffer)
    end
    if t ~= "" then self.buffer = self.buffer .. t end
  end
  function ChatInputScreen:update(dt)
    self.cursorBlink = (self.cursorBlink + 1) % 60
    -- a controller reaches the box through the game's input, not a callback
    local input = self.game and self.game.input
    if input and input.wasPressed then
      for _, button in ipairs({ "a", "start", "b", "select" }) do
        if input:wasPressed(button) then
          return self:onGamepadPressed(button == "select" and "back" or button)
        end
      end
    end
  end
  function ChatInputScreen:onKeyPressed(key)
    if key == "escape" then
      pcall(function() if love.keyboard and love.keyboard.setTextInput then love.keyboard.setTextInput(false) end end)
      self.game.stack:pop()
      if self.onCancel then self.onCancel() end
      return true
    end
    if key == "backspace" then
      if #self.buffer > 0 then
        self.buffer = self.buffer:sub(1, #self.buffer - 1)
        while #self.buffer > 0 and self.buffer:sub(#self.buffer, #self.buffer):byte() >= 128 and self.buffer:sub(#self.buffer, #self.buffer):byte() < 192 do
          self.buffer = self.buffer:sub(1, #self.buffer - 1)
        end
      end
      return true
    end
    if key == "return" or key == "kpenter" or key == "enter" then
      if #self.buffer == 0 then return true end
      local toSend = self.buffer
      pcall(function() if love.keyboard and love.keyboard.setTextInput then love.keyboard.setTextInput(false) end end)
      self.game.stack:pop()
      if self.onDone then self.onDone(toSend) end
      return true
    end
    if key == "delete" or (key == "u" and love.keyboard and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl"))) then
      self.buffer = ""
      return true
    end
    return true
  end
  function ChatInputScreen:keypressed(key)
    return self:onKeyPressed(key)
  end
  function ChatInputScreen:onGamepadPressed(button)
    if button == "b" then
      if #self.buffer == 0 then
        pcall(function() if love.keyboard and love.keyboard.setTextInput then love.keyboard.setTextInput(false) end end)
        self.game.stack:pop()
        if self.onCancel then self.onCancel() end
      else
        self.buffer = self.buffer:sub(1, #self.buffer - 1)
        while #self.buffer > 0 and self.buffer:sub(#self.buffer, #self.buffer):byte() >= 128 and self.buffer:sub(#self.buffer, #self.buffer):byte() < 192 do
          self.buffer = self.buffer:sub(1, #self.buffer - 1)
        end
      end
      return
    end
    if button == "a" or button == "start" then
      if #self.buffer == 0 then return end
      local toSend = self.buffer
      pcall(function() if love.keyboard and love.keyboard.setTextInput then love.keyboard.setTextInput(false) end end)
      self.game.stack:pop()
      if self.onDone then self.onDone(toSend) end
      return
    end
    if button == "back" or button == "guide" or button == "x" then
      self.buffer = ""
      return
    end
  end
  function ChatInputScreen:draw()
    local Font = require("src.render.Font")
    local Theme = require("src.ui.Theme")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, 160, 144)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("GLOBAL CHAT", 8, 8)
    Font.draw(string.format("%d/%d", #self.buffer, self.maxLen), 104, 8)
    -- Preview box area: 20x8 tiles (x=0, y=3, w=20, h=8)
    local boxTx, boxTy, boxTw, boxTh = 0, 3, 20, 8
    Font.drawBox(boxTx, boxTy, boxTw, boxTh)
    local preview = #self.buffer > 0 and self.buffer or "TYPE MESSAGE..."
    local wrapped = wrapText(preview, 17)
    local lines = {}
    for line in (wrapped .. "\n"):gmatch("(.-)\n") do
      if #lines < 3 then
        lines[#lines + 1] = line
      end
    end
    for i = 1, math.min(3, #lines) do
      Font.draw(lines[i] or "", 16, (boxTy + 2 + (i - 1) * 2) * 8)
    end
    -- Cursor
    if self.cursorBlink < 30 then
      local lastLineIdx = math.max(1, #lines)
      local lastLine = lines[lastLineIdx] or ""
      local cx = 16 + Font.width(lastLine)
      local cy = (boxTy + 2 + (lastLineIdx - 1) * 2) * 8
      if cx <= 140 then
        Font.draw("_", cx, cy)
      end
    end
    Font.draw("ENTER:SEND  BKSP:DEL", 8, 104)
    Font.draw("B / ESC: BACK", 8, 120)
    love.graphics.setColor(1, 1, 1, 1)
  end
  -- Keys reach the chat box through the engine's input.key hook (RFC 0020),
  -- which runs before any of the game's own key handling, so a key the box
  -- takes never also moves a cursor underneath it.  Only the chat box is
  -- served: the old love.keypressed override fed every screen with a
  -- keypressed method and swallowed the key from the engine.
  if mod and mod.hooks and mod.hooks.wrap then
    mod.hooks:wrap("input.key", function(nextFn, game, ev)
      local top = game and game.stack and game.stack:top()
      if ev and ev.phase == "pressed" and top and type(top) == "table" and top.gtsTextInput then
        local ok, handled = pcall(top.onKeyPressed, top, ev.key)
        if ok and handled ~= false then return end
      end
      return nextFn(game, ev)
    end)
  end

  -- Typed characters: the engine does not route love.textinput into the
  -- game, so the chat box chains it (installed the first time it opens).
  local _chatTextInputPatched = false
  function ensureChatTextInputPatch()
    if _chatTextInputPatched then return end
    _chatTextInputPatched = true
    local previous = love.textinput
    love.textinput = function(t)
      local g = currentGame
      local top = g and g.stack and g.stack:top()
      if top and type(top) == "table" and top.gtsTextInput then
        pcall(top.textinput, top, t)
        return
      end
      if previous then return previous(t) end
    end
  end

  -- Server address entry, on both generations.  Gen 1's naming keyboard has
  -- no digits and fits about 10 characters, so this is a screen of its own:
  -- type on a keyboard, or with a controller cycle the last character with
  -- UP/DOWN, add one with RIGHT and delete with LEFT or B.
  do
    local AddressScreen = {}
    AddressScreen.__index = AddressScreen
    AddressScreen.isOpaque = true
    AddressScreen.gtsTextInput = true
    AddressScreen.MAX = 40
    AddressScreen.CHARS = "0123456789.:-ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    GtsUI.AddressScreen = AddressScreen

    function AddressScreen.new(game, opts)
      opts = opts or {}
      local self = setmetatable({}, AddressScreen)
      self.game = game
      self.onDone, self.onCancel = opts.onDone, opts.onCancel
      self.current = opts.current
      self.buffer = tostring(opts.initial or ""):upper():sub(1, AddressScreen.MAX)
      self.blink = 0
      self.message = nil
      ensureChatTextInputPatch()
      pcall(function() if love.keyboard and love.keyboard.setTextInput then love.keyboard.setTextInput(true) end end)
      return self
    end
    function AddressScreen:close()
      pcall(function() if love.keyboard and love.keyboard.setTextInput then love.keyboard.setTextInput(false) end end)
      if self.game.stack:top() == self then self.game.stack:pop() end
    end
    function AddressScreen:add(text)
      for ch in tostring(text or ""):upper():gmatch("[%w%.%:%-]") do
        if #self.buffer < AddressScreen.MAX then self.buffer = self.buffer .. ch end
      end
      self.message = nil
    end
    function AddressScreen:back()
      if #self.buffer == 0 then
        self:close()
        if self.onCancel then self.onCancel() end
        return
      end
      self.buffer = self.buffer:sub(1, -2)
      self.message = nil
    end
    -- UP/DOWN: the last character steps through CHARS
    function AddressScreen:cycle(step)
      local chars = AddressScreen.CHARS
      if #self.buffer == 0 then self.buffer = step > 0 and "1" or "9" return end
      local last = self.buffer:sub(-1)
      local i = chars:find(last, 1, true) or 0
      i = (i - 1 + step) % #chars + 1
      self.buffer = self.buffer:sub(1, -2) .. chars:sub(i, i)
      self.message = nil
    end
    function AddressScreen:confirm()
      local url, why = GtsUI.normalizeServerAddress(self.buffer)
      if not url then
        self.message = why
        return
      end
      self:close()
      if self.onDone then self.onDone(url) end
    end
    function AddressScreen:textinput(t) self:add(t) end
    function AddressScreen:onKeyPressed(key)
      if key == "escape" then
        self:close()
        if self.onCancel then self.onCancel() end
      elseif key == "backspace" then
        if #self.buffer > 0 then self:back() end
      elseif key == "return" or key == "kpenter" then
        self:confirm()
      elseif key == "delete" then
        self.buffer, self.message = "", nil
      elseif key == "up" then
        self:cycle(1)
      elseif key == "down" then
        self:cycle(-1)
      elseif key == "right" then
        self:add("0")
      elseif key == "left" then
        if #self.buffer > 0 then self:back() end
      end
      -- every other key types through textinput; swallowing it here keeps
      -- letters like Z and X from also pressing A or B underneath
      return true
    end
    function AddressScreen:keypressed(key) return self:onKeyPressed(key) end
    function AddressScreen:update(dt)
      self.blink = (self.blink + 1) % 60
      -- a controller reaches the screen through the game's input
      local input = self.game and self.game.input
      if not (input and input.wasPressed) then return end
      if input:wasPressed("a") or input:wasPressed("start") then return self:confirm() end
      if input:wasPressed("b") then return self:back() end
      if input:wasPressed("select") then self.buffer, self.message = "", nil return end
      if input:wasPressed("up") then return self:cycle(1) end
      if input:wasPressed("down") then return self:cycle(-1) end
      if input:wasPressed("right") then return self:add("0") end
      if input:wasPressed("left") and #self.buffer > 0 then return self:back() end
    end
    function AddressScreen:draw()
      local G = love.graphics
      G.setColor(1, 1, 1, 1)
      G.rectangle("fill", 0, 0, 160, 144)
      G.setColor(0, 0, 0, 1)
      Font.draw("SERVER ADDRESS?", 8, 8)
      if self.current and self.current ~= "" then
        Font.draw(("NOW " .. self.current):sub(1, 19), 8, 24)
      end
      Font.drawBox(0, 4, 20, 4)
      -- the field scrolls: the last 17 characters stay in view
      local shown = self.buffer
      if #shown > 17 then shown = shown:sub(-17) end
      local fx, fy = 16, 48
      Font.draw(shown, fx, fy)
      if self.blink < 40 then
        -- a block cursor (the fonts have no "_" glyph), under the last
        -- character, which UP/DOWN change
        local w = Font.width(shown)
        local cx = (#shown > 0) and (fx + w - 8) or fx
        G.rectangle("fill", cx, fy + 8, 8, 1)
      end
      local lines = self.message and wrapText(self.message, 18)
        or "EX: 192.168.1.23\nOR 100.64.0.7:7779"
      local y = 72
      for line in (lines .. "\n"):gmatch("(.-)\n") do
        if y <= 88 then Font.draw(line, 8, y) end
        y = y + 8
      end
      Font.draw("UP DOWN: CHANGE", 8, 104)
      Font.draw("RIGHT:ADD  LEFT:DEL", 8, 112)
      Font.draw("A:OK  B:BACK", 8, 128)
      G.setColor(1, 1, 1, 1)
    end
  end

  function wrapText(str, maxLen)
    maxLen = maxLen or 17
    if not str or #str == 0 then return "" end
    local rawLines = {}
    for paragraph in tostring(str):gmatch("[^\r\n\f]+") do
      local currentLine = ""
      for word in paragraph:gmatch("%S+") do
        if #currentLine == 0 then
          currentLine = word
        elseif #currentLine + 1 + #word <= maxLen then
          currentLine = currentLine .. " " .. word
        else
          table.insert(rawLines, currentLine)
          currentLine = word
        end
      end
      if #currentLine > 0 then
        table.insert(rawLines, currentLine)
      end
    end
    -- Group every 2 lines into a dialog page separated by \f
    local pages = {}
    for i = 1, #rawLines, 2 do
      local l1 = rawLines[i]
      local l2 = rawLines[i + 1]
      if l2 then
        table.insert(pages, l1 .. "\n" .. l2)
      else
        table.insert(pages, l1)
      end
    end
    return table.concat(pages, "\f")
  end

  -- Helper to list all Gen 1 Pokémon species sorted alphabetically
  local function getAllGen1Species(data)
    local speciesList = {}
    if data and data.pokemon then
      for key, def in pairs(data.pokemon) do
        local name = def.name or key
        if type(key) == "string" and name and def.dex and def.dex >= 1 and def.dex <= (isGen2 and 251 or 151) then
          table.insert(speciesList, { id = key, name = name, dex = def.dex })
        end
      end
      table.sort(speciesList, function(a, b) return a.name < b.name end)
    end
    return speciesList
  end

  -- Battle / trade transport for LinkBattle & LinkState, implemented over the
  -- GTS HTTP room API. There is no background thread in the launcher sandbox,
  -- so send() POSTs the message to the room immediately and update() polls
  -- the room on a short rate limit; both are synchronous main-thread calls
  -- (localhost latency, like every other gtsApiPost in this mod).
  --
  -- Servicing: Game:step calls game.linkNet:update() every frame (Gen 1), and
  -- LinkBattle/LinkState also call net:update()/net:poll() from their own
  -- updates, so poll() is driven even while a menu sits on top of the battle.
  local GtsNetAdapter = {}
  GtsNetAdapter.__index = GtsNetAdapter

  local BATTLE_POLL_INTERVAL = 0.15

  function GtsNetAdapter.new(myId, targetId, roomId)
    local self = setmetatable({}, GtsNetAdapter)
    self.myId = tostring(myId)
    self.targetId = tostring(targetId)
    self.roomId = roomId or ("ROOM_" .. self.myId .. "_" .. self.targetId)
    self.inbox = {}
    self.closed = false
    self.paired = true   -- already paired when the battle/trade starts
    self.error = nil
    self.lastPollAt = -math.huge
    activeBattleAdapter = self
    return self
  end

  function GtsNetAdapter:send(msg)
    -- Suppress 'bye' messages: LinkBattle.finish sends {type="bye"} AFTER our
    -- battle.finish wrapper has already called clear_battle_room. Forwarding
    -- it would drop it into the just-cleared room queue and poison the
    -- opponent's NEXT battle with an instant "other player left" loop. Room
    -- cleanup is done server-side by clear_battle_room, so bye is dropped.
    if msg and msg.type == "bye" then return end

    gtsApiPost({
      action = "send_battle_msg",
      roomId = self.roomId,
      targetId = self.targetId,
      msg = msg
    }, 1.5)
  end

  function GtsNetAdapter:update()
    if self.closed then return end
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime)
                  and _G.love.timer.getTime() or os.time()
    if now - self.lastPollAt < BATTLE_POLL_INTERVAL then return end
    self.lastPollAt = now
    local res = gtsApiPost({
      action = "poll_battle_msgs",
      roomId = self.roomId,
      myId = self.myId
    }, 1.5)
    if res and res.msgs then
      for _, m in ipairs(res.msgs) do
        table.insert(self.inbox, m)
      end
    end
  end

  function GtsNetAdapter:poll()
    local out = self.inbox
    self.inbox = {}
    return out
  end

  -- Session-compatible status surface used by LinkState:update (src/link/
  -- Session.lua provides the same methods on the vanilla net path).
  function GtsNetAdapter:getStatus()
    if self.closed then return "closed" end
    return "paired"
  end

  function GtsNetAdapter:hasPending()
    return #self.inbox > 0
  end

  function GtsNetAdapter:take(messageType)
    for i, m in ipairs(self.inbox) do
      if m and m.type == messageType then
        return table.remove(self.inbox, i)
      end
    end
    return nil
  end

  function GtsNetAdapter:pollOne()
    if #self.inbox == 0 then return nil end
    return table.remove(self.inbox, 1)
  end

  function GtsNetAdapter:close()
    -- Mark closed and clear the global reference. No "bye" is sent here: the
    -- room is cleared server-side by clear_battle_room in battle.finish, and
    -- a bye would only poison the next battle's fresh room if it raced it.
    self.closed = true
    if activeBattleAdapter == self then
      activeBattleAdapter = nil
    end
  end

  local syncMultiNetPlayers, startPvpBattle, startLinkTrade, saveOnlineAccount, loadOnlineAccount, syncLocalProfile, performForcedSave, writeOnlineSave, loadOnlineSave, addMmoXp, openOnlineOptionsMenu, openFreshOnlinePlayerMenu, openRedeemTokenMenu, openMyProfileMenu, openServerUrlMenu, openTrainerCardScreen, openMmoLevelInfoScreen, openMmoChatMenu, handleDisconnect, handleConnectToServer, applyPlayerSprite


  -- ==========================================================================
  -- Non-blocking persistent HTTP/1.1 client & MMO Sync Engine
  -- ==========================================================================
  local asyncState, asyncSock, asyncHost, asyncPort, asyncIsHttps = "idle", nil, nil, nil, false
  local asyncWrite, asyncRead, asyncBody, asyncBodyLen, asyncInHeaders = "", "", "", -1, true
  local asyncPending, asyncActive = {}, nil
  local asyncConnectTried, asyncConnectStart, asyncReconnectUntil, asyncStallStart, asyncSendTimeout = false, 0, 0, 0, 0

  local function asyncParseUrl(url)
    local scheme, host, port = url:match("^(https?)://([^/:]+):?(%d*)")
    if not scheme then return nil end
    port = tonumber(port) or (scheme == "https" and 443 or 80)
    local path = url:match("^https?://[^/]+(/[^?#]*)") or "/"
    return scheme, host, port, path
  end

  local function asyncClose(reason)
    if asyncSock then
      pcall(function() asyncSock:close() end)
    end
    asyncSock = nil
    asyncState = "idle"
    asyncConnectTried = false
    asyncConnectStart = 0
    asyncStallStart = 0
    asyncWrite = ""
    asyncRead = ""
    asyncBody = ""
    asyncBodyLen = -1
    asyncInHeaders = true
    asyncActive = nil
    -- If there's still pending work and we just failed, retry shortly.
    if #asyncPending > 0 then
      asyncReconnectUntil = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
      asyncReconnectUntil = asyncReconnectUntil + 0.5
    end
    if reason then netDiagAdd("async", "closed: " .. tostring(reason)) end
  end

  local function asyncEnsureHost()
    if not asyncHost or not asyncPort then
      local first = asyncPending[1]
      if first then
        local scheme, host, port = asyncParseUrl(first.url)
        local okSsl, ssl = pcall(require, "ssl")
        if (scheme == "https") and not (okSsl and ssl and ssl.wrap) then
          -- In Love2D runtime without LuaSec SSL: adapt to port 80 HTTP for Cloudflare tunnel/local server
          asyncHost = host
          asyncPort = 80
          asyncIsHttps = false
        else
          asyncHost = host
          asyncPort = port
          asyncIsHttps = (scheme == "https")
        end
      end
    end
    return asyncHost ~= nil
  end



  -- Blocking TLS handshake (runs once per connection, not per request). This is
  -- the exact path makeHttpRequest uses, which provably connects in-game. A
  -- non-blocking handshake (settimeout(0) + dohandshake polling) was tried and
  -- stalls before completing in this runtime, so we keep the reliable blocking
  -- handshake and switch the socket to non-blocking only AFTER it completes.
  local function asyncDoHandshake(tcp)
    local okSsl, ssl = pcall(require, "ssl")
    if not (okSsl and ssl and ssl.wrap) then return nil, "no ssl" end
    local wrapped = ssl.wrap(tcp, { mode = "client", protocol = "any", verify = "none" })
    if not wrapped then return nil, "ssl wrap failed" end
    wrapped:settimeout(8.0)
    local okHs, hsErr = wrapped:dohandshake()
    if not okHs then return nil, "tls handshake failed: " .. tostring(hsErr) end
    wrapped:settimeout(0)
    return wrapped, nil
  end

  -- NON-BLOCKING connect (settimeout 0 + getpeername polling), then a BLOCKING
  -- TLS handshake once the TCP socket is live. After that the socket runs in
  -- non-blocking mode so per-sync send/recv never block the game loop.
  local function asyncStartConnect()
    if not asyncEnsureHost() then asyncClose("bad url"); return end
    -- Diagnostic: a connect during a battle means the persistent connection
    -- dropped, and the blocking handshake below would freeze the PVP lockstep.
    if inBattle then diag("async reconnect during battle") end
    local okS, socket = pcall(require, "socket")
    if not (okS and socket and socket.tcp) then
      asyncClose("no luasocket"); return
    end
    local tcp = socket.tcp()
    tcp:settimeout(0)
    local cok = tcp:connect(asyncHost, asyncPort)
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
    asyncConnectStart = now
    if cok then
      -- Immediate connection: wrap TLS (blocking handshake) then go to send.
      if asyncIsHttps then
        local wrapped, werr = asyncDoHandshake(tcp)
        if not wrapped then asyncClose(werr); return end
        asyncSock = wrapped
      else
        asyncSock = tcp
      end
      asyncConnectTried = false
      asyncState = "send"
    else
      -- Non-blocking connect: poll getpeername in asyncPoll.
      asyncSock = tcp
      asyncConnectTried = true
      asyncState = "connect"
    end
  end

  local asyncLastSuccess, asyncLastTry, asyncLastError, lastFallbackTime, asyncDiagTime = 0, 0, "", 0, 0

  asyncReset = function(reason)
    asyncLastError = tostring(reason or "")
    asyncClose(reason)
    asyncPending = {}
    asyncActive = nil
  end

  -- Store the server typed in-game (nil: back to gts_config.txt).  The
  -- keep-alive engine caches its host, so it reconnects to the new one.
  function GtsUI.setServerUrl(url)
    if url then
      storageWrite("gts_server_url", url)
    else
      storageRemove("gts_server_url")
    end
    loadServerUrl()
    asyncReset("server changed")
    asyncHost, asyncPort, asyncIsHttps = nil, nil, false
  end

  -- Non-blocking socket operations (especially LuaSec TLS with settimeout(0))
  -- return these when there is nothing to do *yet*: the caller should retry on
  -- the next poll, NOT treat it as a connection failure. "closed" and real
  -- errors (refused/reset) are handled separately by the caller.
  local function asyncWouldBlock(err)
    return err == "timeout" or err == "wantread" or err == "wantwrite"
      or err == "wantconnect" or err == "wantaccept" or err == "wantshutdown"
      or err == "wantclientcert" or err == "again" or err == "busy"
  end

  -- Deliver a completed async request: callbacks (battle messages, etc.) get
  -- the decoded body; everything else goes to netInChannel for the normal
  -- sync/challenge drain.
  local function asyncDeliver(req)
    if not req then return false end
    local body = req.resp and table.concat(req.resp)
    if not body or #body == 0 then return false end
    if type(req.callback) == "function" then
      local ok, dec = pcall(Json.decode, body)
      pcall(req.callback, ok and dec or nil, body)
    elseif netInChannel then
      netInChannel:push(body)
    end
    return true
  end

  local function asyncPollInner()
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
    -- Keep servicing while there is pending work OR an in-flight request whose
    -- response is still being read. Only go fully idle when both are empty.
    if #asyncPending == 0 and asyncActive == nil and asyncState == "idle" then
      return
    end
    if asyncState == "idle" then
      if asyncSock then
        -- Reuse the open keep-alive connection for the next request (the whole
        -- point of keep-alive: no fresh connect / TLS handshake per sync).
        asyncState = "send"
      elseif now < asyncReconnectUntil then
        return
      else
        asyncStartConnect()
      end
      return
    elseif asyncState == "connect" then
      if not asyncSock then asyncClose("no sock"); return end
      -- Poll for non-blocking connect completion. Generous timeout: a first
      -- TLS connect through the Cloudflare tunnel can take a few seconds.
      if now - asyncConnectStart > 15.0 then
        asyncClose("connect timed out")
        return
      end
      local peer = asyncSock:getpeername()
      if peer then
        if asyncIsHttps then
          local wrapped, werr = asyncDoHandshake(asyncSock)
          if not wrapped then asyncClose(werr); return end
          asyncSock = wrapped
        end
        asyncConnectTried = false
        asyncState = "send"
      else
        local _, err = asyncSock:getpeername()
        if err and err ~= "timeout" and not asyncWouldBlock(err) then
          asyncClose("connect failed: " .. tostring(err))
          return
        end
        return
      end
    end

    if asyncState == "send" then
      if not asyncSock then asyncClose("no sock"); return end
      if asyncWrite == "" then
        -- Pull the next pending request and build its request bytes.
        if not asyncActive then
          asyncActive = table.remove(asyncPending, 1)
        end
        if not asyncActive then asyncState = "idle"; return end
        local scheme, host, port, path = asyncParseUrl(asyncActive.url)
        local bodyStr = asyncActive.body or ""
        local reqHead = string.format(
          "POST %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: LuaSocket 2.0.2\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Mod-Version: %s\r\n\r\n%s",
          path or "/gts", host, #bodyStr, MOD_VERSION, bodyStr)
        asyncWrite = reqHead
        asyncRead = ""
        asyncBody = ""
        asyncBodyLen = -1
        asyncInHeaders = true
        asyncStallStart = now
      end
      local sent, err, partial = asyncSock:send(asyncWrite)
      if sent and sent > 0 then
        asyncWrite = asyncWrite:sub(sent + 1)
        asyncStallStart = now
      elseif partial and partial > 0 then
        asyncWrite = asyncWrite:sub(partial + 1)
        asyncStallStart = now
      end
      if err and not asyncWouldBlock(err) then
        asyncClose("send failed: " .. tostring(err))
        return
      end
      if asyncStallStart > 0 and now - asyncStallStart > 12.0 then
        -- The reused keep-alive connection is dead (tunnel/server closed it
        -- while idle). Drop it; the next poll reconnects fresh.
        asyncClose("send stalled")
        return
      end
      if asyncWrite == "" then
        asyncState = "recv"
        asyncStallStart = now
      end
      return
    end

    if asyncState == "recv" then
      if not asyncSock then asyncClose("no sock"); return end
      local chunk, err, partial = asyncSock:receive(4096)
      local gotBytes = false
      if chunk then
        asyncStallStart = now
        asyncRead = asyncRead .. chunk
        gotBytes = true
      elseif partial and #partial > 0 then
        -- Non-blocking TLS often returns partial bytes along with "wantread";
        -- consume them so we make progress instead of stalling forever.
        asyncStallStart = now
        asyncRead = asyncRead .. partial
        gotBytes = true
      end

      if gotBytes then
        -- Shared parsing (works for a full chunk OR partial reads): headers
        -- first, then Content-Length-framed body. Repeated here for both
        -- cases would drift, so both feed this one block.
        while asyncInHeaders do
          local hdrEnd = asyncRead:find("\r\n\r\n")
          if not hdrEnd then break end
          local headerBlock = asyncRead:sub(1, hdrEnd - 1)
          asyncRead = asyncRead:sub(hdrEnd + 4)
          for line in (headerBlock .. "\n"):gmatch("([^\r\n]+)") do
            local k, v = line:match("^([^:]+):%s*(.-)%s*$")
            if k and k:lower() == "content-length" then
              asyncBodyLen = tonumber(v) or -1
            end
          end
          asyncInHeaders = false
        end
        if not asyncInHeaders then
          if asyncBodyLen >= 0 then
            asyncBody = asyncBody .. asyncRead
            asyncRead = ""
            if #asyncBody >= asyncBodyLen then
              local full = asyncBody:sub(1, asyncBodyLen)
              if asyncActive and asyncActive.resp then
                asyncActive.resp[#asyncActive.resp + 1] = full
              end
              -- Response complete: deliver and move to next request.
              if asyncActive then
                local req = asyncActive
                if asyncDeliver(req) then asyncLastSuccess = now end
                asyncActive = nil
                asyncState = "send"
              end
            end
          else
            -- No Content-Length: treat as complete on read.
            if asyncActive and asyncActive.resp and #asyncRead > 0 then
              asyncActive.resp[#asyncActive.resp + 1] = asyncRead
            end
            asyncRead = ""
            if asyncActive then
              local req = asyncActive
              if asyncDeliver(req) then asyncLastSuccess = now end
              asyncActive = nil
              asyncState = "send"
            end
          end
        end
      elseif err then
        if err == "closed" then
          -- Server closed the connection (shouldn't with keep-alive, but handle).
          if asyncRead ~= "" or asyncBody ~= "" then
            if asyncActive and asyncActive.resp then
              if asyncBody ~= "" then asyncActive.resp[#asyncActive.resp + 1] = asyncBody end
              if asyncRead ~= "" then asyncActive.resp[#asyncActive.resp + 1] = asyncRead end
            end
            if asyncActive then asyncDeliver(asyncActive) end
            asyncActive = nil
          end
          asyncClose("server closed connection")
        elseif not asyncWouldBlock(err) then
          asyncClose("recv failed: " .. tostring(err))
        else
          -- Would block (timeout / wantread / etc.): retry on the next poll.
          -- If we've been waiting too long on a reused keep-alive connection,
          -- it's dead. Drop it and reconnect.
          if asyncStallStart > 0 and now - asyncStallStart > 12.0 then
            asyncClose("recv stalled")
          end
        end
      end
      return
    end
  end

  -- Crash-proof wrapper: a Lua error inside the async state machine must never
  -- take down the game loop. Reset to a clean state and keep retrying.
  asyncPoll = function()
    local ok, err = pcall(asyncPollInner)
    if not ok then
      asyncReset("async engine error: " .. tostring(err))
    end
  end

  -- Non-blocking battle-message send (PVP rooms): enqueues a POST to /gts via
  -- the async engine and invokes callback(decodedResponse) when it completes.
  pvpBattleSend = function(payload, callback)
    if not payload then return end
    payload.modVersion = MOD_VERSION
    payload.version = MOD_VERSION
    local gName, rVer = getClientVersionInfo()
    payload.gameVersion = gName
    payload.recompVersion = rVer
    payload.generation = isGen2 and 2 or 1
    asyncPending[#asyncPending + 1] = {
      url = getServerUrl() .. "/gts",
      body = Json.encode(payload),
      resp = {},
      callback = callback,
    }
    while #asyncPending > 30 do table.remove(asyncPending, 1) end
  end

  -- Generation-aware party pack for the wire: Gen 2 uses packMon2 so both
  -- peers rebuild identical copies with unpackMon2; Gen 1 keeps the vanilla
  -- packParty path.
  local function packPartyForGame(game, party)
    if isGen2 then
      if Protocol.packParty2 then return Protocol.packParty2(party or {}) end
      local okP, PvpEngine = pcall(requireLocal, "pvp/engine.lua")
      if okP and PvpEngine and PvpEngine.packParty then
        return PvpEngine.packParty(party)
      end
    end
    return Protocol.packParty(party)
  end

  -- Crystal PVP runs on the engine's native lockstep link battle
  -- (src/link/LinkBattle2.lua) when both trainers' clients have it.  A client
  -- that offers it tags the challenge room TAG; an accepting client that also
  -- has it answers on the room plus "K".  Any other combination -- an older
  -- client on either side -- stays on the mod's own engine (pvp/*), so mixed
  -- versions still battle.  The server relays roomId verbatim.
  local NativePvp = {}
  do
    local TAG = "_L2"
    local ACK = TAG .. "K"
    local ok, LinkBattle2 = pcall(require, "src.link.LinkBattle2")
    NativePvp.LinkBattle2 = ok and type(LinkBattle2) == "table" and LinkBattle2 or nil
    NativePvp.available = isGen2 and NativePvp.LinkBattle2 ~= nil
      and type(NativePvp.LinkBattle2.newHost) == "function"
    local function endsWith(s, suffix)
      return type(s) == "string" and #s >= #suffix and s:sub(-#suffix) == suffix
    end
    -- the room a challenger offers
    function NativePvp.offerRoom(roomId)
      return NativePvp.available and (roomId .. TAG) or roomId
    end
    -- the room an accepting client answers on
    function NativePvp.acceptRoom(roomId)
      if NativePvp.available and endsWith(roomId, TAG) then return roomId .. "K" end
      return roomId
    end
    -- did both sides agree on the native battle for this room
    function NativePvp.negotiated(roomId)
      return NativePvp.available and endsWith(roomId, ACK)
    end
  end

  -- =========================================================================
  -- ASYNCHRONOUS JOB SYSTEM (Replacement for Lua Threading)
  -- Coordinates non-blocking network polling and overworld remote player placement
  -- while keeping host player movement and menu navigation 100% local.
  -- =========================================================================
  local Jobs = {
    registry = {},
    nextId = 1
  }

  function Jobs.submit(name, stepFn, cancelFn, persist)
    local id = Jobs.nextId
    Jobs.nextId = Jobs.nextId + 1
    local job = {
      id = id,
      name = name or "task",
      status = "running",
      step = stepFn,
      cancel = cancelFn,
      persist = (persist ~= false),
      createdAt = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
    }
    Jobs.registry[id] = job
    return id
  end

  function Jobs.poll(id)
    return Jobs.registry[id] or { status = "error", err = "unknown job" }
  end

  function Jobs.cancel(id)
    local job = Jobs.registry[id]
    if job and job.status == "running" then
      job.status = "cancelled"
      if job.cancel then pcall(job.cancel, job) end
    end
  end

  function Jobs.step(game, dt)
    dt = dt or (1 / 60)
    for id, job in pairs(Jobs.registry) do
      if job.status == "running" and job.step then
        local ok, res = pcall(job.step, job, game, dt)
        if not ok then
          job.status = "error"
          job.err = tostring(res)
        elseif res == "done" then
          job.status = "done"
        end
      end
      if (job.status == "done" or job.status == "cancelled" or job.status == "error") and not job.persist then
        Jobs.registry[id] = nil
      end
    end
  end

  -- NOTE: Battle responses are drained by GtsNetAdapter:update() directly, not here.
  --       This function only handles position-sync and challenge/trade signals.
  processGlobalThreadMessages = function(game)
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()

    -- Feed the non-blocking persistent HTTP client (coalescing sync_pos to avoid bufferbloat)
    -- so position syncs stay real-time without building a multi-second backlog over the tunnel.
    if netOutChannel then
      while true do
        local req = netOutChannel:pop()
        if not (req and req.url) then break end
        if req.body then
          local okDec, decoded = pcall(Json.decode, req.body)
          if okDec and type(decoded) == "table" then
            decoded.modVersion = MOD_VERSION
            decoded.version = MOD_VERSION
            local gName, rVer = getClientVersionInfo()
            decoded.gameVersion = gName
            decoded.recompVersion = rVer
            decoded.generation = isGen2 and 2 or 1
            req.body = Json.encode(decoded)

            if decoded.action == "sync_pos" then
              -- Coalesce: if a sync_pos is already waiting in asyncPending, update it with
              -- the latest position in place rather than stacking up behind older requests!
              local replaced = false
              for i = #asyncPending, 1, -1 do
                local pReq = asyncPending[i]
                if pReq and pReq.body and pReq.body:find('"action"%s*:%s*"sync_pos"') then
                  req.resp = {}
                  asyncPending[i] = req
                  replaced = true
                  break
                end
              end
              if not replaced then
                req.resp = {}
                asyncPending[#asyncPending + 1] = req
              end
            else
              req.resp = {}
              asyncPending[#asyncPending + 1] = req
            end
          else
            req.resp = {}
            asyncPending[#asyncPending + 1] = req
          end
        else
          req.resp = {}
          asyncPending[#asyncPending + 1] = req
        end
      end
      -- Cap the queue generously: PVP battle messages share this queue, and
      -- dropping them would deadlock the lockstep battle exchange.
      while #asyncPending > 30 do
        table.remove(asyncPending, 1)
      end
    end

    -- Advance the non-blocking engine here AND every frame in core.update.
    -- Local-first: this path never blocks the game loop. Safety net: if the
    -- engine has not delivered a response in ~8s it is not reaching the server,
    -- so send ONE sync synchronously (throttled to every 8s) to keep the player
    -- on the server and refresh remote players. This only fires while the
    -- smooth path is failing, and a brief block every 8s beats losing
    -- visibility. The engine is NOT reset, so it keeps trying and seamlessly
    -- takes back over the moment it delivers.
    if #asyncPending > 0 then
      asyncPoll()
      -- The synchronous fallback must never fire mid-battle: it blocks the
      -- main thread (fresh connection + handshake) which would freeze the PVP
      -- lockstep. During a battle the async path is the only transport.
      if not inBattle and (now - asyncLastSuccess) > 8.0 and (now - lastFallbackTime) >= 8.0 then
        lastFallbackTime = now
        local req = table.remove(asyncPending, 1)
        if req then
          local resp = {}
          local sent = false
          local ok = makeHttpRequest({
            url = req.url,
            method = "POST",
            timeout = 8.0,
            headers = {
              ["Content-Type"] = "application/json",
              ["Content-Length"] = tostring(#(req.body or "")),
              ["X-Mod-Version"] = MOD_VERSION
            },
            source = function()
              if not sent then sent = true; return req.body end
              return nil
            end,
            sink = function(chunk) if chunk then table.insert(resp, chunk) end return 1 end
          })
          if ok and #resp > 0 and netInChannel then
            netInChannel:push(table.concat(resp))
          end
        end
      end
    end

    -- Diagnostic: while the async engine is failing, write its state to a file
    -- every ~5s so the exact failure point can be reported.
    if asyncDiagTime == 0 or now - asyncDiagTime >= 5.0 then
      asyncDiagTime = now
      if (now - asyncLastSuccess) > 5.0 and asyncLastError ~= "" then
        diag("async state=%s lastError=%s lastSuccessAge=%ds pending=%d active=%s sock=%s",
          tostring(asyncState), tostring(asyncLastError),
          math.floor(now - asyncLastSuccess), #asyncPending,
          asyncActive and "yes" or "no", asyncSock and "yes" or "no")
      end
    end
    -- Drain ALL queued position-sync responses (drain-all prevents stale challenge
    -- data from sitting in netInChannel across multiple frames and firing after the
    -- battle ends when the inBattle / cooldown guards are no longer active).
    if not netInChannel then return end

    local respStr = netInChannel:pop()
    while respStr do
      local ok, res = pcall(Json.decode, respStr)
      if ok and type(res) == "table" then
        if res.error == "VERSION_MISMATCH" then
          handleDisconnect(game, string.format("VERSION MISMATCH!\nSERVER IS ON V%s\nCLIENT IS ON V%s\nPLEASE UPDATE MOD!", res.serverVersion or "NEW", MOD_VERSION))
          return
        elseif res.error == "ALREADY_LOGGED_IN" or res.error == "BANNED" then
          handleDisconnect(game, (res.message or "ACCOUNT ALREADY ACTIVE ON ANOTHER DEVICE!\nDISCONNECTED FOR SAFETY."))
          return
        elseif res.error == "WRONG_GENERATION" then
          handleDisconnect(game, GtsUI.wrongWorldText(res.serverGeneration))
          return
        end

        if res.success then
          -- Party invite receiver
          if res.partyInvite and not pendingPartyInvite and not activeParty then
            pendingPartyInvite = res.partyInvite
            local inv = res.partyInvite
            local tid, tName = getTrainerInfo(game.save)
                        local pMenu = {
              {
                label = "ACCEPT INVITE",
                onSelect = function()
                    local gWorld = getWorld(game)
                    local curMap = (gWorld and gWorld.map and gWorld.map.id) or defaultStartingOutdoor
                    local curX = (gWorld and gWorld.player and gWorld.player.cellX) or defaultStartingOutdoorX
                    local curY = (gWorld and gWorld.player and gWorld.player.cellY) or defaultStartingOutdoorY
                    local aRes = gtsApiPost({
                      action = "party_accept",
                      trainerId = tid,
                      name = tName,
                      level = mmoLevel or 1,
                      map = curMap,
                      x = curX,
                      y = curY,
                      spriteId = localSelectedSprite
                    }, 1.5)
                    if aRes and aRes.success then
                      activeParty = aRes.party
                      pendingPartyInvite = nil
                      game.stack:push(TextBox.new(game, wrapText("JOINED CO-OP PARTY!\nYOU CAN NOW WARP TO YOUR PARTY MEMBERS!")))
                    else
                      pendingPartyInvite = nil
                      game.stack:push(TextBox.new(game, wrapText("COULD NOT JOIN PARTY!")))
                    end
                  end
                },
                {
                  label = "DECLINE",
                  onSelect = function()
                    gtsApiPost({ action = "party_decline", trainerId = tid }, 1.0)
                    pendingPartyInvite = nil
                  end
                }
              }
              local invMsg = string.format("%s INVITED YOU TO A CO-OP PARTY!\nACCEPT INVITE?", inv.fromName or "A TRAINER")
              game.stack:push(TextBox.new(game, wrapText(invMsg), function()
                game.stack:push(Menu.new(game, pMenu, { tx = 0, ty = 0, tw = 20, maxVisible = 6, startCloses = true }))
              end))
            end

            -- Shared Party XP receiver
            if res.partyXp and #res.partyXp > 0 then
              for _, xev in ipairs(res.partyXp) do
                addMmoXp(game, "party_share", xev.xp or 50)
                game.stack:push(TextBox.new(game, wrapText(string.format("PARTY CO-OP BONUS!\n+%d XP FROM %s!", xev.xp or 50, xev.fromName or "TEAMMATE"))))
              end
            end

            if res.party ~= nil then
              activeParty = res.party
            end
            -- Synchronize RTC Clock with Server
            if isGen2 and res.serverHour and res.serverMinute and res.serverWeekday and game and game.save then
              local okClock, Clock = pcall(require, "src.core.gen2.Clock")
              if okClock and Clock and Clock.setTime and Clock.setWeekday then
                Clock.setTime(game.save, res.serverHour, res.serverMinute)
                Clock.setWeekday(game.save, res.serverWeekday)
              end
            end

            -- Synchronize Real-Time Global Chat Messages
            if res.chat and type(res.chat) == "table" and #res.chat > 0 then
              handleNewChatMessages(game, res.chat)
            end

            -- 1. Route multi-player positions if overworld active
            local gWorld = getWorld(game)
            if res.players and gWorld then
              syncMultiNetPlayers(game, gWorld, res.players)
            end

          -- 2. Live Network Challenge Receiver (PVP Battle or Trade Popup!)
          if res.challenge then
            local nowT = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
            local inCooldown = (nowT - lastBattleEndTime) < 5.0

            if inCooldown then
              -- Post-battle cooldown: silently wipe stale challenges from the server
              -- so they stop appearing on every sync_pos response.
              local myId = getTrainerInfo(game.save)
              if myId then
                gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
              end
            else
              local challengerName = res.challenge.fromName or "TRAINER"
              local challengerId = res.challenge.fromId
              local cType = res.challenge.type or "PVP"
              local remotePartyPacked = res.challenge.party or {}
              local sharedSeed = res.challenge.seed or 12345
              local roomId = res.challenge.roomId

              if cType == "ACCEPT_PVP" then
                -- Guard: never start a second battle if one is already running
                if inBattle then
                  local myId = getTrainerInfo(game.save)
                  gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                else
                  isWaitingForChallenge = false
                  local myId = getTrainerInfo(game.save)
                  gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)

                  if not game.save or not game.save.party or #game.save.party == 0 then
                    game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
                  elseif not remotePartyPacked or #remotePartyPacked == 0 then
                    game.stack:push(TextBox.new(game, wrapText(string.format("%s HAS NO POKéMON IN THEIR PARTY!", challengerName or "FOE"))))
                  else
                    -- the battle starts as the message closes; pushed the
                    -- other way round, it sat under the battle and only
                    -- showed once the fight was over
                    game.stack:push(TextBox.new(game, "CHALLENGE ACCEPTED!\nSTARTING PVP BATTLE!", function()
                      startPvpBattle(game, challengerName, challengerId, remotePartyPacked, true, sharedSeed, roomId)
                    end))
                  end
                end
              elseif cType == "ACCEPT_TRADE" then
                isWaitingForChallenge = false
                local myId = getTrainerInfo(game.save)
                gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                if not game.save or not game.save.party or #game.save.party == 0 then
                  game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO TRADE!")))
                else
                  game.stack:push(TextBox.new(game, wrapText("OFFER ACCEPTED! STARTING LINK TRADE!")))
                  startLinkTrade(game, challengerName, challengerId, false, roomId)
                end
              elseif cType == "DECLINE" then
                isWaitingForChallenge = false
                local myId = getTrainerInfo(game.save)
                gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                game.stack:push(TextBox.new(game, wrapText("CHALLENGE DECLINED BY OPPONENT.")))
              elseif cType == "PVP" or cType == "TRADE" then
                local myId, myName = getTrainerInfo(game.save)
                local promptItems = {
                  {
                    label = string.format("ACCEPT %s", cType),
                    onSelect = function()
                      gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                      local myPackedParty = packPartyForGame(game, game.save and game.save.party or {})
                      if cType == "PVP" then
                        if not game.save or not game.save.party or #game.save.party == 0 then
                          game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
                          return
                        end
                        if not remotePartyPacked or #remotePartyPacked == 0 then
                          game.stack:push(TextBox.new(game, wrapText(string.format("%s HAS NO POKéMON IN THEIR PARTY!", challengerName or "FOE"))))
                          return
                        end
                        -- answered on the native room when both sides have it
                        local battleRoom = NativePvp.acceptRoom(roomId)
                        gtsApiPost({
                          action = "send_challenge",
                          targetId = challengerId,
                          fromId = myId,
                          fromName = myName,
                          challengeType = "ACCEPT_PVP",
                          party = myPackedParty,
                          seed = sharedSeed,
                          roomId = battleRoom
                        }, 1.5)
                        startPvpBattle(game, challengerName, challengerId, remotePartyPacked, false, sharedSeed, battleRoom)
                      elseif cType == "TRADE" then
                        if not game.save or not game.save.party or #game.save.party == 0 then
                          game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO TRADE!")))
                          return
                        end
                        gtsApiPost({
                          action = "send_challenge",
                          targetId = challengerId,
                          fromId = myId,
                          fromName = myName,
                          challengeType = "ACCEPT_TRADE",
                          roomId = roomId
                        }, 1.5)
                        startLinkTrade(game, challengerName, challengerId, true, roomId)
                      end
                    end
                  },
                  {
                    label = "DECLINE",
                    onSelect = function()
                      gtsApiPost({ action = "clear_challenge", trainerId = myId }, 0.5)
                      gtsApiPost({
                        action = "send_challenge",
                        targetId = challengerId,
                        fromId = myId,
                        fromName = myName,
                        challengeType = "DECLINE"
                      }, 0.5)
                    end
                  }
                }
                game.stack:push(Menu.new(game, promptItems, { tx = 1, ty = 1, tw = 18, th = 6 }))
              end
            end -- end cooldown else
          end -- end if res.challenge
        end -- end if res.success
      end -- end if ok and res
      respStr = netInChannel:pop()
    end
  end

  -- Sync GTS Database with 24/7 Server
  local function fetchGtsServerSync(trainerId)
    local data = gtsApiGet("/gts/browse", 3.0)
    if data and data.success then
      isGtsServerConnected = true
      gtsDb.listings = data.listings or {}
      gtsDb.history = data.history or {}

      if trainerId then
        -- the 10-listing cap counts what the server holds, not this session
        local mine = 0
        for _, listing in pairs(gtsDb.listings) do
          if tostring(listing.trainerId) == tostring(trainerId) then mine = mine + 1 end
        end
        gtsDb.user_counts[tostring(trainerId)] = mine
        local claimData = gtsApiGet("/gts/claims?trainerId=" .. tostring(trainerId), 3.0)
        if claimData and claimData.success then
          gtsDb.claim_boxes[tostring(trainerId)] = claimData.claims or {}
        end
      end
      return true
    end
    return false
  end

  -- Patch SPRITE_RED with walker = true for 3D Voxel camera while preserving GBC color palette
  pcall(function()
    mod.content.sprites:patch("SPRITE_RED", {
      walker = true,
    })
  end)

  local activeQuestsCache = {}

  local function fetchPlayerQuests(game)
    game = game or Game
    local tid = getTrainerInfo and getTrainerInfo(game and game.save) or "100001"
    local data = gtsApiPost({ action = "get_quests", trainerId = tid }, 1.5)
    if data and data.success and data.quests then
      activeQuestsCache = data.quests
      return activeQuestsCache
    end
    return activeQuestsCache or {}
  end

  local function getTrainerId(save)
    local tid, tName = getTrainerInfo(save)
    return tid
  end

  -- Trainer ID & Name Helper
  getTrainerInfo = function(save)
    local p = save and save.player
    if not p then return 12345, "TRAINER" end
    if not p.id then
      -- IMPORTANT: plain math.random() is NOT auto-seeded by Lua/LOVE, so two
      -- players who each roll their very first trainer ID around the same
      -- point in their own process's (identical, unseeded) random sequence
      -- can end up with the SAME id. Since the server keys active_players by
      -- trainerId, a collision means one player's sync_pos overwrites the
      -- other's entry, and each of them filters out anything matching "self"
      -- -- which now also matches the other player -- making them invisible
      -- to each other. love.math's RNG is auto-seeded per-process (time+PID)
      -- by LOVE itself, so it doesn't collide across separate machines.
      math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000000))
      p.id = math.random(10000, 99999)
    end
    return p.id, p.name or "TRAINER"
  end

  -- Calculate Total Owned Badges from Save
  -- Calculate Total Owned Badges from Save
  -- Crystal keeps Johto/Kanto badges under save.player and the dex under
  -- pokedex.caught; Save.summary is the engine's own count of both.
  local function getBadgeCount(save)
    if not save then return 0 end
    if isGen2 then
      local okSave, Gen2Save = pcall(require, "src.core.gen2.Save")
      local summary = okSave and Gen2Save.summary and Gen2Save.summary(save)
      return (summary and summary.badges) or 0
    end
    if not save.badges then return 0 end
    local count = 0
    for _, b in pairs(save.badges) do
      if b then count = count + 1 end
    end
    return count
  end

  -- Calculate Total Pokédex Caught from Save
  local function getPokedexCount(save)
    if not save then return 0 end
    if isGen2 then
      local okSave, Gen2Save = pcall(require, "src.core.gen2.Save")
      local summary = okSave and Gen2Save.summary and Gen2Save.summary(save)
      return (summary and summary.caught) or 0
    end
    if not save.pokedex or not save.pokedex.owned then return 0 end
    local count = 0
    for _, owned in pairs(save.pokedex.owned) do
      if owned then count = count + 1 end
    end
    return count
  end

  -- Dual Save State Storage: the online character's save lives apart from the
  -- game's own save (storageRead/storageWrite "online_save", above).
  local offlineSaveBackup = nil

  local function loadOfflineSave()
    if isGen2 then
      local okGen2Save, Gen2SaveModule = pcall(require, "src.core.gen2.Save")
      if okGen2Save and Gen2SaveModule and Gen2SaveModule.load then
        local data = Gen2SaveModule.load("crystal")
        if data then return data end
      end
    end
    local okSaveData, SaveDataModule = pcall(require, "src.core.SaveData")
    if okSaveData and SaveDataModule and SaveDataModule.load then
      local data = SaveDataModule.load()
      if data then return data end
    end
    return nil
  end

  loadServerUrl()

  loadOnlineSave = function(game)
    local save = storageRead("online_save")
    if save and type(save) == "table" and save.onlineAccount and save.onlineAccount.token then
      return save
    end
    local acc = storageRead("online_account")
    if acc and type(acc) == "table" and acc.token then
      -- an account with no online save yet starts from a COPY of the current
      -- progress; the offline save table itself never goes online
      local curSave = (game and game.save) or (Game and Game.save) or {}
      local Serializer = require("src.core.SaveSerializer")
      local okCopy, copy = pcall(function() return Serializer.decode(Serializer.encode(curSave)) end)
      if okCopy and type(copy) == "table" then curSave = copy end
      curSave.onlineAccount = acc
      return curSave
    end
    if game and game.save and game.save.onlineAccount and game.save.onlineAccount.token then
      return game.save
    end
    return nil
  end

  writeOnlineSave = function(saveTable)
    -- ALWAYS fold the live world state in first: game.save.events, mapScenes,
    -- variableSprites, scriptMem, playerState and backupWarp are only written
    -- into the save by Game2:snapshotSave(). Writing game.save without it
    -- persists stale/empty flag tables, which is what softlocks the overworld
    -- (Rival stuck outside Elm's Lab, Route 30/32 blockers never moving).
    if currentGame and currentGame.snapshotSave then
      pcall(function() currentGame:snapshotSave() end)
    end
    if currentGame and currentGame.save and type(currentGame.save) == "table" then
      -- Write the authoritative snapshotted live save so flags/mapScenes are
      -- never lost even if the caller handed us a stale or copied table.
      saveTable = currentGame.save
    end
    if not saveTable or type(saveTable) ~= "table" then return false end
    -- Normalized the way the engine's own Save.save normalizes, so the online
    -- save reloads through Game2:adoptSave like a normal one.
    if isGen2 then
      local okSave, Gen2Save = pcall(require, "src.core.gen2.Save")
      if okSave and Gen2Save and Gen2Save.normalize then pcall(Gen2Save.normalize, saveTable) end
    end
    saveTable.savedAt = os.time()
    local written = storageWrite("online_save", saveTable)
    if saveTable.onlineAccount then
      storageWrite("online_account", saveTable.onlineAccount)
    end
    if not written then diag("online save could not be written") end
    return written
  end

  -- Global Save Guards: Intercept all Start Menu and in-game saves while online
  -- 1. Gen 1 SaveData.save Guard
  local okSaveData, SaveDataModule = pcall(require, "src.core.SaveData")
  if okSaveData and SaveDataModule and SaveDataModule.save then
    local origSaveDataSave = SaveDataModule.save
    SaveDataModule.save = function(data, mods)
      if isGtsServerConnected or (data and data.onlineAccount and data.onlineAccount.token) then
        saveOnlineAccount(data)
        return writeOnlineSave(data)
      end
      return origSaveDataSave(data, mods)
    end
  end

  -- 2. Gen 2 / Gold Save.save Guard (the sandbox refuses Gen 2 modules on Gen 1)
  local okGen2Save, Gen2SaveModule = false, nil
  if isGen2 then okGen2Save, Gen2SaveModule = pcall(require, "src.core.gen2.Save") end
  if okGen2Save and Gen2SaveModule and Gen2SaveModule.save then
    local origGen2Save = Gen2SaveModule.save
    Gen2SaveModule.save = function(save)
      if isGtsServerConnected or (save and save.onlineAccount and save.onlineAccount.token) then
        saveOnlineAccount(save)
        return writeOnlineSave(save)
      end
      return origGen2Save(save)
    end
  end

  -- Forced Game Save helper (Captures live coordinates & routes strictly to save_online when online)
  performForcedSave = function(game)
    if not game or not game.save then return end
    if not isGtsServerConnected then
      -- Offline saves are written explicitly by in-game Save menu, never forced on every event
      return
    end
    if game.snapshotSave then
      pcall(function() game:snapshotSave() end)
    elseif game.overworld and game.overworld.captureSave then
      pcall(function() game.overworld:captureSave(game.save) end)
    end
    saveOnlineAccount(game.save)
    writeOnlineSave(game.save)
  end

  -- Sync Local Trainer Profile & Online Account to Server
  loadOnlineAccount = function(save)
    -- Online only: offline these touched the OFFLINE save (renaming its
    -- player, stamping the account token that diverts its SAVE into the
    -- online file) and made blocking server calls on every flag/battle.
    if not isGtsServerConnected then return nil end
    local acc = storageRead("online_account")
    if not acc and save and save.onlineAccount and save.onlineAccount.token then
      acc = save.onlineAccount
    end
    if acc and type(acc) == "table" then
      if save then save.onlineAccount = acc end
      if acc.name and save and save.player then save.player.name = acc.name end
      if acc.trainerId and save and save.player then save.player.id = acc.trainerId end
      mmoLevel = tonumber(acc.level) or 1
      mmoXp = tonumber(acc.xp) or 0
      mmoToken = acc.token or nil
      localSelectedSprite = acc.spriteId or (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
      if acc.title then localTrainerTitle = acc.title end
      if acc.favoriteMon then localFavoriteMon = acc.favoriteMon end
      return acc
    end
    return nil
  end

  saveOnlineAccount = function(save)
    -- Online only: offline these touched the OFFLINE save (renaming its
    -- player, stamping the account token that diverts its SAVE into the
    -- online file) and made blocking server calls on every flag/battle.
    if not isGtsServerConnected then return nil end
    if not save then return end
    save.onlineAccount = save.onlineAccount or {}
    save.onlineAccount.trainerId = (save.player and save.player.id) or save.onlineAccount.trainerId or "100001"
    save.onlineAccount.name = (save.player and save.player.name) or save.onlineAccount.name or "CRYSTAL"
    save.onlineAccount.level = mmoLevel or 1
    save.onlineAccount.xp = mmoXp or 0
    save.onlineAccount.token = mmoToken or save.onlineAccount.token
    save.onlineAccount.spriteId = localSelectedSprite or (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
    save.onlineAccount.title = localTrainerTitle or "ACE TRAINER"
    save.onlineAccount.favoriteMon = localFavoriteMon or "PIKACHU"
    storageWrite("online_account", save.onlineAccount)
  end

  syncLocalProfile = function(game, winDelta)
    -- Online only: offline these touched the OFFLINE save (renaming its
    -- player, stamping the account token that diverts its SAVE into the
    -- online file) and made blocking server calls on every flag/battle.
    if not isGtsServerConnected then return nil end
    if not game or not game.save then return end
    loadOnlineAccount(game.save)
    local trainerId, trainerName = getTrainerInfo(game.save)
    gtsApiPost({
      action = "update_profile",
      trainerId = trainerId,
      token = mmoToken,
      name = trainerName,
      title = localTrainerTitle,
      spriteId = localSelectedSprite,
      badges = getBadgeCount(game.save),
      pokedexCount = getPokedexCount(game.save),
      pvpWins = winDelta or 0,
      blackouts = (game.save and game.save.blackoutCount) or 0,
      favoriteMon = localFavoriteMon
    }, 1.5)
  end

  addMmoXp = function(game, xpType, extraAmount, extraFields)
    -- Online only: offline these touched the OFFLINE save (renaming its
    -- player, stamping the account token that diverts its SAVE into the
    -- online file) and made blocking server calls on every flag/battle.
    if not isGtsServerConnected then return nil end
    local rewards = {
      catch = 50,
      wild_battle = 15,
      trainer_battle = 40,
      pvp_win = 100,
      pvp_loss = 25,
      breeding = 60
    }
    local delta = extraAmount or rewards[xpType] or 10
    local oldLevel = mmoLevel
    mmoXp = mmoXp + delta
    mmoLevel = calculateLevelFromXp(mmoXp)

    if game and game.save then
      saveOnlineAccount(game.save)
      performForcedSave(game)

      local tid, tName = getTrainerInfo(game.save)
      local payload = {
        action = "sync_xp",
        trainerId = tid,
        token = mmoToken,
        xpType = xpType,
        -- the amount awarded here, so the server's total matches this one
        xp = delta,
        badges = getBadgeCount(game.save),
        pokedexCount = getPokedexCount(game.save)
      }
      if extraFields then
        for k, v in pairs(extraFields) do payload[k] = v end
      end
      gtsApiPost(payload, 1.5)

      if mmoLevel > oldLevel then
        local Sound = require("src.core.Sound")
        pcall(function() Sound.play(game.data, "Level_Up") end)
        game.stack:push(TextBox.new(game, wrapText(string.format("LEVEL UP!\nREACHED MMO LEVEL %d!", mmoLevel))))
      end
    end
  end

  -- LAUNCH NATIVE LOCKSTEP GEN 1 LINK BATTLES (LinkBattle.newHost / LinkBattle.newGuest)
  startPvpBattle = function(game, opponentName, opponentId, remotePartyPacked, isHostPlayer, seed, roomId)
    if inBattle then return end  -- Double-start guard
    if not game or not game.save or not game.save.party or #game.save.party == 0 then
      inBattle = false
      game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
      return
    end
    if not remotePartyPacked or #remotePartyPacked == 0 then
      inBattle = false
      game.stack:push(TextBox.new(game, wrapText(string.format("%s HAS NO POKéMON IN THEIR PARTY!", opponentName or "FOE"))))
      return
    end

    if isGen2 then
      local okNet, PvpNet = pcall(requireLocal, "pvp/net.lua")
      if not okNet then
        inBattle = false
        game.stack:push(TextBox.new(game, wrapText("PVP MODULE FAILED TO LOAD.")))
        return
      end
      local trainerId, myName = getTrainerInfo(game.save)

      -- Shared by both backends: the battle screen is already off the stack.
      local function finishPvp(outcome, session)
        pcall(function()
          local Music = require("src.core.Music")
          if Music and Music.restoreMap then Music.restoreMap(game.data) end
        end)
        inBattle = false
        activeBattleAdapter = nil
        if session then pcall(function() session:close() end) end
        if netInChannel then while netInChannel:pop() do end end
        isWaitingForChallenge = false
        lastBattleEndTime = (_G.love and _G.love.timer and _G.love.timer.getTime)
                              and _G.love.timer.getTime() or os.time()
        -- Non-blocking room/challenge cleanup (never freeze on the end screen).
        pvpBattleSend({ action = "clear_challenge", trainerId = trainerId })
        pvpBattleSend({ action = "clear_challenge", trainerId = opponentId })
        pvpBattleSend({ action = "clear_battle_room", roomId = roomId })
        local extra = { opponentName = opponentName or "TRAINER", opponentId = opponentId or "0" }
        if outcome == "win" then
          addMmoXp(game, "pvp_win", nil, extra)
          syncLocalProfile(game, 1)
          performForcedSave(game)
        elseif outcome then
          addMmoXp(game, "pvp_loss", nil, extra)
          performForcedSave(game)
        end
      end

      -- Native lockstep battle (both clients negotiated it on the room id).
      if NativePvp.negotiated(roomId) then
        local net = PvpNet.new({
          send = pvpBattleSend,
          myId = trainerId,
          theirId = opponentId,
          roomId = roomId,
        })
        local opts = {
          myParty = packPartyForGame(game, game.save.party),
          theirParty = remotePartyPacked,
          theirName = opponentName or "FOE",
          seed = seed or 12345,
          verdict = "full",
          strict = true,
        }
        local screen, why
        if isHostPlayer then
          screen, why = NativePvp.LinkBattle2.newHost(game, net, opts)
        else
          screen, why = NativePvp.LinkBattle2.newGuest(game, net, opts)
        end
        if not screen then
          net:close()
          game.stack:push(TextBox.new(game, wrapText(tostring(why or "PVP BATTLE COULD NOT START."))))
          return
        end
        inBattle = true
        -- LinkBattle2 pops its own screen and closes the transport first.
        screen.onFinish = function(result)
          finishPvp(result == "win" and "win" or (result == "lose" and "lose" or "draw"))
        end
        game.stack:push(screen)
        return
      end

      -- Fallback: the mod's own Gen 2 PVP engine (pvp/*), for a peer on an
      -- older client.  Both machines run the same deterministic battle with a
      -- shared seed; actions exchange over the async battle transport.
      local okPvp, PvpEngine = pcall(requireLocal, "pvp/engine.lua")
      local okSess, PvpSession = pcall(requireLocal, "pvp/session.lua")
      local okUi, PvpUi = pcall(requireLocal, "pvp/ui.lua")
      if not (okPvp and okSess and okUi) then
        inBattle = false
        game.stack:push(TextBox.new(game, wrapText("PVP MODULE FAILED TO LOAD.")))
        return
      end

      inBattle = true
      local myParty = PvpEngine.clampParty(game.data, packPartyForGame(game, game.save.party))
      local theirParty = PvpEngine.clampParty(game.data, remotePartyPacked)
      if #myParty == 0 or #theirParty == 0 then
        inBattle = false
        game.stack:push(TextBox.new(game, wrapText("BOTH TRAINERS NEED POKéMON TO BATTLE!")))
        return
      end

      local role = isHostPlayer and "host" or "guest"
      local net = PvpNet.new({
        send = pvpBattleSend,
        myId = trainerId,
        theirId = opponentId,
        roomId = roomId,
      })
      local session = PvpSession.new({ net = net, role = role })
      local battle = PvpEngine.new({
        gameData = game.data,
        save = game.save,
        myParty = myParty,
        theirParty = theirParty,
        myName = myName,
        theirName = opponentName or "FOE",
        theirSpriteId = nil, -- localSelectedSprite/their sprite resolved by the UI
        seed = seed or 12345,
        role = role,
      })

      local ui = PvpUi.new(game, {
        battle = battle,
        save = game.save,
        session = session,
        onDone = function()
          -- Return to the map immediately: never leave the battle screen up
          -- (the vanilla Gen 2 onDone pops the battle state).
          if game and game.stack then
            pcall(function() game.stack:pop() end)
          end
          finishPvp(battle and (battle.outcome == "win" and "win" or "lose"), session)
        end,
      })
      game.stack:push(ui)
      return
    end

    inBattle = true
    local trainerId, myName = getTrainerInfo(game.save)
    local myPackedParty = packPartyForGame(game, game.save.party)

    local netAdapter = GtsNetAdapter.new(trainerId, opponentId, roomId)

    local opts = {
      myParty = myPackedParty,
      theirParty = remotePartyPacked,
      theirName = opponentName or "FOE",
      seed = seed or 12345,
      role = isHostPlayer and "host" or "guest"
    }

    local battle = nil
    if isHostPlayer then
      battle = LinkBattle.newHost(game, netAdapter, opts)
    else
      battle = LinkBattle.newGuest(game, netAdapter, opts)
    end

    if battle then
      -- BattleState:finish runs in phases (it calls itself again after the
      -- evolution check before it closes the screen), so the cleanup below
      -- runs once however often finish is called, and the result is booked
      -- once, from onFinish, after the battle screen has closed.
      local origFinish = battle.finish
      battle.finish = function(self)
        if self.gtsCleanedUp then
          if origFinish then return origFinish(self) end
          return
        end
        self.gtsCleanedUp = true
        inBattle = false
        activeBattleAdapter = nil

        -- FLUSH netInChannel to eliminate any stale ACCEPT_PVP / challenge
        -- responses that the poll loop queued during the battle. Without this,
        -- a stale ACCEPT_PVP fires a new battle the moment battle.finish
        -- clears the inBattle guard.
        if netInChannel then while netInChannel:pop() do end end

        -- Clear challenge state for BOTH players on server so neither
        -- gets auto-prompted for a rematch on next sync_pos.
        local myId = getTrainerInfo(game.save)
        gtsApiPost({ action = "clear_challenge", trainerId = myId    }, 0.5)
        gtsApiPost({ action = "clear_challenge", trainerId = opponentId }, 0.5)
        -- Also clear the room so stale battle messages don't linger
        gtsApiPost({ action = "clear_battle_room", roomId = roomId }, 0.5)

        -- Brief cooldown prevents the overworld from immediately firing
        -- another challenge on the very first sync_pos after returning.
        isWaitingForChallenge = false
        lastBattleEndTime = (_G.love and _G.love.timer and _G.love.timer.getTime)
                              and _G.love.timer.getTime() or os.time()

        if origFinish then origFinish(self) end

        -- Call clear_battle_room a SECOND time after origFinish, because the
        -- engine sends a 'bye' inside origFinish (which we now suppress in
        -- GtsNetAdapter:send, but belt-and-suspenders: clear again in case
        -- anything else lands in the room before the opponent polls).
        gtsApiPost({ action = "clear_battle_room", roomId = roomId }, 0.5)
      end

      local origOnFinish = battle.onFinish
      battle.onFinish = function(result)
        if origOnFinish then origOnFinish(result) end
        if result == "win" then
          addMmoXp(game, "pvp_win", nil, { opponentName = opponentName or "TRAINER", opponentId = opponentId or "0" })
          syncLocalProfile(game, 1)
          performForcedSave(game)
          game.stack:push(TextBox.new(game, string.format("VICTORY!\nDEFEATED %s IN PVP!\n(+100 MMO XP)", opponentName or "TRAINER")))
        else
          addMmoXp(game, "pvp_loss", nil, { opponentName = opponentName or "TRAINER", opponentId = opponentId or "0" })
          performForcedSave(game)
          game.stack:push(TextBox.new(game, string.format("LINK BATTLE FINISHED\nWITH %s!\n(+25 MMO XP)", opponentName or "TRAINER")))
        end
      end

      game.stack:push(battle)
    end
  end

  -- LAUNCH REAL VANILLA LINK TRADE ENGINE WITH CUTSCENE & TRADE EVOLUTIONS
  startLinkTrade = function(game, partnerName, partnerId, isHostPlayer, roomId)
    local myId, myName = getTrainerInfo(game.save)

    if isGen2 then
      -- The engine's LinkState (link cable trade) is Gen 1 only; a Gen 2
      -- (Gold) trade room is not ported yet, so refuse cleanly instead of
      -- crashing once both sides reach the party selection screen.
      game.stack:push(TextBox.new(game, wrapText("LINK TRADES ARE NOT YET SUPPORTED ON CRYSTAL (GEN 2).")))
      return
    end
    -- A trade needs one mon to offer and one to keep.
    if not game.save or not game.save.party or #game.save.party < 2 then
      game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 2 POKéMON IN YOUR PARTY TO TRADE!")))
      return
    end

    local netAdapter = GtsNetAdapter.new(myId, partnerId, roomId)
    local LinkState = require("src.link.LinkState")

    local linkState = LinkState.new(game)
    linkState.net = netAdapter
    linkState.peerName = partnerName or "TRAINER"
    linkState.verdict = "full"
    linkState:startMode("trade", isHostPlayer)

    game.stack:push(linkState)
  end

  -- Remove ONLY the follower NPC for a remote player (keeps the player avatar)
  local function removeNetFollower(ow, tid)
    if not ow then return end
    tid = tostring(tid)

    if netFollowers[tid] then
      local fNpc = netFollowers[tid]
      if ow.npcs then
        for i = #ow.npcs, 1, -1 do
          if ow.npcs[i] == fNpc or (ow.npcs[i] and ow.npcs[i].trainerId == tid and ow.npcs[i].isCoopFollower) then
            table.remove(ow.npcs, i)
          end
        end
      end
      if ow.entities then
        for j = #ow.entities, 1, -1 do
          if ow.entities[j] == fNpc or (ow.entities[j] and ow.entities[j].trainerId == tid and ow.entities[j].isCoopFollower) then
            table.remove(ow.entities, j)
          end
        end
      end
      netFollowers[tid] = nil
    end
  end

  -- CLEAN ENTITY GC HELPER
  local function removeNetPlayer(ow, tid)
    if not ow then return end
    tid = tostring(tid)

    removeNetFollower(ow, tid)

    if netNpcs[tid] then
      local pNpc = netNpcs[tid]
      if ow.npcs then
        for i = #ow.npcs, 1, -1 do
          if ow.npcs[i] == pNpc or (ow.npcs[i] and ow.npcs[i].trainerId == tid and ow.npcs[i].isCoopPlayer) then
            table.remove(ow.npcs, i)
          end
        end
      end
      if ow.entities then
        for j = #ow.entities, 1, -1 do
          if ow.entities[j] == pNpc or (ow.entities[j] and ow.entities[j].trainerId == tid and ow.entities[j].isCoopPlayer) then
            table.remove(ow.entities, j)
          end
        end
      end
      netNpcs[tid] = nil
    end

    netPlayerMap[tid] = nil
  end

  local function clearAllNetPlayers(ow)
    if not ow then return end
    for tid, _ in pairs(netNpcs) do
      removeNetPlayer(ow, tid)
    end
    netNpcs = {}
    mod.exports.netNpcs = netNpcs
    netFollowers = {}
    netPlayerMap = {}
  end

  -- Disconnect Flow
  handleDisconnect = function(game, reason)
    if netSession then
      pcall(function() netSession:close() end)
      netSession = nil
    end
    isHost = false
    roomCode = nil
    activeBattleAdapter = nil
    isWaitingForChallenge = false

    -- 1. Save online progress to save_online.lua before disconnecting
    if isGtsServerConnected and game and game.save then
      writeOnlineSave(game.save)
    end
    isGtsServerConnected = false

    local ow = getWorld(game)
    if ow then
      clearAllNetPlayers(ow)
    end

    -- 2. Restore local offline save from backup or disk (save_gold.lua / save.lua)
    local localSave = offlineSaveBackup or loadOfflineSave()
    if localSave and game then
      game.save = localSave
      if game.adoptSave then game:adoptSave(game.save) end
      -- the live world's flags/scenes follow the restored save, as the
      -- ONLINE menu's DISCONNECT does
      if isGen2 and ow and ow.loadPlayerData then
        pcall(ow.loadPlayerData, ow, game.save)
        if ow.vm then ow.vm.events = ow.events end
      end
      localSelectedSprite = (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
      GtsUI.restorePlayerSprite(game)
      local pMap = (game.save.position and game.save.position.map) or (game.save.player and game.save.player.map) or defaultStartingOutdoor
      local px = (game.save.position and game.save.position.x) or (game.save.player and game.save.player.x) or defaultStartingOutdoorX
      local py = (game.save.position and game.save.position.y) or (game.save.player and game.save.player.y) or defaultStartingOutdoorY
      local pDir = (game.save.position and game.save.position.facing) or (game.save.player and game.save.player.facing) or "down"
      if ow and ow.setMap then
        pcall(function() ow:setMap(pMap, px, py, pDir) end)
      end
    end

    game.stack:push(TextBox.new(game, wrapText(reason or "DISCONNECTED FROM SERVER.\nLOCAL SAVE RESTORED.")))
  end

  -- Immediate server disconnect when the player quits to the title screen
  -- (QUIT in the START menu -> returnToTitle).  Must run BEFORE the engine
  -- tears down the world, so returnToTitle is wrapped on both classes.  This
  -- is a silent session teardown: no "DISCONNECTED" box and no offline-save
  -- restore, because the player is leaving the game entirely, not losing the
  -- connection mid-play.
  local function disconnectOnTitle(game)
    if not isGtsServerConnected then return end
    if _G.__gtsQuitLogout then pcall(function() _G.__gtsQuitLogout(game) end) end
    if netSession then
      pcall(function() netSession:close() end)
      netSession = nil
    end
    isHost = false
    roomCode = nil
    activeBattleAdapter = nil
    isWaitingForChallenge = false
    if game and game.save then
      writeOnlineSave(game.save)
    end
    isGtsServerConnected = false
    local ow = getWorld(game)
    if ow then
      clearAllNetPlayers(ow)
    end
  end

  local okGame2, Game2Mod = false, nil
  if isGen2 then okGame2, Game2Mod = pcall(require, "src.core.Game2") end
  for _, cls in ipairs({ Game, (okGame2 and Game2Mod) or nil }) do
    if cls and cls.returnToTitle then
      local origReturnToTitle = cls.returnToTitle
      cls.returnToTitle = function(self, ...)
        disconnectOnTitle(self)
        return origReturnToTitle(self, ...)
      end
    end
  end

  -- MMO speed lock: while connected every player runs at 1x so the online
  -- world stays in sync.  speedLocked is the engine's own lock on both Game
  -- (Gen 1) and Game2 (link battles and minigames use it): logicSpeed
  -- answers 1 and a fast-forward frame in flight is ended cleanly, and the
  -- player's saved GAME SPEED option is left alone for when they go offline.
  for _, cls in ipairs({ Game, (okGame2 and Game2Mod) or nil }) do
    if cls and cls.speedLocked then
      local origSpeedLocked = cls.speedLocked
      cls.speedLocked = function(self, ...)
        if isGtsServerConnected then return true, "online" end
        return origSpeedLocked(self, ...)
      end
    end
  end

  -- REAL-TIME SMOOTH VECTOR INTERPOLATION & AUTHENTIC TILE-STEP ANIMATION
  -- Gen 1 overworld draw.  Remote players join the overworld's entity list
  -- for the draw only, so the engine draws them like any NPC on every path:
  -- flat (y-sorted, tall-grass feet), tilt (upright billboards) and a render
  -- pipeline, which replaces the whole world image -- the voxel mod builds
  -- its cast from state.entities, and anything drawn after the original
  -- drawWorld would land on a canvas it never shows.  Collision, NPC updates
  -- and scripts never see them.
  function GtsUI.gen1DrawWorld(ow, orig)
    local list = isGtsServerConnected and next(netNpcs) and ow.entities
    local added = nil
    if type(list) == "table" then
      local present = {}
      for _, e in ipairs(list) do present[e] = true end
      for _, pNpc in pairs(netNpcs) do
        if pNpc.sprite and pNpc.px and pNpc.py and not present[pNpc] then
          added = added or {}
          added[pNpc] = true
          list[#list + 1] = pNpc
        end
      end
    end
    local ok, res = pcall(orig, ow)
    if added then
      for i = #list, 1, -1 do
        if added[list[i]] then table.remove(list, i) end
      end
    end
    if not ok then error(res, 0) end
    -- what the HUD tags need: was this frame the flat world canvas?
    local renderer = currentGame and currentGame.renderer
    GtsUI.gen1FlatFrame = not (renderer and renderer.worldOverride)
      and not (GtsUI.tiltActive and GtsUI.tiltActive())
    GtsUI.gen1DrawnAt = love.timer and love.timer.getTime() or 0
    return res
  end

  -- One name tag: a light plate and the name, centred on x with its top at
  -- y, in the current transform's units (font pixels).
  function GtsUI.drawTag(name, x, y)
    name = tostring(name or "TRAINER"):gsub("_", " ")
    local width = Font.width(name)
    x, y = math.floor(x - width / 2), math.floor(y)
    love.graphics.setColor(1, 1, 1, 0.85)
    love.graphics.rectangle("fill", x - 1, y - 1, width + 2, 10)
    love.graphics.setColor(1, 1, 1, 1)
    Font.draw(name, x, y)
  end

  -- Every Gen 1 tag as (name, world px, world py) of its trainer: the
  -- remote players and this player.
  function GtsUI.gen1Tags(ow, fn)
    for tid, pNpc in pairs(netNpcs) do
      if pNpc and pNpc.px and pNpc.py then
        fn((netPlayerMap[tid] or {}).name or pNpc.name, pNpc.px, pNpc.py)
      end
    end
    local p, save = ow and ow.player, Game and Game.save
    if p and p.px and p.py then
      fn((save and save.onlineAccount and save.onlineAccount.name)
        or (save and save.player and save.player.name) or "YOU", p.px, p.py, true)
    end
  end

  if not isGen2 then
    local okTilt, Tilt = pcall(require, "src.render.Tilt")
    if okTilt and type(Tilt) == "table" and Tilt.active then
      GtsUI.tiltActive = function() return Tilt.active() end
    end

    -- Name tags in a render pipeline (voxel): drawn in the pipeline's own
    -- FX pass, anchored with the projection it hands the engine's field
    -- effects (the "!" bubble rides the same one), so they sit inside the
    -- world image, under menus and battles.  Nothing in the pipeline mod
    -- changes; only the engine's ctx gets one more effect.
    local okP, Pipelines = pcall(require, "src.render.Pipelines")
    if okP and type(Pipelines) == "table" and type(Pipelines.drawWorld) == "function" then
      local origPipelineDraw = Pipelines.drawWorld
      Pipelines.drawWorld = function(id, ctx)
        if isGtsServerConnected and type(ctx) == "table" and type(ctx.drawFx) == "function"
            and ctx.state and ctx.state.player then
          local drawFx = ctx.drawFx
          ctx.drawFx = function(project, scale, ...)
            local res = drawFx(project, scale, ...)
            pcall(function()
              -- How big a 16-pixel sprite stands at a point: the on-screen
              -- span of 16 world pixels along both ground axes, whatever the
              -- camera's yaw, pitch and zoom.  Measured at this player's
              -- feet, which the camera follows (the screen centre, where
              -- perspective skews it least), then carried to every other
              -- trainer by the projection's depth ratio.
              local function spanAt(fx, fy, sx)
                local ax = project(fx + 16, fy)
                local bx = project(fx, fy + 16)
                return (ax and bx) and math.sqrt((ax - sx) ^ 2 + (bx - sx) ^ 2) or nil
              end
              local limit = 64 * (scale or 1)
              local me = ctx.state.player
              local mfx, mfy = (me.px or 0) + 8, (me.py or 0) + 16
              local msx, _, mdepth = project(mfx, mfy)
              local w0 = msx and spanAt(mfx, mfy, msx)
              -- first person: the camera stands at this player's feet
              local firstPerson = not w0 or w0 > limit
              GtsUI.gen1Tags(ctx.state, function(name, px, py, isPlayer)
                if isPlayer and firstPerson then return end
                local fx, fy = px + 8, py + 16
                local sx, sy, depth = project(fx, fy)
                if not sx then return end
                local w
                if not firstPerson and tonumber(depth) and tonumber(mdepth) and mdepth > 0 then
                  w = w0 * depth / mdepth
                else
                  w = spanAt(fx, fy, sx) or 16 * (scale or 1)
                end
                if w > limit then return end
                -- one sprite (20 px with its 4 px raise) above the feet; the
                -- text keeps one readable size
                local s = (scale or 1) / 2
                love.graphics.push()
                love.graphics.translate(sx, sy - w * 20 / 16)
                love.graphics.scale(s, s)
                GtsUI.drawTag(name, 0, -16)
                love.graphics.pop()
              end)
            end)
            love.graphics.setColor(1, 1, 1, 1)
            return res
          end
        end
        return origPipelineDraw(id, ctx)
      end
    end

    -- Name tags on the flat world: over the finished frame, at half the
    -- world scale like Crystal's, only while the overworld itself is the
    -- top screen (so never over a menu, a text box or a battle).
    if mod and mod.hooks and mod.hooks.wrap then
      mod.hooks:wrap("render.hud", function(nextFn, game, vp)
        local res = nextFn(game, vp)
        local ow = game and game.overworld
        local renderer = game and game.renderer
        local now = love.timer and love.timer.getTime() or 0
        if isGtsServerConnected and ow and ow.camera and renderer and GtsUI.gen1FlatFrame
            and (now - (GtsUI.gen1DrawnAt or 0)) < 0.1
            and game.stack and game.stack:top() == ow
            and renderer.wipeWox and renderer.wipeSx then
          local cam = ow.camera
          local ox, oy, sx, sy = renderer.wipeWox, renderer.wipeWoy, renderer.wipeSx, renderer.wipeSy
          pcall(function()
            GtsUI.gen1Tags(ow, function(name, px, py)
              love.graphics.push()
              love.graphics.translate(ox + (px + 8 - (cam.x or 0)) * sx, oy + (py - 12 - (cam.y or 0)) * sy)
              love.graphics.scale(sx / 2, sy / 2)
              GtsUI.drawTag(name, 0, 0)
              love.graphics.pop()
            end)
          end)
          love.graphics.setColor(1, 1, 1, 1)
        end
        return res
      end)
    end
  end

  local function updateNpcMovement(npc, dt)
    if not npc or not npc.targetPx or not npc.targetPy then return end

    dt = math.min(dt or 0.01667, 0.05)
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()

    local dx = npc.targetPx - npc.px
    local dy = npc.targetPy - npc.py
    local dist = math.sqrt(dx * dx + dy * dy)

    -- If map changed or wildly out of bounds (> 256 px / 16 tiles), snap cleanly
    if dist > 256 then
      npc.px = npc.targetPx
      npc.py = npc.targetPy
      npc.cellX = npc.targetCellX or math.floor((npc.px + 8) / 16)
      npc.cellY = npc.targetCellY or math.floor((npc.py + 8) / 16)
      npc.x = npc.cellX
      npc.y = npc.cellY
      npc.moving = false
      npc.stillTimer = 0
      npc.stepProgress = 0
      npc.animClock = 0
      npc.facing = npc.targetFacing or npc.facing
      return
    end

    if dist > 0.5 then
      -- Dynamic speed calibrated to Game Boy step rates:
      -- 1X normal walk: 64 px/s (16px in 15 frames = ~250ms per tile).
      -- Catch-up speed: if lagging behind (>16px), scale smoothly up to 120-160 px/s so the gap closes naturally.
      local speed = 64
      if dist > 32 then
        speed = math.min(180, dist * 4.0)
      elseif dist > 16 then
        speed = 96
      end

      local maxStep = speed * dt
      local step = math.min(dist, maxStep)

      -- Smooth 2D normalized translation
      local dirX = dx / dist
      local dirY = dy / dist
      npc.px = npc.px + dirX * step
      npc.py = npc.py + dirY * step

      -- Facing direction: orient along the dominant movement vector
      if math.abs(dx) > math.abs(dy) * 1.1 then
        npc.facing = dx > 0 and "right" or "left"
      elseif math.abs(dy) > math.abs(dx) * 1.1 then
        npc.facing = dy > 0 and "down" or "up"
      elseif npc.targetFacing then
        npc.facing = npc.targetFacing
      end

      npc.cellX = math.floor((npc.px + 8) / 16)
      npc.cellY = math.floor((npc.py + 8) / 16)
      npc.x = npc.cellX
      npc.y = npc.cellY

      npc.moving = true
      npc.stillTimer = 0

      -- Leg step animation: advance animClock smoothly at 60Hz and flip legs every 16px of travel
      npc.animClock = (npc.animClock or 0) + (dt * 60)
      npc.stepProgress = (npc.stepProgress or 0) + step
      if npc.stepProgress >= 16 then
        npc.stepProgress = npc.stepProgress - 16
        npc.stepFlip = not npc.stepFlip
      end
    else
      -- Reached destination waypoint
      npc.px = npc.targetPx
      npc.py = npc.targetPy
      npc.cellX = npc.targetCellX or math.floor((npc.px + 8) / 16)
      npc.cellY = npc.targetCellY or math.floor((npc.py + 8) / 16)
      npc.x = npc.cellX
      npc.y = npc.cellY

      if npc.targetFacing then
        npc.facing = npc.targetFacing
      end

      local timeSincePacket = now - (npc.lastPacketTime or now)

      -- CONTINUOUS DEAD RECKONING (capped to ONE tile per packet):
      -- If the remote player was actively moving on their client (serverMoving
      -- == true), the packet was recent (<0.45s), and we have not already
      -- predicted a tile ahead since the last real packet, predictively step
      -- into the next tile instead of stuttering. The `predicting` flag is
      -- reset by syncMultiNetPlayers whenever a fresh server packet arrives,
      -- so this NEVER chains multiple predicted tiles ahead — which is what
      -- made the sprite walk off the map and then teleport back.
      if npc.serverMoving and timeSincePacket < 0.45 and not npc.predicting then
        npc.predicting = true
        local delta = Collision.DELTA[npc.facing] or { 0, 1 }
        npc.targetPx = npc.px + delta[1] * 16
        npc.targetPy = npc.py + delta[2] * 16
        npc.targetCellX = npc.cellX + delta[1]
        npc.targetCellY = npc.cellY + delta[2]
        npc.moving = true
        npc.stillTimer = 0
        npc.animClock = (npc.animClock or 0) + (dt * 60)
        npc.stepProgress = (npc.stepProgress or 0) + (64 * dt)
        if npc.stepProgress >= 16 then
          npc.stepProgress = npc.stepProgress - 16
          npc.stepFlip = not npc.stepFlip
        end
      else
        -- Remote player is genuinely stationary
        npc.stillTimer = (npc.stillTimer or 0) + dt
        if npc.stillTimer >= 0.05 then
          npc.moving = false
          npc.stepProgress = 0
          npc.animClock = 0
        end
      end
    end
  end

  syncMultiNetPlayers = function(game, ow, playersList)
    if not ow or not ow.map then
      clearAllNetPlayers(ow)
      return
    end

    local activeIds = {}
    local currentMapId = tostring(ow.map.id)
    local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()

    for _, data in ipairs(playersList or {}) do
      local tid = tostring(data.trainerId)
      local remoteMapId = tostring(data.map)

      if remoteMapId:lower() == currentMapId:lower() then
        activeIds[tid] = true
        netPlayerMap[tid] = data

        local facing = data.facing or "down"
        local isMoving = (data.moving == true)
        local destX = tonumber(data.x) or 5
        local destY = tonumber(data.y) or 5

        -- Accept high-res px/py if provided by sender, fallback to cell * 16
        local targetPx = (type(data.px) == "number" and data.px) or (destX * 16)
        local targetPy = (type(data.py) == "number" and data.py) or (destY * 16)

        if not netNpcs[tid] then
          -- Initial spawn position
          local initPx = targetPx
          local initPy = targetPy
          if isMoving and (type(data.px) ~= "number") then
            local delta = Collision.DELTA[facing] or { 0, 1 }
            initPx = (destX - delta[1]) * 16
            initPy = (destY - delta[2]) * 16
          end

          local pNpc = {
            trainerId = tid,
            isCoopPlayer = true,
            passable = true,
            px = initPx,
            py = initPy,
            targetPx = targetPx,
            targetPy = targetPy,
            cellX = math.floor((initPx + 8) / 16),
            cellY = math.floor((initPy + 8) / 16),
            targetCellX = destX,
            targetCellY = destY,
            facing = facing,
            targetFacing = facing,
            serverMoving = isMoving,
            lastPacketTime = now,
            packetInterval = 0.18,
            moveSpeed = 96,
            name = data.name or "TRAINER",
            animClock = 0,
            stepFlip = false,
            moving = isMoving,
            stepProgress = 0,
            stillTimer = 0,
            walkPhase = function(self)
              if not self.moving then return 0 end
              local p = math.floor(self.animClock or 0) % 16
              return (p >= 4 and p < 12) and 1 or 0
            end,
            -- Pose contract shared with the engine's Gen 2 NPC:pose
            -- (src/world/gen2/Npc.lua:523), so a rendering mod's entity pass
            -- (e.g. PotatoVoxel's voxel scene) can stand remote players on
            -- the map like any other character.
            pose = function(self)
              return self.sprite, self.px,
                     self.py + (self.spriteYOffset or 0),
                     self.facing, self:walkPhase(), self.stepFlip, false
            end,
            draw = function(self, camX, camY)
              if self.sprite then
                -- Drawn through drawPeople / entity pass
                self.sprite:draw(
                  self.px, self.py, camX or 0, camY or 0,
                  self.facing, self:walkPhase(), self.stepFlip)
              end
            end
          }

          local chosenRemoteSprite = data.spriteId or (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
          local sprites = ow.sprites or (game and game.data and (game.data.gen2Sprites or game.data.sprites)) or {}
          local spriteDef = sprites[chosenRemoteSprite] or sprites["SPRITE_CHRIS"] or sprites["SPRITE_RED"]
          if spriteDef then
            pNpc.spriteDef = spriteDef
            pNpc.spriteId = spriteDef.id or chosenRemoteSprite
            pNpc.sprite = SpriteRenderer.new(spriteDef, tonumber(tid) or 1)
            if ow.applySpritePalette then
              pcall(ow.applySpritePalette, ow, pNpc)
            end
          end

          -- Write remote-sprite diagnostic once so a missing sprite can be diagnosed
          if not gtsSpriteDiagWritten then
            gtsSpriteDiagWritten = true
            diag("remote sprite tid=%s spriteId=%s created=%s def=%s",
              tostring(tid), tostring(data.spriteId),
              (pNpc.sprite and "yes") or "no", tostring(spriteDef and spriteDef.id))
          end

          netNpcs[tid] = pNpc
        else
          local pNpc = netNpcs[tid]
          local prevTime = pNpc.lastPacketTime or (now - 0.18)
          local interval = now - prevTime
          if interval > 0.05 and interval < 2.0 then
            pNpc.packetInterval = interval
          end
          pNpc.lastPacketTime = now
          pNpc.targetPx = targetPx
          pNpc.targetPy = targetPy
          pNpc.targetCellX = destX
          pNpc.targetCellY = destY
          pNpc.targetFacing = facing
          pNpc.serverMoving = isMoving
          pNpc.predicting = false

          -- If spriteDef changed dynamically (e.g. avatar change), update sprite
          local chosenRemoteSprite = data.spriteId or (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
          if not pNpc.sprite or (pNpc.spriteDef and pNpc.spriteDef.id ~= chosenRemoteSprite) then
            local sprites = ow.sprites or (game and game.data and (game.data.gen2Sprites or game.data.sprites)) or {}
            local spriteDef = sprites[chosenRemoteSprite] or sprites["SPRITE_CHRIS"] or sprites["SPRITE_RED"]
            if spriteDef and (not pNpc.spriteDef or pNpc.spriteDef ~= spriteDef) then
              pNpc.spriteDef = spriteDef
              pNpc.spriteId = spriteDef.id or chosenRemoteSprite
              pNpc.sprite = SpriteRenderer.new(spriteDef, tonumber(tid) or 1)
              if ow.applySpritePalette then pcall(ow.applySpritePalette, ow, pNpc) end
            end
          end
        end
      end
    end

    for tid, pNpc in pairs(netNpcs) do
      if not activeIds[tid] then
        removeNetPlayer(ow, tid)
      end
    end
  end

  -- =========================================================================
  -- OVERWORLD POKEMON FOLLOWER SYSTEM (GEN 2 CRYSTAL)
  -- =========================================================================

  -- Crystal's follower system only.  Gen 1's one follower is Yellow's own
  -- Pikachu (src.world.PikachuFollower), whose spawning, talk and moods are
  -- the game's, so the mod leaves Gen 1 followers alone.
  local FollowerMod = nil
  if isGen2 then
    pcall(function() FollowerMod = require("src.world.gen2.Follower") end)
  end

  local function isMonShiny(mon)
    if not mon then return false end
    if mon.shiny ~= nil then return mon.shiny end
    local dvs = mon.dvs
    if dvs and dvs.defense == 10 and dvs.speed == 10 and dvs.special == 10 then
      local atk = dvs.attack or 0
      if atk == 2 or atk == 3 or atk == 6 or atk == 7 or atk == 10 or atk == 11 or atk == 14 or atk == 15 then
        return true
      end
    end
    return false
  end

  local followerSpriteCache = {}

  local function getFollowerSpriteDef(game, species, isShiny)
    if not species then return nil, nil end
    local spKey = species:lower():gsub("-", "_"):gsub(" ", "_")
    local suffix = isShiny and "_shiny" or ""
    local spriteId = "FOLLOWER_" .. species:upper() .. (isShiny and "_SHINY" or "")

    if followerSpriteCache[spriteId] then
      return followerSpriteCache[spriteId], spriteId
    end

    local sprites = (game and game.data and (game.data.gen2Sprites or game.data.sprites))
    if sprites and sprites[spriteId] then
      followerSpriteCache[spriteId] = sprites[spriteId]
      return sprites[spriteId], spriteId
    end

    -- Converted follower sheets ship inside this mod; the engine loads them by
    -- the mod's own path, whatever its install folder is called.
    local assetPath = nil
    for _, rel in ipairs({
      "assets/followers/" .. spKey .. suffix .. ".png",
      "assets/followers/" .. spKey .. ".png",
      "assets/followers/pikachu.png",
    }) do
      if modFileExists(rel) then
        assetPath = (mod.path or "mods/gen1online-plus") .. "/" .. rel
        break
      end
    end

    -- If no follower asset exists on disk, fallback gracefully to vanilla sprite record
    if not assetPath then
      local fallbackDef = sprites and (sprites["SPRITE_PIKACHU"] or sprites["SPRITE_CHRIS"] or sprites["SPRITE_RED"] or (game.save and game.save.player and game.save.player.spriteDef))
      return fallbackDef, "SPRITE_PIKACHU"
    end

    local def = {
      id = spriteId,
      image = assetPath,
      frames = 6,
      frameWidth = 16,
      frameHeight = 16,
      walker = true,
      trueColor = true,
      anchorX = 8,
      anchorY = 16,
    }

    -- Straight into the live sprite table the world reads: the content
    -- registry only merges at load, and registering here collided with this
    -- very write.
    if sprites then
      sprites[spriteId] = def
    end

    followerSpriteCache[spriteId] = def
    return def, spriteId
  end

  -- Enable follower spawning whenever player has a lead Pokemon
  if FollowerMod and FollowerMod.setShouldSpawn then
    FollowerMod.setShouldSpawn(function(game, world)
      if not game or not game.save or not game.save.party or #game.save.party == 0 then
        return false
      end
      local p = world and world.player
      if p and (p.cycling or p.surfing) then
        return false
      end
      return true
    end)
  end

  -- Update active follower entity to match lead Pokemon (only updates on actual changes)
  local function updatePlayerFollower(game, world)
    if not FollowerMod then return end
    if not game or not game.save or not game.save.party or #game.save.party == 0 then return end
    local leadMon = game.save.party[1]
    if not leadMon or not leadMon.species then return end

    local isShiny = isMonShiny(leadMon)
    local def, spId = getFollowerSpriteDef(game, leadMon.species, isShiny)
    if not def then return end

    if FollowerMod then
      FollowerMod.SPRITE = spId
    end

    local ow = world or getWorld(game)
    if not ow then return end

    local fNpc = FollowerMod and FollowerMod.current and FollowerMod.current(ow)
    if fNpc then
      if fNpc.lastSpecies ~= leadMon.species or fNpc.lastShiny ~= isShiny or not fNpc.sprite then
        fNpc.lastSpecies = leadMon.species
        fNpc.lastShiny = isShiny
        fNpc.spriteDef = def
        fNpc.sprite = SpriteRenderer.new(def, 1)
      end
    end
  end

  -- Follower Interaction: Cry + Companion Dialogs
  if FollowerMod then
    FollowerMod.talk = function(game, world, npc, done)
      local save = game and game.save
      if not save or not save.party or #save.party == 0 then
        if done then done() end
        return false
      end

      local leadMon = save.party[1]
      local def = game.data and game.data.pokemon and game.data.pokemon[leadMon.species]
      local monName = leadMon.nickname or (def and def.name) or leadMon.species

      -- Play Cry
      pcall(function()
        local Sound = require("src.core.Sound")
        if Sound.playCry then
          Sound.playCry(game.data, leadMon.species)
        end
      end)

      local dialogues = {
        string.format("%s is happily\nfollowing you!", monName),
        string.format("%s is nudging your\nleg playfully!", monName),
        string.format("%s looked up at\nyou and smiled!", monName),
        string.format("%s is curious\nabout the area.", monName),
        string.format("%s is filled\nwith energy!", monName),
        string.format("%s gave a cheerful\nand confident nod!", monName),
        string.format("%s is watching\nyour back closely!", monName),
        string.format("%s hopped excitedly\nnext to you!", monName)
      }

      local msg = dialogues[math.random(1, #dialogues)]
      local cb = done or function() end
      game.stack:push(TextBox.new(game, wrapText(msg), cb))
      return true
    end
  end

  -- A press on the follower: a cry and a companion line.  facingObjectCell
  -- answers two coordinates, and the counter rule it applies is the one
  -- npcAt needs.
  pcall(function()
    if not isGen2 then return end -- a Gen 2 engine module
    local World = require("src.world.gen2.World")
    if World and World.interactBody then
      local origInteractBody = World.interactBody
      World.interactBody = function(self)
        if not self:busy() and self.player and not self.player.moving then
          local tx, ty = self:facingObjectCell()
          local npc = tx and self:npcAt(tx, ty)
          if npc and (npc.follower or npc.pikachuFollower) then
            if FollowerMod and FollowerMod.talk then
              -- frozen for the line; World:step releases it once not busy
              self:freezeNpc(npc)
              return FollowerMod.talk(self.game, self, npc)
            end
          end
        end
        return origInteractBody(self)
      end
    end
  end)

  -- PokeEmerald Decomp Asset Status Check & Notification
  local hasCheckedEmeraldAssets = false
  local function checkEmeraldAssetsStartup(game)
    if hasCheckedEmeraldAssets then return end
    if not game or not game.stack or isPlayerBusy(game) then return end
    hasCheckedEmeraldAssets = true

    local samples = {
      "pikachu", "bulbasaur", "charmander", "squirtle",
      "chikorita", "cyndaquil", "totodile",
      "treecko", "torchic", "mudkip", "gengar", "eevee"
    }
    for _, sp in ipairs(samples) do
      if modFileExists("assets/followers/" .. sp .. ".png") then return end
    end
    -- Only the actionable case interrupts play: the sheets ship with the mod,
    -- so this fires when an install is missing them.
    game.stack:push(TextBox.new(game, wrapText(
      "POKEEMERALD ASSETS:\nNOT FOUND (OPTIONAL)\nFOLLOWERS USING FALLBACK\nSEE README_ASSETS.MD")))
  end


  -- Register persistent background jobs for asynchronous MMO coordination

  -- =========================================================================
  -- SERVER-SYNCHRONIZED REAL TIME CLOCK & LOCKOUT HOOKS
  -- Bypasses Oak / Mom clock setup screens and locks debug clock overrides
  -- =========================================================================
  -- Online, the server's clock is authoritative (sync_pos re-anchors the
  -- save's RTC every response), so the clock questions are answered for the
  -- player instead of asked.  Offline both screens stay vanilla.
  pcall(function()
    if not isGen2 then return end -- a Gen 2 engine module
    local InitClock = require("src.ui.gen2.InitClock")
    local Clock = require("src.core.gen2.Clock")
    if InitClock and InitClock.new and Clock then
      local origInitClockNew = InitClock.new
      -- InitClock.new(game, opts): opts.mode "clock" | "day", opts.onDone
      -- (hour, minute) / (day).  The caller pops the screen from onDone.
      InitClock.new = function(game, opts, ...)
        if not isGtsServerConnected or type(opts) ~= "table" then
          return origInitClockNew(game, opts, ...)
        end
        local save = opts.save or (game and game.save)
        local h = tonumber(os.date("%H")) or Clock.DEFAULT_HOUR or 10
        local m = tonumber(os.date("%M")) or 0
        local w = Clock.hostWeekday and Clock.hostWeekday() or 0
        if save and Clock.isSet and Clock.isSet(save) then
          h, m, w = Clock.hour(save), Clock.minute(save), Clock.weekday(save)
        end
        if save then
          if opts.mode ~= "day" and Clock.setTime then Clock.setTime(save, h, m) end
          if Clock.setWeekday then Clock.setWeekday(save, w) end
        end
        -- a one-frame stand-in for the screen, answered on its first update
        local standIn = { isOpaque = false, answered = false }
        function standIn:update()
          if self.answered then return end
          self.answered = true
          if opts.onDone then
            if opts.mode == "day" then opts.onDone(w) else opts.onDone(h, m) end
          end
        end
        function standIn:draw() end
        return standIn
      end
    end
  end)

  pcall(function()
    if not isGen2 then return end -- a Gen 2 engine module
    local Specials = require("src.script.gen2.Specials")
    local Clock = require("src.core.gen2.Clock")
    if Specials and Specials.HANDLERS and Specials.HANDLERS.SetDayOfWeek and Clock then
      local origSetDayOfWeek = Specials.HANDLERS.SetDayOfWeek
      -- Mom's "what day is it?" wheel: online it takes the server-synced day,
      -- the same answer the engine's own no-screen fallback gives.
      Specials.HANDLERS.SetDayOfWeek = function(vm, ...)
        if not isGtsServerConnected then return origSetDayOfWeek(vm, ...) end
        local record = (currentGame and currentGame.save) or (vm and vm.game and vm.game.save)
        if record and Clock.setWeekday then
          local day = (Clock.isSet and Clock.isSet(record) and Clock.weekday(record))
            or (Clock.hostWeekday and Clock.hostWeekday()) or 0
          Clock.setWeekday(record, day)
          record.rtc = record.rtc or {}
          record.rtc.day = tonumber(os.date("%j")) or record.rtc.day
        end
      end
    end
  end)

  Jobs.submit("network_sync", function(job, game, dt)
    processGlobalThreadMessages(game)
  end, nil, true)

  Jobs.submit("overworld_placement", function(job, game, dt)
    local ow = getWorld(game)
    if ow then
      checkEmeraldAssetsStartup(game)
      updatePlayerFollower(game, ow)
      if isGtsServerConnected then
        for _, pNpc in pairs(netNpcs) do updateNpcMovement(pNpc, dt) end
        for _, fNpc in pairs(netFollowers) do updateNpcMovement(fNpc, dt) end
      end
    end
  end, nil, true)

  local function getRankTitle(level, pvpWins)
    level = tonumber(level) or 1
    if level >= 100 then return "POKéMON LEGEND"
    elseif level >= 90 then return "GRAND MASTER"
    elseif level >= 80 then return "CHAMPION"
    elseif level >= 70 then return "ELITE FOUR"
    elseif level >= 60 then return "VETERAN"
    elseif level >= 50 then return "MASTER"
    elseif level >= 40 then return "ACE TRAINER"
    elseif level >= 30 then return "EXPERT"
    elseif level >= 20 then return "TRAINER"
    elseif level >= 10 then return "ROOKIE"
    else return "NOVICE" end
  end

        -- View Detailed Trainer Card UI Screen with Server Rank, Level & Battle Record
  openTrainerCardScreen = function(game, tid, rawData)
    local myTid, myName = getTrainerInfo(game.save)
    local isMe = (not tid) or (tostring(tid) == tostring(myTid))
    local queryTid = isMe and myTid or tid

    local pData = gtsApiGet("/gts/profile?trainerId=" .. tostring(queryTid), 1.5)
    local profile = (pData and pData.success and pData.profile) or {}

    local name = profile.name or (isMe and myName) or (rawData and rawData.name) or "TRAINER"
    local level = tonumber(profile.level or (isMe and mmoLevel) or (rawData and rawData.level) or 1)
    local pvpWins = tonumber(profile.pvpWins or (rawData and rawData.pvpWins) or 0)
    local pvpLosses = tonumber(profile.pvpLosses or 0)
    local gtsTrades = tonumber(profile.gtsTrades or 0)
    local serverRank = tonumber(profile.serverRank or 1)
    local totalPlayers = tonumber(profile.totalPlayers or 1)
    local rank = profile.rank or getRankTitle(level, pvpWins)
    local badges = tonumber(profile.badges or (isMe and getBadgeCount(game.save)) or 0)
    local pokedexCount = tonumber(profile.pokedexCount or (isMe and getPokedexCount(game.save)) or 0)
    local favMon = profile.favoriteMon or (isMe and localFavoriteMon) or "PIKACHU"

    local expVal = tonumber(profile.xp or (isMe and mmoXp) or (rawData and rawData.xp) or 0)
    local nextLvlTarget = calculateXpForLevel(level + 1)
    local expNeeded = (level >= 100) and 0 or math.max(0, nextLvlTarget - expVal)

    if #name > 10 then name = name:sub(1, 10) end
    if #rank > 10 then rank = rank:sub(1, 10) end
    if #favMon > 10 then favMon = favMon:sub(1, 10) end

    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") or input:wasPressed("a") or input:wasPressed("start") then
          game.stack:pop()
        end
      end,
      draw = function(self)
        Font.drawBox(0, 0, 20, 18)
        local hdr = "TRAINER CARD"
        Font.draw(hdr, math.floor((160 - #hdr * 8) / 2), 10)
        Font.draw("==================", 8, 20)
        Font.draw(string.format("NAME: %s", name:sub(1, 12)), 8, 30)
        Font.draw(string.format("LV:%d  ID:%s", level, tostring(queryTid):sub(1,6)), 8, 42)
        Font.draw(string.format("EXP:%d (%d NEED)", expVal, expNeeded), 8, 54)
        Font.draw(string.format("TITLE: %s", rank:sub(1, 11)), 8, 66)
        Font.draw(string.format("RANK: #%d / %d", serverRank, totalPlayers), 8, 78)
        Font.draw(string.format("PVP: %dW / %dL", pvpWins, pvpLosses), 8, 90)
        Font.draw(string.format("BADGES:%d/8 DEX:%d", badges, pokedexCount), 8, 102)
        Font.draw(string.format("FAVORITE: %s", favMon:sub(1, 8)), 8, 114)
        Font.draw("==================", 8, 122)
        Font.draw("A/B: CLOSE", math.floor((160 - 10 * 8) / 2), 128)
      end
    }
    game.stack:push(container)
  end

    -- View Dedicated Level, Experience Points & Next Level Info Screen
  openMmoLevelInfoScreen = function(game)
    local lvl = mmoLevel or 1
    local xp = mmoXp or 0
    local nextLvlXp = calculateXpForLevel(lvl + 1)
    local needed = (lvl >= 100) and 0 or math.max(0, nextLvlXp - xp)
    local trainerId, trainerName = getTrainerInfo(game.save)
    local tNameShort = (trainerName or "RED"):sub(1, 10)

    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") or input:wasPressed("a") or input:wasPressed("start") then
          game.stack:pop()
        end
      end,
      draw = function(self)
        Font.drawBox(0, 0, 20, 18)
        local hdr = "EXP & LEVEL INFO"
        Font.draw(hdr, math.floor((160 - #hdr * 8) / 2), 8)
        Font.draw("==================", 8, 18)
        Font.draw(string.format("PLAYER: %s", tNameShort), 8, 28)
        Font.draw(string.format("ID: %s", tostring(trainerId):sub(1, 10)), 8, 40)
        Font.draw(string.format("LEVEL: %d / 100", lvl), 8, 54)
        Font.draw(string.format("TOTAL EXP: %d", xp), 8, 68)
        if lvl >= 100 then
          Font.draw("STATUS: MAX LEVEL!", 8, 84)
          Font.draw("EXP NEEDED: 0", 8, 98)
        else
          Font.draw(string.format("NEXT: LV%d (%d)", lvl + 1, nextLvlXp), 8, 84)
          Font.draw(string.format("EXP NEED: %d", needed), 8, 98)
        end
        Font.draw("==================", 8, 114)
        Font.draw("A/B: CLOSE", math.floor((160 - 10 * 8) / 2), 126)
      end
    }
    game.stack:push(container)
  end

  -- Helper to add history receipt to GTS
  function GtsUI.addGtsReceipt(text)
    table.insert(gtsDb.history, 1, {
      text = text,
      time = os.time()
    })
    while #gtsDb.history > 50 do
      table.remove(gtsDb.history)
    end
  end

  -- Wire format for a GTS mon.  Crystal mons travel as packMon2, so the held
  -- item, happiness, Pokerus and caught data ride along and stats are rebuilt
  -- with Gen 2 rules on arrival; unpackMon2 also reads the Gen 1-shaped
  -- packets earlier clients deposited (Gen 1 packMon dropped all of that and
  -- unpackMon rebuilt stats with Gen 1 formulas).
  function GtsUI.packMon(mon)
    if isGen2 and Protocol.packMon2 then return Protocol.packMon2(mon) end
    return Protocol.packMon(mon)
  end

  function GtsUI.unpackMon(game, packed)
    if isGen2 and Protocol.unpackMon2 then return Protocol.unpackMon2(game.data, packed) end
    return Protocol.unpackMon(game.data, packed)
  end

  function GtsUI.monLabelName(game, mon)
    return mon.nickname or (game.data and game.data.pokemon and game.data.pokemon[mon.species]
      and game.data.pokemon[mon.species].name) or mon.species or "?"
  end

  -- Helper to get all Pokémon across Party and PC Storage Boxes
  function GtsUI.getAllPlayerMons(game)
    local list = {}
    local save = game and game.save
    if not save then return list end
    local okMail, Mail = false, nil
    if isGen2 then okMail, Mail = pcall(require, "src.core.gen2.Mail") end

    -- An egg is not a tradeable listing, and a mon holding MAIL cannot leave:
    -- its letter lives in a party slot the GTS has no way to carry
    -- (the PC refuses it the same way, src/core/gen2/Boxes.lua).
    local function tradeable(mon)
      if not mon or mon.isEgg then return false end
      if isGen2 and okMail and Mail.monHoldsMail and Mail.monHoldsMail(mon) then return false end
      return true
    end

    if save.party then
      for i, pMon in ipairs(save.party) do
        if tradeable(pMon) then
          table.insert(list, {
            source = "party",
            slotIndex = i,
            mon = pMon,
            label = string.format("%s LV%d (PARTY)", GtsUI.monLabelName(game, pMon):sub(1, 8), pMon.level or 1)
          })
        end
      end
    end

    local boxes = save.boxes
    if not isGen2 then
      local okB, BoxesMod = pcall(require, "src.pokemon.Boxes")
      boxes = (okB and BoxesMod and BoxesMod.ensure and BoxesMod.ensure(save)) or save.boxes
    end
    if type(boxes) == "table" then
      for bIdx = 1, 14 do
        for mIdx, bMon in ipairs(boxes[bIdx] or {}) do
          if tradeable(bMon) then
            table.insert(list, {
              source = "box",
              boxIndex = bIdx,
              slotIndex = mIdx,
              mon = bMon,
              label = string.format("%s LV%d (BOX %d)", GtsUI.monLabelName(game, bMon):sub(1, 7), bMon.level or 1, bIdx)
            })
          end
        end
      end
    end
    return list
  end

  -- Helper to remove a Pokémon from Party or PC Storage Box
  function GtsUI.removePlayerMon(game, item)
    local save = game and game.save
    if not save or not item then return nil end
    if item.source == "party" then
      local mon = table.remove(save.party, item.slotIndex)
      -- party mail is keyed by slot: the letters behind it move up one
      if isGen2 and mon then
        local okMail, Mail = pcall(require, "src.core.gen2.Mail")
        if okMail and Mail.removeSlot then pcall(Mail.removeSlot, save, item.slotIndex) end
      end
      return mon
    elseif item.source == "box" then
      local boxes = save.boxes
      if not isGen2 then
        local okB, BoxesMod = pcall(require, "src.pokemon.Boxes")
        boxes = (okB and BoxesMod and BoxesMod.ensure and BoxesMod.ensure(save)) or save.boxes
      end
      if boxes and boxes[item.boxIndex] then
        return table.remove(boxes[item.boxIndex], item.slotIndex)
      end
    end
    return nil
  end

  -- Undo removePlayerMon when the server refuses what the mon was taken for:
  -- a box mon goes back to its slot, a party mon to the end of the party
  -- (the party mail behind its slot has already moved up with the party).
  function GtsUI.restorePlayerMon(game, item, mon)
    local save = game and game.save
    if not save or not item or not mon then return end
    if item.source == "box" then
      local boxes = save.boxes
      if not isGen2 then
        local okB, BoxesMod = pcall(require, "src.pokemon.Boxes")
        boxes = (okB and BoxesMod and BoxesMod.ensure and BoxesMod.ensure(save)) or save.boxes
      end
      local box = boxes and boxes[item.boxIndex]
      if box then
        table.insert(box, math.min(item.slotIndex or (#box + 1), #box + 1), mon)
        return
      end
    end
    GtsUI.addPlayerMon(game, mon)
  end

  -- Is there a party slot or box space for one more Pokémon?
  function GtsUI.hasRoom(game)
    local save = game and game.save
    if not save then return false end
    if #(save.party or {}) < 6 then return true end
    if not isGen2 then
      -- 12 boxes of 20 (src.pokemon.Boxes): a Pokémon with nowhere to go
      -- would be lost after the server has already handed it over
      local okB1, Boxes1 = pcall(require, "src.pokemon.Boxes")
      if not okB1 then return true end
      for _, box in ipairs(Boxes1.ensure(save)) do
        if #box < (Boxes1.CAPACITY or 20) then return true end
      end
      return false
    end
    local okB, Boxes = pcall(require, "src.core.gen2.Boxes")
    if not okB then return false end
    for i = 1, Boxes.NUM_BOXES do
      if not Boxes.isFull(save, i) then return true end
    end
    return false
  end

  -- Helper to add a received Pokémon to Party or PC Storage Box.  Answers
  -- "party", index | "box", boxIndex | nil when there is no room anywhere.
  function GtsUI.addPlayerMon(game, mon)
    local save = game and game.save
    if not save or not mon then return nil end
    save.party = save.party or {}
    if #save.party < 6 then
      save.party[#save.party + 1] = mon
      return "party", #save.party
    end
    if isGen2 then
      -- SendMonIntoBox: the current box first, then the next one with room
      local okB, Boxes = pcall(require, "src.core.gen2.Boxes")
      if not okB then return nil end
      local first = save.currentBox or 1
      for step = 0, Boxes.NUM_BOXES - 1 do
        local index = ((first - 1 + step) % Boxes.NUM_BOXES) + 1
        if not Boxes.isFull(save, index) then
          local box = Boxes.box(save, index)
          box[#box + 1] = Boxes.enterBox(mon, game.data)
          return "box", index
        end
      end
      return nil
    end
    local added = Party.add(save.party, mon)
    if added then return "party", #save.party end
    if Boxes and Boxes.deposit then Boxes.deposit(save, mon) end
    return "box", 1
  end

  -- Execute complete trade sequence: Pre-Save -> Cable Trade Animation -> Trade Evolution -> Post-Save -> MMO XP
  function GtsUI.performTradeWithAnimationAndEvolution(game, sentMon, receivedPacked, otName, otId, onComplete)
    -- 1. Unpack received mon and preserve full stats & OT
    local receivedMon = GtsUI.unpackMon(game, receivedPacked)
    if not receivedMon then
      game.stack:push(TextBox.new(game, wrapText("THAT POKéMON ISN'T IN THIS GAME!")))
      return
    end
    receivedMon.traded = true
    if otName then receivedMon.ot = otName; receivedMon.otName = otName end
    if otId then receivedMon.otId = otId end

    -- Add to player party / boxes
    local whereTo, slot = GtsUI.addPlayerMon(game, receivedMon)

    -- Update Pokédex seen & caught flags
    if game.save then
      game.save.pokedex = game.save.pokedex or {}
      local dex = game.save.pokedex
      dex.seen = dex.seen or {}
      dex.seen[receivedMon.species] = true
      if isGen2 then
        dex.caught = dex.caught or {}
        dex.caught[receivedMon.species] = true
      else
        dex.owned = dex.owned or {}
        dex.owned[receivedMon.species] = true
      end
    end

    -- 2. Saved as soon as the Pokémon is here: the server has already handed
    -- it over, so a crash during the animation must not lose it
    performForcedSave(game)

    local function afterEvolution()
      performForcedSave(game)
      if addMmoXp then addMmoXp(game, "gts_trade", 100) end
      if onComplete then onComplete(receivedMon) end
    end

    -- 3. Post-Animation sequence: Trade Evolution & Learn Moves
    local function finishTradeSequence()
      if isGen2 then
        -- EVOLVE_TRADE fires for a mon arriving in the party, as on the cart;
        -- EvolutionAnim applies it, marks the dex and teaches the new moves.
        local okEvo, Evolution = pcall(require, "src.core.gen2.Evolution")
        local okPal, Palettes = pcall(require, "src.world.gen2.Palettes")
        local entry = whereTo == "party" and okEvo and Evolution.checkMon(game.data, receivedMon, {
          link = true,
          timeOfDay = okPal and Palettes.clockDaytime and Palettes.clockDaytime() or nil,
        })
        local okScreens, Screens = pcall(require, "src.ui.Screens")
        if entry and okScreens and Screens.push then
          Screens.push(game, "Gen2EvolutionAnim", {
            mon = receivedMon,
            entry = entry,
            index = slot,
            party = game.save.party,
            save = game.save,
            onDone = function()
              game.stack:pop()
              if game.restartMapMusicAfterEvolution then
                pcall(game.restartMapMusicAfterEvolution, game)
              end
              afterEvolution()
            end,
          })
          return
        end
        afterEvolution()
        return
      end

      local Evolution = require("src.pokemon.Evolution")
      local nextSpecies = Evolution.pendingFor(game, receivedMon, { kind = "trade" })
      if nextSpecies then
        local okEvo, EvolutionState = pcall(require, "src.ui.EvolutionState")
        if okEvo and EvolutionState and EvolutionState.new then
          local evoScreen = EvolutionState.new(game, receivedMon, nextSpecies, function()
            Evolution.apply(game, receivedMon, nextSpecies, "TRADE")
            Evolution.learnEvolutionMoves(game, receivedMon, afterEvolution)
          end, "TRADE")
          game.stack:push(evoScreen)
          return
        end
        Evolution.apply(game, receivedMon, nextSpecies, "TRADE")
        Evolution.learnEvolutionMoves(game, receivedMon, afterEvolution)
      else
        afterEvolution()
      end
    end

    -- 4. Launch Cable Trade Animation
    local okAnim = false
    if isGen2 then
      -- Gen2TradeAnim reads the OT from an npc_trades-shaped row; it does not
      -- pop itself, so its onDone does, the way TradeMenu:playAnim does.
      local okScreens, Screens = pcall(require, "src.ui.Screens")
      local world = getWorld(game)
      if okScreens and Screens.push then
        okAnim = Screens.push(game, "Gen2TradeAnim", {
          row = { otName = otName or "TRAINER", otId = otId or 0 },
          given = sentMon,
          received = receivedMon,
          save = game.save,
          eventTables = world and world.eventTables or nil,
          onDone = function()
            game.stack:pop()
            finishTradeSequence()
          end,
        }) and true or false
      end
    else
      local okT, TradeAnim = pcall(require, "src.ui.TradeAnim")
      if okT and TradeAnim and TradeAnim.new then
        local anim = TradeAnim.new(game, {
          sent = sentMon,
          received = receivedMon,
          enemyName = otName or "TRAINER",
          onDone = finishTradeSequence
        })
        game.stack:push(anim)
        okAnim = true
      end
    end

    if not okAnim then
      pcall(function() require("src.core.Sound").play(game.data, "Trade_Machine") end)
      finishTradeSequence()
    end
  end

  -- GTS Summary Card & Trade Execution
  function GtsUI.openGtsSummaryCard(game, listing)
    local trainerId, buyerName = getTrainerInfo(game.save)
    local offered = listing.offeredMon or {}
    local offName = offered.nickname or (game.data.pokemon[offered.species] and game.data.pokemon[offered.species].name) or offered.species or "POKéMON"
    local otName = listing.trainerName or offered.ot or "TRAINER"
    local otId = listing.trainerId or offered.otId or 0

    if #offName > 10 then offName = offName:sub(1, 10) end
    if #otName > 8 then otName = otName:sub(1, 8) end

    local wantedList = listing.wanted or {}

    -- Build moves string
    local movesStr = ""
    if offered.moves and #offered.moves > 0 then
      local moveNames = {}
      for _, mv in ipairs(offered.moves) do
        local mId = type(mv) == "table" and mv.id or mv
        local mDef = game.data.moves and game.data.moves[mId]
        table.insert(moveNames, mDef and mDef.name or tostring(mId))
      end
      movesStr = table.concat(moveNames, ", ")
      if #movesStr > 16 then movesStr = movesStr:sub(1, 15) .. ".." end
    end

    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") then
          game.stack:pop()
          return
        elseif input:wasPressed("a") then
          if tostring(listing.trainerId) == tostring(trainerId) then
            game.stack:push(TextBox.new(game, wrapText("THIS IS YOUR OWN LISTING! MANAGE IN MY LISTINGS.")))
            return
          end

          -- Search eligible Pokémon across party and PC boxes
          local allMons = GtsUI.getAllPlayerMons(game)
          local eligibleList = {}

          for _, item in ipairs(allMons) do
            if #wantedList == 0 then
              table.insert(eligibleList, item)
            else
              for _, wSpec in ipairs(wantedList) do
                if item.mon.species == wSpec then
                  table.insert(eligibleList, item)
                  break
                end
              end
            end
          end

          if #eligibleList == 0 then
            game.stack:push(TextBox.new(game, wrapText("YOU DO NOT HAVE ANY OF THE WANTED POKéMON IN PARTY OR PC BOXES!")))
            return
          end

          local tradeItems = {}
          for _, choice in ipairs(eligibleList) do
            table.insert(tradeItems, {
              label = string.format("GIVE %s", choice.label:sub(1, 13)),
              onSelect = function()
                if choice.source == "party" and #game.save.party < 2 then
                  game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 2 POKéMON IN PARTY TO TRADE FROM PARTY!")))
                  return
                end

                -- Remove chosen mon
                local sentMon = GtsUI.removePlayerMon(game, choice)
                if not sentMon then return end
                local packedSent = GtsUI.packMon(sentMon)

                -- Post trade to server.  Nothing is final until it agrees:
                -- the listing may have been bought or withdrawn meanwhile.
                local res = gtsApiPost({
                  action = "trade",
                  listingId = listing.id,
                  buyerId = trainerId,
                  buyerName = buyerName,
                  sentMon = packedSent
                }, 2.0)
                if not (res and res.success) then
                  GtsUI.restorePlayerMon(game, choice, sentMon)
                  game.stack:pop() -- close summary card
                  local why = "COULD NOT REACH THE GTS SERVER!"
                  if res and res.error == "LISTING_GONE" then
                    gtsDb.listings[listing.id] = nil
                    why = "THAT LISTING IS GONE! SOMEONE GOT THERE FIRST."
                  elseif res then
                    why = string.format("THE GTS REFUSED THE TRADE (%s).", tostring(res.error))
                  end
                  game.stack:push(TextBox.new(game, wrapText(why .. " YOUR POKéMON STAYS WITH YOU.")))
                  return
                end
                local receivedPacked = res.receivedMon or offered

                -- Update local database
                gtsDb.claim_boxes[tostring(listing.trainerId)] = gtsDb.claim_boxes[tostring(listing.trainerId)] or {}
                table.insert(gtsDb.claim_boxes[tostring(listing.trainerId)], {
                  mon = packedSent,
                  fromName = buyerName,
                  fromId = trainerId,
                  originalOffered = offName,
                  timestamp = os.time()
                })
                gtsDb.listings[listing.id] = nil
                gtsDb.user_counts[tostring(listing.trainerId)] = math.max(0, (gtsDb.user_counts[tostring(listing.trainerId)] or 1) - 1)

                GtsUI.addGtsReceipt(string.format("%s TRADED %s TO %s FOR %s", buyerName, sentMon.nickname or sentMon.species, otName, offName))

                game.stack:pop() -- close summary card

                -- Run Trade Animation & Trade Evolution
                GtsUI.performTradeWithAnimationAndEvolution(game, sentMon, receivedPacked, otName, otId, function(receivedMon)
                  local rName = receivedMon.nickname or (game.data.pokemon[receivedMon.species] and game.data.pokemon[receivedMon.species].name) or receivedMon.species
                  game.stack:push(TextBox.new(game, wrapText(string.format("GTS TRADE COMPLETE!\nRECEIVED %s!", rName))))
                end)
              end
            })
          end
          table.insert(tradeItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, tradeItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      end,
      draw = function(self)
        Font.drawBox(0, 0, 20, 18)
        local hdr = "GTS LISTING"
        Font.draw(hdr, math.floor((160 - #hdr * 8) / 2), 10)
        Font.draw("==================", 8, 20)
        Font.draw(string.format("OFFER: %s", offName:sub(1, 11)), 8, 30)
        Font.draw(string.format("LEVEL: %d", offered.level or 1), 8, 42)
        Font.draw(string.format("OT: %s (ID %s)", otName:sub(1, 6), tostring(otId):sub(1, 6)), 8, 54)
        if #movesStr > 0 then
          Font.draw(string.format("MOVES: %s", movesStr), 8, 66)
        end
        Font.draw("WANTED POKéMON:", 8, 78)

        if #wantedList == 0 then
          Font.draw(" - ANY POKéMON", 8, 90)
        else
          local curY = 90
          for idx, wSpec in ipairs(wantedList) do
            if curY <= 104 then
              local wName = (game.data.pokemon[wSpec] and game.data.pokemon[wSpec].name) or wSpec
              if #wName > 14 then wName = wName:sub(1, 14) end
              Font.draw(string.format(" - %s", wName), 8, curY)
              curY = curY + 12
            end
          end
        end

        Font.draw("==================", 8, 114)
        local ftr = "A: TRADE  B: BACK"
        Font.draw(ftr, math.floor((160 - #ftr * 8) / 2), 126)
      end
    }
    game.stack:push(container)
  end

  -- GTS Browse Submenu (WITH DEX FILTERS & CONNECTION GUARD)
  function GtsUI.openGtsBrowseMenu(game)
    if not isGtsServerConnected then
      game.stack:push(TextBox.new(game, wrapText("YOU ARE NOT CONNECTED TO GTS SERVER! SELECT CONNECT GTS SERVER FIRST.")))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local function showListingsList(filterMode)
      local items = {}
      local allPlayerMons = GtsUI.getAllPlayerMons(game)

      for id, listing in pairs(gtsDb.listings) do
        local offered = listing.offeredMon or {}
        local offName = offered.nickname or (game.data.pokemon[offered.species] and game.data.pokemon[offered.species].name) or offered.species or "MON"
        local tName = listing.trainerName or "OT"
        if #offName > 7 then offName = offName:sub(1, 7) end
        if #tName > 5 then tName = tName:sub(1, 5) end

        local include = true
        if filterMode == "unowned_dex" then
          -- Filter for unowned species
          local dex = game.save and game.save.pokedex
          local ownedSet = dex and (isGen2 and dex.caught or dex.owned)
          if ownedSet and ownedSet[offered.species] == true then
            include = false
          end
        elseif filterMode == "can_fulfill" then
          -- Filter for listings where player has one of wanted species
          local canFulfill = false
          local wantedList = listing.wanted or {}
          if #wantedList == 0 then
            canFulfill = (#allPlayerMons > 0)
          else
            for _, pItem in ipairs(allPlayerMons) do
              for _, wSpec in ipairs(wantedList) do
                if pItem.mon.species == wSpec then
                  canFulfill = true
                  break
                end
              end
              if canFulfill then break end
            end
          end
          if not canFulfill then include = false end
        end

        if include then
          table.insert(items, {
            label = string.format("%s L%d (%s)", offName, offered.level or 1, tName),
            onSelect = function()
              GtsUI.openGtsSummaryCard(game, listing)
            end
          })
        end
      end

      if #items == 0 then
        game.stack:push(TextBox.new(game, wrapText("NO MATCHING GTS LISTINGS FOUND.")))
        return
      end

      table.insert(items, { label = "BACK", onSelect = function() end })
      local menu = Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true })
      game.stack:push(menu)
    end

    -- Browse Filter Selection Menu
    local filterItems = {
      {
        label = "ALL ACTIVE TRADES",
        onSelect = function() showListingsList("all") end
      },
      {
        label = "UNOWNED (DEX)",
        onSelect = function() showListingsList("unowned_dex") end
      },
      {
        label = "CAN FULFILL",
        onSelect = function() showListingsList("can_fulfill") end
      },
      { label = "BACK", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, filterItems, { tx = 0, ty = 0, tw = 20, maxVisible = 6, startCloses = true }))
  end

  -- Interactive Wanted Species Selection Screen
  function GtsUI.openWantedSpeciesSelector(game, onComplete)
    local wanted = {}
    local allSpecies = getAllGen1Species(game.data)

    local function showMainWantedMenu()
      local items = {}
      if #wanted > 0 then
        table.insert(items, {
          label = string.format("CONFIRM (%d/3)", #wanted),
          onSelect = function()
            onComplete(wanted)
          end
        })
      end

      if #wanted < 3 then
        table.insert(items, {
          label = string.format("+ ADD (%d/3)", #wanted + 1),
          onSelect = function()
            local ranges = {
              { label = "A - C", minChar = "A", maxChar = "C" },
              { label = "D - F", minChar = "D", maxChar = "F" },
              { label = "G - I", minChar = "G", maxChar = "I" },
              { label = "J - L", minChar = "J", maxChar = "L" },
              { label = "M - O", minChar = "M", maxChar = "O" },
              { label = "P - R", minChar = "P", maxChar = "R" },
              { label = "S - U", minChar = "S", maxChar = "U" },
              { label = "V - Z", minChar = "V", maxChar = "Z" },
            }
            local rangeItems = {}
            for _, r in ipairs(ranges) do
              table.insert(rangeItems, {
                label = r.label,
                onSelect = function()
                  local monItems = {}
                  for _, spec in ipairs(allSpecies) do
                    local firstLetter = spec.name:sub(1, 1):upper()
                    if firstLetter >= r.minChar and firstLetter <= r.maxChar then
                      table.insert(monItems, {
                        label = spec.name:sub(1, 14),
                        onSelect = function()
                          table.insert(wanted, spec.id)
                          showMainWantedMenu()
                        end
                      })
                    end
                  end
                  if #monItems == 0 then
                    game.stack:push(TextBox.new(game, wrapText("NO POKéMON IN THIS RANGE.")))
                  else
                    table.insert(monItems, { label = "BACK", onSelect = function() showMainWantedMenu() end })
                    game.stack:push(Menu.new(game, monItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
                  end
                end
              })
            end
            table.insert(rangeItems, { label = "BACK", onSelect = function() showMainWantedMenu() end })
            game.stack:push(Menu.new(game, rangeItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
          end
        })
      end

      if #wanted > 0 then
        table.insert(items, {
          label = "CLEAR ALL",
          onSelect = function()
            wanted = {}
            showMainWantedMenu()
          end
        })
      end

      table.insert(items, {
        label = "CANCEL",
        onSelect = function()
          onComplete(nil)
        end
      })

      game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
    end

    showMainWantedMenu()
  end

  -- GTS Deposit Submenu (Party min 2 & PC Boxes, 10 Mon Limit)
  function GtsUI.openGtsDepositMenu(game)
    if not isGtsServerConnected then
      game.stack:push(TextBox.new(game, wrapText("YOU ARE NOT CONNECTED TO GTS SERVER! SELECT CONNECT GTS SERVER FIRST.")))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local activeCount = gtsDb.user_counts[tostring(trainerId)] or 0
    if activeCount >= 10 then
      game.stack:push(TextBox.new(game, wrapText("YOU REACHED THE MAXIMUM OF 10 GTS LISTINGS!")))
      return
    end

    local function handleDepositSelection(chosenItem)
      if chosenItem.source == "party" and #game.save.party < 2 then
        game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 2 POKéMON IN PARTY TO DEPOSIT FROM PARTY!")))
        return
      end

      GtsUI.openWantedSpeciesSelector(game, function(wantedList)
        if not wantedList or #wantedList == 0 then return end

        performForcedSave(game)

        local depositMon = GtsUI.removePlayerMon(game, chosenItem)
        if not depositMon then return end

        if depositMon.nickname and Profanity and Profanity.censor then
          depositMon.nickname = Profanity.censor(depositMon.nickname)
        end
        local packedMon = GtsUI.packMon(depositMon)

        local res = gtsApiPost({
          action = "deposit",
          trainerId = trainerId,
          trainerName = trainerName,
          offeredMon = packedMon,
          wanted = wantedList
        }, 2.0)

        if not (res and res.success and res.listing) then
          -- the server holds the listing or nobody does: the mon comes back
          GtsUI.restorePlayerMon(game, chosenItem, depositMon)
          local why = "COULD NOT REACH THE GTS SERVER!"
          if res and res.error == "LISTING_LIMIT" then
            why = "YOU REACHED THE MAXIMUM OF 10 GTS LISTINGS!"
          elseif res then
            why = string.format("THE GTS REFUSED THE DEPOSIT (%s).", tostring(res.error))
          end
          game.stack:push(TextBox.new(game, wrapText(why .. " YOUR POKéMON STAYS WITH YOU.")))
          return
        end
        gtsDb.listings[res.listing.id] = res.listing

        gtsDb.user_counts[tostring(trainerId)] = (gtsDb.user_counts[tostring(trainerId)] or 0) + 1
        GtsUI.addGtsReceipt(string.format("%s DEPOSITED %s", trainerName, depositMon.nickname or depositMon.species))
        if addMmoXp then addMmoXp(game, "gts_deposit", 25) end
        performForcedSave(game)

        local msg = string.format("%s WAS DEPOSITED TO GTS!\n(LISTINGS: %d/10)", depositMon.nickname or depositMon.species, gtsDb.user_counts[tostring(trainerId)])
        game.stack:push(TextBox.new(game, wrapText(msg)))
      end)
    end

    local depositSourceMenu = {
      {
        label = "FROM PARTY",
        onSelect = function()
          if not game.save or not game.save.party or #game.save.party < 2 then
            game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 2 POKéMON IN PARTY TO DEPOSIT!")))
            return
          end
          local partyItems = {}
          for idx, mon in ipairs(game.save.party) do
            local monName = mon.nickname or (game.data.pokemon[mon.species] and game.data.pokemon[mon.species].name) or mon.species
            if #monName > 8 then monName = monName:sub(1, 8) end
            table.insert(partyItems, {
              label = string.format("%s (LV%d)", monName, mon.level or 1),
              onSelect = function()
                handleDepositSelection({ source = "party", slotIndex = idx, mon = mon })
              end
            })
          end
          table.insert(partyItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, partyItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      },
      {
        label = "FROM PC BOXES",
        onSelect = function()
          local BoxesMod = nil
          pcall(function() BoxesMod = require(isGen2 and "src.core.gen2.Boxes" or "src.pokemon.Boxes") end)
          local boxes = (BoxesMod and BoxesMod.ensure and BoxesMod.ensure(game.save)) or game.save.boxes
          local boxItems = {}
          if boxes then
            for bIdx, box in ipairs(boxes) do
              for mIdx, bMon in ipairs(box) do
                local bName = bMon.nickname or (game.data.pokemon[bMon.species] and game.data.pokemon[bMon.species].name) or bMon.species
                table.insert(boxItems, {
                  label = string.format("B%d: %s (LV%d)", bIdx, bName:sub(1, 6), bMon.level or 1),
                  onSelect = function()
                    handleDepositSelection({ source = "box", boxIndex = bIdx, slotIndex = mIdx, mon = bMon })
                  end
                })
              end
            end
          end

          if #boxItems == 0 then
            game.stack:push(TextBox.new(game, wrapText("YOUR PC STORAGE BOXES ARE EMPTY!")))
            return
          end

          table.insert(boxItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, boxItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      },
      { label = "BACK", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, depositSourceMenu, { tx = 0, ty = 0, tw = 20, maxVisible = 6, startCloses = true }))
  end

  -- GTS My Listings & Claim Box Submenu
  function GtsUI.openGtsMyListingsMenu(game)
    if not isGtsServerConnected then
      game.stack:push(TextBox.new(game, wrapText("YOU ARE NOT CONNECTED TO GTS SERVER! SELECT CONNECT GTS SERVER FIRST.")))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local items = {}

    -- 1. Active Deposits (Withdraw)
    for id, listing in pairs(gtsDb.listings) do
      if tostring(listing.trainerId) == tostring(trainerId) then
        local offered = listing.offeredMon or {}
        local offName = offered.nickname or (game.data.pokemon[offered.species] and game.data.pokemon[offered.species].name) or offered.species or "MON"
        if #offName > 7 then offName = offName:sub(1, 7) end
        table.insert(items, {
          label = string.format("TAKE %s LV%d", offName, offered.level or 1),
          onSelect = function()
            if not GtsUI.hasRoom(game) then
              game.stack:push(TextBox.new(game, wrapText("YOUR PARTY AND PC BOXES ARE FULL! MAKE ROOM FIRST.")))
              return
            end
            performForcedSave(game)

            -- the server decides first: a listing someone just bought must
            -- not also come back to its owner
            local res = gtsApiPost({ action = "withdraw", listingId = id, trainerId = trainerId }, 2.0)
            if not (res and res.success) then
              if res then gtsDb.listings[id] = nil end
              game.stack:push(TextBox.new(game, wrapText(res
                and "COULD NOT WITHDRAW! IT MAY HAVE JUST BEEN TRADED. CHECK MY LISTINGS FOR A CLAIM."
                or "COULD NOT REACH THE GTS SERVER!")))
              return
            end

            local returnedMon = GtsUI.unpackMon(game, res.mon or offered)
            if returnedMon then GtsUI.addPlayerMon(game, returnedMon) end

            gtsDb.listings[id] = nil
            gtsDb.user_counts[tostring(trainerId)] = math.max(0, (gtsDb.user_counts[tostring(trainerId)] or 1) - 1)
            GtsUI.addGtsReceipt(string.format("%s WITHDREW DEPOSITED %s", trainerName, offName))
            performForcedSave(game)

            local msg = string.format("WITHDREW %s FROM GTS!", offName)
            game.stack:push(TextBox.new(game, wrapText(msg)))
          end
        })
      end
    end

    -- 2. Claim Box (Traded Mons Waiting to be Claimed)
    local claims = gtsDb.claim_boxes[tostring(trainerId)] or {}
    for idx, claim in ipairs(claims) do
      local packed = claim.mon or {}
      local cName = packed.nickname or (game.data.pokemon[packed.species] and game.data.pokemon[packed.species].name) or packed.species or "MON"
      local fromStr = claim.fromName or "TRADER"
      if #cName > 7 then cName = cName:sub(1, 7) end
      if #fromStr > 5 then fromStr = fromStr:sub(1, 5) end
      table.insert(items, {
        label = string.format("GET %s (%s)", cName, fromStr),
        onSelect = function()
          if not GtsUI.hasRoom(game) then
            game.stack:push(TextBox.new(game, wrapText("YOUR PARTY AND PC BOXES ARE FULL! MAKE ROOM FIRST.")))
            return
          end
          local res = gtsApiPost({ action = "claim", trainerId = trainerId, index = idx - 1, claimId = claim.id }, 2.0)
          if not (res and res.success and res.claimed and res.claimed.mon) then
            game.stack:push(TextBox.new(game, wrapText(res
              and "COULD NOT CLAIM! IT IS NO LONGER IN YOUR CLAIM BOX."
              or "COULD NOT REACH THE GTS SERVER!")))
            return
          end
          table.remove(gtsDb.claim_boxes[tostring(trainerId)], idx)
          packed = res.claimed.mon
          GtsUI.addGtsReceipt(string.format("%s CLAIMED TRADED %s", trainerName, cName))

          -- Run Trade Animation & Trade Evolution
          local dummySent = { species = "PIKACHU", level = 5 }
          GtsUI.performTradeWithAnimationAndEvolution(game, dummySent, packed, fromStr, res.claimed.fromId or claim.fromId, function(claimedMon)
            if addMmoXp then addMmoXp(game, "gts_claim", 50) end
            performForcedSave(game)
            local msg = string.format("CLAIMED %s FROM GTS!", cName)
            game.stack:push(TextBox.new(game, wrapText(msg)))
          end)
        end
      })
    end

    if #items == 0 then
      game.stack:push(TextBox.new(game, wrapText("YOU HAVE NO ACTIVE DEPOSITS OR CLAIMS.")))
      return
    end

    table.insert(items, { label = "BACK", onSelect = function() end })
    local menu = Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true })
    game.stack:push(menu)
  end

  -- GTS Wonder Trade Submenu.  The pool lives on the server: one Pokémon per
  -- trainer, and once 5 are waiting the server deals each trainer another's
  -- (never their own) as a claim.  Every step waits for the server's answer.
  function GtsUI.openWonderTradeMenu(game)
    if not isGtsServerConnected then
      game.stack:push(TextBox.new(game, wrapText("YOU ARE NOT CONNECTED TO GTS SERVER! SELECT CONNECT GTS SERVER FIRST.")))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    local wStatus = gtsApiPost({ action = "wonder_trade_status", trainerId = trainerId }, 1.5)
    if not (wStatus and wStatus.success) then
      game.stack:push(TextBox.new(game, wrapText("COULD NOT REACH THE WONDER TRADE POOL! TRY AGAIN LATER.")))
      return
    end
    local poolCount = tonumber(wStatus.poolCount) or 0
    local threshold = tonumber(wStatus.threshold) or 5
    local items = {}

    -- 1. A matched trade waiting to be claimed
    local claim = wStatus.claim
    if claim and claim.mon then
      table.insert(items, {
        label = string.format("CLAIM %s!", GtsUI.monLabelName(game, claim.mon):sub(1, 9)),
        onSelect = function()
          if not GtsUI.hasRoom(game) then
            game.stack:push(TextBox.new(game, wrapText("YOUR PARTY AND PC BOXES ARE FULL! MAKE ROOM FIRST.")))
            return
          end
          local res = gtsApiPost({ action = "wonder_trade_claim", trainerId = trainerId }, 2.0)
          local got = res and res.success and res.claim
          if not (got and got.mon) then
            game.stack:push(TextBox.new(game, wrapText(res
              and "THERE IS NO WONDER TRADE TO CLAIM!"
              or "COULD NOT REACH THE WONDER TRADE POOL!")))
            return
          end
          local gotName = GtsUI.monLabelName(game, got.mon)
          local fromStr = got.fromName or "MYSTERY"
          -- the Pokémon this trainer put in is the one seen leaving
          local okSent, sentMon = pcall(GtsUI.unpackMon, game, got.sentMon)
          if not (okSent and sentMon) then sentMon = { species = "PIKACHU", level = 5 } end
          GtsUI.performTradeWithAnimationAndEvolution(game, sentMon, got.mon, fromStr, got.fromId, function()
            if addMmoXp then addMmoXp(game, "wonder_trade", 75) end
            performForcedSave(game)
            local msg = string.format("WONDER TRADE COMPLETE!\nRECEIVED %s FROM %s!", gotName, fromStr)
            game.stack:push(TextBox.new(game, wrapText(msg)))
          end)
        end
      })
    end

    local mine = wStatus.mine
    if mine and mine.offeredMon then
      -- 2. Already in the pool: status / withdraw
      local pMon = mine.offeredMon
      local mName = GtsUI.monLabelName(game, pMon)
      table.insert(items, {
        label = string.format("STATUS: (%d/%d POOL)", poolCount, threshold),
        onSelect = function()
          local msg = string.format("WONDER TRADE POOL:\n%d/%d POKéMON READY.\nYOUR OFFER: %s LV%d.\nWAITING FOR %d POKéMON...", poolCount, threshold, mName, pMon.level or 1, threshold)
          game.stack:push(TextBox.new(game, wrapText(msg)))
        end
      })
      table.insert(items, {
        label = "WITHDRAW FROM POOL",
        onSelect = function()
          if not GtsUI.hasRoom(game) then
            game.stack:push(TextBox.new(game, wrapText("YOUR PARTY AND PC BOXES ARE FULL! MAKE ROOM FIRST.")))
            return
          end
          performForcedSave(game)
          local res = gtsApiPost({ action = "wonder_trade_withdraw", trainerId = trainerId }, 2.0)
          if not (res and res.success and res.mon) then
            game.stack:push(TextBox.new(game, wrapText((res and res.error == "NOT_IN_POOL")
              and "TOO LATE! YOUR POKéMON WAS JUST MATCHED. OPEN WONDER TRADE AGAIN TO CLAIM YOUR NEW ONE."
              or "COULD NOT WITHDRAW FROM THE WONDER TRADE POOL!")))
            return
          end
          local returnedMon = GtsUI.unpackMon(game, res.mon)
          if returnedMon then GtsUI.addPlayerMon(game, returnedMon) end
          performForcedSave(game)
          game.stack:push(TextBox.new(game, wrapText(string.format("WITHDREW %s FROM WONDER TRADE POOL!", mName))))
        end
      })
    elseif not claim then
      -- 3. Deposit (one per trainer, and not while a claim waits)
      table.insert(items, {
        label = string.format("DEPOSIT (%d/%d POOL)", poolCount, threshold),
        onSelect = function()
          local allMons = GtsUI.getAllPlayerMons(game)
          local monItems = {}

          for _, choice in ipairs(allMons) do
            table.insert(monItems, {
              label = choice.label,
              onSelect = function()
                if choice.source == "party" and #game.save.party < 2 then
                  game.stack:push(TextBox.new(game, wrapText("YOU NEED AT LEAST 2 POKéMON IN PARTY TO DEPOSIT FROM PARTY!")))
                  return
                end

                performForcedSave(game)
                local depositMon = GtsUI.removePlayerMon(game, choice)
                if not depositMon then return end
                local res = gtsApiPost({
                  action = "wonder_trade_deposit",
                  trainerId = trainerId,
                  trainerName = trainerName,
                  offeredMon = GtsUI.packMon(depositMon)
                }, 2.0)
                if not (res and res.success) then
                  -- the pool did not take it: it stays with the player
                  GtsUI.restorePlayerMon(game, choice, depositMon)
                  local why = "COULD NOT REACH THE WONDER TRADE POOL!"
                  if res and res.error == "CLAIM_PENDING" then
                    why = "CLAIM YOUR LAST WONDER TRADE FIRST!"
                  elseif res and res.error == "ALREADY_IN_POOL" then
                    why = "YOU ALREADY HAVE A POKéMON IN THE WONDER TRADE POOL!"
                  elseif res then
                    why = string.format("WONDER TRADE REFUSED (%s).", tostring(res.error))
                  end
                  game.stack:push(TextBox.new(game, wrapText(why)))
                  return
                end

                performForcedSave(game)
                local dName = GtsUI.monLabelName(game, depositMon)
                local msg = res.matched
                  and string.format("%s DEPOSITED INTO WONDER TRADE!\nA MATCH WAS FOUND! OPEN WONDER TRADE TO CLAIM.", dName)
                  or string.format("%s DEPOSITED INTO WONDER TRADE!\n(POOL: %d/%d)", dName, tonumber(res.poolCount) or (poolCount + 1), threshold)
                game.stack:push(TextBox.new(game, wrapText(msg)))
              end
            })
          end

          if #monItems == 0 then
            game.stack:push(TextBox.new(game, wrapText("YOU HAVE NO POKéMON AVAILABLE TO DEPOSIT!")))
            return
          end

          table.insert(monItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, monItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      })
    end

    table.insert(items, { label = "BACK", onSelect = function() end })
    game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 6, startCloses = true }))
  end

  -- GTS Recent History (Last 50 Receipts) Submenu
  function GtsUI.openGtsHistoryMenu(game)
    if not isGtsServerConnected then
      game.stack:push(TextBox.new(game, wrapText("YOU ARE NOT CONNECTED TO GTS SERVER! SELECT CONNECT GTS SERVER FIRST.")))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local items = {}
    for _, r in ipairs(gtsDb.history) do
      local lbl = r.text
      if #lbl > 16 then lbl = lbl:sub(1, 16) end
      table.insert(items, {
        label = lbl,
        onSelect = function()
          game.stack:push(TextBox.new(game, wrapText(r.text)))
        end
      })
    end

    if #items == 0 then
      game.stack:push(TextBox.new(game, wrapText("NO GTS TRANSACTIONS RECORDED YET.")))
      return
    end

    table.insert(items, { label = "BACK", onSelect = function() end })
    local menu = Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true })
    game.stack:push(menu)
  end

  -- Main GTS Top-Level Menu (WITH USER-FRIENDLY AUTO-CONNECT)
  function GtsUI.openGtsMainMenu(game)
    if not isGtsServerConnected then
      local connectPrompt = {
        {
          label = "CONNECT TO GTS",
          onSelect = function()
            handleConnectToServer(game)
          end
        },
        {
          label = "CANCEL",
          onSelect = function() end
        }
      }
      local msg = "YOU ARE NOT CONNECTED TO GTS SERVER!\nWOULD YOU LIKE TO CONNECT NOW?"
      game.stack:push(TextBox.new(game, wrapText(msg), function()
        game.stack:push(Menu.new(game, connectPrompt, { tx = 0, ty = 0, tw = 20, maxVisible = 6, startCloses = true }))
      end))
      return
    end

    local trainerId, trainerName = getTrainerInfo(game.save)
    fetchGtsServerSync(trainerId)

    local items = {
      {
        label = "BROWSE TRADES",
        onSelect = function() GtsUI.openGtsBrowseMenu(game) end
      },
      {
        label = "DEPOSIT MON",
        onSelect = function() GtsUI.openGtsDepositMenu(game) end
      },
      {
        label = "MY LISTINGS",
        onSelect = function() GtsUI.openGtsMyListingsMenu(game) end
      },
      {
        label = "WONDER TRADE",
        onSelect = function() GtsUI.openWonderTradeMenu(game) end
      },
      {
        label = "RECENT HISTORY",
        onSelect = function() GtsUI.openGtsHistoryMenu(game) end
      },
      { label = "LOG OFF", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

  -- Customize Local Trainer Profile Submenu ("ONLINE SETTINGS")
  openMyProfileMenu = function(game)
    local titles = {
      "ACE TRAINER", "BUG CATCHER", "POKéMANIAC", "LASS", "YOUNGSTER",
      "CHAMPION", "GYM LEADER", "BLACKBELT", "SUPER NERD", "COOLTRAINER"
    }

    local items = {
      {
        label = "TRAINER CARD",
        onSelect = function()
          syncLocalProfile(game, 0)
          local tid, tName = getTrainerInfo(game.save)
          openTrainerCardScreen(game, tid, { name = tName })
        end
      },
      {
        label = "CHANGE AVATAR",
        onSelect = function()
          local spriteItems = {}
          for _, av in ipairs(GtsUI.avatarChoices(game)) do
            table.insert(spriteItems, {
              label = av.label,
              onSelect = function()
                localSelectedSprite = av.id
                if game.save and game.save.onlineAccount then
                  game.save.onlineAccount.spriteId = av.id
                end
                applyPlayerSprite(game, av.id)
                saveOnlineAccount(game.save)
                syncLocalProfile(game, 0)
                local msg = string.format("AVATAR CHANGED TO:\n%s!", av.label)
                game.stack:push(TextBox.new(game, wrapText(msg)))
              end
            })
          end
          table.insert(spriteItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, spriteItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      },
      {
        label = "CHANGE TITLE",
        onSelect = function()
          local titleItems = {}
          for _, t in ipairs(titles) do
            table.insert(titleItems, {
              label = t,
              onSelect = function()
                localTrainerTitle = t
                if game.save and game.save.onlineAccount then
                  game.save.onlineAccount.title = t
                end
                syncLocalProfile(game, 0)
                local msg = string.format("TITLE UPDATED TO:\n%s!", t)
                game.stack:push(TextBox.new(game, wrapText(msg)))
              end
            })
          end
          table.insert(titleItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, titleItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      },
      {
        label = "FAVORITE MON",
        onSelect = function()
          if not game.save or not game.save.party or #game.save.party == 0 then
            game.stack:push(TextBox.new(game, wrapText("YOU HAVE NO POKéMON IN YOUR PARTY!")))
            return
          end
          local favItems = {}
          for _, mon in ipairs(game.save.party) do
            local mName = mon.nickname or (game.data.pokemon[mon.species] and game.data.pokemon[mon.species].name) or mon.species
            table.insert(favItems, {
              label = mName:sub(1, 14),
              onSelect = function()
                localFavoriteMon = mName
                if game.save and game.save.onlineAccount then
                  game.save.onlineAccount.favoriteMon = mName
                end
                syncLocalProfile(game, 0)
                local msg = string.format("FAVORITE POKéMON SET TO:\n%s!", mName)
                game.stack:push(TextBox.new(game, wrapText(msg)))
              end
            })
          end
          table.insert(favItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, favItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      },
      {
        label = "VIEW TOKEN",
        onSelect = function()
          local tokStr = mmoToken or (game.save and game.save.onlineAccount and game.save.onlineAccount.token) or "NONE"
          local msg = string.format("RECOVERY TOKEN:\n%s\nSAVE THIS TOKEN TO RESTORE ON ANY DEVICE!", tokStr)
          game.stack:push(TextBox.new(game, wrapText(msg)))
        end
      },
      {
        label = "CREATE NEW PLAYER",
        onSelect = function()
          openFreshOnlinePlayerMenu(game)
        end
      },
      {
        label = "REDEEM RECOVERY TOKEN",
        onSelect = function()
          openRedeemTokenMenu(game)
        end
      },
      {
        label = (function() loadChatNotifPref(); return ChatState.liveEnabled and "LIVE CHAT: ON" or "LIVE CHAT: OFF" end)(),
        onSelect = function()
          saveChatNotifPref(not ChatState.liveEnabled)
          game.stack:push(TextBox.new(game, wrapText(ChatState.liveEnabled and "LIVE CHAT\nENABLED!" or "LIVE CHAT\nDISABLED!")))
        end
      },
      {
        label = "DISCONNECT",
        onSelect = function()
          GtsUI.sendLogout(game)
          handleDisconnect(game)
        end
      },
      { label = "BACK", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

  -- Apply custom sprite avatar to local player immediately on overworld
  applyPlayerSprite = function(game, spriteId)
    if not game or not spriteId then return end
    local gWorld = getWorld(game)
    if not gWorld or not gWorld.player then return end
    local sprites = gWorld.sprites or (game.data and (game.data.gen2Sprites or game.data.sprites)) or {}
    local sDef = sprites[spriteId] or sprites["SPRITE_CHRIS"] or sprites["SPRITE_RED"]
    if sDef and gWorld.player.setSprite then
      pcall(gWorld.player.setSprite, gWorld.player, sDef)
      if gWorld.applySpritePalette then
        pcall(gWorld.applySpritePalette, gWorld, gWorld.player)
      end
    elseif sDef then
      -- Gen 1's Player has no setSprite: its walking sheet is player.sprite
      pcall(function() gWorld.player.sprite = SpriteRenderer.new(sDef, "player") end)
    end
  end

  -- Back to the player's own look after going offline: World:applyPlayerState
  -- picks Chris or Kris by gender, and the bike/surf sheet for that state.
  function GtsUI.restorePlayerSprite(game)
    local gWorld = getWorld(game)
    if isGen2 and gWorld and gWorld.applyPlayerState then
      pcall(gWorld.applyPlayerState, gWorld, gWorld.playerState)
      return
    end
    applyPlayerSprite(game, isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
  end

  -- Wrap Player.new to ensure whenever local player is initialized, chosen avatar is used
  -- Player avatar helper (native walking animations preserved)
  -- Redeem Recovery Token to Restore Lost Save
  -- A naming keyboard.  On Crystal it is the game's own screen -- the box
  -- keyboard when digits are needed, since only BoxNameInput carries 0-9 --
  -- and that screen leaves popping itself to the caller.
  function GtsUI.nameEntry(game, opts)
    if isGen2 then
      local okScreens, Screens = pcall(require, "src.ui.Screens")
      if okScreens and Screens and Screens.push then
        Screens.push(game, "Gen2NamingScreen", {
          type = opts.digits and "box" or "player",
          prompt = opts.prompt,
          maxLength = opts.maxLength,
          initial = opts.initial or "",
          gender = game.save and game.save.player and game.save.player.gender,
          onDone = function(name)
            game.stack:pop()
            if opts.onDone then opts.onDone(name) end
          end,
          onCancel = function()
            game.stack:pop()
            if opts.onCancel then opts.onCancel() end
          end,
        })
        return
      end
    end
    local NamingScreen = require("src.ui.NamingScreen")
    game.stack:push(NamingScreen.new(game, {
      title = opts.prompt, maxLen = opts.maxLength, default = opts.initial or "",
      onDone = opts.onDone,
    }))
  end

  openRedeemTokenMenu = function(game)
    local tokenOpts = {
      prompt = "RECOVERY TOKEN?",
      maxLength = 8,
      digits = true,
      onDone = function(enteredToken)
        if not enteredToken or #enteredToken == 0 then return end
        enteredToken = enteredToken:gsub("%s+", ""):upper()

        local res = gtsApiPost({ action = "redeem_token", token = enteredToken }, 3.0)
        if res and res.success and res.account then
          local acc = res.account
          mmoLevel = acc.level or 1
          mmoXp = acc.xp or 0
          mmoToken = acc.token or enteredToken
          localSelectedSprite = acc.spriteId or (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
          if acc.title then localTrainerTitle = acc.title end
          if acc.favoriteMon then localFavoriteMon = acc.favoriteMon end

          local newSave = nil
          -- Restore the existing online save (party, flags, map scenes,
          -- inventory, position) when one is present for THIS account; only
          -- build a fresh save when there is nothing to restore (e.g. first
          -- time on a new device).
          local restoredSave = loadOnlineSave(game)
          if restoredSave and restoredSave.onlineAccount
             and tostring(restoredSave.onlineAccount.token or ""):upper()
                == tostring(acc.token or enteredToken or ""):upper() then
            newSave = restoredSave
          end
          if not newSave then
            if isGen2 then
              local okGen2Save, Gen2SaveModule = pcall(require, "src.core.gen2.Save")
              if okGen2Save and Gen2SaveModule and Gen2SaveModule.newGame then
                newSave = Gen2SaveModule.newGame({ playerName = acc.name or "CRYSTAL" })
              end
            end
            if not newSave then
              local SaveDataModule = pcall(require, "src.core.SaveData") and require("src.core.SaveData") or nil
              local bootCfg = game.bootConfig and game:bootConfig() or nil
              newSave = (SaveDataModule and SaveDataModule.newGame and SaveDataModule.newGame(bootCfg)) or {}
            end
            -- Fresh save: default starting location fields.
            newSave.player = newSave.player or {}
            newSave.player.map = defaultStartingOutdoor
            newSave.player.x = defaultStartingOutdoorX
            newSave.player.y = defaultStartingOutdoorY
            newSave.player.facing = "down"
            newSave.player.surfing = false
            if isGen2 then
              newSave.position = {
                map = defaultStartingOutdoor,
                x = defaultStartingOutdoorX,
                y = defaultStartingOutdoorY,
                facing = "down"
              }
              newSave.spawn = defaultStartingOutdoor
              newSave.player.money = 3000
            else
              newSave.lastHeal = { map = defaultStartingOutdoor, x = defaultStartingOutdoorX, y = defaultStartingOutdoorY }
              newSave.lastOutdoor = { id = defaultStartingOutdoor, x = defaultStartingOutdoorX, y = defaultStartingOutdoorY }
              newSave.money = 3000
            end
            newSave.blackoutCount = acc.blackoutCount or 0
          end

          -- Always refresh the account profile on the restored/fresh save.
          newSave.player = newSave.player or {}
          newSave.player.name = acc.name or (isGen2 and "CRYSTAL" or "RED")
          newSave.player.id = acc.trainerId or getTrainerInfo(game.save)
          newSave.onlineAccount = acc

          currentGame = game
          game.save = newSave
          if game.adoptSave then game:adoptSave(game.save) end
          isGtsServerConnected = true
          saveOnlineAccount(game.save)

          applyPlayerSprite(game, localSelectedSprite)

          -- Restore the exact saved location (existing save) or default start
          -- (fresh save), then persist the snapshotted save so flags/mapScenes
          -- ride along.
          local ow = getWorld(game)
          if ow then
            local pMap = (newSave.position and newSave.position.map)
              or (newSave.player and newSave.player.map) or defaultStartingOutdoor
            local px = (newSave.position and newSave.position.x)
              or (newSave.player and newSave.player.x) or defaultStartingOutdoorX
            local py = (newSave.position and newSave.position.y)
              or (newSave.player and newSave.player.y) or defaultStartingOutdoorY
            local pFacing = (newSave.position and newSave.position.facing)
              or (newSave.player and newSave.player.facing) or "down"
            if isGen2 and ow.loadPlayerData then
              pcall(ow.loadPlayerData, ow, newSave)
              if ow.vm then ow.vm.events = ow.events end
            end
            if ow.setMap then
              pcall(function() ow:setMap(pMap, px, py, pFacing) end)
            end
          end
          writeOnlineSave(game.save)

          syncLocalProfile(game, 0)
          fetchGtsServerSync(acc.trainerId)
          startChatSession(game)

          game.stack:push(TextBox.new(game, wrapText(string.format("TOKEN REDEEMED!\nWELCOME BACK, %s!\nMMO LEVEL %d RESTORED!", acc.name or "TRAINER", mmoLevel)), function()
            openOnlineOptionsMenu(game)
          end))
        else
          local err = (res and res.error) or "TOKEN NOT FOUND"
          game.stack:push(TextBox.new(game, wrapText(string.format("ERROR: %s!\nCOULD NOT RESTORE SAVE.", err))))
        end
      end
    }
    GtsUI.nameEntry(game, tokenOpts)
  end

  -- Fresh Online Player Creation & Authentic Naming Screen
    openFreshOnlinePlayerMenu = function(game)

    local function pickCharacterSprite(chosenName)
      local spriteItems = {}
      for _, av in ipairs(GtsUI.avatarChoices(game)) do
        table.insert(spriteItems, {
          label = av.label,
          onSelect = function()
            local chosenSprite = av.id

            local res = gtsApiPost({
              action = "register_player",
              isNewCharacter = true,
              name = chosenName,
              spriteId = chosenSprite,
              title = localTrainerTitle,
              badges = 0,
              pokedexCount = 0
            }, 10.0)

            if res and res.success and res.account then
              local acc = res.account
              local newTid = tonumber(acc.trainerId) or 100001
              mmoLevel = 1
              mmoXp = 0
              mmoToken = acc.token
              localSelectedSprite = chosenSprite
              isGtsServerConnected = true

              -- ALWAYS build a brand-new save for a new character.  Reusing
              -- game.save here is what kept the old character's flags, map
              -- scenes and position alive under the new id/sprite: the fresh
              -- online save files are gone, but the in-memory game.save from
              -- the previous session still has a party, so the old guard
              -- (`if not activeSave.party`) silently reused it.
              local activeSave = nil
              if isGen2 then
                local okGen2Save, Gen2SaveModule = pcall(require, "src.core.gen2.Save")
                if okGen2Save and Gen2SaveModule and Gen2SaveModule.newGame then
                  activeSave = Gen2SaveModule.newGame({ playerName = chosenName, trainerId = newTid })
                end
              end
              if not activeSave then
                local SaveDataModule = pcall(require, "src.core.SaveData") and require("src.core.SaveData") or nil
                local bootCfg = game.bootConfig and game:bootConfig() or nil
                activeSave = (SaveDataModule and SaveDataModule.newGame and SaveDataModule.newGame(bootCfg)) or {}
              end
              -- Fresh save: start in the player's bedroom like a new game,
              -- not wherever the old character logged out.
              activeSave.player = activeSave.player or {}
              activeSave.player.name = chosenName
              activeSave.player.id = newTid
              activeSave.position = {
                map = defaultStartingIndoor,
                x = defaultStartingIndoorX,
                y = defaultStartingIndoorY,
                facing = "down",
              }
              activeSave.player.map = defaultStartingIndoor
              activeSave.player.x = defaultStartingIndoorX
              activeSave.player.y = defaultStartingIndoorY
              activeSave.player.facing = "down"
              activeSave.player.surfing = false
              activeSave.spawn = "SPAWN_HOME"
              activeSave.onlineAccount = {
                trainerId = tostring(newTid),
                name = chosenName,
                level = 1,
                xp = 0,
                token = acc.token,
                spriteId = chosenSprite,
                title = localTrainerTitle,
                favoriteMon = localFavoriteMon
              }

              game.save = activeSave
              if game.adoptSave then game:adoptSave(game.save) end
              currentGame = game

              -- Clear stale net state from the previous character.
              netNpcs = {}
              mod.exports.netNpcs = netNpcs
              netFollowers = {}
              isWaitingForChallenge = false

              -- Apply sprite to local player immediately with Gen 2 palettes
              applyPlayerSprite(game, chosenSprite)

              -- Reload the LIVE world from the fresh save BEFORE persisting it.
              -- writeOnlineSave -> currentGame:snapshotSave() folds the running
              -- world.events into game.save.events (src/core/Game2.lua:812), so
              -- persisting first would copy the PREVIOUS character's flags into
              -- the fresh save and every map/flag would come back.
              local ow = getWorld(game)
              if isGen2 and ow and ow.loadPlayerData then
                pcall(ow.loadPlayerData, ow, game.save)
                -- loadPlayerData REPLACES world.events with a new Events, but
                -- the script VM was built at World:load with a reference to
                -- the OLD events object (src/world/gen2/World.lua:931).  Re-
                -- point it or the VM keeps reading the previous character's
                -- flags and the fresh save never takes effect in dialogue.
                if ow.vm then ow.vm.events = ow.events end
              end
              if ow and ow.setMap then
                pcall(function() ow:setMap(defaultStartingIndoor, defaultStartingIndoorX, defaultStartingIndoorY, "down") end)
              end

              -- Now that the world mirrors the fresh save, persist it so the
              -- online save file carries the wiped events/mapScenes, not the
              -- previous character's.
              saveOnlineAccount(game.save)
              writeOnlineSave(game.save)
              syncLocalProfile(game, 0)
              fetchGtsServerSync(newTid)
              startChatSession(game)

              if ow and ow.player and ow.map and netOutChannel then
                local p = ow.player
                local delta = Collision.DELTA[p.facing] or { 0, 1 }
                local followerSpecies = game.save.party and game.save.party[1] and game.save.party[1].species

                netOutChannel:push({
                  url = getServerUrl() .. "/gts",
                  body = Json.encode({
                    action = "sync_pos",
                    modVersion = MOD_VERSION,
                    version = MOD_VERSION,
                    gameVersion = select(1, getClientVersionInfo()),
                    recompVersion = select(2, getClientVersionInfo()),
                    trainerId = tostring(newTid),
                    name = chosenName,
                    spriteId = localSelectedSprite,
                    title = localTrainerTitle,
                    level = 1,
                    map = ow.map.id,
                    x = p.cellX,
                    y = p.cellY,
                    px = p.cellX * 16,
                    py = p.cellY * 16,
                    fx = p.cellX - delta[1],
                    fy = p.cellY - delta[2],
                    facing = p.facing,
                    moving = false,
                    species = followerSpecies
                  })
                })
              end

              local createdMsg = string.format("PLAYER CREATED!\nTRAINER ID: %d\nTOKEN: %s\nWELCOME TO GEN 1 ONLINE!", newTid, acc.token or "READY")
              game.stack:push(TextBox.new(game, wrapText(createdMsg), function()
                openOnlineOptionsMenu(game)
              end))
            else
              local err = (res and res.error) or netDiagReport()
              local errMsg = string.format("COULD NOT CREATE PLAYER!\n%s", err)
              game.stack:push(TextBox.new(game, wrapText(errMsg)))
            end
          end
        })
      end
      game.stack:push(Menu.new(game, spriteItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
    end

    local function startNewCharacterFlow()
      GtsUI.nameEntry(game, {
        prompt = "YOUR ONLINE NAME?",
        maxLength = 7,
        onDone = function(enteredName)
          enteredName = (enteredName or ""):gsub("^%s+", ""):gsub("%s+$", "")
          if #enteredName == 0 then
            game.stack:push(TextBox.new(game, wrapText("PLEASE ENTER A VALID ONLINE NAME!"), function()
              startNewCharacterFlow()
            end))
            return
          end

          if Profanity and Profanity.contains and Profanity.contains(enteredName) then
            game.stack:push(TextBox.new(game, wrapText("NAME CONTAINS INAPPROPRIATE LANGUAGE!\nPLEASE CHOOSE ANOTHER NAME."), function()
              openFreshOnlinePlayerMenu(game)
            end))
            return
          end

          local check = gtsApiGet("/player/check_name?name="
            .. enteredName:gsub("[^%w]", function(c) return string.format("%%%02X", c:byte()) end), 1.5)
          if check and check.taken then
            local reasonMsg = string.format("NAME '%s' IS ALREADY TAKEN ON SERVER!", enteredName)
            game.stack:push(TextBox.new(game, wrapText(reasonMsg), function()
              local takenOptions = {
                {
                  label = "ENTER RECOVERY TOKEN",
                  onSelect = function()
                    openRedeemTokenMenu(game)
                  end
                },
                {
                  label = "CHOOSE DIFFERENT NAME",
                  onSelect = function()
                    startNewCharacterFlow()
                  end
                },
                { label = "CANCEL", onSelect = function() end }
              }
              game.stack:push(Menu.new(game, takenOptions, { tx = 1, ty = 1, tw = 18, maxVisible = 5, startCloses = true }))
            end))
          else
            pickCharacterSprite(enteredName)
          end
        end
      })
    end

    local connectOptions = {
      {
        label = "CREATE NEW PLAYER",
        onSelect = function()
          startNewCharacterFlow()
        end
      },
      {
        label = "REDEEM RECOVERY TOKEN",
        onSelect = function()
          openRedeemTokenMenu(game)
        end
      }
    }

    game.stack:push(Menu.new(game, connectOptions, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
  end

  -- In-Game Global & Local MMO Chat Menu
  openMmoChatMenu = function(game)
    local trainerId, trainerName = getTrainerInfo(game.save)

    loadChatNotifPref()
    local chatOptions = {
      {
        label = "TYPE CUSTOM MESSAGE",
        onSelect = function()
          ensureChatTextInputPatch()
          local screen = ChatInputScreen.new(game, {
            onDone = function(txt) sendGlobalChat(game, txt, "global") end,
            onCancel = function() end
          })
          game.stack:push(screen)
        end
      },
      {
        label = "SEND PRESET",
        onSelect = function()
          local chatPresets = {
            "HELLO EVERYONE!",
            "LOOKING FOR TRADES!",
            "ANYONE READY FOR PVP?",
            "GG, WELL PLAYED!",
            "JUST CAUGHT A RARE MON!",
            "AT INDIGO PLATEAU!",
            "TRADING AT GTS!",
            "EXPLORING KANTO/JOHTO!"
          }
          local presetItems = {}
          for _, msgText in ipairs(chatPresets) do
            table.insert(presetItems, {
              label = msgText:sub(1, 17),
              onSelect = function()
                sendGlobalChat(game, msgText, "global")
              end
            })
          end
          table.insert(presetItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, presetItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
        end
      },
      {
        label = ChatState.liveEnabled and "LIVE NOTIF: ON" or "LIVE NOTIF: OFF",
        onSelect = function()
          saveChatNotifPref(not ChatState.liveEnabled)
          game.stack:push(TextBox.new(game, wrapText(ChatState.liveEnabled and "LIVE NOTIFICATIONS\nENABLED!" or "LIVE NOTIFICATIONS\nDISABLED!")))
        end
      },
      {
        label = "VIEW CHAT LOG",
        onSelect = function()
          local res = gtsApiGet("/chat/history", 1.5)
          local msgs = (res and res.success and res.messages) or ChatState.history or {}
          if res and res.success and res.messages then ChatState.history = res.messages end
          -- mark read
          ChatState.unread = 0
          if res and res.messages then
            local maxId = 0
            for _, m in ipairs(res.messages) do maxId = math.max(maxId, tonumber(m.id) or 0) end
            if maxId > ChatState.lastId then ChatState.lastId = maxId end
          end
          local logItems = {}
          for i = #msgs, 1, -1 do
            local m = msgs[i]
            local previewTxt = (m.text or ""):gsub("[\r\n\f]", " ")
            if #previewTxt > 8 then previewTxt = previewTxt:sub(1, 7) .. ".." end
            local line = string.format("%s:%s", (m.name or "TR"):sub(1, 6), previewTxt)
            if #line > 16 then line = line:sub(1, 16) end
            table.insert(logItems, {
              label = line,
              onSelect = function()
                local fullText = string.format("%s (%s):\n%s", m.name or "TRAINER", (m.scope or "GLOBAL"):upper(), m.text or "")
                game.stack:push(TextBox.new(game, wrapText(fullText)))
              end
            })
          end
          table.insert(logItems, {
            label = "REPLY (TYPE)",
            onSelect = function()
              ensureChatTextInputPatch()
              local screen = ChatInputScreen.new(game, {
                onDone = function(txt) sendGlobalChat(game, txt, "global") end
              })
              game.stack:push(screen)
            end
          })
          table.insert(logItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, logItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
        end
      },
      { label = "EXIT", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, chatOptions, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
  end

    -- =========================================================================
  -- CO-OP MULTIPLAYER PARTY SYSTEM (Shared Double XP, Party Warp & Status HUD)
  -- =========================================================================

  openPartyMainMenu = function(game)
    local trainerId, trainerName = getTrainerInfo(game.save)
    local gWorld = getWorld(game)
    local curMap = (gWorld and gWorld.map and gWorld.map.id) or defaultStartingOutdoor
    local px = (gWorld and gWorld.player and gWorld.player.cellX) or defaultStartingOutdoorX
    local py = (gWorld and gWorld.player and gWorld.player.cellY) or defaultStartingOutdoorY

    if not activeParty then
      local soloItems = {
        {
          label = "CREATE PARTY",
          onSelect = function()
            local res = gtsApiPost({
              action = "party_create",
              trainerId = trainerId,
              name = trainerName,
              level = mmoLevel or 1,
              map = curMap,
              x = px,
              y = py,
              spriteId = localSelectedSprite
            }, 1.5)
            if res and res.success then
              activeParty = res.party
              local msg = "PARTY CREATED!\nINVITE PLAYERS TO TEAM UP AND WARP TO EACH OTHER!"
              game.stack:push(TextBox.new(game, wrapText(msg), function()
                openPartyMainMenu(game)
              end))
            else
              game.stack:push(TextBox.new(game, wrapText("COULD NOT CREATE PARTY!")))
            end
          end
        },
        {
          label = "INVITE PLAYER",
          onSelect = function()
            local pRes = gtsApiGet("/gts/players", 1.5)
            local players = (pRes and pRes.players) or {}
            local inviteItems = {}
            for tid, p in pairs(players) do
              if tostring(tid) ~= tostring(trainerId) then
                local pNameShort = (p.name or "TRAINER"):sub(1, 8)
                table.insert(inviteItems, {
                  label = string.format("%s (LV%d)", pNameShort, p.level or 1),
                  onSelect = function()
                    local iRes = gtsApiPost({
                      action = "party_invite",
                      trainerId = trainerId,
                      name = trainerName,
                      targetId = tid,
                      level = mmoLevel or 1,
                      map = curMap,
                      x = px,
                      y = py,
                      spriteId = localSelectedSprite
                    }, 1.5)
                    if iRes and iRes.success then
                      local msg = string.format("INVITATION SENT TO %s!", p.name or "TRAINER")
                      game.stack:push(TextBox.new(game, wrapText(msg)))
                    else
                      game.stack:push(TextBox.new(game, wrapText("COULD NOT SEND INVITE!")))
                    end
                  end
                })
              end
            end
            if #inviteItems == 0 then
              game.stack:push(TextBox.new(game, wrapText("NO OTHER PLAYERS CURRENTLY ONLINE.")))
            else
              table.insert(inviteItems, { label = "BACK", onSelect = function() end })
              game.stack:push(Menu.new(game, inviteItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
            end
          end
        },
        { label = "BACK", onSelect = function() end }
      }
      game.stack:push(Menu.new(game, soloItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
      return
    end

    -- In active party
    local isLeader = (tostring(activeParty.leaderId) == tostring(trainerId))
    local partyItems = {
      {
        label = "MEMBERS & HUD",
        onSelect = function()
          local memberItems = {}
          for mid, m in pairs(activeParty.members or {}) do
            local leaderTag = (tostring(mid) == tostring(activeParty.leaderId)) and "*" or ""
            local mNameShort = (m.name or "TRAINER"):sub(1, 8)
            table.insert(memberItems, {
              label = string.format("%s%s (LV%d)", mNameShort, leaderTag, m.level or 1),
              onSelect = function()
                local statusMsg = string.format("PARTY MEMBER:\nNAME: %s\nLEVEL: %d\nMAP: %s", m.name or "TRAINER", m.level or 1, m.map or "UNKNOWN")
                game.stack:push(TextBox.new(game, wrapText(statusMsg)))
              end
            })
          end
          table.insert(memberItems, { label = "BACK", onSelect = function() end })
          game.stack:push(Menu.new(game, memberItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
        end
      },
      {
        label = "WARP TO MEMBER",
        onSelect = function()
          local warpItems = {}
          for mid, m in pairs(activeParty.members or {}) do
            if tostring(mid) ~= tostring(trainerId) then
              local mNameShort = (m.name or "TRAINER"):sub(1, 10)
              table.insert(warpItems, {
                label = string.format("WARP: %s", mNameShort),
                onSelect = function()
                  local wRes = gtsApiPost({ action = "party_warp_target", targetId = mid }, 1.5)
                  local wWorld = getWorld(game)
                  if wRes and wRes.success and wWorld and wWorld.setMap then
                    pcall(function() require("src.core.Sound").play(game.data, "Teleport_Exit1") end)
                    wWorld:setMap(wRes.map or defaultStartingOutdoor, (wRes.x or 5) + 1, wRes.y or 5, "down")
                    local msg = string.format("WARPED TO %s!", m.name or "TEAMMATE")
                    game.stack:push(TextBox.new(game, wrapText(msg)))
                  else
                    game.stack:push(TextBox.new(game, wrapText("COULD NOT WARP TO MEMBER!")))
                  end
                end
              })
            end
          end
          if #warpItems == 0 then
            game.stack:push(TextBox.new(game, wrapText("NO OTHER PARTY MEMBERS TO WARP TO.")))
          else
            table.insert(warpItems, { label = "BACK", onSelect = function() end })
            game.stack:push(Menu.new(game, warpItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
          end
        end
      },
      {
        label = "INVITE PLAYER",
        onSelect = function()
          local pRes = gtsApiGet("/gts/players", 1.5)
          local players = (pRes and pRes.players) or {}
          local inviteItems = {}
          for tid, p in pairs(players) do
            if tostring(tid) ~= tostring(trainerId) and not (activeParty.members and activeParty.members[tostring(tid)]) then
              local pNameShort = (p.name or "TRAINER"):sub(1, 8)
              table.insert(inviteItems, {
                label = string.format("%s (LV%d)", pNameShort, p.level or 1),
                onSelect = function()
                  local iRes = gtsApiPost({
                    action = "party_invite",
                    trainerId = trainerId,
                    name = trainerName,
                    targetId = tid,
                    level = mmoLevel or 1,
                    map = curMap,
                    x = px,
                    y = py,
                    spriteId = localSelectedSprite
                  }, 1.5)
                  if iRes and iRes.success then
                    local msg = string.format("INVITATION SENT TO %s!", p.name or "TRAINER")
                    game.stack:push(TextBox.new(game, wrapText(msg)))
                  else
                    game.stack:push(TextBox.new(game, wrapText("COULD NOT SEND INVITE!")))
                  end
                end
              })
            end
          end
          if #inviteItems == 0 then
            game.stack:push(TextBox.new(game, wrapText("NO OTHER AVAILABLE PLAYERS ONLINE.")))
          else
            table.insert(inviteItems, { label = "BACK", onSelect = function() end })
            game.stack:push(Menu.new(game, inviteItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
          end
        end
      },
      {
        label = "LEAVE PARTY",
        onSelect = function()
          gtsApiPost({ action = "party_leave", trainerId = trainerId }, 1.5)
          activeParty = nil
          game.stack:push(TextBox.new(game, wrapText("LEFT THE PARTY.")))
        end
      },
      { label = "BACK", onSelect = function() end }
    }

    game.stack:push(Menu.new(game, partyItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

    -- Online Options Menu (Shown in Start Menu once connected)
  openServerUrlMenu = function(game)
    local info = string.format("CURRENT SERVER:\n%s\n\nTO CHANGE IT, DISCONNECT, THEN CHOOSE START > CONNECT > SERVER ADDRESS.",
      GtsUI.displayAddress(getServerUrl()))
    game.stack:push(TextBox.new(game, wrapText(info)))
  end

  -- Type a server address; on OK it is saved and the game connects to it.
  function GtsUI.openAddressEntry(game)
    game.stack:push(GtsUI.AddressScreen.new(game, {
      current = GtsUI.displayAddress(getServerUrl()),
      onDone = function(url)
        GtsUI.setServerUrl(url)
        handleConnectToServer(game)
      end,
    }))
  end

  -- START > CONNECT while offline
  function GtsUI.openConnectMenu(game)
    local addr = GtsUI.displayAddress(getServerUrl())
    local items = {
      { label = (#addr <= 12) and ("JOIN " .. addr) or "JOIN SERVER",
        onSelect = function() handleConnectToServer(game) end },
      { label = "SERVER ADDRESS", onSelect = function() GtsUI.openAddressEntry(game) end },
    }
    if GtsUI.serverUrlTyped then
      items[#items + 1] = { label = "USE CONFIG FILE", onSelect = function()
        GtsUI.setServerUrl(nil)
        game.stack:push(TextBox.new(game, wrapText("SERVER FROM gts_config.txt:\n"
          .. GtsUI.displayAddress(getServerUrl()))))
      end }
    end
    items[#items + 1] = { label = "CANCEL", onSelect = function() end }
    game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, startCloses = true }))
  end

  openOnlineOptionsMenu = function(game)
    local trainerId, trainerName = getTrainerInfo(game.save)
    loadOnlineAccount(game.save)

    local items = {
      {
        label = (activeParty and "PARTY (ACTIVE)") or "CO-OP PARTY",
        onSelect = function()
          openPartyMainMenu(game)
        end
      },
      {
        label = "MY PROFILE",
        onSelect = function()
          syncLocalProfile(game, 0)
          openTrainerCardScreen(game, trainerId, { name = trainerName })
        end
      },
      {
        label = string.format("EXP (LV%d)", mmoLevel or 1),
        onSelect = function()
          openMmoLevelInfoScreen(game)
        end
      },
      {
        label = "GLOBAL CHAT",
        onSelect = function() openMmoChatMenu(game) end
      },
      {
        label = "ONLINE SETTINGS",
        onSelect = function() openMyProfileMenu(game) end
      },
      {
        label = "SERVER URL",
        onSelect = function() openServerUrlMenu(game) end
      },
      {
        label = string.format("VERSION: V%s", MOD_VERSION),
        onSelect = function()
          local srvInfo = gtsApiGet("/server/info", 1.5)
          local srvVer = (srvInfo and (srvInfo.modVersion or srvInfo.version)) or MOD_VERSION
          local msg = string.format("MOD VERSION: V%s\nSERVER VERSION: V%s\nPROTOCOLS SYNCED!", MOD_VERSION, srvVer)
          game.stack:push(TextBox.new(game, wrapText(msg)))
        end
      },
      {
        label = "RESET / SWITCH",
        onSelect = function()
          local confirmMenu = {
            {
              label = "NO, KEEP CURRENT",
              onSelect = function() end
            },
            {
              label = "YES, RESET",
              onSelect = function()
                storageRemove("online_save")
                storageRemove("online_account")
                openFreshOnlinePlayerMenu(game)
              end
            }
          }
          game.stack:push(TextBox.new(game, wrapText("WARNING: THIS WILL OVERWRITE YOUR ONLINE CHARACTER! LOCAL SAVE IS UNTOUCHED. PROCEED?"), function()
            game.stack:push(Menu.new(game, confirmMenu, { tx = 0, ty = 0, tw = 20, maxVisible = 6, startCloses = true }))
          end))
        end
      },
      {
        label = "DISCONNECT",
        onSelect = function()
          GtsUI.sendLogout(game)
          isGtsServerConnected = false
          netNpcs = {}
          mod.exports.netNpcs = netNpcs
          netFollowers = {}
          if game and game.save then
            writeOnlineSave(game.save)
          end
          if offlineSaveBackup then
            game.save = offlineSaveBackup
            if game.adoptSave then game:adoptSave(game.save) end
            local ow = getWorld(game)
            if isGen2 and ow and ow.loadPlayerData then
              pcall(ow.loadPlayerData, ow, game.save)
              if ow.vm then ow.vm.events = ow.events end
            end
            local pMap = (game.save.position and game.save.position.map) or (game.save.player and game.save.player.map)
            local px = (game.save.position and game.save.position.x) or (game.save.player and game.save.player.x)
            local py = (game.save.position and game.save.position.y) or (game.save.player and game.save.player.y)
            local pFacing = (game.save.position and game.save.position.facing) or (game.save.player and game.save.player.facing) or "down"
            if ow and ow.setMap and pMap and px and py then
              pcall(ow.setMap, ow, pMap, px, py, pFacing)
            end
            GtsUI.restorePlayerSprite(game)
          end
          game.stack:push(TextBox.new(game, wrapText("DISCONNECTED FROM ONLINE SERVER.\nLOCAL OFFLINE SAVE RESTORED.")))
        end
      }
    }

    game.stack:push(Menu.new(game, items, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true }))
  end

  handleConnectToServer = function(game)
    -- 1. Verify Mod Version Handshake with Server First
    local srvInfo = gtsApiGet("/server/info", 3.0)
    if not srvInfo then
      -- nobody answered: say so, rather than offering to create a player
      GtsUI.openAddressEntry(game)
      game.stack:push(TextBox.new(game, wrapText("COULDN'T REACH THE SERVER AT "
        .. GtsUI.displayAddress(getServerUrl()) .. ".\nCHECK THE ADDRESS WITH THE HOST.")))
      return
    end
    if srvInfo and (srvInfo.modVersion or srvInfo.version) then
      local srvVer = srvInfo.modVersion or srvInfo.version
      -- the server's own rule (is_version_compatible): major.minor must
      -- match, so a patch release still connects to the same server
      local function series(v) return tostring(v or ""):match("^(%d+%.%d+)") end
      if series(srvVer) ~= series(MOD_VERSION) then
        local msg = string.format("VERSION MISMATCH!\nSERVER IS ON V%s\nYOUR MOD IS ON V%s\nPLEASE UPDATE TO PLAY!", srvVer, MOD_VERSION)
        game.stack:push(TextBox.new(game, wrapText(msg)))
        return
      end
    end
    -- One generation per server: a Gen 1 world turns Crystal away, and back.
    local srvGen = srvInfo and tonumber(srvInfo.generation)
    if srvGen and srvGen ~= (isGen2 and 2 or 1) then
      game.stack:push(TextBox.new(game, wrapText(GtsUI.wrongWorldText(srvGen))))
      return
    end

    -- 2. Backup the local offline save in memory and capture exact offline coordinates
    if game and game.save and not isGtsServerConnected then
      local ow = getWorld(game)
      if game.snapshotSave then
        pcall(function() game:snapshotSave() end)
      elseif ow and ow.player and ow.map then
        local p = ow.player
        if isGen2 then
          game.save.position = game.save.position or {}
          game.save.position.map = ow.map.id
          game.save.position.x = p.cellX
          game.save.position.y = p.cellY
          game.save.position.facing = p.facing
        end
        game.save.player = game.save.player or {}
        game.save.player.map = ow.map.id
        game.save.player.x = p.cellX
        game.save.player.y = p.cellY
        game.save.player.facing = p.facing
      end
      local SaveSerializer = require("src.core.SaveSerializer")
      local ok, encoded = pcall(SaveSerializer.encode, game.save)
      if ok and encoded then
        offlineSaveBackup = SaveSerializer.decode(encoded)
      else
        offlineSaveBackup = game.save
      end
    end

    -- 3. Check for existing online profile or launch Character Creation
    local onlineSave = loadOnlineSave(game)
    local onlineAcc = onlineSave and onlineSave.onlineAccount

    local loginSuccess = false
    if onlineAcc and onlineAcc.token then
      local loginRes = gtsApiPost({ action = "login_player", token = onlineAcc.token, trainerId = tostring(onlineAcc.trainerId) }, 2.0)
      if loginRes and loginRes.success and loginRes.account then
        onlineAcc = loginRes.account
        onlineSave.onlineAccount = onlineAcc
        loginSuccess = true
      end
    end

    if not loginSuccess then
      -- First time connecting or token invalid: Prompt user to create their online character!
      openFreshOnlinePlayerMenu(game)
      return
    end

    -- Adopt online save and restore exact location, map, flags, party, inventory
    mmoLevel = tonumber(onlineAcc.level) or 1
    mmoXp = tonumber(onlineAcc.xp) or 0
    mmoToken = onlineAcc.token
    localSelectedSprite = onlineAcc.spriteId or (isGen2 and "SPRITE_CHRIS" or "SPRITE_RED")
    localTrainerTitle = onlineAcc.title or "ACE TRAINER"
    localFavoriteMon = onlineAcc.favoriteMon or "PIKACHU"

    game.save = onlineSave
    if game.adoptSave then game:adoptSave(game.save) end

    local ow = getWorld(game)
    if isGen2 and ow and ow.loadPlayerData then
      pcall(ow.loadPlayerData, ow, game.save)
      if ow.vm then ow.vm.events = ow.events end
    end

    -- Teleport to the exact last recorded online location!
    local pMap = (game.save.position and game.save.position.map) or (game.save.player and game.save.player.map) or defaultStartingOutdoor
    local px = (game.save.position and game.save.position.x) or (game.save.player and game.save.player.x) or defaultStartingOutdoorX
    local py = (game.save.position and game.save.position.y) or (game.save.player and game.save.player.y) or defaultStartingOutdoorY
    local pFacing = (game.save.position and game.save.position.facing) or (game.save.player and game.save.player.facing) or "down"

    if ow and ow.setMap and pMap and px and py then
      pcall(ow.setMap, ow, pMap, px, py, pFacing)
    end

    applyPlayerSprite(game, localSelectedSprite)
    writeOnlineSave(game.save)
    isGtsServerConnected = true
    -- Init global chat poll state (vanilla wrap, no spam on connect)
    startChatSession(game)

    syncLocalProfile(game, 0)
    local tid, currentName = getTrainerInfo(game.save)

    if ow and ow.player and ow.map and netOutChannel then
      local p = ow.player
      local delta = Collision.DELTA[p.facing] or { 0, 1 }
      local followerSpecies = game and game.save and game.save.party and game.save.party[1] and game.save.party[1].species

      netOutChannel:push({
        url = getServerUrl() .. "/gts",
        body = Json.encode({
          action = "sync_pos",
          modVersion = MOD_VERSION,
          version = MOD_VERSION,
          gameVersion = select(1, getClientVersionInfo()),
          recompVersion = select(2, getClientVersionInfo()),
          trainerId = tid,
          name = onlineAcc.name or currentName,
          spriteId = localSelectedSprite,
          title = localTrainerTitle,
          level = mmoLevel,
          map = ow.map.id,
          x = p.cellX,
          y = p.cellY,
          px = p.cellX * 16,
          py = p.cellY * 16,
          fx = p.cellX - delta[1],
          fy = p.cellY - delta[2],
          facing = p.facing,
          moving = false,
          species = followerSpecies
        })
      })
    end

    local connMsg = string.format("CONNECTED TO SERVER!\nONLINE SAVE: %s\nLOCATION: %s", onlineAcc.name or currentName, tostring(pMap))
    game.stack:push(TextBox.new(game, wrapText(connMsg), function()
      openOnlineOptionsMenu(game)
    end))
  end
  _G.gtsConnectToServer = handleConnectToServer

  -- Active server logout (used by quit-to-title and the START-menu QUIT item).
  -- Stored on _G so the big returned function below does not need to capture
  -- the extra locals (LuaJIT's 60-upvalue cap on that closure).
  _G.__gtsQuitLogout = function(game)
    GtsUI.sendLogout(game)
  end

  -- Tell the server this player left, right now: a DISCONNECT or a QUIT.
  -- Queued on the async engine it never went out (the disconnected engine
  -- is reset every frame, and a quitting game is gone), so the server kept
  -- the session live: friends saw a frozen trainer for 30 s, and coming back
  -- within 10 s was refused as "ALREADY ACTIVE ON ANOTHER DEVICE".  The
  -- engine is reset first, so no queued sync can re-add the session after.
  -- Not for forced disconnects (another device, wrong version or world),
  -- which must not drop the other device's session.
  function GtsUI.sendLogout(game)
    if not isGtsServerConnected then return end
    local tid = getTrainerInfo(game and game.save)
    if not tid then return end
    asyncReset("logout")
    gtsApiPost({ action = "logout", trainerId = tid }, 1.5)
    gtsApiPost({ action = "clear_challenge", trainerId = tid }, 1.5)
  end


return function(mod)
  currentMod = mod
  print("[Gen1Online] Initializing Gen1Online Asynchronous Threaded 60FPS MMO Mod...")

  -- Wrap the START-menu QUIT / EXIT item so the player is actively logged out
  -- of the server before the app closes (never leave a ghost online).
  local function wrapQuitItems(game, list)
    if not list then return end
    for i, item in ipairs(list) do
      if item and item.label then
        local lbl = tostring(item.label):upper()
        if lbl == "QUIT" or lbl:find("EXIT") or lbl:find("SHUTDOWN") then
          local origSelect = item.onSelect
          item.onSelect = function(...)
            if _G.__gtsQuitLogout then pcall(function() _G.__gtsQuitLogout(game) end) end
            if origSelect then origSelect(...) end
          end
        end
      end
    end
  end

  -- Hook Start Menu (identical method as DebugMenu)
  mod.hooks:wrap("ui.start_menu.items", function(nextFn, game, items)
    local list = nextFn and nextFn(game, items) or items
    if not list or type(list) ~= "table" then list = items end

    -- While connected to the online server, hide the engine's SAVE row: online
    -- saves are written automatically to the server-backed save, so a manual
    -- save prompt would be misleading (matches the SaveData guards below).
    -- Only a LIVE connection hides it; a restored online profile that is not
    -- connected still shows SAVE.
    if isGtsServerConnected then
      for i = #list, 1, -1 do
        local item = list[i]
        if item then
          local itemValue = tostring(item.value or ""):lower()
          local itemLabel = tostring(item.label or ""):upper()
          if itemValue == "save" or itemLabel == "SAVE" then
            table.remove(list, i)
          end
        end
      end
    end

    local connectItem = {
      label = isGtsServerConnected and "ONLINE" or "CONNECT",
      onSelect = function()
        if isGtsServerConnected then
          openOnlineOptionsMenu(game)
        else
          GtsUI.openConnectMenu(game)
        end
      end,
    }

    local targetIndex = #list + 1
    for i, item in ipairs(list) do
      if item and item.label and tostring(item.label):upper():find("DEBUG") then
        targetIndex = i
        break
      end
    end

    table.insert(list, targetIndex, connectItem)
    wrapQuitItems(game, list)
    return list
  end)

  -- Patch Gen 2 CenterPcMenu (Main Pokemon Center PC Menu) to include GTS on the top-level UI
  pcall(function()
    if not isGen2 then return end -- a Gen 2 engine module
    local CenterPcMenu = require("src.ui.gen2.CenterPcMenu")
    if CenterPcMenu and CenterPcMenu.buildEntries then
      local origBuildEntries = CenterPcMenu.buildEntries
      CenterPcMenu.buildEntries = function(self)
        origBuildEntries(self)
        local entries = self.entries or {}
        local hasGts = false
        for _, e in ipairs(entries) do
          if e.id == "gts" then hasGts = true; break end
        end
        if not hasGts then
          local turnOffIdx = #entries
          for idx, e in ipairs(entries) do
            if e.id == "turnoff" then turnOffIdx = idx; break end
          end
          table.insert(entries, turnOffIdx, { id = "gts", label = "GTS" })
          self.entries = entries
        end
      end

      local origChoose = CenterPcMenu.choose
      CenterPcMenu.choose = function(self)
        local entry = self.entries and self.entries[self.index]
        if entry and entry.id == "gts" then
          self:playSfx("Sfx_ChoosePcOption")
          GtsUI.openGtsMainMenu(self.game)
          return
        end
        return origChoose(self)
      end
    end
  end)

  -- Patch Gen 1 PlayerPC (Bedroom PC in Red's House) to include GTS
  pcall(function()
    local PlayerPC = require("src.ui.PlayerPC")
    if PlayerPC and PlayerPC.new then
      local origNew = PlayerPC.new
      PlayerPC.new = function(game, opts)
        local menu = origNew(game, opts)
        if menu and menu.items then
          local hasGts = false
          for _, it in ipairs(menu.items) do
            if it.label == "GTS" then hasGts = true; break end
          end
          if not hasGts then
            local insertIdx = #menu.items
            table.insert(menu.items, insertIdx, {
              label = "GTS",
              keepOpen = true,
              onSelect = function()
                pcall(function() require("src.core.Sound").play(game.data, "Enter_PC") end)
                GtsUI.openGtsMainMenu(game)
              end
            })
            if menu.th then menu.th = #menu.items * 2 + 2 end
          end
        end
        return menu
      end
    end
  end)

  -- Hook PC Menu (Adds GTS to Gen 1 Pokemon Center main PC & Gen 2 Bedroom PC)
  mod.hooks:wrap("ui.pc.items", function(nextFn, game, items)
    local list = nextFn and nextFn(game, items) or items
    if not list or type(list) ~= "table" then list = items end

    -- Check if GTS already exists
    for _, it in ipairs(list) do
      if it.label == "GTS" or it.id == "gts" then return list end
    end

    -- In Gen 2, if this is an item storage submenu without house/decorations, skip adding GTS inside <PLAYER>'s PC
    local isItemSubMenu = false
    local hasHouse = false
    for _, it in ipairs(list) do
      if it.id == "withdraw" or it.id == "deposit" then isItemSubMenu = true end
      if it.id == "decoration" then hasHouse = true end
    end
    if isItemSubMenu and isGen2 and not hasHouse then
      return list
    end

    local gtsItem = {
      label = "GTS",
      id = "gts",
      keepOpen = true,
      onSelect = function()
        pcall(function() require("src.core.Sound").play(game.data, "Enter_PC") end)
        GtsUI.openGtsMainMenu(game)
      end
    }

    table.insert(list, gtsItem)
    return list
  end)

  -- =========================================================================
  -- AUTOMATIC IMMEDIATE SAVE & SYNC ON ALL TRAINER / PARTY / TRADE / BATTLE ACTIONS
  -- =========================================================================

  local function onEvent(eventName, callback)
    if mod and mod.events and type(mod.events.on) == "function" then
      pcall(function() mod.events:on(eventName, callback) end)
    end
  end

  -- 1. Battles Finished (Wild & Trainer Battles) - Handled in BattleState.finish hook below to prevent double XP triggers

  -- 2. Pokémon Caught
  onEvent("pokemon.caught", function(payload)
    if Game and Game.save then
      addMmoXp(Game, "catch")
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  -- 3. Pokémon Evolved & Move Learned
  onEvent("pokemon.evolved", function(payload)
    if Game and Game.save then
      addMmoXp(Game, "breeding", 50)
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  onEvent("pokemon.level_up", function(payload)
    if Game and Game.save then
      performForcedSave(Game)
    end
  end)

  onEvent("pokemon.move_learned", function(payload)
    if Game and Game.save then
      performForcedSave(Game)
    end
  end)

  -- 4. Trades & Pokémon Received
  onEvent("trade.completed", function(payload)
    if Game and Game.save then
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  onEvent("pokemon.received", function(payload)
    if Game and Game.save then
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  -- 5. Trainer Badges & Story Milestone Flags
  onEvent("flag.changed", function(payload)
    if Game and Game.save then
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  -- 6. Blackout / Party Fainted
  onEvent("world.blacked_out", function(payload)
    if Game and Game.save then
      Game.save.blackoutCount = (Game.save.blackoutCount or 0) + 1
      saveOnlineAccount(Game.save)
      performForcedSave(Game)
      syncLocalProfile(Game, 0)
    end
  end)

  -- 7. PC Box Storage Operations
  local BoxesModule = pcall(require, "src.pokemon.Boxes") and require("src.pokemon.Boxes") or nil
  if BoxesModule and BoxesModule.deposit then
    local origDeposit = BoxesModule.deposit
    BoxesModule.deposit = function(save, mon)
      local res = origDeposit(save, mon)
      if isGtsServerConnected and Game and Game.save then performForcedSave(Game) end
      return res
    end
  end

  -- 8. Bag & Inventory Operations
  local BagModule = pcall(require, "src.inventory.Bag") and require("src.inventory.Bag") or nil
  if BagModule then
    if BagModule.add then
      local origBagAdd = BagModule.add
      BagModule.add = function(save, itemId, count, data)
        local res = origBagAdd(save, itemId, count, data)
        if isGtsServerConnected and Game and Game.save then performForcedSave(Game) end
        return res
      end
    end
    if BagModule.remove then
      local origBagRemove = BagModule.remove
      BagModule.remove = function(save, itemId, count)
        local res = origBagRemove(save, itemId, count)
        if isGtsServerConnected and Game and Game.save then performForcedSave(Game) end
        return res
      end
    end
  end

  -- Hook Map Transition to clear and re-sync overworld entities
  local origSetMap = OverworldState.setMap
  OverworldState.setMap = function(self, mapId, cellX, cellY, facing)
    clearAllNetPlayers(self)
    local res = origSetMap(self, mapId, cellX, cellY, facing)
    lastPlayerMap = mapId
    if isGtsServerConnected and Game and Game.save and Game.save.position then
      Game.save.position.map = mapId
      Game.save.position.x = cellX or Game.save.position.x or 3
      Game.save.position.y = cellY or Game.save.position.y or 6
      Game.save.position.facing = facing or Game.save.position.facing or "down"
    end
    if NPCs and NPCs.spawnForMap then pcall(NPCs.spawnForMap, self) end
    return res
  end

  -- (MMO name tags are drawn in the world pass -- the drawPeople wrapper
  -- below -- not over the window: there they line up with their sprites and
  -- never paint over a battle, trade or evolution screen.)

  -- Hook Overworld Update with TRUE ZERO-LAG Async Threading & Lockout Guard
  local origOverworldUpdate = OverworldState.update
  OverworldState.update = function(self, dt)
    -- LOCKOUT PLAYER MOVEMENT WHILE WAITING FOR CHALLENGE RESPONSE
    if isWaitingForChallenge then
      challengeWaitTimer = (challengeWaitTimer or 0) + dt
      if challengeWaitTimer > 16.0 then
        isWaitingForChallenge = false
        challengeWaitTimer = 0
        Game.stack:push(TextBox.new(Game, "CHALLENGE TIMED OUT\nNO RESPONSE."))
      end
      -- Maintain NPC movement lerp
      for _, pNpc in pairs(netNpcs) do updateNpcMovement(pNpc, dt) end
      for _, fNpc in pairs(netFollowers) do updateNpcMovement(fNpc, dt) end

      -- CRITICAL: Keep pushing sync_pos to the background thread every 150ms so it
      -- polls the server and brings back the ACCEPT_PVP / DECLINE response.
      local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
      if now - lastSendTime >= 0.15 and self.player and self.map and netOutChannel then
        lastSendTime = now
        local trainerId, trainerName = getTrainerInfo(Game.save)
        local p = self.player
        local delta = Collision.DELTA[p.facing] or { 0, 1 }
        local followerSpecies = Game.save.party and Game.save.party[1] and Game.save.party[1].species
        netOutChannel:push({
          url = getServerUrl() .. "/gts",
          body = Json.encode({
            action = "sync_pos",
            trainerId = trainerId,
            sessionId = clientSessionId,
            name = trainerName,
            title = localTrainerTitle,
            map = self.map.id,
            x = p.cellX,
            y = p.cellY,
            px = p.px,
            py = p.py,
            fx = p.cellX - delta[1],
            fy = p.cellY - delta[2],
            facing = p.facing,
            moving = false,
            species = followerSpecies
          })
        })
      end

      -- Read any server responses the background thread has returned
      processGlobalThreadMessages(Game)
      return
    end

    if self.map and NPCs and NPCs.spawnForMap then
      pcall(NPCs.spawnForMap, self)
    end
    if origOverworldUpdate then origOverworldUpdate(self, dt) end
    if not Game or not isGtsServerConnected then return end

    -- 1. Background jobs run once per frame, from the core.update hook.

    -- 2. Push position to background network queue (Rate limited to preserve 60FPS fluid gameplay)
    local ow = self
    local p = ow.player
    if p and ow.map and netOutChannel then
      local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
      local positionChanged = (p.cellX ~= lastPlayerX) or (p.cellY ~= lastPlayerY) or (ow.map.id ~= lastPlayerMap)
      local movingChanged = (p.moving ~= lastPlayerMoving)
      local isMoving = (p.moving == true) or positionChanged

      if movingChanged or (isMoving and now - lastSendTime >= 0.10) or (now - lastSendTime >= GtsUI.idleSyncInterval()) then
        lastSendTime = now
        lastPlayerX = p.cellX
        lastPlayerY = p.cellY
        lastPlayerMap = ow.map.id
        lastPlayerMoving = p.moving

        if Game and Game.save and Game.save.position then
          Game.save.position.map = ow.map.id
          Game.save.position.x = p.cellX
          Game.save.position.y = p.cellY
          Game.save.position.facing = p.facing
        end

        local trainerId, trainerName = getTrainerInfo(Game.save)
        local followerSpecies = Game.save.party and Game.save.party[1] and Game.save.party[1].species

        local delta = Collision.DELTA[p.facing] or { 0, 1 }
        local fx = p.cellX - delta[1]
        local fy = p.cellY - delta[2]

        local payload = {
          action = "sync_pos",
          modVersion = MOD_VERSION,
          version = MOD_VERSION,
          gameVersion = select(1, getClientVersionInfo()),
          recompVersion = select(2, getClientVersionInfo()),
          trainerId = trainerId,
          sessionId = clientSessionId,
          name = trainerName,
          spriteId = localSelectedSprite,
          title = localTrainerTitle,
          level = mmoLevel,
          map = ow.map.id,
          x = p.cellX,
          y = p.cellY,
          px = p.px,
          py = p.py,
          fx = fx,
          fy = fy,
          facing = p.facing,
          moving = p.moving,
          species = followerSpecies
        }

        netOutChannel:push({
          url = getServerUrl() .. "/gts",
          body = Json.encode(payload)
        })

        processGlobalThreadMessages(Game)
      end
    end
  end

  -- Hook Gen 1 Overworld drawWorld to render remote player sprites
  if not isGen2 and type(OverworldState) == "table" then
    local dwKey = "draw" .. "World"
    local origGen1DrawWorld = OverworldState[dwKey]
    if origGen1DrawWorld then
      OverworldState[dwKey] = function(self)
        return GtsUI.gen1DrawWorld(self, origGen1DrawWorld)
      end
    end
  end


  local origTalkTo = OverworldState.talkTo
  OverworldState.talkTo = function(self, npc)
    local helpers = {
      wrapText = wrapText,
      getTrainerId = getTrainerId,
      fetchPlayerQuests = fetchPlayerQuests,
      questApiPost = gtsApiPost,
      activeQuestsCache = activeQuestsCache,
      findBugHeadButterfreeIndex = Quests.findBugHeadButterfreeIndex,
      addMmoXp = addMmoXp
    }
    if NPCs.talkTo and NPCs.talkTo(self, npc, helpers) then
      return
    end
    return origTalkTo and origTalkTo(self, npc)
  end

  -- Hook Overworld Interact (Facing any MMO player on the map and pressing A)
  local origInteract = OverworldState.interact
  OverworldState.interact = function(self)
    if isWaitingForChallenge then return end

    local p1 = self.player
    local fx, fy = p1:facingCell()

    for tid, pNpc in pairs(netNpcs) do
      if pNpc.cellX == fx and pNpc.cellY == fy then
        local rawData = netPlayerMap[tid] or {}
        local pName = rawData.name or "TRAINER"
        local targetTid = pNpc.trainerId or tid

        local items = {
          {
            label = "VIEW TRAINER CARD",
            onSelect = function()
              openTrainerCardScreen(Game, targetTid, rawData)
            end
          },
          {
            label = "PVP 1V1 SINGLES",
            onSelect = function()
              if not Game.save or not Game.save.party or #Game.save.party == 0 then
                Game.stack:push(TextBox.new(Game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
                return
              end
              local myId, myName = getTrainerInfo(Game.save)
              local myPackedParty = packPartyForGame(Game, Game.save.party)
              local linkSeed = math.random(1, 2^30)
              local roomId = NativePvp.offerRoom("BATTLE_"
                .. tostring(math.min(tonumber(myId) or 0, tonumber(targetTid) or 0))
                .. "_"
                .. tostring(math.max(tonumber(myId) or 0, tonumber(targetTid) or 0))
                .. "_" .. tostring(linkSeed))

              isWaitingForChallenge = true
              challengeWaitTimer = 0

              gtsApiPost({
                action = "send_challenge",
                targetId = targetTid,
                fromId = myId,
                fromName = myName,
                challengeType = "PVP",
                party = myPackedParty,
                seed = linkSeed,
                roomId = roomId
              }, 1.5)
              Game.stack:push(TextBox.new(Game, string.format("WAITING FOR %s\nTO ACCEPT 1V1 PVP...", pName)))
            end
          },
          {
            label = "LINK TRADE",
            onSelect = function()
              if not Game.save or not Game.save.party or #Game.save.party == 0 then
                Game.stack:push(TextBox.new(Game, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO TRADE!")))
                return
              end
              local myId, myName = getTrainerInfo(Game.save)
              local roomId = "TRADE_"
                .. tostring(math.min(tonumber(myId) or 0, tonumber(targetTid) or 0))
                .. "_"
                .. tostring(math.max(tonumber(myId) or 0, tonumber(targetTid) or 0))
                .. "_" .. tostring(math.random(1, 2^30))

              isWaitingForChallenge = true
              challengeWaitTimer = 0

              gtsApiPost({
                action = "send_challenge",
                targetId = targetTid,
                fromId = myId,
                fromName = myName,
                challengeType = "TRADE",
                roomId = roomId
              }, 1.5)
              Game.stack:push(TextBox.new(Game, wrapText(string.format("WAITING FOR %s TO ACCEPT TRADE...", pName))))
            end
          },
          { label = "CANCEL", onSelect = function() end }
        }
        Game.stack:push(Menu.new(Game, items, { tx = 1, ty = 1, tw = 16, th = 8 }))
        return
      end
    end
    return origInteract(self)
  end

  -- =========================================================================
  -- GEN 2 (GOLD) WORLD HOOKS (setMap, drawWorldBody, step, interact)
  -- =========================================================================
  local okGen2World, Gen2World = false, nil
  if isGen2 then okGen2World, Gen2World = pcall(require, "src.world.gen2.World") end
  if okGen2World and Gen2World then
    -- 1. Gen 2 Map Transition Hook
    local origGen2SetMap = Gen2World.setMap
    Gen2World.setMap = function(self, mapId, cx, cy, facing, opts)
      clearAllNetPlayers(self)
      local res = origGen2SetMap(self, mapId, cx, cy, facing, opts)
      lastPlayerMap = mapId
      local curGame = self.game or Game
      if isGtsServerConnected and curGame and curGame.save then
        if curGame.save.player then
          curGame.save.player.map = mapId
          curGame.save.player.x = cx or (self.player and self.player.cellX) or defaultStartingOutdoorX
          curGame.save.player.y = cy or (self.player and self.player.cellY) or defaultStartingOutdoorY
          curGame.save.player.facing = facing or (self.player and self.player.facing) or "down"
        end
        if curGame.save.position then
          curGame.save.position.map = mapId
          curGame.save.position.x = cx or (self.player and self.player.cellX) or defaultStartingOutdoorX
          curGame.save.position.y = cy or (self.player and self.player.cellY) or defaultStartingOutdoorY
          curGame.save.position.facing = facing or (self.player and self.player.facing) or "down"
        end
      end
      if NPCs and NPCs.spawnForMap then pcall(NPCs.spawnForMap, self) end
      -- Persist on map transition (throttled): story scripts set event flags /
      -- map scenes during the previous map (e.g. EVENT_RIVAL_NEW_BARK_TOWN set
      -- at Mr. Pokémon's, Route 32 scene), and the next map change is when the
      -- world actually reflects them. Snapshot + save here so the online save
      -- never lags a story beat behind.
      if isGtsServerConnected and curGame and curGame.save then
        local nowMap = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
        local lastSave = self._gtsLastMapSaveTime or 0
        if nowMap - lastSave >= 1.0 then
          self._gtsLastMapSaveTime = nowMap
          performForcedSave(curGame)
        end
      end
      return res
    end

    -- 2. Gen 2 sprite persistence: map loads / teleports / dismounts run
    -- World:applyPlayerState, which snaps the local sprite back to the
    -- default SPRITE_CHRIS (src/world/gen2/World.lua:5310).  Re-apply the
    -- chosen avatar whenever the player returns to the normal walk state;
    -- bike/surf keep their own state sprites.
    local okFieldMoves, FieldMoves = pcall(require, "src.world.gen2.FieldMoves")
    if okFieldMoves and FieldMoves and Gen2World.applyPlayerState then
      local origApplyPlayerState = Gen2World.applyPlayerState
      Gen2World.applyPlayerState = function(self, state)
        local res = origApplyPlayerState(self, state)
        if isGtsServerConnected
            and (self.playerState or FieldMoves.PLAYER_NORMAL)
              == FieldMoves.PLAYER_NORMAL then
          applyPlayerSprite(self.game or Game, localSelectedSprite)
        end
        return res
      end
    end

    -- 3. Gen 2 Overworld Step & Async Multi-Net Sync Hook
    local origGen2Step = Gen2World.step
    Gen2World.step = function(self)
      local curGame = self.game or Game
      -- LOCKOUT PLAYER MOVEMENT WHILE WAITING FOR CHALLENGE RESPONSE
      if isWaitingForChallenge then
        local dt = 1 / 60
        challengeWaitTimer = (challengeWaitTimer or 0) + dt
        if challengeWaitTimer > 16.0 then
          isWaitingForChallenge = false
          challengeWaitTimer = 0
          if curGame and curGame.stack then
            curGame.stack:push(TextBox.new(curGame, "CHALLENGE TIMED OUT\nNO RESPONSE."))
          end
        end
        for _, pNpc in pairs(netNpcs) do updateNpcMovement(pNpc, dt) end
        for _, fNpc in pairs(netFollowers) do updateNpcMovement(fNpc, dt) end

        local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
        if now - lastSendTime >= 0.15 and self.player and self.map and netOutChannel then
          lastSendTime = now
          local trainerId, trainerName = getTrainerInfo(curGame.save)
          local p = self.player
          local delta = Collision.DELTA[p.facing] or { 0, 1 }
          local followerSpecies = curGame.save and curGame.save.party and curGame.save.party[1] and curGame.save.party[1].species
          netOutChannel:push({
            url = getServerUrl() .. "/gts",
            body = Json.encode({
              action = "sync_pos",
              trainerId = trainerId,
              sessionId = clientSessionId,
              name = trainerName,
              title = localTrainerTitle,
              map = self.map.id,
              x = p.cellX,
              y = p.cellY,
              px = p.px,
              py = p.py,
              fx = p.cellX - delta[1],
              fy = p.cellY - delta[2],
              facing = p.facing,
              moving = false,
              species = followerSpecies
            })
          })
        end
        return
      end

      if self.map and NPCs and NPCs.spawnForMap then
        pcall(NPCs.spawnForMap, self)
      end

      if origGen2Step then origGen2Step(self) end
      if not curGame or not isGtsServerConnected then return end

      -- (background jobs run once per frame, from the core.update hook: a
      -- second and third run here made remote players interpolate 3x fast)

      local p = self.player
      if p and self.map and netOutChannel then
        local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
        local positionChanged = (p.cellX ~= lastPlayerX) or (p.cellY ~= lastPlayerY) or (self.map.id ~= lastPlayerMap)
        local movingChanged = (p.moving ~= lastPlayerMoving)
        local isMoving = (p.moving == true) or positionChanged

        if movingChanged or (isMoving and now - lastSendTime >= 0.10) or (now - lastSendTime >= GtsUI.idleSyncInterval()) then
          lastSendTime = now
          lastPlayerX = p.cellX
          lastPlayerY = p.cellY
          lastPlayerMap = self.map.id
          lastPlayerMoving = p.moving

          if curGame.save and curGame.save.player then
            curGame.save.player.map = self.map.id
            curGame.save.player.x = p.cellX
            curGame.save.player.y = p.cellY
            curGame.save.player.facing = p.facing
          end
          if curGame.save and curGame.save.position then
            curGame.save.position.map = self.map.id
            curGame.save.position.x = p.cellX
            curGame.save.position.y = p.cellY
            curGame.save.position.facing = p.facing
          end

          local trainerId, trainerName = getTrainerInfo(curGame.save)
          local followerSpecies = curGame.save and curGame.save.party and curGame.save.party[1] and curGame.save.party[1].species
          local delta = Collision.DELTA[p.facing] or { 0, 1 }
          local fx = p.cellX - delta[1]
          local fy = p.cellY - delta[2]

          local payload = {
            action = "sync_pos",
            modVersion = MOD_VERSION,
            version = MOD_VERSION,
            gameVersion = select(1, getClientVersionInfo()),
            recompVersion = select(2, getClientVersionInfo()),
            trainerId = trainerId,
            sessionId = clientSessionId,
            name = trainerName,
            spriteId = localSelectedSprite,
            title = localTrainerTitle,
            level = mmoLevel,
            map = self.map.id,
            x = p.cellX,
            y = p.cellY,
            px = p.px,
            py = p.py,
            fx = fx,
            fy = fy,
            facing = p.facing,
            moving = p.moving,
            species = followerSpecies
          }

          netOutChannel:push({
            url = getServerUrl() .. "/gts",
            body = Json.encode(payload)
          })

          processGlobalThreadMessages(curGame)
        end
      end
    end

    -- 4. Gen 2 Overworld Interaction Hook (A-button on remote players)
    local origGen2Interact = Gen2World.interact
    Gen2World.interact = function(self)
      if isWaitingForChallenge then return end
      local curGame = self.game or Game
      local p1 = self.player
      if not p1 then return origGen2Interact and origGen2Interact(self) end
      local d = Collision.DELTA[p1.facing] or { 0, 1 }
      local fx, fy = p1.cellX + d[1], p1.cellY + d[2]

      for tid, pNpc in pairs(netNpcs) do
        if pNpc.cellX == fx and pNpc.cellY == fy then
          local rawData = netPlayerMap[tid] or {}
          local pName = rawData.name or "TRAINER"
          local targetTid = pNpc.trainerId or tid

          local items = {
            {
              label = "VIEW TRAINER CARD",
              onSelect = function()
                openTrainerCardScreen(curGame, targetTid, rawData)
              end
            },
            {
              label = "PVP 1V1 SINGLES",
              onSelect = function()
                if not curGame.save or not curGame.save.party or #curGame.save.party == 0 then
                  curGame.stack:push(TextBox.new(curGame, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO BATTLE!")))
                  return
                end
                local myId, myName = getTrainerInfo(curGame.save)
                local myPackedParty = packPartyForGame(curGame, curGame.save.party)
                local linkSeed = math.random(1, 2^30)
                local roomId = NativePvp.offerRoom("BATTLE_"
                  .. tostring(math.min(tonumber(myId) or 0, tonumber(targetTid) or 0))
                  .. "_"
                  .. tostring(math.max(tonumber(myId) or 0, tonumber(targetTid) or 0))
                  .. "_" .. tostring(linkSeed))

                isWaitingForChallenge = true
                challengeWaitTimer = 0

                gtsApiPost({
                  action = "send_challenge",
                  targetId = targetTid,
                  fromId = myId,
                  fromName = myName,
                  challengeType = "PVP",
                  party = myPackedParty,
                  seed = linkSeed,
                  roomId = roomId
                }, 1.5)
                curGame.stack:push(TextBox.new(curGame, string.format("WAITING FOR %s\nTO ACCEPT 1V1 PVP...", pName)))
              end
            },
            {
              label = "LINK TRADE",
              onSelect = function()
                if not curGame.save or not curGame.save.party or #curGame.save.party == 0 then
                  curGame.stack:push(TextBox.new(curGame, wrapText("YOU NEED AT LEAST 1 POKéMON IN YOUR PARTY TO TRADE!")))
                  return
                end
                local myId, myName = getTrainerInfo(curGame.save)
                local roomId = "TRADE_"
                  .. tostring(math.min(tonumber(myId) or 0, tonumber(targetTid) or 0))
                  .. "_"
                  .. tostring(math.max(tonumber(myId) or 0, tonumber(targetTid) or 0))
                  .. "_" .. tostring(math.random(1, 2^30))

                isWaitingForChallenge = true
                challengeWaitTimer = 0

                gtsApiPost({
                  action = "send_challenge",
                  targetId = targetTid,
                  fromId = myId,
                  fromName = myName,
                  challengeType = "TRADE",
                  roomId = roomId
                }, 1.5)
                curGame.stack:push(TextBox.new(curGame, wrapText(string.format("WAITING FOR %s TO ACCEPT TRADE...", pName))))
              end
            },
            { label = "CANCEL", onSelect = function() end }
          }
          curGame.stack:push(Menu.new(curGame, items, { tx = 1, ty = 1, tw = 16, th = 8 }))
          return
        end
      end
      return origGen2Interact and origGen2Interact(self)
    end

    -- 5. Gen 2 remote player sprite drawing. netNpcs are NOT part of self.npcs,
    -- so the engine never rendered them (name tags drew via render.hud, sprites
    -- were invisible). Hook drawPeople (called by both the flat drawWorldBody
    -- path and the tilt path) and draw each remote sprite using the SAME
    -- transform the local player uses (src/world/gen2/Player.lua:198):
    -- translate by the camera offset, scale by the zoom, then sprite:draw at
    -- the entity's own world px/py. This keeps size, position and animation in
    -- lockstep with the local character.
    if Gen2World.drawPeople then
      local origGen2DrawPeople = Gen2World.drawPeople
      local drawDiagTime = 0
      Gen2World.drawPeople = function(self, s, billboard)
        local res = origGen2DrawPeople(self, s, billboard)
        local drawn = 0
        if isGtsServerConnected and self.camera and next(netNpcs) then
          local cam = self.camera
          local ox = (0 - (cam.x or 0)) * (s or 1)
          local oy = (0 - (cam.y or 0)) * (s or 1)
          local G = love.graphics
          for _, pNpc in pairs(netNpcs) do
            if pNpc and pNpc.sprite and pNpc.px and pNpc.py then
              pcall(function()
                G.push()
                G.translate(ox, oy)
                G.scale(s or 1, s or 1)
                pNpc.sprite:draw(
                  pNpc.px, pNpc.py, 0, 0,
                  pNpc.facing, pNpc:walkPhase(), pNpc.stepFlip)
                G.pop()
              end)
              drawn = drawn + 1
            end
          end
        end
        -- Name tags, in the same camera transform as the sprites so each sits
        -- right above its trainer, and only when the overworld itself is
        -- drawn.  Half the world scale keeps them small; a light plate keeps
        -- them readable on any ground.
        if isGtsServerConnected and self.camera and self.player then
          local G = love.graphics
          local cam, scale = self.camera, (s or 1)
          local function tag(name, wx, wy)
            name = tostring(name or "TRAINER"):gsub("_", " ")
            local width = Font.width(name)
            local x = math.floor((wx + 8) * 2 - width / 2)
            local y = math.floor((wy - 12) * 2)
            G.setColor(1, 1, 1, 0.85)
            G.rectangle("fill", x - 1, y - 1, width + 2, 10)
            G.setColor(1, 1, 1, 1)
            Font.draw(name, x, y)
          end
          G.push()
          G.translate(-(cam.x or 0) * scale, -(cam.y or 0) * scale)
          G.scale(scale / 2, scale / 2)
          pcall(function()
            for tid, pNpc in pairs(netNpcs) do
              if pNpc and pNpc.px and pNpc.py then
                local rawData = netPlayerMap[tid] or {}
                tag(rawData.name or pNpc.name, pNpc.px, pNpc.py)
              end
            end
            local save = self.game and self.game.save
            tag((save and save.onlineAccount and save.onlineAccount.name)
              or (save and save.player and save.player.name) or "YOU",
              self.player.px or 0, self.player.py or 0)
          end)
          G.pop()
          G.setColor(1, 1, 1, 1)
        end
        -- Diagnostic (throttled, developer mode only): how many remote
        -- sprites this pass drew.
        local nowD = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
        if mod.developer and (drawDiagTime == 0 or nowD - drawDiagTime >= 3.0) then
          drawDiagTime = nowD
          diag("drawPeople remote sprites drawn=%d s=%s", drawn, tostring(s))
        end
        return res
      end
    end
  end

  -- Wrap Game.update to continuously service active GtsNetAdapter during battle
  mod.hooks:wrap("core.update", function(nextFn, game, dt)
    currentGame = game
    -- (the 1x speed lock while connected is Game2.speedLocked, below)

    if nextFn then nextFn(game, dt) end

    -- Continuous frame service for background jobs (sync, placement, and battle messages)
    Jobs.step(game, dt)
    -- Advance the non-blocking sync client every frame (non-blocking and
    -- crash-proof) so it can complete requests and recover from stalls.
    asyncPoll()
    -- Global chat live poll + overworld queue drain (vanilla TextBox style)
    if isGtsServerConnected then
      loadChatNotifPref()
      ChatState.pollTimer = (ChatState.pollTimer or 0) + dt
      if ChatState.pollTimer >= (ChatState.pollInterval or 5.0) then
        ChatState.pollTimer = 0
        pcall(pollGlobalChat, game)
      end
      pcall(serviceChatFetch, game)
      pcall(drainChatNotifQueue, game)
    end

    -- Low-rate keepalive ping (only when player is stationary / in menu)
    local gWorld = getWorld(game)
    -- If the session is disconnected, tear down any leftover async connection
    -- so a stale engine can't interfere with a later reconnect.
    if not isGtsServerConnected and asyncReset then
      asyncReset("disconnected")
    end
    if isGtsServerConnected and not isWaitingForChallenge and gWorld
       and gWorld.player and gWorld.map and netOutChannel then
      local ow = gWorld
      local p = ow.player
      local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
      if not p.moving and (now - lastSendTime >= GtsUI.idleSyncInterval()) then
        lastSendTime = now
        lastPlayerX = p.cellX
        lastPlayerY = p.cellY
        lastPlayerMap = ow.map.id

        local trainerId, trainerName = getTrainerInfo(game.save)
        local followerSpecies = game.save.party and game.save.party[1] and game.save.party[1].species
        local delta = Collision.DELTA[p.facing] or { 0, 1 }

        netOutChannel:push({
          url = getServerUrl() .. "/gts",
          body = Json.encode({
            action = "sync_pos",
            trainerId = trainerId,
            name = trainerName,
            title = localTrainerTitle,
            map = ow.map.id,
            x = p.cellX,
            y = p.cellY,
            px = p.px,
            py = p.py,
            fx = p.cellX - delta[1],
            fy = p.cellY - delta[2],
            facing = p.facing,
            moving = false,
            species = followerSpecies
          })
        })
      end
    end

    -- Hook Catch XP reward & Analytics Stat reporting
    if Party and Party.add and not Party._mmoHooked then
      Party._mmoHooked = true
      local origPartyAdd = Party.add
      Party.add = function(party, mon)
        local res = origPartyAdd(party, mon)
        if res and Game and isGtsServerConnected then
          addMmoXp(Game, "catch")
          local tid = getTrainerId and getTrainerId(Game.save) or "100001"
          local sp = mon and mon.species
          gtsApiPost({ action = "report_battle_stat", trainerId = tid, battleType = "wild", species = sp, caught = true })
        end
        return res
      end
    end

    -- Hook Wild / Trainer Battle XP reward & Analytics Stat reporting (Single Authoritative Hook)
    if BattleState and BattleState.finish and not BattleState._mmoHooked then
      BattleState._mmoHooked = true
      local origBattleFinish = BattleState.finish
      BattleState.finish = function(self)
        if self.result == "win" and Game and isGtsServerConnected then
          local tid = getTrainerId and getTrainerId(Game.save) or "100001"
          local isTrainer = (self.kind == "trainer" or self.trainer ~= nil or self.oppClass ~= nil)
          if isTrainer then
            addMmoXp(Game, "trainer_battle")
            gtsApiPost({ action = "report_battle_stat", trainerId = tid, battleType = "npc" })
            if self.oppClass == "OPP_ROUTE2_DAN" or self.oppClass == "OPP_ROUTE2_DAVE" then
              if Game.save then Game.save.route2BrothersDefeated = true end
            end
          else
            addMmoXp(Game, "wild_battle")
            local species = self.enemy and self.enemy.mon and self.enemy.mon.species
            gtsApiPost({ action = "report_battle_stat", trainerId = tid, battleType = "wild", species = species })
          end
          performForcedSave(Game)
          syncLocalProfile(Game, 0)
        end
        if origBattleFinish then origBattleFinish(self) end
      end
    end
  end)

  -- Helper to format full chat messages with wrapping and separation for Pokegear scrolling view
  local function buildChatLines(msgs, maxLineChars)
    maxLineChars = maxLineChars or 20
    local lines = {}
    if not msgs or #msgs == 0 then return lines end
    -- Most recent chats at the top
    for i = #msgs, 1, -1 do
      local m = msgs[i]
      if m then
        local sender = (m.name or "TR"):sub(1, 8)
        local prefix = sender .. ":"
        local text = (m.text or ""):gsub("[\r\n\f]+", " ")

        local words = {}
        for w in text:gmatch("%S+") do
          table.insert(words, w)
        end

        if #words == 0 then
          table.insert(lines, prefix)
        else
          local curLine = prefix
          for _, word in ipairs(words) do
            while #word > maxLineChars do
              local part = word:sub(1, maxLineChars)
              word = word:sub(maxLineChars + 1)
              if #curLine == 0 or curLine == prefix then
                table.insert(lines, curLine .. " " .. part)
                curLine = "  "
              else
                table.insert(lines, curLine)
                table.insert(lines, "  " .. part)
                curLine = "  "
              end
            end

            if #word > 0 then
              local testLine = (#curLine == 0 or curLine == "  ") and (curLine .. word) or (curLine .. " " .. word)
              if #testLine <= maxLineChars then
                curLine = testLine
              else
                table.insert(lines, curLine)
                curLine = "  " .. word
              end
            end
          end
          if #curLine > 0 and curLine ~= "  " then
            table.insert(lines, curLine)
          end
        end

        -- Gap between distinct messages
        if i > 1 then
          table.insert(lines, "")
        end
      end
    end
    return lines
  end

  local pokegearChatRegistered = false
  local function tryRegisterPokegearChatCard()
    if pokegearChatRegistered then return true end
    local ok, api = pcall(function() return mod.find and mod.find("pokegear_cards") and mod.find("pokegear_cards").exports end)
    if not ok or not api or not api.register then return false end
    -- Also ensure isGen2 (Crystal only)
    if not isGen2 then return false end
    local H = api.helpers
    local regOk, err = api.register({
      id = "global_chat",
      label = function() return (ChatState.unread and ChatState.unread > 0) and string.format("CHAT (%d)", ChatState.unread) or "CHAT" end,
      icon = 0x44, -- distinct communication icon (never shares 0x40 map icon)
      iconX = 8, -- separate 5th tab slot (Clock=0, Map=2, Phone=4, Radio=6, Chat=8)
      priority = 100,
      visible = function(gear) return isGtsServerConnected end,
      onHighlight = function(gear)
        loadChatNotifPref()
        ChatState.unread = 0
        pcall(pollGlobalChat, gear.game or currentGame)
      end,
      draw = function(gear)
        -- 1. Draw top icon strip first
        H.drawStrip(gear)

        loadChatNotifPref()

        -- 2. Content box below arrow indicator (arrow spans y=1.5..2.5)
        -- Interior: 18 wide, 10 high (tx=0, ty=3, tw=20, th=12, covers up to y=15)
        H.textbox(gear, 0, 3, 18, 10)

        -- Header line inside box at row 4
        H.text(gear, "GLOBAL CHAT", 2, 4)
        H.text(gear, ChatState.liveEnabled and "[ON]" or "[OFF]", 14, 4)

        local s = (api.state and api.state("global_chat")) or ChatState
        local msgs = ChatState.history or {}
        if (#msgs == 0) and isGtsServerConnected and not ChatState._hasDrawnOnce then
          ChatState._hasDrawnOnce = true
          pcall(pollGlobalChat, gear.game or currentGame)
          msgs = ChatState.history or {}
        end
        local lines = buildChatLines(msgs, 20)
        local visibleCount = 5
        local maxScroll = math.max(0, #lines - visibleCount)
        s.scroll = math.max(0, math.min(s.scroll or 0, maxScroll))

        if #lines == 0 then
          H.text(gear, "NO CHAT YET!", 2, 7)
          H.text(gear, "PRESS A TO SEND", 2, 8)
        else
          local G = love.graphics
          local Font = require("src.render.Font")
          local scale = 0.75

          -- Render full wrapped lines
          for slot = 1, visibleCount do
            local lineIdx = (s.scroll or 0) + slot
            local line = lines[lineIdx]
            if line and line ~= "" then
              local py = 43 + (slot - 1) * 10
              G.push()
              G.translate(16, py)
              G.scale(scale, scale)
              G.setColor(0, 0, 0, 1)
              Font.draw(line, 0, 0)
              G.pop()
              G.setColor(1, 1, 1, 1)
            end
          end

          -- Scroll arrows on right margin
          if (s.scroll or 0) > 0 then
            H.text(gear, "▲", 18, 5)
          end
          if (s.scroll or 0) < maxScroll then
            H.text(gear, "▼", 18, 10)
          end
        end

        -- Controls footer at row 12 and 13 (clean two-column alignment within 18 cols)
        H.text(gear, "▲▼:SCROLL", 2, 12)
        H.text(gear, "A:MENU", 12, 12)
        H.text(gear, "L/R:NOTIF", 2, 13)
        H.text(gear, "B:BACK", 12, 13)
      end,
      update = function(gear, input, dt)
        local s = (api.state and api.state("global_chat")) or ChatState
        local msgs = ChatState.history or {}
        local lines = buildChatLines(msgs, 20)
        local visibleCount = 5
        local maxScroll = math.max(0, #lines - visibleCount)

        if input:wasPressed("up") then
          if (s.scroll or 0) > 0 then
            s.scroll = s.scroll - 1
            pcall(function()
              if gear.game and gear.game.data then
                require("src.core.Sound").play(gear.game.data, "Press_AB")
              end
            end)
          end
          return
        end

        if input:wasPressed("down") then
          if (s.scroll or 0) < maxScroll then
            s.scroll = (s.scroll or 0) + 1
            pcall(function()
              if gear.game and gear.game.data then
                require("src.core.Sound").play(gear.game.data, "Press_AB")
              end
            end)
          end
          return
        end

        if input:wasPressed("left") or input:wasPressed("right") or input:wasPressed("select") then
          saveChatNotifPref(not ChatState.liveEnabled)
          pcall(function()
            if gear.game and gear.game.data then
              require("src.core.Sound").play(gear.game.data, "Press_AB")
            end
          end)
          return
        end

        if input:wasPressed("a") then
          local game = gear.game or currentGame
          if not game then return end
          pcall(function()
            if game.data then require("src.core.Sound").play(game.data, "Press_AB") end
          end)

          -- Clear unread on interaction
          ChatState.unread = 0
          local res = gtsApiGet("/chat/history", 1.5)
          if res and res.success and res.messages then
            ChatState.history = res.messages
          end

          local chatPresets = {
            "HELLO EVERYONE!",
            "LOOKING FOR TRADES!",
            "ANYONE READY FOR PVP?",
            "GG, WELL PLAYED!",
            "JUST CAUGHT A RARE MON!",
            "AT INDIGO PLATEAU!",
            "TRADING AT GTS!",
            "EXPLORING JOHTO!"
          }

          local actions = {
            {
              label = "TYPE MESSAGE",
              onSelect = function()
                ensureChatTextInputPatch()
                local screen = ChatInputScreen.new(game, {
                  onDone = function(txt)
                    sendGlobalChat(game, txt, "global")
                  end
                })
                game.stack:push(screen)
              end
            },
            {
              label = "SEND PRESET",
              onSelect = function()
                local presetItems = {}
                for _, msgText in ipairs(chatPresets) do
                  table.insert(presetItems, {
                    label = msgText:sub(1, 17),
                    onSelect = function()
                      sendGlobalChat(game, msgText, "global")
                    end
                  })
                end
                table.insert(presetItems, { label = "BACK", onSelect = function() end })
                game.stack:push(Menu.new(game, presetItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
              end
            },
            {
              label = "VIEW FULL LOG",
              onSelect = function()
                local histRes = gtsApiGet("/chat/history", 1.5)
                local histMsgs = (histRes and histRes.success and histRes.messages) or ChatState.history or {}
                if histRes and histRes.success and histRes.messages then
                  ChatState.history = histRes.messages
                end
                local logItems = {}
                for i = #histMsgs, 1, -1 do
                  local m = histMsgs[i]
                  local previewTxt = (m.text or ""):gsub("[\r\n\f]", " ")
                  if #previewTxt > 8 then previewTxt = previewTxt:sub(1, 7) .. ".." end
                  local line = string.format("%s:%s", (m.name or "TR"):sub(1, 6), previewTxt)
                  if #line > 16 then line = line:sub(1, 16) end
                  table.insert(logItems, {
                    label = line,
                    onSelect = function()
                      local fullText = string.format("%s (%s):\n%s", m.name or "TRAINER", (m.scope or "GLOBAL"):upper(), m.text or "")
                      game.stack:push(TextBox.new(game, wrapText(fullText)))
                    end
                  })
                end
                table.insert(logItems, {
                  label = "REPLY (TYPE)",
                  onSelect = function()
                    ensureChatTextInputPatch()
                    local screen = ChatInputScreen.new(game, {
                      onDone = function(txt) sendGlobalChat(game, txt, "global") end
                    })
                    game.stack:push(screen)
                  end
                })
                table.insert(logItems, { label = "BACK", onSelect = function() end })
                game.stack:push(Menu.new(game, logItems, { tx = 1, ty = 1, tw = 18, maxVisible = 6, startCloses = true }))
              end
            },
            {
              label = ChatState.liveEnabled and "LIVE NOTIF: ON" or "LIVE NOTIF: OFF",
              onSelect = function()
                saveChatNotifPref(not ChatState.liveEnabled)
                game.stack:push(TextBox.new(game, wrapText(ChatState.liveEnabled and "LIVE NOTIFICATIONS\nENABLED!" or "LIVE NOTIFICATIONS\nDISABLED!")))
              end
            },
            { label = "BACK", onSelect = function() end }
          }

          game.stack:push(Menu.new(game, actions, { tx = 1, ty = 2, tw = 18, maxVisible = 5, startCloses = true }))
        end
      end,
      onEnter = function(gear)
        ChatState.unread = 0
        pcall(pollGlobalChat, gear.game or currentGame)
      end,
      busy = function(gear) return false end,
    })
    if regOk then pokegearChatRegistered = true end
    return regOk and true or false
  end
  -- Attempt immediate register, plus retry on every core.update until success
  pcall(tryRegisterPokegearChatCard)
  local _origTryRegister = tryRegisterPokegearChatCard
  mod.hooks:wrap("core.update", function(nextFn, game, dt)
    if not pokegearChatRegistered then pcall(_origTryRegister) end
    if nextFn then return nextFn(game, dt) end
  end)


  local function loadLocal(mod, relative)
    local source = nil
    if mod and mod.read then pcall(function() source = mod:read(relative) end) end
    if not source then return {} end
    local loadFn = loadstring or load
    local chunk, err = loadFn(source, "@" .. (mod.path or "mod") .. "/" .. tostring(relative))
    if not chunk then return {} end
    local ok, res = pcall(chunk)
    if not ok then return {} end
    return res or {}
  end

  local function safeCall(fn, ...)
    if type(fn) == "function" then
      local ok, res = pcall(fn, ...)
      if ok then return res end
    end
    return fn or {}
  end

  -- Load and wire the (currently empty) NPC and quest registries, on every
  -- generation (before the casino, which Gen 1 skips). Each
  -- module is `return function(loadModFile, mod) ... return api end`. The
  -- overworld hooks call NPCs.spawnForMap / NPCs.talkTo / Quests.* at runtime,
  -- so assigning the top-level locals here (before the factory returns) makes
  -- the real modules visible to them.
  local NPCsModule = loadLocal(mod, "npcs/init.lua")
  local QuestsModule = loadLocal(mod, "quests/init.lua")
  local function installModule(fn, fallback)
    if type(fn) == "function" then
      local ok, res = pcall(fn, loadLocal, mod)
      if ok and type(res) == "table" then return res end
    end
    return fallback
  end
  NPCs = installModule(NPCsModule, NPCs)
  Quests = installModule(QuestsModule, Quests)

  -- The casino (Crash, Tube Flyer, Prize Case, the pawn shop) takes over the
  -- Celadon Game Corner's clerks and raises the coin cap, which would change
  -- vanilla Red/Blue/Yellow, so on Gen 1 it is not set up at all.  (Its map
  -- hookup was GAME_CORNER talk scripts; see git history to restore it.)
  if not isGen2 then
    print("[Gen1Online+] Asynchronous Threaded 60FPS Multiplayer Mod initialized successfully.")
    return
  end

  local paths = { crash = "games/crash/", tube = "games/tube_flyer/", case = "games/prize_case/" }
  local CrashRules, FlappyRules, CaseRules = loadLocal(mod, paths.crash .. "rules.lua"), loadLocal(mod, paths.tube .. "rules.lua"), loadLocal(mod, paths.case .. "rules.lua")
  local ArcadeUI = loadLocal(mod, "games/shared/ui.lua")
  local CrashView, TubeView, CaseView = safeCall(loadLocal(mod, paths.crash .. "view.lua"), ArcadeUI), safeCall(loadLocal(mod, paths.tube .. "view.lua"), ArcadeUI), safeCall(loadLocal(mod, paths.case .. "view.lua"), ArcadeUI)
  local Catalog, Pawn, Services, UIFactory = loadLocal(mod, "other/prizes/catalog.lua"), loadLocal(mod, "other/pawn/rules.lua"), loadLocal(mod, "other/services.lua"), loadLocal(mod, "other/ui.lua")
  local CoinCase, Lounge = loadLocal(mod, "other/coin_case.lua"), loadLocal(mod, "other/lounge.lua")
  local Stats, Sound = require("src.pokemon.Stats"), require("src.core.Sound")

  local ids = {
    pokemon = "BlackjackCornerPokemonPrizes",
    item = "BlackjackCornerItemPrizes",
    crash = "BlackjackCornerCrash",
    tube = "BlackjackCornerTubeFlyer",
    case = "BlackjackCornerPrizeCase",
    lounge = "BLACKJACK_LOUNGE",
  }
  local config = {
    coinCap = 1000000,
    coinBundle = 50,
    coinBundlePrice = 1000,
    masterBallKey = "master_ball_redeemed",
    pawnLedgerKey = "pawned_pokemon",
  }

  if mod.options and mod.options.define then
    pcall(function()
      mod.options:define({
        { key = "shiny_sparkles", label = "SHINY SPARKLES", type = "toggle", default = true },
      })
    end)
  end
  if mod.content and mod.content.constants and mod.content.constants.patch then
    pcall(function() mod.content.constants:patch("coinCap", config.coinCap) end)
  end
  if type(CoinCase) == "function" then
    local ok, res = pcall(CoinCase, mod)
    if ok and type(res) == "table" then CoinCase = res end
  end
  if type(CoinCase) == "table" and CoinCase.installSlotCompatibility then
    pcall(CoinCase.installSlotCompatibility, config.coinCap)
    pcall(CoinCase.installHiddenCoinCompatibility, config.coinCap)
  end

  local Service = safeCall(Services, mod, Catalog, Pawn, config)
  local UI = safeCall(UIFactory, mod, Service, Catalog, Pawn, config)
  local function playSound(game, name) if Sound and Sound.play and game and game.data then Sound.play(game.data, name) end end
  local common = {
    mod = mod, coins = (Service and Service.coins), coinCap = config.coinCap,
    close = (UI and UI.close), play = playSound,
  }
  local function context(extra)
    local out = {}
    for key, value in pairs(common) do out[key] = value end
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
  end

  local Crash = safeCall(loadLocal(mod, paths.crash .. "screen.lua"), context({
    rules = CrashRules, view = CrashView,
  }))
  local TubeFlyer = safeCall(loadLocal(mod, paths.tube .. "screen.lua"), context({
    rules = FlappyRules, view = TubeView,
  }))
  local PrizeCase = safeCall(loadLocal(mod, paths.case .. "screen.lua"), context({
    rules = CaseRules, view = CaseView,
    rewardPool = function(game) return (Service and Service.caseRewardPool and Service.caseRewardPool(game, CaseRules)) end,
    giveReward = (Service and Service.giveCaseReward),
  }))

  if mod.content and mod.content.screens and mod.content.screens.register then
    for screen, class in pairs({
      [ids.crash] = Crash, [ids.tube] = TubeFlyer, [ids.case] = PrizeCase,
    }) do
      pcall(function() mod.content.screens:register(screen, { new = class.new }) end)
    end
    pcall(function() mod.content.screens:register(ids.pokemon, { new = UI.pokemonMenu }) end)
    pcall(function() mod.content.screens:register(ids.item, { new = UI.itemMenu }) end)
  end

  local function getDerivedPath(subpath)
    return "save/mod-derived/" .. tostring(mod.id or "gen1online-plus") .. "/" .. subpath
  end

  if mod.content and mod.content.sprites and mod.content.sprites.register then
    for _, machine in ipairs({ "crash", "flappy", "case" }) do
      for piece = 1, 2 do
        local sub = string.format("world/%s_machine_%02d.png", machine, piece)
        pcall(function()
          mod.content.sprites:register(("SPRITE_ARCADE_%s_%02d")
            :format(machine:upper(), piece), {
              image = getDerivedPath(sub), frames = 1, trueColor = true,
            })
        end)
      end
    end
  end

  if type(Lounge) == "table" and Lounge.register then
    pcall(Lounge.register, mod, ids.lounge)
  elseif type(Lounge) == "function" then
    pcall(Lounge, mod, ids.lounge)
  end

  local function openCasino(game, message, screen, done)
    UI.openAfterMessage(game, message, screen, done)
  end

  print("[Gen1Online+] Asynchronous Threaded 60FPS Multiplayer Mod initialized successfully.")
end
