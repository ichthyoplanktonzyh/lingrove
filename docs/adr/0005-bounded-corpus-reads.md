# Bounded corpus browsing and content-free operation scopes

Status: accepted, 2026-11-12.

Opening the corpus previously awaited the same full document reconstruction, lossless row
check, relationship validation and read-index preparation used by whole-document consumers.
At 20,000 entries this was a multi-second prerequisite even for displaying a few headwords.
The validated write cache remains useful, but it is the wrong readiness boundary for a list.

## Decision

The engine exposes separate page summaries and single-entry details. Pages use SQL filtering,
global counts and keyset cursors, with a default/maximum of 100 entries. Creation-time expression
indexes describe display order without reintroducing ordinal membership fields. SQLite maintains
these indexes for all writers; they are additive, rebuildable indexes on the canonical database.

Every page/cursor/detail binds workspace, notebook, durable generation, notebook revision and
the trigger-maintained corpus clock. A cursor also binds its query. A stale cursor/result is
rejected rather than appended to another account/filter/revision. Detail reconstruction selects
the entry's senses, personal content and source/interpretation closure, using the existing
lossless codec. It does not create the complete-corpus proof required by writers. Detail image
reads check subtree membership, the exact fence and the workspace's blob mapping.

The store owns a separate read-only worker/connection and UI browsing model. Page/detail work
does not queue behind the archive actor's full validation or writes. The store's existing
`entries`, read index, semantics and complete snapshot retain their complete-corpus contract.
The view observes summaries through the browsing model instead of publishing partial entries
through that compatibility interface. Edits refresh the visited window; changing a filter starts
a new window. Closing a window deactivates browsing; application shutdown drains and retires IO.

An operation scope contains identity/revision only. An editor carries its explicit entry draft
as its merge baseline; a scope no longer retains a complete document. Review can separately
reuse an acknowledged complete snapshot. A favorite lookup queries the exact entry key, including
entries outside the loaded pages. Pending/unavailable lookup is distinct from confirmed absence.

## Costs and boundaries

Graph/search, global batch operations and export continue to request the complete interface.
They cannot silently operate on loaded pages alone. The semantic links section prepares its
complete dependency when explicitly opened. First-page readiness does not certify those features
ready, and is measured separately from full-store readiness.

Ordinary cold writes still establish the complete checked state before using existing scoped
commit/receipt paths. This preserves uniqueness, relationships, media ownership, atomic saves
and review-history retention. It is an intentional remaining cost, measured as a fresh first
favorite/delete with no preceding full-load warm-up. A future cold-write design must replace
that proof boundary explicitly; displaying partial data grants no permission to bypass it.

Initial writable engine setup creates missing query indexes once. First-page timings start at
the store browse request after repository construction, and do not measure this one-time upgrade
or actual frame painting. Validation uses generated data and private hosts, never the installed
Dev application's real corpus.
