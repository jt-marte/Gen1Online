# Gen1Online+

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Mod Version: v0.5.1](https://img.shields.io/badge/version-0.5.1-green.svg)](manifest.json)
[![Games: Red, Blue, Yellow, Crystal, FireRed, LeafGreen](https://img.shields.io/badge/target-Red%20%7C%20Blue%20%7C%20Yellow%20%7C%20Crystal%20%7C%20FireRed%20%7C%20LeafGreen-blue.svg)](https://github.com/bryanthaboi/gen1recomp)

Online multiplayer for *Pokémon Red, Blue, Yellow, Crystal, FireRed* and *LeafGreen* on the [gen1recomp](https://github.com/bryanthaboi/gen1recomp) engine: see other trainers on the map, trade, battle and chat, on a server you host for your friends.

## Features

- **Live co-op overworld**: other players walk the map with you, with name tags and trainer avatars.
- **Trading**: the GTS (START menu and the Pokémon Center PC), Wonder Trade, and face-to-face link trades on Red/Blue/Yellow and FireRed/LeafGreen (Crystal trades through the GTS). Trade evolutions included.
- **PVP**: face another player, press **A**, and battle on the game's own link battle.
- **Chat, co-op parties** (up to 4; warp to a teammate), trainer cards and an online level.
- **A separate online save**: your offline save is never touched.
- **Crystal extras**: true-color follower sprites, a shared server clock for day and night, and a PokéGear chat tab with [pokegear_cards](https://github.com/1Jamie/pokegear_cards).
- **Game modes** on Red/Blue/Yellow and FireRed/LeafGreen: hardcore Nuzlocke, co-op randomizer, randomized trainers, wild legendaries, shared key items and multiworld. See [Game modes](#game-modes).

A server hosts one generation: Red/Blue/Yellow together, Crystal, or FireRed/LeafGreen together.

## Hosting a server

The server is one Python file: Python 3.8 or newer, nothing to install.

1. **Start it**: `server/start.sh` (Linux/macOS) or double-click `server\start.bat` (Windows; tick "Add python.exe to PATH" when installing Python). It prints the addresses to give your friends. **Ctrl+C** stops it; your world lives in `server/gts_data.json`.
2. **Set it up** in `server/server_config.txt`, then restart: the address and port it listens on (`host`, `port`) and the game modes. Command-line flags win over the file: `--host`, `--port`, `--data <file>`, `--gen 1|2|3`, `--config <file>`, `--new-run`.
3. **Connect each game**: **START > CONNECT > SERVER ADDRESS**, type the host's address (like `192.168.1.23`; `:7779` is added when there's no port) and press **A**. The game remembers it. `gts_config.txt` in the mod folder holds the default, `server_url=http://127.0.0.1:7779`, which is right for the host.
4. **Let friends reach it**, one of:
   - **Same Wi-Fi**: the host's LAN address. Let TCP 7779 through the firewall: `sudo ufw allow 7779/tcp`, `sudo firewall-cmd --add-port=7779/tcp`, or on Windows allow Python on private networks.
   - **[Tailscale](https://tailscale.com/download)** (best over the internet): everyone joins the host's tailnet and uses its `100.x.y.z` address. Nothing to forward.
   - **Port forwarding**: forward TCP 7779 to the host and share your public IP with friends only.

The first game to connect decides the server's generation (or start it with `--gen`). To host two, give each its own port and data file: `server/start.sh --gen 1 --port 7780 --data server/gts_data_gen1.json`.

A recovery token is shown when a character is created; **REDEEM RECOVERY TOKEN** restores the character on another device.

## Game modes

Red/Blue/Yellow and FireRed/LeafGreen servers; everyone on the server plays the same run. All are off by default. `server/server_config.txt`:

```
host = 0.0.0.0             # 127.0.0.1 = this PC only
port = 7779
nuzlocke = hardcore        # off | hardcore
randomizer = on            # off | on
randomize_encounters = on
randomize_items = on
randomize_badges = on
randomize_starters = on
randomize_trainers = off   # gyms | on (every trainer)
wild_legendaries = off     # on (1 in 100) or a percent, like 2
shared_key_items = auto    # auto = on with the randomizer
multiworld = off           # on: one world per player
players = 2                # multiworld only
seed =                     # a number replays the same world
```

- **Hardcore Nuzlocke**: only the first wild Pokémon you meet in each area can be caught (encounters before your first Poké Balls don't count), fainted Pokémon are gone for good, no items in battle, SET style, and a level cap at the next gym leader's ace. If any player's whole party faints, the run ends for everyone and a new world begins.
- **Randomizer**: wild Pokémon (swapped for ones of similar strength; on FireRed/LeafGreen any of the 386), items, gym badges and Oak's starters, with progression logic so every run can be finished. **Trainers**: random teams of the same strength; gym leaders and the Elite Four keep their type. **Wild legendaries**: a small chance per wild encounter.
- **Shared key items**: key items, HMs and badges belong to the team; whatever one player finds, everyone gets.
- **Multiworld**: each player gets their own world, and every key item exists in only one of them.
- **ONLINE > RUN INFO** shows the modes, the level cap, your fallen Pokémon and the team's finds.

Turning a mode on, or a new run starting, restarts each player's **online** save in the bedroom (the old one is kept as a backup). While a mode is on, every player needs the current version of the mod. On FireRed/LeafGreen, online link trades ignore the National Pokédex lock.

## Follower sprites (Crystal)

The follower sheets live in `assets/followers/`. `tools/import_emerald_follower.py --emerald-dir <pokeemerald-expansion>/graphics/pokemon --out-dir assets/followers --all` makes more from a [pokeemerald-expansion](https://github.com/rh-hideout/pokeemerald-expansion) checkout.

## Credits

- **Project Lead & Core Direction**: **Brookes**
- **Original Mod Creator**: **Gamecorner33**
- **Engine, Netcode, RTC Sync & Cart Architecture**: **Antigravity**
- **Platform & Recompilation Engine**: **bryanthaboi** and the **Gen 1 Recomp Team** ([bryanthaboi/gen1recomp](https://github.com/bryanthaboi/gen1recomp))
- **Decompilation Assets & Sprite Data**: **pret** / The **pokeemerald** & **pokeemerald-expansion** decompilation projects ([rh-hideout/pokeemerald-expansion](https://github.com/rh-hideout/pokeemerald-expansion))
- **MMO Architecture Foundation**: **alamops** ([alamops/RBYMMOMod](https://github.com/alamops/RBYMMOMod))
- **PotatoVoxel 3D Diorama Bridge**: **ShaneMcGovernIE** ([ShaneMcGovernIE/potato_voxel](https://github.com/ShaneMcGovernIE/potato_voxel))
- **PokéGear Cards Expansion**: **1Jamie** ([1Jamie/pokegear_cards](https://github.com/1Jamie/pokegear_cards))
