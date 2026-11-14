# Closed dependencies for certified entry edits

Status: accepted, 2026-11-13.

This extends [ADR 0006](0006-certified-local-entry-writes.md) and
[ADR 0007](0007-local-reviewed-source-retirement.md). Initial Release measurements on a synthetic
10k-entry corpus with 512 images, 2k enrolled senses and 1k ratings found several cold edits
still falling back to complete preparation: reviewed-source edits, cited interpretation edits,
shared-source captures and image changes took approximately 3.3–3.5 seconds.

## Decision

Keep the exact durable validation certificate, existing domain rules and common transactional
writer. Expand the selected fragment to its closed dependencies instead of introducing a second
business implementation or treating a page as a complete document.

`NotebookEntryAdmission+Dependencies` selects the entry's complete lexical/evidence subtree,
its owned patterns/mappings, their slots/roles/evidence and referenced node definitions. A valid
mapping can cite only examples belonging to its own sense. Arbitrary foreign-sense citations
are invalid domain data, not another supported shape. Existing domain reconciliation retracts
changed evidence and marks the mapping proposed; deleting a sense retires its patterns/mappings.
Shared meaning nodes, relations and classifications are never removed by the local writer.

An incoming example can reuse a canonical source/occurrence or accept an unassigned candidate.
The packet includes those immutable dependencies. Global indexed checks still reject accepted
occurrence theft, key collisions and identity collisions. An already accepted interpretation
owned by another entry retains the full capture policy's cloning/fallback behavior. A partial
receipt never populates the complete notebook cache.

Review material projection now has an internal version-plus-complete-affected-entries boundary.
Full and local callers use the same Card renderer, shared Note template reconciliation,
media registration and history-preserving Card writer. Source edits refresh
changed live senses (all live senses when the shared expression/header changes). Retirement
updates only the retired canonical/alias sources, without rendering unchanged siblings. Types,
Notes and memberships are selected by affected ownership. Retired Cards and rating events remain.
Canonical rows, revision CAS, pending journal, material changes and replacement certificate
commit or roll back together.

`VocabularyArchive+EntryCommands` admits cold editor saves and sense creation through the same
local command as capture. Editor three-way merging is shared with the full path. The store
continues to publish one bounded receipt and refresh pages; a complete consumer explicitly loads
the whole corpus. Independent example movement was subsequently retired by the confirmed business
model; appending examples and whole-sense consolidation remain supported.

## Media ownership

`NotebookEntryAdmission+Media` starts with the certificate's complete reference set. It adds new
local references and removes an old one only if no other canonical block owns it. Block ownership
uses a guarded digest expression index. The 2026-11-14 retirement removed embedded review plans,
templates, their media traversal and their global-identity index. Shared Note templates reference
corpus content; the separate review media holder continues to protect admitted Card resources.
Certificate validation version 2 revokes proofs made under the former corpus identity model.

All live workspace mappings and registry/cache metadata are still rechecked inside every writer
transaction. `LingroveNotebookMediaStore+Registration` batches that check into one indexed join.
Stale cache metadata still takes the existing validated PNG repair path; an unowned foreign
cache hit still fails. Document pins are diffed with set SQL instead of deleting/reinserting
every image. Re-pinning still atomically cancels release debt, and history/resource retention
rules remain with their existing owners. Supplied PNG staging retains the full writer's file
publication and rollback contract.

## Tag projection

`NotebookTagIndex` owns a disposable relational browsing projection of canonical collection tags.
SQLite triggers cover ordinary writes, sync, raw repairs, rollback and deletion. Installation or
repair rebuilds it atomically; a schema change revokes old certificates until complete validation.
Read-only hosts can use the canonical JSON query before a writable host installs the index.

Index maintenance guards malformed JSON. Invalid tag payloads are recorded separately so version
metadata remains readable, while tag queries fail instead of hiding corrupt collections. A tagged
page materializes matching owners before display sorting; otherwise SQLite may walk the entire
newest-first workspace index to find a selective tag. This changes query planning, not business
order, canonical payloads or public synchronization format.

## Boundaries and validation

Missing, stale or damaged proof still requires complete strict preparation. Broader graph/import/
export/search operations retain their complete interface. Work remains proportional to the edited
entry, its linked exercises, selected tag matches and the complete image metadata set; this is
not a constant-time guarantee for one enormous entry or unbounded consumer fan-out.

Storage tests cover lossless reloading, shared-source reuse, occurrence/claim ownership,
semantic evidence retraction, shared nodes, supplied/reused images, sibling content ownership, stale media
metadata repair, affected-material selection and atomic late failure. Tag tests cover raw edits,
second readers, rollback, deletion, rebuild, invalid payloads and bounded selective-query VM work.
Native tests exercise cold editor saves/sense creation and later complete loading. Release paired
experiments use the same closed seed before per-version installation/certification, then a fresh
connection and independent copy for each operation. Setup and assertions are outside command
timers. Prepared image addition excludes staging; PNG staging has focused correctness coverage.
The installed Dev app and its real corpus are outside every validation host and fixture.
