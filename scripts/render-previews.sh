#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
PREVIEW_OUTPUT=${1:-output/implementation-review/current}
if [ "$#" -gt 0 ]; then shift; fi
swift build --product HerdrOrb
PREVIEW_BINARY=$(swift build --show-bin-path)
exec "$PREVIEW_BINARY/HerdrOrb" --render-previews "$PREVIEW_OUTPUT" "$@"
