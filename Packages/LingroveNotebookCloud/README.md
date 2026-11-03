# Lingrove notebook cloud integration

This package joins the portable SQLite engine to the portable cloud ports. It imports both;
neither lower package imports the other. Native Mac and mobile therefore use the same adapters
instead of duplicating SQL, canonical review decoding or sync orchestration in each app.

`NotebookEngineStorage` is owned by the native application's repository (or by a mobile caller
beside its existing borrowed engine). It implements `NotebookStorage`, `NotebookMediaStorage`
and `NotebookReviewStorage`. The primary engine supplies lifetime/capture checks. Background
stages receive only explicit database/media URLs and immutable values, open a temporary owning
engine on that **same file**, and close before returning. No native handle or non-Sendable engine
crosses an actor boundary. No transaction remains open across HTTP. The storage operation itself
still checks durable generation/CAS in its transaction; async preflight is not authorization.

| Flow | Owner and invariant |
| --- | --- |
| Corpus metadata | `LingroveNotebookEngine.notebookSyncState` reads snapshot, journals and cancellation/rejection flags consistently |
| Frozen uploads | Restore private coverage from SQLite by frozen digest and verify exact body bytes; the network projection cannot acknowledge arbitrary local writes |
| Windows/staging/ACK | Forward the existing engine prepare, receipt, confirmation and atomic apply commands; never rebuild a second rebase or journal |
| Media | Preserve pin/consumer, job revision/attempt and cancellation identities; engine validates PNG/digests and workspace ownership |
| Review | Encode the existing canonical request once, preserve those bytes across HTTP, decode the canonical reply and exact-ACK it with the original binding |
| Retry | Capture only existing cancellation/rejection revisions; a click cannot authorize a later cancellation or another generation |
| Lifecycle | Validate the original primary connection before/after each stage; a closed or changed original owner cannot silently continue using a fresh handle |

`NotebookAccount.isGuest` preserves the existing mobile authorization kind while installation
metadata is bound. It does not create a guest; native Mac uses bearer accounts. No token is saved
by this adapter. Account login, workspace metadata, user consent, timers, UI and production gates
belong to the host, not this package.

Mobile's `LingroveNotebookNetworkRunner` and `LingroveNotebookReviewNetworkRunner` now delegate
to the public runners through these ports. Its existing CloudSessionRuntime keeps app lifetime
and recovery orchestration. Cancel controls and shared runner borrow the same media-transfer
registry. The native `MacNotebookRepository` exposes one engine/adapter pair for its corpus, sync and review consumers.

`EngineCloudIntegrationTests` executes actual SQLite + canonical codec/ports, exact ACK with a
later rating, persistence/reopen, generation ABA, primary close and guest-kind retention. The
combined native HTTP/PostgreSQL check uses the production mobile wrapper with this package;
its executed evidence is recorded separately in `docs/MAC_WORKSPACE.md`.

The adapter derives from Lingrove and the existing Nibomo storage IO at checkpoint `9351fd93`.
Lingrove additions use the repository license; the original upstream MIT notice is retained in
`UPSTREAM-MIT-LICENSE`. No new endpoint, guest bootstrap, telemetry or production switch is added.

The review adapter also preserves the engine's version-2 material/media envelope and counts its
pending resource messages as work. The existing runner transports the exact bounded body and
cannot report settlement until the engine has validated version, exact digest ACKs and operation
ACKs. Old servers leave rich material pending with a protocol failure. The backend adoption and
unverified real-server boundary are documented in `../LingroveNotebookEngine/README.md`.
