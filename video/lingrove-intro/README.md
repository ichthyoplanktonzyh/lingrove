# Lingrove intro film

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
