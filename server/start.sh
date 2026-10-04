#!/bin/sh
# Start the Gen1Online+ server (Linux / macOS).  Options pass through:
#   server/start.sh                 0.0.0.0:7779, data in server/gts_data.json
#   server/start.sh --port 8000
HERE=$(cd "$(dirname "$0")" && pwd)
if command -v python3 >/dev/null 2>&1; then
  exec python3 "$HERE/gts_server.py" "$@"
fi
echo "Python 3 is not installed: get it from your package manager or https://www.python.org/downloads/" >&2
exit 1
