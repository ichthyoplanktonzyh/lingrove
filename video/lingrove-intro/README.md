# Lingrove intro film

**Current audience (2026-11-07): English speakers learning Chinese.** The two current
`Lingrove-FirstHello` compositions share the same Chinese-learning story, with Chinese or
English interface/editorial copy. Earlier sections below document previous cuts; the
Chinese-learning revision at the end describes the current content and exports.

A standalone, code-animated product film. React components reproduce product UI states using synthetic data; the app and user data are never opened or modified. Remotion controls every frame. This is a visual interpretation, not a screen recording or a functional app.

```sh
npm ci
npx remotion studio src/index.ts
npx remotion render src/index.ts LingroveIntro out/lingrove-intro.mp4
```

The timings and scenes are in `src/video.tsx`; the visual styling is in `src/visual.css`. The first draft is intentionally silent and uses Chinese titles. Logo and fish icons come from Lingrove's own assets.

## Refined writing sequence

The independently rendered writing sample uses `src/director-entry.ts` and the `WritingSequence` composition. Its three recreated interface components live under `src/components/`; they are deterministic visual simulations driven by elapsed time, with no connection to the app or user data.

```sh
npx remotion render src/director-entry.ts WritingSequence out/lingrove-writing-refined.mp4
```

`src/director.tsx` owns the scene timing, copy, framing and camera movement. Components own their simulated UI state and animation, so visual styling or shot timing can be changed independently.

For crisp delivery, render at 1080p from the original 1280 × 720 composition using browser-rendered PNG frames and a high-quality H.264 encode (not a post-render upscale):

```sh
npx remotion render src/director-entry.ts WritingSequence out/lingrove-writing-1080p.mp4 --scale=1.5 --image-format=png --codec=h264 --crf=14
npx remotion render src/lookup-entry.ts SceneStudy out/lingrove-scenes-1080p.mp4 --scale=1.5 --image-format=png --codec=h264 --crf=14
```

Camera movement is intentionally kept off full text-bearing surfaces: continuously scaling or moving browser-rendered text makes its antialiasing change frame by frame. Movement is reserved for controls, cursors, and opacity transitions.

## Complete story

`src/story.tsx` composes the synthetic bookshop narrative into `LingroveStory`. Each scene owns a local time; the director controls scene order and transitions. The writing preview pauses for dictionary lookup and returns for explicit replacement, then the message is sent before the reading and review scenes.

```sh
npx remotion render src/story-entry.ts LingroveStory out/lingrove-story-1080p.mp4 --scale=1.5 --image-format=png --codec=h264 --crf=14
```

The first complete cut is silent. User-provided reference frames are excluded from version control and are not used as video assets.

## Narrative revision — opening proof

The original film is checkpointed at `e8f35506`. `LingroveOpening` is a separate 15-second,
silent editorial proof: the suggestion appears after one second, Tab accepts each chunk,
and the same message continues into expression assistance. Full-window establishing shots
alternate with static editor crops; text is never continuously zoomed while being read.

```sh
npx remotion render src/opening-entry.ts LingroveOpening out/lingrove-opening-v2-1080p.mp4 --scale=1.5 --image-format=png --codec=h264 --crf=14
```

- `opening-timeline.ts` owns the shot's deterministic text states and action times. It returns
  values to the director, with no timers, application connections or mutable state.
- `opening.tsx` owns the composition, framing, captions and editorial key indicators;
  `opening.css` scopes its framing and host-window alignment to this composition.
- `GhostDemo` and `ExpressionDemo` accept optional frame values while retaining their original
  time-driven defaults. Their responsibility remains the recreated interface, not the edit.
- `opening-entry.ts` registers only the new composition, keeping the existing cuts renderable.

The planned full cut follows: autocomplete → expression assistance → translation and send →
reply and reading → explicit collection with context → explicit review enrollment and practice →
writing again a few days later. Reading, collection, review and later writing should share one
expression. Later writing illustrates human learning, not automatic recall from the collection.
Only the opening is implemented in this proof; the full cut and sound design remain future work.

## Current film: Next time

`Lingrove-NextTime` is the new 50.4-second product film. The earlier paragraph above describes
the superseded opening proof; both that proof and the original complete cut remain renderable.
The new film follows one fictional book-club exchange: hesitation → autocomplete → expressing
an idea → translation → collecting the expression with context → explicitly enrolling and
reviewing → typing the expression oneself a few days later. Reading lookup is omitted from
this cut to keep one causal thread rather than give every feature its own chapter.

