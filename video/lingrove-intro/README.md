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
