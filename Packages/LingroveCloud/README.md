# LingroveCloud

Foundation-only account and authorized notebook networking for native Mac and iOS. The package
imports the existing `LingroveNotebook` / `LingroveNotebookSync` values and codecs. It has no
SwiftUI, UIKit, SQLite, Card/FSRS, `FlashcardsStore`, default endpoint, guest creation, telemetry,
Keychain entitlement, Bundle lookup, or implicit connection on initialization.

## Ownership and data flow

`AccountSession` is a process-lifetime `@MainActor` state machine. A host supplies explicit
API/auth configuration, `AccountAuthenticating`, private `AccountCredentialStoring`, and nonsecret
`AccountConfigurationStoring`. The synchronous save/clear seam lets a generation check and a
Keychain write complete without suspension. `AccountAPIClient` implements the fixed native OTP,
refresh and authenticated `/me` protocol. Only `/me.userId` confirms the business owner; JWT
subject is never parsed. Pending credentials and rotated refresh tokens are saved before the next
network wait. Recovery/refresh callers share one flight; individual waiter cancellation does not
cancel another consumer. Logout, service change, cancel and shutdown retire in-flight work.

The host observes safe state through `onChange`. Mac's existing `AccountSessionService` is the
Combine facade; its existing private Keychain and UserDefaults adapters remain local. The visible
connection draft still uses `AccountConfigurationPolicy.matchesSavedConnection`. No secret can be
saved through the nonsecret configuration port, and there is no plaintext credential fallback.

`NotebookSyncCoordinator` is the app-owned single-flight and retry-report owner. Constructing an
account value does not authorize synchronization; the host calls `synchronize` only after the
user's explicit enable/adoption decisions. The value contains a trusted business owner, selected
workspace, endpoint and authorization header, plus the unchanged connect automation/distribution
flags. The host owns credentials and refresh: HTTP 401/410 propagate to its account recovery seam.
Call `cancel()` and advance the repository's durable generation on logout, workspace/account
replacement or shutdown. An individual cancelled waiter leaves the shared flight intact.

The runner captures a `NotebookBinding` before capability/connect requests and checks it after
suspensions. A binding consists of the existing NotebookSync owner/workspace/notebook/replica
scope plus the host's durable generation. Owner comparisons are literal UTF-8 bytes. Capturing an
unknown book/replica before connect uses placeholders only; storage must never adopt those IDs.
The canonical connect result is checked against the authorized owner/workspace before use.

## Storage ports and transaction obligations

The package never opens a database. The host must implement the three ports against its single
primary repository, validating the supplied binding **inside every transaction**, not merely in an
async preflight. Borrow a connection for each stage and release it before HTTP waiting. Temporary
connections to the same protected file are allowed; a second database or scheduler is not.

| Port | Stages and obligations |
| --- | --- |
| `NotebookStorage` | installation/capture/validate; initial/state/ownership/sequence/conflict; next/existing/control; exact outcome/confirmation/closure recording; captured retry authorization; window begin/receive/discard/references/apply |
| `NotebookMediaStorage` | durable enqueue/pin, revision-CAS claim/check, owned validated PNG, complete/fail/available, release/prune/remote-release ACK |
| `NotebookReviewStorage` | canonical bounded request encoding; response scope/clock validation and exact ACK application; independent durable review cursor |

`NotebookPendingUpload` is a projection of a repository-restored planner batch plus its exact frozen
public bytes and settlement progress. The host must validate the batch against its confirmed
baseline, frozen digest and journal coverage before exposing it. Coverage itself stays private in
the repository, addressed by `frozenSHA256`; do not regenerate bodies or IDs on network failure.
`record` does not retire the journal. Positive ACK retirement belongs to a verified covering window
apply, and must remove only operations captured by the frozen batch. Negative/staged closure keeps
local intent. `existing` must return the same frozen identity with current cancellation/progress.

Normal and staged upload use the same prior protocol. One pass settles at most one frozen group.
Staged status/open/chunk/finalize/confirmation-page keep the original chunk/member/body budgets,
check per-chunk cancellation, save a known terminal decision before cleanup, and verify complete
confirmation before returning an outcome. Windows use the existing canonical manifest/page codecs;
storage verifies/assembles them, prepares rebase outside its write lock and applies atomically.
After settlement a stale lease is released before opening a fresh canonical window. Cache release
debt is reported separately from already committed data.

