# Reuse complete validation after synchronized writes

Status: accepted, 2026-11-13.

The certified local commands in ADRs 0006/0007 avoid full preparation while their durable
certificate matches the exact canonical fence. A synchronized apply already reconstructs and
validates its complete candidate, but previously left the certificate at the older corpus
clock/version. A later fresh archive could therefore repeat complete preparation for one text
capture. First full preparation itself also carries per-row allocation overhead.

## Decision

`LingroveNotebookSyncStore.commit` records its replacement certificate in the existing apply
transaction after canonical rows, revision, review material, shadow and receipts are finalized.
The full domain validator and media-ownership checks run before this point. A changed document
uses its checked media set; a metadata-only result certifies the current persisted media set.
Cancellation, manifest lease and binding checks remain after the certificate write, so a late
failure rolls back the certificate with all other apply rows.

An exact replay reads and checks the current local snapshot before reissuing its certificate.
It cannot use an older prepared candidate: newer local edits must survive replay. Missing
derived metadata can be restored without advancing the notebook revision. The existing
conditional UPSERT avoids rewriting an already-current certificate. Read-only snapshot,
backup/export and statistical query interfaces retain their existing transaction semantics.

The certificate contract is unchanged: workspace/notebook/revision/generation, schema version,
trigger epoch/corpus clock, validation-policy version and checksummed complete media references
must match. Unknown/raw canonical changes still invalidate it. The canonical SQL rows remain
the source of content; a certificate grants no permission to publish partial rows as a complete
document or to skip ownership checks on a later edit.

## Full-read allocation

`VocabularyPersistenceRowDecoder` is owned by one synchronous SQL read and has one private
Foundation JSON decoder. Its ordered nullable index values follow
`VocabularyPersistenceEntity.indexKeys`, the same order used to select SQL columns. It checks
slot count and position before payload decoding. This removes per-row index dictionaries/key
sets and repeated decoder construction while retaining the exhaustive typed payload dispatcher.
The SQL adapter still checks SQLite storage types and raw UTF-8; reconstruction still performs
lossless row-shape/index comparison and complete domain validation. This decoder is temporary
reader state, separate from the connection-owned complete save cache and long-lived UI graph.

Tests exercise all current payload families through both row interfaces, explicit NULL versus
missing/extra slots, malformed payload recovery, literal Unicode/NUL bytes and contradictory
index columns. Sync integration covers changed/metadata-only/replayed pulls, newer local edits,
fresh cold commands and rollback when certificate publication fails.

## Measurement

The engine comparison builds the preceding `2f5fc372` packages and the changed packages in
Release, then alternates three fresh processes per variant on byte-identical closed 20k seeds.
Median first engine load changes from 7329.457ms to 6951.004ms (about 5%). Paired changes are
-422.489ms, -378.454ms and -233.612ms. This is a modest allocation improvement, not removal of
the complete-read dependency. Engine initialization and UI index preparation are outside that
window; the OS disk cache is not purged.

The native inventory adds a closed post-apply seed created through the ordinary window
accumulator and apply prepare/commit. The synthetic empty, uninitialized remote preserves the
existing local corpus. Derived certificate metadata is removed immediately before the complete
writer; that writer must recreate it. Two fresh copies of the committed seed then retain or
remove only the certificate and time the same favorite command. Setup/sync validation, fixture
copies and assertions are outside those timers; both variants check all historical ratings.
This measures the second preparation avoided by reusing completed work, rather than treating
the first validation as free. All state and hosts are private/synthetic; no installed app,
account, corpus, transport or real endpoint participates.
