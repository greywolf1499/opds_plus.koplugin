#!/usr/bin/env bash
# LuaLS checks first-party Lua without executing it. Outputs stay in .tools/luals.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
SERVER=${LUA_LANGUAGE_SERVER:-lua-language-server}
KOREADER=${KOREADER_DIR:-/usr/lib/koreader}
LEVEL=Warning
if [[ $# -eq 1 && $1 == --hints ]]; then
    LEVEL=Hint
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--hints]" >&2
    exit 2
fi

if ! command -v "$SERVER" >/dev/null; then
    echo "LuaLS not found. Set LUA_LANGUAGE_SERVER to its executable (LuaLS 3.19.2 or newer)." >&2
    exit 1
fi
if [[ ! -f "$KOREADER/frontend/ui/uimanager.lua" ]]; then
    echo "KOReader not found at $KOREADER. Set KOREADER_DIR to its install directory." >&2
    exit 1
fi
KOREADER=$(cd -- "$KOREADER" && pwd -P)

mkdir -p "$ROOT/.lua_env" "$ROOT/.tools/luals/log" "$ROOT/.tools/luals/meta"
LIBRARY="$ROOT/.lua_env/koreader"
if [[ -e "$LIBRARY" || -L "$LIBRARY" ]]; then
    if [[ ! -d "$LIBRARY" ]] || [[ $(cd -- "$LIBRARY" && pwd -P) != "$KOREADER" ]]; then
        echo "$LIBRARY already exists and does not point to $KOREADER; nothing was replaced." >&2
        exit 1
    fi
else
    ln -s "$KOREADER" "$LIBRARY"
fi

exec "$SERVER" \
    --check="$ROOT" \
    --configpath="$ROOT/.luarc.json" \
    --logpath="$ROOT/.tools/luals/log" \
    --metapath="$ROOT/.tools/luals/meta" \
    --check_format=json \
    --checklevel="$LEVEL" \
    --check_out_path="$ROOT/.tools/luals/diagnostics.json"
