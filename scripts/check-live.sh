#!/bin/sh
# Explicit opt-in: read-only access to configured Herdr machines and their output.
set -eu
cd "$(dirname "$0")/.."
CHECK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/herdrorb-live.XXXXXX")
trap 'rm -rf "$CHECK_TMP"' EXIT HUP INT TERM
swiftc -parse-as-library Sources/HerdrOrb/Installation.swift Sources/HerdrOrb/HerdrClient.swift Sources/HerdrOrb/Transport.swift Sources/HerdrOrb/ConversationCache.swift Sources/HerdrOrb/SessionNames.swift Sources/HerdrOrb/TerminalPresentation.swift Tests/LiveConnectionChecks.swift -o "$CHECK_TMP/live"
"$CHECK_TMP/live"
