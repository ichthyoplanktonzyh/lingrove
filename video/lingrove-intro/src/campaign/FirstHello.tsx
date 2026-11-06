import React from 'react';
import {AbsoluteFill, Img, Sequence, staticFile, useVideoConfig} from 'remotion';
import {Audio} from '@remotion/media';
import {OpeningDemo} from '../components/BookshopDemo';
import DictionaryDemo from '../components/DictionaryDemo';
import ReviewDemo from '../components/ReviewDemo';
import {Camera, CameraKey, Caption, Cursor, Mark, useTime} from './camera';
import {MessageHost} from './MessageHost';
import {captionAt,featureAt,FEATURES,lerp,p} from './timeline';
import './first-hello.css';

/** Act one supplies a concrete reason to write. The invitation card, its call to action and
 * the next message share the same destination; the invitation is an event, not background art. */
function Invitation() {
  const t=useTime(), approach=p(t,2.7,4.05), exit=p(t,5.4,6);
  return <AbsoluteFill className="hello-film hello-paper"><Mark/>
    <div className="hello-sun" style={{transform:`translate(${lerp(120,0,p(t,0,1.2))}px,0) scale(${1-exit*.3})`}}/>
    <div className="hello-invite-title" style={{opacity:1-p(t,2.7,3.2),transform:`translateY(${-approach*90}px)`}}><span>想去。</span><br/>但怎么开口？</div>
    <div className="hello-bookshop" style={{left:lerp(570,95,approach),top:lerp(105,72,approach),transform:`perspective(1400px) rotateY(${lerp(-16,0,approach)}deg) rotateZ(${lerp(6,0,approach)}deg) scale(${lerp(.8,1.2,approach)})`,opacity:1-exit,translate:`0 ${-exit*65}px`,'--cta-scale':t>=5.1&&t<5.4?.95:1} as React.CSSProperties}><OpeningDemo t={Math.min(4,t)}/></div>
    {t>4&&t<5.5&&<Cursor x={lerp(510,312,p(t,4,4.65))} y={lerp(565,585,p(t,4,4.65))} press={t>=5.1}/>}
    <Caption>{captionAt(0)}</Caption>
  </AbsoluteFill>;
}

const WRITE_CAMERA:CameraKey[]=[
  {at:6,cx:600,cy:390,zoom:.88},{at:7.2,cx:500,cy:285,zoom:1.38},
  {at:11.4,cx:500,cy:285,zoom:1.38},{at:12.3,cx:535,cy:350,zoom:1.3},
  {at:17.5,cx:535,cy:350,zoom:1.3},{at:18.6,cx:510,cy:420,zoom:1.3},
  {at:23.5,cx:510,cy:420,zoom:1.3},{at:24.5,cx:600,cy:400,zoom:.95},
  {at:27,cx:600,cy:400,zoom:.95},{at:27.7,cx:550,cy:440,zoom:1.08},
  {at:30,cx:550,cy:440,zoom:1.08},
];
function Exchange() {
  const t=useTime()+6;
  return <AbsoluteFill className={`hello-film ${t<18?'hello-paper':t<24?'hello-cool':'hello-paper'}`}>
    <div className="hello-stage-rule"/>
    <Camera t={t} keys={WRITE_CAMERA}><MessageHost t={t}/></Camera>
    <Caption>{captionAt(t)}</Caption>
  </AbsoluteFill>;
}

/** A selected phrase lifts from the sent message into its real dictionary component. The
 * source remains visible behind it, preserving what the word means in this specific exchange. */
