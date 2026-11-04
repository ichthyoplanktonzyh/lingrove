# Documentation map

Use this map to find the owner of a question. Source code and tests are the final authority for
implemented behavior; descriptions of design intent and validation are not proof of deployment.

| Question | Maintained source |
| --- | --- |
| Product rules and cross-platform responsibilities | [PRODUCT_MODEL.md](PRODUCT_MODEL.md), [CONTEXT.md](../CONTEXT.md) |
| Mac ownership and UI | [MAC_WORKSPACE.md](MAC_WORKSPACE.md), [MAC_UI_SYSTEM.md](MAC_UI_SYSTEM.md) |
| Review Notes, templates, and Anki | [REVIEW_TEMPLATE_DESIGN.md](REVIEW_TEMPLATE_DESIGN.md), [ANKI_NOTE_SYNC.md](ANKI_NOTE_SYNC.md) |
| Sync contract and repository ownership | [NOTEBOOK_SYNC_CONTRACT.md](NOTEBOOK_SYNC_CONTRACT.md), [REPOSITORY_BOUNDARIES.md](REPOSITORY_BOUNDARIES.md), [ADRs](adr/) |
| Runtime and source placement | [ARCHITECTURE.md](../ARCHITECTURE.md), [SOURCE_LAYOUT.md](../SOURCE_LAYOUT.md) |
| Build, testing, CLI, releases | [CONTRIBUTING.md](../CONTRIBUTING.md), [CLI.md](../CLI.md), [RELEASING.md](../RELEASING.md) |
| Autocomplete evaluation | [MODEL_EVAL.md](../MODEL_EVAL.md), [PHRASE_EVAL.md](../PHRASE_EVAL.md), [SUPPORTED_MODEL_EVAL.md](../SUPPORTED_MODEL_EVAL.md) |
| Language learning behavior | [LANGUAGE_LEARNING.md](LANGUAGE_LEARNING.md) |
| Origin, third-party licenses, and UI provenance | [FORK.md](../FORK.md), [THIRD_PARTY_LICENSES.md](../THIRD_PARTY_LICENSES.md), [review/account UI sources](MAC_REVIEW_ACCOUNT_UI_REUSE.md), [Progress UI sources](MAC_PROGRESS_UI_REUSE.md) |
| Mobile/backend testing and deployment | The [independent mobile repository](REPOSITORY_BOUNDARIES.md); [test environment plan](LINGROVE_TEST_ENVIRONMENT.md) is historical planning and must be rechecked there |

`benchmarks/` contains datasets, reports and historical evidence. Some historical learning-expression
commands apply only to the revision named in its README, and old absolute `build/` paths are not
portable or guaranteed to exist. [Historical planning files](../benchmarks/phrase-prediction/planning/) are not active instructions. Completed
checkpoint reports removed from the working tree remain in Git history. Do not remove license,
source attribution, reproducibility evidence, or unresolved validation boundaries as process noise.