```sh
npm run studio
npm run check
npm run render:film
npx remotion render src/film-entry.ts OpeningA-Thought out/opening-a-thought.mp4 --scale=1.5 --image-format=png --crf=14
npx remotion render src/film-entry.ts OpeningB-Invitation out/opening-b-invitation.mp4 --scale=1.5 --image-format=png --crf=14
```

### Direction and source boundaries

The visual direction applies [motion-art-direction](https://github.com/iart-ai/motion-design-skills/tree/main/skills/motion-art-direction),
[launch-video](https://github.com/charlie947/motion-graphics-skills/tree/main/skills/launch-video),
[motion-effects](https://github.com/charlie947/motion-graphics-skills/tree/main/skills/motion-effects),
and the [Remotion skills](https://github.com/remotion-dev/skills). Their HTML recipes are adapted
to the established React components rather than migrating the project to HyperFrames.

Two openings were explored: A, a stalled sentence in a dark typographic scene; B, a warm
bookshop invitation. A is used for the full film because the hesitation creates a direct
setup for autocomplete. B remains a comparison composition.

| Direction choice | Implementation |
| --- | --- |
| Promise | Help this expression now; keep something for the next expression |
| Brand | Exact whale SVG; navy `#174467` and turquoise `#3CBFCF` sampled from it |
| Supporting surfaces | Dark navy `#102D43`, warm paper `#F5F1E9`, native white UI |
| Motion | Cubic ease-out for entrances; cubic ease-in-out for the caret portal; 0.6-second beat |
| Attention | One primary event per shot; camera lands before the text needs reading |
| Transitions | Caret expands into the writing world; saved card grows into the notebook; cuts follow musical bars |
| Sound | Original deterministic 100-BPM synthesized score, with acceptance clicks and transition swells; no voiceover |
| Truth boundary | Recreated synthetic UI. Cinematic transformations are editorial, not native-app animations. Later reuse depicts human learning, not inference from saved vocabulary. |

`src/film/motion.tsx` owns reusable camera poses and masked text reveals. `openings.tsx` owns
the two entry concepts and the shared autocomplete payoff. `story-scenes.tsx` directs the
remaining narrative beats while borrowing the existing components. `root.tsx` owns the
explicit scene timing and soundtrack; `film.css` contains only this film's presentation.
`DictionaryDemo` adds a card-only framing option and corresponding pointer coordinates;
`ReplyDemo` accepts optional message text. Their original defaults remain intact.

`scripts/make-score.py` generates the original soundtrack using Python/numpy and local FFmpeg.
It writes `public/audio/lingrove-score.m4a` and removes its intermediate WAV after successful
encoding. No external samples, music services, credentials, app data or user corpus are used.
The score's event times are coupled to `root.tsx`; regenerate it when changing scene timing.

### Validation of this cut

- `npm run check` passes for the new film and every earlier entry point.
- Rendered stills were inspected across the hook, acceptance, expression query, translation,
  dictionary, card expansion, enrollment, review answer, later writing and end card. The review
  context and final composer were reframed after initial clipping was found.
- Remotion Studio loads the full composition and its named scenes with no current error;
  the collection-to-notebook sequence was previewed in Studio.
- The complete MP4 decodes without errors: 1,512 H.264 frames at 1920×1080 / 30fps, with stereo
  AAC audio. The picture is 50.4 seconds; the muxed container reports 50.411 seconds.
- Both 9.6-second opening alternatives render with audio and decode without errors.
- This is an editorial candidate, not audience-tested creative. Music is synthesized; no
  voiceover, public release URL, conversion claim or automatic vocabulary recall is implied.
- No native app was opened or built, and no repository DerivedData remains.

## First Hello — continuous-story revision

The prior accepted film is checkpoint `685fedcf`. `Lingrove-FirstHello` is a separate 60-second
revision, keeping the checkpoint composition available. The user approved the book-club story
and explicitly freed the film from the app's theme colors. Warm paper `#F1EEE5`, charcoal
`#242420`, vermilion `#D94B30`, and a soft blue `#D7E4F1` now carry the editorial scenes;
the existing product components retain their recognizable native materials.

Creative mode: autonomous revision of the approved story and reused components. Existing
approved UI references and the inspected Shotcraft motion samples serve as the visual baseline;
each new scene is checked with rendered stills before delivery. This is a synthetic fictional
exchange, with no real customer, account, native application or corpus access.

| Time | Story event / state | Visual and motion purpose |
| --- | --- | --- |
| 0–6 | See the book-club invitation and click contact | Invitation rotates from a paper-like angled view into readable frontal composition |
| 6–12 | Start one message; explicitly accept autocomplete chunks | Camera settles on the caret; ghost continuation reveals and Tab consumes words |
| 12–18 | Describe a missing expression in Chinese, confirm candidate | Same host persists; candidate lifts, holds, then collapses before insertion |
| 18–24 | Write the final thought in Chinese, inspect and replace | Camera follows the third line; native translation preview rises as a separate layer |
| 24–30 | Click send, then receive the bookshop's welcome | The composed content becomes a sent bubble; reply arrives before the learning act |
| 30–36 | Revisit and explicitly collect the expression just used | Context remains behind the lifted dictionary card; save control receives a click |
| 36–42 | Find the expression with its context and enroll it | Entry drops into its actual notebook slot; camera moves to context and enrollment |
| 42–49.2 | Start review, recall, reveal, rate | Camera lands before interaction; the answer card turns at the reveal midpoint |
| 49.2–55.2 | After the event, write a new thank-you and anticipation | Same recipient, new purpose; human typing uses the expression without a ghost |
| 55.2–60 | Brand close | Stable title and wordmark hold; no fabricated release URL or CTA |

### Implementation and motion sources

`campaign/timeline.ts` owns story time and synthetic text states. `MessageHost.tsx` owns one
continuous editor and conversation shell. `GhostLine`, `ExpressionLine` and `TranslationPreview`
are extracted from the existing demos so their controls can share that host; original demo
defaults are retained. `camera.tsx` owns deterministic camera poses, and `FirstHello.tsx` owns
the scene sequence, captions and component choreography. `first-hello.css` scopes this cut's
palette, framing and motion variables. Nothing is wired to native app behavior.

Motion research: [video-shotcraft](https://github.com/Vincentwei1021/video-shotcraft), Gallery
index revision `bdd94be16d60fa8f`. Read cards, exact source and extracted sample frames:

- `cursor-flyover` / `demos/camera/cursor-flyover/CursorFlyover.tsx`: adapt camera focal points,
  asymmetric in-out easing and move→hold→act grammar to one continuous message, rather than
  reproducing a four-station dashboard tour.
- `row-embed` / `demos/ui-entrance/row-embed/RowEmbed.tsx`: adapt one-row descent, 16° flattening
  and contact compression to the saved expression. This is a single-item narrative adaptation,
  not the demo's accelerating five-row sequence.
- `line-carry-transition` was inspected but not used: the existing phrase/host continuity is
  sufficient, and a second long graphic transition would interrupt the conversation.

Upstream code/docs are Apache-2.0; see `licenses/video-shotcraft-LICENSE.txt`. Recipes are
adapted, not claimed to be pixel-identical. UI surfaces remain the user's approved recreations,
an explicit exception to Shotcraft's default preference for fresh native screenshots. The
native data-bearing app stays closed. Repeated phrases are intentional story callbacks rather
than repeated feature demonstrations. The soundtrack retains the prior film's original
synthesized vocabulary; no Freesound sampling or recorded-foley claim is made.

### Reproduce

```sh
python3 scripts/make-first-hello-score.py
npm run check
npx remotion render src/film-entry.ts Lingrove-FirstHello out/lingrove-first-hello-1080p.mp4 --scale=1.5 --image-format=png --codec=h264 --crf=14
npx remotion render src/film-entry.ts Lingrove-FirstHello out/first-hello-no-bgm-render.mp4 --props='{"bgm":false}' --scale=1.5 --image-format=png --codec=h264 --crf=14
ffmpeg -i out/lingrove-first-hello-1080p.mp4 -i out/first-hello-no-bgm-render.mp4 -map 0:v:0 -map 1:a:0 -c copy out/lingrove-first-hello-no-bgm.mp4
```

The two audio stems are independently reproducible: music and timed foley. Both exports share
the same picture and foley, with only the `bgm` prop changing. Sound event seconds are declared
in `make-first-hello-score.py`, and must follow the action markers in `timeline.ts`.
The last remux reuses the main video bitstream, eliminating minute independent-encode pixel
differences between the two picture tracks without re-encoding either picture or audio.

Technical QA for this revision: `npm run check` and the legacy opening's still render pass;
the complete main MP4 decodes cleanly (1,800 frames, 1080p, 30fps, stereo AAC). Source foley
versus no-music output was cross-correlated at 8.4, 22.6, 41.0 and 54.7 seconds after decoding
both to 48kHz mono: measured lag was 0 samples at every probe, so no pipeline offset was
applied. Pipeline: Remotion 4.0.541, H.264/AAC, 48kHz output, MP4; checked 2026-11-06.
Main audio peak is −5.2 dBFS and mean is −21.9 dBFS. This establishes signal integrity and
alignment, not a claim of professional listening approval. The two delivered decoded picture
streams share SHA-256 `de356610473e40a5cec94624ae432c3f594d3754746084e641cef140857e27c4`.

Independent review was requested with the final MP4, reference cards/source, sample frames and
review criteria, but returned no report within the bounded review window and was stopped.
It is **unverified**, not a pass. The checks above are the producing agent's actual technical
and visual checks. This cut remains an editorial review candidate.

## Previous English international edition (English-learning story)

The approved Chinese film, corrected replacement-button pointer, and README demo assets are
checkpointed at `048cf9db`. The current 67.2-second cut also has an English international
edition, `Lingrove-FirstHello-English`. Both compositions render the same `FirstHello` component;
`locale` selects the display language independently of the fictional learner's language pair.

The English edition keeps a Chinese speaker learning English. Chinese expression queries,
translation source text, encountered translations, and saved review answers remain Chinese.
English captions explain their meaning, while the editorial titles, feature labels, controls,
corpus navigation, and review UI use English. The original soundtrack, action timing, and
camera poses are shared. Both current editions omit the message composer's lower-left writing
assistance badge, including in the later follow-up; the send button retains its position.

`src/demo-copy.tsx` owns the two editorial copy packs, typed UI translations, and a render-scoped
locale context. The composition owns the provider; the shared dictionary, expression, reading,
and review components consume it without reading application settings. Without a provider they
retain their Chinese defaults, keeping earlier compositions usable. `campaign/timeline.ts`
continues to own all story timing and learner text states. English-only typography is scoped
under `.hello-language-en` in `campaign/first-hello.css`, so text fitting does not resize the
Chinese edition.

```sh
npm run studio
npm run check
npm run render:first-hello       # Chinese
npm run render:first-hello:en    # English international
```

For the same composition with explicit parameters:

```sh
npx remotion render src/film-entry.ts Lingrove-FirstHello out/lingrove-first-hello-en.mp4 --props='{"locale":"en","bgm":true}' --scale=1.5 --image-format=png --codec=h264 --crf=14
```

No real app, account, or user corpus is used. The root READMEs embed GitHub video
attachments directly, with a link to the other language:

- English: https://github.com/user-attachments/assets/bdc61a21-d21f-410d-97cc-3ea119bd6bb3
- Chinese: https://github.com/user-attachments/assets/ce68087d-21fb-49df-ab15-4635b60fe5d1

Repository MP4 copies and end-card posters were removed after attachment upload. Keep
master exports locally under `out/`; source compositions and their required assets remain
tracked. Both published demos omit the writing assistance badge.

For an attachment below 10 MB, encode each 67.2-second master with two-pass libx264
at 1000 kbit/s, AAC at 96 kbit/s, and `-movflags +faststart`. The published copies
retain 1920×1080 at 30 fps and are about 8.8 MiB each. Both decode completely without
errors; frame checks at 35 seconds retain readable interface text and captions.

Validation for these review exports (2026-11-06):

- `npm run check` passes across all existing entry points. English Studio loads without an
  error, and the replacement pointer tip is inside its button at frame 681.
- Seventeen English stills cover the opening, autocomplete, query/candidate, replacement,
  reading, saving, enrollment, review, later writing, and end card. The longer English labels
  fit the inspected layouts.
- Before removing the badge, six Chinese PNG frames (45, 490, 681, 1434, 1605, 1980) are
  byte-identical to fresh renders of checkpoint `048cf9db`. After removal, frames 490 and
  681 differ only within the former badge's pixel bounds; frames 1434 and 1980 remain identical.
- `out/lingrove-first-hello-en-clean-1080p.mp4` and
  `out/lingrove-first-hello-zh-clean-1080p.mp4` both decode completely without errors:
  2,016 H.264 frames, 1920×1080, 30 fps, 67.2 seconds, stereo AAC at 48 kHz.


## Current revision — learning Chinese

Both current 67.2-second FirstHello compositions now follow an English-speaking learner
joining a fictional Chinese book club at 松间书店 (Songjian Bookshop). The audience already
knows some written Chinese. The film remains a synthetic UI reconstruction, with no native
application, real account or user corpus access. The `.example` addresses are fictional.
Existing GitHub attachments above still show the prior English-learning story; this revision
has **not** been uploaded or substituted into either root README.

### Shared story, two display languages

- Invitation: 中文读书会, welcoming Chinese learners.
- Autocomplete: `你好，我看到你们的读书会活动，` → `想报名参加。` Three explicit Tab
  acceptances at 8.4, 9.1 and 9.8 seconds consume `想 / 报名 / 参加。`. Foundation's
  `.byWords` segmentation was checked locally; trailing Chinese punctuation follows the
  product's default punctuation-binding rule.
- Expression help: English query `give it a try, even though I’m nervous` → `试试看`;
  the completed line is `我有点紧张，不过想试试看。`.
- Translation: `I’m looking forward to hearing everyone’s thoughts.` →
  `很期待听听大家的想法。`, previewed before explicit replacement and sending.
- Reply: `欢迎你来！周五见。`.
- Reading: encounter `期待` again in `期待和大家一起聊聊最近读的书。`; point at the word
  and press the existing shortcut for its English contextual meaning.
- Collection and review: save `期待` with the original sent sentence and English translation;
  explicitly enroll, recall its meaning, reveal `look forward to`, and rate.
- Days later: `谢谢，今晚聊得很开心。期待下次再见！` is typed in a new message. It depicts
  human reuse, not retrieval from the corpus or proof that one review guarantees mastery.

`campaign/learning-story.tsx` owns the immutable fictional content and a render-scoped
provider. FirstHello supplies it to the existing bookshop, expression, translation, reading,
collection and review components; standalone legacy studies retain their no-provider content.
`demo-copy.tsx` owns display-language copy independently. The timeline owns time and text states;
MessageHost keeps the same editor and recipient through the exchange. English typing now lasts
18–20.2 seconds; the translation preview starts at 20.3, finishes by 21.5, and replacement
remains at 23.1 seconds. The original music is retained; foley was regenerated for the three
Chinese acceptances and longer English typing interval.

The local bundled lexicon has no standalone `期待` entry. Its collection card therefore uses
**In context**, with a synthetic English explanation, rather than fabricating a bundled
Wiktionary result or source attribution. No new pinyin, pronunciation-assessment or IME feature
is depicted. Both subtitle editions show Chinese learner text with English semantic help.

### Reproduce current exports

```sh
python3 scripts/make-first-hello-score.py
npm run check
npx remotion render src/film-entry.ts Lingrove-FirstHello-English out/lingrove-learn-chinese-en-1080p.mp4 --scale=1.5 --image-format=png --codec=h264 --crf=14 --concurrency=4
npx remotion render src/film-entry.ts Lingrove-FirstHello out/lingrove-learn-chinese-zh-1080p.mp4 --scale=1.5 --image-format=png --codec=h264 --crf=14 --concurrency=4
```

Use `npm run studio` for both current compositions. The standard `render:first-hello` scripts
also render the updated story to their existing generic filenames. The audience-specific export
names above keep older local review masters intact.

### Validation (2026-11-07)

- `npm run check` passed across all entry points. Both current compositions loaded in Studio.
- Inspected key frames in both editions from invitation to end card, including the Chinese
  suggestion, English query, translation preview, contextual lookup, save, review and reuse.
  Verified pointer tips against the invitation CTA, replacement control and the reading target;
  checked the revised invitation and later title again from the encoded files.
- Both final MP4s decoded fully with FFmpeg: 2,016 H.264 frames, 1920×1080 at 30 fps, 67.2 seconds,
  with matching 48 kHz stereo AAC audio. An earlier `Lingrove-NextTime` corpus still also rendered
  with its original English-learning example.
