#!/bin/sh
# Run the Gen1Online test suite.  Needs dev/setup.sh first.
#   dev/run_tests.sh            synthetic tests + real-Crystal drivers
#   dev/run_tests.sh quick      synthetic tests only (no ROM needed)
# Screenshots from the real-game drivers land in $G1O_WORK/shots.
DEV=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$DEV")
export G1O_WORK=${G1O_WORK:-/tmp/gen1online-dev}
export G1O_DEV=$DEV MOD_DIR=$REPO GTS_PORT=${GTS_PORT:-17781}
RECOMP=${G1O_RECOMP:-$(dirname "$REPO")/gen1recomp}
LUAJIT=$G1O_WORK/bin/luajit
LOVE=$G1O_WORK/bin/love
PROFILE=$G1O_WORK/xdg/love/gen1online-test
status=0
step() { echo "== $1: $2"; [ "$2" = "ALL PASS" ] || status=1; }
result() { grep -E 'ALL PASS|FAILED' "$1" | tail -1; }

if (cd "$REPO" && python3 -m unittest server/test_gts_server.py) > "$G1O_WORK/server_unittest.log" 2>&1; then
  step "server unittest" "ALL PASS"
else
  step "server unittest" "FAILED (see $G1O_WORK/server_unittest.log)"
fi

cd "$RECOMP" || exit 1
"$LUAJIT" -e "local f=io.open('$REPO/main.lua','rb'); local c,e=loadstring(f:read('*a'),'@main.lua'); print(c and 'main.lua compiles' or e)"

"$LUAJIT" "$DEV/harness/offline_test.lua" > "$G1O_WORK/offline.log" 2>&1
step "synthetic offline" "$(result "$G1O_WORK/offline.log")"
"$LUAJIT" "$DEV/harness/modes_test.lua" > "$G1O_WORK/modes.log" 2>&1
step "game modes (seed, logic, placement)" "$(result "$G1O_WORK/modes.log")"
"$DEV/server.sh" >/dev/null
DEV=1 "$LUAJIT" "$DEV/harness/online_test.lua" > "$G1O_WORK/online.log" 2>&1
step "synthetic online" "$(result "$G1O_WORK/online.log")"
"$DEV/server.sh" >/dev/null
DEV=1 "$LUAJIT" "$DEV/harness/wonder_test.lua" > "$G1O_WORK/wonder.log" 2>&1
step "synthetic wonder trade" "$(result "$G1O_WORK/wonder.log")"
"$DEV/server.sh" >/dev/null
DEV=1 "$LUAJIT" "$DEV/harness/gts_test.lua" > "$G1O_WORK/gts.log" 2>&1
step "synthetic gts" "$(result "$G1O_WORK/gts.log")"

# the server address typed in-game, on Crystal and on Gen 1
for g in crystal yellow; do
  "$DEV/server.sh" >/dev/null
  G1O_GAME=$g DEV=1 "$LUAJIT" "$DEV/harness/address_test.lua" > "$G1O_WORK/address_$g.log" 2>&1
  step "synthetic server address ($g)" "$(result "$G1O_WORK/address_$g.log")"
done

# Gen 1: Red, Blue and Yellow on a Gen 1 server; each generation turned away
# by the other's server
for g in red blue yellow; do
  G1O_GAME=$g "$LUAJIT" "$DEV/harness/gen1_offline_test.lua" > "$G1O_WORK/gen1_offline_$g.log" 2>&1
  step "synthetic gen1 offline ($g)" "$(result "$G1O_WORK/gen1_offline_$g.log")"
  GTS_GENERATION=1 "$DEV/server.sh" >/dev/null
  G1O_GAME=$g DEV=1 "$LUAJIT" "$DEV/harness/gen1_test.lua" > "$G1O_WORK/gen1_$g.log" 2>&1
  step "synthetic gen1 online ($g)" "$(result "$G1O_WORK/gen1_$g.log")"
