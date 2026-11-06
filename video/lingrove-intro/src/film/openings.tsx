import React from 'react';
import {Easing, Img, interpolate, staticFile} from 'remotion';
import GhostDemo from '../components/GhostDemo';
import {OpeningDemo} from '../components/BookshopDemo';
import {Brand, move, Title, typed, UIStage, useSeconds, World} from './motion';

/** Opening A turns a stalled caret into the next scene's surface. The enlarging rectangle is
 * editorial motion, not a claim that the native app animates the entire desktop. */
export function Hesitation() {
  const t=useSeconds();
  const open=interpolate(t,[4.2,4.8],[0,1],{extrapolateLeft:'clamp',extrapolateRight:'clamp',easing:Easing.inOut(Easing.cubic)});
  return <World tone="ink"><Brand light/>
    <div className="launch-overline" style={{opacity:move(t,.15,.6)}}>一次想参加的读书会。</div>
    <Title lines={['明明有话想说。','却停在了这里。']} at={.15}/>
    <div className="stalled-line" style={{opacity:move(t,.7,1.1)}}><span>I’d like to</span><span className="stalled-dots">…</span><i style={{opacity:Math.floor(t*2)%2 ? .25 : 1}}/></div>
    <div className="invitation-stamp" style={{opacity:move(t,1.2,1.8),transform:`translateY(${move(t,1.2,1.8,28,0)}px) rotate(-7deg)`}}><span>PAPER & PINE</span><b>Book club</b><small>Come as you are.</small><span className="stamp-star">✳</span></div>
    <div className="caret-portal" style={{left:376*(1-open),top:446*(1-open),width:5+1275*open,height:69+651*open,borderRadius:3*(1-open),opacity:t>=4.2 ? 1 : 0}}/>
  </World>;
}

/** Opening B uses the existing bookshop illustration as an invitation, not another UI tour. */
export function InvitationOpening() {
  const t=useSeconds();
  return <World tone="paper"><Brand/>
    <div className="launch-overline">从一次想参加的读书会开始。</div>
    <Title lines={['一封消息。','一个新开始。']} at={.1}/>
    <UIStage x={move(t,0,1,790,665)} y={move(t,0,1,270,130)} scale={.67} rotate={move(t,0,1,13,-5)}><OpeningDemo t={Math.min(4,t)}/></UIStage>
    <div className="invite-note" style={{opacity:move(t,1.8,2.5),transform:`translateY(${move(t,1.8,2.5,80,0)}px) rotate(4deg)`}}><small>想说的是</small><span>“我也想试试。”</span><Img src={staticFile('fish-outline.svg')}/></div>
    <div className="invite-wipe" style={{transform:`translateY(${move(t,3.8,4.8,101,0)}%)`}}/>
  </World>;
}

/** Word-by-word acceptance remains the real product behavior; four key pulses identify the
 * four chunks. The shot settles before the first suggestion so text never moves while read. */
export function Writing() {
  const t=useSeconds(), chunks=['I’d',' love',' to',' join.'], times=[1.6,2.2,2.8,3.4];
  const count=times.filter(at=>t>=at).length;
  return <World tone="aqua"><Brand/>
    <Title lines={['接着，把话写下去。']} at={.15}/>
    <div className="launch-giant-word" style={{transform:`translateX(${move(t,0,1.2,100,0)}px)`}}>Write.</div>
    <UIStage x={move(t,0,.7,175,90)} y={move(t,0,.7,360,243)} scale={move(t,0,.7,.91,1.22)} rotate={move(t,0,.7,-4,0)} className="writing-stage">
      <GhostDemo t={t} state={{typed:'Hi! I saw your book club event'+typed(' and ',t,.1,.4),accepted:chunks.slice(0,count).join(''),remaining:t>=.75?chunks.slice(count).join(''):''}}/>
    </UIStage>
    <div className="launch-key-cue"><kbd style={{transform:times.some(at=>t>=at&&t<at+.18)?'translateY(3px)':'none',background:times.some(at=>t>=at&&t<at+.18)?'#174467':'#fff',color:times.some(at=>t>=at&&t<at+.18)?'#fff':'#174467'}}>Tab</kbd><span>{t<3.5?'一点一点，接住你的想法。':'想法没有停，笔也不用停。'}</span></div>
  </World>;
}
