# Gen1Online+ - Multiplayer, GTS & Overworld Expansion

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Mod Version: v0.5.1](https://img.shields.io/badge/version-0.5.1-green.svg)](manifest.json)
[![Games: Red, Blue, Yellow, Crystal](https://img.shields.io/badge/target-Red%20%7C%20Blue%20%7C%20Yellow%20%7C%20Crystal-blue.svg)](https://github.com/bryanthaboi/gen1recomp)

**Gen1Online+** brings a complete real-time multiplayer co-op experience and a 24/7 Global Trade Station (GTS) to *Pokémon Red*, *Blue*, *Yellow* and *Crystal*, plus true-color overworld follower sprites and a real-time authoritative server clock on Crystal.

A server hosts one generation's world: Gen 1 players (Red, Blue and Yellow together) play with each other, and Crystal players with each other.

---

## 🌟 Key Features

### 🌐 1. Real-Time 60FPS Threaded Multiplayer
- **Seamless Overworld Co-op**: Live player movement synchronization across Johto and Kanto with zero stutter or lag.
- **Player Customization**: Walkable character avatars (`RED`, `BLUE`, `LEAF`, `PROF. OAK`, `COOLTRAINER`, `TEAM ROCKET`, and various trainer classes).
- **Dedicated Dual-Save Architecture**: Online progress writes strictly to its own file in the mod's private storage (`save_online_crystal.lua`, `save_online_red.lua`, ...), leaving your offline save untouched.

### 🕒 2. Authoritative Server RTC Clock & Day/Night Sync (Crystal)
- **Synchronized Real-Time Clock**: Server broadcasts the canonical hour, minute and day of the week on every sync heartbeat.
- **Unified Day/Night Cycles**: Ensures all players in the world experience synchronized morning, day, night lighting and encounter tables. Manual clock manipulation is locked out for fair gameplay.

### 🐾 3. 1:1 True-Color PokeEmerald Follower Sprites (Crystal; Yellow keeps its own Pikachu)
- **Authentic Gen 3 Follower Sprites**: True-color overworld follower sprites for all Generation 1 & 2 Pokémon.
- **Dynamic Directional Walking**: Followers mirror the player's movements with full 4-direction animations.

### 💬 4. Global & Local Chat + PokéGear Integration
- **Real-Time Live Notifications**: Receive popup alerts when other trainers send messages in the world.
- **Dedicated PokéGear Chat Tab** (Crystal, with the optional [pokegear_cards](https://github.com/1Jamie/pokegear_cards) mod): Full scrollable chat history built directly into the player's PokéGear with unread badges.

### 🏪 5. 24/7 Global Trade Station (GTS) & Overworld PVP
- **Persistent GTS Network**: Deposit and search for Pokémon listings asynchronously.
- **Overworld Direct PVP Battles**: Walk up to any trainer in the world, face them, and press **`A`** to challenge them. Battles run on the recomp's native lockstep link battle. On Red, Blue and Yellow you can also link-trade face to face; on Crystal, trade through the GTS.

### 👥 6. Co-Op Party System
- **Party System (Up to 4 Players)**: Invite nearby trainers, view live teammate locations and levels.

### 💀 7. Hardcore Nuzlocke & Co-Op Randomizer (Red, Blue, Yellow)
The host turns these on in `server/server_config.txt`; everyone on the server plays the same run.
- **Co-Op Randomizer**: wild Pokémon (each swapped for one of similar strength), items and gym badges are shuffled from the run's seed. Brock might hand you a POTION while the BOULDERBADGE lies in an item ball in Mt. Moon or comes from an NPC. Placement follows the game's progression, so every run can be finished: nothing you need is left aboard the S.S. Anne (she sails for good), and the early routes always hold wild Pokémon that can learn CUT.
- **Shared Key Items**: key items, HMs and badges are the team's. Whatever one player finds, every player gets.
- **Multiworld (optional)**: each player gets their own world, and every badge, HM and key item exists in only one of them. The BOULDERBADGE might be in your friend's Mt. Moon and nowhere in yours; when they pick it up, you both have it. The shuffle still guarantees the team can finish, splits the key items evenly, and gives each world its own wild Pokémon.
- **Hardcore Nuzlocke**: only the first wild Pokémon in each area can be caught (per player, with the dupes clause), fainted Pokémon are gone for good, no items in battle, SET battle style, and a level cap at the next gym leader's ace (with shuffled badges, the weakest gym leader you can reach and haven't beaten, so a fight you need is never above it). If **any** player's whole party faints, the run ends for the whole team and everyone starts over in a new world.
- **ONLINE > RUN INFO** shows the modes, the level cap, your fallen Pokémon and the team's finds.

---

## 🎨 Importing Follower Assets from PokéEmerald Decompilation

The mod supports loading true-color overworld follower sprite sheets directly from a local clone of the **[pokeemerald-expansion](https://github.com/rh-hideout/pokeemerald-expansion)** or **[pokeemerald](https://github.com/pret/pokeemerald)** decompilation repository.

### How to Acquire and Import Assets

1. **Locate Your Local Decompilation Folder**:
   Find your local checkout of the decompilation repository (e.g. `pokeemerald-expansion/graphics/pokemon/`).

2. **Source Sprite Sheets**:
   Follower sprite assets are located within each species subfolder:
   ```text
   graphics/pokemon/<species_name>/
   ├── walking.png  (or follower.png / overworld.png)
   └── palette.pal
   ```

3. **Place Assets in the Mod Directory**:
   Copy the extracted 32x32 / 16x16 4-directional walking sprite sheets into:
   ```text
   pokemon-gen1-recomp/mods/gen1online-plus/assets/followers/
   ```
   Name each sprite file by species name or national Pokédex index (e.g., `025_pikachu.png`, `151_mew.png`, `249_lugia.png`).

4. **Auto-Detection**:
   When launching the game, `Gen1Online+` automatically mounts and renders true-color sprite sheets for player followers.

---

## 🛠️ Hosting a Server for Friends

The server is one Python file with nothing to install. One person hosts it, and everyone (the host too) points their game at it.

### 1. Start the server

You need Python 3.8 or newer ([python.org](https://www.python.org/downloads/); on Windows, tick "Add python.exe to PATH" in the installer).

- **Linux / macOS**: `server/start.sh` (the same as `python3 server/gts_server.py`)
- **Windows**: double-click `server\start.bat`

It listens on port **7779** and keeps accounts, GTS listings, chat and the Wonder Trade pool in `server/gts_data.json` (copy that file to back up your world). When it starts, it prints the `server_url=...` lines to hand out. Options: `--port 8000`, `--host 127.0.0.1` (this PC only), `--data path/to/file.json`, `--gen 1` or `--gen 2`. Stop it with **Ctrl+C**.

**One generation per server.** A server is either a Gen 1 world (Red, Blue and Yellow) or a Crystal world. The first game to connect decides, or start it with `--gen 1` (Gen 1) or `--gen 2` (Crystal) to decide up front. A game of the other generation is told the server isn't for it and never joins. To host both, run two servers with their own port and data file:
```text
server/start.sh --gen 2
server/start.sh --gen 1 --port 7780 --data server/gts_data_gen1.json
```

### 2. Point each game at it

In the game: **START > CONNECT > SERVER ADDRESS**, type the host's address from step 3 (for example `192.168.1.23`, or `100.64.0.7` over Tailscale; `:7779` is added when no port is given) and press **A**. The game remembers it and connects. With a controller, **UP/DOWN** change the last character, **RIGHT** adds one and **LEFT** or **B** deletes; with a keyboard just type and press **Enter**. **USE CONFIG FILE** forgets the typed address.

`gts_config.txt` in the mod's folder (next to `main.lua`) is the default for a game that has no typed address, which suits the host:
```text
server_url=http://127.0.0.1:7779
```

### 3. Let your friends reach it (pick one)

**Same Wi-Fi / LAN.** Friends use the host's LAN address, which the server prints (for example `server_url=http://192.168.1.23:7779`). Let the port through the host's firewall:
- Fedora: `sudo firewall-cmd --add-port=7779/tcp` (add `--permanent` to keep it after a reboot)
- Ubuntu: `sudo ufw allow 7779/tcp`
- Windows: when the firewall prompt asks about Python, allow it on **private networks**.

**Tailscale (recommended over the internet).** Everyone installs [Tailscale](https://tailscale.com/download) and joins the host's tailnet (the host invites friends, or shares the machine with them). Friends use the host's `100.x.y.z` address (`tailscale ip -4`, also printed by the server): `server_url=http://100.x.y.z:7779`. Nothing to forward, and the server stays off the open internet.

**Router port forwarding.** Forward TCP port 7779 on the router to the host's LAN address, and give friends `server_url=http://<your public IP>:7779`. Share that address only with friends: the server is built for people you trust, with no passwords beyond each player's recovery token.

A player's recovery token (shown when the character is created) restores the online character on a new device through **ENTER RECOVERY TOKEN**.

### 4. Game modes (optional, Red/Blue/Yellow servers)
Edit `server/server_config.txt` and restart the server:

```
nuzlocke = hardcore      # off | hardcore
randomizer = on          # off | on
randomize_encounters = on
randomize_items = on
randomize_badges = on
shared_key_items = auto  # auto = on with the randomizer
multiworld = off         # on: one world per player, key items split between them
players = 2              # how many worlds (multiworld only)
seed =                   # a number replays the same world; empty = a new world every run
```

The server prints the active modes, the run number and its seed when it starts. `--config <file>` (or `GTS_CONFIG`) uses another file, and `--new-run` ends the current run by hand. Turning a mode on, or a new run starting, restarts every player's **online** save from their bedroom (with the same online character); the old online save is kept as a backup, and offline saves are never touched. Players on Red/Blue and on Yellow get worlds shuffled from the same seed, each one finishable in their own game.

With `multiworld = on`, the first `players` trainers to join a run each take a world and keep it (also when a Nuzlocke run restarts). Anyone else is told the run is full, and everyone has to play the same game's data (Red/Blue, or Yellow: the first player to join decides). A world's items can only be picked up by its own player, so if someone stops playing, the team may get stuck.

---

## 👨‍💻 Credits & Acknowledgements

- **Project Lead & Core Direction**: **Brookes**
- **Original Mod Creator**: **Gamecorner33**
- **Engine, Netcode, RTC Sync & Cart Architecture**: **Antigravity**
- **Platform & Recompilation Engine**: **bryanthaboi** and the **Gen 1 Recomp Team** ([bryanthaboi/gen1recomp](https://github.com/bryanthaboi/gen1recomp))
- **Decompilation Assets & Sprite Data**: **pret** / The **pokeemerald** & **pokeemerald-expansion** decompilation projects ([rh-hideout/pokeemerald-expansion](https://github.com/rh-hideout/pokeemerald-expansion))
- **MMO Architecture Foundation**: **alamops** ([alamops/RBYMMOMod](https://github.com/alamops/RBYMMOMod))
- **PotatoVoxel 3D Diorama Bridge**: **ShaneMcGovernIE** ([ShaneMcGovernIE/potato_voxel](https://github.com/ShaneMcGovernIE/potato_voxel))
- **PokéGear Cards Expansion**: **1Jamie** ([1Jamie/pokegear_cards](https://github.com/1Jamie/pokegear_cards))
