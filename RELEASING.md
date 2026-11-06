# Releasing Lingrove (拾语)

This document owns distribution and release verification. `project.yml` is the source of app
version/build metadata. `scripts/package_dmg.py` validates the production app and stages only its
explicit installer/legal inputs; `scripts/build_dmg.sh` is its shell entry point. GitHub Actions
retains the separate future Developer ID/notarization/update workflow.

## Current release: 1.0.0 (build 5)

Publish the clean current source as **Lingrove（拾语）v1.0.0**, tag `v1.0.0`, with GitHub's
prerelease flag disabled and the release marked latest. The universal artifact is
`Lingrove-1.0.0-universal.dmg`; it has no test designation. Release notes live in
[releases/lingrove-1.0.0.md](releases/lingrove-1.0.0.md).

The package remains **ad-hoc signed and unnotarized** because the distribution identity is not
configured. Stable version naming does not establish Developer ID signing or notarization.
Keep these facts visible in the install guide and notes. Sparkle remains disabled, with no feed
or public key; manual update opens this repository's Releases page. Leave
`LINGROVE_RELEASES_ENABLED` unset until the independent signing/update setup below is complete.

The production scheme produces `Lingrove.app` (`io.ichthyoplanktonzyh.lingrove`). Lingrove Dev
has its separate bundle, storage and credentials. Do not launch, replace or read the installed
user app/data for release validation. Validate with synthetic fixtures and a private host.

## Build and verify

Hold `/tmp/lingrove-mobile-validation.lock` for Xcode, native preparation and package inspection.
Build from a clean committed source revision:

```sh
scripts/build_dmg.sh --output-dir build/distributions/v1.0.0
```

The script prepares the pinned inference/native helpers, builds Release for arm64 and x86_64,
signs only a clean staging copy and checks DMG integrity. It holds its checkout build lock through
packaging and removes `build/DerivedData`, including on failure. `--app-path` is only for an
existing Release app from the exact source revision; that mode leaves DerivedData to its caller.

The DMG contains the app, Applications shortcut, `INSTALL.txt` from
`assets/release/INSTALL.zh-CN.txt`, and third-party/legal notices. Downloaded model weights,
user data and credentials are excluded. Attach the DMG, `INSTALL.zh-CN.txt`, `SHA256SUMS.txt`
and `build-info.json` to the release. Build metadata records exact source SHA, dirty flags,
version/build, architectures, minimum macOS and signing/notarization state. Both dirty flags must
be false for publication. Shared packages, CLI and all native helper inputs participate in source
tracking.

Before publishing, verify mounted contents, version/build, every embedded executable's slices,
nested signatures, absence of test bundles/entitlements, and SHA-256. Run the packaging regression
suite and the affected feature/storage checks; distinguish executed tests from compilation.
Intel hardware and a fresh downloaded Gatekeeper install remain unverified unless actually tested.
After upload, compare GitHub asset SHA-256 values against local artifacts and confirm the tag
resolves to `build-info.json`'s source commit. Publish and verify the new release before removing
all superseded GitHub Releases and their assets. Retain historical Git tags and source commits.

## Installation and permissions

macOS 14 or later is required. Apple Intelligence additionally needs a supported Mac and macOS 26.
Users drag Lingrove.app into Applications, eject the DMG and launch from Applications. Because the
package is unnotarized, macOS may require Open Anyway in Privacy & Security. See the bundled guide
for detailed steps and Apple's Gatekeeper reference. Updates are manual; back up important data.

Accessibility and Input Monitoring enable autocomplete. Screen Recording is separate and optional,
for visual context/region OCR/pointer OCR. Dev settings, models and credentials are not imported.
Local models are downloaded separately. Remote inference/dictionary/account services require
explicit configuration. No account service URLs are bundled; local corpus/review/Progress work
offline. Signing identity changes can require macOS permissions to be granted again.

## Independent update architecture

