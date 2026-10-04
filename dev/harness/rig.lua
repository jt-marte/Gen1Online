-- Shared rig for the synthetic tests: boots the mod through gen1recomp's real
-- Loader and sandbox on a Crystal version, with a real gen2 World over a
-- synthetic map, a real StateStack and a real Crystal new-game save.  No ROM.
-- Run from the gen1recomp checkout (dev/run_tests.sh does this).
--
-- env: G1O_WORK (toolchain root), MOD_DIR (this repo), DEV=1 (mod developer
-- mode, which turns the mod's diag() lines on), VERBOSE=1 (echo engine log)
local Rig = {}

local WORK = assert(os.getenv("G1O_WORK"), "G1O_WORK")
package.path = "./?.lua;./?/init.lua;" .. WORK .. "/root/usr/share/lua/5.1/?.lua;"
  .. WORK .. "/root/usr/share/lua/5.1/?/init.lua;" .. package.path
package.cpath = WORK .. "/root/usr/lib64/lua/5.1/?.so;" .. package.cpath

love = require("tests.love_stub")
local socket = require("socket")
love.timer = love.timer or {}
love.timer.getTime = socket.gettime

local GameVersion = require("src.core.GameVersion")
GameVersion.set("crystal")

-- ------- swallowed-error capture: the mod pcall()s nearly everything, so the
-- sandbox's pcall is wrapped to record every error it would have hidden
Rig.errors = {}
local function record(kind, err)
  local msg = tostring(err)
  if msg:find("module '[^']+' not found") then return end
  Rig.errors[#Rig.errors + 1] = kind .. ": " .. msg
end
Rig.record = record

local Sandbox = require("src.mods.Sandbox")
local origEnvFor = Sandbox.envFor
Sandbox.envFor = function(opts)
  local env = origEnvFor(opts)
  local realPcall = env.pcall
  local function pack(...) return { n = select("#", ...), ... } end
  env.pcall = function(f, ...)
    local r = pack(realPcall(f, ...))
    if not r[1] then record("pcall", r[2]) end
    return unpack(r, 1, r.n)
  end
  return env
end

local Logger = require("src.core.Logger")
Rig.logs = {}
for _, level in ipairs({ "error", "warn", "info" }) do
  local orig = Logger[level]
  Logger[level] = function(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    Rig.logs[#Rig.logs + 1] = level:upper() .. ": " .. (ok and msg or tostring(fmt))
    if os.getenv("VERBOSE") and orig then return orig(fmt, ...) end
  end
end

-- ------- io-backed fs with a virtual mods/gen1online-plus ------------------
local MOD_DIR = assert(os.getenv("MOD_DIR"), "MOD_DIR")
Rig.overrides = {}   -- relative path -> contents, layered over the real mod
Rig.writes = {}      -- path -> contents written through the fs (all in memory)
local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end
local function isDir(path)
  local ok = os.execute("test -d '" .. path .. "'")
  return ok == true or ok == 0
end
local function rel(path) return path:match("^mods/gen1online%-plus/?(.*)$") end
local fs = {}
function fs.read(path)
  if Rig.writes[path] then return Rig.writes[path] end
  local r = rel(path)
  if r and Rig.overrides[r] then return Rig.overrides[r] end
  if r then return readFile(MOD_DIR .. "/" .. r) end
  return nil
end
function fs.getInfo(path)
  if path == "mods" then return { type = "directory" } end
  if Rig.writes[path] then return { type = "file", size = #Rig.writes[path] } end
  local r = rel(path)
  if not r then return nil end
  if r == "" then return { type = "directory" } end
  if Rig.overrides[r] then return { type = "file", size = #Rig.overrides[r] } end
  local p = MOD_DIR .. "/" .. r
  if isDir(p) then return { type = "directory" } end
  local s = readFile(p)
  if s then return { type = "file", size = #s } end
  return nil
end
function fs.load(path)
  local s = fs.read(path)
  if not s then return nil, "unable to read " .. path end
  return loadstring(s, "@" .. path)
end
function fs.getDirectoryItems(path)
  if path == "mods" then return { "gen1online-plus" } end
  local r = rel(path)
  if not r then return {} end
  local out = {}
  local pipe = io.popen("ls -1 '" .. MOD_DIR .. "/" .. r .. "' 2>/dev/null")
  for line in pipe:lines() do out[#out + 1] = line end
  pipe:close()
  return out
end
function fs.write(path, data) Rig.writes[path] = tostring(data); return true end
function fs.createDirectory() return true end
function fs.remove(path) Rig.writes[path] = nil; return true end
Rig.fs = fs

-- saves, mod.storage and the legacy compat store all land in memory too
love.filesystem = love.filesystem or {}
for k, v in pairs(fs) do
  if k ~= "load" then love.filesystem[k] = v end
end

-- ------- the game ------------------------------------------------------------
local StateStack = require("src.core.StateStack")
local World = require("src.world.gen2.World")
local Gen2Save = require("src.core.gen2.Save")

local COLL_FLOOR, COLL_GRASS = 0x00, 0x18
local MAP_W, MAP_H = 10, 9

function Rig.fakeMap(id)
  return {
    id = id or "NEW_BARK_TOWN",
    width = MAP_W, height = MAP_H,
    widthCells = MAP_W * 2, heightCells = MAP_H * 2,
    def = { bgEvents = {}, objects = {}, width = MAP_W, height = MAP_H },
    cellCollision = function(_, x, y)
      if x >= 4 and x <= 9 and y >= 10 and y <= 14 then return COLL_GRASS end
      return COLL_FLOOR
    end,
    inBounds = function(_, x, y)
      return x >= 0 and y >= 0 and x < MAP_W * 2 and y < MAP_H * 2
    end,
    isWalkable = function() return true end,
    isWalkableCell = function() return true end,
    warpAt = function() return nil end,
  }
end

function Rig.newInput()
  local input = { pressed = {}, held = {} }
  function input:press(b) self.pressed[b] = true end
  function input:wasPressed(b)
    if self.pressed[b] then self.pressed[b] = nil; return true end
    return false
  end
  function input:isDown(b) return self.held[b] == true end
  function input:update() end
  return input
end

function Rig.newGame()
  local save = Gen2Save.newGame({ playerName = "KRIS", trainerId = 4242 })
  save.party = {
    { species = "CYNDAQUIL", nickname = "CYNDAQUIL", level = 7, hp = 24,
      maxHp = 24, moves = { { id = "TACKLE", pp = 35 } },
      dvs = { attack = 9, defense = 8, speed = 7, special = 6 } },
  }
  save.position = { map = "NEW_BARK_TOWN", x = 6, y = 6, facing = "down" }
  local game = {
    data = { pokemon = { CYNDAQUIL = { name = "CYNDAQUIL" } },
             gen2Sprites = {}, sprites = {}, audio = { cries = {}, sfx = {} } },
    save = save,
    options = { speed = 3, speedOverworld = 3 },
    input = Rig.newInput(),
    stack = StateStack.new and StateStack.new() or setmetatable({}, { __index = StateStack }),
    phase = "world",
  }
  if not game.stack.states then game.stack:init() end
  local world = World.new(game)
  game.world = world
  world.map = Rig.fakeMap()
  world.maps = { NEW_BARK_TOWN = world.map.def }
  world.player = {
    cellX = 6, cellY = 6, px = 96, py = 96, facing = "down", moving = false,
    turnArmed = true, stepFlip = false, animClock = 0,
    update = function() return false end,
    setSprite = function(self, def) self.spriteDef = def end,
    facingCell = function(self)
      local d = ({ up = {0,-1}, down = {0,1}, left = {-1,0}, right = {1,0} })[self.facing]
      return self.cellX + d[1], self.cellY + d[2]
    end,
    walkPhase = function() return 0 end,
    draw = function(self) self.drawn = (self.drawn or 0) + 1 end,
  }
  world.npcs, world.entities = {}, { world.player }
  world.pollTimeOfDay = function() end
  world.tilesets = world.tilesets or {}
  world.camera = { x = 16, y = 24 }
  world.showText = function(self, body, onDone) if onDone then onDone() end end
  game.stack:push(world)
  -- the Game2 methods the mod calls
  function game:snapshotSave() return self.save end
  function game:adoptSave(s) self.save = s end
  function game:returnToTitle() self.returnedToTitle = true end
  function game:logicSpeed() return self.options.speed end
  return game
end

function Rig.load(game)
  local Loader = require("src.mods.Loader")
  local loader = Loader.new({ fs = fs, generation = 2, version = "crystal",
    dev = os.getenv("DEV") == "1" })
  loader.game = game
  local ok, err = pcall(function() return loader:load(game.data) end)
  Rig.loader, Rig.Runtime = loader, require("src.mods.Runtime")
  return ok, err
end

function Rig.hook(name, vanilla, ...)
  return Rig.Runtime.call(name, vanilla, ...)
end

function Rig.dump(label)
  print(("---- %s: %d swallowed errors"):format(label, #Rig.errors))
  local seen = {}
  for _, e in ipairs(Rig.errors) do
    if not seen[e] then seen[e] = true; print("  " .. e) end
  end
  Rig.errors = {}
end

return Rig
