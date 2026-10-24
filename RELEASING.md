# Releasing Lingrove (拾语)

This document owns the distribution boundary: how our app becomes a signed release and how
installed copies discover it. App lifecycle stays in `AppUpdateManager`, packaging stays in
`scripts/build_release_dmg.py`, and GitHub Actions coordinates building, notarizing, and publishing.

## Current state

- The production `Lingrove` scheme produces `Lingrove.app` with Bundle ID
  `io.ichthyoplanktonzyh.lingrove`; `Lingrove Dev` produces `Lingrove Dev.app` with
  `io.ichthyoplanktonzyh.lingrove.dev`. First-party targets and modules also use Lingrove; installed Bundle IDs and storage identities remain unchanged.
- Sparkle is included but never started: `LingroveUpdatesEnabled` is false, automatic checks and
  installation are off, and there is no inherited `SUFeedURL` or `SUPublicEDKey`.
- The manual update action opens this repository's GitHub Releases page. There is no independent
  automatic-update service or verified upgrade path yet.
- Release and Pages-republish jobs require repository variable `LINGROVE_RELEASES_ENABLED=true`.
  Leave it unset until the steps below are complete. The upstream Homebrew dispatch is removed.
- Developer signing has no shared team default. Each developer uses `Config/Signing.local.xcconfig`;
  CI supplies its own distribution team and certificate.
- The v0.5.1 build 2 test app is ad-hoc signed and packaged in a DMG for the public `v0.5.1-test.1` prerelease. It
  is not Developer ID signed, notarized, or connected to automatic updates; this does not enable
  the production release or Pages workflows.

Local development can continue without a paid Apple Developer Program membership. The production
Developer ID signing and notarization flow described here requires that membership; keep release
jobs paused until its certificates and notarization credentials are available. The ad-hoc v0.5.1
test package also does not require a paid membership; its test status and Gatekeeper steps
are documented below.

## Current development checkpoint (not published)

The namespace migration is integrated on `main` at `257cb125`. First-party source, modules,
targets, settings keys and diagnostics use Lingrove names; legacy settings and launch interfaces
retain explicit compatibility. Full regression passed with 2,956 XCTest cases (25 conditional
skips) and 758 Swift Testing tests, followed by focused namespace checks, 121 Python tests and
localization validation for 1,536 source keys. No new lint diagnostics were introduced; 91 existing
diagnostics remain. Dev Release launch and all 83 retained preference entries were verified.

The local production-target package is built with `scripts/build_test_dmg.sh --output-dir
build/distributions/namespace-migration-257cb125`. Its `build-info.json` identifies the exact
committed source used for the package, including any subsequent packaging-documentation changes.
This package remains ad-hoc signed and unnotarized: this Mac has no Developer ID Application
identity. Creating and validating this local installer does not publish a new GitHub Release or
enable automatic updates. The historical published artifacts below remain unchanged.

The local development version additionally contains independently switchable autocomplete with
cancellable warmup/runtime admission, incremental translation previews and committed-input fixes,
and the first vocabulary notebook. The notebook stores examples, notes, tags and dictionary
attribution locally, reuses speech, and exports versioned JSON. This checkpoint does not change
the published `v0.5.1-test.1` artifacts or enable automatic updates.

Dictionary lookup uses Lingrove's own nonactivating card for words and expressions; the native
popup and its injected favorite accessory have been removed. The Dictionary tab now manages
built-in/system sources, imported MDX/MDD files and optional online English/API or HTTPS website
sources. Network sources default off. Formatted system content uses an experimental private DCS
helper with a deadline and public-text fallback; system images are not loaded. Imported static
HTML/CSS/images use isolated WebKit rendering with scripts, remote assets and file URLs blocked.
Current examples, collection, speech and source-specific attribution remain in the existing flow.

