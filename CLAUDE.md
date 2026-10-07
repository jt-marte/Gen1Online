# Gen1Online+ (mod id `gen1online-plus`)

Online multiplayer mod for **Pokémon Red, Blue, Yellow, Crystal, FireRed and
LeafGreen** on the gen1recomp engine (a LÖVE2D re-implementation). Live co-op
overworld, GTS trading, PVP link battles, global chat, co-op parties, a
separate online save; true-color followers and the server RTC on Crystal
only, face-to-face link trades on Gen 1 and FireRed/LeafGreen. The server's
game modes (Nuzlocke, randomizer, multiworld) play on Gen 1 and
FireRed/LeafGreen. `manifest.json` `"games": ["red", "blue", "yellow",
"crystal", "firered", "leafgreen"]`. A server hosts one generation's world
(see "Server").

## Ground rules

- **Work only in this repo.** `../gen1recomp` is the engine, used as
  reference and as the test host. Never edit it.
- **Local sessions: never commit or push** unless the user asks in that
  message. **Cloud sessions** (claude.ai/code, GitHub agents) only keep work
  that is pushed: commit to the session's branch (the server rewrite lives on
  `server-rewrite`), push it, and open a PR into `master` when done. Never
  push to `master` directly and never force-push.
- **Authentic Pokémon experience.** Overworld wild-Pokémon roaming was removed
  on purpose (0.5.1); wild encounters are the game's own tall-grass ones. Don't
  add gameplay that changes the vanilla game outside the online features. On
  Gen 1 that is why the casino is never set up (it would take over the
  Celadon Game Corner and raise the coin cap) and why the mod leaves Yellow's
  own Pikachu follower (`src.world.PikachuFollower`) alone. The one
  sanctioned exception is the server's game modes (`modes/`: hardcore
  Nuzlocke, randomizer, shared key items), which the user asked for: off by
  default, chosen by the host in `server/server_config.txt`, online only, and
  undone the moment the player is offline.
- **The server is for friends**, with no Cloudflare. See "Server" below.
- The user's Crystal ROM (v1.1, verified SHA-1) is at
  `/home/jt/Desktop/Pokemon/Pokemon - Crystal Version (UE) (V1.1) [C][!].zip`.
  It is the user's own copy: never commit it, copy it into the repo, or
  share it. The same goes for the FireRed and LeafGreen ROMs, which sit in
  the workspace root: `../Pokemon - Fire Red Version (U) (V1.1).gba` and
  `../Pokemon - Leaf Green Version (U) (V1.1).gba`.

## Layout