done
# the hardcore Nuzlocke's trade limit (1 per gym leader) on every way a
# Pokémon comes in by trade: GTS, Wonder Trade, link trade offers and answers
mkdir -p "$G1O_WORK/server"
printf 'nuzlocke = hardcore\nnuzlocke_trades = 1\n' > "$G1O_WORK/server/trades_config.txt"
GTS_CONFIG="$G1O_WORK/server/trades_config.txt" GTS_GENERATION=1 "$DEV/server.sh" >/dev/null
G1O_GAME=yellow DEV=1 "$LUAJIT" "$DEV/harness/nuzlocke_trades_test.lua" > "$G1O_WORK/nuzlocke_trades.log" 2>&1
step "synthetic nuzlocke trade limit (yellow)" "$(result "$G1O_WORK/nuzlocke_trades.log")"
GTS_GENERATION=1 "$DEV/server.sh" >/dev/null
DEV=1 "$LUAJIT" "$DEV/harness/wrong_world_test.lua" > "$G1O_WORK/wrong_world_crystal.log" 2>&1
step "synthetic wrong world (crystal on gen 1)" "$(result "$G1O_WORK/wrong_world_crystal.log")"
GTS_GENERATION=2 "$DEV/server.sh" >/dev/null
G1O_GAME=red DEV=1 "$LUAJIT" "$DEV/harness/wrong_world_test.lua" > "$G1O_WORK/wrong_world_red.log" 2>&1
step "synthetic wrong world (red on crystal)" "$(result "$G1O_WORK/wrong_world_red.log")"

if [ "${1:-}" != "quick" ]; then
  if [ ! -f "$PROFILE/crystal/rom-cache.complete" ]; then
    echo "== real Crystal: skipped (run dev/setup.sh <rom> first)"
  else
    "$DEV/server.sh" >/dev/null
    "$DEV/install_mod.sh" >/dev/null
    rm -rf "$PROFILE/mod_compat" "$PROFILE/saves" "$PROFILE"/save_crystal.lua*
    mkdir -p "$G1O_WORK/shots"
    run() {
      XDG_DATA_HOME=$G1O_WORK/xdg POKEPORT_IDENTITY=gen1online-test POKEPORT_VERSION=crystal \
        POKEPORT_BACKGROUND=1 POKEPORT_DRIVER=$DEV/drivers/$1 SHOTS=$G1O_WORK/shots/$2 \
        timeout 600 "$LOVE" . > "$G1O_WORK/$2.log" 2>&1
      step "real Crystal $2" "$(result "$G1O_WORK/$2.log" | sed 's/.*\t//')"
    }
    run follower.lua follower
    run online.lua online_fresh
    run online.lua online_returning
  fi
fi
# Real Yellow with DramaticShapeVoxelMod installed unmodified next to the mod:
# remote players inside the voxel scene, name tags in every view, the free
# cameras (1ST and 3RD).  Needs the Yellow cache (G1O_YELLOW_ROM=<rom>
# dev/setup.sh) and the voxel mod (G1O_VOXEL_MOD, default
# ../DramaticShapeVoxelMod-latest, else
# ../DramaticShapeVoxelMod-master/DramaticShapeVoxelMod-master).
VOXEL_MOD=${G1O_VOXEL_MOD:-$(dirname "$REPO")/DramaticShapeVoxelMod-latest}
[ -f "$VOXEL_MOD/manifest.json" ] || [ -n "${G1O_VOXEL_MOD:-}" ] \
  || VOXEL_MOD=$(dirname "$REPO")/DramaticShapeVoxelMod-master/DramaticShapeVoxelMod-master
YPROFILE=$G1O_WORK/xdg/love/gen1online-yellow
if [ "${1:-}" != "quick" ]; then
  if [ ! -f "$YPROFILE/yellow/rom-cache.complete" ] || [ ! -f "$VOXEL_MOD/manifest.json" ]; then
    echo "== real Yellow + voxel: skipped (needs the Yellow cache and the voxel mod)"
  else
    GTS_GENERATION=1 "$DEV/server.sh" >/dev/null
    rm -rf "$YPROFILE/mods" "$YPROFILE/mod_compat" "$YPROFILE/saves" "$YPROFILE"/save_yellow.lua*
    VOXEL_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$VOXEL_MOD/manifest.json")
    mkdir -p "$YPROFILE/mods/gen1online-plus" "$YPROFILE/mods/$VOXEL_ID"
    (cd "$REPO" && tar --exclude=.git --exclude='*.modpkg' --exclude=dev --exclude=server -cf - .) \
      | (cd "$YPROFILE/mods/gen1online-plus" && tar -xf -)
    printf 'server_url=http://127.0.0.1:%s\n' "$GTS_PORT" > "$YPROFILE/mods/gen1online-plus/gts_config.txt"
    (cd "$VOXEL_MOD" && tar --exclude=.git -cf - .) | (cd "$YPROFILE/mods/$VOXEL_ID" && tar -xf -)
    rm -rf "$G1O_WORK/shots/gen1_voxel"
    XDG_DATA_HOME=$G1O_WORK/xdg POKEPORT_IDENTITY=gen1online-yellow POKEPORT_VERSION=yellow \
      POKEPORT_BACKGROUND=1 POKEPORT_DRIVER=$DEV/drivers/gen1_voxel.lua SHOTS=$G1O_WORK/shots/gen1_voxel \
      timeout 900 "$LOVE" . > "$G1O_WORK/gen1_voxel.log" 2>&1
    step "real Yellow + voxel" "$(result "$G1O_WORK/gen1_voxel.log" | sed 's/.*\t//')"
  fi
