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

The extraction source is 59f2542f4984ffcde94c7c6fc4b60900c059fa04, which includes all delivered
main-chat/mobile and native Mac work through Wave 4 and the existing macOS 0.7.2 preparation.
Completed plans, dispatch/delivery notes and integration journals are consolidated into
maintained docs; their original records remain in this repository's Git history. Ignored local
validation evidence is retained separately in build/, not copied into the private source repo.

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
