#!/usr/bin/env bash
# Runs the overlay, ready to perform. Ctrl-C quits.
#
#   ./run.sh                    # the whole thing: scener's overlay + key capture
#   ./run.sh --check-permission # report whether Accessibility is granted
#   ./run.sh --tint             # any Overlay flag still passes through
#
# No flags are needed for a show. The overlay is scener's LiveView
# (OVERLAY_URL to point elsewhere) and the key tap is armed against the scene
# runner on 127.0.0.1:4041.
#
# Arming the tap is safe with nothing listening: keys are only swallowed while
# the runner is connected, so until scener is up the keyboard behaves as
# normal. Escape disables capture, Command-Escape re-enables it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Overlay.app"
OVERLAY_URL="${OVERLAY_URL:-http://localhost:4040/overlay}"
PROMPTER_URL="${PROMPTER_URL:-http://localhost:4040/prompter}"
LOG="/tmp/overlay-$USER.log"

[[ -x "$APP/Contents/MacOS/Overlay" ]] || "$ROOT/build.sh"

# Everything goes through LaunchServices. macOS attributes Accessibility to the
# responsible process, and a binary exec'd straight from a terminal is
# attributed to the terminal — so an Overlay.app entry in System Settings would
# never apply and the key tap would silently do nothing. `open` makes the app
# responsible for itself.
overlay() {
  open -n -W --stdout "$LOG" --stderr "$LOG" -a "$APP" --args "$@"
}

: > "$LOG"

for arg in "$@"; do
  if [[ "$arg" == "--check-permission" ]]; then
    overlay --check-permission || true
    cat "$LOG"
    exit 0
  fi
done

# Check before drawing anything. `open -W` does not report the app's exit
# status, so read the answer rather than the exit code.
overlay --check-permission || true
if ! grep -q "Accessibility: granted" "$LOG"; then
  cat "$LOG" >&2
  echo "run.sh: refusing to start without key capture." >&2
  exit 1
fi

: > "$LOG"

cleanup() {
  [[ -n "${TAIL_PID:-}" ]] && kill "$TAIL_PID" 2>/dev/null || true
  pkill -f "Overlay.app/Contents/MacOS/Overlay" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

tail -f "$LOG" &
TAIL_PID=$!

# With two displays the performer's one gets the prompter and the projected one
# gets the set dressing. With one display there is nowhere private to put the
# prompter, so show the performance and say so rather than silently hiding it.
DISPLAYS="$("$APP/Contents/MacOS/Overlay" --list-screens | grep -c '^\[' || true)"
ROUTING=()
if [[ "${DISPLAYS:-1}" -gt 1 ]]; then
  ROUTING=(--url-on "primary=$PROMPTER_URL")
  echo "run.sh: $DISPLAYS displays — prompter on the primary, performance on the rest"
else
  echo "run.sh: one display — showing the performance; connect a second for the prompter"
fi

overlay --url "$OVERLAY_URL" "${ROUTING[@]}" --capture-keys "$@"
