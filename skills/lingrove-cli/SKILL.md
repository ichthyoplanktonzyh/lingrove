---
name: lingrove-cli
description: Read, save, and organize language-learning material in local Lingrove (拾语) through its macOS CLI. Use for notebook capture, learning notes, personal collections, source interpretations, and meaning-graph organization. Do not use for general language questions without a Lingrove request, autocomplete control, or Anki synchronization.
---

# Lingrove CLI

Use the bundled `lingrove` client as the notebook interface. The app owns validation, media,
and atomic storage; never edit its SQLite database, media directory, or mailbox directly.
These commands stay local and do not invoke app inference or send material to Anki.

## Select the notebook and discover the contract

- For the normal notebook, resolve `lingrove` on PATH, then try `~/.local/bin/lingrove`.
- Use `lingrove-dev` / `~/.local/bin/lingrove-dev` only for the explicitly selected Dev notebook.
  Dev and production have separate data. If the requested command is unavailable, report that
  rather than silently switching notebooks.
- A known app bundle can run its `Contents/Helpers/lingrove` directly. `--app APP_PATH` explicitly
  overrides the destination app. Keep the executable and any app override fixed through reads,
  preview, commit, and retries.
- If missing, direct the user to **Lingrove → Settings → General → Command-line tools**.
  Do not download another CLI, require administrator access, or rewrite shell configuration.

In shell examples, `lingrove_cli` means the resolved executable path. Assign it in each shell
invocation that needs it; do not assume variables survive between tools.

```sh
lingrove_cli="$HOME/.local/bin/lingrove"
"$lingrove_cli" --version
"$lingrove_cli" status
"$lingrove_cli" schema
```

Read `status` for supported `languages`, `kinds`, and the notebook `revision`. Read `schema`
before preparing a batch; it emits the installed client's JSON Schema without launching the app.
Run `schema` or `schema capture`, `--help`, and `--version` alone, without request flags. Prefer the installed
contract over remembered enums. If the requested material needs an unsupported capability,
explain the limit instead of inventing commands or fields.

Requests start the containing app in the background if needed. `--no-launch` requires a running
app. `--timeout SECONDS` accepts 1–120 (default 30); allow the outer tool enough time to receive
the CLI's final JSON response.

## Capture material with a small task interface

Prefer `vocab capture` when adding entries, examples and meaning groups together. Read
`schema capture` and [references/capture.md](references/capture.md): it accepts batch defaults,
short meaning refs and nested senses. The app generates IDs, evidence and personal membership,
locates unique spans and returns a complete saved summary. Read existing material before deciding
whether to create a new sense or extend an exact existing sense ID. New definitions never merge
by similarity. Use resource operations for fine-grained replacement/deletion or independent claims.

Authorized agent organization is adopted by default and keeps model authorship. `confirmed` means
active in the notebook, not reviewed by a human; do not relabel model authorship as user authorship.
Use explicit proposed/candidate states only for uncertain material or requested alternatives.
Populate optional fields only when they add information. A usage note describes syntax or register;
an association nuance describes a meaningful distinction from alternatives. Keep each fact in
one appropriate place. Conditions must state a concrete applicability restriction; omit boilerplate
such as "only this sense/example/usage", which adds no restriction beyond the existing links.

## Read before choosing a write

```sh
"$lingrove_cli" vocab list --query 'bank' --language en --limit 20 --offset 0
"$lingrove_cli" vocab get 'ENTRY_UUID'
```

`list` is a search, not an exact identity lookup. Paginate with `--offset` while it is below
`result.total`; `--limit` accepts 1–200 (default 50). Summaries may truncate expression/meaning
labels and include only the first 50 senses. Use `get` before choosing a sense or reusing text.
The read shapes differ: list uses `entries[].entryID` and `senses[].senseID`; get uses
`entry.id` and `entry.senses[].id`, all inside `result`. Get's `revision` is the notebook revision,
not a per-entry version. Its portable entry is read output, not an apply payload.

| User intent | Operation | Required decision |
| --- | --- | --- |
| Save a new expression or a distinct meaning | `add` | Exact normalized expression + language + kind select the entry; every add creates a new sense, even if its meaning text already exists. |
| Add examples, explanation blocks, or tags to a saved meaning | `append` | Read and use the exact entry and sense IDs. Do not use add as a shortcut for appending. |
| Correct a saved meaning, note, or tags | `update` | Read the entry and use its current notebook revision as `expectedRevision`; supply only intended replacement fields. |