function SavePhrase() {
  const t=useTime(), enter=p(t,.55,1.7);
  return <AbsoluteFill className="hello-film hello-charcoal"><Mark light/>
    <div className="hello-source-message" style={{opacity:lerp(.8,.2,enter),transform:`perspective(1400px) rotateY(${lerp(0,15,enter)}deg) scale(${lerp(.8,.65,enter)}) translateX(${-enter*150}px)`}}><MessageHost t={30.1}/></div>
    <div className="hello-phrase-title" style={{opacity:p(t,1.1,1.9),transform:`translateY(${lerp(40,0,p(t,1.1,1.9))}px)`}}>look<br/><em>forward</em><br/>to<span>.</span></div>
    <div className="hello-dictionary" style={{left:lerp(350,745,enter),top:lerp(315,80,enter),opacity:p(t,.55,1.0)}}><div style={{width:900,height:520,zoom:lerp(.75,1.2,enter),transformOrigin:'0 0',transform:enter<1?`perspective(1000px) rotateY(${lerp(-17,0,enter)}deg) rotateX(${lerp(12,0,enter)}deg)`:undefined}}><DictionaryDemo t={2.1+t*.92} isolated/></div></div>
    <Caption light>{captionAt(t+30)}</Caption>
  </AbsoluteFill>;
}

/** Adapted row-embed: one saved entry falls into its actual list slot, rotates flat, and
 * briefly compresses on contact. The same reused notebook supplies both slot and final text. */
function FileExpression() {
  const t=useTime();
  const air=1-p(t,.6,1.2), press=t<1.2?1.06-.065*(1-air):lerp(.995,1,p(t,1.2,1.34));
  const keys:CameraKey[]=[{at:0,cx:470,cy:320,zoom:1.02},{at:1.4,cx:470,cy:320,zoom:1.02},{at:2.3,cx:670,cy:360,zoom:1.35},{at:6,cx:670,cy:360,zoom:1.35}];
  const style={ '--row-y':`${-160*air}px`,'--row-r':`${16*air}deg`,'--row-scale':press,'--row-opacity':p(t,.55,.7),'--detail-opacity':p(t,1.2,1.8) } as React.CSSProperties;
  return <AbsoluteFill className="hello-film hello-paper"><Mark/>
    <Camera t={t} keys={keys}><div className="hello-notebook row-arrival" style={style}><ReviewDemo t={Math.max(0,t-1.8)}/></div></Camera>
    <Caption>{captionAt(36+t)}</Caption>
  </AbsoluteFill>;
}

function Recall() {
  const t=useTime();
  const flip=t<3.4?p(t,3.05,3.4):1-p(t,3.4,3.75);
  const ui=t<1.1?5.4+t*1.72:t<3.4?7.3+(t-1.1)/2.3*2.69:t<5.8?10+(t-3.4)/2.4*3.5:13.7;
  const keys:CameraKey[]=[{at:0,cx:600,cy:365,zoom:1.02},{at:1.1,cx:600,cy:365,zoom:1.02},{at:1.8,cx:710,cy:410,zoom:1.55},{at:7.2,cx:710,cy:410,zoom:1.55}];
  return <AbsoluteFill className="hello-film hello-cool">
    <Camera t={t} keys={keys}><div className="hello-notebook hello-recall" style={{'--flip':`${flip*88}deg`} as React.CSSProperties}><ReviewDemo t={ui}/></div></Camera>
    <Caption>{captionAt(42+t)}</Caption>
  </AbsoluteFill>;
}

function Later() {
  const t=useTime(), intro=p(t,.7,1.35);
  return <AbsoluteFill className="hello-film hello-paper">
    <div className="hello-later-title" style={{opacity:1-intro,transform:`translateY(${-intro*65}px)`}}>读书会之后<span>。</span></div>
    <div className="hello-after-ticket" style={{opacity:p(t,.3,1),transform:`rotate(-8deg) translateY(${lerp(70,0,p(t,.3,1))}px)`}}><b>PAPER & PINE</b><span>BOOK<br/>CLUB</span><small>GOOD STORIES. GOOD COMPANY.</small></div>
    <div style={{opacity:intro}}><Camera t={t} keys={[{at:0,cx:600,cy:370,zoom:.95},{at:1.35,cx:600,cy:370,zoom:.95},{at:2.1,cx:565,cy:335,zoom:1.25},{at:4.5,cx:565,cy:335,zoom:1.25},{at:5.2,cx:600,cy:400,zoom:.94},{at:6,cx:600,cy:400,zoom:.94}]}><MessageHost t={49.2+t} later/></Camera></div>
    {t>1.4&&<Caption>{captionAt(50)}</Caption>}
  </AbsoluteFill>;
}

