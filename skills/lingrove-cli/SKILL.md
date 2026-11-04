---
name: lingrove-cli
description: Read, save, and organize language-learning material in local Lingrove (拾语) through its macOS CLI. Use for notebook capture, learning notes, personal collections, source interpretations, and semantic organization. Do not use for general language questions without a Lingrove request, autocomplete control, or Anki synchronization.
---

# Lingrove CLI

Use the app's CLI to read and write notebook material. The app owns storage; do not edit its
SQLite, media or mailbox files directly. These commands do not request inference or send to Anki.

## Choose the notebook

Resolve `lingrove` on PATH, then `~/.local/bin/lingrove`. Use `lingrove-dev` only when the user
selects the separate Dev notebook. A known app's `Contents/Helpers/lingrove` can be used with
`--app APP_PATH`. Keep the executable and app destination fixed through reads, preview and write.
If that client is unavailable, report it instead of switching notebooks. Installation is under
**Settings → General → Command-line tools**.

```sh
"$lingrove_cli" status
"$lingrove_cli" schema capture
```

Set `lingrove_cli` to the selected executable in each shell invocation; variables may not persist
between tools. `status` supplies the current revision, study
languages and expression kinds. CLI 4 replies also identify the actual serving app in top-level
`server` (path, version/build, process, instance and capabilities). Requests handshake before
sending material and reject mismatched app destinations. `--version` identifies the local helper;
it does not identify the server. Inspect `schema capture` for capture tasks; reserve the much
larger `schema` for individual record edits. Run schema/help/version commands alone, without request flags.
Requests launch the app if needed; `--no-launch` requires a running app. `--timeout` accepts
1–120 seconds, default 30.

## Read and select the operation

```sh
"$lingrove_cli" vocab list --query 'bank' --language en --limit 20 --offset 0
"$lingrove_cli" vocab get ENTRY_UUID
```

Search before saving. List entries use `entryID`/`senseID`; full `get` results use `entry.id` and
`entry.senses[].id`. Summaries may be truncated; get the entry before selecting a sense or reusing
its text. Paginate while offset is below `result.total`; list limits are 1–200.

| Intent | Interface |
| --- | --- |
| Save expressions, examples, meaning nodes and their categories together | **One `vocab capture` task**; read [capture.md](references/capture.md). |
| Append examples/content or replace a saved meaning, note or tags | `vocab apply`; read [batches.md](references/batches.md). |
| Resolve interpretations, manage collection membership or organize semantic links | `data list/get` and resource `put`/`delete`; read [organization.md](references/organization.md). |
| Only classify an existing node, or edit category definitions/hierarchy | Read [classification.md](references/classification.md); use resource operations. |

For an ordinary “save and classify this expression” request:

1. Search the expression; get a matching entry only when choosing an existing sense.
2. Search relevant `nodes` and `categories` with `data list ... --query TEXT --summary --limit 10`.
   CLI 4 provides summary output; inspect `--help` once if its availability is unknown.
   Read a shortlisted category's full record only to distinguish its scope from alternatives.
3. Put nodes in `meanings`, classification keys in each meaning's `categories`, and sense-to-node
   links in `associations`. A single capture generates IDs and persists all of them atomically.
4. Preview, commit the identical file, and inspect the returned IDs and category receipts.

Do not expand this into separate `nodes`, `mappings` and `categoryMemberships` writes or read
all resource manuals. Those interfaces serve independent edits. Search is substring matching,
not semantic retrieval; try a focused paraphrase or broader topic if a query has no matches.
Stop searching when an existing meaning/category fits the intended context; do not enumerate
the whole directory to prove a globally optimal classification.

A new sense is always distinct; definitions do not merge by similarity. Extend an exact existing
sense ID when it matches the intended meaning. Preserve source expression/context and distinguish
a sense definition, contextual meaning and full-sentence translation. Do not invent source text;
mark requested illustrative model-written examples as generated.

Optional fields should add distinct information: usage notes describe syntax/register, association
nuance distinguishes alternatives, and conditions state actual applicability restrictions. Omit
redundant or generic filler. Agent semantic assertions retain model authorship and default to
active adoption; `confirmed` does not claim human review. Use proposed/candidate states for
uncertain readings or requested alternatives.

## Save and verify

Prepare one JSON file with a fresh idempotency key for the intended change. Use a JSON serializer
or quoted heredoc to preserve learning text without shell substitution. Preview using
`vocab capture --file PATH --dry-run` or `vocab apply --file PATH --dry-run`, inspect the result,
then complete the authorized write with the identical file and key without `--dry-run`.
Do not stop at preview when the user requested saving. General discussion does not authorize edits.

Inspect `ok`, `result.dryRun`, `result.replayed` and `result.operations`. A fresh save has
`ok: true`, `dryRun: false`. Report the material saved and any limitation. Read affected records
when needed to confirm their current state; a replay only acknowledges an earlier write.
Capture meaning receipts include category IDs/keys, membership IDs and whether they were created;
`summary.categoryMembershipCount` counts newly added memberships. Use those receipts to confirm
classification instead of rereading every generated relationship.

Each write is atomic. Resource writes and sense updates require the current notebook revision;
capture may optionally guard one. On a definitive conflict, reread and reconcile before preparing
a revised write. On busy/timeout, retry unchanged, at most twice more. A timeout may already have
committed: preserve the same key, material and image bytes. Never use a fresh key for an uncertain
retry. For other failures, inspect `error.code` and the message; payload and recovery details are
in [batches.md](references/batches.md).

## Stop on a client/app mismatch

If input validation rejects `notebookScope` but the app requires it, stop write attempts. Do not
remove scope, switch batch versions, or create replacement senses to bypass the error. This is
an incompatible client/app combination until demonstrated otherwise.

Compare the resolved executable, its `--version` and schema with the server identity from a
successful read. Older CLIs may report the same version despite different schemas and may not
return server identity. `--app` on an old client is not proof of which instance serves requests.
Use the selected running app's own `Contents/Helpers/lingrove` and keep that destination fixed;
installation/update is under Settings → General → Command-line tools. If installation reports
another command, inspect the link and report the conflict rather than deleting an unknown file.
After a confirmed version repair, reread the notebook and rebuild the draft from that scope.
Do not promise that changing a symlink alone resolves an unexplained later failure.