| Path | What |
| --- | --- |
| `main.lua` | ~7,900 lines, nearly the whole mod. **CRLF line endings.** |
| `pvp/` | Fallback Gen 2 PVP engine, used only against pre-0.5.1 peers. |
| `other/`, `games/` | Gen 1 casino (Crash, Tube Flyer, Prize Case, pawn). Off: main.lua returns before setting it up on Gen 1, and on Crystal its maps don't exist. |
| `npcs/`, `quests/` | Registries (empty). `npcs/{quest,trade}/*` are dead Gen 1 leftovers. |
| `modes/` | Server game modes: `init.lua` (Gen 1: hooks, the run, shared items, Nuzlocke), `frlg.lua` (the same interface on FireRed/LeafGreen), `randomizer.lua` (pure: build/apply/undo the world from a seed; `build` also takes another game's places and species), `logic.lua` / `logic_frlg.lua` (what each item place needs), `rng.lua` (Park-Miller, pinned). Loaded by main.lua as `GtsUI.Modes` (exported as `mod.exports.modes`). |
| `gen3/` | The FireRed/LeafGreen layer (`GtsUI.G3`, exported as `mod.exports.gen3`): `ui.lua` (the mod's screens on FireRed's modal stack, in its windows and font), `init.lua` (game wrapper, live save view, session swap, Pokémon and PC, presence actors, avatars, the PC's GTS row), `link.lua` (PVP and link trades over the server). |
| `assets/followers/` | Follower sheets (16x96, 6 frames), from pokeemerald via `tools/import_emerald_follower.py`. |
| `gts_config.txt` | `server_url=...`, read at startup through `mod:read`. The default only: an address typed in-game (START > CONNECT > SERVER ADDRESS, stored as `gts_server_url`) wins. |
| `server/` | The server (`gts_server.py`, stdlib Python), its unittest, `start.sh`/`start.bat`. Never packaged. |
| `dev/` | Test harness (excluded from packages by `.modkitignore`). |

### main.lua structure

- Lines before `return function(mod)` run at load with `mod` from `...`: helpers,
  networking, persistence, GTS UI, connect/disconnect flows, engine patches.
  The factory after it registers hooks (`core.update`, `ui.start_menu.items`,
  `ui.pc.items`, `input.key`) and the Gen 2 `World` wrappers (`setMap`, `step`,
  `interact`, `interactBody`, `drawPeople`, `applyPlayerState`).
- **Lua limits are tight.** The top-level chunk is within about 5 locals of
  Lua's 200-local cap. Put new helpers inside `do ... end` blocks, or as fields
  on an existing table (`GtsUI.x`, `NativePvp.x`). The factory closure is near
  LuaJIT's 60-upvalue cap. Check every edit compiles:
  `luajit -e "assert(loadstring(io.open('main.lua','rb'):read('*a')))"`.
- **Use-before-`local` bugs have bitten this file.** A name used above its
  `local` line silently reads a nil global. Check with the bytecode scan:
  `LUA_PATH="$G1O_WORK/root/usr/share/luajit-2.1/?.lua;;" luajit -bl main.lua | grep -oE '(GGET|GSET) .*"[A-Za-z_]+"'`.
  Every GGET name must also have a GSET, or be a builtin.
- **Preserve CRLF** in `main.lua`, `other/coin_case.lua`, `other/ui.lua` and
  `README.md`. Python's text mode silently rewrites them to LF and turns the
  diff into thousands of lines. Edit with exact-match replacements done in
  binary.
- The mod runs in the engine's **sandbox**. Read its own files with `mod:read`,
  `mod:info` and `requireLocal("pvp/x.lua")`. Never use `io`,
  `require("mods.gen1online-plus...")` or hardcoded `mods/gen1online-plus/`
  paths (the install folder name varies). Images use `mod.path .. "/..."`.
- **Persistence** goes through `storageRead`/`storageWrite`/`storageRemove`.
  They are installation-wide (`mod_compat/gen1online-plus/` via the engine's
  legacy compat store), because `mod.storage` is per-playthrough and the online
  character spans playthroughs. The online save is per game:
  `save_online_crystal.lua` (with `gen1online_online_account.lua`) on Crystal,
  `save_online_<red|blue|yellow>.lua` (with
  `gen1online_online_account_<game>.lua`) on Gen 1.
- **Online-only code must check `isGtsServerConnected`.** Offline, the account
  helpers once renamed the offline player and diverted offline SAVEs into the
  online file.
- On Crystal the overworld is an **empty** `game.stack`: the world isn't a
  stack state.
- **Generations.** `isGen2` picks the branch. On Gen 1 the engine's `Game`
  (`src.core.Game`), `StateStack` and overworld (`src.world.OverworldController`)
  are singleton modules, the overworld sits on the stack, the save keeps the
  position in `save.player.map/x/y`, and `Player` has no `setSprite`. The
  sandbox refuses Gen 2 engine modules (`src.*.gen2.*`, `src.core.Game2`) on
  Gen 1 with an error: guard such requires with `isGen2`, as the existing
  ones are (the Gen 1 tests fail on any swallowed error).
- **FireRed/LeafGreen** (`isGen3`, `GtsUI.G3` from `gen3/init.lua`): the
  engine hands mods the raw Game3, so main.lua works on `G3.game` (the mod's
  stack, a live save view, the adapter's data and overworld). The online
  save is a FireRed save table; connecting, disconnecting and a new
  character swap the live session with `G3.enter` (the engine's own
  teardown, then CONTINUE or a new game). The mod's screens are
  `G3.UI.Stack` on a layer of FireRed's modal stack: a screen pushed during
  a battle waits until it ends (a layer over the battle took its input).
  Badges are flags (`FLAG_BADGE01_GET` = 0x820..0x827), Pokémon are numbers
  (`Pokemon.speciesFromNational`), items pret's numeric ids.

## Testing

```bash
dev/setup.sh "/home/jt/Desktop/Pokemon/Pokemon - Crystal Version (UE) (V1.1) [C][!].zip"  # once, or after /tmp is wiped
dev/run_tests.sh          # everything (~3 min)
dev/run_tests.sh quick    # synthetic only, no ROM needed
```

- **`setup.sh`** builds `$G1O_WORK` (default `/tmp/gen1online-dev`). It
  extracts LuaJIT, LÖVE 11.5 and luasocket from Fedora RPMs (no sudo) and
  imports the ROM into a throwaway LÖVE profile. The user's real game profile
  is never touched. It also clones gen1recomp next to this repo if it's
  missing, pinned to the verified commit (`RECOMP_REF`, now `21a64419`, dev of
  2026-10-06). An engine update can bump a game's ROM cache version
  (FireRed/LeafGreen went 130 -> 131 then): the game then waits in its
  importer, silently, and every driver hangs. Delete that game's cache in
  the test profiles and run `setup.sh` with the ROMs again. The tests run `server/gts_server.py`
  through `dev/server.sh` (fresh database each start).
- **Cloud / no ROM** (Ubuntu, claude.ai/code): run `dev/setup.sh` with no
  argument, then `dev/run_tests.sh quick`. Without `dnf` it apt-installs
  `luajit` and `lua-socket` and uses them. Verified in a clean `ubuntu:24.04`
  container: the synthetic suites pass. The real-Crystal drivers need the
  user's ROM, which must never leave their machine, so they're skipped there.
  Say so in the PR, and ask the user to run the full `dev/run_tests.sh`
  locally before merging.
- **Server unittest**: `python3 -m unittest server/test_gts_server.py` (also
  the first step of `run_tests.sh`). Real HTTP on a free port with a fake
  clock: every action, HTTP 200 on errors, keep-alive, persistence.
- **Synthetic tests** (`dev/harness/`) load the mod through the engine's real
  Loader and sandbox, with a real gen2 `World` on a fake map. The sandbox's
  `pcall` is wrapped so the mod's swallowed errors are reported.
  - `offline_test.lua`: mod installed, never connected.
  - `online_test.lua`: the full online flow against the local server, with a
    second trainer, BUDDY, played over raw HTTP.
  - `wonder_test.lua`: Wonder Trade with the real client and five raw-HTTP
    trainers: pool count, withdraw, a refused deposit, matching (nobody gets
    their own), CLAIM_PENDING, claim, and client/server XP agreement.
  - `gts_test.lua`: GTS deposit, buy, withdraw and claim, each losing a race
    to another trainer or device first; the player's Pokémon must stay put.
  - Both stub `Gen2TradeAnim` and `Gen2NamingScreen` (no art in the rig) and
    give `game.data.pokemon` minimal defs so `unpackMon2` works.
  - **Gen 1**: `G1O_GAME=red|blue|yellow` makes the rig boot the real Gen 1
    `Game`, `StateStack` and overworld modules, with stand-ins for the
    overworld methods that need ROM data (`setMap`, `update`, `interact`,
    `drawWorld`, ...) installed before the mod wraps them.
    `gen1_offline_test.lua` checks the vanilla game is intact (casino off,
    Pikachu follower untouched); `gen1_test.lua` runs the whole online flow
    on a Gen 1 server, including an accepted PVP battle (booked once) and a
    link trade opening over the room. `run_tests.sh` runs both for Red, Blue
    and Yellow.
  - `modes_test.lua` (plain LuaJIT, no engine or ROM): the pinned RNG, 200
    seeds of placement on a synthetic world (always finishable, no
    progression on hidden tiles, post-game maps or the S.S. Anne's cabins, a
    pure permutation), the badges-only / items-only / encounters-only
    variants, the species shuffle (drawn again until CUT has early learners,
    deterministically; unchanged without encounter data), the starter pool
    and draws, apply/undo, and multiworld.
  - `wrong_world_test.lua`: each generation's CONNECT is turned away by the
    other generation's server (run as Crystal on Gen 1, and as Red on Crystal).
  - `address_test.lua` (Crystal and Yellow): the CONNECT menu (JOIN / SERVER
    ADDRESS / USE CONFIG FILE), the address screen by keyboard, `love.textinput`
    and D-pad, refused addresses, an unreachable server, and a typed address
    winning over `gts_config.txt`.
  - CONNECT opens that menu, so every test presses CONNECT, then `^JOIN`.
  - `dev/server.sh` passes `GTS_GENERATION` through to the server.
- **Real-Crystal drivers** (`dev/drivers/`) boot the actual game from the
  imported ROM in the engine's `POKEPORT_DRIVER` mode.
- **Real Yellow + voxel** (`dev/drivers/gen1_voxel.lua`): Yellow with
  DramaticShapeVoxelMod (1.9.0: id `DRAMATIC_SHAPE`; older releases were
  `BATTLE_ART_VOXEL_FORK`) installed unmodified next to the mod, in a folder
  named after its manifest id. The voxel mod is Gen 1 only. The driver types
  an address, connects, puts BUDDY beside the player and checks the voxel
  scene draws him and his name tag on the orbit rungs (50, 15, FULL, 75) and
  in the free cameras, 1ST and 3RD (`VoxelState.FP_LEVEL`/`TP_LEVEL`). In
  those it also checks: the player's own card hidden in 1ST and shown in 3RD,
  BUDDY's tag centred over his head (seen head-on and diagonally) and gone
  when he is behind the eye, A on BUDDY opening his menu, START opening the
  start menu, the free (off-grid) walk reaching the server, and BUDDY gliding
  to an off-grid spot. Probes are read-only: they count `pose()` calls on
  BUDDY and the player (the voxel scene poses every entity it draws), and
  record where `Font.draw` puts each name next to `Voxel3D.project` of
  BUDDY's card, through the voxel mod's `exports.lib`. 1.9.0 has no
  `characterRenderers` API any more. Screenshots in
  `$G1O_WORK/shots/gen1_voxel`. It needs the Yellow cache
  (`G1O_YELLOW_ROM=<rom> dev/setup.sh ...`, profile `gen1online-yellow`) and
  the voxel mod (`G1O_VOXEL_MOD`, default `../DramaticShapeVoxelMod-latest`,
  else `../DramaticShapeVoxelMod-master/DramaticShapeVoxelMod-master`);
  otherwise `run_tests.sh` skips it. In a headless container the real-game
  drivers run under Xvfb (`Xvfb :99 +extension GLX`, `DISPLAY=:99`); Mesa's
  llvmpipe carries the voxel pipeline. The user's Yellow ROM is
  `/home/jt/Desktop/Pokemon/Pokemon - Yellow Version (UE) [C][!].gbc` (same
  rules as the Crystal one). Never edit the voxel mod.
- **Real Yellow game modes** (`dev/drivers/gen1_modes.lua`): Yellow on a
  server with `nuzlocke = hardcore`, `randomizer = on`, `seed = 4242`
  (`run_tests.sh` writes that config and starts the server with
  `GTS_CONFIG`). A new character connects; the driver checks a randomized
  `rollEncounter`, a real item ball through `talkTo`, a `give_item` row
  through the overworld's script runner, Brock's `checkVictoryRewards`, team
  finds both ways (BUDDY over raw HTTP), RUN INFO, the Nuzlocke hooks (battle
  events are emitted, not fought), a wipe starting run 2 and BUDDY's wipe
  starting run 3, and DISCONNECT restoring the vanilla world. First, on the
  vanilla data, the soft-lock checks: every item ball on a logic map is
  walked to (a BFS from the map's warps and edges on the engine's own
  `Map`/`Collision`, with Cut trees, water, boulders and locked Silph doors
  as walls unless the map's requirement has the HM or Card Key; ledges one
  way), and 900 worlds (150 seeds, 1-3 worlds) are replayed as the team
  (finishable, no progression hidden/post-game/on the S.S. Anne, Cut
  learners in 3+ early areas). After connecting it also covers a lost
  report sent again, a full bag sending a team item to the PC, no room at
  all (not counted, comes later), an owed gym prize, and the level cap with
  gyms open out of order. The starters: Red/Blue's lab rows through the
  mod's `script.command` hook (no Red/Blue data here) and Yellow's gift
  through the overworld's runner (BELLSPROUT for seed 4242, the PIKACHU
  scene skipped). Last, a new device (the online files deleted):
  REDEEM RECOVERY TOKEN joins the current run in the shuffled world. Needs
  the Yellow cache only.
- **Real Yellow multiworld** (`dev/drivers/gen1_multiworld.lua`): a server
  with `randomizer = on`, `multiworld = on`, `players = 2`, `seed = 4242`.
  The client joins as world 1, BUDDY (raw HTTP) as world 2, a third trainer
  gets `RUN_FULL`; every progression item is in exactly one world (world 2
  built in the driver with `Modes.planFor(2)`), evenly split; a world-1 ball
  find reaches the team and BUDDY's world-2 find reaches the client; RUN
  INFO; and a new player on the device (its online files deleted) is refused
  on CONNECT and stays offline.
- **Real Yellow Nuzlocke battles** (`dev/drivers/gen1_nuzlocke.lua`): the
  same server config, played in real battles. Wild encounters come from the
  engine's own `onStepComplete` in real grass; battles are driven through
  `src.battle.BattleAPI` (menus, moves), the native bag list (rows carry
  `.value`) and the battle's own YES/NO `ChoiceBox`. Covers: a randomized
  Route 1 species, a POTION refused before any target picker, a real catch,
  the second encounter's ball refused and kept, a lead fainting (buried, the
  player runs), the Safari Zone's own ball menu refused without spending a
  ball, Snorlax's `static_battle` row and a fishing bite shuffled, Brock
  fought for his shuffled badge slot (SET style, no EXP past the level cap),
  a real blackout ending the run, then DISCONNECT and JOIN reloading the run
  from disk without a restart, and a save from an older run restarting.
  Driver gotchas: the battle asks "Use next POKéMON?" with a `ChoiceBox` on
  top (the snapshot says `locked`); a forced switch menu opens on
  `game.partyMenuSavedIndex`; `battle.ended` is observed by wrapping
  `Runtime.emit` (a driver can't use `mod.events`).
  - `follower.lua`: follower and offline checks.
  - `online.lua`: run twice (fresh install, then returning player). Covers
    connect, PVP with non-default moves on both sides, a GTS trade with
    Kadabra→Alakazam trade evolution, save routing, and disconnect.
  - Screenshots go to `$G1O_WORK/shots`. Look at them: they caught misplaced
    name tags that every assertion missed.
- **Real FireRed / LeafGreen** (`dev/drivers/gen3_*.lua`, helpers in
  `gen3_util.lua`): need the caches (`G1O_FIRERED_ROM=<gba>
  G1O_LEAFGREEN_ROM=<gba> dev/setup.sh ...`; profiles `gen1online-frlg` and
  `gen1online-frlg2` for the link driver's second game). `run_tests.sh` runs
  them per game, on a `--gen 3` server:
  - `gen3_online.lua`: a new character, a remote player on the field, PC
    GTS deposit and claim, a Pokémon deposited from a PC box and withdrawn
    back, a KADABRA bought and evolved, Wonder Trade, chat, DISCONNECT and
    back.
  - `gen3_link.lua` (two LÖVE processes, host and guest): a PVP battle and
    a Trade Center link trade over the server.
  - `gen3_modes.lua` (both games; hardcore, randomizer, seed 4242): the map
    walk (`gen3_walk.lua`: every ball and hidden item on a logic map
    reached by a BFS on FireRed's own collision from the map's warps and
    edges: elevation, water, one-way ledges, Cut trees, Rock Smash rocks
    and boulders as walls unless the requirement, with what its `L.FIXED`
    items imply, has the HM; the Pokémon Mansion's switch gates open; it
    found Kindle Road's two balls behind Rock Smash rocks), 200 seeds with items
    and badges (finishable, progression never hidden or post-game), badges
    only, 1-3 worlds x 50 seeds replayed as the team, the 386-species
    shuffle, a shuffled wild battle, a ball, a hidden item and the TEA,
    a starter picked in Oak's lab (CHARMANDER's ball holds SQUIRTLE for
    seed 4242; the question names it), a badge picked up from a ball,
    shared finds both ways, the level cap,
    BROCK fought for his slot (SET, no EXP over the cap), a burial, a wipe
    starting run 2, DISCONNECT restoring vanilla, JOIN again reloading run
    2 from the online save, and BUDDY's wipe while ASH is offline making
    JOIN start run 3 (run 2's save kept as a backup), then a new device:
    REDEEM RECOVERY TOKEN joining run 3 in the shuffled world. It prints
    the item places' fingerprint; `run_tests.sh` checks FireRed's and
    LeafGreen's agree. Wild legendaries are checked by pinning
    `Modes.rules.wildLegendaries` to 100 (wrapping `Modes.synced`, since
    each sync brings the server's rules again): Route 1 gives legendaries
    at their level, a scripted SNORLAX battle keeps its own. Trainers the
    same way (`trainers = gyms`): BROCK's real team is all Rock types, the
    seed's draw for his GEODUDE and ONIX; a route trainer keeps his team,
    the Champion's changes. `gen1_modes.lua` checks Brock's and, through the
    real `trainer.party` hook, Lorelei's Ice team at her levels.
  - `gen3_nuzlocke.lua` (FireRed): real battles. A Route 1 encounter before
    any Poké Ball not counting, an old client (`modesVersion = 0`) turned
    away, a Master Ball thrown from
    the battle bag, the next encounter's ball refused in the bag (the
    reason in `BagMenu.messageText`) and kept, the Safari Zone's BALL
    refused with no Safari Ball spent, an owned species met first on Route
    22 caught (no dupes clause), an encounter with an empty bag still using
    Viridian City up, a fainted MAGIKARP buried, and a real blackout
    starting the next run. The burial battle puts a level-100
    CHARIZARD with FLAMETHROWER second: a shuffled FUTURE SIGHT is worked
    out against the 1-HP lead (Gen 3) and lands on the next one in, which
    once wiped the party and started a new run mid-test.
  - `gen3_multiworld.lua` (FireRed; `multiworld = on`, `players = 2`):
    world 1 joined, BUDDY world 2, a third trainer `RUN_FULL`, another
    game's data `WRONG_WORLD_DATA`, every progression item in one world, a
    world-1 ball picked up for real reaching the team and BUDDY's world-2
    find reaching the client, RUN INFO, and a newcomer refused on CONNECT.
  - `gen3_friend.lua` (FireRed; two LÖVE processes, host ASH and guest
    MISTY, on a hardcore server): both get the rules and see each other on
    Route 1 (ASH's game, its modes dropped, sets them up again from its next
    sync); ASH catches Route 1's first Pokémon and says so in the chat,
    then MISTY catches hers (the area is each player's own); for both the
    next Route 1 ball is refused and kept; then MISTY's lone CATERPIE loses
    a real battle: her wipe ends run 1 for both, ASH is told why, and both
    start run 2 in the bedroom.
  - `gen3_social.lua` (FireRed; plain server, `gts_config.txt` at a dead
    port): JOIN reporting the dead server, SERVER ADDRESS typed through
    `love.textinput`, `Game3:keypressed` and the D-pad (bad addresses
    refused), a new player, MY PROFILE and EXP (read off `G3.Font.draw`),
    ONLINE SETTINGS (title, avatar seen by BUDDY, favorite, token, live
    chat), a chat line typed into the chat box, BUDDY's card through A,
    parties (BUDDY's invite accepted, MEMBERS, WARP TO MEMBER to BUDDY in
    Pallet Town, LEAVE and the party gone; ASH's own party with BUDDY
    joining), and a new device: a wrong token refused,
    REDEEM RECOVERY TOKEN (lower case), DISCONNECT restoring the offline
    game. The mod's menus close when an item is picked, so a screen opened
    from one returns to the field.
- Driver gotchas:
  - Driver mode skips the `core.update` hook, so drivers re-route
    `game.update` through it.
  - FireRed: the mod's own text boxes are `G3.UI.Stack` states, FireRed's
    are `src.ui.game3.message`; `H.fieldFree()` and `H.clearTexts()` answer
    both. The first catch online is an MMO level-up, shown once the battle
    is over. A shuffled wild Pokémon may trap the player (Arena Trap or
    Shadow Tag, by its random personality) or TELEPORT away: drivers check
    `Engine.canRun` before RUN and retry a battle meant to make someone
    faint. `/tmp` logs piped through `grep` need `--line-buffered`.
  - The engine treats a driver like a mod: take `socket.http` from
    `package.loaded`.
- **Never `pkill -f <name>`** where the name appears in your own command. It
  kills your shell. Use `dev/server.sh stop`, or kill by port.
- The engine's own checks: from `../gen1recomp`, run
  `python3 tools/modkit.py validate|lint|gen2check ../Gen1Online` (needs
  `luajit` on PATH: `$G1O_WORK/bin`).

## Server

**Status (2026-10-04).** `server/gts_server.py` is the server, rewritten from
scratch on branch `server-rewrite` against the protocol below. `dev/server.sh`
runs it for the tests. The legacy-server stand-in (`dev/make_test_server.py`)
is gone, and the original 0.5.x server was never in this repo. Gen 1 support
(client and the server's generation lock) followed; both are on `master`.

**One generation per server.** The data file records its world's generation
(`"generation": 1 | 2 | 3`). `--gen 1|2|3` (or `GTS_GENERATION`) sets it;
without it, the first request from a known game claims the world (reads
never do). A request's generation is its `generation` field (GET: `gen`
query param), else read off `gameVersion` ("Pokemon Red" → 1, "Pokemon
Crystal" → 2, "Pokemon FireRed" → 3). FireRed and LeafGreen share a Gen 3
world. A known generation that doesn't match gets
`{"success":false,"error":"WRONG_GENERATION","serverGeneration":N}`; a request
naming no game (a script) is let through. `/server/info` answers
`generation` (null until claimed), and the client checks it on CONNECT. A
Gen 1 world's recovery tokens are 8 letters A–Z (Gen 1's naming keyboard has
no digits); Crystal and Gen 3 worlds' stay 8 hex characters.

### Wire protocol (the client defines it, so a server must match exactly)

Transport and framing:
- Plain HTTP. Without LuaSec the client rewrites `https://` to `http://`, so
  serve plain HTTP.
- `POST /gts` with a JSON body dispatched on `action`. Answers are JSON with
  a `Content-Length`.
- The client's async engine reuses keep-alive connections; it also copes with
  close-after-response.
- Every request carries the `X-Mod-Version` header, and POST bodies carry
  `modVersion`, `version`, `gameVersion` and `recompVersion`. Accept a client
  when its major.minor matches the server's. Otherwise answer
  `{"success":false,"error":"VERSION_MISMATCH","serverVersion":...}`.
- POST bodies also carry `modesVersion` (`GtsUI.MODES_VERSION`, now 4: the
  game modes' rules the client plays). While a game mode is on, the server
  answers a Gen 1 or FireRed/LeafGreen POST below `MODES_VERSION` (logout
  excepted) with `VERSION_MISMATCH`, `serverVersion` "0.5.1+ (GAME MODES)":
  the rules are enforced by each client, so an old copy would play without
  them. Bump both when the rules change.
- Errors are `{"success":false,"error":"CODE"}`. The client acts on
  `VERSION_MISMATCH`, `WRONG_GENERATION`, `ALREADY_LOGGED_IN`, `BANNED` and
  `NAME_TAKEN`.
- POST bodies also carry `generation` (1 or 2) and GETs `&gen=<1|2>`; see
  "One generation per server".
- **Send every JSON answer, errors included, with HTTP 200.** `makeHttpRequest`
  (main.lua ~354) treats any status of 400 or more as a dead transport. It
  re-sends the request over raw TCP and appends that body to the first one,
  so the client can't decode the error, and a write action can run twice. The
  legacy server's 4xx statuses were a latent bug.
- The synchronous helpers send `Connection: close` and read until the socket
  closes. The async engine sends `Connection: keep-alive` and frames answers
  by `Content-Length`. `ThreadingHTTPServer` with `protocol_version =
  "HTTP/1.1"` handles both.
- GETs also carry `?version=<v>&modVersion=<v>` in the query. Don't
  version-gate `/server/info`: the client reads it to compare versions itself.

GET:
| Path | Answer |
| --- | --- |
| `/server/info` | `{success, version, modVersion, generation}` (the client compares major.minor, and the generation: 1, 2 or null) |
| `/chat/history` | `{success, messages:[{id, trainerId, name, text, scope, time}]}`, the last 50 with ascending `id` |
| `/gts/browse` | `{success, listings:{id: listing}, history:[{text, time}]}`, where listing = `{id, trainerId, trainerName, offeredMon, wanted:[species], timestamp}` |
| `/gts/claims?trainerId=` | `{success, claims:[{mon, fromName, fromId, originalOffered, timestamp}]}` |
| `/gts/players` | `{success, players:{trainerId: {name, level, map, ...}}}`, the active players |
| `/gts/profile?trainerId=` | `{success, profile:{name, level, xp, pvpWins, pvpLosses, gtsTrades, serverRank, totalPlayers, rank, badges, pokedexCount, favoriteMon}}` |
| `/player/check_name?name=` | `{taken: bool}` (the name arrives URL-encoded) |

POST `action`s (request fields → answer):

Accounts and profile:
- `register_player` `{isNewCharacter, name, spriteId, title, badges, pokedexCount}` →
  `{success, account}`, where account = `{trainerId, name, token, level, xp,
  spriteId, title, favoriteMon, ...}`. A fresh 6-digit `trainerId` and an
  8-character `token` (hex on Crystal, letters on Gen 1). Names are unique,
  case-insensitive (`NAME_TAKEN`).
- `login_player` `{trainerId, token}` → `{success, account}`.
- `redeem_token` `{token}` → `{success, account}`, for restoring on a new device.
- `update_profile` `{trainerId, token, name, title, spriteId, badges,
  pokedexCount, pvpWins (a delta), blackouts, favoriteMon}` → `{success, profile}`.
- `sync_xp` `{trainerId, token, xpType, badges, pokedexCount, opponentName?, opponentId?}` →
  `{success, level, xp}`. The server owns XP (the client mirrors it).
- `report_battle_stat` `{trainerId, battleType, species?, caught?}` → `{success}`.
- `logout` `{trainerId}` → drop the player from the active players.

Presence:
- `sync_pos` `{trainerId, sessionId, name, spriteId, title, level, map, x, y,
  px, py, fx, fy, facing, moving, species}`, sent every 0.1–2 s, plus a 4 s
  keepalive. The answer is:
  ```
  {success,
   players: [same-map entries, EXCLUDING the requester; the client does not filter itself],
   challenge: {fromId, fromName, type, party, seed, roomId} | null,
   partyInvite, partyXp: [{xp, fromName}], party,
   serverHour, serverMinute, serverWeekday (0 = Sunday)}
  ```
  The clock fields drive the online RTC. Drop players after about 30 s
  without a sync. Answer `ALREADY_LOGGED_IN` when another `sessionId` is live
  for the same `trainerId`.

Chat:
- `send_chat` `{trainerId, name, text, scope}` → `{success, message}`. The
  client profanity-filters the text before sending; the server does not.

Challenges and battles:
- `send_challenge` `{targetId, fromId, fromName, challengeType, party?, seed?, roomId}`.
  `challengeType` is one of `PVP`, `TRADE`, `ACCEPT_PVP`, `ACCEPT_TRADE` or
  `DECLINE`. Store it as the target's pending challenge, and return it on
  every `sync_pos` until `clear_challenge {trainerId}` or about 15 s pass.
  **Relay `roomId` verbatim.** Native-PVP negotiation rides on it: the
  challenger offers `..._L2`, and an accepting 0.5.1+ client answers on
  `..._L2K`.
- `send_battle_msg` `{roomId, targetId, msg}` appends `msg` (opaque JSON) to
  that player's inbox in the room.
- `poll_battle_msgs` `{roomId, myId}` → `{success, msgs}`, which drains the
  inbox. `clear_battle_room {roomId}` deletes it. The native battle sends
  `{type: action|hash|replace|bye|forfeit}` messages and polls every 0.25 s.

GTS:
- `deposit` `{trainerId, trainerName, offeredMon, wanted}` → `{success, listing}`.
  A per-trainer cap is fine; the client allows 10.
- `trade` `{listingId, buyerId, buyerName, sentMon}` → `{success, receivedMon}`.
  Moves `sentMon` into the seller's claim box and removes the listing.
- `withdraw` `{listingId, trainerId}` → `{success, mon}` (`LISTING_GONE` once
  it was bought). `claim` `{trainerId, index, claimId?}` (index 0-based;
  `claimId`, each claim's `id`, wins when given) → `{success, claimed}`.
- Mons are opaque `Protocol.packMon2` tables. Store and relay them; never
  rebuild them.

Wonder Trade:
- `wonder_trade_status`, `wonder_trade_deposit` `{trainerId, trainerName,
  offeredMon}`, `wonder_trade_withdraw` and `wonder_trade_claim`, all keyed on
  `trainerId`. The pool is server-side; see the design notes below.

Parties:
- `party_create`, `party_invite {targetId}`, `party_accept`, `party_decline`,
  `party_leave` and `party_warp_target {targetId}` → `{success, map, x, y}`.
  Parties hold up to 4, as `{leaderId, members: {tid: {name, level, map}}}`.
  Invites and shared XP reach the target through `sync_pos`.

Quests:
- `get_quests` → `{success, quests: []}`. There is no quest content yet.

Game modes (Gen 1 and FireRed/LeafGreen; `server/server_config.txt`,
`--config`, `GTS_CONFIG`):
- The rules view `{nuzlocke: "off"|"hardcore", randomizer, encounters, items,
  badges, starters, wildLegendaries, trainers, sharedKeyItems, active, runId,
  seed}` (`wildLegendaries`: a percent, 0 when off or without the
  randomizer; `trainers`: "off" | "gyms" | "on") rides `/server/info` as
  `rules` and every `sync_pos` answer as `run`, next to `team: {rev, items:
  [ITEM]}`. Sub-flags read false when the randomizer is off;
  `shared_key_items = auto` follows the randomizer.
- `team_status` → `{success, run, team}`.
- `team_found {trainerId, token, runId, item, itemName, location}` →
  `{success, first, team}`; `RUN_OVER` for a stale `runId`, `NOT_SHARED` when
  sharing is off. The clients decide what is shared (badges, key items, HMs;
  not Oak's Parcel, the fossils or Safari Balls).
- `run_wipe {trainerId, token, runId}` → `{success, run, team}`. Hardcore
  only (`NOT_NUZLOCKE`). A wipe of the current run starts the next one: new
  seed (a fixed `seed` replays run 1; later runs derive from it), empty team.
  A late wipe of an ended run changes nothing. `--new-run` does it by hand.
- Multiworld (`multiworld = on`, `players = 2..8`; needs the randomizer and
  something shuffled, and forces `sharedKeyItems`): the rules view adds
  `multiworld` and `players` (1 when off). `run_join {trainerId?, token?,
  fingerprint, gameName}` → `{success, world, players, run}`: a member gets
  their world back, a newcomer the next free one (first come);
  `RUN_FULL`; `WRONG_WORLD_DATA` with the run's `gameName` when the
  fingerprint (`Randomizer.fingerprint` of the item places) differs from the
  first joiner's. Without a trainerId it only checks (CONNECT's
  `Modes.precheck`, before the offline save is touched) and answers
  `{world: null, free}`. `players = 1` never refuses.
- Persisted: `run {id, seed, started, worlds {tid: world}, fingerprint,
  gameName}` (a new run keeps the worlds) and `team {items, rev}`. The client
  stamps its online save with `g1oModes.run`; a save from another run is
  archived (`gen1online_online_save_<game>_run<N>_backup.lua`) and replaced by
  a new game in the bedroom with the same `onlineAccount`.

### The server (`server/gts_server.py`)

**Why a rewrite.** The legacy server was about 2,700 lines, and most of it was
dead weight for a friends' server: Texas Hold'em tables, anti-cheat audits,
an IP ledger, an HTML analytics dashboard, rate limiting, Cloudflare
assumptions and a Gold-only game gate. It also predated 0.5.x, and Wonder
Trade was never server-side. The client fully specifies the protocol above,
so a small server built against it is simpler to trust and to run.

How it is built: `GtsStore` holds all state behind one `RLock` and has one
`act_<action>` method per POST action (collected into `GtsStore.ACTIONS`)
and one route per GET; it knows nothing about HTTP, and takes an injectable
clock for the tests. `GtsHandler` is the `BaseHTTPRequestHandler`
(HTTP/1.1, always 200, `Content-Length` on every answer, chunked request
bodies accepted, `//gts` from a trailing-slash `server_url` normalized, no
request log). Strings round-trip byte-exact (`surrogateescape`). Expiry runs
lazily on requests: presence, challenges and invites every second, GTS
listings and claims every minute.

Beyond the protocol as first written: `withdraw` answers `mon`; `claim` takes
`claimId`; `trade` refuses `OWN_LISTING` and `NOT_WANTED` (species not on the
wanted list); `deposit` answers `LISTING_LIMIT` at 10; a listing that expires
after 30 days goes back to its owner's claim box instead of vanishing.
`report_battle_stat` is acknowledged and nothing more (`sync_xp` counts the
same battles). Other error codes: `BAD_REQUEST`, `BAD_JSON`, `BAD_MON`,
`BAD_NAME`, `UNKNOWN_ACTION`, `NOT_FOUND`, `UNKNOWN_TRAINER`,
`INVALID_TOKEN` (a token was sent and is wrong), `INVALID_LOGIN`,
`TOKEN_NOT_FOUND`, `EMPTY_MESSAGE`, `NOT_YOUR_LISTING`, `NO_CLAIM`,
`NOT_ONLINE`, `NO_INVITE`, `PARTY_FULL`, `ALREADY_IN_PARTY`, `SERVER_ERROR`.

The prompt the rewrite was done from (kept for the record):

> Write `server/gts_server.py`: a single-file, stdlib-only Python 3 server for
> Gen1Online+ that speaks the wire protocol in CLAUDE.md exactly. Follow the
> "One command to host" notes and "Findings from reading main.lua" under
> "Next task" too. It's for playing with friends: no Cloudflare, no analytics,
> no IP logging, no anti-cheat. Use `http.server.ThreadingHTTPServer` with
> `protocol_version = "HTTP/1.1"` (keep-alive, `Content-Length` on every
> answer, HTTP 200 even for errors). One lock around the state. Persist to
> JSON with an atomic write (tmp + rename). Options: `--host` (default
> 0.0.0.0), `--port` (7779), `--data` (default `server/gts_data.json`), also
> settable through the env vars `PORT`, `GTS_DB_PATH` and `GTS_MOD_VERSION`,
> which `dev/server.sh` already sets. The version is `0.5.1`, and any client
> with the same major.minor is accepted. Implement Wonder Trade server-side,
> and update the client to use it and to fix the GTS races. Edit `main.lua`
> byte-exact: it is CRLF and near Lua's local and upvalue limits. Add
> `server/start.sh` and `server/start.bat`. Add a README section on hosting for
> friends: same network (LAN IP, plus `sudo firewall-cmd --add-port=7779/tcp`
> or the Windows firewall prompt), Tailscale (everyone joins the tailnet and
> uses the host's 100.x IP; recommended), or router port forwarding (TCP
> 7779, and share the public IP only with friends). Point the default
> `gts_config.txt` at `http://127.0.0.1:7779`. Done means `python3 -m
> unittest` for the server passes and `dev/run_tests.sh quick` passes with
> `dev/server.sh` running the new server, including the new Wonder Trade
> test. In a cloud session, commit to `server-rewrite`, push, and open a PR
> into `master` that says the real-Crystal drivers still need a local run by
> the user. Locally, don't commit.

**One command to host.** The user wants to start the server on any machine
with a single command and then either port-forward or use Tailscale. So:
- `python3 server/gts_server.py` with no arguments must just work: Python
  3.8+, stdlib only, nothing to install, and listening on `0.0.0.0:7779`. Data
  goes to `server/gts_data.json`, next to the script rather than the current
  directory. Gitignore it.
- Add thin wrappers: `server/start.sh` (Linux/macOS) and `server/start.bat`
  (Windows, double-clickable). Both run the script and pass arguments through.
- On start, print the URLs to give friends: `http://127.0.0.1:7779` for the
  host itself, the LAN IP (UDP-connect trick, no packets sent), and the
  Tailscale IP when `tailscale ip -4` answers. Print each as the
  `server_url=...` line for `gts_config.txt`.
- Exclude `server/` from the mod package. `.modkitignore` matches exact paths
  only, so list each file.

**Design notes from reading main.lua** (session of 2026-10-04; line numbers
are approximate). All of these are implemented:
- *Accounts.* `trainerId` is a 6-digit string (100001–999999), unique. The
  token is 8 uppercase hex characters (`secrets.token_hex(4).upper()`). The
  recovery prompt is Crystal's box keyboard, which has letters and digits.
  Compare tokens case-insensitively. The client reads `trainerId, token,
  level, xp, spriteId, title, favoriteMon, name` off `account`.
  `login_player` succeeds only when the token matches. `check_name` and
  `NAME_TAKEN` compare case-insensitively. The client already
  profanity-filters names, nicknames and chat (`other/profanity.lua`), so a
  friends' server needs no filter of its own.
- *XP drift.* `addMmoXp` (~2235) awards its own amounts: catch 50, wild_battle
  15, trainer_battle 40, pvp_win 100, pvp_loss 25, breeding 50, gts_trade 100,
  gts_deposit 25, gts_claim 50, wonder_trade 75, party_share N. The legacy
  server ignored them and used its own table (unknown types got 10), so the
  two disagreed, and on the next login the client adopts the server's
  numbers. Fix: add `xp = delta` to the `sync_xp` payload in `addMmoXp`, and
  have the server add it, clamped to 0..500, falling back to the table when
  it's absent. The level curve is `xpForLevel(l) = floor(50*(l-1)^1.8)`,
  capped at 100. `sync_xp` also keeps the stats: pvp_win bumps `pvpWins` and
  writes the history line `"<A> DEFEATED <B> IN PVP!"`, pvp_loss bumps
  `pvpLosses`, plus the wild/trainer battle counters. It answers `{success,
  level, xp, leveledUp}`.
- *Wins are counted once.* After a PVP win the client sends `sync_xp`
  pvp_win and then `update_profile` with `pvpWins = 1`. Count the win in
  `sync_xp` only. `gtsTrades` is never sent: count it on `trade`, for buyer
  and seller.
- *Profile.* `/gts/profile` answers `{success, profile}`, where `serverRank`
  is the 1-based position among all accounts sorted by (level, xp, pvpWins,
  badges, pokedexCount) descending, and `totalPlayers` is the account count.
  `rank` titles go by level: 100 POKéMON LEGEND, 90 GRAND MASTER, 80
  CHAMPION, 70 ELITE FOUR, 60 VETERAN, 50 MASTER, 40 ACE TRAINER, 30 EXPERT,
  20 TRAINER, 10 ROOKIE, else NOVICE. Also return `title`, `blackouts`,
  `favoriteMon` and `gtsTrades`.
- *Presence.* A `sync_pos` player entry is the request's presence fields plus
  `trainerId` and a timestamp. Echo it to others **without** `sessionId`, at
  most 16 per map. `ALREADY_LOGGED_IN` fires only if the other session synced
  within the last 10 s, so a crashed client can reconnect at once. `/gts/players`
  is keyed by trainerId, and the party menu reads `name` and `level`.
  Challenges live 15 s, party invites 30 s.
- *Party XP never happens.* No client code asks the server to share XP, and
  the legacy server's `party_share_xp` was never called. Always answer
  `partyXp: []`. Don't invent sharing: each event pops a text box mid-game.
  `party` is the caller's party or `null`, and `party_warp_target` answers
  `{success, map, x, y}` from the target's last sync.
- *Chat.* Ids must keep increasing. The legacy `len(chat)+1` repeated ids
  once the log was trimmed to 100, and the client drops any id at or below
  its `lastId`. Keep a persisted `next_chat_id`. Trim text to 200 characters
  (the client's limit).
- *GTS.* The deposit cap is 10 per trainer, matching the client (the legacy
  server allowed 3). Listing ids look like `GTS_<n>`. `trade` answers
  `{success, receivedMon}` and adds a claim for the seller. `claim` should
  echo `{success, claimed}`. `/gts/claims` answers `{success, claims}`.
  Expire listings after 30 days and claims after 60.
- *GTS client races (fixed in main.lua).* Withdraw (~4108), claim (~4140) and
  buy (~3705) changed the local state before the server answered. Withdrawing
  a listing someone just bought hands the mon back while the buyer also has
  it. Make each one wait for `res.success`. On failure, buy restores the sent
  mon and shows that the listing is gone, withdraw and claim show an error,
  and claim uses `res.claimed.mon`.
- *Wonder Trade design* (client: `GtsUI.openWonderTradeMenu` ~4169; drop its
  local pool and matching):
  - `wonder_trade_status {trainerId}` → `{success, poolCount, threshold: 5,
    mine: {offeredMon, timestamp} | null, claim: {mon, fromName, fromId,
    sentMon} | null}`.
  - `wonder_trade_deposit {trainerId, trainerName, offeredMon}`: one per
    trainer (`ALREADY_IN_POOL`). Refuse while a claim is unclaimed
    (`CLAIM_PENDING`), or a new match would overwrite it. Once the pool
    reaches 5 or more, shuffle it and give each entry's mon to the next entry
    in the cycle, so nobody gets their own. Answer `{success, poolCount,
    matched}`.
  - `wonder_trade_withdraw` → `{success, mon}`, or `NOT_IN_POOL` when it was
    already matched (the client then shows the claim). The client returns
    `res.mon` only on success.
  - `wonder_trade_claim` → `{success, claim}`, or `NO_CLAIM`. The client posts
    first, then animates with `claim.sentMon` as the outgoing mon instead of
    the dummy Pikachu.
  - Deposit removes the mon locally, posts, and puts it back if the answer
    isn't `success`.
- *Persisted vs memory.* Persist accounts (and stats), listings, claims,
  history (newest first, 50), chat (100), the Wonder pool and claims, and the
  id counters. Keep in memory: presence, challenges, battle rooms, parties
  and invites.
- *Leftovers.* The repo-root `gts_database.json` is a legacy database (one
  test account, three profiles). The server never reads it; delete it when
  convenient. `gts_config.txt` and main.lua's `DEFAULT_SERVER_URL` now point
  at `http://127.0.0.1:7779` (they pointed at a dead trycloudflare URL).
- *Tests.* `dev/harness/wonder_test.lua` and `dev/harness/gts_test.lua`
  (wired into `run_tests.sh`), and `server/test_gts_server.py`. See Testing.
- *HTTP sinks (fixed in main.lua).* The LTN12 sinks in `gtsApiGet`,
  `gtsApiPost` and the sync fallback returned nil, which stops LuaSocket's
  pump after the first 2048-byte block: any bigger answer (the GTS browse
  with a handful of listings) was cut off and failed to decode. They return 1
  now. The async engine (`Content-Length` framing) was never affected.

Why not Cloudflare: friends on one Wi-Fi need only the host's LAN IP. Over
the internet, Tailscale gives everyone a stable private IP with no port
forwarding, and it keeps plain HTTP, which the client needs without LuaSec,
off the open internet.

## Known gaps

- Gen 1 has one real-game driver (`gen1_voxel.lua`: connect, a remote
  player, voxel views). A full PVP battle and a link trade between two real
  Gen 1 games are still verified synthetically only (the tests stop once
  each has started).
- For 5 s after a battle the client drops incoming challenge answers as stale
  (`lastBattleEndTime`), on both generations, so an offer made right after a
  battle times out.
- Gen 1 link battles and trades run over `GtsNetAdapter`, which polls the
  server synchronously on the main thread every 0.15 s (Crystal's native
  battle uses the async engine, `pvpBattleSend`). Fine on a LAN; over
  Tailscale or the internet each poll can stall a frame.
- On Gen 1, remote players are added to the overworld's `entities` for the
  `drawWorld` call only (`GtsUI.gen1DrawWorld`), so the engine draws them on
  the flat, tilt and render-pipeline paths; a pipeline draws whatever is in
  `state.entities` and nothing drawn after `drawWorld` reaches the screen.
  Name tags: `render.hud` on the flat path; inside a pipeline, an extra
  effect on the engine's `ctx.drawFx` (the `Pipelines.drawWorld` wrapper),
  placed with the pipeline's own `project`. Tilt shows no tags. The
  projection the pipeline hands `drawFx` is ground-only (no height), so a tag
  is raised by the sprite's on-screen width; its x comes from the cell centre
  (where a voxel card stands), its y from the cell's south edge (as the orbit
  views were tuned). Tags have no depth test: in the voxel views, 1ST
  included, a trainer behind a building still shows a tag over it.
- In DramaticShapeVoxelMod's 1ST and 3RD the walk is free (off the grid) and
  `player.moving` stays false, so `sync_pos` goes out on each cell crossed and
  on the idle interval (0.25 s with someone on the map); remote clients glide
  between those points (measured: a new position every sample over 1 s).
- Remote players only arrive in the answer to this client's own `sync_pos`,
  so an idle client keeps syncing (`GtsUI.idleSyncInterval`: 0.25 s with
  someone else on the map, 1 s alone). DISCONNECT and QUIT log out
  synchronously (`GtsUI.sendLogout`); queued on the async engine the logout
  was never sent.

- Every GTS and Wonder Trade arrival runs through
  `performTradeWithAnimationAndEvolution`, which awards `gts_trade` (100 XP)
  on top of the caller's own award (`gts_claim` 50, `wonder_trade` 75). The
  server adds whatever the client reports, so the totals agree; whether a
  claim should earn both is a design call.
- No client code shares party XP, and the server always answers
  `partyXp: []` (see the design notes); the README and mod card no longer
  promise it.

- In-world link trades don't work on Crystal (the engine's `LinkState` trade
  is Gen 1 only); the GTS covers trading.
- Online saves use the engine's legacy compat store, which logs a "migrate to
  mod.storage" warning. Moving to `mod.cache` or `mod.storage` needs a
  migration that keeps existing players' `save_online_crystal.lua`.
- `gen1online-plus-0.4.0.0.modpkg` is a stale release file in the repo.
- Game modes (`modes/`), by design or not yet done:
  - `logic.lua` is hand-written and conservative per map; an unlisted map
    holds filler only. If no placement works in 60 tries (a data set it
    doesn't know) the items stay vanilla and the player is told. The
    driver's map walk checks it on Yellow only (no Red/Blue data here), and
    only within each map: whether a map can be entered with what it lists
    (gates, guards, cross-map paths) is from the engine's scripts by hand.
    The S.S. Anne is unlisted on purpose: she sails for good after the
    captain's gift (`EVENT_GOT_HM01`), whatever it is.
  - Shuffled: item balls, hidden items, the twelve `give_item` gifts in
    `L.GIFTS`, the gym badge slots (gym TMs stay), and the starters
    (`randomize_starters`, rules view `starters`): `Randomizer.starterPool`
    is every basic Pokémon that evolves twice (no legendaries), and
    `plan.starters` maps Red/Blue's three balls and Yellow's PIKACHU
    (`R.STARTERS`) to distinct ones, salt 20000 (+ world in a multiworld).
    On Gen 1 the `script.command` hook rewrites Oak's lab rows (the
    DexEntryMenu, the `ask`, the received line, `give_pokemon`; Yellow's
    PIKACHU scene rows are skipped) and `load_player_starter_name`; the
    rival's lines and teams stay vanilla. Yellow's starter is a different
    Pokémon, so the PIKACHU follower never comes. Not shuffled: Lua-handler
    gifts (Bicycle, HM02, HM05, fossils, Oak's aides), trainers' teams, the
    gift and trade Pokémon. The Town Map's nest view reads the
    vanilla encounter tables.
  - Each client shuffles its own game's data, so Red/Blue and Yellow players
    on one server get different (each finishable) worlds from one seed.
  - Multiworld: the fill places all N worlds at once against the team's one
    shared inventory, keeps one copy of each progression item (the other
    copies become filler from the worlds' own items, a POTION in badges-only
    mode), and gives the next progression item to the world holding the
    least so far. With `worlds = 1` the plan is exactly the plain
    randomizer's. Anything that builds or fingerprints must use the vanilla
    data (`withVanilla` in `modes/init.lua`): an applied shuffle changes the
    map objects. A world's items are only reachable by its player, so a
    player who stops playing can stall the run; no takeover by design.
  - Field moves still need a party Pokémon that knows the HM. The species
    shuffle is drawn again (salt + 10000 per try, the same on every client)
    until `L.FIELD_MOVES` holds: CUT learners in 3+ early wild areas. SURF and
    STRENGTH always have gift Pokémon in time (the Mt. Moon Magikarp, the
    Dojo's Hitmons, the Celadon Eevee, the Silph Lapras). In a hardcore run
    the catch rules can still leave a player without one: blacking out on
    purpose restarts the run.
  - The hardcore level cap is the highest of: the next leader by badges
    held, by leaders beaten (`victories` flags), and the weakest leader not
    yet beaten whose gym the logic says is open with the bag and PC. In gym
    order that is the vanilla cap.
  - Each player's own finds are kept in the save (`g1oModes.found`) and sent
    again with every new team view until the team has them; a team item
    is only marked received (`got`) once it found room (bag, else item PC);
    a gym prize with no room anywhere goes to `g1oModes.owed`.
  - Nuzlocke areas are map ids (each floor counts). The first wild Pokémon
    met in an area is the only one that may be caught, whatever it is (no
    dupes clause). Nothing counts until the player first has Poké Balls
    (`st.hadBalls`, sticky; a save with any area used counts as having had
    them); after that an empty bag still uses an area up. Pokémon from the
    GTS, Wonder Trade and link trades skip the catch rules (a design call).
  - The hardcore rules hook `item.use` (the bag), `ItemEffects.needsTarget`
    (a refused item gets no target picker), `BattleState.safariAction` (the
    Safari Zone's own BALL), `battle.style`, `exp.gain`, and the
    `battle.started` / `battle.ended` / `world.blacked_out` events. Link
    battles use copies of the party, so PVP never buries anything.
- Game modes on FireRed/LeafGreen (`modes/frlg.lua`, `modes/logic_frlg.lua`):
  - Shuffled: item balls, hidden items, the gifts in `L.GIFTS` (TEA, LIFT
    KEY, SILPH SCOPE, HM06, NET BALL: scripts with the standard obtain-item
    call) and the gym badge slots. Fixed (`L.FIXED`): S.S. TICKET, HM01,
    BICYCLE, POKé FLUTE, HM03, HM04, TRI-PASS, and the gym TMs.
  - Badges are flags. A badge the shuffle puts in a ball or a gift travels
    as a marker item (unused `ITEM_034`..`ITEM_03B`) that reads as the badge
    (`ItemsData.info`), always fits (`Bag.canAdd`) and sets the flag when
    picked up (`Bag.add`). A leader's slot hands over its content when his
    script sets the badge flag (`Flags.setFlag` with a script context), with
    a note after the battle; his own defeat text still names his badge (most
    leaders' texts aren't in the script bundle, so they aren't rewritten).
  - Only field moves, Viridian Gym's door and the Route 22/23 guards check a
    badge flag (every script scanned), so badges are plain progression. The
    logic covers Kanto and One to Three Island before the Elite Four;
    post-game maps (Cerulean Cave, Four to Seven Island) hold filler.
  - Trainers (`randomize_trainers`, `M.trainerTeam`): the engine's
    `trainer.party` hook (BattleBridge.start, names in, numbers back). Types
    by trainer number (`M.TRAINER_TYPE`: Brock 414..Sabrina 420, Giovanni
    350, the Elite Four 410-413 and 735-738) or by the gym map the battle is
    in (`M.GYM_TYPE`); the Champion (438-440, 739-741) any type; with "on"
    everyone else. `Randomizer.trainerTeam` picks among the nearest by
    base-stat total (6 themed, 10 not; no legendaries, no repeats while it
    can), from Rng(seed, 30000 + trainer [+ world * 1000]). Moves are
    cleared so the new Pokémon get their own. Gen 1 does the same in its
    `trainer.party` hook (class, party index, party): types by gym map
    (`M.GYM_TYPE`, leaders and their trainers) or class (`M.ELITE_TYPE`),
    OPP_RIVAL3 any type, salt from "CLASS#party".
  - Wild legendaries (`M.wildLegendary`): `BattleBridge.startWild` calls
    with no options (the field's grass, water, fishing, Rock Smash and Sweet
    Scent) roll `Randomizer.rollLegendary` (love.math.random) against the
    rules' `wildLegendaries` percent, from all 21 (`speciesData`'s legend
    set), before the species shuffle. A scripted battle always passes
    options (its `done` at least) and keeps its Pokémon. Gen 1 rolls in the
    `encounter.species` / `encounter.fishing` hooks, from `R.LEGENDARY`.
  - Starters: Oak's balls (`FR_OAKS_LAB`) put their species in VAR_TEMP_2
    after their index in VAR_TEMP_1; `M.starterRows` finds those rows by
    place, `apply` sets them and rewrites the question text (found by "X is
    your choice." in the bundle's text table) with the new name and type.
    FireRed and LeafGreen draw the same three.
  - Species: all 386 by national number, in strength tiers, the legendaries
    (Jirachi and Deoxys included) among themselves. Every wild battle goes
    through `BattleBridge.startWild` (grass, water, fishing, Rock Smash, the
    scripted ones); roamers and the Pokémon Tower's ghost keep their species.
    With the shuffle on, Johto and Hoenn Pokémon evolve before the National
    Pokédex (`Evolution.nationalAllows`).
  - Nuzlocke: battle items refused through `BattleItems.isBattleUsable` (the
    bag offers CANCEL), a refused ball through the bag's and the Safari
    menu's own "box is full" stop with the reason, SET through
    `Options.battleStyle`; the old man's demo, the POKé DUDE and ghosts never
    use up an area. Caps: 14, 21, 24, 29, 43, 43, 47, 50, then 63.
  - FireRed and LeafGreen hold the same item places (one fingerprint), so
    their players can share a multiworld run.
