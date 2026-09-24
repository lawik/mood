#!/usr/bin/env bash
# Runs the overlay in the foreground. Ctrl-C quits.
#
#   ./run.sh                 # scener's LiveView overlay (the default)
#   ./run.sh embers          # a local scene from web/, with live reload
#   ./run.sh --tint          # default overlay plus any Overlay flags
#   ./run.sh --capture-keys  # key tap on (launched via LaunchServices, see below)
#   ./run.sh --check-permission
#
# The leaves live in scener now, as a LiveView, so scene state and the set
# dressing come from one place. OVERLAY_URL overrides where that is.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Overlay.app"
BIN="$APP/Contents/MacOS/Overlay"
OVERLAY_URL="${OVERLAY_URL:-http://localhost:4000/overlay}"

SCENE=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  SCENE="$1"
  shift
fi

if [[ -n "$SCENE" ]]; then
  if [[ ! -f "$ROOT/web/$SCENE/index.html" ]]; then
    echo "run.sh: no local scene '$SCENE'. Available:" >&2
    for d in "$ROOT"/web/*/; do [[ -f "$d/index.html" ]] && echo "  $(basename "$d")" >&2; done
    echo "  (with no argument, the overlay comes from $OVERLAY_URL)" >&2
    exit 1
  fi
  SOURCE=(--file "$ROOT/web/$SCENE/index.html" --watch)
else
  SOURCE=(--url "$OVERLAY_URL")
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
  exec "$BIN" "${SOURCE[@]}" "$@"
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

open -n -W --stdout "$LOG" --stderr "$LOG" -a "$APP" --args "${SOURCE[@]}" "$@"
