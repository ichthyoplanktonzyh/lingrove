# Lingrove CLI

Read, save and organize language-learning material in the local Lingrove notebook.
Commands do not request AI inference or send material to Anki.

## Installation and notebook selection

Install from **Settings → General → Command-line tools**. The normal app installs
`~/.local/bin/lingrove`; the developer app installs `~/.local/bin/lingrove-dev`.
They use separate notebooks. Use the full executable path if `~/.local/bin` is not on PATH.

The client starts its app in the background when needed. Global options:

| Option | Effect |
| --- | --- |
| `--app APP_PATH` | Select a particular app installation. |
| `--no-launch` | Require that app to be running. |
| `--timeout SECONDS` | Wait 1–120 seconds; default 30. |

Keep the selected executable and app destination consistent throughout a read/write operation.

## Discover and read

```sh
lingrove --version
lingrove status
lingrove schema
lingrove schema capture
lingrove vocab list --query bank --language en --limit 20 --offset 0
lingrove vocab get ENTRY_UUID
```

`status` reports the notebook revision, supported study languages and expression kinds.
`schema` describes batch input; `schema capture` describes capture input. Run schema, help and
version commands without request options. The installed schema is the authority for available fields.

`vocab list/get` reads collected material. Lists return summaries with `entryID`, `senseID`,
`total` and truncation flags; `get` returns the full entry under `result.entry`, using `id` fields.
List pages accept 1–200 entries. Read the full entry before choosing an existing sense or reusing
truncated text. Use the app's export if an entry is too large for a CLI response.

## Save entries, examples and meanings

Use `vocab capture` for adding expressions, examples and semantic associations together.
Save this illustrative task as `capture.json`, replacing the idempotency key for each new task:

```json
{
  "version": 1,
  "idempotencyKey": "REPLACE-WITH-A-FRESH-UUID",
  "defaults": {
    "language": "en",
    "meaningLanguage": "zh-Hans",
    "sourceKind": "generated"
  },
  "meanings": [
    {"ref": "finance", "title": "金融机构", "definition": "提供存款、借贷等金融服务的机构。"}
  ],
  "entries": [
    {
      "expression": "bank",
      "senses": [
        {
          "meaning": "银行；提供存款、借贷等服务的金融机构。",
          "examples": [{"text": "The bank is closed.", "translation": "银行关门了。"}],
          "associations": [{"meaning": "finance"}]
        }
      ]
    }
  ]
}
```

```sh
lingrove vocab capture --file capture.json --dry-run
lingrove vocab capture --file capture.json
```

Capture reuses an exact expression/language/kind header. Every sense without an `id` is new;
meaning similarity does not merge senses. Supply a sense's exact `id` to extend it. An existing
semantic meaning is referenced with `{"ref":"finance","id":"NODE_UUID"}`.
Omit `meanings` and `associations` when no semantic organization is wanted.

A sense's `meaning` defines the expression; example `meaning` describes its contextual reading;
`translation` translates the whole example. Preserve real source text and its provenance. Mark
illustrative model-written examples as `generated`, and incomplete context as `fragment`.
See [capture fields and examples](skills/lingrove-cli/references/capture.md).

## Edit individual records

`vocab apply` accepts atomic batches with 1–100 operations:

| Action | Use |
| --- | --- |
| `add` | Add a distinct sense, with optional examples, notes, tags and rich content. |
| `append` | Add examples, content or tags to an exact entry/sense ID. |
| `update` | Replace specified sense meaning, language, note or tags; requires the current notebook revision. |
| `put` / `delete` | Create, patch or remove catalog resources and explicit relationships. |

Use batch `version: 1` for `add`/`append`/`update`; resource batches use `version: 2` and a
batch-level `expectedRevision`. Both require a fresh `idempotencyKey` for each new intent.
`put` preserves omitted fields, replaces arrays and clears nullable fields with null.
Creation requirements are listed in schema under `x-requiredOnCreate`.

```sh
lingrove vocab apply --file changes.json --dry-run
lingrove vocab apply --file changes.json
lingrove vocab apply --stdin < changes.json
```

Use `--file` or `--stdin`. Preview and commit the same material and key. A dry run returns a
validated plan without saving it. On a stale-revision conflict, reread and reconcile the changes.
See [batch payloads, rich content and limits](skills/lingrove-cli/references/batches.md).

## Read and organize catalog resources

