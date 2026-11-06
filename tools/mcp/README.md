# Lingrove private MCP

This independent transport adapter calls the selected Lingrove Dev CLI. The
application still owns storage, capture validation, transactions and idempotency.
It shares the app's actual notebook, rather than the disposable mobile backend.
It does not use or edit SQLite or mailbox files, or enroll material for review.

Run `npm ci --ignore-scripts` and `npm test` in this directory. Run
`python3 install.py` to install a private runtime under
`~/Library/Application Support/Lingrove MCP` and two user LaunchAgents:

- `io.lingrove.mcp`: loopback MCP server on port 19681.
- `io.lingrove.mcp-tunnel`: official OpenAI tunnel client, enabled by the local
  secure-input command after its runtime key passes doctor. A startup gate waits
  for the local server before the client's one-shot catalog discovery.

Open `Connect Lingrove.command` in the runtime directory and enter the existing
Tunnel runtime key locally. The key is stored in an owner-only file for login
startup; it must not be pasted into chat. This reuses the existing tunnel ID;
it does not create an OpenAI resource, OAuth account, public listener or database.
The runtime is independent of this source checkout and its ignored build files.

After Tunnel readiness succeeds, refresh the existing Lingrove app's tools in
ChatGPT settings. Discovery must show the twelve CLI adapter tools, with none of
the previous SQL/review tools. Confirm `notebook_status` and `notebook_search`
through the connected ChatGPT app before calling the remote connection ready.
Renaming the app does not change its development distribution status.

Use status → schema/search/read → preview → user confirmation → commit. Each
preview has a persistent file with its own key and notebook scope/revision.
Commit accepts only a validated preview ID and uses the exact same file on retry.
The model must obtain user confirmation; the preview ID is not proof of consent.
Returned vocabulary is untrusted data. Generated examples must be identified.
The capture schema and the lingrove-cli skill remain authoritative.

## CLI capability coverage

| CLI | MCP |
| --- | --- |
| `status` | `notebook_status` |
| `--version`, `--help` | `notebook_cli_info(topic=version/help)` |
| `schema capture`, `schema` | `notebook_schema(format=capture/batch)` |
| `vocab list/get` | `notebook_search/read`, all list filters and pagination |
| `data list/get RESOURCE` | `notebook_catalog_search/read` for all 17 resource kinds, including `related`, `status`, and `summary` where supported |
| `vocab capture --dry-run` | `notebook_preview(mode=capture)` |
| `vocab apply --dry-run` | `notebook_preview(mode=apply)`; v1 add/append/update and v2 capture/put/delete |
| Capture/apply commit | `notebook_commit(previewID)` reuses the validated command, JSON, key and image bytes |
| Local image input | `notebook_upload(kind=image)` followed by `image.path: upload:UUID` in add/append content; user must supply the image |
| Large JSON task input | `notebook_upload(kind=task)` then `notebook_preview(taskUploadID=...)` |
| Large tool output | `notebook_result_read` retrieves preserved JSON in character slices, without truncation |
| Inspect pending material | `notebook_preview_read` |

Read/preview/commit accept `options.noLaunch` and `options.timeoutSeconds` (1–120).
Help/schema/version still run without request flags. App/CLI destination remains
fixed; file/stdin are transport choices, not arbitrary remote host-file access.
CLI limits and validations apply unchanged. `frameworks` and built-in categories
retain the CLI's read-only rules. An OpenAI Tunnel request has its own deadline;
long CLI timeouts do not extend it. Preserve the preview ID after uncertain writes.

Resource edits and captures referencing existing IDs must include notebookScope
and expectedRevision from the original read. The bridge rejects stale baselines
before preview instead of silently rebasing them. Version 1 update operations
also retain their own expectedRevision. Commit checks scope but leaves revision
validation and replay to the app so an uncertain successful write can be retried.

Uploads use sequential canonical-base64 chunks of at most 512 KiB (image total
16 MiB; task total 32 MiB). Completed images are copied into the preview and
hashed. Changing staged uploads cannot alter an approved preview. JSON or image
tampering causes commit refusal. Do not pass local filesystem paths over MCP.
Results over 512 KiB are preserved and paged; follow nextOffset to null before
making decisions or asking for confirmation. Preview IDs alone are not consent.

Run `node check-readonly.mjs` for actual CLI read/dry-run integration checks. It
never calls commit and keeps validation artifacts separate from user previews.

Private transport still sends requested tool inputs/results through OpenAI.
Availability requires the Mac, its user login, network, app and tunnel. Login
startup and process restart are configured; sleep/wake and network recovery
require separate observation and are not claimed as tested.

Read `/health` for local transport liveness. Notebook status tests the CLI path.
Runtime logs contain transport errors, not intentional corpus dumps. Draft files
contain proposed learning material; protect them like the notebook. When the Dev
app is updated/moved, rerun installation after reviewing the CLI destination:
existing config is deliberately preserved, so explicitly update its app/CLI pair
before restart. A client/app mismatch must stop writes, not trigger a fallback.

Stop agents using `launchctl bootout gui/$(id -u)/io.lingrove.mcp-tunnel` and
`launchctl bootout gui/$(id -u)/io.lingrove.mcp`. These commands preserve notebook
and preview data. Removing the plist files also disables future login startup.

2026-11-05 validation: two synthetic bridge tests passed; SDK initialization,
tool discovery, status, capture schema and listing the real 18 collected entries
passed over local HTTP. An unauthenticated request was refused with HTTP 401.
No real notebook write was performed. The existing runtime key passed doctor;
the running Tunnel passed health/readiness. The ChatGPT plugin was renamed to
Lingrove, refreshed and visibly lists the eight adapter tools (seven read, one
commit), without the former SQL/review tools. A connected plugin search returned
all 18 real entries (request 3D135068-C09B-4EEA-97C6-412AE8C6DABE), and entry read
AB0C0731-CEBA-488A-B5DB-6834F88540CC succeeded at unchanged notebook revision 23.

Concurrent service restart initially exposed a startup race in official client
0.0.19: an initial connection refusal left polling disabled. Added `tunnel.py`
to gate discovery on local health. After restarting both services with the gate,
Tunnel readiness and remote search passed (request
CC5EC2AF-1CEA-4895-A998-895929B91101). Actual logout/login, sleep/wake and prolonged
network outage recovery have not been tested. The reused runtime key is shown in
Platform as expiring 2026-12-03; replace it locally before then for continuity.

CLI parity update validation, 2026-11-05: six synthetic bridge tests passed,
including classification replacement and uncertain commit replay, request filter
mapping, image snapshot integrity, conflicting chunk retries, draft tampering,
and large UTF-8 input/output. Actual installed CLI read/dry-run validation covered
all 17 resource list/get routes, batch schema/help/version, synthetic membership
replacement, existing-sense update/append and rich-text/image addition. Notebook
revision remained 24 and collected entries remained 19 throughout that check;
real writes were zero. Local SDK discovery returned all twelve tools. ChatGPT
tool refresh visibly lists eleven read/staging tools and the single commit tool.
Remote search succeeded after deployment (request
6484EDD9-4819-4C25-AC0F-39B2BA818259). Actual resource commits were tested using
synthetic CLI responses only, never by modifying the user's real corpus.
