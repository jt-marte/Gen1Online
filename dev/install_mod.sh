#!/bin/sh
# Copy this repo's working tree into the test profile as an installed mod
# (mods/gen1online-plus), pointing the COPY's gts_config.txt at the local
# test server.  The repo's own gts_config.txt is never touched.
DEV=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$DEV")
WORK=${G1O_WORK:-/tmp/gen1online-dev}
P=$WORK/xdg/love/gen1online-test
DEST=$P/mods/${1:-gen1online-plus}
rm -rf "$P/mods"; mkdir -p "$DEST"
(cd "$REPO" && tar --exclude=.git --exclude='*.modpkg' --exclude=dev --exclude=server -cf - .) | (cd "$DEST" && tar -xf -)
printf 'server_url=http://127.0.0.1:%s\n' "${GTS_PORT:-17781}" > "$DEST/gts_config.txt"
echo "installed to $DEST"
