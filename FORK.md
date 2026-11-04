# Repository origin and development

This document records Lingrove's relationship to Cotabby and how development reaches a release. It
complements CONTRIBUTING.md, which owns the build and test instructions.

## Direction and attribution

- Repository: https://github.com/ichthyoplanktonzyh/lingrove
- Upstream: https://github.com/FuJacob/cotabby
- Product direction: inline autocomplete and language learning are equally core capabilities.
  Develop both together for everyday writing, including translation and expression learning.
- This repository maintains the native Mac app and authoritative shared Swift packages. The
  independent mobile application and its service boundaries are documented in
  [REPOSITORY_BOUNDARIES.md](docs/REPOSITORY_BOUNDARIES.md).
- Product name: **Lingrove** in English and **拾语** in Chinese. Use `lingrove` for new technical
  identifiers. The name reflects learning expressions from everyday reading and writing.
- The approved Lingrove whale mark is maintained in `assets/branding/lingrove-logo.svg`, with
  `scripts/generate_brand_assets.mjs` as its asset-generation entry point. Release installer artwork
  is generated from the same master by `scripts/generate_dmg_background.mjs`.
- The field-edge activation indicator uses a separate tail-only source at
  `assets/branding/lingrove-activation-indicator.svg`.
- App products are `Lingrove.app` and `Lingrove Dev.app`, with Bundle IDs
  `io.ichthyoplanktonzyh.lingrove` and `io.ichthyoplanktonzyh.lingrove.dev`. The internal Xcode
  schemes use `Lingrove` / `Lingrove Dev`. Targets, the Swift module and source folders also use Lingrove. The real upstream inference
  dependency keeps its own name and attribution. Legacy preference keys, arguments and environment
  variables remain readable through explicit compatibility policies.
- Models, encrypted typing history, and logs use separate `Lingrove` / `Lingrove Dev` folders.
  Preferences and Keychain services use the new Bundle IDs. Existing Cotabby data stays untouched;
  automatic import is not implemented. Encrypted history requires its original key for any future
  migration, so copying only its archive is insufficient.
- Sparkle stays disabled in every build until independent updates are configured. Manual update
  checks open this repository's releases. User-facing brand copy and project links use Lingrove.
  See RELEASING.md for the independent update plan.
- Original authorship and contributor attribution remain intact; Lingrove does not claim ownership
  of upstream contributions.
- LICENSE remains AGPL v3. Third-party code, dictionaries, and model weights retain their own terms.

## Repository workflow

`origin` points to `ichthyoplanktonzyh/lingrove`; `upstream` points to FuJacob/Cotabby. Lingrove's
`main` is the active in-development integration branch. Review upstream changes before applying
them; upstream changes are inputs to evaluate, not automatic product decisions.

Before adopting an unmerged upstream pull request, review its GitHub page: confirm its base branch,
head repository and branch, full diff, and whether it depends on other pull requests or unmerged
commits. Fetch only the PR head ref with tags disabled, then inspect and record its head SHA. Create
a topic branch from Lingrove's `main` before cherry-picking reviewed commit(s). The `-x` option adds
each source commit SHA to the resulting commit message:

```sh
git fetch --no-tags upstream refs/pull/123/head
git show --stat --oneline FETCH_HEAD
git rev-parse FETCH_HEAD
git switch -c codex/adopt-pr-123 main
git cherry-pick -x REVIEWED_COMMIT_SHA
```

Replace `123` with the pull request number and `REVIEWED_COMMIT_SHA` with a reviewed commit ID.
Record the PR URL, captured PR head SHA, selected commit SHA(s), dependencies, and adoption or
rejection result in the integration PR or review notes. If local comparison with the PR base is
needed, fetch only that specific upstream base ref with `--no-tags`. This is a manual review
workflow; it does not automatically merge upstream changes. Avoid rebasing or force-pushing a
shared development branch.

The original `codex/language-learning` branch was a checkpoint of the local learning implementation
and related input, insertion, endpoint, and settings work. The approved work from that checkpoint is
now part of Lingrove's `main` branch. The branch name records an intermediate development step; the
checkpoint itself was not a release-validation signoff.

Interface localization follows the same boundary: `Localizable.xcstrings` is the upstream common
catalog, while `Learning.xcstrings` contains Lingrove's learning and integration copy. English is
the UI source language with 14 translated locales. Interface language, autocomplete languages,
and learning source/target languages remain separate preferences. See CONTRIBUTING.md for catalog
ownership, translation imports, and compiled-resource checks.

## Historical adoptions and releases

Individual upstream reviews and completed implementation checkpoints formerly appended to this
file remain in this repository's Git history. Preserve upstream commit attribution when adopting
changes. Current release prerequisites and status are maintained in [RELEASING.md](RELEASING.md),
and bundled attribution and licenses in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
