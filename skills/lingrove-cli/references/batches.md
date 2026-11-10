# Vocabulary batch material

For edits that refer to existing records, retain `result.notebookScope` from the same read and include it as top-level `notebookScope` alongside the original revision. This applies to append/update/resource changes, capture with existing sense/meaning IDs, and any `expectedRevision`. It contains `workspaceID`, `notebookID`, and `generation`; never refresh only that scope on an old draft after an account change. Pure new captures may omit it.

Read the installed client's `schema` for wire shape and `status` for supported language/kind
values. These examples illustrate version 1; replace example keys with a fresh key per intended
batch, and example IDs/revisions with values read from the chosen notebook.

## Add a sense

```json
{
  "version": 1,
  "idempotencyKey": "example-add-bank-001",
  "operations": [
    {
      "add": {
        "expression": "bank",
        "dictionaryForm": "bank",
        "language": "en",
        "kind": "word",
        "meaning": "银行，提供存取款等服务的金融机构",
        "meaningLanguage": "zh-Hans",
        "tags": ["finance"],
        "examples": [
          {
            "text": "The bank is open.",
            "sourceKind": "generated",
            "translation": "银行开门了。",
            "translationLanguage": "zh-Hans",
            "completeness": "sentence"
          }
        ],
        "content": [
          {"text": "Common patterns", "bold": true},
          {"text": "open an account at a bank; deposit money in a bank"}
        ]
      }
    }
  ]
}
```

Required add fields are `expression`, `language`, `kind`, and nonempty `meaning`. Optional
`dictionaryForm` defaults to expression. Existing entries keep their dictionary form, notes,
and senses. Each add creates a distinct sense; neither identical meaning text nor a shared
dictionary form performs a sense merge.

