# Changelog

## [Unreleased]

A server of our own, built for playing with friends.

### Added

- `server/gts_server.py`: a single-file, standard-library Python 3.8+ server
  that speaks the client's protocol. `python3 server/gts_server.py` (or
  `server/start.sh`, or double-clicking `server/start.bat`) listens on port
  7779 and prints the `server_url=` lines for this PC, the LAN and Tailscale.
  Every answer is HTTP 200 JSON, keep-alive connections are reused, and the
  data is saved atomically to `server/gts_data.json`. No Cloudflare, analytics,
  IP logging or anti-cheat.
- Wonder Trade runs on the server: one Pokémon per trainer, and once 5 are
  waiting each trainer is dealt another's (never their own). The client reads
  the real pool, and a claim shows the player's own Pokémon leaving.
- README: hosting for friends on a LAN, over Tailscale, or with a port forward.
- **Pokémon Red, Blue and Yellow.** The mod runs on Gen 1 again (it has been
  Crystal-only since 0.4.0): connect, overworld sync, chat, GTS, Wonder Trade,
  PVP link battles, co-op parties and, on Gen 1 only, face-to-face link
  trades. Each game keeps its own online save (`save_online_red.lua`, ...).
- **One generation per server.** A server is a Gen 1 world (Red, Blue and
  Yellow together) or a Crystal world: `--gen 1` / `--gen 2`, or the first
  game to connect decides. The other generation gets `WRONG_GENERATION`, and
  the game says the server is not for it before anything changes. A Gen 1
  world's recovery tokens are 8 letters, which the Gen 1 keyboard can type.

### Changed

- `gts_config.txt` and the built-in default point at `http://127.0.0.1:7779`
  instead of a dead Cloudflare tunnel.
- `sync_xp` sends the XP the client awarded, so the server's total matches.

### Fixed

- GTS buy, withdraw and claim changed the game before the server answered:
  withdrawing a listing someone had just bought handed the Pokémon back while
  the buyer also got it. Each now waits for the server, and a refused trade or
  deposit leaves the Pokémon with the player (a refused deposit used to leave
  a listing only this client could see).
- Answers over 2048 bytes (the GTS listings, once a few are up) were cut off
  and dropped: the HTTP sink stopped LuaSocket after its first block.
- The 10-listing cap counts the server's listings, not this session's deposits.
- A Gen 1 PVP win was booked twice (the engine finishes a battle in two
  calls); it is now booked once, after the battle screen closes.
- On Gen 1 the casino stays off (the Celadon Game Corner and its coin cap are
  vanilla), Yellow's own Pikachu follower is left alone, the avatar applies to
  the Gen 1 player sprite, and the 1x speed lock covers Gen 1 too.

## [0.5.1] - 2026-10-04

Brought up to date with the current gen1recomp engine and tested on a real
Crystal boot. Connects to 0.5.x servers.

### Removed

- Overworld wild Pokémon roaming (wild Pokémon walking around in the grass and
  A-press battles). Wild encounters are the game's own tall-grass encounters
  again. `data/encounter_tables.json` and `tools/encounter_editor.py`, which only
  fed that feature, are gone too.

### Changed

- Crystal PVP now runs on the engine's native lockstep link battle
  (`LinkBattle2`) when both players are on 0.5.1+: real per-turn desync checks,
  and each player picks their own replacement after a faint. A player on an
  older client still gets the mod's own battle engine, negotiated through the
  challenge room id, so mixed versions can still battle.
- The 1x speed lock while online uses the engine's own lock
  (`Game2:speedLocked`) instead of overwriting the player's GAME SPEED options
  every frame, so the player's speed setting is intact after going offline.
- The global chat poll runs in the background through `mod.fetch` (with the
  old request as a fallback), removing a hitch every 5 seconds online.
- Chat typing goes through the engine's `input.key` hook instead of replacing
  `love.keypressed`, which also swallowed keys meant for other screens.
- Online name tags are drawn in the overworld pass, right above each trainer,
  and no longer over battle, trade and evolution screens.
- The mod loads its own files through the sandbox (`mod:read`/`mod:info`)
  instead of `require("mods.gen1online-plus...")` and `io.open`, so it works
  whatever its install folder is called. Debug files are no longer written to
  disk every few seconds (developer-mode log lines instead).
- Character creation and recovery-token entry use Crystal's own naming
  screen (the token uses the box keyboard, the only one with digits).
- The client accepts any server on the same major.minor version, the same rule
  the server applies.

### Fixed

- Online saves, the online account and the chat setting now actually persist
  (the storage calls used the wrong signature and silently failed).
