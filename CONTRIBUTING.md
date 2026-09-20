# Contributing to herdrorb

Start with a small issue or describe the problem your change solves. For a
large feature, discuss the approach before investing in implementation.
Contributions are welcome; this is a spare-time project without a response SLA.

## Development

Use macOS 14+ and Swift 6+. Clone the repository, then run:

```sh
swift test
sh scripts/check.sh
sh build-app.sh
open -n dist/herdrorb.app --args --demo
```

`swift test` covers installation, compatibility, quoting, redaction, privacy,
and migration. The check script additionally exercises native composer keys,
scrolling, parser fixtures, terminal input, folder browsing, and asynchronous
connection behavior. It creates unique temporary files and uses fake transports.
Neither command requires Herdr, agent accounts, or SSH keys.

The source is a Swift Package Manager executable with SwiftUI/AppKit views.
Xcode can open Package.swift; an Xcode project file is not required. See
[Architecture](docs/ARCHITECTURE.md) for the code map.

## Review expectations

Explain the user-visible result and how you verified it. Include demo-data
screenshots for UI changes. Preserve drafts, independent machine recovery,
normal approval prompts, and the rule against automatically resending uncertain
mutations. Keep runtime dependencies pinned and test protocol changes against a
supported Herdr version. Never add personal SSH profiles, prompts, credentials,
or real conversation screenshots as fixtures.

Run all three commands above before requesting review. CI exercises Apple
Silicon/macOS 14 and Intel/macOS 15. GUI focus and accessibility require a
manual pass; a green build does not establish those behaviors.

## Live checks

`sh scripts/check-live.sh` explicitly opts into read-only checks against the
user's configured Herdr machines. It reads snapshots and terminal output but
prints only timings/counts. Do not use personal machines in CI. Tests that
create sessions, send messages, or close panes must use disposable sessions
created for that purpose with the tester's consent.

## License and conduct

By submitting a contribution, you agree to license it under this repository's
MIT license and confirm you have the right to contribute it. No separate CLA
is required. Follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Do not put
vulnerability details in public issues; use [SECURITY.md](SECURITY.md).
