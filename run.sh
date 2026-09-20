#!/usr/bin/env bash
# Runs the overlay in the foreground against the working copy in web/, with
# live reload. Ctrl-C quits. Extra arguments are passed through, e.g.
#   ./run.sh --screen all
#   ./run.sh --level menubar
#   ./run.sh --tint
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/build/Overlay.app/Contents/MacOS/Overlay"

[[ -x "$BIN" ]] || "$ROOT/build.sh"

exec "$BIN" --file "$ROOT/web/index.html" --watch "$@"
