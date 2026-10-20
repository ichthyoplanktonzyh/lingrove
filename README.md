# Lingrove · 拾语

<p align="center">
  <img src=".github/assets/readme/logo.png" width="112" alt="Lingrove whale logo">
</p>

Inline autocomplete and language learning, wherever you write. Get continuations beside your
cursor, translate sentences, and learn useful expressions without leaving your editor.

Lingrove is an open-source macOS menu bar app maintained by
[ichthyoplanktonzyh](https://github.com/ichthyoplanktonzyh), derived from
[FuJacob/Cotabby](https://github.com/FuJacob/cotabby) and its contributors. Inline autocomplete and
language learning are its two core capabilities, developed together.

> **In development.** Lingrove V0.5 is being developed on this repository's `main` branch.
> Independent production releases and automatic updates are not yet available.

[Source](https://github.com/ichthyoplanktonzyh/lingrove) ·
[Feedback](https://github.com/ichthyoplanktonzyh/lingrove/issues) ·
[Releases](https://github.com/ichthyoplanktonzyh/lingrove/releases) ·
[FAQ](FAQ.md) · [AGPLv3 license](LICENSE)

## Two core capabilities

### Inline autocomplete

- **Ghost-text continuations:** receive suggestions beside the cursor in supported macOS fields;
  accept a word, phrase, or whole suggestion with your configured shortcuts.
- **Choice of backend:** use Apple Intelligence, in-process local GGUF inference, or an
  OpenAI-compatible endpoint you configure.
- **Context and control:** choose suggestion length, within-word prediction, streaming, and
  optional screen/clipboard context. Pause globally or disable it for specific apps.

### Language learning

- **Translation beside your text:** translate a completed sentence or a paused draft into your
  chosen language while continuing to write in the same field.
- **Sentence understanding:** identify reusable expressions through offline lexical recognition
  and request contextual AI explanations for words, expressions, or sentences.
- **Expression and word lookup:** inspect an expression or word using the bundled expression
  lexicon and the dictionaries enabled on your Mac.
- **Independent learning models:** configure translation and AI explanation separately, using
  local models or endpoints you explicitly choose.
- **Vocabulary notebook:** save expressions with their example sentences from the fish-tail button,
  then search, edit, listen to, or export the collection from the menu bar's Vocabulary window.
  Expressions group stable senses, and each sense owns its usages and notes. Merge senses or move
  a usage explicitly; regenerating an explanation never changes its identity.

### Additional writing tools

Autocorrect, emoji insertion, and slash macros for calculations/conversions complement both core
capabilities.

The menu bar controls global pause and opens Settings. Configure source/target languages and
learning models in Settings before enabling language learning. Tab and Return keep their ordinary
behavior in the learning card; Escape dismisses it. Autocomplete's acceptance keys are configurable.

## Privacy and local storage

- Apple Intelligence and local GGUF inference run on your Mac. Translation and AI explanation can also
  run locally once their models are installed.
- An explicitly configured endpoint receives the request for its task, which can include typed
  text and enabled context. Autocomplete and learning tasks have their own model/server settings;
  use the local path when you want that task to remain on-device.
- Screenshots and OCR run on-device. If screen context is enabled for endpoint autocomplete, its
  bounded text excerpt can be included in that endpoint request.
- Input-history recording is off by default. When enabled, the recorded text is stored in an
  encrypted archive on this Mac with its key in Keychain. You can clear the history in Settings.
- Developer mode (`-cotabby-debug`) can write full model inputs/outputs to local diagnostic logs.
  Model download/search uses the network. Automatic app updates remain disabled until independent
  update infrastructure is configured; the manual update action opens this project's Releases page.
- There is no hosted account requirement, analytics, or remote crash reporting built into the app.

Lingrove and Lingrove Dev use separate preferences, Keychain services, model/history folders, and
logs. Existing Cotabby data is preserved and is not imported automatically. See [FORK.md](FORK.md).

## Install and develop

Requires macOS 14 or later. Apple Silicon is recommended for local inference. Autocomplete can use
Apple Intelligence on supported Macs with macOS 26 or later, an installed local GGUF model, or an
OpenAI-compatible endpoint. Translation and AI explanation use their separately configured learning models.

There is no Lingrove Homebrew cask or independent production download established yet. Follow
[this repository's Releases](https://github.com/ichthyoplanktonzyh/lingrove/releases) for future builds.
Download the v0.5.1 test DMG from the [v0.5.1-test.1 prerelease](https://github.com/ichthyoplanktonzyh/lingrove/releases/tag/v0.5.1-test.1).
This is an ad-hoc-signed, unnotarized test build with manual updates. Follow the
[Simplified Chinese install guide](assets/testing/INSTALL.zh-CN.txt), included in the DMG as `INSTALL.txt`.
Ordinary installation only needs the DMG; checksum verification is optional and no terminal is required.
To build from source:

```sh
git clone https://github.com/ichthyoplanktonzyh/lingrove.git
cd lingrove
scripts/dev-setup.sh
scripts/prepare_cotabby_workspace.sh
open build/cotabby-dependencies/Cotabby.xcworkspace
```

Select **Cotabby Dev** in Xcode; this internal scheme builds **Lingrove Dev.app**. Production uses
the **Cotabby** scheme and produces **Lingrove.app**. Internal module and source-folder names stay
unchanged during the product migration. Local signing uses your own team in the gitignored xcconfig.
See [CONTRIBUTING.md](CONTRIBUTING.md) for build/test instructions and [RELEASING.md](RELEASING.md)
for the independent update plan.

## Permissions

Grant Accessibility and Input Monitoring for text access, typing detection, and insertion.
Screen Recording is needed for screenshot-based context, explicit region OCR, and pointer lookup OCR fallback. Generation and insertion remain blocked
in secure fields. Follow the permission guidance using the installed app's actual name in System
Settings.

## Interface language

Choose Settings → General → Interface Language. English and 14 translated locales are available.
Simplified Chinese displays 拾语, Traditional Chinese displays 拾語, and other locales use Lingrove.
Restart to apply an interface-language change; this setting is separate from autocomplete languages
and learning source/target languages. The stable English bundle names keep storage paths unchanged.

## Learning behavior and model details

<details>
<summary>Translation, correspondence, dictionaries, models, and request metrics</summary>


Language learning can be enabled independently of inline autocomplete. In **Settings → Language Learning → Translation**,
choose one or more source languages and a target language. Configure the detail shortcut (default
**Option+T**) and replacement shortcut (default **Control+Option+T**) in **Settings → Shortcuts → Translation**.
Model summaries link to their configuration
in **Settings → Engine & Model**.
The master feature is off by default; enabling it enables automatic sentence preview.

Use your input method as usual: confirm the candidate and pause briefly. A target-language
preview appears beside the caret without stealing focus. Click Replace or press Control+Option+T to
confirm replacement of its saved sentence or selection. A dedicated translation model delivers the
expression first. Option+T or the expand button reveals the source and translation; lexical
recognition underlines reusable expressions without another generation request.
Word lookup opens Lingrove's own dictionary card, with shared read-aloud and fish-tail collection
actions. Available system definitions depend on the Mac's enabled dictionaries. Compact translation
also supports double-click word lookup. Esc returns a component word to its expression, then closes
the dictionary; continuing to type closes the learning windows. Contextual AI explanations use
their own model and preserve the chosen text and its sentence context.
Tab and Return retain their ordinary behavior; Escape dismisses the learning card.

Click an empty fish tail on a Lingrove preview or expression card to save its displayed content.
For words and expressions, available sentence context is retained as an example; saving does not
start another model request. A blue fish tail opens actions to view the entry or remove that saved
usage. **Vocabulary** in the menu bar opens the searchable notebook, where meanings, notes, tags,
and examples can be edited and the collection exported as JSON. Notebook data stays on this Mac;
it has no automatic synchronization or Anki connection. Its two optional shortcuts are configured
only in **Settings → Shortcuts** and are initially unset.

The small speaker on a preview or expression-detail card reads its text aloud without taking
typing focus. Click it again to stop; choosing another speaker replaces the current playback.
Choose **Apple system speech**, a **local Qwen3-TTS Base model through llama.cpp**, or a
compatible **TTS endpoint** in **Settings → Engine & Model → TTS**. Adjust the default speed in
**Settings → Language Learning → Read Aloud**. System speech uses installed macOS voices and
reports a missing voice instead of reading with an unrelated language. The local option provides
verified downloads for a matching model and audio decoder (about 1.48 GB), plus an optional
WAV/MP3 reference voice. It streams PCM directly to playback without temporary audio files. It loads on the first click,
stays ready for two idle minutes, and releases idle weights sooner under memory pressure.
An endpoint must support `/audio/speech`; only the chosen text is sent, with its separately stored
TTS credential. Playback starts only on a click, shows progress during synthesis, and can be
stopped from the same speaker. Editing speech settings or dismissing its card cancels that playback.
The TTS page follows the existing engine/runtime/model/folder/installed/connection layout, with
provider-specific voice controls. **Performance → Request Type → TTS** shares the existing opt-in
history and 100-request limit. Live CPU, memory and available GPU readings include the app-owned
local speech process, sampled only while Performance is open. Correlated speech lifecycle logs use
the normal Console/JSONL sinks and contain no spoken text, audio, reference paths or credentials.

Pauses trigger previews without ending a sentence. Extending an unfinished sentence updates that
sentence; punctuation and newlines distinguish a new sentence. The preceding sentence's translation
can remain visible while the new one arrives. An older version is labelled while typing continues.
Focus entry alone never sends existing text: automatic requests require a new edit in the same field.
No particular input-method brand or switch to ABC is required. Known active marked composition blocks
generation. Some editors omit marked-range information even after candidates are committed; selecting
a Chinese input source alone does not disable explicit replacement. Missing evidence remains unknown,
and each confirmed replacement still revalidates the saved field, full text and selection before writing.

Turning off automatic sentence preview restores the explicit selected-text/current-sentence preview,
including its verified click-to-replace operation. Customized shortcuts are preserved; the old default
Control+Command+T migrates to Option+T.

In Language Learning, enable translation and choose its behavior. Engine & Model provides task
tabs for Autocomplete, Translation, AI explanation and TTS, each reusing the grouped settings
layout. Translation and explanation support in-process GGUF or separately configured
OpenAI-compatible endpoints, with independent model, address, credential and power profiles.
Local execution needs no Ollama service. The translation catalog offers Hy-MT2 1.8B,
Hy-MT2 7B and TranslateGemma 4B; explanation uses general instruction models. Existing model
selections and downloaded files are preserved. Chunk alignment is deferred to
`codex/chunk-alignment-experiment-20261020`; it is absent from the current product's settings,
model requests and sentence cards.

The full translation appears first. An offline expression lexicon independently adds learning-unit
boundaries: fixed expressions use a neutral underline, while ordinary words remain directly
queryable. Double-click an expression in either the compact preview or expanded translation to
query the whole expression. Its dictionary window offers internal words and a return-to-expression
action in the same window. Missing expression entries are stated explicitly; constituent word
definitions are never combined into a phrase definition. Copy always returns the original sentence.

The bundled Wiktionary / Kaikki expression subset is about 11.5 MB and contains entries for all
configured target languages, with uneven coverage and English definitions. Recognition uses exact
headwords, recorded forms and conservative one-word slots in explicitly recorded expression
patterns; it is not a comprehensive grammatical phrase detector. The data has separate
[CC BY-SA attribution and provenance](Cotabby/Resources/learning-expressions.NOTICE.md).
**Settings → Language Learning → Dictionary** enables and orders built-in expressions, system
dictionaries, imported MDX/MDD files and optional online sources. Entry language is captured from
the original or translated sentence; double-click lookup works on either sentence in details.
A preferred definition language is independent of the translation direction. Automatic lookup
excludes known mismatching entry languages, prioritizes the preferred gloss language, and preserves
source order within each tier. Choosing a source in a card queries only that source for the current term.
Formatted system content uses experimental private DCS calls isolated in a helper. Its bundle
metadata selects a matching entry language; public plain-text fallback uses that same book.
Missing language metadata or an unavailable helper never falls back to an unfiltered system query. External system dictionary images are not loaded. Imported local HTML/CSS/images
render in the same app-owned card with scripts and remote subresources blocked.
When available, the encountered sentence and its existing translation appear as the current example
and remain attached when a component word is collected. Free Dictionary API is English-only and
default-off; enabling it sends only the lookup term to dictionaryapi.dev. Custom HTTPS templates
containing `{query}` are also default-off and open only on an explicit browser action. The recommended
website menu includes Cambridge, Oxford, Wiktionary, 汉典 and DLE presets; imported books and custom
websites can be annotated with their entry/definition languages. Unannotated imported books remain
available for manual selection and are excluded from automatic lookup until annotated. Presets contain URLs, not licensed
commercial dictionary data. The existing offline expression subset retains its English glosses. Source and
license metadata remain attached to saved definitions. No extra model request is made.

A sentence preview sends only the selected text or current sentence, up to 6 KB; larger scopes are
rejected without truncation. Learning requests exclude unrelated clipboard contents and typing
history. The settings disclose transmission to a configured endpoint, and learning sessions reject
HTTP redirects. Translation and AI explanation keep separate model selections and credentials.
Lexical recognition runs locally and word lookup remains available if recognition fails.

`LearningTranslationPrompt` selects the specialist's translation instructions independently of
chat framing. Hy-MT retains its existing vendor prompt; GGUF template metadata distinguishes the
different 1.8B and 7B turn tokens. TranslateGemma uses the
[Ollama plaintext guide](https://ollama.com/library/translategemma:4b), explicit source/target language
codes (including zh-Hans / zh-Hant), and a user-only Gemma turn. Its Traditional Chinese label is
explicit rather than relying on the script code alone. This is not Google's structured HF
processor request: endpoints requiring that processor need a separate server adapter. Recognizable
Endpoint model IDs select the plaintext guide; opaque aliases retain the generic prompt. Native
TranslateGemma rejects input above 2,048 actual tokens, including instructions and framing, without
truncation. Endpoint token limits are enforced by the selected server. Native sampling is model-specific;
the shared OpenAI-compatible transport forwards only temperature and top_p.

Pinned local translation defaults are 8,192 total tokens for Hy-MT2 1.8B and 4,096 for TranslateGemma
4B. Each total covers the prompt, source, references and output reserve; TranslateGemma's 2,048-token
task-input cap remains separate. Saved per-model overrides survive switching and restart, and reset
returns that model to its recommendation. Endpoints, unknown local models and AI explanation retain 8,192.

Performance tracking uses the existing opt-in switch. Its request-type picker separates autocomplete,
translation, AI explanation, TTS and screen OCR. Historical alignment records remain readable but are not selectable. The shared ring retains the most
recent 100 requests across all tasks. Learning rows show completed/failed/cancelled outcomes and
observed load, first-output, first-usable and panel-publication durations. No text or credentials are
stored in these metrics. Full model inputs/outputs use the existing `-cotabby-debug` LLM I/O sink.

Learning follows the existing global pause and Low Power Mode setting: pausing releases its native
contexts, and resuming keeps the eligible local translator warm. Local explanation loads on demand and
releases after 60 seconds idle. Endpoint tasks keep their separate server/key configuration. The
redundant passive word-hint workflow has been removed; legacy hint preferences are ignored.

</details>

## Contribute

[Report an issue or share an idea](https://github.com/ichthyoplanktonzyh/lingrove/issues).
See [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md),
[ARCHITECTURE.md](ARCHITECTURE.md), and [SOURCE_LAYOUT.md](SOURCE_LAYOUT.md) for development guidance.

## Maintainer and origins

Lingrove is maintained by [ichthyoplanktonzyh](https://github.com/ichthyoplanktonzyh).
The original Cotabby project was created by [FuJacob](https://github.com/FuJacob) and developed with
[jam-cai](https://github.com/jam-cai), [akramj13](https://github.com/akramj13), McHamster, and other
contributors. Their authorship and contributions remain credited.

Dependencies and data retain their own attribution and licenses, including
[CotabbyInference](https://github.com/FuJacob/cotabbyinference),
[llama.cpp](https://github.com/ggml-org/llama.cpp), [Sparkle](https://github.com/sparkle-project/Sparkle),
[swift-log](https://github.com/apple/swift-log),
[LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin-Modern),
[SymSpell](https://github.com/wolfgarbe/SymSpell), and [GitHub gemoji](https://github.com/github/gemoji).
Bundled dictionaries and expression data are documented in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
and [learning-expression notices](Cotabby/Resources/learning-expressions.NOTICE.md).

## License

Lingrove retains the [GNU Affero General Public License v3.0](LICENSE). See the license for
redistribution and corresponding-source requirements. Third-party code, dictionaries, and model
weights retain their own terms.