function Finish() {
  const t=useTime();
  return <AbsoluteFill className="hello-film hello-vermilion">
    <div className="hello-end-rule" style={{width:`${p(t,0,.8)*100}%`}}/>
    <div className="hello-end-copy" style={{clipPath:`inset(${100*(1-p(t,.2,1))}% 0 0 0)`}}>从这一次敢说，<br/>到下一次会说。</div>
    <div className="hello-end-lockup" style={{opacity:p(t,1,1.6),transform:`translateY(${lerp(35,0,p(t,1,1.6))}px)`}}><Img src={staticFile('lingrove-logo.svg')}/><span>Lingrove <small>拾语</small></span></div>
    <div className="hello-end-sub" style={{opacity:p(t,1.45,2)}}>Mac 上的自动补全与语言学习</div>
    {/* Recap: the six capabilities the story just showed, staggered so the eye reads them as
        a list after the headline lands. Names come from FEATURES so labels cannot drift. */}
    <ol className="hello-end-recap">{FEATURES.map((f,i)=>{const v=p(t,1.2+i*.12,1.6+i*.12);
      return <li key={f.index} style={{opacity:v,transform:`translateX(${lerp(24,0,v)}px)`}}><b>{f.index}</b>{f.name}</li>;})}</ol>
    <div className="hello-end-local" style={{opacity:p(t,2.2,2.7)}}>补全可完全在本机运行 · 不偷走焦点</div>
  </AbsoluteFill>;
}

/** One overlay owns the feature label for the whole film, so it never remounts at Sequence
 * boundaries and its enter/exit stays continuous even when a feature crosses a scene cut. */
function FeatureKicker({dark}:{dark:(t:number)=>boolean}) {
  const t=useTime(), f=featureAt(t);
  if(!f) return null;
  const v=p(t,f.start,f.start+.35)*(1-p(t,f.end-.3,f.end));
  return <div className={`hello-kicker ${dark(t)?'on-dark':''}`} style={{opacity:v,transform:`translateY(${lerp(-14,0,v)}px)`}}>
    <b>{f.index}</b><span>{f.name}</span><small>{f.hint}</small>
  </div>;
}

/** Existing approved assets and core promises are preserved; this composition owns a new
 * story, palette and camera system. Audio stems allow the same edit with or without music. */
export function FirstHello({bgm=true}:{bgm?:boolean}) {
  const {fps}=useVideoConfig();
  return <>
    <Sequence name="看到邀请" durationInFrames={6*fps}><Invitation/></Sequence>
    <Sequence name="同一封消息：补全、表达、翻译、发送、回复" from={6*fps} durationInFrames={24*fps}><Exchange/></Sequence>
    <Sequence name="留下刚用过的表达" from={30*fps} durationInFrames={6*fps}><SavePhrase/></Sequence>
    <Sequence name="表达落入语料库" from={36*fps} durationInFrames={6*fps}><FileExpression/></Sequence>
    <Sequence name="再次回想" from={42*fps} durationInFrames={7.2*fps}><Recall/></Sequence>
    <Sequence name="活动之后，主动使用" from={49.2*fps} durationInFrames={6*fps}><Later/></Sequence>
    <Sequence name="从敢说到会说" from={55.2*fps} durationInFrames={4.8*fps}><Finish/></Sequence>
    <FeatureKicker dark={t=>t>=30&&t<36}/>
    {bgm&&<Audio src={staticFile('audio/first-hello-music.m4a')}/>}
    <Audio src={staticFile('audio/first-hello-foley.m4a')}/>
  </>;
}
