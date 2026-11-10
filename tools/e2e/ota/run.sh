#!/usr/bin/env bash
# End-to-end check of the self-updater in a real, headless KOReader.
#
#   tools/e2e/ota/run.sh            needs xvfb-run, python3 and KOReader in $KOREADER_DIR (/usr/lib/koreader)
#   OTA_E2E_KEEP=1 tools/e2e/ota/run.sh   keeps the work dir for a look afterwards
#
# Builds the release archive, installs it as a plain copy into a throwaway KO_HOME under
# /tmp/opds_plus_test_e2e.*, and serves the same archive with the next minor version from a loopback mock of
# GitHub. KOReader then starts three times: update (plus the up-to-date, toast, read-only, development
# install and bad digest checks), rollback, and a last start on the rolled-back version.
# The repository is never linked into KO_HOME, so nothing the updater moves or deletes can reach it.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
KOREADER_DIR=${KOREADER_DIR:-/usr/lib/koreader}
for tool in xvfb-run python3 curl; do
	command -v "$tool" > /dev/null || { echo "missing $tool" >&2; exit 2; }
done
[[ -x "$KOREADER_DIR/reader.lua" ]] || { echo "no KOReader at $KOREADER_DIR" >&2; exit 2; }

WORK=$(mktemp -d /tmp/opds_plus_test_e2e.XXXXXXXX)
work_is_ours() {
	[[ "$WORK" =~ ^/tmp/opds_plus_test_e2e\.[A-Za-z0-9]{8}$ && -d "$WORK" && ! -L "$WORK" ]]
}
work_is_ours || { echo "unexpected work dir $WORK" >&2; exit 2; }

SERVER=
cleanup() {
	if [[ -n "$SERVER" ]]; then
		kill "$SERVER" 2> /dev/null || true
	fi
	if [[ "${OTA_E2E_KEEP:-0}" == 1 ]]; then
		echo "work dir kept: $WORK"
	elif work_is_ours; then
		chmod -R u+w -- "$WORK"
		rm -rf --one-file-system -- "$WORK"
	fi
}
trap cleanup EXIT

python3 "$ROOT/scripts/build_release.py" > "$WORK/build.log"
read -r OLD NEW < <(python3 "$HERE/assets.py" "$ROOT/dist/opds_plus.koplugin.zip" "$WORK")
echo "installed $OLD, offering $NEW"

KO_HOME="$WORK/kohome"
mkdir -p "$KO_HOME/patches" "$KO_HOME/settings" "$WORK/home"
cp "$HERE/driver.lua" "$KO_HOME/patches/2-ota-e2e.lua"
cat > "$KO_HOME/settings.reader.lua" << 'EOF'
return {
    ["quickstart_shown_version"] = 2099000000,
    ["start_with"] = "filemanager",
}
EOF

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$HERE/mock_github.py" --port "$PORT" --asset "$WORK/release.zip" --old-version "$OLD" \
	--new-version "$NEW" --log "$WORK/requests.jsonl" > "$WORK/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 50); do
	curl -s -o /dev/null "http://127.0.0.1:$PORT/__mode?m=same" && break
	sleep 0.1
done

status=0
for phase in update rollback rolled_back; do
	echo "== $phase"
	(
		cd "$KOREADER_DIR"
		export KO_HOME HOME="$WORK/home" LC_ALL=C.UTF-8 \
			OTA_E2E_PHASE="$phase" OTA_E2E_BASE="http://127.0.0.1:$PORT" OTA_E2E_OUT="$WORK/$phase.out" \
			OTA_E2E_WORK="$WORK" OTA_E2E_OLD_VERSION="$OLD" OTA_E2E_NEW_VERSION="$NEW"
		timeout "${OTA_E2E_TIMEOUT:-180}" xvfb-run -a ./reader.lua > "$WORK/$phase.log" 2>&1
	) || true
	if [[ -f "$WORK/$phase.out" ]]; then
		cat "$WORK/$phase.out"
	else
		echo "FAIL $phase: no driver output (see $phase.log)"
	fi
	if ! grep -qx DONE "$WORK/$phase.out" 2> /dev/null; then
		status=1
		tail -n 30 "$WORK/$phase.log" || true
		break
	fi
done
curl -s -o /dev/null "http://127.0.0.1:$PORT/__quit" || true
exit $status
