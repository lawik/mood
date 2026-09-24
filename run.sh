#!/usr/bin/env bash
# Runs a scene from web/ in the foreground, with live reload. Ctrl-C quits.
#
#   ./run.sh                 # the default scene
#   ./run.sh embers          # a named scene from web/
#   ./run.sh leaves --tint   # scene plus any Overlay flags
#   ./run.sh --capture-keys  # key tap on (launched via LaunchServices, see below)
#   ./run.sh --check-permission
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Overlay.app"
BIN="$APP/Contents/MacOS/Overlay"
SCENE="leaves"

if [[ $# -gt 0 && "$1" != -* ]]; then
  SCENE="$1"
  shift
fi

if [[ ! -f "$ROOT/web/$SCENE/index.html" ]]; then
  echo "run.sh: no scene '$SCENE'. Available:" >&2
  for d in "$ROOT"/web/*/; do [[ -f "$d/index.html" ]] && echo "  $(basename "$d")" >&2; done
  exit 1
fi

[[ -x "$BIN" ]] || "$ROOT/build.sh"

# Anything involving the key tap must go through LaunchServices. macOS
# attributes Accessibility to the responsible process, and a binary exec'd
# straight from a terminal is attributed to the terminal — so an Overlay.app
# entry in System Settings would never apply, and the tap would silently do
# nothing. `open` makes the app responsible for itself.
via_launchservices=false
check_only=false
for arg in "$@"; do
  case "$arg" in
    --capture-keys) via_launchservices=true ;;
    --check-permission) via_launchservices=true; check_only=true ;;
  esac
done

if ! $via_launchservices; then
  exec "$BIN" --file "$ROOT/web/$SCENE/index.html" --watch "$@"
fi

LOG="/tmp/overlay-$USER.log"
: > "$LOG"

if $check_only; then
  open -n -W --stdout "$LOG" --stderr "$LOG" -a "$APP" --args --check-permission || true
  cat "$LOG"
  exit 0
fi

cleanup() {
  [[ -n "${TAIL_PID:-}" ]] && kill "$TAIL_PID" 2>/dev/null || true
  pkill -f "Overlay.app/Contents/MacOS/Overlay" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

tail -f "$LOG" &
TAIL_PID=$!

open -n -W --stdout "$LOG" --stderr "$LOG" \
  -a "$APP" --args --file "$ROOT/web/$SCENE/index.html" --watch "$@"