The dictionary expansion passed 201 scoped tests (239 parameterized executions), zero failures
or skips, plus seven independent parser tests, 158 Python tests, strict SwiftLint and 1,384 source
keys in 15 languages. Coverage includes MDX 1/2, MDD PNG, zlib/LZO, truncation and block/work limits,
import/reopen limits, website encoding and opt-in, API attribution, helper timeout/cancellation/
oversize child cleanup, and real WebKit rendering with a reachable loopback image canary.
These scoped results do not replace the historical full-suite run below.
The user confirmed real-click acceptance in TextEdit: word lookup opens Lingrove's own card,
collection and removal keep the card open, source switching works, and outside clicks dismiss it.
This closes the former native-popup fish-tail dismissal issue for the verified flow.

The preceding own-card checkpoint passed 186 scoped tests (214 parameterized executions), with no failures
or skips, plus 158 Python tests, strict SwiftLint and 1,362 active localization keys in 15 languages.
The scoped run covers source settings and search, fallback/cancellation, captured examples,
definition persistence, real SwiftUI detail popovers and writing/reading integration. It is not
a replacement for the historical full-suite result recorded below.

Closeout checks on Apple Silicon include successful Release app/test builds, strict SwiftLint,
158 Python tests, and localization validation of 1,353 source keys across three tables and 15
languages. The latest complete test execution, during a locked desktop session, recorded 3,397
passes, 47 skips and one failure in the Window Server registration check. An unlocked rerun is
required; a successful build-for-testing does not establish test execution success. The isolated
Release settings benchmark recorded zero Writing/container body updates for all four unrelated
background-update sources.

Before the next test package, use the validated, committed checkpoint as its source and retain
any remaining limitation in the release notes. Intel/fresh-install verification, Developer ID signing,
notarization, and automatic-update validation remain separate distribution work.

## v0.5.1 test package (public prerelease)

