# Compatibility

| Component | Contract for 0.2.0-beta.1 |
|---|---|
| macOS | Deployment target 14.0+. CI targets macOS 14 (arm64) and macOS 15 (Intel). |
| CPU | Separate arm64 and x86_64 builds. Choose the architecture of your Mac. |
| Swift | Manifests require 6.0+. Local build/unit/interaction validation used Apple Swift 6.3.3. CI logs record its actual toolchain. |
| Herdr | Tested with 0.9.1; API protocol must equal 22. Other versions sharing 22 are not automatically claimed as tested. |
| SwiftTerm | Pinned to 1.20.0; resolved dependency versions are committed. |
| Agents | Codex and Claude Code executable discovery and terminal attachment. Authentication stays with the CLIs. |
| Remote OS | macOS. Remote previews use BSD stat; Linux hosts are not supported by this release. |

## What is verified

Local Apple Silicon validation covers a clean release build, standard unit
tests, interaction/regression checks, bundle resources/signatures, and native
demo/setup/settings UI inspection. Herdr JSON status was checked against an
existing server and a nonexistent session without creating or changing sessions.

CI is configured to run unit tests, interaction checks, and bundle builds on
both architecture/OS combinations above. Consult the checks on the exact release
commit for results. Build/CI success does not establish a complete interactive
session acceptance pass on every supported Mac.

Agent output fixtures are sanitized samples, not a promise that every Codex or
Claude release renders identically. A current full live send/authentication/
approval lifecycle matrix for named agent CLI versions is still pending. Use
Terminal if formatted conversation output is incomplete. Contributions should
record exact versions in new compatibility reports.

## Upgrading

Do not upgrade Herdr blindly to fix a connection. Compare the detected protocol
with this table and the release notes. Unsupported protocols fail before session
mutations; herdrorb never silently downgrades or installs Herdr.

Herdr 0.9.1 does not implement the general output-change wait used by some API
schema descriptions. herdrorb uses lifecycle/status events and visible-pane
reads, with a 100 ms working / 500 ms idle pause between requests. This is not a
claim of token streaming or a guaranteed complete agent transcript.