For capture requests, check likely existing entries and reuse the matching sense when the meaning
is clear. If evidence is ambiguous, retain candidate interpretations or a distinct provisional
sense rather than forcing a merge. Ask only when the requested existing destination cannot be
inferred and affects the user's intent. Preserve the
source expression and context; put a known lemma in `dictionaryForm` without assuming it merges
different expression spellings. Distinguish the sense's `meaning` from an example's translation
and contextual meaning. Use the user's requested explanation language and supported codes.
Do not invent a source sentence; label any requested illustrative material as agent-authored.

Read [references/batches.md](references/batches.md) when preparing a write. It contains complete
add/append/update payloads, rich-content rules, UTF-16 ranges, and size limits.

## Organize retained material and meaning knowledge

Traditional `vocab list/get` reads the personal collection. `data list/get` reads the independent
catalog, evidence, interpretations, collections and optional meaning graph. Organizing knowledge
does not imply collecting it, and uncollecting does not delete its evidence or interpretations.

Read [references/organization.md](references/organization.md) for resource reads and version 2
`put`/`delete` batches. Use these operations when the user asks to classify meanings, resolve
candidate interpretations, move claims, manage personal membership or maintain the meaning graph.
The external agent makes those decisions; Lingrove validates and stores them without an internal
classifier. Do not create a graph merely because the user asks to save an expression.

## Preview, commit, and report

1. A request to save or edit authorizes that write. General discussion alone does not.
2. For capture, create a version 1 task file as documented above. For traditional/resource writes, create one JSON batch file with `version: 1` for traditional actions, or `version: 2` and a
   current `expectedRevision` for resource actions, plus a fresh `idempotencyKey` for this intended
   change (for example a UUID), and 1–100 operations. Use a JSON serializer or a quoted heredoc
   to keep quotes, newlines, backticks, and shell substitutions in learning text intact.
3. Preview with `vocab capture --file /absolute/path/material.json --dry-run` for capture tasks, or `vocab apply` for batches. Inspect the exit
   status and reply. Resolve any validation or ownership error before committing.
4. For an authorized write, run the same command without `--dry-run`, using the same file, key,
   images, and destination. Preview success alone does not mean anything was saved.
5. Check `ok`, `result.dryRun`, `result.replayed`, and `result.operations`. Confirm a fresh commit
   with `ok: true`, `dryRun: false`. Report the expressions/meanings saved and any material limitation.

Dry runs validate images and domain rules without writing material, media, or a receipt. Planned
new IDs stay stable for the same batch, but the notebook can change before commit. All operations
commit atomically or the batch fails. Capture meaning refs are local names resolved inside the task.
Resource operations cannot refer to prior outcomes symbolically; use actual UUIDs, or commit and
read before preparing dependent follow-up material.

## Handle replies and uncertain writes

Request replies, including failures, are JSON on stdout: inspect `ok` and `error.code` even when
the process exits nonzero. `schema` emits a JSON Schema; help/version emit plain text.

| Exit / code | Action |
| --- | --- |
| 2 / `invalid_input` | Correct the payload using schema and error message. For an oversized get response, use the app's export. |
| 3 / `not_found` | Read/search again; never guess replacement IDs. |
| 4 / `conflict` | Read the current entry. Resolve stale revision or sense ownership; never force a replacement or blindly make a new key. |
| 5 / `busy` | Retry the unchanged batch after a short delay. |
| 6 / `unavailable` | Check the chosen executable/app, then open that app or request CLI installation. |
| 7 / `io` | Inspect the named input/image paths and app availability; preserve any uncertain write's key and material. |
| 8 / `timeout` | A commit may already exist. Retry exactly the same key and material, including image bytes. |

For transient busy/timeout results, make at most two additional attempts, then report the
unresolved result and retain the batch and image files for recovery. Never generate a fresh key
to retry an uncertain write. The same key with different material conflicts; even changing image
bytes changes the payload. After a definitive rejected batch is corrected, use a fresh key for
the revised intent. For a stale update, reread and preserve concurrent user edits before rebuilding.

`replayed: true` acknowledges the original commit. It does not restore subsequently edited or
deleted items, and `revision` is the original commit's revision; `currentRevision` is current.
A replay can be returned even for `--dry-run` if that key already committed. Read again before
claiming material still exists or using its revision for an update.
