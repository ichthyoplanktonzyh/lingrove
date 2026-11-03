# Repository boundaries

## Native Mac

This repository's main branch owns the existing native macOS Lingrove app: menu-bar inline
completion, writing/reading acquisition, original corpus page, account/sync, built-in review,
Progress, CLI and optional Anki adapter. It remains AGPL. The corpus window now adds only
Personal corpus / Review / Progress; menu and existing Settings/account UI retain their entry.
See MAC_WORKSPACE.md for ownership, local-save behavior, validation evidence and remaining gaps.

## Independent private mobile application

[lingrove-mobile](https://github.com/ichthyoplanktonzyh/lingrove-mobile) contains the complete
former Nibomo subtree, flattened at its own root, plus mobile/backend/MCP validation tooling.
Its local checkout is /Users/shadow/lingrove-mobile. It is a separate private Git repository;
there is no live subtree, submodule or sibling-path build requirement here. The mobile product
retains the inherited account/sync/review infrastructure with Lingrove's corpus model. MIT and
other third-party attribution is preserved there. Creating/pushing it does not deploy services.

The independent repository retains the extracted mobile application and services. On 2026-11-03,
mobile-only paths, their upstream squash root and local recovery references were purged from
this Mac repository's Git history. Historical mobile commits are intentionally unavailable here;
the private mobile repository is their maintenance source. Its shared/core-source.json records
a valid current Mac core revision. Completed Mac wave reports remain in Mac Git history; mobile
phase records were purged together with mobile source. Ignored local validation evidence stays
outside Git and is not a substitute for the maintained private repository.

Do not merge or restore pre-cleanup Mac histories, old mobile worktrees or old subtree snapshots
into this repository. Consume mobile features in the private repository; shared changes flow from
the authoritative Mac packages through an explicit reviewed snapshot. Public origin references
were inspected and did not contain the removed mobile paths; this cleanup did not force-push them.

## Shared source and wire contracts

This repository remains authoritative for Packages/LingroveNotebook, LingroveNotebookEngine,
LingroveCloud and LingroveNotebookCloud, plus the canonical vocabulary classification catalog.
Mobile vendors exact regular-file snapshots, whose commit and hashes are recorded in
shared/core-source.json. Its scripts/sync-shared-core.py refuses modified managed files before
updating from a reviewed Mac Git revision. Update/validate core here first, then import and
regenerate the backend catalog in mobile. Do not maintain independent shared implementations.

NOTEBOOK_SYNC_CONTRACT.md and PRODUCT_MODEL.md describe the common identity/business contract.
Mobile docs/shared-core.md and docs/lingrove-corpus-architecture.md describe its consumed core
and backend/storage adapters. Old Nibomo source paths in package manifests and UI source maps
are historical extraction provenance, not files that Mac builds need in this checkout.

Local corpus/review works without login. Authentication, ownership acceptance and sync consent
remain separate. Save never enrolls; a sense is the review object; examples only supply material.
Anki keeps separate history. Temporary translations, autocomplete context and logs do not become
synced corpus. No old-user-data migration is required; future writes/history remain protected.
