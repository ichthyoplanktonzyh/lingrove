import React from 'react';
import {Img, interpolate, staticFile} from 'remotion';
import ExpressionDemo from '../components/ExpressionDemo';
import TranslationDemo from '../components/TranslationDemo';
import DictionaryDemo from '../components/DictionaryDemo';
import ReviewDemo from '../components/ReviewDemo';
import {ReplyDemo} from '../components/BookshopDemo';
import {Brand, move, Pointer, Title, typed, UIStage, useSeconds, World} from './motion';

/** Each scene directs a single narrative beat. Existing UI components remain the source of
 * product visuals; camera placement and annotations are intentionally film-only concerns. */
export function FindWords() {
  const t=useSeconds();
  return <World tone="paper"><Brand/>
    <div className="expression-world-word" style={{transform:`translateY(${move(t,0,1,90,0)}px)`}}>意思</div>
    <Title lines={['不会说的，先用中文。']} at={.1} className="find-title"/>
    <UIStage x={move(t,0,.7,1280,110)} y={215} scale={1.18} className="find-stage">
      <ExpressionDemo t={t} state={{
        leadText:typed('I’m a little nervous, but I’d like to ',t,.7,.7),
        queryText:typed('想鼓起勇气尝试一下',t,2.0,1.1),
        triggerText:t<1.65?'':t<1.85?'?':'??',
        phase:t>=5.6?'accepted':t>=3.6?'candidate':t>=3.3?'loading':t>=1.85?'query':'writing',
      }}/>
    </UIStage>
    <div className="film-bottom-note">{t<3.6?'想鼓起勇气尝试一下。':t<5.6?'give it a try':'原来，可以这样说。'}</div>
  </World>;
}

export function TranslateThought() {
  const t=useSeconds();
  const uiTime=interpolate(t,[0,.8,2.1,3.3,4.2,4.8],[3.15,4.3,5.95,7.5,8.6,9.2],{extrapolateLeft:'clamp',extrapolateRight:'clamp'});
  return <World tone="blue"><Brand light/>
    <Title lines={['先写下。','再说出来。']} at={.1} className="translate-title"/>
    <div className="translate-context" style={{opacity:move(t,.3,1)}}>我很期待和大家<br/>分享我的想法。</div>
    <UIStage x={move(t,0,.8,650,420)} y={160} scale={1.13} rotate={move(t,0,.8,5,0)} className="translate-stage"><TranslationDemo t={uiTime}/></UIStage>
    {t>2.5 && t<4.25 && <Pointer x={move(t,2.5,3.6,1090,997)} y={move(t,2.5,3.6,480,388)} pressed={uiTime>=8.1&&uiTime<8.5}/>}
    <div className="translate-footnote">{t<4.2?'看过译文，再决定使用。':'这一次，完整地表达。'}</div>
  </World>;
}

export function KeepExpression() {
  const t=useSeconds(), saved=t>=(6.52-2.1)/.7;
  return <World tone="paper"><Brand/>
    <div className="launch-overline">一句话写完了。新的积累才开始。</div>
    <Title lines={['这次用过的，','别让它溜走。']} at={.15} className="keep-title"/>
    <div className="keep-expression" style={{opacity:move(t,.5,1.2)}}>look forward to<div style={{width:`${move(t,.6,1.4,0,100)}%`}}/></div>
    <div className="keep-context" style={{opacity:move(t,1.1,1.6)}}>连同这一次的语境。</div>
    <UIStage x={move(t,0,.8,920,745)} y={155} scale={1.25} rotate={move(t,0,.8,8,0)} className="dictionary-stage"><DictionaryDemo t={2.1+t*.7} isolated/></UIStage>
    <div className="saved-note" style={{opacity:move(t,6.32,6.6),transform:`translateY(${move(t,6.32,6.6,15,0)}px)`}}><Img src={staticFile(saved?'fish-filled.svg':'fish-outline.svg')}/>已收藏</div>
  </World>;
}

/** One shell grows from the dictionary card into the notebook. The incoming UI waits until
 * the shell is wide enough; this is the card→workspace recipe, with an actual reused workspace. */
export function IntoNotebook() {
  const t=useSeconds(), grow=move(t,.15,1.25), incoming=move(t,.7,1.3);
  return <World tone="paper"><Brand/>
    <div className="notebook-heading" style={{opacity:move(t,1.2,1.7)}}>留下的，有表达，也有来处。</div>
    <div className="growing-workspace" style={{left:745+(80-745)*grow,top:155+(145-155)*grow,width:425+(1120-425)*grow,height:503+(535-503)*grow,borderRadius:16}}>
      <div style={{position:'absolute',left:0,top:0,width:900,height:520,transform:'scale(1.25)',transformOrigin:'0 0',opacity:1-incoming}}><DictionaryDemo t={7.3} isolated/></div>
      <UIStage x={0} y={-22} scale={1.244} opacity={incoming} className="notebook-stage"><ReviewDemo t={Math.max(0,t-1.2)}/></UIStage>
    </div>
  </World>;
}

export function Remember() {
  const t=useSeconds();
  const uiTime=interpolate(t,[0,.8,1.6,2.9,3.4,5.2,5.7,7.2],[5.4,6.8,7.3,9.4,10,12.8,13.6,15.1],{extrapolateLeft:'clamp',extrapolateRight:'clamp'});
  return <World tone="ink"><Brand light/>
    <Title lines={['留住。再想起。']} at={.1} className="review-title"/>
    <div className="review-editorial-note">{t<1.6?'把想记住的表达，加入复习。':t<3.4?'给自己一点回想的时间。':t<5.7?'带着那句话，再认识一次。':'每一次回想，都更熟悉一点。'}</div>
    <div className="review-shot"><UIStage x={move(t,1.5,2.1,80,-35)} y={move(t,1.5,2.1,0,-75)} scale={move(t,1.5,2.1,.98,1.2)} className="practice-stage"><ReviewDemo t={uiTime}/></UIStage></div>
  </World>;
}

/** This payoff is explicitly human typing after a time jump. There is no ghost suggestion or
 * collection-to-inference animation that could imply automatic recall from saved vocabulary. */
export function NextTime() {
  const t=useSeconds();
  return <World tone="paper"><Brand/>
    <div className="time-jump" style={{opacity:1-move(t,.75,1.15),transform:`translateY(${move(t,.75,1.15,0,-40)}px)`}}>几天后。</div>
    <div style={{opacity:move(t,.85,1.3)}}><Title lines={['这一次，自己写出来。']} at={.85} className="next-title"/></div>
    <UIStage x={130} y={move(t,.55,1.2,780,205)} scale={1.14} className="next-stage"><ReplyDemo t={Math.max(0,t-.15)} message="Thank you! I’m looking forward to meeting everyone."/></UIStage>
  </World>;
}

export function EndCard() {
  const t=useSeconds();
  return <World tone="aqua">
    <div className="end-type"><Title lines={['写得顺手。','学得自然。']} at={.15}/></div>
    <div className="end-logo" style={{transform:`translateY(${move(t,0,.9,100,0)}px) rotate(${move(t,0,.9,-15,0)}deg)`,opacity:move(t,0,.7)}}><Img src={staticFile('lingrove-logo.svg')}/></div>
    <div className="end-name" style={{opacity:move(t,.7,1.2),transform:`translateY(${move(t,.7,1.2,25,0)}px)`}}>Lingrove <span>拾语</span></div>
    <div className="end-position" style={{opacity:move(t,1.0,1.6)}}>Mac 上的自动补全与语言学习</div>
  </World>;
}
