# Meaning categories

Read the selected installed client's `schema` and `schema capture`; category support is additive
to CLI 3. Do not infer capability from the version number alone. The app installs its bundled
catalog locally; no model or vector search is involved.

```sh
"$lingrove_cli" data list categories --query 'content.degree' --limit 100
"$lingrove_cli" data list categoryParents --related CATEGORY_UUID
"$lingrove_cli" data list categoryMemberships --related NODE_UUID
"$lingrove_cli" data list categoryOverrides --related CATEGORY_UUID
```

Paginate using `nextOffset`. A category has an `axis` (`content` or `function`), multilingual
`labels`, optional definition and stable `id`. Built-ins also have `frameworkID` and `key`;
custom categories have neither. `frameworks` exposes read-only catalog version receipts.
Do not reproduce an entire category catalog in prompts when a narrow query suffices.

Capture meaning declarations accept additive `categories`, each a category UUID or an unambiguous
built-in key. Read a key from the installed catalog before using it. Existing-node references may
add categories while preserving their names and cues:

```json
{"ref":"almost-none","title":"几乎没有","categories":["content.degree.near-zero"]}
```

```json
{"ref":"existing","id":"NODE_UUID","categories":["CATEGORY_UUID"]}
```

Choose the intended meaning rather than the expression's surface spelling: barely may express
near absence or just reaching a threshold in different senses. Do not assign all its senses to
one category automatically. Category membership is not an expression-to-meaning mapping, nor a
personal learning relationship. Existing uncategorized nodes are retained without inferred links.

For explicit organization, use revisioned version 2 resource batches as described in
[organization.md](organization.md):

| Resource | Write behavior |
| --- | --- |
| `categories` | Create/edit a custom category with `id`, `axis`, `labels`, optional `definition` and provenance. |
| `categoryParents` | `id`, `categoryID`, `parentID`; custom children may have several same-axis parents, or none for a root. Cycles and duplicate pairs fail. |
| `categoryMemberships` | `id`, `nodeID`, `categoryID`, optional provenance. Several categories per meaning; duplicate pairs fail. New agent memberships default to model/confirmed. |
| `categoryOverrides` | Keyed by `categoryID`, with optional replacement `labels`, `definition`, and `isHidden`. Omitted fields retain current values; null clears an optional override. |
| `frameworks` | Read only. |

Built-in definitions and their parent links are read only. Rename or hide a built-in via its
override; do not relabel it as custom or replace its catalog key. Catalog upgrades retain local
overrides, custom children and memberships. Retired definitions keep their IDs and existing links;
new capture memberships must reference active categories.

Deleting a custom category also detaches its parent edges, child edges, memberships and override.
It preserves meanings, lexical senses, examples and other categories. Delete a membership to
unclassify a meaning; delete an override to inherit the catalog's display values again. A proposed
membership is retained for maintenance but excluded from active category filtering.

Preview, commit and verify through the CLI using the same destination, file and idempotency key.
Resource writes require the latest notebook revision. Never edit the database or catalog file in
the installed app to organize a notebook.

## Category guidance and sources

Categories may include `definition`, `examples: [{"text": "not", "language": "en"}]`,
`scopeNote`, and `references`. These describe classification, not collected entries; examples
never create senses, evidence or review cards. Read this guidance before creating a new category.
In particular, distinguish negation from near absence, obligation from permission, and spatial
arrival from attaining a goal. Use sense-level meaning, not surface spelling, when choosing a branch.

A reference has `source`, `identifier`, `url`, and `relationship` (`adapted`, `combined`, or
`narrower`), plus optional `attribution` and `license`. It records a source mapping, not a claim
that the frameworks are equivalent. Consult the referenced definition when boundaries are unclear;
do not present a locally adapted summary as an external project's exact definition.

`data list/get categories` returns catalog/custom records. Also read `categoryOverrides` for a
category's effective local guidance. Optional override `examples`, `scopeNote` and `references`
replace the corresponding base values; omission preserves a patch's current value, null restores
inheritance, and an empty array/string explicitly clears the value. Custom category guidance is
optional. Built-in changes still use overlays and survive future catalog updates.

The catalog retains its sourced Chinese summaries and language-tagged examples, mainly English;
v3 adds localized names and guidance as described below. Source mappings and the bundled notice identify the adapted
SIL v4 material under CC BY-SA 4.0. Preserve reference attribution/license when exporting or
adapting that guidance. The app shows only the existing short category description; scope notes,
examples and sources are available through CLI, not additional notebook explanation panels.

## Localized category presentation

Catalog v3 provides names, definitions and scope notes in all 15 interface locales. `localizations`
is an array of objects with required `language` (BCP-47-style string) and optional `name`,
`definition`, `scopeNote`. These locale tags are independent of `status.languages`, which lists
study languages: `id`, `tr` and `pt-BR` are valid interface tags without changing study-language
support. Read all authored versions through the normal `data list/get categories` commands.
The original `labels`, `definition` and `scopeNote` stay available for compatibility.

Presentation chooses the current interface locale (including an available regional/script alias),
then English, then the original field. Missing fields inherit separately; an empty definition or
scope note explicitly hides that field. Names must be nonblank. Examples retain their source
language and are not translated or duplicated as collected entries. Source references are shared
across translations.

Custom categories can provide one language only. Locale keys must be unique after case/underscore
normalization. A `categoryOverrides.localizations` array replaces the stored override array, but
its effective rows merge into the base category by language and field. Null removes those local
translation overrides; [] has no per-language overrides. Old untagged definition/scope overrides
remain visible as authored fallback text until translated overrides are supplied. Editing through
the UI writes only changed fields in the interface locale; saving a displayed fallback unchanged
does not create a translation. Restore defaults removes local overrides together.

Category example language tags are also independent BCP-47-style strings. This does not add
new languages to lexical-entry capture or change saved examples; existing language codes decode unchanged.