fi
# Real Yellow on a server with every game mode on (hardcore Nuzlocke, the
# randomizer, shared key items): the randomized world, the team's items, the
# Nuzlocke rules and a run ending.  Needs the Yellow cache.
if [ "${1:-}" != "quick" ]; then
  if [ ! -f "$YPROFILE/yellow/rom-cache.complete" ]; then
    echo "== real Yellow game modes: skipped (needs the Yellow cache)"
  else
    # nuzlocke_trades: gen1_modes.lua checks the allowance around Brock;
    # gen1_nuzlocke.lua makes no trades, so the limit never gets in its way
    printf 'nuzlocke = hardcore\nnuzlocke_trades = 1\nrandomizer = on\nseed = 4242\n' > "$G1O_WORK/server/modes_config.txt"
    GTS_CONFIG="$G1O_WORK/server/modes_config.txt" GTS_GENERATION=1 "$DEV/server.sh" >/dev/null
    rm -rf "$YPROFILE/mods" "$YPROFILE/mod_compat" "$YPROFILE/saves" "$YPROFILE"/save_yellow.lua*
    mkdir -p "$YPROFILE/mods/gen1online-plus"
    (cd "$REPO" && tar --exclude=.git --exclude='*.modpkg' --exclude=dev --exclude=server -cf - .) \
      | (cd "$YPROFILE/mods/gen1online-plus" && tar -xf -)
    printf 'server_url=http://127.0.0.1:%s\n' "$GTS_PORT" > "$YPROFILE/mods/gen1online-plus/gts_config.txt"
    rm -rf "$G1O_WORK/shots/gen1_modes"
    XDG_DATA_HOME=$G1O_WORK/xdg POKEPORT_IDENTITY=gen1online-yellow POKEPORT_VERSION=yellow \
      POKEPORT_BACKGROUND=1 POKEPORT_DRIVER=$DEV/drivers/gen1_modes.lua SHOTS=$G1O_WORK/shots/gen1_modes \
      timeout 600 "$LOVE" . > "$G1O_WORK/gen1_modes.log" 2>&1
    step "real Yellow game modes" "$(result "$G1O_WORK/gen1_modes.log" | sed 's/.*\t//')"
    # the same modes in real battles (fresh server, fresh profile)
    GTS_CONFIG="$G1O_WORK/server/modes_config.txt" GTS_GENERATION=1 "$DEV/server.sh" >/dev/null
    rm -rf "$YPROFILE/mod_compat" "$YPROFILE/saves" "$YPROFILE"/save_yellow.lua*
    XDG_DATA_HOME=$G1O_WORK/xdg POKEPORT_IDENTITY=gen1online-yellow POKEPORT_VERSION=yellow \
      POKEPORT_BACKGROUND=1 POKEPORT_DRIVER=$DEV/drivers/gen1_nuzlocke.lua SHOTS=$G1O_WORK/shots/gen1_nuzlocke \
      timeout 900 "$LOVE" . > "$G1O_WORK/gen1_nuzlocke.log" 2>&1
    step "real Yellow Nuzlocke battles" "$(result "$G1O_WORK/gen1_nuzlocke.log" | sed 's/.*\t//')"
    # the multiworld split: two worlds, a third player turned away
    printf 'randomizer = on\nmultiworld = on\nplayers = 2\nseed = 4242\n' > "$G1O_WORK/server/multiworld_config.txt"
    GTS_CONFIG="$G1O_WORK/server/multiworld_config.txt" GTS_GENERATION=1 "$DEV/server.sh" >/dev/null
    rm -rf "$YPROFILE/mod_compat" "$YPROFILE/saves" "$YPROFILE"/save_yellow.lua*
    XDG_DATA_HOME=$G1O_WORK/xdg POKEPORT_IDENTITY=gen1online-yellow POKEPORT_VERSION=yellow \
      POKEPORT_BACKGROUND=1 POKEPORT_DRIVER=$DEV/drivers/gen1_multiworld.lua SHOTS=$G1O_WORK/shots/gen1_multiworld \
      timeout 600 "$LOVE" . > "$G1O_WORK/gen1_multiworld.log" 2>&1
    step "real Yellow multiworld" "$(result "$G1O_WORK/gen1_multiworld.log" | sed 's/.*\t//')"
  fi
