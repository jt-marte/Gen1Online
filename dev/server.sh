#!/bin/sh
# (Re)start the local GTS server (server/gts_server.py) for tests, with a
# fresh database.
#   dev/server.sh          start (kills the previous one)
#   dev/server.sh stop     stop
# Port: $GTS_PORT (default 17781).  PID in $G1O_WORK/server/server.pid.
DEV=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$DEV")
WORK=${G1O_WORK:-/tmp/gen1online-dev}
D=$WORK/server
mkdir -p "$D"
PORT=${GTS_PORT:-17781}
[ -f "$D/server.pid" ] && kill "$(cat "$D/server.pid")" 2>/dev/null
rm -f "$D/server.pid"
# wait for the old server to let go of the port
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ss -ltn 2>/dev/null | grep -q ":$PORT " || break
  sleep 0.3
done
[ "${1:-}" = "stop" ] && exit 0
SERVER=${SERVER:-$REPO/server/gts_server.py}
rm -f "$D/run_db.json"
cd "$D" || exit 1
PORT=$PORT GTS_DB_PATH="$D/run_db.json" \
  nohup python3 "$SERVER" --host 127.0.0.1 > "$D/server.log" 2>&1 &
echo $! > "$D/server.pid"   # python's own PID, so stop/restart really kills it
sleep 1.2
curl -sf -m 3 "http://127.0.0.1:$PORT/server/info" >/dev/null \
  && echo "server up: $SERVER" || { echo "server failed, see $D/server.log"; exit 1; }
