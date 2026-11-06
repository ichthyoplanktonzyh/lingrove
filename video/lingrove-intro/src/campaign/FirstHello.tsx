import React from 'react';
import {AbsoluteFill, Img, Sequence, staticFile, useVideoConfig} from 'remotion';
import {Audio} from '@remotion/media';
import {OpeningDemo} from '../components/BookshopDemo';
import DictionaryDemo from '../components/DictionaryDemo';
import ReadingDemo from '../components/ReadingDemo';
import ReviewDemo from '../components/ReviewDemo';
import {Camera, CameraKey, Caption, Cursor, Mark, useTime} from './camera';
import {MessageHost} from './MessageHost';
import {captionAt,featureAt,featuresFor,lerp,p} from './timeline';
import {DemoLocale, DemoLocaleProvider, filmCopy, useDemoLocale} from '../demo-copy';
import './first-hello.css';

/** Act one supplies a concrete reason to write. The invitation card, its call to action and
 * the next message share the same destination; the invitation is an event, not background art. */
function Invitation() {
  const locale=useDemoLocale(), copy=filmCopy(locale);
  const t=useTime(), approach=p(t,2.5,4.05), exit=p(t,5.4,6);
  return <AbsoluteFill className="hello-film hello-paper">
    <div className="hello-sun" style={{transform:`translate(${lerp(120,0,p(t,0,1.2))}px,0) scale(${1-exit*.3})`}}/>
    <div className="hello-invite-block" style={{opacity:1-p(t,2.1,2.75),transform:`translateY(${-approach*60}px)`}}>
      <div className="hello-invite-eyebrow"><b>I · INVITATION</b><span>PAPER &amp; PINE BOOKSHOP</span></div>
      <div className="hello-invite-title"><span>{copy.invitation[0]}</span><br/>{copy.invitation[1]}</div>
    </div>
    <div className="hello-bookshop" style={{left:lerp(540,190,approach),top:lerp(98,84,approach),transform:`perspective(1500px) rotateY(${lerp(-14,0,approach)}deg) rotateZ(${lerp(4.5,0,approach)}deg) scale(${lerp(.8,1.0,approach)})`,opacity:1-exit*.4,translate:`0 ${-exit*25}px`,'--cta-scale':t>=5.1&&t<5.4?.95:1} as React.CSSProperties}><OpeningDemo t={Math.min(4,t)}/></div>
    {t>4&&t<5.5&&<Cursor x={lerp(560,368,p(t,4,4.65))} y={lerp(520,492,p(t,4,4.65))} press={t>=5.1}/>}
    <Caption>{captionAt(0,locale)}</Caption>
  </AbsoluteFill>;
}

const WRITE_CAMERA:CameraKey[]=[
  {at:6,cx:600,cy:315,zoom:1.0},{at:7.2,cx:545,cy:250,zoom:1.28},
  {at:11.4,cx:545,cy:250,zoom:1.28},{at:12.3,cx:575,cy:305,zoom:1.26},
  {at:17.5,cx:575,cy:305,zoom:1.26},{at:18.6,cx:610,cy:345,zoom:1.22},
  {at:23.5,cx:610,cy:345,zoom:1.22},{at:24.5,cx:600,cy:320,zoom:1.04},
  {at:27,cx:600,cy:320,zoom:1.04},{at:27.7,cx:590,cy:340,zoom:1.12},
  {at:30,cx:590,cy:340,zoom:1.12},
];
function Exchange() {
  const locale=useDemoLocale();
  const t=useTime()+6;
  return <AbsoluteFill className="hello-film hello-paper">
    <Camera t={t} keys={WRITE_CAMERA}><MessageHost t={t}/></Camera>
    <Caption>{captionAt(t,locale)}</Caption>
  </AbsoluteFill>;
}

/** Hover-based reading lookup (`LearningReadingSource.pointer`): while browsing the bookshop's
 * journal, the user simply points the cursor at an unfamiliar phrase (`come together`) — with zero
 * selection highlight or pre-hover UI on the page — and presses the shortcut (`⌃⇧T`) to pop up
 * the lookup card directly. */
