#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFO_JSON="$SCRIPT_DIR/modfiles/info.json"

if [ ! -f "$INFO_JSON" ]; then
    echo "Error: info.json not found at $INFO_JSON"
    exit 1
fi

MOD_NAME=$(python3 -c "import json; print(json.load(open('$INFO_JSON'))['name'])")
MOD_VERSION=$(python3 -c "import json; print(json.load(open('$INFO_JSON'))['version'])")
MOD_FOLDER="${MOD_NAME}_${MOD_VERSION}"

MODS_DIR="$HOME/Library/Application Support/factorio/mods"

if [ ! -d "$MODS_DIR" ]; then
    echo "Error: Factorio mods directory not found at $MODS_DIR"
    echo "Is Factorio installed?"
    exit 1
fi

TARGET="$MODS_DIR/$MOD_FOLDER"

if [ -d "$TARGET" ]; then
    echo "Removing existing $MOD_FOLDER ..."
    rm -rf "$TARGET"
fi

echo "Deploying $MOD_FOLDER to $MODS_DIR ..."
cp -R "$SCRIPT_DIR/modfiles" "$TARGET"

echo "Done. Enable '$MOD_NAME' in Factorio's mod manager."
