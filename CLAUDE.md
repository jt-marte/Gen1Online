# Gen1Online+ (mod id `gen1online-plus`)

Online multiplayer mod for **Pokémon Red, Blue, Yellow and Crystal** on the
gen1recomp engine (a LÖVE2D re-implementation). Live co-op overworld, GTS
trading, PVP link battles, global chat, co-op parties, a separate online save;
true-color followers and the server RTC on Crystal only, face-to-face link
trades on Gen 1 only. `manifest.json` `"games": ["red", "blue", "yellow",
"crystal"]`. A server hosts one generation's world (see "Server").

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
  own Pikachu follower (`src.world.PikachuFollower`) alone.
- **The server is for friends**, with no Cloudflare. See "Server" below.
- The user's Crystal ROM (v1.1, verified SHA-1) is at
  `/home/jt/Desktop/Pokemon/Pokemon - Crystal Version (UE) (V1.1) [C][!].zip`.
  It is the user's own copy: never commit it, copy it into the repo, or
  share it.

## Layout

| Path | What |
| --- | --- |
| `main.lua` | ~6,800 lines, nearly the whole mod. **CRLF line endings.** |
| `pvp/` | Fallback Gen 2 PVP engine, used only against pre-0.5.1 peers. |
| `other/`, `games/` | Gen 1 casino (Crash, Tube Flyer, Prize Case, pawn). Off: main.lua returns before setting it up on Gen 1, and on Crystal its maps don't exist. |
| `npcs/`, `quests/` | Registries (empty). `npcs/{quest,trade}/*` are dead Gen 1 leftovers. |
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
  missing, pinned to the verified commit. The tests run `server/gts_server.py`
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
  - `follower.lua`: follower and offline checks.
  - `online.lua`: run twice (fresh install, then returning player). Covers
    connect, PVP with non-default moves on both sides, a GTS trade with
    Kadabra→Alakazam trade evolution, save routing, and disconnect.
  - Screenshots go to `$G1O_WORK/shots`. Look at them: they caught misplaced
    name tags that every assertion missed.
- Driver gotchas:
  - Driver mode skips the `core.update` hook, so drivers re-route
    `game.update` through it.
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
(`"generation": 1 | 2`). `--gen 1|2` (or `GTS_GENERATION`) sets it; without
it, the first request from a known game claims the world (reads never do).
A request's generation is its `generation` field (GET: `gen` query param),
else read off `gameVersion` ("Pokemon Red" → 1, "Pokemon Crystal" → 2, Gen 3
names → 3, refused). A known generation that doesn't match gets
`{"success":false,"error":"WRONG_GENERATION","serverGeneration":N}`; a request
naming no game (a script) is let through. `/server/info` answers
`generation` (null until claimed), and the client checks it on CONNECT. A
Gen 1 world's recovery tokens are 8 letters A–Z (Gen 1's naming keyboard has
no digits); a Crystal world's stay 8 hex characters.

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
