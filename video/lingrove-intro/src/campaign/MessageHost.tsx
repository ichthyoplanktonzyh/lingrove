import React from 'react';
import {GhostLine} from '../components/GhostDemo';
import {ExpressionLine} from '../components/ExpressionDemo';
import {TranslationPreview} from '../components/TranslationDemo';
import {Cursor} from './camera';
import {expressionAt,FIRST,ghostAt,lerp,NEXT,p,SECOND,SOURCE,STORY,THIRD,translationAt,type} from './timeline';

/** This host lives for the entire exchange. The existing inline components now supply only
 * their UI, while one deterministic story supplies text. The camera never remounts a new host
 * when a feature changes, avoiding the window/typography jumps in the earlier cut. */
export function MessageHost({t, later=false}:{t:number;later?:boolean}) {
  const sent=!later&&t>=STORY.send;
  const reply=!later&&t>=STORY.reply;
  const sendMotion=p(t,STORY.send,STORY.send+.65);
  const previewTime=translationAt(t);
  const replacing=t>=STORY.replace;
  const third=later?type(NEXT,t,50.2,53.7):replacing?THIRD:type(SOURCE,t,18,19);
  const candidateIn=p(t,15.3,15.7), candidateOut=p(t,16.8,17);
  const componentMotion={
    '--candidate-y':`${lerp(24,0,candidateIn)-candidateOut*9}px`,
    '--candidate-r':`${lerp(-14,0,candidateIn)}deg`,
    '--candidate-s':lerp(.94,1,candidateIn)-candidateOut*.03,
    '--candidate-opacity':candidateIn*(1-candidateOut),
    '--accept-wash':.16*(1-p(t,17.2,17.9)),
    '--ghost-reveal':`${100*(1-p(t,7.7,8))}%`,
  } as React.CSSProperties;
  return <div className={`hello-host ${sent?'has-sent':''}`}>
    <div className="hello-host-bar"><div className="hello-traffic"><i/><i/><i/></div><span>给书店发消息</span><span>···</span></div>
    <div className="hello-recipient"><span>收件人：</span>Paper &amp; Pine Bookshop</div>
    {!sent&&<div className="hello-body" style={componentMotion}>
      {later?<><p>Thanks for a lovely evening.</p><p className="hello-last-line">{third}<i className="hello-caret"/></p></>:<>
        <div className={t>=12?'hello-context-line':''}>{t<12?<GhostLine t={t-6} state={ghostAt(t)}/>:FIRST}</div>
        {t>=12&&<div className={`hello-line-two ${t>=18?'hello-context-line':''}`}>{t<18?<ExpressionLine t={t-12} state={expressionAt(t)}/>:SECOND}</div>}
        {t>=18&&<div className="hello-line-three">{third}<i className="hello-caret"/></div>}
        {t>=19&&t<24&&<div className="hello-translation-layer" style={{transform:`perspective(1000px) translateY(${lerp(28,0,p(t,19,19.55))}px) rotateX(${lerp(-12,0,p(t,19,19.55))}deg)`}}><TranslationPreview t={previewTime}/></div>}
      </>}
    </div>}
    {sent&&<>
      <div className="hello-sent-bubble" style={{transform:`translateY(${lerp(45,0,sendMotion)}px) scale(${lerp(1.07,1,sendMotion)})`,opacity:p(t,25.2,25.45)}}>
        <small>你 · 已发送 ✓</small><p>{FIRST}</p><p>{SECOND}</p><p>I’m <span className={t>=30?'hello-saved-phrase':''}>looking forward to</span> sharing my thoughts with everyone.</p>
      </div>
      {reply&&<div className="hello-reply" style={{transform:`translateY(${lerp(38,0,p(t,27,27.6))}px) scale(${lerp(.9,1,p(t,27,27.6))})`,opacity:p(t,27,27.35)}}><span>✳</span><div><small>Paper &amp; Pine Bookshop</small><p>We’d love to have you!</p></div></div>}
    </>}
    {!sent&&<div className="hello-toolbar"><span>A<span>⌄</span></span><button className={t>=25&&t<25.2?'pressed':''}>{later&&t>=54.7?'✓':'↑'}</button></div>}
    {!later&&t>=22&&t<23.25&&<Cursor x={lerp(975,818,p(t,22,22.55))} y={lerp(450,397,p(t,22,22.55))} press={t>=22.6&&t<22.85}/>}
    {!later&&t>=24.4&&t<25.3&&<Cursor x={lerp(890,1045,p(t,24.4,25))} y={lerp(440,563,p(t,24.4,25))} press={t>=25}/>}
    {later&&t>=54&&t<54.9&&<Cursor x={lerp(900,1045,p(t,54,54.6))} y={lerp(430,563,p(t,54,54.6))} press={t>=54.6}/>}
  </div>;
}