```sh
lingrove data list sources --limit 20
lingrove data list interpretations --status candidate
lingrove data list mappings --related SENSE_UUID
lingrove data list nodes --query 金融
lingrove data get senses SENSE_UUID
```

| Resources | Content |
| --- | --- |
| `entries`, `senses` | Lexical headers and distinct senses, including uncollected knowledge. |
| `sources`, `occurrences`, `interpretations` | Source text, selected spans and contextual readings. |
| `collections` | Collected senses, selected interpretations, notes and tags; keyed by `senseID`. |
| `nodes`, `patterns`, `mappings`, `relations` | Reusable meanings, usage patterns and their explicit links. |
| `cues`, `cueTargets` | Retrieval wording and its targets. |
| `frameworks`, `categories`, `categoryParents`, `categoryMemberships`, `categoryOverrides` | Classification directory, hierarchy, memberships and local overrides. |

Resource lists return full `records`, `revision`, `total` and `nextOffset`; `get` returns `record`.
Use `nextOffset` until null. Pages accept 1–200 records and at most 16 MiB. `--related` matches
UUID-valued references; `--status` applies only to interpretations. Timestamps are Unix seconds.

Resource writes use explicit UUIDs. Sources and occurrences are immutable; corrections create
new records. Except for custom-category deletion described below, deletions must remove or
redirect incoming dependencies in the same batch.
Uncollecting removes collection membership while retaining the lexical sense and its evidence.
See [resource fields and organization](skills/lingrove-cli/references/organization.md).

## Classify meanings

```sh
lingrove data list categories --query content.degree --limit 100
lingrove data list categoryMemberships --related NODE_UUID
lingrove data list categoryOverrides --related CATEGORY_UUID
```

Categories organize semantic meaning nodes; mappings link those nodes to lexical senses.
Discover category IDs or stable keys before using them. Capture meaning declarations accept
`categories: ["CATEGORY_UUID_OR_KEY"]`; resource operations edit individual memberships.
A meaning may belong to several categories, and a category may have several same-axis parents.
New agent assertions are active (`model`/`confirmed`) by default; proposed assertions are explicit.

Built-in categories and their parent links are read only. Use `categoryOverrides` to change local
presentation or visibility. Custom categories are editable; deleting one detaches its links while
preserving meanings and expressions.

Category records include definitions, language-tagged examples, scope notes and source references.
Their examples are classification metadata, not collected vocabulary. `localizations` stores
language-specific names, definitions and scope notes. Read the base category and its overrides
for effective values. Presentation falls back from interface language to English, then original
text. Locale and category-example language tags are independent of the study-language enum.
See [category fields, localization and overrides](skills/lingrove-cli/references/classification.md).

## Results and recovery

Requests return JSON on stdout. Inspect `ok`, including when the command exits nonzero.
A write result includes `revision`, `operations`, `dryRun` and `replayed`.

If a reply is lost or times out, retry the same key, material and image bytes. Reusing a key
with different content is a conflict. `replayed: true` acknowledges the original write; it does
not restore material edited or deleted later. Reread before making a subsequent change.
The app owns storage writes; do not modify its SQLite, media or mailbox files directly.

| Exit | Error code | Action |
| --- | --- | --- |
| 0 | — | Inspect the successful result. |
| 2 | `invalid_input` | Check schema, content limits or response size. |
| 3 | `not_found` | Search/read the target again. |
| 4 | `conflict` | Reread the revision, ownership or existing key's result. |
| 5 | `busy` | Retry the unchanged request. |
| 6 | `unavailable` | Check the executable, app path and launch state. |
| 7 | `io` | Check the reported file/storage failure; preserve uncertain writes. |
| 8 | `timeout` | Retry the same write key and content. |

## Agent skill

Use the portable [lingrove-cli skill](skills/lingrove-cli/SKILL.md) to save or organize material
through an agent. Install the complete `skills/lingrove-cli` directory in the agent's skill folder,
or symlink it for a checkout-backed installation:

```sh
lingrove_skill_root="${CODEX_HOME:-$HOME/.codex}/skills"
mkdir -p "$lingrove_skill_root"
ln -s "$PWD/skills/lingrove-cli" "$lingrove_skill_root/lingrove-cli"
```

Inspect an existing destination instead of overwriting it. CLI installation remains separate.
Invoke `$lingrove-cli`, for example: “把这次对话里的表达和例句保存到拾语。”
Name `lingrove-dev` explicitly when saving to the Dev notebook.