Keep Sparkle as the updater. GitHub Releases stores the signed, notarized `Lingrove.dmg`, while
GitHub Pages hosts `appcast.xml`. No application server or custom domain is required for this plan.
With the current repository name, the intended standard Pages feed is
`https://ichthyoplanktonzyh.github.io/lingrove/appcast.xml`; this is a planned address, not a deployed
service. Confirm the actual URL after enabling Pages. Optionally set `LINGROVE_UPDATES_DOMAIN` to a
domain we control; release CI then writes its CNAME.

The flow is:

1. Archive the production app with an increasing build number and our Developer ID signature.
2. Package, notarize, and staple the final DMG.
3. Sign that final archive with our Sparkle Ed25519 private key.
4. Generate the appcast with version, minimum-platform metadata where needed, download URL,
   archive length, and signature. The workflow passes its own GitHub owner/repository explicitly.
5. Upload the DMG to Releases, then publish the appcast to Pages.
6. Installed apps read the feed; Sparkle compares build numbers, downloads and validates the archive,
   and handles installation/relaunch. Checking for an update and installing it are separate policies.

Apple Developer ID signing/notarization establishes the macOS distribution identity. Sparkle's
Ed25519 signature authenticates the update archive to the installed app. These are separate keys
and both must belong to Lingrove's release process.

## Configuration before enabling updates

1. Configure our Developer ID certificate and Apple notarization account in repository secrets:
   `DEVELOPER_ID_APPLICATION_CERT`, `DEVELOPER_ID_CERT_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`,
   and `APPLE_APP_SPECIFIC_PASSWORD`. Preserve their existing workflow encodings.
2. Generate a distinct Sparkle key using the pinned Sparkle tools. Use a separate Keychain account
   so another product's existing key is not silently reused:

   ```sh
   <Sparkle tools>/generate_keys --account lingrove
   ```

   Put the printed public key in `SUPublicEDKey` in `LingroveInfo.plist`. Keep the private key in
   Keychain, back it up securely, and provide the exported key to CI as
   `SPARKLE_ED25519_PRIVATE_KEY`. Do not put it in the repository or command output. The existing
   release job checks that CI's private key matches the bundled public key.
3. Enable GitHub Pages with GitHub Actions as its source and configure the `github-pages`
   environment. Add `SUFeedURL` using the confirmed HTTPS feed URL.
4. Set `LingroveUpdatesEnabled` to true for production. Choose automatic-check/install defaults
   explicitly; development remains disabled regardless of this flag. Recommended initial behavior
   is automatic checks with user-confirmed installation.
5. Set `LINGROVE_RELEASES_ENABLED=true` only after the app and workflow configuration agree. A
   `workflow_dispatch` run with `publish: false` validates packaging/notarization without publishing;
   a `v<version>` tag publishes. Versions use SemVer and `github.run_number` supplies the increasing
   build number. Preserve monotonic build numbers if the workflow or repository is replaced.
6. Test an older signed Lingrove version upgrading to a newer signed version using a staging feed.
   Verify the signature, install location, restart, settings/history/model preservation, permissions,
   failure/cancellation behavior, and that dev/upstream installations are unaffected. Use a staging
   feed to confirm invalid signatures are rejected before declaring updates ready.
7. Publish the corresponding source and build instructions for each distributed release, including
   the pinned inference revision and applied patch. See LICENSE and THIRD_PARTY_LICENSES.md.

## Native dependency and historical releases

Run `scripts/prepare_lingrove_workspace.sh` before building: it pins CotabbyInference and applies
`patches/cotabbyinference-upstream-pending.patch`. Do not remove the patch before a compatible
package revision is available. See CONTRIBUTING.md for builds and tests.

Historical Cotabby / CoHamster release notes describe earlier binaries. They do not configure
Lingrove's identity, feed, keys, or release destinations.

References: [Sparkle setup](https://sparkle-project.org/documentation/) and
[publishing updates](https://sparkle-project.org/documentation/publishing/), plus
[GitHub Pages setup](https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site)
and [Apple Developer ID](https://developer.apple.com/developer-id/).
