#!/usr/bin/env bash
# Builds the project-local test toolchain used by scripts/test.sh and CI.
#
#   .tools/venv  Python venv that holds hererocks (nothing is installed globally)
#   .lua_env     LuaJIT (the Lua flavour KOReader runs) + LuaRocks + busted and friends
#
# Usage: scripts/setup_test_env.sh [--force]
#   --force  delete .lua_env and build it again
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PYTHON="${PYTHON:-python3}"
HERERO_VERSION="0.25.1"
# LuaJIT no longer publishes release tarballs, so pin an exact commit of its v2.1 branch.
LUAJIT_COMMIT="c4b1e2f73a2e10fbcc637fcec474f639c38daafe"
LUAROCKS_TAG="v3.13.0"
ROCKS_SERVER="https://luarocks.org"

# "name version", dependencies first so that every rock resolves to exactly these versions.
ROCKS=(
    "luafilesystem 1.9.0-1"
    "penlight 1.15.0-1"
    "say 1.4.1-3"
    "lua_cliargs 3.0.2-1"
    "luasystem 0.7.1-1"
    "lua-term 0.8-1"
    "mediator_lua 1.1.2-0"
    "luassert 1.9.0-1"
    "dkjson 2.11-1"
    "busted 2.3.0-1"
    "luasocket 3.1.0-1"
)

if [[ "${1:-}" == "--force" ]]; then
    rm -rf .lua_env
fi

if [[ -x .lua_env/bin/busted ]]; then
    echo "Test environment already present (use --force to rebuild)."
    exit 0
fi

for tool in "$PYTHON" git make cc curl; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: '$tool' is required to build the test environment" >&2
        exit 1
    }
done

if [[ ! -x .tools/venv/bin/hererocks ]]; then
    "$PYTHON" -m venv .tools/venv
    .tools/venv/bin/pip install --disable-pip-version-check --quiet "hererocks==${HERERO_VERSION}"
fi

rm -rf .lua_env
.tools/venv/bin/hererocks .lua_env -j "@${LUAJIT_COMMIT}" -r "@${LUAROCKS_TAG}"

for rock in "${ROCKS[@]}"; do
    # shellcheck disable=SC2086 # deliberate word splitting: "name version"
    .lua_env/bin/luarocks --only-server="$ROCKS_SERVER" install $rock
done

echo
.lua_env/bin/lua -v
.lua_env/bin/busted --version
echo "Test environment ready. Run scripts/test.sh"
