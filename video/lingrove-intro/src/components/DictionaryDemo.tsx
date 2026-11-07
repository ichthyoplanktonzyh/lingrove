import React from 'react';
import {useLearningStory} from '../campaign/learning-story';
import {useDemoText} from '../demo-copy';
import {staticFile} from 'remotion';
import './dictionary.css';
const ease = (n: number) => { const x = Math.max(0, Math.min(1, n)); return 1 - (1 - x) ** 3; };
/** Reconstructs the sentence and dictionary cards from synthetic data, entirely from the supplied time. */
export default function DictionaryDemo({t, isolated = false}: {t: number; isolated?: boolean}) {
  const text=useDemoText(), story=useLearningStory();
  const selected = t >= 1.8, card = ease((t - 2.05) / .45), saved = t >= 6.52;
  const a = ease((t - .55) / .8), b = ease((t - 4.55) / 1.25);
  const pressed = (t >= 1.45 && t < 1.55) || (t >= 1.7 && t < 1.8) || (t >= 6.15 && t < 6.35);
  // 期待 has no entry in the bundled expression subset. Show the existing contextual
  // explanation surface instead of assigning a fabricated definition to that dictionary.
  if (story) return <div className={`dictionary-demo ${isolated?'dictionary-isolated':''}`}><div className="dictionary-window">
    <div className="dictionary-card" style={{opacity:card}}>
      <div className="dictionary-card-header"><span>{text('语境释义')}</span><div className="dictionary-actions"><span>✧</span><span className={`dictionary-fish ${saved?'saved':''}`} style={{transform:`scale(${t>=6.15&&t<6.35?.92:1})`}}>{t>=6.35&&t<6.52?<span className="dictionary-pending"/>:<img src={staticFile(saved?'fish-filled.svg':'fish-outline.svg')}/>}</span><span>◖))</span><span>×</span></div></div>
      <div className="dictionary-title">{story.term}</div><div className="dictionary-form">{text('中文 → English')}</div>
      <div className="dictionary-segments"><span className="active">{text('语境释义')}</span><span>{text('词典释义')}</span></div>
      <div className="dictionary-content"><div className="dictionary-pos">verb</div><div>{story.meaning}</div><div className="dictionary-chips"><span>{story.term}</span></div><div className="dictionary-example"><div>{text('本次例句')}</div><p>{story.beforeTerm}<mark>{story.term}</mark>{story.afterTerm}</p><p>{story.source}</p></div></div>
    </div>
    {t>=(isolated?5.4:.55)&&t<7.05&&<div className="dictionary-pointer" style={{left:705-(isolated?445:0),top:140-(isolated?120:0),transform:`scale(${pressed?.85:1})`}}><svg width="23" height="29" viewBox="0 0 23 29" fill="none"><path d="M2 1.5v20l5.1-4.8 3.9 9.2 3.4-1.5-3.9-9.1 7.1-.3L2 1.5Z" fill="#17191d" stroke="white" strokeWidth="1.7" strokeLinejoin="round"/></svg></div>}
  </div></div>;
  return <div className={`dictionary-demo ${isolated ? 'dictionary-isolated' : ''}`}><div className="dictionary-window">
    <div className="dictionary-bar"><div className="dictionary-lights"><i/><i/><i/></div><span>{text('给书店发消息')}</span><div className="dictionary-bar-spacer"/></div>
    <div className="dictionary-address"><span>{text('收件人：')}</span> Paper &amp; Pine Bookshop</div>
    <div className="dictionary-letter">Hi! I saw your book club event and I’d love to join.<br/><br/>I’m a little nervous, but I’d like to give it a try.<br/><br/>我很期待和大家分享我的想法。<span className="dictionary-caret"/></div>
    <div className="dictionary-sentence"><div className="dictionary-sentence-head"><span>◒ &nbsp;English</span><span>✧ &nbsp; <img className="dictionary-header-fish" src={staticFile("fish-outline.svg")}/> &nbsp; ◖)) &nbsp;│&nbsp; ⇄ &nbsp;⌄ &nbsp; ×</span></div><div>I’m <span className={selected ? 'dictionary-term selected' : 'dictionary-term'}>looking forward to</span> sharing my thoughts with everyone.</div></div>
    <div className="dictionary-card" style={{opacity:card}}>
      <div className="dictionary-card-header"><span>{text('内置表达词库')} <small>⌄</small></span><div className="dictionary-actions"><span>✧</span><span className={`dictionary-fish ${saved?'saved':''}`} style={{transform:`scale(${t>=6.15&&t<6.35?.92:1})`}}>{t >= 6.35 && t < 6.52 ? <span className="dictionary-pending"/> : <img src={staticFile(saved?'fish-filled.svg':'fish-outline.svg')}/> }</span><span>◖))</span><span>×</span></div></div>
      <div className="dictionary-title">looking forward to</div><div className="dictionary-form">{text('英语 → 英语')}</div><div className="dictionary-form">{text('词典词形：')}look forward to</div>
      <div className="dictionary-segments"><span>{text('语境释义')}</span><span className="active">{text('词典释义')}</span></div>
      <div className="dictionary-content"><div className="dictionary-pos">verb · idiomatic, transitive</div><div>1. To anticipate, expect, or wait for, especially with a feeling of approval or pleasure; to be excited or eager to.</div><div className="dictionary-source">Wiktionary / Kaikki</div><div className="dictionary-chips"><span>look</span><span>forward</span><span>to</span></div><div className="dictionary-example"><div>{text('本次例句')}</div><p>I’m <mark>looking forward to</mark> sharing my thoughts with everyone.</p><p>我很期待和大家分享我的想法。</p></div></div>
      <div className="dictionary-attribution">Wiktionary contributors / Kaikki · CC BY-SA 4.0</div>
    </div>
    {t>=(isolated?5.4:.55)&&t<7.05&&<div className="dictionary-pointer" style={{left:(t<4.55?300-a*70:230+b*475)-(isolated?445:0),top:(t<4.55?330-a*74:256-b*116)-(isolated?120:0),transform:`scale(${pressed?.85:1})`}}><svg width="23" height="29" viewBox="0 0 23 29" fill="none"><path d="M2 1.5v20l5.1-4.8 3.9 9.2 3.4-1.5-3.9-9.1 7.1-.3L2 1.5Z" fill="#17191d" stroke="white" strokeWidth="1.7" strokeLinejoin="round"/></svg></div>}
  </div></div>;
}
