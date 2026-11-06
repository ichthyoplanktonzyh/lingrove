import React from 'react';
import {AbsoluteFill, Composition, staticFile, useCurrentFrame} from 'remotion';
import GhostDemo from './components/GhostDemo';
import ExpressionDemo from './components/ExpressionDemo';
import {OPENING, expressionFrame, ghostFrame, openingCaption} from './opening-timeline';
import './opening.css';

/** A 15-second opening proof. This director owns framing and editorial annotations; the reused
 * components own the synthetic UI. Static shot changes keep small text crisp while it is read. */
function OpeningFilm() {
  const t = useCurrentFrame() / OPENING.fps;
  const expression = t >= OPENING.expression;
  const close = (t >= OPENING.suggestion && !expression) || (t >= OPENING.query && t < OPENING.insert);
  const caption = openingCaption(t);
  const tabPressed = OPENING.acceptChunks.some(at => t >= at && t < at + .2);
  const enterPressed = [OPENING.lookup, OPENING.insert].some(at => t >= at && t < at + .25);
  const key = !expression ? 'Tab' : t < OPENING.lookup ? '??' : 'Return';
  return <AbsoluteFill className="opening-film">
    <header className="opening-brand"><img src={staticFile('lingrove-logo.svg')}/><span>Lingrove <small>拾语</small></span></header>
    <div className="opening-copy"><h1>{caption.title}</h1></div>
    <div className={`opening-viewport ${close ? 'opening-detail-shot' : ''}`}><div className="opening-stage">
      {expression ? <ExpressionDemo t={t} state={expressionFrame(t)}/> : <GhostDemo t={t} state={ghostFrame(t)}/>}
    </div></div>
    <div className="opening-caption"><span>{caption.detail}</span>
      {t >= OPENING.suggestion && <kbd className={tabPressed || enterPressed ? 'pressed' : ''}>{key}</kbd>}
    </div>
  </AbsoluteFill>;
}

export const OpeningRoot = () => <Composition id="LingroveOpening" component={OpeningFilm}
  width={1280} height={720} fps={OPENING.fps} durationInFrames={OPENING.duration * OPENING.fps}/>;
