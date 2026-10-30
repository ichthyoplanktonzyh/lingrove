# Vocabulary search relevance

The notebook searches for collected senses that express the user's intended meaning. Returning
the nearest eight vectors unconditionally makes unrelated collections look like answers. Admission
now happens before reciprocal rank fusion; the fusion weight only orders admitted candidates.

## Rules and ownership

- `VocabularySearchPolicy` builds bounded meaning material and matches literal whole-word phrases
  within one field. An exact expression remains retrievable even with a weak or absent vector.
  Source sentences and personal notes cannot admit a hit; an accepted contextual interpretation
  remains a definition. Tokens scattered across fields cannot manufacture a phrase match. In hybrid
  search a substring inside a longer definition only boosts an already admitted vector: a comparison
  such as "加快进程；与推迟不同" cannot bypass the gate on the word "推迟". Headword phrases
  and exact definitions/cues remain independent routes; keyword-only fallback retains phrase lookup.
- `VocabularySearchRelevancePolicy` admits finite normalized cosine scores at least **0.48**, and
  at most **0.04** below the best score in the current language/tag scope. These numbers belong to
  this model and material format, not to embeddings generally or to a probability scale.
- `VocabularySearchIndex` owns native computation and cache lifetime. The controller passes only
  the scoped documents; it no longer passes raw entries through a separate broad keyword route.
  Existing material hashes remain valid because the embedding payload and query instruction did
  not change. No additional model or user step was introduced.

## Calibration and validation

Model: official Qwen3 Embedding 0.6B Q8_0, revision
`370f27d7550e0def9b39c1f16d3fbaa13aa67728`, LAST pooling, normalized 1024-dimensional vectors,
llama.cpp b9310 through the production `CotabbyEmbeddingEngine`. Measured on 2026-10-30.

The synthetic, manually labeled [corpus](../../LingroveTests/Fixtures/vocabulary-search-relevance.json)
contains 24 senses and 43 queries: 22 calibration cases and 21 validation cases. Queries cover
Chinese, English, Japanese, French, Arabic, Hindi, German and Spanish. Thirty-one cases have an
answer; twelve have none, including pools from which the intended answer was deliberately removed.
Labels include close but wrong meanings (earlier/later, accept/reject, lend/borrow, rule in/out).
This is a small regression corpus, not an estimate of real-world user accuracy.

The existing model suite separately checks recall into each of the 14 study languages using
six query languages, plus an unrelated query in every study-language scope. A 0.60 floor rejected
several correct cross-language results; the weakest
correct first result in those controls was approximately 0.481. A 0.48 floor retains those controls.
The narrower 0.04 gap improves precision on the calibration cases while retaining several close
alternatives where the model supports them. A larger gap of 0.08 admitted more wrong neighbors.
The validation cases are reported separately, not used to raise the floor for English-only scores.

The native probe used exactly the production engine, material and query prefix for the before/after
comparison. App-hosted Swift tests then exercised the final production index and policy directly,
matching the counts below. The final targeted app-hosted run passed 124 tests with one existing optional
case skipped; both real-model search suites ran. This follow-up used Debug for policy/UI assertions;
the installed Dev app is built in Release, and no Debug latency is reported. All 14 positive study-language controls and all
14 unrelated scope controls passed.

| Measurement | Previous top-eight search | Admission + fusion |
| --- | ---: | ---: |
| Calibration: relevant returned / all returned | 26 / 169 (15.4%) | 19 / 26 (73.1%) |
| Validation: relevant returned / all returned | 16 / 161 (9.9%) | 14 / 20 (70.0%) |
| Calibration: positive queries retaining an answer | 17 / 17 | 16 / 17 |
| Validation: positive queries retaining an answer | 14 / 14 | 14 / 14 |
| Calibration: absent answers returning empty | 0 / 5 | 3 / 5 |
| Validation: absent answers returning empty | 0 / 7 | 5 / 7 |
| Fully unrelated queries returning empty, both splits | 0 / 8 | 8 / 8 |

First-result correctness is unchanged (28 of 31 positive queries). Filtering prevents the long
irrelevant tail; it does not improve the embedding model's interpretation of every query.

Final Release Dev UI checks also passed: unrelated-query abstention, a natural paraphrase, direct
expression lookup, and exclusion of an opposite mentioned only inside a definition. Header counts
matched the displayed hits. The installed app was signature-verified and its binary timestamp
advanced; repo-scoped DerivedData and staging directories were removed after installation.

## Known limitations

The model sometimes embeds opposites close together. "Do it earlier than planned" can still
retrieve postponement, and a query asking to retain possibilities can rank "rule out" above
"rule in". When postponement is absent, cancellation can still qualify. The lower multilingual
floor deliberately preserves recall, so these related false positives remain in the corpus and
test budgets. A universal high threshold cannot resolve them without losing legitimate languages.

The ambiguous "这事先不拍板，明天再想" no longer returns "sleep on it" in the full pool: its
score is below the strongest postponement candidate by more than the admitted gap. That miss is
retained in the labeled corpus. The explicit overnight-decision query remains a positive control.
This rule does not parse negation in definitions. A literal mention inside a longer definition
requires semantic admission when vectors are available, preventing that weak match from bypassing
the threshold. Keyword-only fallback can still return such mentions, and an incorrect exact cue
can still admit a wrong answer. The removed broad route specifically stops incidental matches
from notes, full examples, translations and unrelated explanation fields.

## Re-running

Use the normal Release `build-for-testing` workflow in `CONTRIBUTING.md`, always with
`-derivedDataPath build/DerivedData`. Add `LINGROVE_SEARCH_MODEL_PATH` to the generated xctestrun's
`LingroveTests.EnvironmentVariables`, pointing to the already downloaded model. Optionally add
`LINGROVE_SEARCH_RELEVANCE_REPORT` with an absolute JSON output path. Select
`VocabularySearchRelevanceTests` and `VocabularySearchTests` with `test-without-building`.
The former records every returned ID and per-split counts; the latter checks all 14 study languages,
cache reuse and deletion. Neither reads the user's collection or modifies the downloaded weights.

Ordinary CI runs `VocabularySearchPolicyTests` without a model: low-score/invalid-vector rejection,
threshold boundary, scoped best-score calculation, tail trimming, exact lookup, field boundaries,
and exclusion of notes and source sentences. Clean `build/DerivedData` after validation.
