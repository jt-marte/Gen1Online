-- What the randomizer must keep reachable on FireRed and LeafGreen: the
-- same shape as modes/logic.lua (Gen 1), for the Kanto of the Game Boy
-- Advance and the first three Sevii Islands.  Items are pret's names without
-- ITEM_ (TEA, SILPH_SCOPE, HM01); BADGE1..BADGE8 are the gym badges (flags
-- on FireRed; a shuffled one in a ball or a gift is a marker item, see
-- modes/frlg.lua).  Only field moves, Viridian Gym's door and the Route 23
-- guards check a badge flag: nothing in the story does.
--
-- Requirements are conservative, as on Gen 1: a map whose items sit partly
-- behind a Cut tree counts as needing Cut for all of them.  Asking too much
-- only makes a spot less likely to hold progression.  A map that isn't
-- listed never holds progression (its items are still shuffled).
local L = {}

L.MACROS = {
  CUT = { "HM01", "BADGE2" },
  SURF = { "HM03", "BADGE5" },
  STRENGTH = { "HM04", "BADGE4" },
  ROCK_SMASH = { "HM06", "BADGE6" },
  -- Celadon, Lavender and the Underground Path west-east are past Route 9's
  -- Cut tree (Lavender is also reachable from Route 11: counted as Cut)
  MIDGAME = { "CUT" },
  -- Saffron's gate guards want a drink: the TEA from Celadon's mansion
  SAFFRON = { "CUT", "TEA" },
  -- Fuchsia: past a Snorlax on Route 12 or 16 (the POKé FLUTE)
  FUCHSIA = { "CUT", "POKE_FLUTE" },
  CINNABAR = { "SURF" },
  -- Bill takes the player to One Island after Blaine
  SEVII = { "CINNABAR", "SECRET_KEY", "BADGE7", "TRI_PASS" },
  BADGES7 = { "BADGE1", "BADGE2", "BADGE3", "BADGE4", "BADGE5", "BADGE6", "BADGE7" },
  BADGES8 = { "BADGES7", "BADGE8" },
  NEVER = { "__NEVER__" },
}

