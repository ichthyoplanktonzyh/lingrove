import React from 'react';
import {useLearningStory} from '../campaign/learning-story';
import {useDemoText} from '../demo-copy';
import {staticFile} from 'remotion';
import './reading.css';
const clamp = (n: number) => Math.max(0, Math.min(1, n));
/** A fictional reading session, driven entirely by the caller's time in seconds. */
export default function ReadingDemo({t}: {t: number}) {
  const text=useDemoText(), story=useLearningStory();
  const selected = t >= 1.65;
  const icon = clamp((t - 2.05) / .3) * (1 - clamp((t - 3.55) / .2));
  const card = clamp((t - 3.55) / .35);
  const result = clamp((t - 4.65) / .35);
  const move = clamp((t - 2.65) / .65);
  if (story) return <div className="reading-demo reading-chinese"><div className="reading-window">
    <div className="reading-browser"><div className="reading-lights"><i/><i/><i/></div><div className="reading-address">⌑ &nbsp; songjian.example / journal</div><span>↗</span></div>
    <div className="reading-page"><div className="reading-nav"><span>{story.bookshop}</span><div>书籍　　活动　　手记</div></div>
      <div className="reading-content"><div className="reading-kicker">书店手记 / 读书会</div><h1>{story.reading.title[0]}<br/><em>{story.reading.title[1]}</em></h1><div className="reading-meta">周五 · 19:30 · 中文交流</div><div className="reading-rule"/>
        <p>{story.reading.intro}</p><p><span>{story.term}</span>{story.reading.after}</p><p className="reading-faded">{story.reading.outro}</p></div>
      <div className="reading-side"><div className="reading-side-art"><span>✳</span><strong>一本书，<br/>一段对话。</strong><small>松间书店<br/>中文读书会</small></div><div className="reading-side-caption">一起读书，也一起练习中文</div></div></div>
    <div className="reading-lookup" style={{opacity:card}}><div className="reading-lookup-head"><span>{text('中文 → English')}</span><div><b className="reading-sparkle">✧</b><b className="reading-fish"><img src={staticFile('fish-outline.svg')}/></b><b className="reading-speaker">◖))</b><b>×</b></div></div>
      <div className="reading-word">{story.term}</div><div className="reading-label-space">&nbsp;</div><div className="reading-segment"><span>{text('语境释义')}</span><span>{text('词典')}</span></div>
      <div className="reading-result">{result>=.5&&<strong style={{opacity:result}}>{story.gloss}</strong>}<p><mark>{story.term}</mark>{story.reading.after}</p>{result>=.5?<><p className="reading-translation" style={{opacity:result}}>{story.reading.translation}</p><div className="reading-details">▸ &nbsp;{text('详解')}</div></>:<div className="reading-loading">{text('正在解释…')}</div>}<div className="reading-words"><span>{story.term}</span></div></div>
    </div>
  </div></div>;
  return <div className="reading-demo"><div className="reading-window">
    <div className="reading-browser"><div className="reading-lights"><i/><i/><i/></div><div className="reading-address">⌑ &nbsp; paperandpine.book / journal</div><span>↗</span></div>
    <div className="reading-page"><div className="reading-nav"><span>PAPER &amp; PINE</span><div>BOOKS &nbsp;&nbsp;&nbsp; EVENTS &nbsp;&nbsp;&nbsp; JOURNAL</div></div>
      <div className="reading-content"><div className="reading-kicker">FROM OUR BOOKSHOP &nbsp; / &nbsp; EVENTS</div><h1>An evening for<br/><em>stories and strangers.</em></h1><div className="reading-meta">OCTOBER 18 &nbsp; · &nbsp; 4 MIN READ</div><div className="reading-rule"/>
        <p>Every Thursday, we open our doors a little later. Readers gather around the long table, bringing a book, a question, or simply their curiosity.</p>
        <p>It’s a chance to <span className={selected ? 'reading-selected' : ''}>come together</span> over stories that stay with us long after the last page.</p><p className="reading-faded">There is always room for another chair.</p></div>
      <div className="reading-side"><div className="reading-side-art"><span>✳</span><strong>STORIES<br/>SHARED<br/>HERE.</strong><small>PAPER &amp; PINE<br/>BOOKSHOP &amp; COMMUNITY</small></div><div className="reading-side-caption">A PLACE TO READ, MEET &amp; BELONG</div></div></div>
    <div className="reading-affordance" style={{opacity: icon, transform: `translateY(${(1-icon)*5}px)`}}><span className="reading-whale"/></div>
    <div className="reading-lookup" style={{opacity: card}}><div className="reading-lookup-head"><span>{text('English → 中文')}</span><div><b className="reading-sparkle">✧</b><b className="reading-fish"><img src={staticFile('fish-outline.svg')}/></b><b className="reading-speaker">◖))</b><b>×</b></div></div><div className="reading-word">come together</div><div className="reading-label-space">&nbsp;</div><div className="reading-segment"><span>{text('语境释义')}</span><span>{text('词典')}</span></div><div className="reading-result">{result >= .5 && <strong style={{opacity: result}}>相聚；聚在一起</strong>}<p>It’s a chance to <mark>come together</mark> over stories that stay with us long after the last page.</p>{result >= .5 ? <><p className="reading-translation" style={{opacity: result}}>这是一个相聚的机会，分享那些读完最后一页仍萦绕心头的故事。</p><div className="reading-details">▸ &nbsp;{text('详解')}</div></> : <div className="reading-loading">{text('正在解释…')}</div>}<div className="reading-words"><span>come</span><span>together</span></div></div></div>
    {t >= 2.65 && t < 3.6 && <div className="reading-pointer" style={{left: `${36 - move * 10}%`, top: `${90 - move * 10}%`, transform: `scale(${t >= 3.35 && t < 3.53 ? .85 : 1})`}}><svg width="23" height="29" viewBox="0 0 23 29" fill="none"><path d="M2 1.5v20l5.1-4.8 3.9 9.2 3.4-1.5-3.9-9.1 7.1-.3L2 1.5Z" fill="#17191d" stroke="white" strokeWidth="1.7" strokeLinejoin="round"/></svg></div>}
  </div></div>;
}
