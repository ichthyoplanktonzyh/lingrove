<div align="center">

<img src=".github/assets/readme/logo.png" width="120" alt="Lingrove whale logo" />

# Lingrove · 拾语

**Local-first inline autocomplete and language learning while you write on macOS.**  
Get ghost-text continuations beside your cursor, translate sentences in place, find expressions from a description, look up words, and build your Anki vocabulary—without leaving your editor.

[**English**](README.md) · [**简体中文**](README.zh-CN.md) · [**Releases**](https://github.com/ichthyoplanktonzyh/lingrove/releases) · [**FAQ**](FAQ.md) · [**Learning Docs**](docs/LANGUAGE_LEARNING.md) · [**Feedback**](https://github.com/ichthyoplanktonzyh/lingrove/issues)

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square&logo=apple)](#install)
[![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-success?style=flat-square)](#install)
[![Inference](https://img.shields.io/badge/AI-On--Device%20%7C%20Endpoint-purple?style=flat-square)](#engines--models)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPLv3-orange?style=flat-square)](LICENSE)

</div>

> [!NOTE]
> **Active Preview (v0.5):** Lingrove is under active development on `main`. You can try the latest [v0.5.1-test.1 prerelease DMG](https://github.com/ichthyoplanktonzyh/lingrove/releases/tag/v0.5.1-test.1) today or build from source.

---

## Preview

See the features in use below. The five Lingrove language-learning recordings use the Chinese interface.

<table align="center">
  <tr>
    <td width="50%" align="center" valign="top">
      <a href="gifs/imessage.gif"><img src="gifs/imessage.gif" width="400" alt="Upstream Cotabby recording showing inline autocomplete in Messages" /></a>
      <br />
      <sub><b>Autocomplete</b> — Ghost text at the caret; press Tab to accept.</sub>
    </td>
    <td width="50%" align="center" valign="top">
      <a href=".github/assets/readme/writing-translation.gif"><img src=".github/assets/readme/writing-translation.gif" width="400" alt="Lingrove translating a Chinese greeting into English beside the caret" /></a>
      <br />
      <sub><b>Writing translation</b> — Pause after typing to preview a translation.</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" align="center" valign="top">
      <a href=".github/assets/readme/expression-assistance.gif"><img src=".github/assets/readme/expression-assistance.gif" width="400" alt="Describing a concept in Chinese and inserting confirmation bias into an English sentence" /></a>
      <br />
      <sub><b>Expression assistance</b> — Describe what you mean, then insert a candidate.</sub>
    </td>
    <td width="50%" align="center" valign="top">
      <a href=".github/assets/readme/double-click-lookup.gif"><img src=".github/assets/readme/double-click-lookup.gif" width="400" alt="Double-clicking a word in a translation preview and switching between contextual and dictionary meanings" /></a>
      <br />
      <sub><b>Double-click lookup</b> — Double-click to compare contextual and dictionary meanings.</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" align="center" valign="top">
      <a href=".github/assets/readme/reading-translation.gif"><img src=".github/assets/readme/reading-translation.gif" width="400" alt="Selecting an English sentence on a web page to translate it, then looking up a selected word" /></a>
      <br />
      <sub><b>Reading translation</b> — Select text on a page to translate or look it up.</sub>
    </td>
    <td width="50%" align="center" valign="top">
      <a href=".github/assets/readme/save-to-vocabulary.gif"><img src=".github/assets/readme/save-to-vocabulary.gif" width="400" alt="Saving a translation with the fish-tail button and opening the saved entry in Vocabulary" /></a>
      <br />
      <sub><b>Save and open Vocabulary</b> — Save with the fish-tail button and open the saved entry.</sub>
    </td>
  </tr>
</table>

Click a GIF to view it full size. Autocomplete footage is from [upstream Cotabby](https://github.com/FuJacob/Cotabby#demo); the remaining recordings show Lingrove.

---

## Core Capabilities

Lingrove is built around two equally core capabilities that work together in any supported macOS text field:

### 1. Inline Autocomplete

- **Ghost-Text Continuations:** Suggestions appear right beside your caret in native apps, browsers, and Electron editors. Accept a single word, a phrase, or the entire completion with `Tab` and configurable shortcuts.
- **Flexible Inference Backends:** Run 100% locally via **Apple Intelligence** or in-process **`llama.cpp` (GGUF)**, or connect to any **OpenAI-compatible endpoint**.
- **Rich Context & Granular Control:** Tune completion length, within-word prediction, and streaming. Optionally ground predictions with on-device screen OCR and clipboard context, and pause globally or per app.

### 2. Language Learning While Writing

- **Expression Assistance:** Type `??` at the caret and describe a missing expression or term, then press Enter or Tab to insert a candidate. It shares the AI explanation model and can be enabled independently of translation.
- **Write & Translate in Place:** Type in your native or target language and pause briefly to see a non-intrusive translation preview beside the cursor. Press `Control+Option+T` to replace the sentence in place, or `Option+T` to expand details.
- **Expression Recognition & Deep Lookup:** An offline 11.5 MB Wiktionary/Kaikki lexicon automatically underlines reusable idioms and phrases without extra LLM calls. Double-click any word or expression to inspect definitions across **built-in expressions**, **macOS system dictionaries**, **imported `MDX`/`MDD` books**, or **contextual AI explanations**.
- **Read Aloud (TTS):** Listen to sentences or expressions without losing typing focus using **macOS system voices**, an in-process **Qwen3-TTS Base (`llama.cpp`)** model with optional voice cloning, or a `/audio/speech` endpoint.
- **Vocabulary Notebook ("Fish Tail"):** Save expressions with their original sentences, then browse by entry or meaning in the same list and graph views. Associate specific senses with concepts or communicative functions, record usage patterns and compare collected expressions. Notes, tags and unclassified entries remain available in the notebook.
- **Local CLI & Agent Skill:** Search and save vocabulary from an agent through the local `lingrove` CLI. Install the portable [`lingrove-cli` skill](CLI.md#agent-skill) for sense-aware capture, batch previews, and safe retries.
- **One-Click Anki Sync:** Preview recognition and cloze/gap cards, attach generated TTS audio, and send or batch-update notes directly to **Anki Desktop** via [AnkiConnect](https://ankiweb.net/shared/info/2055492159) while preserving your review history.

### Additional Writing Tools

- **Inline Utilities:** Fast local **autocorrect**, `:emoji:` lookup, and `/` **slash macros** for instant calculations and unit conversions.
- **15 Interface Locales:** Switch between English, Simplified Chinese (`拾语`), Traditional Chinese (`拾語`), and 12 other languages in **Settings → General → Interface Language**.

> Looking for prompt templates, token budgets, dictionary priority rules, or IME edge cases? See [**Language Learning Behavior & Model Details**](docs/LANGUAGE_LEARNING.md).

---

## Engines & Models

Choose **Use recommended setup** during onboarding to configure missing local models, download them, and enable autocomplete, writing/selection translation, and expression assistance. Explanation and expression assistance share a model; new setups use system speech. Existing models, languages, and shortcuts are kept. **Configure manually** remains available, and macOS permissions are granted separately.

Each capability configures its model and server settings independently—using an endpoint for translation never routes your autocomplete keystrokes off-device unless you explicitly configure both.

| Task | On-Device Local Options | Custom Endpoint Option |
| :--- | :--- | :--- |
| **Autocomplete** | • In-process `llama.cpp` (base GGUF models)<br>• Apple Intelligence *(macOS 26+ on supported Macs)* | OpenAI-compatible `/v1/completions` or `/v1/chat/completions` |
| **Translation** | • In-process `llama.cpp` (`Hy-MT2 1.8B / 7B`, `TranslateGemma 4B`) | OpenAI-compatible chat endpoint |
| **AI Explanation & Expression Assistance** | • In-process `llama.cpp` (general instruction GGUF models) | OpenAI-compatible chat endpoint |
| **Read Aloud (TTS)** | • Apple macOS System Speech<br>• Local `Qwen3-TTS Base` via `llama.cpp` (~1.48 GB, PCM streaming) | OpenAI-compatible `/audio/speech` endpoint |
| **Lexicon & OCR** | • Always on-device (Wiktionary/Kaikki subset + macOS Vision OCR) | — |

---

## Install

### System Requirements

- **OS:** macOS 14.0 (Sonoma) or later *(macOS 26+ required only if using Apple Intelligence autocomplete)*.
- **Hardware:** Apple Silicon (`arm64`) recommended for local GGUF and TTS inference; Universal binary supports Intel (`x86_64`).

### Option 1: Download Prebuilt Test DMG (For Users)

1. Download `Lingrove-0.5.1-test-universal.dmg` from the [**v0.5.1-test.1 Prerelease**](https://github.com/ichthyoplanktonzyh/lingrove/releases/tag/v0.5.1-test.1).
2. Open the DMG, drag **Lingrove.app** into **Applications**, eject the disk image, and launch Lingrove from Applications.
3. Because test builds use ad-hoc signing (not yet notarized), if macOS shows an unverified developer prompt, open **System Settings → Privacy & Security** and click **Open Anyway**.
4. See the [Simplified Chinese Install & Quickstart Guide](assets/testing/INSTALL.zh-CN.txt) (also bundled inside the DMG as `INSTALL.txt`) for a step-by-step walkthrough.

### Option 2: Build from Source (For Developers)

```sh
git clone https://github.com/ichthyoplanktonzyh/lingrove.git
cd lingrove
scripts/dev-setup.sh
scripts/prepare_lingrove_workspace.sh
open build/lingrove-dependencies/Lingrove.xcworkspace
```

- In Xcode, select the **Lingrove Dev** scheme to build **Lingrove Dev.app** (isolated preferences, Keychain, and logs for local development), or **Lingrove** to build **Lingrove.app**.
- Local signing uses your own Apple team in the gitignored `LocalSigning.xcconfig`.
- See [CONTRIBUTING.md](CONTRIBUTING.md) for testing guidelines and [RELEASING.md](RELEASING.md) for the release roadmap.

---

## Quick start

In first-run setup, choose **Use recommended setup** to configure missing models and enable the recommended features. Wait for the required downloads to finish and grant Accessibility and Input Monitoring permissions. You can also configure each task manually in **Settings → Engine & Model**.

| Try | What to do |
| :--- | :--- |
| **Autocomplete** | Type in a supported editor and pause. Press `Tab` to accept the next part of the suggestion. |
| **Writing translation** | Enable **Language Learning → Translation**, choose a target language, and turn on sentence previews. Type a sentence and pause; use the card's Replace action or the default `Control+Option+T` to insert its translation. |
| **Expression assistance** | Enable **Language Learning → Explanation & expression → Expression assistance**. Set the target language to English, type `??` at the caret, and describe “only noticing evidence that supports your existing beliefs.” Choose a candidate, then press `Enter` / `Tab` to insert or `Esc` to cancel. |
| **Double-click lookup** | Double-click a word or underlined expression inside a Lingrove translation card. Switch between **Contextual meaning** and **Dictionary** in the lookup window. |
| **Reading translation** | Enable selection translation and its icon in **Language Learning → Translation**, and allow the app you want to read in. Select text on a page, then click the translation icon or use your configured selection-translation shortcut. |
| **Vocabulary** | Click the fish-tail button on a card to save it. Click the saved button again and choose **View in Vocabulary**, or open Vocabulary from the menu bar. |

Target and explanation languages are configured in **Language Learning**; shortcuts can be changed in **Settings → Shortcuts**. See [Language Learning Behavior & Model Details](docs/LANGUAGE_LEARNING.md) for the full interaction rules.

---

## Permissions

Lingrove requests only the macOS permissions required for the features you enable. **Password and secure text fields are always blocked from both reading and insertion.**

| Permission | Required? | Why Lingrove Needs It |
| :--- | :--- | :--- |
| **Accessibility** | **Required** | Reads focused text field context, locates the caret, and inserts accepted completions or translations. |
| **Input Monitoring** | **Required** | Detects typing pauses, dismissal keys (`Esc`), and acceptance shortcuts (`Tab`) without stealing focus. |
| **Screen Recording** | *Optional* | Used only when you enable visual screen context, region OCR translation, or pointer lookup OCR fallback. |

---

## Privacy & Data Isolation

- **Local by Default:** Apple Intelligence, `llama.cpp` GGUF models, Vision OCR, and dictionary lookup run entirely on your Mac with zero network calls.
- **Explicit Endpoint Scope:** Only tasks explicitly configured to use a remote endpoint send bounded text context to that server. Learning requests never include unrelated clipboard contents or typing history.
- **Encrypted Opt-In History:** Input-history recording is **off by default**. When enabled, history is stored in a local encrypted archive whose key lives in your macOS Keychain, and can be wiped anytime in Settings.
- **Zero Telemetry:** No user accounts, no analytics, and no remote crash reporting. Automatic app updates remain disabled until independent Sparkle infrastructure is finalized.
- **Clean Side-by-Side Storage:** `Lingrove`, `Lingrove Dev`, and legacy `Cotabby` installations use separate preferences, Keychain services, and application support directories. See [FORK.md](FORK.md).

---

## Documentation & Community

- [**FAQ.md**](FAQ.md) — Common questions on setup, offline usage, and permissions
- [**docs/LANGUAGE_LEARNING.md**](docs/LANGUAGE_LEARNING.md) — Deep dive into translation workflows, dictionaries, TTS, and model token budgets
- [**ARCHITECTURE.md**](ARCHITECTURE.md) & [**SOURCE_LAYOUT.md**](SOURCE_LAYOUT.md) — Subsystem boundaries and codebase navigation
- [**CONTRIBUTING.md**](CONTRIBUTING.md) & [**CODE_OF_CONDUCT.md**](CODE_OF_CONDUCT.md) — How to report issues, run evaluations, and submit pull requests

---

## Maintainer, Origins & License

**Lingrove (拾语)** is independently maintained by [ichthyoplanktonzyh](https://github.com/ichthyoplanktonzyh).  
It derives from [FuJacob/Cotabby](https://github.com/FuJacob/cotabby), created by [FuJacob](https://github.com/FuJacob) and developed with [jam-cai](https://github.com/jam-cai), [akramj13](https://github.com/akramj13), McHamster, and other contributors. Their authorship and contributions remain credited.

Built with [CotabbyInference](https://github.com/FuJacob/cotabbyinference), [llama.cpp](https://github.com/ggml-org/llama.cpp), [Sparkle](https://github.com/sparkle-project/Sparkle), [swift-log](https://github.com/apple/swift-log), [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin-Modern), [SymSpell](https://github.com/wolfgarbe/SymSpell), and [GitHub gemoji](https://github.com/github/gemoji). Bundled dictionary and expression notices are documented in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) and [learning-expressions.NOTICE.md](Lingrove/Resources/learning-expressions.NOTICE.md).

Licensed under the [**GNU Affero General Public License v3.0 (AGPLv3)**](LICENSE). Third-party libraries, dictionaries, and model weights retain their respective licenses.
