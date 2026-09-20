# Changelog

## 0.2.0-beta.1 — 2026-09-20

First public developer beta, renamed from the private Herdr Bubble prototype to
**herdrorb**. Existing prototype preferences and cache directories are migrated
on first normal launch; demo and setup previews use separate state.

- Added automatic first-run setup and recovery from missing or stopped Herdr.
- Replaced human-readable status parsing with Herdr's JSON status interface.
- Added typed connection states, executable overrides and shared SSH validation.
- Added agent executable checks and recovery actions for failed startup.
- Added conversation-persistence and automatic-image settings, cache clearing,
  and redacted diagnostic copying.
- Added fictional demo sessions, native app icon and About metadata.
- Added MIT licensing, dependency/artwork notices and contribution documentation.
- Added SwiftPM tests, isolated test temporary directories, two-architecture CI,
  and release packaging with an optional Developer ID/notarization path.

Requires Herdr 0.9.1 / protocol 22. Initial downloadable archives use ad-hoc
signatures and are not notarized. See docs/COMPATIBILITY.md for validation limits.