function HoverLookup() {
  const locale=useDemoLocale(), copy=filmCopy(locale);
  const t=useTime();
  const move=p(t,.45,1.55), pressed=t>=1.9&&t<2.4;
  const cardIn=p(t,2.05,2.55);
  const uiTime=t<2.05?0:3.55+Math.min(2.2,(t-2.05)*1.05);
  const keys:CameraKey[]=[
    {at:0,cx:600,cy:355,zoom:.98},{at:1.1,cx:600,cy:355,zoom:.98},
    {at:2.05,cx:520,cy:375,zoom:1.18},{at:7.2,cx:520,cy:375,zoom:1.18},
  ];
  const cursorX=lerp(420,192,move), cursorY=lerp(435,342,move);
  const hudIn=p(t,1.15,1.55)*(1-p(t,6.4,6.9));
  const style={
    '--lookup-card-y':`${lerp(10,0,cardIn)}px`,
    '--lookup-card-s':lerp(.94,1,cardIn),
    '--lookup-card-opacity':cardIn,
  } as React.CSSProperties;
  return <AbsoluteFill className="hello-film hello-paper">
    <Camera t={t} keys={keys}>
      <div className="hello-reading-stage" style={style}>
        <ReadingDemo t={uiTime}/>
        <Cursor x={cursorX} y={cursorY}/>
      </div>
    </Camera>
    {hudIn>.01&&<div className={`hello-keystroke-hud ${pressed?'is-pressed':''}`} style={{opacity:hudIn,transform:`translateY(${lerp(12,0,p(t,1.15,1.55))}px) scale(${pressed?.96:1})`}}>
      <div className="hello-keystroke-meta">
        <i></i>
        <span>{copy.shortcut}</span>
      </div>
      <div className="hello-keystroke-keys">
        <kbd>⌃</kbd><span>+</span><kbd>⇧</kbd><span>+</span><kbd>T</kbd>
      </div>
    </div>}
    <Caption>{captionAt(30+t,locale)}</Caption>
  </AbsoluteFill>;
}

/** A selected phrase lifts from the sent message into its real dictionary component. The
 * source remains visible behind a frosted scrim, preserving context without visual clutter. */
function SavePhrase() {
  const locale=useDemoLocale(), copy=filmCopy(locale);
  const t=useTime(), enter=p(t,.45,1.6);
  return <AbsoluteFill className="hello-film hello-charcoal">
    <div className="hello-source-message" style={{opacity:lerp(.55,.18,enter),filter:`blur(${lerp(2,9,enter)}px)`,transform:`perspective(1400px) rotateY(${lerp(0,12,enter)}deg) scale(${lerp(.84,.72,enter)}) translateX(${-enter*120}px)`}}><MessageHost t={30.1} backdrop={false}/></div>
    <div className="hello-phrase-block" style={{opacity:p(t,.85,1.65),transform:`translateY(${lerp(28,0,p(t,.85,1.65))}px)`}}>
      <div className="hello-phrase-eyebrow"><b>SAVED EXPRESSION</b><span>FROM YOUR SENT NOTE</span></div>
      <div className="hello-phrase-title">look<br/><em>forward</em><br/>to<span>.</span></div>
      <div className="hello-phrase-gloss">{copy.gloss}{locale==='en'?'':' · '}<span>{copy.grammar}</span></div>
    </div>
    <div className="hello-dictionary" style={{left:lerp(420,660,enter),top:lerp(260,86,enter),opacity:p(t,.4,1.0)}}><div style={{width:900,height:520,zoom:lerp(.78,1.06,enter),transformOrigin:'0 0',transform:enter<1?`perspective(1100px) rotateY(${lerp(-14,0,enter)}deg) rotateX(${lerp(9,0,enter)}deg)`:undefined}}><DictionaryDemo t={2.1+t*.92} isolated/></div></div>
    <Caption light>{captionAt(t+37.2,locale)}</Caption>
  </AbsoluteFill>;
}

/** Adapted row-embed: one saved entry falls into its actual list slot, rotates flat, and
 * briefly compresses on contact. The same reused notebook supplies both slot and final text. */
