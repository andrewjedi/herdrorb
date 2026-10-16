#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
CHECK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/herdrorb-checks.XXXXXX")
trap 'rm -rf "$CHECK_TMP"' EXIT HUP INT TERM
COMMON="Sources/HerdrOrb/ConversationApproval.swift Sources/HerdrOrb/ConversationActivity.swift Sources/HerdrOrb/RemoteTranscriptConnection.swift Sources/HerdrOrb/ConversationArchive.swift Sources/HerdrOrb/ProviderTranscript.swift Sources/HerdrOrb/ProviderBridge.swift Sources/HerdrOrb/ContextUsage.swift Sources/HerdrOrb/DesignSystem.swift Sources/HerdrOrb/Installation.swift Sources/HerdrOrb/HerdrClient.swift Sources/HerdrOrb/Transport.swift Sources/HerdrOrb/ConversationCache.swift Sources/HerdrOrb/SessionNames.swift Sources/HerdrOrb/TerminalPresentation.swift Sources/HerdrOrb/CodexSessionSettings.swift Sources/HerdrOrb/ClaudeSessionSettings.swift"
swiftc -parse-as-library $COMMON Sources/HerdrOrb/MessageComposer.swift Tests/ConversationChecks.swift -o "$CHECK_TMP/herdr-conversation-checks"
"$CHECK_TMP/herdr-conversation-checks"
cat Sources/HerdrOrb/ConversationActivity.swift Sources/HerdrOrb/TerminalPresentation.swift Tests/PresentationChecks.swift > "$CHECK_TMP/herdr-presentation-checks.swift"
swift "$CHECK_TMP/herdr-presentation-checks.swift"
swiftc -parse-as-library $COMMON Tests/ResponsivenessChecks.swift -o "$CHECK_TMP/herdr-responsiveness-checks"
"$CHECK_TMP/herdr-responsiveness-checks"
swiftc -parse-as-library $COMMON Sources/HerdrOrb/ConversationScroll.swift Tests/ScrollChecks.swift -o "$CHECK_TMP/herdr-scroll-checks"
"$CHECK_TMP/herdr-scroll-checks"
# Link the real Markdown package into the standalone artifact checks as well.
swift build --product HerdrOrb
CHECK_BIN=$(swift build --show-bin-path)
python3 - "$CHECK_BIN" "$CHECK_TMP/markdown-objects" <<'PYOBJECTS'
from pathlib import Path
import shlex, sys
base = Path(sys.argv[1])
objects = [str(path) for name in ['Markdown', 'CAtomic', 'cmark_gfm', 'cmark_gfm_extensions'] for path in (base / (name + '.build')).rglob('*.o')]
Path(sys.argv[2]).write_text('\n'.join(shlex.quote(path) for path in objects))
PYOBJECTS
swiftc -parse-as-library -I "$CHECK_BIN/Modules" -I .build/checkouts/swift-markdown/Sources/CAtomic/include -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include $COMMON Sources/HerdrOrb/RichMarkdown.swift Sources/HerdrOrb/SyntaxHighlight.swift Sources/HerdrOrb/ConversationMarkdown.swift Sources/HerdrOrb/Artifacts.swift Tests/ArtifactChecks.swift @"$CHECK_TMP/markdown-objects" -o "$CHECK_TMP/herdr-artifact-checks"
"$CHECK_TMP/herdr-artifact-checks"
swiftc -parse-as-library Sources/HerdrOrb/TerminalInputBuffer.swift Tests/TerminalInputChecks.swift -o "$CHECK_TMP/herdr-terminal-input-checks"
"$CHECK_TMP/herdr-terminal-input-checks"
swiftc -parse-as-library $COMMON Sources/HerdrOrb/ProjectFolders.swift Tests/ProjectFolderChecks.swift -o "$CHECK_TMP/herdr-project-folder-checks"
"$CHECK_TMP/herdr-project-folder-checks"
swiftc -parse-as-library Sources/HerdrOrb/TerminalThemeFilter.swift Tests/TerminalThemeChecks.swift -o "$CHECK_TMP/herdr-theme-checks"
"$CHECK_TMP/herdr-theme-checks"

python3 scripts/tests/test_provider_bridge.py