- Offline play no longer touches the online account: event handlers renamed
  the offline player to the online name, stamped the account token into the
  offline save (diverting its SAVE into the online file) and made blocking
  server calls on every badge, catch and battle.
- GTS on Crystal used the Gen 1 Pokémon format, losing held items, happiness,
  Pokérus and caught data and rebuilding stats with Gen 1 formulas. It now uses
  the Gen 2 format (old listings still load), honors party mail, checks for
  room before a withdraw or claim, and lets Johto Pokémon (#152–251) be
  requested.
- GTS trades play Crystal's trade animation and evolve trade evolutions
  (e.g. KADABRA into ALAKAZAM) on arrival; the animation used to be left on
  screen.
- A forced disconnect now reloads the offline save's story flags into the
  world, and both disconnect paths restore the player's own Chris/Kris sprite.
- Badge and Pokédex counts on profiles read Crystal's save layout (they were
  always 0).
- The online clock bypass (Oak's and Mom's clock questions) matches the
  engine's current `InitClock` and only applies while online.
- Talking to the follower works (it searched the wrong cell and called a
  function the engine does not have).
- The first chat message on a quiet server is no longer swallowed, and a new
  character gets live chat notifications straight away.
- RESET / SWITCH actually deletes the online save.
- Background jobs ran three times a frame while online, so remote players
  moved at 3x speed.
- "CHALLENGE ACCEPTED" showed up after the battle instead of before it.
- Text showed `POKÃ©MON` instead of `POKéMON`.
- `mod.card` is in the engine's Lua format.

## [0.5.0] - 2026-08-27

### Added
- Synchronized Real-Time Clock with server authority and automatic Day/Night cycle locking.
- 1:1 True-Color PokeEmerald follower sprites.
- Synchronized overworld wild Pokémon encounters with live grass roaming across Johto and Kanto.
- Rebranded to Gen1Online+.

## [0.4.0] - 2026-08-24

### Added

- **Gen1Online++ rebrand**: new mod id `gen1online-plus`, targeting
  **Pokemon Crystal only** (Gen 2 / `crystal` engine).

### Removed

- **Blackjack** and the expanded blackjack code.
- **Live Multiplayer Online Texas Hold'em** (the poker tables, screens, rules,
  and table art).

### Changed

- Version bumped to 0.4.0.0 across manifest, mod.card, README, and server.
- Online save files now use the `_crystal` suffix (`save_online_crystal.lua`).

## [0.3.6.1] - 2026-08-17

### Added

- **Custom Gen 2 PVP battle engine** (`pvp/` modules): deterministic lockstep
  battles on Gold using the native Gen 2 battle engine, with full-party
  switching, shared RNG seed, canonical turn order, and the vanilla battle UI.
  Swappable backend (`pvp.config.engine = "custom" | "native"`) for an easy
  switch back when the recomp gains native PVP.
- **Active server logout on quit** — new `logout` server action; the START-menu
  QUIT item and quit-to-title both log the player out immediately (no 30s ghost).
- **1x game-speed lock while online** — all players are forced to normal speed
  and cannot alter it while connected, so the MMO stays synced.

### Changed

- Version bumped to 0.3.6.1 across manifest, mod.card, README, and server.
- Remote-player movement over-prediction capped to one tile per packet (no more
  walking off the map before snapping back).
- PVP battle end now returns to the map (pops the battle state) instead of
  freezing on the victory/defeat screen.
- Battle-message transport is non-blocking via the async HTTP engine; the async
  queue cap raised so battle messages are never dropped.

## [0.3.5.0] - 2026-08-11

### Added

- **Gen 2 (Gold) Support.** The mod now declares `"api": 2` and
  `"games": ["gen1", "gen2"]`, enabling it to load on Gold boots via the
  Gen 2 compatibility adapter.
- Generation detection helper (`currentGeneration` / `isGen2`) for
  future generation-conditional logic.

### Changed

- Online save files on Gold now use a `_gold` suffix
  (`save_online_gold.lua`) to keep progress separate from Gen 1 saves.
- `Game.logicSpeed` override is now guarded with a nil check for Gen 2
  facade safety — the patch only installs when the method exists.

## [0.2.0] - 2026-08-07

### Added

- A 1,000,000-coin Coin Case limit across the mod's purchases, wagers, payouts,
  prize refunds, and pawn transactions.
- Compatibility for the original slot machines, including high-balance-safe
  payouts and a compact four-character credit counter up to `1.0M`.
- House-banked Texas Hold'em with real best-five-of-seven hand evaluation.
- Progressive Play wagering across all three streets: check or bet 3x/4x
  before the flop, continue with 2x after the flop, then check or bet 1x at
  the river.
