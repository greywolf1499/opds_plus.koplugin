#!/usr/bin/env bash
# Regenerates the README screenshots: draws the showcase covers, runs the "shots" scenario on a 600x800 screen
# and frames the pictures.
#
#   tools/e2e/catalog/screenshots.sh              writes .github/screenshots/*.png
#   tools/e2e/catalog/screenshots.sh <out dir>    writes them somewhere else
#
# Needs what run.sh needs, plus Python with Pillow: PYTHON (default .tools/venv/bin/python, see
# scripts/setup_test_env.sh; install it there with .tools/venv/bin/pip install pillow).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=${1:-$ROOT/.github/screenshots}
PYTHON=${PYTHON:-$ROOT/.tools/venv/bin/python}
"$PYTHON" -c "import PIL" 2> /dev/null || { echo "$PYTHON has no Pillow (pip install pillow)" >&2; exit 2; }

WORK=$(mktemp -d /tmp/opds_plus_test_shots.XXXXXX)
work_is_ours() {
	[[ "$WORK" =~ ^/tmp/opds_plus_test_shots\.[A-Za-z0-9]{6}$ && -d "$WORK" && ! -L "$WORK" ]]
}
work_is_ours || { echo "unexpected work dir $WORK" >&2; exit 2; }
cleanup() {
	if work_is_ours; then
		rm -rf --one-file-system -- "$WORK"
	fi
}
trap cleanup EXIT

mkdir "$WORK/raw"
(cd "$HERE" && "$PYTHON" make_covers.py "$WORK/covers")
HARNESS_COVERS="$WORK/covers" HARNESS_SHOTS_OUT="$WORK/raw" HARNESS_NO_KEYBOARD=1 \
	EMULATE_READER_W=600 EMULATE_READER_H=800 EMULATE_READER_DPI=160 HARNESS_TIMEOUT="${HARNESS_TIMEOUT:-180}" \
	"$HERE/run.sh" shots
(cd "$HERE" && "$PYTHON" frame.py "$WORK/raw" "$OUT")
