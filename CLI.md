# Local vocabulary CLI

Install from **Settings → General → Command-line tools**. The app embeds its client at
`Lingrove.app/Contents/Helpers/lingrove`; installation adds a symlink at `~/.local/bin/lingrove`.
The developer app installs **`~/.local/bin/lingrove-dev`** and uses the independent Dev notebook.
If `~/.local/bin` is not on your PATH, use the complete path. Installation does not edit shell files.

```sh
lingrove status
lingrove schema
lingrove vocab list --query bank --language en --limit 20
lingrove vocab get ENTRY_UUID
lingrove vocab apply --file material.json --dry-run
lingrove vocab apply --file material.json
cat material.json | lingrove vocab apply --stdin
```

The client starts its containing app in the background when needed. `--app /path/Lingrove.app`
chooses another installation explicitly. `--no-launch` requires an already running app.
`--timeout SECONDS` accepts 1–120 seconds; the default is 30. No network port is opened.
Learning material stays on the Mac; none of these commands requests AI inference or sends to Anki.

## Atomic batches

The executable publishes the version 1/2 input JSON Schema with `lingrove schema`. `status` lists
supported language codes and expression kinds. Input accepts 1–100 operations. Unknown keys are
rejected so a spelling mistake cannot silently discard a note.

```json
{
  "version": 1,
  "idempotencyKey": "lesson-2026-10-21-bank-1",
  "operations": [
    {
      "add": {
        "expression": "bank",
        "dictionaryForm": "bank",
        "language": "en",
        "kind": "word",
        "meaning": "银行，提供存取款等服务的金融机构",
        "meaningLanguage": "zh-Hans",
        "note": "Lesson 1",
        "tags": ["finance"],
        "examples": [
          {
            "text": "The bank is open.",
            "translation": "银行开门了。",
            "translationLanguage": "zh-Hans",
            "meaning": "银行",
            "meaningLanguage": "zh-Hans",
            "completeness": "sentence"
          }
        ],
        "content": [
          {"text": "A place to keep or borrow money.", "bold": true},
          {"image": {"path": "images/bank.png", "caption": "A bank building"}}
        ]
      }
    }
  ]
}
```

- **`add`** groups exact normalized expressions of the same language/kind and creates a new sense.
  It never merges meanings by wording. Existing dictionary forms, senses and user notes stay intact.
- **`append`** requires exact `entryID` and `senseID`; it appends `examples`, `content`, or `tags`.
  A repeated occurrence in that sense retains its ID and primary translation, collecting distinct
  translations as variants. Conflicting saved contextual meanings fail rather than overwrite.
  An occurrence already owned by another sense is a conflict; move it explicitly with resource operations.
- **`update`** requires `entryID`, `senseID`, and the **current notebook `expectedRevision`** returned
  by `get` or `status`. It replaces only supplied `meaning`, `meaningLanguage`, `note`, or `tags`.
  An empty note or empty tags array clears that field. The entire batch fails on stale revision.

```json
{
  "version": 1,
  "idempotencyKey": "lesson-1-append-2",
  "operations": [
    {"append": {
      "entryID": "ENTRY_UUID",
      "senseID": "SENSE_UUID",
      "content": [{"text": "Additional learning material"}],
      "tags": ["review-later"]
    }}
  ]
}
```

Example `ranges`, when supplied, are `{ "location": 4, "length": 4 }` offsets in **UTF-16**,
matching macOS text ranges. If omitted, one exact occurrence is located automatically; multiple
matches require explicit ranges. No match leaves the range empty rather than inventing a span.
Use `completeness: "fragment"` for incomplete context. Agent-supplied meanings and rich text are
saved as authored learning material; they are not relabeled as an app-generated AI explanation.

Image paths are relative to the JSON file, or the current directory for stdin. The CLI reads only
these explicit paths and sends bounded bytes. The app normalizes images using the same PNG pipeline
as its editor. HTML and executable content are not accepted. A batch permits 64 images, 512 content
blocks, and 1000 examples in total; each operation permits 64 blocks and 100 examples. Input and
wire messages are limited to 32 MiB, and original image bytes to 16 MiB per batch.

`--dry-run` checks the same domain rules and images, returns planned IDs, and does not write
material, media, or an idempotency receipt. New IDs remain stable between a dry run and its commit
for the same batch. The baseline revision can still change before commit; read again on conflict.

## Independent resources and external organization

`vocab list/get` reads personally collected material. Catalog knowledge and raw evidence can
exist without a personal collection or meaning graph. Resource commands expose both:

```sh
lingrove data list sources --limit 20
lingrove data list interpretations --status candidate
lingrove data list mappings --related SENSE_UUID
lingrove data list nodes --query 金融
lingrove data get senses SENSE_UUID
```

