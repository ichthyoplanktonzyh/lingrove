# Legacy schema 5 SQLite fixture

`schema5-synthetic.sqlite` was created by running the checkpoint's original
`VocabularySQLiteDatabase.write` implementation in an isolated `swiftc` harness, then reopened
and checked by the original `VocabularySQLiteDatabase.read` and `receipt` methods. It is a real
SQLite file with the Lingrove application ID, `user_version=5`, and revision 1. The v9 fixture
retains those records and omits the retired example-selection rows.

The fixture contains only synthetic material: one ambiguous English headword with two senses, two
source snapshots and occurrences, two accepted interpretations and collection records, two meaning
nodes with mappings, one valid classification framework/category/membership, one review card, and one
CLI receipt. All IDs and text were invented for this fixture; there is no user data or credential.

The adjacent `schema5-synthetic-source-sha256.txt` records the SHA-256 of every frozen checkpoint
source used by the oracle. The generated executable, compile-only shims, full frozen source copies,
and run output remain under the ignored `build/notebook-storage-baseline/` directory.

`document-v9-codec.json` is the fixed synthetic graph with personal fields stored on senses.
The storage tests complete its category and evidence references in memory before checking the
full row projection.
