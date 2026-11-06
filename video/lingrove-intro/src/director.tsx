import React from 'react';
import {AbsoluteFill, Composition, interpolate, staticFile, useCurrentFrame} from 'remotion';
import GhostDemo from './components/GhostDemo';
import ExpressionDemo from './components/ExpressionDemo';
import TranslationDemo from './components/TranslationDemo';
import './director.css';

const FPS = 24;
// The three independently animated interfaces share one continuous writing story. Their local
// clocks begin at each cut so changing the scene timings does not change the UI animation.
const scenes = [
  {start: 0, duration: 10, number: '01', label: 'AUTOCOMPLETE', line: <>让想法，<br/><em>自然继续。</em></>, component: GhostDemo},
  {start: 10, duration: 11, number: '02', label: 'EXPRESSION ASSIST', line: <>想说的意思，<br/><em>总有一种表达。</em></>, component: ExpressionDemo},
  {start: 21, duration: 11, number: '03', label: 'WRITING TRANSLATION', line: <>先写下想法。<br/><em>再决定如何表达。</em></>, component: TranslationDemo},
];
const clamp = {extrapolateLeft:'clamp' as const, extrapolateRight:'clamp' as const};
function Film() {
  const frame = useCurrentFrame();
  const time = frame / FPS;
  const sceneIndex = Math.min(scenes.length-1, Math.max(0, scenes.findIndex(s => time < s.start+s.duration)));
  const scene = scenes[sceneIndex];
  const t = time-scene.start;
  const sceneOpacity = Math.min(interpolate(t,[0,.48],[0,1],clamp),interpolate(t,[scene.duration-.45,scene.duration],[1,0],clamp));
  const Current = scene.component;
  return <AbsoluteFill className="film">
    <div className="film-orb film-orb-a"/><div className="film-orb film-orb-b"/>
    <div className="film-grain"/>
    <header className="film-header"><div className="film-brand"><img src={staticFile('lingrove-logo.svg')}/><span>Lingrove</span><small>拾语</small></div><div className="film-header-note">LANGUAGE, IN THE FLOW OF LIFE</div></header>
    <div className="film-scene" style={{opacity:sceneOpacity}}>
      <aside className="film-copy"><div className="film-chapter"><span>{scene.number}</span><i/>{scene.label}</div><h1>{scene.line}</h1><div className="film-copy-rule"/><p>让每一次表达，<br/>都更靠近你想说的。</p></aside>
      <div className="film-stage"><div className="film-window"><Current t={t}/></div></div>
    </div>
    <footer className="film-footer"><span>LINGROVE　/　拾语</span><div className="film-progress"><div style={{width:`${time/32*100}%`}}/></div><span>一段写作的旅程</span></footer>
  </AbsoluteFill>;
}
export const DirectorRoot = () => <Composition id="WritingSequence" component={Film} width={1280} height={720} fps={FPS} durationInFrames={32*FPS}/>;