The current test artifact is `build/distributions/v0.5.1-test.1/Lingrove-0.5.1-test-universal.dmg`, accompanied by
`SHA256SUMS.txt` and `build-info.json`. The DMG, Chinese install guide, checksum, and build metadata
are published at the [v0.5-test.1 prerelease](https://github.com/ichthyoplanktonzyh/lingrove/releases/tag/v0.5.1-test.1).
The app is an ad-hoc-signed, unnotarized test build, has no automatic updates, and is not a public
production release. The DMG includes the Simplified Chinese `INSTALL.txt` guide (copied from the
source file `assets/testing/INSTALL.zh-CN.txt`), the app, an Applications shortcut, and license
materials: `LICENSE`, `THIRD_PARTY_LICENSES.md`, `SpellingDictionaries-NOTICE.md`,
`LearningExpressions-NOTICE.md`, and `ThirdPartyLicenses/`. It does not include user preferences,
credentials, or downloaded inference/learning model weights.

`build-info.json` records the package's product/bundle identity, version/build, source commit,
actual architecture slices, minimum macOS version, signing/notarization state, and creation time.
Its `sourceDirty` flag reports whether tracked or untracked app build inputs were modified;
`workingTreeDirty` reports whether anything in the full checkout was modified. The checkout can
therefore be dirty because of documentation or packaging work while the built app inputs remain
clean. For public test publication, commit all source and packaging inputs before building and
publish the matching commit/tag; the artifact must report `sourceDirty=false`. Native speech sources
and preparation/embed scripts participate in this check. The packager also requires an executable
speech helper supporting every advertised app architecture and its embedded license resources.
TTS notices are copied into `ThirdPartyLicenses/` alongside the existing materials.

Build the current test package with:

```sh
scripts/build_test_dmg.sh --output-dir build/distributions/v0.5.1-test.1
```

Use `--app-path /absolute/path/Lingrove.app` only for a Release app built from that exact clean
source revision. The build path prepares both pinned runtimes and cleans repo-scoped DerivedData
after packaging; app-path mode leaves cleanup to its caller. Final publication checks include
DMG verification, mounted contents, signatures/entitlements, embedded binary slices and a local
launch smoke test. Keep unnotarized and unverified-hardware limitations visible in release notes.

The Xcode deployment target is macOS 14.0. The universal app contains `arm64` and `x86_64` slices.
Build, package-integrity, and basic-launch checks run locally on Apple Silicon; Intel hardware and
the downloaded first-install flow on other Macs remain for testers to validate. This does not claim
a fresh-machine Gatekeeper flow has been validated. Apple Intelligence autocomplete requires a
supported Mac running macOS 26 or later. Otherwise, testers can download a compatible GGUF model
(which may take several GB) or explicitly configure an OpenAI-compatible endpoint. No provider
credentials are bundled. Translation and optional chunk alignment use their own independently
configured local models or endpoints.

Ordinary installation requires only the DMG download; no terminal commands or checksum-file download
are required. Open the DMG, drag `Lingrove.app` to its `Applications` shortcut, eject the mounted disk image in
Finder, then launch Lingrove from Applications. Do not run the app from the mounted DMG. Because
this test build is not Developer ID signed or notarized, Gatekeeper may require the user to open it
once, dismiss the first warning, then choose **Open Anyway** under System Settings → Privacy &
Security. Continue only for a package downloaded from this repository's Releases.
If macOS says the app “will damage your computer,” or reports a broken/corrupt signature,
stop and contact the distributor; do not bypass the warning, remove quarantine, or
disable Gatekeeper. See Apple's [Gatekeeper guidance](https://support.apple.com/en-us/102445).

Accessibility and Input Monitoring are required for autocomplete. Screen Recording is optional and
is needed for screenshot-based visual context, explicit region OCR, and pointer lookup OCR fallback. After granting the first two
permissions the first time, quit Lingrove and reopen it once so the input listener starts with the
updated permission state. This package uses the production bundle identifier, while Lingrove Dev
uses a separate identifier and separate preferences/model storage; settings and models are not
imported from the dev app. During production-app testing, quit Lingrove Dev so only one app instance
owns the global keyboard monitor; uninstalling the dev app is unnecessary. Replacing an ad-hoc build
may require granting macOS permissions again.

Updates to this test build are manual: quit Lingrove, replace the app in Applications with the new
test copy, eject the DMG, and launch the replacement. Back up anything important before replacing
test builds. Input-history recording is optional, encrypted, and off by default; no history is
automatically imported from Lingrove Dev.

For autocomplete, use Settings → Appearance → **Show Field Indicator** if the focus indicator is
helpful, then type in a supported text field and press **Tab** to accept the suggestion. Acceptance
keys can be changed in Settings → Shortcuts. Language Learning has separate Translation, Chunk
alignment, and Read Aloud tabs. Engine & Model owns translation/analysis/TTS provider configuration.
Writing translation can replace the current sentence or explicit selection after confirmation;
reading translation reuses the existing card but remains read-only. Its selection, pointer, and
region OCR entries have independent switches, per-app permissions, and centrally managed shortcuts.
Pointer lookup currently translates the pointed word; contextual sense disambiguation is deferred.
Card speakers support system voices, the optional local Qwen3-TTS model/decoder pair, or an explicitly
configured speech endpoint. Speech weights are downloaded separately and are not included in the DMG.
Autocomplete and language learning are both core test areas.

Send feedback at [GitHub Issues](https://github.com/ichthyoplanktonzyh/lingrove/issues) with the
app version/build, macOS version, chip, and reproducible steps. Do not attach full prompts, model
logs, or private input; remove personal text and credentials from any diagnostic excerpt before
sharing it. A later formal distribution will require the Developer ID membership, signing and
notarization setup below. Although the production bundle identifier is already set, the ad-hoc test
signature is not the stable Developer ID distribution identity.

### Optional integrity check for technical users

`SHA256SUMS.txt` remains an optional release attachment for troubleshooting or comparing the downloaded
DMG with the published file. Users who want this check can put the DMG and checksum file in the same
directory and run:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

`OK` confirms file consistency. A matching checksum does not establish software safety or replace
Developer ID signing and notarization. Keep this command out of the default installation steps.

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