Resources are `entries`, `senses`, `sources`, `occurrences`, `interpretations`, `collections`,
`nodes`, `patterns`, `mappings`, `relations`, `cues`, and `cueTargets`. Lists return full records,
`total` and `nextOffset`, with limits of 1–200 and 16 MiB per page. `--related` matches a UUID
in record values; `--status` is specific to interpretations. Resource timestamps are Unix seconds.

Use a version 2 batch with a batch-level `expectedRevision` for `put`/`delete`. Caller-supplied
UUIDs make linked records possible in one atomic batch. `put` preserves omitted fields, replaces
arrays and clears optional nulls. `schema` includes `x-requiredOnCreate` for creation fields.
Sources and occurrences are immutable; corrections create new UUIDs. Delete dependencies
explicitly in the same batch: no automatic cascade or orphan cleanup is performed.

Personal membership is a `collections` record keyed by `senseID`, owning notes, tags, selected
accepted interpretation IDs and private review state. Uncollecting removes this relation while
preserving catalog, evidence, interpretations and meaning knowledge. Collection creation is
explicit for resource writes; traditional `add`/`append` remain personal-save conveniences.
Sources can precede interpretations, and several candidate interpretations can share an
occurrence. At most one accepted interpretation is allowed per occurrence.

The external agent performs classification. Lingrove validates relationships and persists
its changes; no internal classification service, vector matching or automatic model request is
introduced. New agent assertions default to model/proposed provenance. See the complete
[resource organization guide](skills/lingrove-cli/references/organization.md) for payloads,
candidate resolution, membership, corrections and deletion.

## Results, retries and ownership

Request results and errors are JSON on stdout (`--help` and `--version` use text). A successful
write returns `revision`, `operations` with exact IDs, `dryRun`, and `replayed`. An open notebook
updates through the app's shared store immediately. `list` returns paginated summaries, and `get`
returns portable learning material, excluding app-specific Anki receipts and host metadata.
List summaries include at most 50 senses per expression and 200 Unicode scalars per label; `get`
reads the complete entry. `expressionTruncated` and `meaningTruncated` explicitly mark abbreviated
labels; retrieve the entry before reusing its complete text. A conservative pre-encoding budget rejects extremely large entries
before allocating the full JSON response; use the app's export for those.

Each committed batch stores an idempotency receipt **in the same SQLite transaction** as its
content. If a reply is lost or times out, retry the **same key and same material**. A different
payload with an existing key fails. `replayed: true` returns the original write acknowledgement;
it does not recreate items subsequently edited or deleted. `currentRevision` reports the present
notebook revision on replay. Read the entry again before preparing an update.

The app is the writer: do not modify its SQLite file or image directory directly. Mailbox files
are private to the current macOS user. A passive directory watcher consumes requests; idle apps
do not poll. The client removes consumed replies and unclaimed timed-out requests; the server
retires abandoned reply files after a day. Durable idempotency receipts are not expired.

| Exit | Error code | Meaning |
| --- | --- | --- |
| 0 | — | Success |
| 2 | `invalid_input` | Invalid input, content limit, or oversized response |
| 3 | `not_found` | Entry/sense no longer exists |
| 4 | `conflict` | Stale revision, changed key payload, or conflicting ownership |
| 5 | `busy` | Storage/server busy; retry the same key |
| 6 | `unavailable` | App cannot be found/launched |
| 7 | `io` | Local file/storage failure |
| 8 | `timeout` | Completion uncertain; retry the same key |

## Agent skill

The portable [lingrove-cli skill](skills/lingrove-cli/SKILL.md) teaches agents to search before
saving, choose add/append/update, preview batches, and recover uncertain writes without duplicates.
Its [batch reference](skills/lingrove-cli/references/batches.md) travels with it; agents can use the
skill without access to this repository or the app source. The installed CLI's `schema` and
`status` remain the authority for the available input format and language/kind values.

For Codex, install from the repository root (the symlink keeps local edits in sync):

```sh
lingrove_skill_root="${CODEX_HOME:-$HOME/.codex}/skills"
mkdir -p "$lingrove_skill_root"
ln -s "$PWD/skills/lingrove-cli" "$lingrove_skill_root/lingrove-cli"
```

This intentionally fails if that destination already exists; inspect it rather than overwriting
another skill. To install independently of the checkout, copy the complete `skills/lingrove-cli`
directory into your agent's skill directory instead. CLI installation is a separate step, described
at the top of this document.

Invoke with `$lingrove-cli`, for example: “把这次对话里的表达和例句保存到拾语。” The skill can also be
selected automatically for Lingrove notebook requests. It uses the normal notebook by default;
explicitly name `lingrove-dev` when the Dev notebook is intended.
