# Local retirement of reviewed corpus sources

Status: accepted, 2026-11-13; narrowed to Notes on 2026-11-14.

The user subsequently chose Note-only authoring/practice and waived compatibility for existing
legacy card content/history. The legacy-link/retained-face branches described in the original
checkpoint below have been removed. The current writer selects affected Notes/memberships and
uses `sourceMissing` only; corpus atomicity and future Note/Card history guarantees still apply.

[ADR 0009](0009-closed-entry-dependencies-and-tag-index.md) extends the same writer to live
reviewed sources and replaces conservative semantic/media fallbacks with closed dependency checks.

ADR 0006 conservatively sent every cold entry command with review consumers through complete
corpus preparation. The 20k Release median for deleting an enrolled sense remained 8800.997ms.
Source retirement needs a smaller operation than arbitrary source editing: no live source
remains to render, while saved Cards, Notes, memory, authored fields and rating history survive.

## Decision

The certified local command derives the retired canonical sense ID and its merged historical
IDs from its losslessly decoded previous entry. The existing domain removal, foreign semantic
citation admission, media checks, revision CAS and corpus journal remain in the same transaction.
After replacing canonical rows/header, the writer calls
`LingroveNotebookReviewMaterialStore.retireSourcesInTransaction`, then records its replacement
certificate. This internal method accepts no arbitrary UI draft or partial document.

The existing material store owns the retirement rules:

- Read live legacy links by workspace, notebook and retired source IDs. Skip Cards owned by
  shared Notes so their material policy is applied only once.
- Mark active legacy exercises `sourceMissing`, or `retained` if the user explicitly elected
  to keep using their saved faces. Missing/tombstoned Cards retain the full path's skip behavior.
- Read Notes by the exact notebook/source IDs and membership by those Note IDs. Validate only
  their affected Note/type/template models, then reuse `ReviewNoteStore.refreshCard` with an
  absent source. Shared Note Cards retain the established `sourceMissing` rule.
- Reuse one material-state upsert shared with the full renderer. Card faces/tags, scheduler
  state, Note/custom-field/type definitions, enrollments, links, memberships, their journals
  and append-only rating events are not rewritten by source retirement.

There is no new renderer, transport, schema format or storage owner. Cancellation is checked
before canonical writes and within affected-material loops. A material/type/journal failure
rolls back canonical rows, header, material states and certificate together. The existing
entry receipt updates pages/selections and publishes repository changes only after admission;
the complete store/cache remains unloaded until a complete consumer requests it.

This specialization applies to deletion with an exact valid certificate. Reviewed captures or
arbitrary source edits, changed media references, foreign semantic citations, missing/stale proof
and other unsupported shapes keep the established full path. Warm complete writers keep their
existing full-cache incremental path.

## Query shape

Adding a notebook filter to selected legacy-link reads allows the existing composite source
index to constrain all three keys. No new index is necessary. Scoped Note and membership
queries no longer ask SQL to order by note/card identity: SQLite otherwise chose workspace-wide
primary/unique index walks to satisfy that ordering. Their small returned collections are sorted
in memory to preserve the existing deterministic query interface. This introduces no authored
membership order or persisted positions.

A trace-based regression grows unrelated Notes/Cards from 20 to 400. The retirement command
retains approximately 6,648 SQLite VM instructions at both sizes. The initial ordered query
prototype grew from 7,121 to 16,621 instructions; most growth came from the two selected queries.
This is an assertion about that synthetic query workload, not a constant-time guarantee for
arbitrarily many linked Cards, media references or cross-citation shapes.

## Validation

Private storage integration covers multi-template Notes, authored custom fields, retained
schedules/history, stale rating rejection, surviving sibling material, merged historical IDs,
ordinary/explicitly-retained legacy Cards, rollback at material and journal stages, affected
definition corruption and workspace/generation isolation. A native store test checks cold
receipt admission, page/detail refresh and later complete loading while retaining a rated Card.

The Release inventory keeps the same generated 10k/20k workload and three trials per operation.
The old `sense.remove.cold.enrolled-fallback` window becomes `sense.remove.cold.enrolled`; its
timer still invokes the same production store command. Assertions now require a partial receipt,
an unchanged Card, `sourceMissing` material and all 1,000 historical ratings. Missing-proof
fallback remains separately measured. All validation uses synthetic state and private hosts;
the installed Dev app and its real corpus remain outside this checkpoint.
