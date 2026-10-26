#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_BIN_DIR="/tmp/pob-dev"

# Ensure dev runtime directory exists with binary and libraries from installed app
mkdir -p "$DEV_BIN_DIR"
if [ ! -f "$DEV_BIN_DIR/Path of Building" ]; then
    cp "/Applications/Path of Building.app/Contents/MacOS/Path of Building" "$DEV_BIN_DIR/"
fi
ln -sf "/Applications/Path of Building.app/Contents/MacOS"/*.dylib "$DEV_BIN_DIR/"
ln -sf "/Applications/Path of Building.app/Contents/Resources/SimpleGraphic" "$DEV_BIN_DIR/SimpleGraphic"
ln -sf "/Applications/Path of Building.app/Contents/Resources/cacert.pem" "$DEV_BIN_DIR/cacert.pem"

# Run Path of Building directly from repository source
"$DEV_BIN_DIR/Path of Building" "$DIR/PathOfBuilding/src/Launch.lua" "$@"
