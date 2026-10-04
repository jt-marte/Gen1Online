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

cd "$RECOMP" || exit 1
"$LUAJIT" -e "local f=io.open('$REPO/main.lua','rb'); local c,e=loadstring(f:read('*a'),'@main.lua'); print(c and 'main.lua compiles' or e)"

"$LUAJIT" "$DEV/harness/offline_test.lua" > "$G1O_WORK/offline.log" 2>&1
step "synthetic offline" "$(result "$G1O_WORK/offline.log")"
"$DEV/server.sh" >/dev/null
DEV=1 "$LUAJIT" "$DEV/harness/online_test.lua" > "$G1O_WORK/online.log" 2>&1
step "synthetic online" "$(result "$G1O_WORK/online.log")"

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
"$DEV/server.sh" stop
echo "logs: $G1O_WORK/*.log"
exit $status