-- Maps with item balls or hidden items, and what reaching ALL of them takes.
L.MAPS = {
  -- before Cut
  FR_VIRIDIAN_FOREST = {}, FR_ROUTE_3 = {}, FR_MT_MOON_1F = {}, FR_MT_MOON_B1F = {},
  FR_MT_MOON_B2F = {}, FR_ROUTE_4 = {}, FR_ROUTE_24 = {}, FR_ROUTE_25 = {},
  FR_ROUTE_6 = {}, FR_UNDERGROUND_PATH_NORTH_SOUTH_TUNNEL = {},
  -- The S.S. Anne isn't listed: she sails for good once the captain hands over
  -- HM01, and a key item left in one of her cabins would be lost.
  -- after Cut (some of these only need it for one item, counted for all)
  FR_VIRIDIAN_CITY = { "CUT" }, FR_PEWTER_CITY = { "CUT" }, FR_CERULEAN_CITY = { "CUT" },
  FR_VERMILION_CITY = { "CUT" }, FR_ROUTE_2 = { "CUT" }, FR_ROUTE_11 = { "CUT" },
  FR_ROUTE_9 = { "CUT" }, FR_ROCK_TUNNEL_1F = { "CUT" }, FR_ROCK_TUNNEL_B1F = { "CUT" },
  FR_ROUTE_8 = { "CUT" }, FR_ROUTE_7 = { "CUT" }, FR_UNDERGROUND_PATH_EAST_WEST_TUNNEL = { "CUT" },
  FR_CELADON_CITY = { "CUT" },
  FR_ROCKET_HIDEOUT_B1F = { "CUT" }, FR_ROCKET_HIDEOUT_B2F = { "CUT" },
  FR_ROCKET_HIDEOUT_B3F = { "CUT" }, FR_ROCKET_HIDEOUT_B4F = { "CUT", "LIFT_KEY" },
  FR_POKEMON_TOWER_3F = { "CUT" }, FR_POKEMON_TOWER_4F = { "CUT" }, FR_POKEMON_TOWER_5F = { "CUT" },
  FR_POKEMON_TOWER_6F = { "CUT", "SILPH_SCOPE" }, FR_POKEMON_TOWER_7F = { "CUT", "SILPH_SCOPE" },
  FR_ROUTE_10 = { "CUT", "SURF" },
  -- Saffron and Silph Co. (card key doors on every floor; the Card Key's own
  -- ball is outside 5F's, L.SPOTS)
  FR_SAFFRON_CITY_COPYCATS_HOUSE_2F = { "SAFFRON" },
  FR_SILPH_CO_2F = { "SAFFRON", "CARD_KEY" }, FR_SILPH_CO_3F = { "SAFFRON", "CARD_KEY" },
  FR_SILPH_CO_4F = { "SAFFRON", "CARD_KEY" }, FR_SILPH_CO_5F = { "SAFFRON", "CARD_KEY" },
  FR_SILPH_CO_6F = { "SAFFRON", "CARD_KEY" }, FR_SILPH_CO_7F = { "SAFFRON", "CARD_KEY" },
  FR_SILPH_CO_8F = { "SAFFRON", "CARD_KEY" }, FR_SILPH_CO_9F = { "SAFFRON", "CARD_KEY" },
  FR_SILPH_CO_10F = { "SAFFRON", "CARD_KEY" }, FR_SILPH_CO_11F = { "SAFFRON", "CARD_KEY" },
  -- Fuchsia and around it; Route 12's items sit by the water, the Warden's
  -- house has a boulder
  FR_ROUTE_12 = { "FUCHSIA", "SURF" }, FR_ROUTE_13 = { "FUCHSIA" }, FR_ROUTE_14 = { "FUCHSIA" },
  FR_ROUTE_15 = { "FUCHSIA" }, FR_FUCHSIA_CITY = { "FUCHSIA" },
  FR_ROUTE_16 = { "FUCHSIA", "BICYCLE" }, FR_ROUTE_17 = { "FUCHSIA", "BICYCLE" },
  FR_SAFARI_ZONE_CENTER = { "FUCHSIA", "SURF" }, FR_SAFARI_ZONE_EAST = { "FUCHSIA" },
  FR_SAFARI_ZONE_NORTH = { "FUCHSIA" }, FR_SAFARI_ZONE_WEST = { "FUCHSIA" },
  FR_FUCHSIA_CITY_WARDENS_HOUSE = { "FUCHSIA", "STRENGTH" },
  FR_POWER_PLANT = { "CUT", "SURF" },
  -- over the water
  FR_ROUTE_20 = { "SURF" }, FR_ROUTE_21_NORTH = { "SURF" },
  FR_POKEMON_MANSION_1F = { "SURF" }, FR_POKEMON_MANSION_2F = { "SURF" },
  FR_POKEMON_MANSION_3F = { "SURF" }, FR_POKEMON_MANSION_B1F = { "SURF" },
  FR_SEAFOAM_ISLANDS_1F = { "SURF", "STRENGTH" }, FR_SEAFOAM_ISLANDS_B1F = { "SURF", "STRENGTH" },
  FR_SEAFOAM_ISLANDS_B2F = { "SURF", "STRENGTH" }, FR_SEAFOAM_ISLANDS_B3F = { "SURF", "STRENGTH" },
  FR_SEAFOAM_ISLANDS_B4F = { "SURF", "STRENGTH" },
  -- One to Three Island, before the Elite Four (Rock Smash and Strength
  -- counted wherever there might be a rock)
  SEVII_ONE_ISLAND_KINDLE_ROAD = { "SEVII", "SURF" }, SEVII_ONE_ISLAND_TREASURE_BEACH = { "SEVII", "SURF" },
  FR_MT_EMBER_EXTERIOR = { "SEVII", "SURF", "ROCK_SMASH", "STRENGTH" },
  FR_TWO_ISLAND = { "SEVII" }, FR_THREE_ISLAND = { "SEVII" },
  FR_THREE_ISLAND_BOND_BRIDGE = { "SEVII", "SURF" }, FR_THREE_ISLAND_BERRY_FOREST = { "SEVII", "SURF" },
  -- the end of the game
  FR_VIRIDIAN_CITY_GYM = { "BADGES7" },
  FR_ROUTE_23 = { "BADGES8", "SURF" },
  FR_VICTORY_ROAD_1F = { "BADGES8", "SURF", "STRENGTH" },
  FR_VICTORY_ROAD_2F = { "BADGES8", "SURF", "STRENGTH" },
  FR_VICTORY_ROAD_3F = { "BADGES8", "SURF", "STRENGTH" },
  -- post-game (Cerulean Cave, Four to Seven Island, Cape Brink's Ruby path...)
  -- is not listed: it holds filler only
}

-- single spots that need less than the rest of their map, by map and the
-- item vanilla puts there
L.SPOTS = {
  FR_ROCKET_HIDEOUT_B4F = { LIFT_KEY = { "CUT" } },
  FR_SILPH_CO_5F = { CARD_KEY = { "SAFFRON" } },
  -- behind Rock Smash rocks (the map walk, dev/drivers/gen3_walk.lua)
  SEVII_ONE_ISLAND_KINDLE_ROAD = { CARBOS = { "SEVII", "SURF", "ROCK_SMASH" },
                                   ETHER = { "SEVII", "SURF", "ROCK_SMASH" } },
}

-- NPC gifts the shuffle may change, by the item vanilla gives (scripts that
-- hand it over with the standard obtain-item call).  The others stay put
-- (fixed below): their scripts give through other commands.
L.GIFTS = {
  TEA = { "CUT" },                        -- the old lady in Celadon's mansion
  LIFT_KEY = { "CUT" },                   -- the Rocket on Hideout B4F
  SILPH_SCOPE = { "CUT", "LIFT_KEY" },    -- Giovanni, Hideout B4F
  HM06 = { "SEVII" },                     -- the Ember Spa, One Island
  NET_BALL = { "FUCHSIA", "SURF" },       -- Route 12's fishing house
}

-- What the game gives that the shuffle never moves, with what it takes:
-- the logic counts on them (the captain's HM01 opens the way for Cut...).
L.FIXED = {
  SS_TICKET = {},                         -- Bill, Route 25
  HM01 = { "SS_TICKET" },                 -- the S.S. Anne's captain
  BICYCLE = {},                           -- the Bike Voucher, Vermilion's fan club
  POKE_FLUTE = { "CUT", "SILPH_SCOPE" },  -- Mr. Fuji
  HM03 = { "FUCHSIA" },                   -- the Safari Zone's secret house
  HM04 = { "FUCHSIA", "GOLD_TEETH" },     -- the Warden
  TRI_PASS = { "CINNABAR", "SECRET_KEY" },-- Bill, after Blaine
}

-- the gym leaders' badge slots, by what reaching the leader takes
L.GYMS = {
  BADGE1 = {}, BADGE2 = {},
  BADGE3 = { "CUT" },                     -- a Cut tree in front of Vermilion Gym
  BADGE4 = { "CUT" },                     -- and one inside Celadon Gym
  BADGE5 = { "FUCHSIA" },
  BADGE6 = { "SAFFRON" },
  BADGE7 = { "CINNABAR", "SECRET_KEY" },
  BADGE8 = { "BADGES7" },
}

-- The items the logic tracks that the shuffle moves: each is placed first,
-- somewhere already reachable (the badges when randomize_badges is on).
L.PROGRESSION = {
  "BADGE1", "BADGE2", "BADGE3", "BADGE4", "BADGE5", "BADGE6", "BADGE7", "BADGE8",
  "TEA", "LIFT_KEY", "SILPH_SCOPE", "CARD_KEY", "SECRET_KEY", "GOLD_TEETH", "HM06",
}

L.GOAL = { "BADGES8", "SURF", "STRENGTH" }

-- Cut needs a Pokémon to learn it in time: the shuffle keeps one in at least
-- 3 of the wild areas open before Cut (fewer only if vanilla has fewer).
-- HM01 is TM-case index 50.
L.FIELD_MOVES = {
  { tmIndex = 50, areas = 3,
    maps = { "FR_ROUTE_1", "FR_ROUTE_2", "FR_ROUTE_22", "FR_VIRIDIAN_FOREST", "FR_ROUTE_3",
             "FR_MT_MOON_1F", "FR_MT_MOON_B1F", "FR_MT_MOON_B2F", "FR_ROUTE_4", "FR_ROUTE_24",
             "FR_ROUTE_25", "FR_ROUTE_5", "FR_ROUTE_6", "FR_ROUTE_11", "FR_DIGLETTS_CAVE_B1F" } },
}

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
