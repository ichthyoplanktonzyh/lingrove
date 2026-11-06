import React from 'react';
import {AbsoluteFill, Composition, interpolate, staticFile, useCurrentFrame} from 'remotion';
import GhostDemo from './components/GhostDemo';
import ExpressionDemo from './components/ExpressionDemo';
import TranslationDemo from './components/TranslationDemo';
import DictionaryDemo from './components/DictionaryDemo';
import ReadingDemo from './components/ReadingDemo';
import ReviewDemo from './components/ReviewDemo';
import {OpeningDemo, ReplyDemo} from './components/BookshopDemo';
import './director.css';
import './story.css';

const fps = 24;
type Scene = {duration:number; label:string; title:React.ReactNode; View:React.ComponentType<{t:number}>};
const ConfirmTranslation = ({t}:{t:number}) => <TranslationDemo t={t+7.4}/>;

/** One synthetic message closes the writing sequence before the story returns to reading. */
function SendMessage({t}:{t:number}) {
  const sent = t >= 2.25;
  return <div className="story-message-host"><div className="story-message-window">
    <div className="story-message-title"><div className="story-message-lights"><i/><i/><i/></div>给书店发消息 <span>···</span></div>
    <div className="story-message-recipient"><span>收件人：</span> Paper &amp; Pine Bookshop</div>
    <div className="story-message-content">Hi! I saw your book club event and I’d love to join.<br/><br/>I’m a little nervous, but I’d like to give it a try.<br/><br/>I’m looking forward to sharing my thoughts with everyone.</div>
    <div className="story-message-toolbar"><span>✦</span><span className={sent?'story-sent':'story-send'}>{sent ? '已发送 ✓' : '↑'}</span></div>
    {t >= 1 && t < 2.4 && <div className="story-message-pointer" style={{left: `${91 - Math.min(1,(t-1)/1)*2}%`, top:`${86 - Math.min(1,(t-1)/1)*2}%`}}><svg width="23" height="29" viewBox="0 0 23 29" fill="none"><path d="M2 1.5v20l5.1-4.8 3.9 9.2 3.4-1.5-3.9-9.1 7.1-.3L2 1.5Z" fill="#17191d" stroke="white" strokeWidth="1.7" strokeLinejoin="round"/></svg></div>}
  </div></div>;
}
function EndCard() { return <div className="story-end"><img src={staticFile('lingrove-logo.svg')}/><div>Lingrove <span>拾语</span></div><p>写作时，自然积累语言。</p></div>; }

// The translation preview pauses for lookup. Returning at t=7.4 shows the explicit replacement,
// so the original sentence never reappears after it was replaced in the story.
const scenes:Scene[] = [
  {duration:5,label:'故事的开始',title:<>有些想法，<br/><em>想与人分享。</em></>,View:OpeningDemo},
  {duration:10,label:'自动补全',title:<>让想法，<br/><em>自然继续。</em></>,View:GhostDemo},
  {duration:11,label:'表达辅助',title:<>想说的意思，<br/><em>总有一种表达。</em></>,View:ExpressionDemo},
  {duration:8,label:'写作翻译',title:<>先写下想法。<br/><em>再决定如何表达。</em></>,View:TranslationDemo},
  {duration:9,label:'收集表达',title:<>在真实语境里，<br/><em>留下值得记住的话。</em></>,View:DictionaryDemo},
  {duration:3.5,label:'写作翻译',title:<>看过译文，<br/><em>再决定使用。</em></>,View:ConfirmTranslation},
  {duration:4,label:'一封消息',title:<>把想说的话，<br/><em>送给远方的人。</em></>,View:SendMessage},
  {duration:9,label:'阅读理解',title:<>阅读时遇见，<br/><em>就在此刻理解。</em></>,View:ReadingDemo},
  {duration:15,label:'语料与复习',title:<>遇见过的语言，<br/><em>慢慢成为自己的语言。</em></>,View:ReviewDemo},
  {duration:5,label:'故事继续',title:<>每一次表达，<br/><em>都通向新的相遇。</em></>,View:ReplyDemo},
  {duration:5,label:'LINGROVE 拾语',title:<>写作时，<br/><em>自然积累语言。</em></>,View:EndCard},
];
const total = scenes.reduce((sum,scene)=>sum+scene.duration,0);
const clamp = {extrapolateLeft:'clamp' as const, extrapolateRight:'clamp' as const};
function StoryFilm() {
  const time=useCurrentFrame()/fps;
  let elapsed=0, index=0;
  while(index<scenes.length-1 && time>=elapsed+scenes[index].duration){elapsed+=scenes[index].duration;index++;}
  const scene=scenes[index], t=time-elapsed, View=scene.View;
  const opacity=Math.min(interpolate(t,[0,.35],[0,1],clamp),interpolate(t,[scene.duration-.35,scene.duration],[1,0],clamp));
  return <AbsoluteFill className="film"><div className="film-orb film-orb-a"/><div className="film-orb film-orb-b"/><div className="film-grain"/>
    <header className="film-header"><div className="film-brand"><img src={staticFile('lingrove-logo.svg')}/><span>Lingrove</span><small>拾语</small></div><div className="film-header-note">LANGUAGE, IN THE FLOW OF LIFE</div></header>
    <div className="film-scene" style={{opacity}}><aside className="film-copy"><div className="film-chapter"><span>{String(index+1).padStart(2,'0')}</span><i/>{scene.label}</div><h1>{scene.title}</h1><div className="film-copy-rule"/><p>让每一次表达，<br/>都更靠近你想说的。</p></aside><div className="film-stage"><div className="film-window"><View t={t}/></div></div></div>
    <footer className="film-footer"><span>LINGROVE　/　拾语</span><div className="film-progress"><div style={{width:`${time/total*100}%`}}/></div><span>一段写作的旅程</span></footer>
  </AbsoluteFill>;
}
export const StoryRoot=()=> <Composition id="LingroveStory" component={StoryFilm} width={1280} height={720} fps={fps} durationInFrames={total*fps}/>;
