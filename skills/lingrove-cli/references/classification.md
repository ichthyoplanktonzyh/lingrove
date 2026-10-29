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
