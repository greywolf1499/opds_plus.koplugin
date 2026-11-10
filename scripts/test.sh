#!/usr/bin/env bash
# Runs the test suite with the project-local toolchain (see scripts/setup_test_env.sh).
#
#   scripts/test.sh               unit + integration specs (what CI runs)
#   scripts/test.sh --contract    opt-in contract specs against a real KOReader install
#                                 (KOREADER_DIR, default /usr/lib/koreader)
#   scripts/test.sh --all         luacheck, then the default specs, then the contract specs
#
# Anything else is passed to busted, e.g.:
#   scripts/test.sh spec/unit/url_utils_spec.lua
#   scripts/test.sh --filter="buildSearchUrl"
#
# PLUGIN_ROOT=<dir> tests another copy of the plugin, such as an extracted release zip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mode=default
case "${1:-}" in
    --contract) mode=contract; shift ;;
    --all) mode=all; shift ;;
esac

if [[ ! -x .lua_env/bin/busted ]]; then
    echo "Test environment missing. Run scripts/setup_test_env.sh first." >&2
    exit 2
fi

# luacheck runs before the Lua environment is activated, so it keeps its own interpreter and paths.
if [[ "$mode" == all ]]; then
    command -v luacheck >/dev/null 2>&1 || {
        echo "error: luacheck not found on PATH" >&2
        exit 1
    }
    luacheck . --config .luacheckrc
fi

export PATH="$ROOT/.lua_env/bin:$PATH"
eval "$(luarocks path --no-bin)"

status=0
if [[ "$mode" != contract ]]; then
    busted "$@" || status=$?
fi
if [[ "$mode" != default ]]; then
    export KOREADER_DIR="${KOREADER_DIR:-/usr/lib/koreader}"
    busted --run=contract || status=$?
fi
exit "$status"
