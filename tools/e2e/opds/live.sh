#!/usr/bin/env bash
# Live smoke run of catalog browsing against real OPDS servers, in a real, headless KOReader.
#
#   tools/e2e/opds/live.sh
#   OPDS_LIVE_KOMGA=user:password tools/e2e/opds/live.sh                      adds the Komga demo
#   OPDS_LIVE_CWA_URL=http://localhost:8083/opds OPDS_LIVE_CWA=user:password tools/e2e/opds/live.sh
#
# Needs xvfb-run, python3, network access and KOReader in $KOREADER_DIR (/usr/lib/koreader). The Komga demo
# login is the one published on komga.org; logins are only ever passed through the environment.
#
# Installs the current build as a plain copy into a throwaway KO_HOME under /tmp/opds_plus_test_live.*, then
# patches/2-opds-live.lua (driver.lua) opens each catalog through the plugin's own modules, follows a few
# folders and runs a search, at most one request per second. Fails if a login shows up in KOReader's log.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
KOREADER_DIR=${KOREADER_DIR:-/usr/lib/koreader}
command -v xvfb-run > /dev/null || { echo "missing xvfb-run" >&2; exit 2; }
command -v python3 > /dev/null || { echo "missing python3" >&2; exit 2; }
[[ -x "$KOREADER_DIR/reader.lua" ]] || { echo "no KOReader at $KOREADER_DIR" >&2; exit 2; }

WORK=$(mktemp -d /tmp/opds_plus_test_live.XXXXXXXX)
work_is_ours() {
	[[ "$WORK" =~ ^/tmp/opds_plus_test_live\.[A-Za-z0-9]{8}$ && -d "$WORK" && ! -L "$WORK" ]]
}
work_is_ours || { echo "unexpected work dir $WORK" >&2; exit 2; }
cleanup() {
	if work_is_ours; then
		chmod -R u+w -- "$WORK"
		rm -rf --one-file-system -- "$WORK"
	fi
}
trap cleanup EXIT

python3 "$ROOT/scripts/build_release.py" > "$WORK/build.log"
KO_HOME="$WORK/kohome"
mkdir -p "$KO_HOME/patches" "$KO_HOME/plugins" "$KO_HOME/settings" "$WORK/home"
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
	"$ROOT/dist/opds_plus.koplugin.zip" "$KO_HOME/plugins"
cp "$HERE/driver.lua" "$KO_HOME/patches/2-opds-live.lua"
cat > "$KO_HOME/settings.reader.lua" << 'EOF'
return {
    ["quickstart_shown_version"] = 2099000000,
    ["start_with"] = "filemanager",
}
EOF

OUT="$WORK/live.out"
(
	cd "$KOREADER_DIR"
	export KO_HOME HOME="$WORK/home" LC_ALL=C.UTF-8 OPDS_LIVE_OUT="$OUT" OPDS_LIVE_WORK="$WORK"
	timeout "${OPDS_LIVE_TIMEOUT:-300}" xvfb-run -a ./reader.lua > "$WORK/reader.log" 2>&1
) || true

status=0
if [[ -f "$OUT" ]]; then
	cat "$OUT"
else
	echo "FAIL no driver output"
fi
grep -qx DONE "$OUT" 2> /dev/null || status=1

leaked=
for login in "${OPDS_LIVE_KOMGA:-}" "${OPDS_LIVE_CWA:-}"; do
	password=${login#*:}
	if [[ -n "$login" && -n "$password" ]] && grep -rqF --exclude-dir=plugins -- "$password" "$WORK"; then
		echo "FAIL a login password was written to the work dir"
		leaked=1
	fi
done
# KOReader's log is only shown once it is known to hold no password
if [[ -n "$leaked" ]]; then
	exit 1
fi
if [[ $status != 0 ]]; then
	tail -n 30 "$WORK/reader.log" || true
fi
errors=$(grep -E 'traceback|ERROR' "$WORK/reader.log" || true)
if [[ -n "$errors" ]]; then
	echo "KOReader logged errors:"
	echo "$errors" | head -n 20
else
	echo "KOReader logged no errors"
fi
exit $status