function FileExpression() {
  const locale=useDemoLocale();
  const t=useTime();
  const air=1-p(t,.6,1.2), press=t<1.2?1.06-.065*(1-air):lerp(.995,1,p(t,1.2,1.34));
  const keys:CameraKey[]=[{at:0,cx:595,cy:355,zoom:.96},{at:1.4,cx:595,cy:355,zoom:.96},{at:2.3,cx:655,cy:360,zoom:1.18},{at:6,cx:655,cy:360,zoom:1.18}];
  const style={ '--row-y':`${-160*air}px`,'--row-r':`${16*air}deg`,'--row-scale':press,'--row-opacity':p(t,.55,.7),'--detail-opacity':p(t,1.2,1.8) } as React.CSSProperties;
  return <AbsoluteFill className="hello-film hello-paper">
    <Camera t={t} keys={keys}><div className="hello-notebook row-arrival" style={style}><ReviewDemo t={Math.max(0,t-1.8)}/></div></Camera>
    <Caption>{captionAt(43.2+t,locale)}</Caption>
  </AbsoluteFill>;
}

function Recall() {
  const locale=useDemoLocale();
  const t=useTime();
  const flip=t<3.4?p(t,3.05,3.4):1-p(t,3.4,3.75);
  const ui=t<1.1?5.4+t*1.72:t<3.4?7.3+(t-1.1)/2.3*2.69:t<5.8?10+(t-3.4)/2.4*3.5:13.7;
  const keys:CameraKey[]=[{at:0,cx:600,cy:355,zoom:.96},{at:1.1,cx:600,cy:355,zoom:.96},{at:1.8,cx:665,cy:375,zoom:1.16},{at:7.2,cx:665,cy:375,zoom:1.16}];
  return <AbsoluteFill className="hello-film hello-paper">
    <Camera t={t} keys={keys}><div className="hello-notebook hello-recall" style={{'--flip':`${flip*88}deg`} as React.CSSProperties}><ReviewDemo t={ui}/></div></Camera>
    <Caption>{captionAt(49.2+t,locale)}</Caption>
  </AbsoluteFill>;
}

function Later() {
  const locale=useDemoLocale(), copy=filmCopy(locale);
  const t=useTime(), intro=p(t,.75,1.4);
  return <AbsoluteFill className="hello-film hello-paper">
    <div className="hello-later-block" style={{opacity:1-intro,transform:`translateY(${-intro*55}px)`}}>
      <div className="hello-invite-eyebrow"><b>II · AFTER THE GATHERING</b><span>FRIDAY NIGHT · 9:40 PM</span></div>
      <div className="hello-later-title">{copy.later}<span>{locale==='en'?'.':'。'}</span></div>
    </div>
    <div className="hello-after-ticket" style={{opacity:p(t,.2,.75)*(1-p(t,.75,1.25)),transform:`rotate(-6deg) translateY(${lerp(55,0,p(t,.2,.75))-p(t,.75,1.25)*35}px)`}}><b>PAPER &amp; PINE</b><span>BOOK<br/>CLUB</span><small>GOOD STORIES. GOOD COMPANY.</small></div>
    <div style={{opacity:intro}}><Camera t={t} keys={[{at:0,cx:600,cy:320,zoom:.98},{at:1.35,cx:600,cy:320,zoom:.98},{at:2.1,cx:575,cy:310,zoom:1.24},{at:4.5,cx:575,cy:310,zoom:1.24},{at:5.2,cx:600,cy:320,zoom:1.02},{at:6,cx:600,cy:320,zoom:1.02}]}><MessageHost t={49.2+t} later/></Camera></div>
    {t>1.4&&<Caption>{captionAt(58,locale)}</Caption>}
  </AbsoluteFill>;
}

function Finish() {
  const locale=useDemoLocale(), copy=filmCopy(locale);
  const t=useTime();
  return <AbsoluteFill className="hello-film hello-vermilion">
    <div className="hello-end-colophon"><span>LINGROVE · 拾语</span><span>A WRITING &amp; MEMORY COMPANION FOR MAC</span></div>
    <div className="hello-end-copy" style={{clipPath:`inset(${100*(1-p(t,.15,.95))}% 0 0 0)`}}>{copy.finish[0]}<br/>{copy.finish[1]}<span>{copy.finish[2]}</span></div>
    <div className="hello-end-lockup" style={{opacity:p(t,.95,1.55),transform:`translateY(${lerp(24,0,p(t,.95,1.55))}px)`}}>
      <Img src={staticFile('lingrove-logo.svg')}/>
      <div><span>Lingrove <small>拾语</small></span><p>{copy.tagline}</p></div>
    </div>
    <ol className="hello-end-recap">{featuresFor(locale).map((f,i)=>{const v=p(t,1.05+i*.1,1.48+i*.1);
      return <li key={f.index} style={{opacity:v,transform:`translateX(${lerp(18,0,v)}px)`}}><b>{f.index}</b><span>{f.name}</span><small>{f.hint}</small></li>;})}</ol>
    <div className="hello-end-local" style={{opacity:p(t,2.0,2.6)}}><span>LOCAL-FIRST ON MAC</span><i>·</i><span>{copy.local}</span></div>
  </AbsoluteFill>;
}

