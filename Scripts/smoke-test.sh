#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXECUTABLE="$ROOT_DIR/.build/ProcessTapDSP.app/Contents/MacOS/ProcessTapDSP"
DURATION_SECONDS=${SMOKE_TEST_SECONDS:-6}
MODE="default"
EXPECTED_START="Started Process Tap -> unity passthrough DSP -> default output playback."
EXPECTED_PITCH="Pitch shift: enabled=false"
APP_ARGS=""

if [ "${1:-}" = "--debug-pitch-up" ]; then
    MODE="debug-pitch-up"
    EXPECTED_START="Started Process Tap -> debug pitch-up DSP -> default output playback."
    EXPECTED_PITCH="Pitch shift: enabled=true"
    APP_ARGS="--debug-pitch-up"
fi

LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/processtapdsp-smoke.XXXXXX")
PID=""

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

cd "$ROOT_DIR"
make

echo "Running ProcessTapDSP smoke test: $MODE"
"$EXECUTABLE" $APP_ARGS >"$LOG_FILE" 2>&1 &
PID=$!

sleep "$DURATION_SECONDS"

kill -INT "$PID" 2>/dev/null || true
wait "$PID" || true
PID=""

cat "$LOG_FILE"

grep -F "$EXPECTED_START" "$LOG_FILE" >/dev/null
grep -F "$EXPECTED_PITCH" "$LOG_FILE" >/dev/null
grep -F "Tap source device:" "$LOG_FILE" >/dev/null
grep -F "Playback output device:" "$LOG_FILE" >/dev/null
grep -F "ring fill:" "$LOG_FILE" >/dev/null
grep -F "Shutdown complete. Normal system audio should be restored." "$LOG_FILE" >/dev/null

echo "Smoke test passed: $MODE"
