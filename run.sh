#!/usr/bin/env bash
# Runs a scene from web/ in the foreground, with live reload. Ctrl-C quits.
#
#   ./run.sh                 # the default scene
#   ./run.sh embers          # a named scene from web/
#   ./run.sh leaves --tint   # scene plus any Overlay flags
#   ./run.sh --url https://example.com
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/build/Overlay.app/Contents/MacOS/Overlay"
SCENE="leaves"

# A bare first argument names a scene; anything starting with - is a flag.
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

exec "$BIN" --file "$ROOT/web/$SCENE/index.html" --watch "$@"
