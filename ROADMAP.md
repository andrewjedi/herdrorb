# Roadmap

## Public beta delivered

- Guided setup, executable overrides, JSON status and protocol checks.
- Per-device diagnostics, agent detection, failed-launch recovery.
- Local data controls, independent demo mode, sanitized support diagnostics.
- MIT licensing, contributor docs, native icon, repeatable release packaging.
- Standard unit tests, interaction checks, macOS CI and draft release workflow.

## Before a recommended general-use binary release

- Provision a Developer ID Application certificate and notarization credentials;
  exercise the signed release path and test a quarantined download on another Mac.
- Independent installation tests by people following only the README.
- Full keyboard/VoiceOver, small-display, multiple-monitor, IME/dictation, and
  energy profiling passes on representative hardware.
- Verify compatibility with additional Herdr and agent CLI versions before
  expanding the supported-version table.

## Possible follow-ups

- Richer structured agent history if upstream provides a stable interface.
- Configurable per-project automatic-preview policies.
- A signed update mechanism and Homebrew cask once distribution is stable.
- Additional agent types, each with parser and interaction fixtures.

These are priorities and ideas, not delivery-date commitments.
