-- A seeded random number generator that gives the same numbers on every
-- client: Park-Miller "minimal standard" (x = x * 16807 mod 2^31 - 1).
-- Pure double arithmetic -- 16807 * (2^31 - 2) stays under 2^53 -- so it
-- needs no bit library and LuaJIT and plain Lua agree to the last digit.
-- Everyone on a server shuffles the world from the run's seed with this, so
-- it must never change for a given mod series.
local Rng = {}
Rng.__index = Rng

local M = 2147483647

function Rng.new(seed, salt)
  local s = math.floor(tonumber(seed) or 1) + 7919 * (salt or 0)
  s = s % (M - 1)
  if s < 1 then s = s + (M - 1) end
  local self = setmetatable({ state = s }, Rng)
  -- the first draws of a Park-Miller stream follow the seed closely
  for _ = 1, 4 do self:next() end
  return self
end

function Rng:next()
  self.state = (self.state * 16807) % M
  return self.state
end

-- an integer in lo..hi
function Rng:int(lo, hi)
  return lo + (self:next() % (hi - lo + 1))
end

-- Fisher-Yates, in place; returns the list
function Rng:shuffle(list)
  for i = #list, 2, -1 do
    local j = self:int(1, i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

function Rng:pick(list)
  return list[self:int(1, #list)]
end

return Rng
