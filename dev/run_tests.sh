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
    printf 'nuzlocke = hardcore\nrandomizer = on\nseed = 4242\n' > "$G1O_WORK/server/modes_config.txt"
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
  fi
fi
"$DEV/server.sh" stop
echo "logs: $G1O_WORK/*.log"
exit $status