Sense `meaning` names the saved sense. Example `translation` translates the whole example;
examples do not accept `meaning`/`meaningLanguage`. Put detailed explanations in sense `content`
(or capture's `explanation`) and personal annotations in `note`. Raw generation records are not
an authoring surface.

## Append to an existing sense

```json
{
  "version": 1,
  "idempotencyKey": "example-append-bank-002",
  "operations": [
    {
      "append": {
        "entryID": "11111111-1111-4111-8111-111111111111",
        "senseID": "22222222-2222-4222-8222-222222222222",
        "examples": [
          {
            "text": "She works at a bank.",
            "sourceKind": "generated",
            "translation": "她在一家银行工作。",
            "translationLanguage": "zh-Hans",
            "completeness": "sentence"
          }
        ],
        "tags": ["work"]
      }
    }
  ]
}
```

At least one nonempty `examples`, `content`, or `tags` array is required. Append adds tags;
update replaces the tag array. Append cannot edit a sense's meaning or note.

Omitting `sourceID` creates a new source; identical sentence text from different sources stays
distinct. Explicitly reusing the original source ID and ranges keeps the existing example ID and
primary translation, collecting distinct translations as variants. Capture and append share this
rule. Another sense owning that occurrence is a conflict. `source` records an optional citation;
editing the citation requires `exampleEdits`. Retrying appends with a new key can duplicate content.

## Update only intended fields

```json
{
  "version": 1,
  "idempotencyKey": "example-update-bank-003",
  "operations": [
    {
      "update": {
        "entryID": "11111111-1111-4111-8111-111111111111",
        "senseID": "22222222-2222-4222-8222-222222222222",
        "expectedRevision": 12,
        "note": "Use a bank for an unspecified institution and the bank for one already identified.",
        "tags": ["finance", "review"]
      }
    }
  ]
}
```

Use the latest get's `result.revision` as `expectedRevision`. All updates in one batch check
the same baseline notebook revision; do not increment it between operations. A stale revision
rejects the whole batch. Reread and reconcile with the current content before a revised write.

Only supplied fields change. `note: ""` and `tags: []` clear those fields; meaning stays nonempty.
`explanation` replaces a plain, unformatted, image-free body only; an empty string clears it.
A rich body rejects this shortcut. Use `contentEdits` with part IDs from a canonical read:

```json
"contentEdits": [
  {"blockID":"TEXT_PART_UUID", "find":"exact unique fragment", "replacement":"corrected fragment"},
  {"blockID":"IMAGE_PART_UUID", "caption":"New caption"}
]
```

A fragment must match exactly once, including overlapping matches. Untouched formatting, paragraph
styles and images survive. An explicit `{"blockID":"PART_UUID","remove":true}` removes one part.
Append new text/images through `append.content`; do not rebuild rich text from a plain read.
Do not combine `explanation` and `contentEdits` in one update.

`exampleEdits` accepts `{id, text?, translation?, translationLanguage?, completeness?, ranges?,
sourceKind?, source?}`. Changed source text creates new evidence while retaining the example ID
and original source snapshot. Omitted fields stay unchanged. `removeExamples: [EXAMPLE_UUID]`
removes only examples owned by this sense. `linkNodes: [{nodeID, conditions?}]` adds existing nodes;
`unlinkNodes: [NODE_UUID]` detaches all this sense's mappings to those nodes, preserving shared nodes.
All edits participate in the same revision check and atomic before/after preview.

Delete a sense using `{"remove":{"entryID":"ENTRY_UUID","senseID":"SENSE_UUID"}}` in a version 2
batch with root `expectedRevision` and `notebookScope`. Its examples/links are removed; shared nodes
and independent source evidence survive. An empty headword is removed as part of the same operation.

## Merge duplicate senses

Read both senses and choose the survivor deliberately. Use a version 2 batch with the original
`notebookScope` and `expectedRevision`; do not combine senses from different entries.

```json
{
  "version": 2,
  "idempotencyKey": "REPLACE-WITH-A-FRESH-UUID",
  "expectedRevision": 12,
  "notebookScope": {
    "workspaceID": "WORKSPACE_FROM_READ",
    "notebookID": "11111111-1111-4111-8111-111111111111",
    "generation": "GENERATION_FROM_READ"
  },
  "operations": [{"merge": {
    "entryID": "22222222-2222-4222-8222-222222222222",
    "sourceSenseID": "33333333-3333-4333-8333-333333333333",
    "targetSenseID": "44444444-4444-4444-8444-444444444444"
  }}]
}
```

The target keeps its ID, definition, explanation, notes, tags and semantic links. Source examples
move with their translations and provenance; shared source content is removed. Same sentence text
from different sources stays distinct. Source-only semantic links are removed without deleting
shared nodes. Preview and commit reuse the same JSON/key; MCP uses its existing reviewed
`notebook_preview`/`notebook_commit` path. A committed retry returns the original receipt.

## Context and UTF-16 ranges

- Supply the actual source sentence if available; use `completeness: "fragment"` for clipped
  context, or `"unknown"` for unverified boundaries. Do not label a fragment as a complete sentence. If no context is available, omit the
  example rather than fabricating one.
- Omitted `ranges` finds one exact expression occurrence automatically. No match leaves an empty
  range. Multiple matches, including overlapping ones, need explicit ranges to disambiguate.
- Ranges use UTF-16 code units, not UTF-8 bytes, Unicode scalars, or grapheme counts. In
  `"🏦 bank"`, bank is `{"location": 3, "length": 4}` because the emoji occupies two UTF-16 units.
  For already selected Python string indices `start:end`, compute:

  ```python
  location = len(text[:start].encode("utf-16-le")) // 2
  length = len(text[start:end].encode("utf-16-le")) // 2
  ```

Example `sourceKind` can be `captured`, `imported`, `authored`, `generated`, or `unspecified`.
It defaults to `authored`. Preserve the actual provenance; do not label illustrative material
as captured. Use `generated` for model-created source text.

## Rich content and local files

Each content block is either `{"text": "...", "bold": true, "italic": false}` (style flags
optional), or `{"image": {"path": "images/bank.png", "caption": "A bank building"}}` (caption
optional). Image blocks cannot have text/style flags. Do not pass HTML, executable content,
remote URLs, raw base64, or app-private media references as input blocks.

Use only images supplied or explicitly selected for the task. Paths are relative to the input
JSON file; `--stdin` uses the command's current working directory. Absolute paths work for both.
The CLI reads those files and sends bounded bytes; the app normalizes the images. Keep input
files and image bytes available and unchanged while a write's outcome is uncertain.

```sh
"$lingrove_cli" vocab apply --file /absolute/path/material.json --dry-run
"$lingrove_cli" vocab apply --file /absolute/path/material.json
# Stdin is an alternative input mode, not an additional commit step:
"$lingrove_cli" vocab apply --stdin < /absolute/path/material.json
```

Choose `--file` or `--stdin`, never both. Every operation has exactly one action. Unknown keys
are rejected at every input level, so do not copy a get response into apply.

## Limits

| Scope | Limit |
| --- | --- |
| Batch | 1–100 operations; nonempty idempotency key, at most 200 UTF-8 bytes |
| Input or wire message | 32 MiB, including wire encoding overhead |
| Original images in a batch | 64 images and 16 MiB total image bytes |
| Content and examples per batch | 512 content blocks and 1,000 examples |
| Each operation | 64 content blocks and 100 examples |
| Each example | 64 ranges |
| Expression, dictionary form, sense meaning | 32,000 UTF-8 bytes per field |
| Note, example text/translation, content text | 262,144 UTF-8 bytes per field |
| Image caption | 16,384 UTF-8 bytes |
| Tags on a sense | 100 tags, each nonempty after trimming and at most 200 UTF-8 bytes |

Split larger material into independently keyed batches; atomicity stops at each batch boundary.

## Replies and recovery

Replies are JSON on stdout; inspect `ok` and `error.code` even after a nonzero exit.

| Exit / code | Action |
| --- | --- |
| 2 / `invalid_input` | Check schema, fields, limits or response size. Use app export for an oversized get. |
| 3 / `not_found` | Search/read the target again; do not guess replacement IDs. |
| 4 / `conflict` | Reread revision, ownership and the result of an existing key; reconcile before a revised write. |
| 5 / `busy` | Retry the unchanged request. |
| 6 / `unavailable` | Check the executable/app destination and launch state. |
| 7 / `io` | Check the named input/image/storage path; preserve uncertain write material. |
| 8 / `timeout` | The write may have committed; retry exactly the same key and content. |

A committed retry returns `replayed: true`, the original `revision`, and `currentRevision`.
It does not restore subsequently changed or deleted records. A replay can also be returned for
`--dry-run` after the same key has committed. Read affected records before further updates.
