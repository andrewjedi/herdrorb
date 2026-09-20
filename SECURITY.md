# Security

Use GitHub's private vulnerability reporting:
https://github.com/andrewjedi/herdrorb/security/advisories/new

Include the affected release, reproduction steps using fictional data, and
expected impact. Do not publish credentials, SSH targets, or conversation logs.
This is maintained in spare time; no guaranteed response time is offered.

Security fixes target the latest published beta or stable release. Older
releases may require upgrading. Dependency updates are reviewed through
Dependabot and CI; a pinned version is not a security guarantee.

herdrorb can read local files, display terminal output, send user-authorized
terminal input, and access saved remote machines using the user's SSH
configuration. Agent output and local/remote files are untrusted content.
The application is not a sandbox for agents. SSH host-key checks remain enabled.
Never bypass an unknown or changed host key just to make a connection succeed.

See docs/PRIVACY.md for retained data and diagnostics behavior. Release binaries
must state their signing/notarization status; initial developer betas are not
notarized. Signed releases require the maintainer's Developer ID identity and
Apple notarization credentials, which must never enter source control.
