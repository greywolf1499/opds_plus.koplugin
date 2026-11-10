#!/usr/bin/env bash
# Real-API dry run of the self-updater, before tagging a release.
#
#   tools/e2e/ota/real_dryrun.sh [pretend version, default 0.0.1]
#
# Installs the current build as a plain copy in /tmp/opds_plus_test_dryrun.*, then lets the updater, claiming
# the installed version is older, fetch the latest real release from GitHub, verify its digest and swap it in.
# Needs network access and KOReader in $KOREADER_DIR (/usr/lib/koreader).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
KOREADER_DIR=${KOREADER_DIR:-/usr/lib/koreader}
PRETEND=${1:-0.0.1}

WORK=$(mktemp -d /tmp/opds_plus_test_dryrun.XXXXXXXX)
work_is_ours() {
	[[ "$WORK" =~ ^/tmp/opds_plus_test_dryrun\.[A-Za-z0-9]{8}$ && -d "$WORK" && ! -L "$WORK" ]]
}
work_is_ours || { echo "unexpected work dir $WORK" >&2; exit 2; }
cleanup() {
	if [[ "${OTA_E2E_KEEP:-0}" == 1 ]]; then
		echo "work dir kept: $WORK"
	elif work_is_ours; then
		chmod -R u+w -- "$WORK"
		rm -rf --one-file-system -- "$WORK"
	fi
}
trap cleanup EXIT

python3 "$ROOT/scripts/build_release.py" > /dev/null
mkdir -p "$WORK/plugins" "$WORK/cache"
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
	"$ROOT/dist/opds_plus.koplugin.zip" "$WORK/plugins"

cd "$KOREADER_DIR"
./luajit "$HERE/real_dryrun.lua" "$ROOT" "$WORK" "$PRETEND"