fi
# Real FireRed and LeafGreen on a Gen 3 server: the online flow (a new
# character, a remote player drawn on the field, GTS with the trade scene and
# a trade evolution, Wonder Trade, chat, DISCONNECT and back), then two games
# at once for a PVP battle and a link trade.  Needs the FRLG caches
# (G1O_FIRERED_ROM / G1O_LEAFGREEN_ROM to dev/setup.sh).
FPROFILE=$G1O_WORK/xdg/love/gen1online-frlg
FPROFILE2=$G1O_WORK/xdg/love/gen1online-frlg2
install_frlg() {   # install_frlg <profile dir>
  rm -rf "$1/mods" "$1/mod_compat" "$1/save" "$1/saves"
  mkdir -p "$1/mods/gen1online-plus"
  (cd "$REPO" && tar --exclude=.git --exclude='*.modpkg' --exclude=dev --exclude=server -cf - .) \
    | (cd "$1/mods/gen1online-plus" && tar -xf -)
  printf 'server_url=http://127.0.0.1:%s\n' "$GTS_PORT" > "$1/mods/gen1online-plus/gts_config.txt"
}
frlg() {   # frlg <game> <identity> <driver> <name> [env...]
  game=$1 identity=$2 driver=$3 name=$4
  shift 4
  rm -rf "$G1O_WORK/shots/$name"
  env "$@" XDG_DATA_HOME=$G1O_WORK/xdg POKEPORT_IDENTITY=$identity POKEPORT_VERSION=$game \
    POKEPORT_BACKGROUND=1 POKEPORT_DRIVER=$DEV/drivers/$driver SHOTS=$G1O_WORK/shots/$name \
    timeout 900 "$LOVE" . > "$G1O_WORK/$name.log" 2>&1
}
if [ "${1:-}" != "quick" ]; then
  for g in firered leafgreen; do
    if [ ! -f "$FPROFILE/$g/rom-cache.complete" ]; then
      echo "== real $g: skipped (needs its cache: G1O_$(echo $g | tr a-z A-Z)_ROM=<rom.gba> dev/setup.sh)"
      continue
    fi
    GTS_GENERATION=3 "$DEV/server.sh" >/dev/null
    install_frlg "$FPROFILE"
    frlg $g gen1online-frlg gen3_online.lua gen3_online_$g
    step "real $g online" "$(result "$G1O_WORK/gen3_online_$g.log" | sed 's/.*\t//')"
    if [ -f "$FPROFILE2/$g/rom-cache.complete" ]; then
      GTS_GENERATION=3 "$DEV/server.sh" >/dev/null
      install_frlg "$FPROFILE"
      install_frlg "$FPROFILE2"
      frlg $g gen1online-frlg gen3_link.lua gen3_link_${g}_host G1O_ROLE=host &
      sleep 3
      frlg $g gen1online-frlg2 gen3_link.lua gen3_link_${g}_guest G1O_ROLE=guest
      wait
      step "real $g PVP + link trade (host)" "$(result "$G1O_WORK/gen3_link_${g}_host.log" | sed 's/.*\t//')"
      step "real $g PVP + link trade (guest)" "$(result "$G1O_WORK/gen3_link_${g}_guest.log" | sed 's/.*\t//')"
    fi
    # the game modes on a Gen 3 server (hardcore, the randomizer with the
    # badges, shared key items): the map walk and seeds, the shuffled world,
    # the team's finds, Brock's slot, the Nuzlocke rules and a run ending
    mkdir -p "$G1O_WORK/server"
    # nuzlocke_trades: gen3_modes.lua checks the allowance after BROCK;
    # gen3_nuzlocke.lua and gen3_friend.lua make no trades
    printf 'nuzlocke = hardcore\nnuzlocke_trades = 1\nrandomizer = on\nseed = 4242\n' > "$G1O_WORK/server/modes_config.txt"
    GTS_CONFIG="$G1O_WORK/server/modes_config.txt" GTS_GENERATION=3 "$DEV/server.sh" >/dev/null
    install_frlg "$FPROFILE"
    frlg $g gen1online-frlg gen3_modes.lua gen3_modes_$g
    step "real $g game modes" "$(result "$G1O_WORK/gen3_modes_$g.log" | sed 's/.*\t//')"
    if [ "$g" = firered ]; then
      # the same modes in real battles (fresh server, fresh profile)
      GTS_CONFIG="$G1O_WORK/server/modes_config.txt" GTS_GENERATION=3 "$DEV/server.sh" >/dev/null
      install_frlg "$FPROFILE"
      frlg $g gen1online-frlg gen3_nuzlocke.lua gen3_nuzlocke_$g
      step "real $g Nuzlocke battles" "$(result "$G1O_WORK/gen3_nuzlocke_$g.log" | sed 's/.*\t//')"
      # the multiworld split: two worlds, a third player turned away
      printf 'randomizer = on\nmultiworld = on\nplayers = 2\nseed = 4242\n' > "$G1O_WORK/server/multiworld_config.txt"
      GTS_CONFIG="$G1O_WORK/server/multiworld_config.txt" GTS_GENERATION=3 "$DEV/server.sh" >/dev/null
      install_frlg "$FPROFILE"
      frlg $g gen1online-frlg gen3_multiworld.lua gen3_multiworld_$g
      step "real $g multiworld" "$(result "$G1O_WORK/gen3_multiworld_$g.log" | sed 's/.*\t//')"
      # parties, profiles and settings, the server address typed in (the
      # config file points at a dead port) and a recovery token on a new device
      GTS_GENERATION=3 "$DEV/server.sh" >/dev/null
      install_frlg "$FPROFILE"
      printf 'server_url=http://127.0.0.1:1\n' > "$FPROFILE/mods/gen1online-plus/gts_config.txt"
      frlg $g gen1online-frlg gen3_social.lua gen3_social_$g
      step "real $g parties, profile, address, token" "$(result "$G1O_WORK/gen3_social_$g.log" | sed 's/.*\t//')"
      # you and a friend: two games on one hardcore server, each with their
      # own first encounter per area
      if [ -f "$FPROFILE2/$g/rom-cache.complete" ]; then
        GTS_CONFIG="$G1O_WORK/server/modes_config.txt" GTS_GENERATION=3 "$DEV/server.sh" >/dev/null
        install_frlg "$FPROFILE"
        install_frlg "$FPROFILE2"
        frlg $g gen1online-frlg gen3_friend.lua gen3_friend_host G1O_ROLE=host &
        sleep 3
        frlg $g gen1online-frlg2 gen3_friend.lua gen3_friend_guest G1O_ROLE=guest
        wait
        step "real $g Nuzlocke with a friend (you)" "$(result "$G1O_WORK/gen3_friend_host.log" | sed 's/.*\t//')"
        step "real $g Nuzlocke with a friend (friend)" "$(result "$G1O_WORK/gen3_friend_guest.log" | sed 's/.*\t//')"
      fi
      # the optional modes from the server's own file: wild legendaries (at
      # 100%) and every trainer's team randomized
      printf 'randomizer = on\nwild_legendaries = 100\nrandomize_trainers = on\nseed = 4242\n' \
        > "$G1O_WORK/server/options_config.txt"
      GTS_CONFIG="$G1O_WORK/server/options_config.txt" GTS_GENERATION=3 "$DEV/server.sh" >/dev/null
      install_frlg "$FPROFILE"
      frlg $g gen1online-frlg gen3_options.lua gen3_options_$g
      step "real $g optional modes from the server's file" "$(result "$G1O_WORK/gen3_options_$g.log" | sed 's/.*\t//')"
    fi
  done
  # FireRed and LeafGreen hold the same item places, so their players can
  # share one multiworld run (the server compares these fingerprints)
  fr=$(grep -o "item places fingerprint [0-9]*" "$G1O_WORK/gen3_modes_firered.log" 2>/dev/null | tail -1)
  lg=$(grep -o "item places fingerprint [0-9]*" "$G1O_WORK/gen3_modes_leafgreen.log" 2>/dev/null | tail -1)
  if [ -n "$fr" ] && [ -n "$lg" ]; then
    if [ "$fr" = "$lg" ]; then step "FireRed and LeafGreen share item places" "ALL PASS"
    else step "FireRed and LeafGreen share item places" "FAILED ($fr / $lg)"; fi
  fi
fi
"$DEV/server.sh" stop
echo "logs: $G1O_WORK/*.log"
exit $status
