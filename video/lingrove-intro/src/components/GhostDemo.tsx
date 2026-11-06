import React from 'react';
import './ghost.css';

/** A self-contained, time-addressable recreation of inline completion in a host editor.
 * The caller owns the clock, so seeking and rendering individual Remotion frames are deterministic.
 */
export const GHOST_DEMO_DURATION = 10;

const prefix = 'Hi! I saw your book club event and ';
// With the default add-space setting off, whitespace belongs to the following word.
const chunks = ['I’d', ' love', ' to', ' join.'];
const acceptAt = [5.45, 6.15, 6.85, 7.55];

export function GhostDemo({t}: {t: number}) {
  // Slightly uneven keystroke intervals make the prefix read like human input, while remaining
  // a pure function of video time. Tab consumes only the next chunk of the same suggestion.
  const count = Array.from(prefix).reduce((n, _, i) => n + (t >= 0.35 + i * 0.079 + Math.floor(i / 8) * 0.08 ? 1 : 0), 0);
  const typed = prefix.slice(0, count);
  const visible = t >= 3.75;
  const acceptedCount = acceptAt.filter((time) => t >= time).length;
  const accepted = visible ? chunks.slice(0, acceptedCount).join('') : '';
  const remaining = visible ? chunks.slice(acceptedCount).join('') : '';
  const caretOpacity = remaining || t < 3.75 ? 1 : (Math.floor(t * 2) % 2 === 0 ? 1 : 0);

  return <div className="lg-ghost-demo">
    <div className="lg-ghost-window">
      <div className="lg-ghost-titlebar">
        <div className="lg-ghost-lights"><i/><i/><i/></div>
        <span>给书店发消息</span><span className="lg-ghost-more">···</span>
      </div>
      <div className="lg-ghost-recipient"><span>收件人：</span><b>Paper &amp; Pine Bookshop</b></div>
      <div className="lg-ghost-editor">
        <div className="lg-ghost-text">{typed}{accepted}<span className="lg-ghost-caret" style={{opacity: caretOpacity}}/><span className="lg-ghost-completion">{remaining}</span>{remaining && <span className="lg-ghost-keycap">Tab</span>}</div>
      </div>
      <div className="lg-ghost-bottom"><span>✦</span><span className="lg-ghost-send">↑</span></div>
    </div>
  </div>;
}

export default GhostDemo;
