# Releasing

1. Update VERSION, CHANGELOG.md, and the compatibility table. Use a distinct
   APP_BUILD integer for every distribution build.
2. Run `swift test`, `sh scripts/check.sh`, and `sh build-app.sh`. Inspect demo
   and setup-preview UI, and verify the bundle with `sh scripts/verify-bundle.sh`.
3. Review exactly what will be committed, including asset rights and a secret
   scan. Commit Package.resolved. Never commit dist, signing keys, personal
   profiles, or real conversation screenshots.
4. Push main and require its CI checks to pass. Tag the matching commit with
   `v` plus VERSION. The tag workflow tests/builds both architectures, packages
   archives/checksums, and creates a draft prerelease. Review and publish it.

The default workflow produces **ad-hoc-signed, unnotarized developer betas**.
The release body says so explicitly. Source builds remain available to everyone.
Do not remove that warning until actual distribution signing and notarization
have succeeded for every advertised binary.

## Local packaging

```sh
sh scripts/package-release.sh
```

Set `APP_ARCH=arm64` or `APP_ARCH=x86_64` to select the target. The resulting
ZIP, SHA-256 file, and signing-status.txt are written under dist. Verify Intel
behavior on Intel hardware/CI; cross-compilation alone is not runtime testing.

## Signed/notarized distribution

Provision a Developer ID Application certificate through your Apple Developer
account and install it in your signing keychain. An Apple Development certificate
is not a substitute. Store notarytool credentials in Keychain using Apple's
documented process. No credentials should be checked into this repository.

With the certificate/profile already available:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='herdrorb-notary' APP_BUILD=3 \
sh scripts/package-release.sh
```

The script signs with hardened runtime and secure timestamps, submits the ZIP,
staples and validates the ticket, checks Gatekeeper assessment, and recreates the
archive/checksum after stapling. If any step fails, do not publish its binary.
The script does not grant unnecessary entitlements or disable security checks.

Test a real browser-downloaded archive on a separate clean Mac, including
Terminal attachment, resource loading, local/remote recovery, and quitting.

Apple reference: https://developer.apple.com/developer-id/

## Maintainer follow-up

GitHub's private vulnerability reporting must be enabled in the repository.
Use read-only permissions for PR CI; signing secrets belong only in a controlled
release environment. Action dependencies are commit-pinned and tracked by
Dependabot. Contributions do not need maintainer credentials to build or test.
