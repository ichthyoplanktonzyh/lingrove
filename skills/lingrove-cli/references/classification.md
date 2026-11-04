# Meaning categories

For edits that refer to existing records, retain `result.notebookScope` from the same read and include it as top-level `notebookScope` alongside the original revision. This applies to append/update/resource changes, capture with existing sense/meaning IDs, and any `expectedRevision`. It contains `workspaceID`, `notebookID`, and `generation`; never refresh only that scope on an old draft after an account change. Pure new captures may omit it.

Categories group reusable semantic meaning nodes; mappings connect those nodes to lexical senses.
When saving an expression and classifying it together, use the complete [capture example](capture.md).
Read the full `schema` only for an independent membership edit or custom category maintenance.

```sh
"$lingrove_cli" data list categories --query 'content.degree' --summary --limit 10
"$lingrove_cli" data list categoryParents --related CATEGORY_UUID
"$lingrove_cli" data list categoryMemberships --related NODE_UUID
"$lingrove_cli" data list categoryOverrides --related CATEGORY_UUID
```

Paginate using `nextOffset`. Categories have stable `id`, `axis` (`content` or `function`) and
multilingual `labels`. Built-ins also have `frameworkID` and `key`. Search narrowly rather than
loading the entire directory when a known topic suffices. Summary results omit examples,
localizations, references and scope notes; use `data get categories UUID` for a shortlisted record.
Queries match substrings anywhere in the full record, with whitespace-separated terms ANDed;
there is no semantic ranking. Search one concept/paraphrase at a time and stop at a defensible fit.

## Assign a meaning

Capture meaning declarations accept category UUIDs or unambiguous active catalog keys:

```json
{"ref":"almost-none","title":"几乎没有","categories":["content.degree.near-zero"]}
```

Within a capture that also includes entries, an existing node can receive additive memberships
without replacing its names or cues:

```json
{"ref":"existing","id":"NODE_UUID","categories":["CATEGORY_UUID_OR_KEY"]}
```

Use the particular sense and context, not surface spelling, to choose a category. Read definitions
and scope notes for adjacent categories. A meaning can have several memberships; different
paths to one category do not require duplicate meanings. Agent memberships default to
`model`/`confirmed`; proposed memberships are excluded from active filtering.

## Category fields

| Field | Meaning |
| --- | --- |
| `definition` | Original category description. |
| `examples` | Up to 64 `{text, language?}` illustrations; not collected vocabulary. |
| `scopeNote` | Inclusion/exclusion boundaries and distinctions from adjacent categories. |
| `references` | Up to 64 source mappings with `source`, `identifier`, HTTP(S) `url`, `relationship`, optional `attribution`/`license`. |
| `localizations` | Up to 64 language-specific rows with required `language` and optional `name`, `definition`, `scopeNote`. At least one presentation field is required. |

Reference relationships are `adapted`, `combined` or `narrower`. Consult a source when its boundary
is unclear; an adapted summary is not an external project's exact definition. Preserve attribution
and license fields when exporting or adapting sourced guidance.

Locale and example-language tags are independent BCP-47-style strings, not the study-language enum
from `status.languages`. Keep examples in their source language. Custom guidance and translations
are optional; a category can provide one language only. Locale keys must be unique after
case/underscore normalization, and names must be nonblank.

Presentation resolves each field from the current interface locale (including available regional
or script aliases), then English, then the original field. Missing localized fields inherit;
an empty localized definition or scope note clears that field.

## Edit categories and local overrides

Use revisioned resource batches as described in [organization.md](organization.md).
For a standalone “attach this existing node to this category” task, read the node, category and
existing memberships, then submit one `put categoryMemberships` with a fresh membership UUID,
`nodeID`, `categoryID`, the read's `expectedRevision` and unchanged `notebookScope`.
If that membership already exists, report it without creating a duplicate. Capture requires
entries; do not fabricate an expression or sense merely to classify an existing node.

| Resource | Write behavior |
| --- | --- |
| `categories` | Create or patch a custom category: explicit `id`, `axis`, `labels`, optional guidance and provenance. |
| `categoryParents` | Explicit `id`, `categoryID`, `parentID`; custom children can have multiple same-axis parents or none. Cycles and duplicate edges fail. |
| `categoryMemberships` | Explicit `id`, `nodeID`, `categoryID`, optional provenance. |
| `categoryOverrides` | Keyed by `categoryID`; replaces local labels, description, examples, scope, references or visibility. |
| `frameworks` | Read-only catalog receipts. |

Built-in categories and their parent edges are read only. Use overrides to rename, describe or
hide a built-in. Read both the base category and its override to resolve effective values.
Omitted patch fields stay unchanged; null clears an optional override and restores inheritance.
Empty arrays/strings explicitly clear examples, references or scope text.

`categoryOverrides.localizations` replaces the stored override array, then merges its rows into
the base by language and non-null field. Null removes translated overrides; [] supplies none.
Original untagged description/scope overrides remain authored fallback text.

Deleting a custom category detaches its parent/child edges, memberships and override, preserving
meanings and lexical senses. Delete just a membership to unclassify a meaning, or delete an
override to restore inherited presentation. Catalog updates preserve user categories and overlays.