- One clear starting bet, standard best-hand comparison against the house,
  and 1:1 payouts across all committed wagers.
- A dedicated blue-felt Hold'em screen with hole cards, five community cards,
  staged controls, showdown hands, and net results.
- A second dealer and interactive poker table in the casino lounge.
- A shady Pokemon pawn broker at the original Game Corner counter.
- Stat-, level-, and rarity-based appraisals paid in Game Corner coins, with
  exact Pokemon restoration for a 30% redemption premium.
- Five persistent pawn slots with an explicit first-pawned-first-sold warning
  when adding a sixth Pokemon.
- Safe party/PC redemption and protections for the final party member, full
  Coin Cases, and full Pokemon storage.
- Three generated center-lounge arcade cabinets with separate Crash, Tube
  Flyer, and Prize Case screens.
- A wager-and-cash-out Crash game with a hidden house-edged crash point,
  continuously rising multiplier, four wager sizes, and persistent records.
- A 10-coin flying game with deterministic tube physics, immediate one-coin
  payouts per passed tube, best scores, and safe Coin Case limits.
- A 500-coin case-opening reel with rarity colors, a premium Pokemon roster,
  rare items and TMs, and a roughly 0.1% Master Ball chance.
- Transactional case rewards that use party/PC delivery and refund the full
  opening price if the selected reward cannot be stored.

### Improved

- Replaced low-tier Prize Case Pokemon with starters, fossils, Dragonite,
  Mew, and a special Pikachu that arrives knowing Surf.
- Styled the Master Ball reel card as a gold-and-black jackpot and slowed the
  case reel and Crash multiplier growth for clearer decision timing.
- Refactored the runtime into per-game `games/` modules and supporting
  `other/` services, reducing `main.lua` to composition and registration.
- Rebuilt all three arcade screens around bright, machine-specific Game Boy
  palettes so the engine's black tile font remains legible in every state.
- Crash now presents all four wagers at once with a clear selection, a visual
  launch preview, and a light graph surface.
- Tube Flyer gained readable top-HUD scoring, capped pipe openings, a clearer
  bird silhouette, and a compact result ribbon that preserves the playfield.
- Prize Case gained icon-led reel cards, shorter readable reel labels, stronger
  winner markers, and compact opening/result panels without a dark backdrop.
- Expanded the lounge from 14x10 to 20x12 walk cells for two distinct games,
  more breathing room, and a central circulation aisle.
- Reduced both overworld tables from five to four tiles wide and gave each
  game its own locally generated table art.
- Added concise in-world guidance for progressive Hold'em decisions and
  standard best-hand payouts.
- Verify each wager independently, so a player with exactly one starting bet
  can check every street and still reach showdown.
- Early bets now reveal only the next street instead of skipping directly to
  showdown, and unaffordable bets never block the free Check action.
- Removed the Ultimate Hold'em Ante, Blind, bonus-paytable, and dealer-
  qualification rules that conflicted with the multi-street game.

### Fixed

- Original slot payouts now cross the old 9,999-coin boundary instead of
  silently losing the next payout coin.
- Hidden Game Corner coin pickups preserve five- and six-digit balances
  instead of clamping them back to 9,999.
- Prize Case reel positioning and winner highlighting now share the same
  configured winning-card index.

## [0.1.0] - 2026-08-06

### Added

- Playable blackjack using the existing Game Corner coin balance.
- Pixel-drawn cards, chips, casino table, action states, and round feedback.
- Expanded Red- and Blue-aware Pokemon prize catalogues.
- Persistent shiny upgrades with locally derived gold battle art.
- Rare item prizes and a one-time 9,999-coin Master Ball redemption.
- Larger 50, 250, 500, 1,000, and capacity-aware MAX coin purchases.
- Red-, Blue-, and Yellow-aware prize catalogues with starters, fossils, and
  opposite-version species.
- Safe party/PC delivery and failure handling that never charges for a prize
  the player cannot receive.

### Improved

- Removed level suffixes from Pokemon prize rows so long names no longer
  collide with their prices.
- Failed prize purchases now return to the catalogue instead of closing it.
- Replaced the borrowed octagonal dining table with a wide, green semicircular
  blackjack table, centered dealer, betting marks, chips, deck, and a fully
  interactive front edge.
- Moved the table into a dedicated Blackjack Lounge with its own double-door,
  spectators, open circulation space, and reciprocal Game Corner warps.
- Expanded the coin clerk with 50, 250, 500, 1,000, and capacity-aware MAX
  purchases at the original exchange rate.
- Card pips, court cards, silhouettes, and color rendering were rebuilt for the
  real 160x144 game pipeline.
