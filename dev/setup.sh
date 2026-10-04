#!/bin/sh
# One-time (or after /tmp is wiped) setup for the Gen1Online test harness.
#
#   dev/setup.sh [path/to/crystal-rom.gbc-or-.zip]
#
# Builds $G1O_WORK (default /tmp/gen1online-dev):
#   root/, bin/luajit, bin/love  LuaJIT, LOVE 11.5 and luasocket for LuaJIT,
#                                extracted from Fedora packages (no sudo).
#                                Without dnf (Ubuntu, cloud sandboxes) it uses
#                                the system's luajit + lua-socket instead,
#                                installing them with apt-get when missing;
#                                LOVE is then optional (only the real-game
#                                drivers need it, and they need the ROM too).
#   xdg/love/gen1online-test/    a throwaway LOVE profile with the Crystal
#                                cache imported (only when a ROM is given)
#   server/gts_test_server.py    the legacy v0.3.5.59 server from this repo's
#                                git history, patched to speak to 0.5.x
#                                (a stand-in until server/ is rewritten)
# Also clones gen1recomp next to this repo when it isn't there, at the
# commit the suite was last verified against ($G1O_RECOMP_REF).
set -eu
DEV=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$DEV")
WORK=${G1O_WORK:-/tmp/gen1online-dev}
RECOMP=${G1O_RECOMP:-$(dirname "$REPO")/gen1recomp}
RECOMP_REF=${G1O_RECOMP_REF:-340e2567ec93d8ac74659d7091ebbec8925d7295}
mkdir -p "$WORK/rpms" "$WORK/root" "$WORK/bin" "$WORK/server"

# --- engine -------------------------------------------------------------------
if [ ! -f "$RECOMP/main.lua" ]; then
  git init -q "$RECOMP"
  git -C "$RECOMP" fetch -q --depth 1 https://github.com/bryanthaboi/gen1recomp.git "$RECOMP_REF"
  git -C "$RECOMP" checkout -q FETCH_HEAD
fi
echo "gen1recomp: $RECOMP ($(git -C "$RECOMP" rev-parse --short HEAD 2>/dev/null || echo unknown))"

# --- toolchain --------------------------------------------------------------
if [ ! -x "$WORK/bin/luajit" ]; then
  if command -v dnf >/dev/null 2>&1; then
    cd "$WORK/rpms"
    dnf download --arch x86_64 luajit love liblove lua5.1-socket lua5.1-sec
    for r in *.x86_64.rpm; do rpm2cpio "$r" | (cd "$WORK/root" && cpio -idm 2>/dev/null); done
    for tool in luajit love; do
      cat > "$WORK/bin/$tool" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH=$WORK/root/usr/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
exec $WORK/root/usr/bin/$tool "\$@"
EOF
      chmod +x "$WORK/bin/$tool"
    done
  else
    if ! command -v luajit >/dev/null 2>&1 \
       || ! luajit -e 'require("socket.http")' >/dev/null 2>&1; then
      SUDO=; [ "$(id -u)" = 0 ] || SUDO=sudo
      $SUDO apt-get update -qq
      $SUDO apt-get install -y -qq luajit lua-socket curl iproute2 >/dev/null
    fi
    ln -sf "$(command -v luajit)" "$WORK/bin/luajit"
    if command -v love >/dev/null 2>&1; then ln -sf "$(command -v love)" "$WORK/bin/love"; fi
  fi
fi
"$WORK/bin/luajit" -v
"$WORK/bin/luajit" -e 'require("socket.http")' && echo "luasocket: ok"
[ -x "$WORK/bin/love" ] && "$WORK/bin/love" --version || echo "LOVE: not installed (real-game drivers unavailable)"

# --- stand-in server ------------------------------------------------------------
if [ -f "$REPO/server/gts_server.py" ]; then
  echo "server/gts_server.py exists: dev/server.sh will run it"
elif git -C "$REPO" show 97e502f:gts_server.py > "$WORK/server/gts_server_legacy.py" 2>/dev/null; then
  python3 "$DEV/make_test_server.py" "$WORK/server/gts_server_legacy.py" "$WORK/server/gts_test_server.py"
else
  echo "legacy server not in git history (shallow clone?): no stand-in server"
fi

# --- test profile with the Crystal cache ------------------------------------------
PROFILE="$WORK/xdg/love/gen1online-test"
if [ $# -ge 1 ] && [ ! -f "$PROFILE/crystal/rom-cache.complete" ] && [ -x "$WORK/bin/love" ]; then
  ROM=$1
  case "$ROM" in
    *.zip) mkdir -p "$WORK/rom"; unzip -o -q "$ROM" -d "$WORK/rom"
           ROM=$(ls "$WORK/rom"/*.gbc | head -1) ;;
  esac
  (cd "$RECOMP" && XDG_DATA_HOME="$WORK/xdg" POKEPORT_IDENTITY=gen1online-test \
    POKEPORT_VERSION=crystal POKEPORT_IMPORT_ONLY=1 POKEPORT_IMPORT_ROM="$ROM" \
    "$WORK/bin/love" .)
  # the engine's bundled follower mod would muddy the follower tests
  python3 - "$PROFILE/options.lua" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
if "mystery_dungeon_follower = false" not in s:
    s = s.replace("  mods = {},\n", "  mods = { mystery_dungeon_follower = false },\n", 1)
open(p, "w").write(s)
EOF
fi
[ -f "$PROFILE/crystal/rom-cache.complete" ] && echo "Crystal cache: ready" \
  || echo "Crystal cache: missing (pass the ROM to run the real-game drivers)"
