import React from 'react';
import {AbsoluteFill, Composition, interpolate, staticFile, useCurrentFrame} from 'remotion';
import {OpeningDemo, ReplyDemo} from './components/BookshopDemo';
import DictionaryDemo from './components/DictionaryDemo';
import ReadingDemo from './components/ReadingDemo';
import ReviewDemo from './components/ReviewDemo';
import './director.css';

const fps = 24;
const shots = [
  {start:0, length:5, title:'故事的开始', line:<>有些想法，<br/><em>想与人分享。</em></>, View:OpeningDemo},
  {start:5, length:9, title:'收集表达', line:<>在真实语境里，<br/><em>留下值得记住的话。</em></>, View:DictionaryDemo},
  {start:14, length:9, title:'阅读理解', line:<>阅读时遇见，<br/><em>就在此刻理解。</em></>, View:ReadingDemo},
  {start:23, length:15, title:'语料与复习', line:<>遇见过的语言，<br/><em>慢慢成为自己的语言。</em></>, View:ReviewDemo},
  {start:38, length:5, title:'故事继续', line:<>让每一次表达，<br/><em>都有新的可能。</em></>, View:ReplyDemo},
];
const clamp = {extrapolateLeft:'clamp' as const, extrapolateRight:'clamp' as const};
function Reel(){
 const time=useCurrentFrame()/fps;
 const index=Math.min(shots.length-1,Math.max(0,shots.findIndex(s=>time<s.start+s.length)));
 const shot=shots[index], t=time-shot.start, View=shot.View;
 const opacity=Math.min(interpolate(t,[0,.4],[0,1],clamp),interpolate(t,[shot.length-.4,shot.length],[1,0],clamp));
 return <AbsoluteFill className="film"><div className="film-orb film-orb-a"/><div className="film-orb film-orb-b"/><div className="film-grain"/>
 <header className="film-header"><div className="film-brand"><img src={staticFile('lingrove-logo.svg')}/><span>Lingrove</span><small>拾语</small></div><div className="film-header-note">LANGUAGE, IN THE FLOW OF LIFE</div></header>
 <div className="film-scene" style={{opacity}}><aside className="film-copy"><div className="film-chapter"><span>0{index+1}</span><i/>{shot.title}</div><h1>{shot.line}</h1><div className="film-copy-rule"/><p>让每一次表达，<br/>都更靠近你想说的。</p></aside><div className="film-stage"><div className="film-window"><View t={t}/></div></div></div>
 <footer className="film-footer"><span>LINGROVE　/　拾语</span><div className="film-progress"><div style={{width:`${time/43*100}%`}}/></div><span>场景组件预览</span></footer></AbsoluteFill>
}
export const ReferenceRoot=()=> <Composition id="SceneStudy" component={Reel} width={1280} height={720} fps={fps} durationInFrames={43*fps}/>;
