# Capture language material and meaning organization

Use `vocab capture` for ordinary entry/example/meaning capture. Read `schema capture` rather than
learning every resource record. Keep the selected CLI and `--app` fixed throughout the task.
The capture-task format is version 1; it is transported as a version 2 batch operation.

```json
{
  "version": 1,
  "idempotencyKey": "REPLACE-WITH-A-FRESH-UUID",
  "defaults": {
    "language": "en",
    "meaningLanguage": "zh-Hans",
    "sourceKind": "generated",
    "source": "Agent-created practice material"
  },
  "meanings": [
    {
      "ref": "delay",
      "title": "推迟安排",
      "aliases": [{"text": "Postponing an event", "language": "en"}],
      "definition": "使原定活动在更晚的时间发生。",
      "cues": ["晚点再做"]
    }
  ],
  "entries": [
    {
      "expression": "postpone",
      "senses": [
        {
          "meaning": "推迟；把活动安排到更晚的时间。",
          "tags": ["scheduling"],
          "examples": [
            {"text": "We need to postpone the meeting.", "translation": "我们需要推迟会议。"}
          ],
          "associations": [
            {"meaning": "delay", "usage": "postpone + event", "nuance": "常用于预先安排的活动。"}
          ]
        }
      ]
    }
  ]
}
```

```sh
"$lingrove_cli" schema capture
"$lingrove_cli" vocab capture --file /absolute/path/capture.json --dry-run
"$lingrove_cli" vocab capture --file /absolute/path/capture.json
```

Inspect `ok`, `dryRun`, `replayed` and `operations`. A capture outcome contains `summary` counts,
entry/expression/language and sense IDs, example IDs, association IDs and resolved meaning refs.
The same key/material produces stable IDs and a committed retry replays its receipt. Do not
invent a fresh key after a timeout. Optional `expectedRevision` guards an explicit baseline;
a capture otherwise uses the archive's serialized current snapshot without replacing fields.

## Defaults and meaning references

- Entry language comes from the entry or `defaults.language`; it must be specified somewhere.
  `kind` defaults to `word`; dictionary form defaults to expression.
- Sense/example meaning language and meaning label language inherit `defaults.meaningLanguage`.
  Translation language inherits `defaults.translationLanguage`, falling back to meaning language.
- Examples default to `sourceKind: generated`. Set captured/imported/authored truthfully when
  the material comes from those sources. Completeness defaults to sentence; mark fragments or
  unknown boundaries explicitly. Unique exact expression spans are located automatically;
  repeated/overlapping matches need explicit UTF-16 ranges. A missing match keeps spans empty.
- Model authorship defaults to active adoption (`origin: model`, `status: confirmed`). Confirmed
  means usable, not personally verified by the learner. Optional `defaults.status: proposed`
  makes the whole task tentative; individual meanings, associations and relations can override
  status. Explicit uncertainty remains available and is never inferred just from model authorship.
- Each meaning `ref` is a unique short name scoped to this capture. A new meaning needs `title`;
  `kind` defaults to concept, or use function for communicative acts. Aliases need text, optional
  language, and no UUID. Cues inherit the meaning language and status.
- To refer to existing knowledge, supply `{"ref":"delay","id":"NODE_UUID"}` instead of a new
  definition. Existing references accept ref/id and optional additive categories, preserving the node's names and cues.
  Similar wording does not automatically merge two meanings.
- Optional meaning `categories` contains category UUIDs or unambiguous built-in keys discovered
  with `data list categories`. Read [classification.md](classification.md) for category membership,
  custom parents and local overrides. Omission leaves current membership unchanged.
- An association names a meaning ref. `usage` creates a pattern; optional formality, medium and
  collocations describe that pattern. Nuance and conditions describe the association. The app
  infers expressesContent/realizesFunction from the node kind and attaches this capture's examples
  as evidence. Omit usage for a whole-sense association. Roles/slots need resource operations.
  Omit nuance when it only repeats the saved definition. Conditions are optional and should name
  an actual restriction (for example, a specific register or situation); do not fill them with
  "only this example/sense/usage". Do not copy the same explanation into several fields.
- Optional `relations` link refs using from/to/kind and optional note/status. `narrower` points
  from the narrower meaning to its broader parent. Final graph validation rejects invalid cycles.

## Identity, existing senses and limits

Exact normalized expression/language/kind selects an existing lexical entry. A sense without
`id` always creates a distinct sense; capture never guesses synonymy or merges definitions.
Read existing material first. To extend a known sense, supply its `id` plus examples, tags and
associations. Existing meanings/languages/notes cannot be replaced by capture; use update/resource
operations for explicit edits. Existing-node references and new local nodes may coexist.

Capture collects every selected sense and its examples. It preserves existing collection notes,
review state and selected examples. Duplicate example evidence can be reused within its owning
sense; conflicting meanings/translations or another sense's ownership fail without overwriting.

One task permits at most 100 entries, 100 senses total, 100 meaning declarations and 1000 examples.
Unknown fields, unsupported language codes, dangling refs and invalid relationships reject the
entire task. Capture accepts text material; use traditional append for rich text/images. Low-level
resource batches remain available for independent evidence, candidate interpretations, explicit
replacement, deletion and detailed graph maintenance. Neither path invokes a model or vector search.
