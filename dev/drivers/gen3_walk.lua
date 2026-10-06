-- The FireRed / LeafGreen map walk: does every ball and hidden item on a
-- logic map sit where the logic says it can be reached?  A BFS within each
-- map, from its warps and edges, on FireRed's own collision (elevation,
-- water, one-way ledges and directional blocks), with Cut trees, Rock Smash
-- rocks and Strength boulders as walls unless the requirement has the HM.
--
-- What a requirement holds includes what it implies: the shuffle never
-- moves L.FIXED's items, so holding one (HM03) means its spot was reached
-- (FUCHSIA, so CUT).  On the maps in SWITCH_MAPS the gates are switches in
-- the same map: every cell a script there can open (setmetatile ...
-- passable) counts as open.
--
--   local walk = dofile(os.getenv("G1O_DEV") .. "/drivers/gen3_walk.lua")
--   local wrong, total = walk(raw, L, locs)    -- raw = the Game3
-- Rebinds the collision grid while it walks; the caller binds the current
-- map again afterwards.
local SWITCH_MAPS = {
  FR_POKEMON_MANSION_1F = true, FR_POKEMON_MANSION_2F = true,
  FR_POKEMON_MANSION_3F = true, FR_POKEMON_MANSION_B1F = true,
}

return function(raw, L, locs)
  local Collision = require("src.core.game3.collision")
  local Connections = require("src.core.game3.connections")
  local Space = require("src.core.game3.scripting.space")
  local maps = raw.data.maps
  local scripts = Space.ensureBundle().scripts
  local GFX = require("src.core.game3.constants.firered.event_objects").byName
  local TREE, ROCK, BOULDER = GFX.OBJ_EVENT_GFX_CUT_TREE, GFX.OBJ_EVENT_GFX_ROCK_SMASH_ROCK,
    GFX.OBJ_EVENT_GFX_PUSHABLE_BOULDER
  local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
  local function gfxOf(o) local g = o.graphicsId or o.graphics; return tonumber(g) or GFX[g] end

  -- the requirement and everything it implies (L.FIXED never moves)
  local function implied(set)
    local out, changed = {}, true
    for k in pairs(set) do out[k] = true end
    while changed do
      changed = false
      for item in pairs(out) do
        local req = L.FIXED[item]
        if req then
          for k in pairs(L.expand(req)) do
            if not out[k] then out[k], changed = true, true end
          end
        end
      end
    end
    return out
  end

  -- cells the map's own scripts can make passable (its switch gates)
  local function switchCells(def)
    local seen, order = {}, {}
    local function add(k) if type(k) == "string" and scripts[k] and not seen[k] then seen[k] = true; order[#order + 1] = k end end
    local function scan(v, depth)
      if depth > 3 then return end
      if type(v) == "string" then add(v)
      elseif type(v) == "table" then for _, x in pairs(v) do scan(x, depth + 1) end end
    end
    scan(def.mapScripts, 0)
    for _, list in ipairs({ def.bgEvents or {}, def.coordEvents or {}, def.objects or {} }) do
      for _, e in ipairs(list) do add(e.scriptKey) end
    end
    local open, i = {}, 1
    while i <= #order do
      for _, r in ipairs(scripts[order[i]]) do
        for _, v in pairs(r) do add(v) end
        if r.op == "setmetatile" and tonumber(r[4]) == 0 and tonumber(r[1]) and tonumber(r[2]) then
          open[tonumber(r[2]) * 4096 + tonumber(r[1])] = true
        end
      end
      i = i + 1
    end
    return open
  end

  local function walk(mapId, cap)
    local def = maps[mapId]
    if not (def and def.midLayout and Collision.bindMap(raw, mapId, def)) then return nil end
    local W, Ht = def.midLayout.width, def.midLayout.height
    local wall = {}
    for _, o in ipairs(def.objects or {}) do
      local g = gfxOf(o)
      if (g == TREE and not cap.cut) or (g == ROCK and not cap.smash) or (g == BOULDER and not cap.strength) then
        wall[o.y * 4096 + o.x] = true
      end
    end
    local gate = SWITCH_MAPS[mapId] and switchCells(def) or {}
    local function walkable(x, y) return gate[y * 4096 + x] or Collision.isWalkable(x, y) end
    local seen, cells, queue = {}, {}, {}
    local function push(x, y, e, surf)
      if x < 0 or y < 0 or x >= W or y >= Ht or wall[y * 4096 + x] then return end
      e = e or 0
      local k = ((y * 4096 + x) * 16 + e) * 2 + (surf and 1 or 0)
      if seen[k] then return end
      seen[k], cells[y * 4096 + x] = true, true
      queue[#queue + 1] = { x, y, e, surf }
    end
    local function enter(x, y)
      if x < 0 or y < 0 or x >= W or y >= Ht then return end
      local e = Collision.elevationOn(def, x, y) or 0
      if Collision.isWaterOn(def, x, y) then
        if cap.surf then push(x, y, e, true) end
      elseif walkable(x, y) then
        push(x, y, e, false)
      end
    end
    for _, w in ipairs(def.warps or {}) do push(w.x, w.y, Collision.elevationOn(def, w.x, w.y), false) end
    for _, c in ipairs(Connections.each(def)) do
      local n = (c.dir == "north" or c.dir == "south") and W or Ht
      for i = 0, n - 1 do
        if c.dir == "north" then enter(i, 0) elseif c.dir == "south" then enter(i, Ht - 1)
        elseif c.dir == "west" then enter(0, i) elseif c.dir == "east" then enter(W - 1, i) end
      end
    end
    local i = 1
    while i <= #queue do
      local x, y, e, surf = queue[i][1], queue[i][2], queue[i][3], queue[i][4]
      i = i + 1
      for dir, d in pairs(DIRS) do
        local tx, ty = x + d[1], y + d[2]
        if not surf then
          local lx, ly = Collision.ledgeLanding(raw, x, y, dir)
          if lx then push(lx, ly, (Collision.nextElevation(def, e, lx, ly, x, y)), false) end
        end
        if Collision.inBounds(tx, ty) and not wall[ty * 4096 + tx]
            and not Collision.directionallyImpassable(x, y, tx, ty, dir) then
          local mismatch = Collision.elevationMismatchOn(def, e, tx, ty)
          local water = Collision.isWaterOn(def, tx, ty)
          local nextE = (Collision.nextElevation(def, e, tx, ty, x, y))
          if surf then
            if water then
              if not mismatch then push(tx, ty, nextE, true) end
            elseif walkable(tx, ty) then
              -- getting off: onto the same level, or a shore (elevation 3)
              if not mismatch then push(tx, ty, nextE, false)
              elseif Collision.elevationOn(def, tx, ty) == 3 then push(tx, ty, 3, false) end
            end
          elseif water then
            -- SURF from the shore: any surfable tile faced
            if cap.surf and Collision.isSurfable(Collision.behaviorOn(def, tx, ty)) then
              push(tx, ty, Collision.elevationOn(def, tx, ty), true)
            end
          elseif not mismatch and walkable(tx, ty) then
            push(tx, ty, nextE, false)
          end
        end
      end
    end
    return cells
  end

  local function beside(cells, x, y)
    if cells[y * 4096 + x] then return true end
    for _, d in pairs(DIRS) do if cells[(y + d[2]) * 4096 + (x + d[1])] then return true end end
    return false
  end

  local wrong, total, walked = {}, 0, {}
  for _, loc in ipairs(locs) do
    if (loc.kind == "ball" or loc.kind == "hidden") and not loc.reqSet.__NEVER__ then
      local have = implied(loc.reqSet)
      local cap = { cut = have.HM01, surf = have.HM03, strength = have.HM04, smash = have.HM06 }
      local key = loc.map .. (cap.cut and "c" or "") .. (cap.surf and "s" or "") .. (cap.strength and "t" or "")
        .. (cap.smash and "r" or "")
      if walked[key] == nil then walked[key] = walk(loc.map, cap) or false end
      local x = loc.kind == "ball" and loc.x or loc.ref.x
      local y = loc.kind == "ball" and loc.y or loc.ref.y
      if walked[key] and x and y then
        total = total + 1
        if not beside(walked[key], x, y) then
          wrong[#wrong + 1] = ("%s %s %s (%d,%d)"):format(loc.map, loc.kind, loc.vanilla.item, x, y)
        end
      end
    end
  end
  table.sort(wrong)
  return wrong, total
end
