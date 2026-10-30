# Notebook compatibility fixtures

The complete-document JSON fixtures were encoded from Lingrove's declarations at commit
`c66fb60b6fa76cf5b4483d0e0ab2d7a11cbf09b9`, before the document graph moved into this package.
An independent encoder compiled the original model and projection files, adding only compilation
shims for `VocabularyError`, `LanguageCatalog` and `SpeechExportAudio`. It did not change their
stored fields, Codable implementations or projection logic. The old decoder also read the
generated output before the new package tests were attached.

`document-v8.json` contains two meanings of one expression, Unicode source ranges, competing
interpretations, independent collection state, saved explanations, content/media references,
semantic and classification relationships, and local review bindings/audio receipts.
`document-v7-missing-classification.json` exercises the existing version upgrade and absent
optional templates. `category-guidance-absent.json` exercises the category decoder's historical
default handling.

Do not regenerate these fixtures with the current encoder: that would remove the independent
historical oracle. The frozen sources, generator and SHA checks for this extraction are retained
under the ignored `build/notebook-domain-baseline/` directory. The fixtures themselves are tracked
and copied as SwiftPM test resources, so tests use `Bundle.module` rather than an absolute source
path. Only known unordered review dictionaries and sets are normalized during comparison;
ordered evidence, labels, relations and content must retain their order.
