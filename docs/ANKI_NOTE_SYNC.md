# Shared Note → Anki sending

2026-11-04. Mac single-sense and batch sends now use the same Note/Note Type/Card Template
model as built-in review. The existing endpoint/key/profile settings and controller operation
lease are reused. No real Anki collection was accessed during implementation or validation.

## Journey and ownership

Corpus → Add to Anki opens a shared-type/deck preview. Loading/closing the sheet does not create
a Note or enroll a sense. Explicit sending prepares a stable Note, then publishes named fields,
front/back templates, CSS and only referenced owned images. A Note prepared for Anki can later
be enrolled in built-in review with the same identity and custom fields. Source/type/custom-field
refresh alone never enrolls an Anki-only Note. Mobile consumes this rule from the shared package.

Repeated sends find the stable `LingroveNoteID` field and update the same remote note. Models are
namespaced by workspace and type ID; template names use stable IDs to avoid accidental card
replacement on local display-name edits. These internal Anki names are not final presentation
polish. Existing legacy per-card associations retain their explicit editor; no old exercise or
Anki association is automatically migrated. New batch exports use the shared default type.

## Boundaries

- `NoteAnkiIO` owns scoped database reads and the adjacent `*.anki-notes.json` local journal.
  It does not store credentials. Receipts are scoped by workspace, endpoint and active profile.
- `NoteAnkiModelPlan` produces expected before/after shapes for field renames/additions,
  template additions/updates and CSS updates. Temporary field names preserve values during swaps.
- `NoteAnkiSender` persists the plan before remote writes, recognizes an already-committed
  prefix after a lost reply, and verifies every mutation. Source/type/profile changes abort stale
  work. Anki's duplicate guard and identity lookup prevent ordinary retry duplication.
- `NoteAnkiFieldMerge` retains remote edits when source values are unchanged. Concurrent edits
  require a field choice; a choice against an outdated remote value is rejected. Media upload is
  followed by another note read before update. AnkiConnect's legacy API has no cross-call CAS;
  this is checked, recoverable orchestration, not a distributed atomic transaction.

A template disable/removal pauses all identified notes using the shared Anki model before making
the question empty. Enabling installs readable templates before restoring only suspensions
recorded by this adapter. Existing manual Anki suspensions remain intact. Templates/fields with
history are retained in Anki rather than destructively removed. A detected customized Anki model
stops publication; it is not silently overwritten. A missing previously acknowledged remote note
also stops; ordinary retry does not recreate a deliberately deleted note.

Anki content updates happen on explicit Send, including batch Send; this does not add background
Anki contact on corpus edits. Built-in source projection remains automatic. The two schedulers
and rating histories are independent. Local Anki receipts are device-specific and are not part of
the portable corpus backup/sync contract.

The implementation uses the existing version-6 transport. Method shapes were checked against
[the official AnkiConnect source](https://git.sr.ht/~foosoft/anki-connect), revision `c577b44`
(`plugin/__init__.py` and `plugin/legacy.py`), including model edits and suspension actions.

## Validation

Shared engine checks: seven targeted tests passed, including Anki-only preparation followed by
source, type and custom-field changes without creating any built-in cards, and later explicit
enrollment reusing the Note. Native isolated protocol fixtures cover lost add/model replies,
stable Card IDs, named-field updates, manual field conflicts/stale choices, model customization,
multiple notes sharing one model, disabled-template suspension and preservation of manual pauses.
The source passes native build-for-testing; final fixture counts are recorded with the checkpoint.
New Anki implementation files pass scoped strict SwiftLint. This is not a live-user-profile or
final visual acceptance claim. Evidence is under `build/note-anki-validation` and
`build/mac-w2-c/note-target-core.log`.

Final checkpoint: seven native protocol-fixture tests passed (including multiple notes sharing
an enabled/disabled template and retaining a manually suspended sibling), and seven shared-engine
targeted tests passed. The native build-for-testing passed. The journal source was subsequently
moved unchanged into the existing flat Models/Review folder; XcodeGen regenerated its references.
No source behavior changed after those checks. The mobile repository imported the shared-core
commit recorded by `shared/core-source.json`; no mobile UI/backend edits or live deployment were
needed for this target-admission rule.