/** One overlay owns the editorial header, feature folio, and film finish for the whole composition,
 * so neither remounts at Sequence boundaries. Soft paper washes bridge hard scene cuts. */
function FilmOverlay({dark}:{dark:(t:number)=>boolean}) {
  const locale=useDemoLocale();
  const t=useTime(), f=featureAt(t,locale), isDark=dark(t), isEnd=t>=62.4;
  const v=f?p(t,f.start,f.start+.35)*(1-p(t,f.end-.3,f.end)):0;
  const cuts=[6,30,37.2,43.2,49.2,56.4,62.4];
  const wash=Math.max(0,...cuts.map(c=>Math.max(0,1-Math.abs(t-c)/.22)*.55));
  return <>
    {!isEnd&&<header className={`hello-editorial-head ${isDark?'on-dark':''}`}>
      <Mark light={isDark}/>
      <div className="hello-head-rule"/>
      {f?<div className="hello-kicker" style={{opacity:v,transform:`translateY(${lerp(-8,0,v)}px)`}}>
        <b>{f.index}</b><span>{f.name}</span><small>{f.hint}</small>
      </div>:<div className="hello-head-chapter">{t<6?'PROLOGUE · THE INVITATION':t<30?'ACT I · FIRST MESSAGE':'EPILOGUE · NEXT MEETING'}</div>}
    </header>}
    {wash>.01&&<div className="hello-wash" style={{opacity:wash}}/>}
    <div className="hello-vignette"/><div className="hello-grain"/>
  </>;
}

/** Existing approved assets and core promises are preserved; this composition owns a new
 * story, palette and camera system. Audio stems allow the same edit with or without music. */
export function FirstHello({bgm=true,locale='zh-CN'}:{bgm?:boolean;locale?:DemoLocale}) {
  const {fps}=useVideoConfig();
  return <DemoLocaleProvider locale={locale}><AbsoluteFill className={`hello-language-${locale}`} lang={locale} style={{'--review-source':JSON.stringify(filmCopy(locale).source)} as React.CSSProperties}>
    <Sequence name="看到邀请" durationInFrames={6*fps}><Invitation/></Sequence>
    <Sequence name="同一封消息：补全、表达、翻译、发送、回复" from={6*fps} durationInFrames={24*fps}><Exchange/></Sequence>
    <Sequence name="阅读手记：鼠标悬停查词" from={30*fps} durationInFrames={Math.round(7.2*fps)}><HoverLookup/></Sequence>
    <Sequence name="留下刚用过的表达" from={Math.round(37.2*fps)} durationInFrames={6*fps}><SavePhrase/></Sequence>
    <Sequence name="表达落入语料库" from={Math.round(43.2*fps)} durationInFrames={6*fps}><FileExpression/></Sequence>
    <Sequence name="再次回想" from={Math.round(49.2*fps)} durationInFrames={Math.round(7.2*fps)}><Recall/></Sequence>
    <Sequence name="活动之后，主动使用" from={Math.round(56.4*fps)} durationInFrames={6*fps}><Later/></Sequence>
    <Sequence name="从敢说到会说" from={Math.round(62.4*fps)} durationInFrames={Math.round(4.8*fps)}><Finish/></Sequence>
    <FilmOverlay dark={t=>t>=37.2&&t<43.2}/>
    {bgm&&<Audio src={staticFile('audio/first-hello-music.m4a')}/>}
    <Audio src={staticFile('audio/first-hello-foley.m4a')}/>
  </AbsoluteFill></DemoLocaleProvider>;
}
