-- What the randomizer must keep reachable: for every place an item can be
-- found on Gen 1 (Red, Blue, Yellow), what the player needs before they can
-- get to it.  The placement in randomizer.lua only ever puts a progression
-- item (a badge, an HM, a key item that opens the way) somewhere the items
-- placed before it already reach, so every seed can be finished.
--
-- Requirements are CONSERVATIVE on purpose: a map whose items sit partly
-- behind a Cut tree counts as needing Cut for all of them.  Asking for too
-- much only makes a spot less likely to hold progression; asking for too
-- little could hide a badge behind the thing it unlocks.  A map that is not
-- listed never holds progression (its items are still shuffled).
local L = {}

-- Requirement macros: a requirement is a list of these names and item ids,
-- all of which the player must have.
L.MACROS = {
  CUT = { "HM_CUT", "CASCADEBADGE" },
  SURF = { "HM_SURF", "SOULBADGE" },
  STRENGTH = { "HM_STRENGTH", "RAINBOWBADGE" },
  -- Celadon, Lavender and Saffron are past the Cut tree on Route 9 (or the
  -- one into Route 2's east side); Saffron's gate drinks come from Celadon
  MIDGAME = { "CUT" },
  -- Fuchsia: past the Snorlax on Route 12 (or 16) from Lavender or Celadon
  FUCHSIA = { "CUT", "POKE_FLUTE" },
  -- the Viridian Gym door wants the seven other badges
  BADGES7 = { "BOULDERBADGE", "CASCADEBADGE", "THUNDERBADGE", "RAINBOWBADGE",
              "SOULBADGE", "MARSHBADGE", "VOLCANOBADGE" },
  BADGES8 = { "BADGES7", "EARTHBADGE" },
  -- never: post-game or unused maps hold filler only
  NEVER = { "__NEVER__" },
}

-- Maps with item balls or hidden items (by map id) and what reaching ALL of
-- them takes.  Missing maps count as NEVER.
L.MAPS = {
  -- before Cut: Viridian to Cerulean and down to Vermilion
  VIRIDIAN_CITY = {}, VIRIDIAN_FOREST = {}, PEWTER_CITY = {}, ROUTE_3 = {},
  ROUTE_22 = {}, MT_MOON_1F = {}, MT_MOON_B1F = {}, MT_MOON_B2F = {},
  ROUTE_4 = {}, CERULEAN_CITY = {}, ROUTE_24 = {}, ROUTE_25 = {}, BILLS_HOUSE = {},
  ROUTE_5 = {}, ROUTE_6 = {}, UNDERGROUND_PATH_NORTH_SOUTH = {}, ROUTE_11 = {},
  -- The S.S. Anne is NOT listed: once the captain hands over his gift
  -- (whatever it is) the ship sails for good, and a badge left in one of her
  -- cabins would be lost.  Her items are filler; the captain's gift (L.GIFTS)
  -- is the last thing she gives, so it may hold progression.
  -- after Cut
  VERMILION_CITY = { "CUT" }, ROUTE_2 = { "CUT" }, DIGLETTS_CAVE = { "CUT" },
  ROUTE_9 = { "CUT" }, ROUTE_10 = { "CUT" }, ROCK_TUNNEL_1F = { "CUT" },
  ROCK_TUNNEL_B1F = { "CUT" }, LAVENDER_TOWN = { "CUT" }, ROUTE_8 = { "CUT" },
  ROUTE_7 = { "CUT" }, UNDERGROUND_PATH_WEST_EAST = { "CUT" },
  CELADON_CITY = { "CUT" }, CELADON_MART_ROOF = { "CUT" }, GAME_CORNER = { "CUT" },
  ROCKET_HIDEOUT_B1F = { "CUT" }, ROCKET_HIDEOUT_B2F = { "CUT" },
  ROCKET_HIDEOUT_B3F = { "CUT" }, ROCKET_HIDEOUT_B4F = { "CUT", "LIFT_KEY" },
  POKEMON_TOWER_3F = { "CUT" }, POKEMON_TOWER_4F = { "CUT" },
  POKEMON_TOWER_5F = { "CUT" }, POKEMON_TOWER_6F = { "CUT", "SILPH_SCOPE" },
  POKEMON_TOWER_7F = { "CUT", "SILPH_SCOPE" },
  SAFFRON_CITY = { "CUT" }, COPYCATS_HOUSE_2F = { "CUT" }, FIGHTING_DOJO = { "CUT" },
  -- every Silph floor has card key doors; the Card Key's own ball (L.SPOTS)
  -- is outside 5F's, its Protein is behind one
  SILPH_CO_1F = { "CUT", "CARD_KEY" }, SILPH_CO_2F = { "CUT", "CARD_KEY" },
  SILPH_CO_3F = { "CUT", "CARD_KEY" }, SILPH_CO_4F = { "CUT", "CARD_KEY" },
  SILPH_CO_5F = { "CUT", "CARD_KEY" },
  SILPH_CO_6F = { "CUT", "CARD_KEY" }, SILPH_CO_7F = { "CUT", "CARD_KEY" },
  SILPH_CO_8F = { "CUT", "CARD_KEY" }, SILPH_CO_9F = { "CUT", "CARD_KEY" },
  SILPH_CO_10F = { "CUT", "CARD_KEY" }, SILPH_CO_11F = { "CUT", "CARD_KEY" },
  -- Fuchsia and the routes around it.  Route 12's TM and the Safari Zone
  -- center's Nugget sit across water, the Warden's Rare Candy behind a
  -- boulder (dev/drivers/gen1_modes.lua walks every map to check this table)
  ROUTE_12 = { "FUCHSIA", "SURF" }, ROUTE_13 = { "FUCHSIA" }, ROUTE_14 = { "FUCHSIA" },
  ROUTE_15 = { "FUCHSIA" }, FUCHSIA_CITY = { "FUCHSIA" },
  SAFARI_ZONE_GATE = { "FUCHSIA" }, SAFARI_ZONE_CENTER = { "FUCHSIA", "SURF" },
  SAFARI_ZONE_EAST = { "FUCHSIA" }, SAFARI_ZONE_NORTH = { "FUCHSIA" },
  SAFARI_ZONE_WEST = { "FUCHSIA" }, WARDENS_HOUSE = { "FUCHSIA", "STRENGTH" },
  ROUTE_16 = { "FUCHSIA", "BIKE_VOUCHER" }, ROUTE_17 = { "FUCHSIA", "BIKE_VOUCHER" },
  ROUTE_18 = { "FUCHSIA", "BIKE_VOUCHER" },
  -- over water
  ROUTE_21 = { "SURF" }, ROUTE_20 = { "SURF" }, ROUTE_19 = { "SURF" },
  CINNABAR_ISLAND = { "SURF" }, POKEMON_MANSION_1F = { "SURF" },
  POKEMON_MANSION_2F = { "SURF" }, POKEMON_MANSION_3F = { "SURF" },
  POKEMON_MANSION_B1F = { "SURF" },
  SEAFOAM_ISLANDS_1F = { "SURF", "STRENGTH" }, SEAFOAM_ISLANDS_B1F = { "SURF", "STRENGTH" },
  SEAFOAM_ISLANDS_B2F = { "SURF", "STRENGTH" }, SEAFOAM_ISLANDS_B3F = { "SURF", "STRENGTH" },
  SEAFOAM_ISLANDS_B4F = { "SURF", "STRENGTH" },
  POWER_PLANT = { "CUT", "SURF" },
  -- the end of the game
  VIRIDIAN_GYM = { "BADGES7" },
  ROUTE_23 = { "BADGES8", "SURF" },
  VICTORY_ROAD_1F = { "BADGES8", "SURF", "STRENGTH" },
  VICTORY_ROAD_2F = { "BADGES8", "SURF", "STRENGTH" },
  VICTORY_ROAD_3F = { "BADGES8", "SURF", "STRENGTH" },
}

-- Single spots that need less than the rest of their map (by map, then the
-- item vanilla puts there).  The Lift Key's own ball is on the floor its
-- elevator serves; the Card Key's is outside Silph 5F's locked doors.
L.SPOTS = {
  ROCKET_HIDEOUT_B4F = { LIFT_KEY = { "CUT" } },
  SILPH_CO_5F = { CARD_KEY = { "CUT" } },
}

-- NPC gifts handed over by a script's give_item row, by the item the
-- vanilla game gives there.  Only these are shuffled: other gifts (the
-- Bicycle, HM02/HM05, the fossils, Oak's Parcel, the Poke Balls) stay as
-- they are, because their scripts either test the item afterwards or do not
-- go through give_item.
L.GIFTS = {
  TOWN_MAP = {},                        -- Daisy, Pallet Town
  S_S_TICKET = {},                      -- Bill, Route 25
  TM_DIG = {},                          -- the Cerulean burglar
  BIKE_VOUCHER = {},                    -- the Fan Club chairman, Vermilion
  OLD_ROD = {},                         -- Vermilion fishing guru
  HM_CUT = { "S_S_TICKET" },            -- the S.S. Anne captain
  POKE_FLUTE = { "CUT", "SILPH_SCOPE" },-- Mr. Fuji
  MASTER_BALL = { "CUT", "CARD_KEY" },  -- Silph's president
  GOOD_ROD = { "FUCHSIA" },
  SUPER_ROD = { "FUCHSIA" },            -- Route 12's house, south of Snorlax
  HM_SURF = { "FUCHSIA" },              -- the Safari Zone secret house
  HM_STRENGTH = { "FUCHSIA", "GOLD_TEETH" }, -- the Warden
}

-- What each gym leader's badge slot needs (by the badge vanilla gives there).
L.GYMS = {
  BOULDERBADGE = {},
  CASCADEBADGE = {},
  THUNDERBADGE = { "CUT" },             -- a Cut tree outside Vermilion Gym
  RAINBOWBADGE = { "CUT" },             -- and one inside Celadon Gym
  MARSHBADGE = { "MIDGAME" },
  SOULBADGE = { "FUCHSIA" },
  VOLCANOBADGE = { "SURF", "SECRET_KEY" },
  EARTHBADGE = { "BADGES7" },
}

-- Items the logic tracks.  Placed first, each one somewhere already reachable.
L.PROGRESSION = {
  "BOULDERBADGE", "CASCADEBADGE", "THUNDERBADGE", "RAINBOWBADGE", "SOULBADGE",
  "MARSHBADGE", "VOLCANOBADGE", "EARTHBADGE",
  "HM_CUT", "HM_SURF", "HM_STRENGTH", "S_S_TICKET", "SILPH_SCOPE", "POKE_FLUTE",
  "CARD_KEY", "LIFT_KEY", "SECRET_KEY", "GOLD_TEETH", "BIKE_VOUCHER",
}

-- What finishing the game takes: the Elite Four are past Victory Road.
L.GOAL = { "BADGES8", "SURF", "STRENGTH" }

-- Field moves the way on needs a Pokémon for, and the wild areas (encounter
-- map ids) open before them.  The species shuffle keeps a Pokémon that can
-- learn the move in at least `areas` of these (fewer only if vanilla has
-- fewer).  Only Cut needs it: on Red and Blue nothing else is sure to learn
-- it in time (a Squirtle start), while Surf and Strength always have gift
-- Pokémon first (the Mt. Moon Magikarp, the Dojo's Hitmons, the Celadon
-- Eevee, the Silph Lapras).
L.FIELD_MOVES = {
  { move = "CUT", areas = 3,
    maps = { "ROUTE_1", "ROUTE_2", "ROUTE_22", "VIRIDIAN_FOREST", "ROUTE_3", "MT_MOON_1F",
             "MT_MOON_B1F", "MT_MOON_B2F", "ROUTE_4", "ROUTE_24", "ROUTE_25", "ROUTE_5",
             "ROUTE_6", "ROUTE_11", "DIGLETTS_CAVE" } },
}

-- A requirement list flattened to plain item ids (a set).
function L.expand(req, out)
  out = out or {}
  for _, token in ipairs(req or {}) do
    local macro = L.MACROS[token]
    if macro then L.expand(macro, out) else out[token] = true end
  end
  return out
end

function L.satisfied(set, have)
  for item in pairs(set) do
    if not have[item] then return false end
  end
  return true
end

return L
