# Language Learning Behavior & Model Details

This document covers the detailed interaction rules, dictionary architecture, model prompt formatting, token budgets, TTS lifecycle, and performance metrics for Lingrove's language learning subsystem.

---

## 1. Translation & Interaction Workflow

Language learning can be enabled independently of inline autocomplete:

- In **Settings → Language Learning → Translation**, choose one or more source languages and a target language.
- Configure the detail shortcut (default **Option+T**) and replacement shortcut (default **Control+Option+T**) in **Settings → Shortcuts → Translation**.
- Model summaries link to their configuration in **Settings → Engine & Model**.
- The master feature is off by default; enabling it enables automatic sentence preview.

### Input Method & Sentence Preview Behavior

- Use your input method as usual: confirm the candidate and pause briefly. A target-language preview appears beside the caret without stealing focus.
- Click **Replace** or press **Control+Option+T** to confirm replacement of its saved sentence or selection.
- Pauses trigger previews without ending a sentence. Extending an unfinished sentence updates that sentence; punctuation and newlines distinguish a new sentence.
- The preceding sentence's translation can remain visible while the new one arrives. An older version is labelled while typing continues.
- **Focus entry safety:** Focus entry alone never sends existing text—automatic requests require a new edit in the same field.
- **IME compatibility:** No particular input-method brand or switch to ABC is required. Known active marked composition blocks generation. Some editors omit marked-range information even after candidates are committed; selecting a Chinese input source alone does not disable explicit replacement. Missing evidence remains unknown, and each confirmed replacement still revalidates the saved field, full text, and selection before writing.
- Turning off automatic sentence preview restores the explicit selected-text/current-sentence preview, including its verified click-to-replace operation. Customized shortcuts are preserved; the old default `Control+Command+T` migrates to `Option+T`.
- `Tab` and `Return` retain their ordinary behavior; `Escape` dismisses the learning card, and continuing to type closes the learning windows.

---

## 2. Expression Recognition & Dictionary Lookup

- A dedicated translation model delivers the full sentence translation first.
- Pressing **Option+T** or clicking the expand button reveals the source and translation; offline lexical recognition underlines reusable expressions without another generation request.
- Fixed expressions use a neutral underline, while ordinary words remain directly queryable. Double-click an expression in either the compact preview or expanded translation to query the whole expression.
- Its dictionary window offers internal words and a return-to-expression action in the same window (`Escape` returns a component word to its expression, then closes the dictionary).
- Missing expression entries are stated explicitly; constituent word definitions are never combined into a phrase definition. Copy always returns the original sentence.
- Contextual AI explanations use their own model and preserve the chosen text and its sentence context.

### Bundled Expression Lexicon

- The bundled Wiktionary / Kaikki expression subset is about **11.5 MB** and contains entries for all configured target languages, with uneven coverage and English definitions.
- Recognition uses exact headwords, recorded forms, and conservative one-word slots in explicitly recorded expression patterns; it is not a comprehensive grammatical phrase detector.
- The data has separate [CC BY-SA attribution and provenance](../Cotabby/Resources/learning-expressions.NOTICE.md).

### Dictionary Sources & Priority

- **Settings → Language Learning → Dictionary** enables and orders built-in expressions, system dictionaries, imported `MDX`/`MDD` files, and optional online sources.
- Entry language is captured from the original or translated sentence; double-click lookup works on either sentence in details.
- A preferred definition language is independent of the translation direction. Automatic lookup excludes known mismatching entry languages, prioritizes the preferred gloss language, and preserves source order within each tier. Choosing a source in a card queries only that source for the current term.
- Formatted system content uses experimental private DCS calls isolated in a helper. Its bundle metadata selects a matching entry language; public plain-text fallback uses that same book. Missing language metadata or an unavailable helper never falls back to an unfiltered system query. External system dictionary images are not loaded.
- Imported local HTML/CSS/images render in the same app-owned card with scripts and remote subresources blocked.
- When available, the encountered sentence and its existing translation appear as the current example and remain attached when a component word is collected.
- **Online & Custom Sources:** Free Dictionary API is English-only and default-off; enabling it sends only the lookup term to `dictionaryapi.dev`. Custom HTTPS templates containing `{query}` are also default-off and open only on an explicit browser action. The recommended website menu includes Cambridge, Oxford, Wiktionary, 汉典, and DLE presets; imported books and custom websites can be annotated with their entry/definition languages. Unannotated imported books remain available for manual selection and are excluded from automatic lookup until annotated. Presets contain URLs, not licensed commercial dictionary data. Source and license metadata remain attached to saved definitions. No extra model request is made.

---

## 3. Vocabulary Notebook & Anki Integration

- Click an empty **fish tail** button on a Lingrove preview or expression card to save its displayed content. For words and expressions, available sentence context is retained as an example; saving does not start another model request.
- A blue fish tail opens actions to view the entry or remove that saved usage.
- **Vocabulary** in the menu bar opens the searchable notebook, where meanings, notes, tags, and examples can be edited and the collection exported as JSON.
- Expressions group stable senses, and each sense owns its usages and notes. Merge senses or move a usage explicitly; regenerating an explanation never changes its identity.
- Its two optional shortcuts are configured only in **Settings → Shortcuts** and are initially unset.

