# Vocabulary batch material

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
            "meaning": "银行",
            "meaningLanguage": "zh-Hans",
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

Sense `meaning` names the saved sense. Example `meaning` describes that expression's meaning
in its specific context, while `translation` translates the whole example. These are separate
fields, with separate language codes. Put learning notes in `note` or `content`; there is no
`explanations` input field.

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

A repeated occurrence within the target sense keeps its existing usage ID and primary
translation, collecting distinct translations as variants. A conflicting contextual meaning
fails instead of overwriting saved material. If another sense owns the occurrence, append to
that owner when appropriate or use an explicitly authorized [resource organization batch](organization.md). Creating another sense is not
a conflict-resolution mechanism. Retrying rich-text appends with a new key can duplicate blocks.

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

Only supplied `meaning`, `meaningLanguage`, `note`, and `tags` are replaced. Omit fields that
should stay unchanged; do not use null as a clearing command. `note: ""` and `tags: []` clear
those fields. Meaning must remain nonempty. Update cannot rename an entry, replace examples,
delete senses, or move usages; use [version 2 resource operations](organization.md) for those actions.

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
| Expression, dictionary form, sense/example meaning | 32,000 UTF-8 bytes per field |
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