Media upload finishes before corpus apply. Download jobs pin validated bytes until window apply
commits, then release local pins and acknowledge remote cleanup. `NotebookMediaTransfers` is an
injected process-lifetime cancellation registry; share it with user Cancel controls. Storage's
attempt revision wins over a late HTTP callback, including when task cancellation cannot undo
bytes already accepted remotely. A cancelled queue job never gains authorization merely because
owned bytes exist. The host captures durable queue retry intent before `requestRetry`; that call
only clears the in-memory report gate and supplies exact captured upload authorization.

Review runs only when corpus work is settled. `NotebookReviewRequest` accepts already encoded,
canonical byte-admitted Data (at most 7 MiB), cursor and a `hasWork` flag covering **all** held work,
including history adoptions. This package deliberately does not duplicate the review wire codec.
`apply` receives the exact sent request and bounded response (8 MiB), validates/decodes in the host,
then commits exact ACK and cursor together; return the validated response's `hasMore`. Sixteen
pages bound a pass. Review failure preserves the successful corpus revision and its own cursor,
and is reported through `reviewStatus`, not disguised as corpus failure.

Reports retain original classifications/backoff: media pending 10s; offline/failure 30s; unavailable
300s; ownership/rejection/conflict until explicit Retry or relevant local revision change. `requestRetry`
captures a new attempt epoch so an older failure cannot reinstall the gate the user just cleared.
Durable retry/cancel versions and idempotent frozen/outcome identities remain repository truth.

## Transport and host integration

`BoundedHTTPClient` owns an immutable ephemeral URLSession by default. Every request disables
cookies/cache, refuses redirects via a per-task delegate, cancels its stream on completion/overflow,
and caps both declared and accumulated decompressed bytes. Injection is for host/test transport
configuration; it does not bypass the per-request redirect fence. Endpoints allow HTTPS or explicit
loopback HTTP and reject embedded credentials, query, fragment, encoded/traversing base paths.
Corpus uses the same `/workspaces/{id}/notebook/*` paths, feature header, connect fields and byte
budgets; media remains on the notebook origin, never a persisted signed URL.

Mac `project.yml` and the generated project reference this product. The mobile auth/email facade
uses the shared bounded transport while retaining its successful-email hint and fixed error mapping;
Apple/Google provider and account-method flows are unchanged. Corpus/media mobile transports are
thin value/error adapters over this implementation. Mobile project package references are owned by
the integration checkpoint. The existing mobile storage IO and orchestration remain host-side until
that checkpoint bridges the three ports to the extracted engine. This package does not depend on
an in-progress engine package or claim that Mac sync lifecycle is already wired into AppEnvironment.

## Validation

From the repository root, with the shared Apple validation flock held:

```sh
swift test --package-path Packages/LingroveCloud --scratch-path build/cloud-scratch
```

`CloudBoundaryTests` starts its own synthetic Python HTTP peer on an available port in 19180–19182,
uses real URLSession for OTP/refresh/me/corpus/staged/window/media/review, and recording storage
ports for phase/ACK/pin/generation assertions. It does not contact a provider, email address,
production service, PostgreSQL or a running app. The canonical wire codecs validate the emitted
pages/receipts; SQLite, rebase and FSRS remain engine/combined-checkpoint responsibilities.
See the module delivery report for actual executed evidence and cleanup.

## Provenance

Account policy/session behavior is extracted from the native Lingrove account checkpoint
`9351fd93b697a145ded9ded6bb008420b864b5d8`. Notebook/media/staged/review orchestration and wire
transport are extracted from the same checkpoint's `Nibomo/apps/ios/Flashcards/Flashcards/Cloud`.
The public seam removes host persistence/UI coupling; it does not change server protocols or
production feature gates. Lingrove-derived files remain under the repository's AGPL-3.0 license.
The upstream Nibomo portions originate under Kirill Markin's MIT license; its full notice is
retained in `UPSTREAM-MIT-LICENSE`. No FSRS implementation is copied into this package.
