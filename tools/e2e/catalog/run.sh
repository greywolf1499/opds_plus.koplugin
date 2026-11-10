#!/usr/bin/env bash
# End-to-end check of catalog browsing in a real, headless KOReader, against a loopback mock OPDS server.
#
#   tools/e2e/catalog/run.sh                       every scenario but the explicit ones
#   tools/e2e/catalog/run.sh opds2,series          only these scenarios
#   HARNESS_KEEP=1 tools/e2e/catalog/run.sh shots  keeps the work dir (screenshots are in shots/)
#
# Needs xvfb-run, python3, curl and KOReader in $KOREADER_DIR (/usr/lib/koreader). The plugin directory is
# the repository (PLUGIN_DIR overrides it), linked into a throwaway KO_HOME under /tmp/opds_plus_test_harness.*.
# driver.lua runs as a user patch and writes "<scenario>.result=PASS|FAIL" lines; the exit code is 1 when a
# scenario fails or the run does not finish.
# Env: HARNESS_TIMEOUT (seconds, default 600), EMULATE_READER_W/H/DPI (screen, default 1264x1680 at 300 dpi),
# HARNESS_COVERS (directory of showcase covers for the mock server), HARNESS_SHOTS_OUT (existing directory the
# screenshots are copied to; files already there are kept). screenshots.sh uses the last two.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
PLUGIN_DIR=$(realpath "${PLUGIN_DIR:-$ROOT}")
SCENARIOS=${1:-}
KOREADER_DIR=${KOREADER_DIR:-/usr/lib/koreader}
for tool in xvfb-run python3 curl; do
	command -v "$tool" > /dev/null || { echo "missing $tool" >&2; exit 2; }
done
[[ -x "$KOREADER_DIR/reader.lua" ]] || { echo "no KOReader at $KOREADER_DIR" >&2; exit 2; }

WORK=$(mktemp -d /tmp/opds_plus_test_harness.XXXXXX)
work_is_ours() {
	[[ "$WORK" =~ ^/tmp/opds_plus_test_harness\.[A-Za-z0-9]{6}$ && -d "$WORK" && ! -L "$WORK" ]]
}
work_is_ours || { echo "unexpected work dir $WORK" >&2; exit 2; }

SERVER=
cleanup() {
	if [[ -n "$SERVER" ]]; then
		kill "$SERVER" 2> /dev/null || true
	fi
	if [[ "${HARNESS_KEEP:-0}" == 1 ]]; then
		echo "work dir kept: $WORK"
	elif work_is_ours; then
		chmod -R u+w -- "$WORK"
		rm -rf --one-file-system -- "$WORK"
	fi
}
trap cleanup EXIT

KO_HOME="$WORK/kohome"
mkdir -p "$KO_HOME/plugins" "$KO_HOME/patches" "$KO_HOME/settings" "$WORK/home" "$WORK/shots" "$WORK/tmp"
ln -s "$PLUGIN_DIR" "$KO_HOME/plugins/opds_plus.koplugin"
cp "$HERE/driver.lua" "$KO_HOME/patches/2-harness.lua"
cp "$HERE/reader_seed.lua" "$KO_HOME/settings.reader.lua"

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
BASE="http://127.0.0.1:$PORT"
sed "s#__BASE__#$BASE#g" "$HERE/opdsplus_seed.lua" > "$KO_HOME/settings/opdsplus.lua"
COVERS_ARGS=()
[[ -n "${HARNESS_COVERS:-}" ]] && COVERS_ARGS=(--covers "$HARNESS_COVERS")
python3 "$HERE/mock_opds_server.py" --port "$PORT" --log "$WORK/requests.jsonl" "${COVERS_ARGS[@]}" \
	> "$WORK/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 50); do
	curl -s -o /dev/null "$BASE/__stats" && break
	sleep 0.1
done

(
	cd "$KOREADER_DIR"
	export KO_HOME HOME="$WORK/home" LC_ALL=en_US.UTF-8 TMPDIR="$WORK/tmp" HARNESS_TMP="$WORK/tmp" \
		HARNESS_OUT="$WORK/out.txt" HARNESS_SHOTS="$WORK/shots" HARNESS_SCENARIOS="$SCENARIOS" HARNESS_BASE="$BASE" \
		EMULATE_READER_W="${EMULATE_READER_W:-1264}" EMULATE_READER_H="${EMULATE_READER_H:-1680}" \
		EMULATE_READER_DPI="${EMULATE_READER_DPI:-300}"
	timeout "${HARNESS_TIMEOUT:-600}" xvfb-run -a -s "-screen 0 1400x1800x24" ./reader.lua > "$WORK/ko.log" 2>&1
) || true

cat "$WORK/out.txt" 2> /dev/null || echo "(no driver output, see ko.log)"
if [[ -n "${HARNESS_SHOTS_OUT:-}" ]] && compgen -G "$WORK/shots/*.png" > /dev/null; then
	cp -n -- "$WORK"/shots/*.png "$HARNESS_SHOTS_OUT"/
fi
echo "== requests: $(wc -l < "$WORK/requests.jsonl" 2> /dev/null || echo 0)"
python3 "$HERE/summarize_requests.py" "$WORK/requests.jsonl" || true
echo "== KOReader errors"
grep -E 'traceback|ERROR' "$WORK/ko.log" | head -n 20 || true

if ! grep -qx 'done=1' "$WORK/out.txt" 2> /dev/null; then
	echo "FAIL: the run did not finish"
	exit 1
fi
if grep -qE '\.(result=FAIL|error=)' "$WORK/out.txt"; then
	echo "FAIL: $(grep -cE '\.result=FAIL' "$WORK/out.txt") scenario(s) failed"
	exit 1
fi
echo "PASS: $(grep -c '\.result=PASS' "$WORK/out.txt") scenario(s)"