### Anki Review Workflow

- Notebook data stays on this Mac; Anki writes occur only when you explicitly send or update a review note.
- Prepare a sense with a representative example, preview recognition and gap cards, and explicitly send or update its Anki note.
- Configure the local AnkiConnect connection, deck, and optional custom field mappings in **Language Learning → Review**. Anki Desktop and the [AnkiConnect add-on](https://ankiweb.net/shared/info/2055492159) must be running on the Mac.
- Optional expression/example recordings reuse the configured TTS provider, with explicit audition and regeneration. Audio is stored in Anki only when sent.
- Use the notebook's checklist to prepare multiple senses and send a serial batch, stop it, or retry individual unsuccessful items.
- "Review in Anki" opens the linked note's current deck. Existing Lingrove templates can be upgraded explicitly without replacing card IDs or review history; customized templates stay under Anki's control.

---

## 4. Read Aloud (Text-to-Speech)

- The small speaker on a preview or expression-detail card reads its text aloud without taking typing focus. Click it again to stop; choosing another speaker replaces the current playback.
- Choose **Apple system speech**, a **local Qwen3-TTS Base model through llama.cpp**, or a compatible **TTS endpoint** in **Settings → Engine & Model → TTS**. Adjust the default speed in **Settings → Language Learning → Read Aloud**.
- **System speech:** Uses installed macOS voices and reports a missing voice instead of reading with an unrelated language.
- **Local Qwen3-TTS:** Provides verified downloads for a matching model and audio decoder (about 1.48 GB), plus an optional WAV/MP3 reference voice. It streams PCM directly to playback without temporary audio files. It loads on the first click, stays ready for two idle minutes, and releases idle weights sooner under memory pressure.
- **TTS Endpoint:** Must support `/audio/speech`; only the chosen text is sent, with its separately stored TTS credential. Playback starts only on a click, shows progress during synthesis, and can be stopped from the same speaker. Editing speech settings or dismissing its card cancels that playback.

---

## 5. Models, Prompting & Token Budgets

- **Engine & Model** provides task tabs for Autocomplete, Translation, AI Explanation, and TTS, each reusing the grouped settings layout.
- Translation and explanation support in-process GGUF or separately configured OpenAI-compatible endpoints, with independent model, address, credential, and power profiles. Local execution needs no Ollama service.
- The translation catalog offers **Hy-MT2 1.8B**, **Hy-MT2 7B**, and **TranslateGemma 4B**; explanation uses general instruction models. Existing model selections and downloaded files are preserved.
- Chunk alignment is deferred to `codex/chunk-alignment-experiment-20261020`; it is absent from the current product's settings, model requests, and sentence cards.

### Prompting & Sampling Details

- `LearningTranslationPrompt` selects the specialist's translation instructions independently of chat framing.
- **Hy-MT:** Retains its existing vendor prompt; GGUF template metadata distinguishes the different 1.8B and 7B turn tokens.
- **TranslateGemma:** Uses the [Ollama plaintext guide](https://ollama.com/library/translategemma:4b), explicit source/target language codes (including `zh-Hans` / `zh-Hant`), and a user-only Gemma turn. Its Traditional Chinese label is explicit rather than relying on the script code alone. This is not Google's structured HF processor request: endpoints requiring that processor need a separate server adapter. Recognizable Endpoint model IDs select the plaintext guide; opaque aliases retain the generic prompt.
- Native sampling is model-specific; the shared OpenAI-compatible transport forwards only `temperature` and `top_p`.

### Request Bounds & Token Caps

- A sentence preview sends only the selected text or current sentence, up to **6 KB**; larger scopes are rejected without truncation.
- Learning requests exclude unrelated clipboard contents and typing history. The settings disclose transmission to a configured endpoint, and learning sessions reject HTTP redirects.
- Native TranslateGemma rejects input above **2,048 actual tokens**, including instructions and framing, without truncation. Endpoint token limits are enforced by the selected server.
- Pinned local translation defaults are **8,192 total tokens** for Hy-MT2 1.8B and **4,096** for TranslateGemma 4B. Each total covers the prompt, source, references, and output reserve; TranslateGemma's 2,048-token task-input cap remains separate.
- Saved per-model overrides survive switching and restart, and reset returns that model to its recommendation. Endpoints, unknown local models, and AI explanation retain **8,192**.

---

## 6. Power Management & Performance Metrics

- **Lifecycle & Power:** Learning follows the existing global pause and Low Power Mode setting: pausing releases its native contexts, and resuming keeps the eligible local translator warm. Local explanation loads on demand and releases after 60 seconds idle.
- **Performance Tracking:** Uses the opt-in switch in **Settings → Performance**. Its request-type picker separates autocomplete, translation, AI explanation, TTS, and screen OCR (retaining the most recent 100 requests across all tasks).
- Learning rows show completed/failed/cancelled outcomes and observed load, first-output, first-usable, and panel-publication durations.
- Live CPU, memory, and available GPU readings include the app-owned local speech process, sampled only while Performance is open.
- **Privacy in Logs:** No text, audio, reference paths, or credentials are stored in performance metrics or normal Console/JSONL lifecycle logs. Full model inputs/outputs use only the explicit `-cotabby-debug` LLM I/O sink.
