# Capture language material and meaning organization

For edits that refer to existing records, retain `result.notebookScope` from the same read and include it as top-level `notebookScope` alongside the original revision. This applies to append/update/resource changes, capture with existing sense/meaning IDs, and any `expectedRevision`. It contains `workspaceID`, `notebookID`, and `generation`; never refresh only that scope on an old draft after an account change. Pure new captures may omit it.

Use `vocab capture` for ordinary entry/example/meaning capture. Read `schema capture` rather than
learning every resource record. Keep the selected CLI and `--app` fixed throughout the task.
The capture-task format uses `version: 1`.
Apply the shared [semantic-modeling guidance](semantic-modeling.md) when selecting node scope,
kind, patterns and categories. A node describes reusable meaning, not a whole example scene.
For practice material, see [Capture after language practice](semantic-modeling.md#capture-after-language-practice)
for the full workflow and readback.

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
    {
      "ref": "delay",
      "title": "推迟安排",
      "aliases": [{"text": "Postponing an event", "language": "en"}],
      "definition": "使原定活动在更晚的时间发生。",
      "cues": ["晚点再做"],
      "categories": ["content.time.timing"]
    }
  ],
  "entries": [
    {
      "expression": "postpone",
      "senses": [
        {
          "meaning": "推迟；把活动安排到更晚的时间。",
          "explanation": "postpone 后接活动或事件，常用于预先安排的活动。",
          "tags": ["scheduling"],
          "examples": [
            {"text": "We need to postpone the meeting.", "translation": "我们需要推迟会议。"}
          ],
          "associations": [
            {"meaning": "delay"}
          ]
        }
      ]
    }
  ]
}
```

```sh
"$lingrove_cli" schema capture
"$lingrove_cli" data list categories --query content.time.timing --summary --limit 10
"$lingrove_cli" vocab capture --file /absolute/path/capture.json --dry-run
"$lingrove_cli" vocab capture --file /absolute/path/capture.json
```

Inspect `ok`, `dryRun`, `replayed` and `operations`. A capture outcome contains `summary` counts,
entry/expression/language and sense IDs, example IDs, association IDs and resolved meaning refs.
Each resolved meaning includes `categories` with `categoryID`, optional `key`, `membershipID`
and `created`. `summary.categoryMembershipCount` counts newly added memberships; existing ones
return `created: false`. Use the returned IDs to read back practice capture relationships.
The same key/material produces stable IDs and a committed retry replays its receipt. Do not
invent a fresh key after a timeout. Optional `expectedRevision` guards an explicit baseline;
a capture otherwise uses the archive's serialized current snapshot without replacing fields.

## Defaults and meaning references

- Entry language comes from the entry or `defaults.language`; it must be specified somewhere.
  `kind` defaults to `word`; dictionary form defaults to expression.
- Sense meaning language and meaning label language inherit `defaults.meaningLanguage`.
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
  with `data list categories --summary`. This completes ordinary classification in the same
  capture; there is no separate membership write. Read [classification.md](classification.md)
  only for independent classification edits, custom parents or local overrides. Omission leaves
  current membership unchanged.
- An association accepts only `meaning`, optional `conditions`, and `status`. It links the whole
  sense to the named node; relation kind follows the node kind. `conditions` describes a real
  restriction. Syntax, register and usage explanations belong to the sense body. `usage`, `nuance`,
  formality and collocations are not capture association fields. Advanced pattern constraints
  remain available through resource operations.
- Optional `relations` link refs using from/to/kind and optional note/status. `narrower` points
  from the narrower meaning to its broader parent. Final graph validation rejects invalid cycles.

## Identity, existing senses and limits

Exact normalized expression/language/kind selects an existing lexical entry. A sense without
`id` always creates a distinct sense; capture never guesses synonymy or merges definitions.
Read existing material first. To extend a known sense, supply its `id` plus examples, tags and
associations. Existing meanings/languages/explanations/notes cannot be replaced by capture; use update/resource
operations for explicit edits. Existing-node references and new local nodes may coexist.

Capture adds each selected sense and its examples, preserving existing notes and review state.
Without `sourceID`, each example is a new source even if its sentence text matches another source.
To reuse existing evidence, supply its read `source.id` as `sourceID`, preserve its exact text/ranges,
and retain notebook scope. Capture and append both keep the primary translation and add distinct
translations as variants. Another sense's ownership is a conflict; use an explicit merge/edit.
An example's optional `source` is a citation (for example an article title/URL), defaulting to
`defaults.source`. It does not establish identity; only `sourceID` does.

One task permits at most 100 entries, 100 senses total, 100 meaning declarations and 1000 examples.
Unknown fields, unsupported language codes, dangling refs and invalid relationships reject the
entire task. Capture accepts text material; use traditional append for rich text/images. Low-level
resource batches remain available for independent evidence, candidate interpretations, explicit
replacement, deletion and detailed graph maintenance.


Detailed explanation belongs on the sense through `explanation`. Example `meaning` and
`meaningLanguage` are not accepted by capture/add/append. Put useful usage prose in the sense
body, retaining semantic associations for node links and genuine applicability restrictions.
Generic CSV/TXT import is not an app operation: read the file, determine the intended senses,
search existing material and use these explicit commands. A bare word list does not establish
which senses the learner intends to collect; agree on the scope rather than expanding all senses.
