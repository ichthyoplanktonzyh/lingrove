import React from 'react';
import {GhostLine} from '../components/GhostDemo';
import {ExpressionLine} from '../components/ExpressionDemo';
import {TranslationPreview} from '../components/TranslationDemo';
import {OpeningDemo} from '../components/BookshopDemo';
import {Cursor} from './camera';
import {expressionAt,FIRST,ghostAt,lerp,NEXT,p,SECOND,SOURCE,STORY,THIRD,translationAt,type} from './timeline';

/** This host lives for the entire exchange. By keeping the Paper & Pine webpage alive and softly
 * dimmed behind the compact stationery modal, the viewer never drops into an empty white void. */
export function MessageHost({t, later=false, backdrop=true}:{t:number;later?:boolean;backdrop?:boolean}) {
  const sent=!later&&t>=STORY.send;
  const reply=!later&&t>=STORY.reply;
  const sendMotion=p(t,STORY.send,STORY.send+.65);
  const previewTime=translationAt(t);
  const replacing=t>=STORY.replace;
  const third=later?type(NEXT,t,50.2,53.7):replacing?THIRD:type(SOURCE,t,18,19);
  const candidateIn=p(t,15.3,15.7), candidateOut=p(t,16.8,17);
  const tabPulse=[8.4,9.1,9.8,10.5].some(at=>t>=at-.04&&t<at+.18);
  const componentMotion={
    '--candidate-y':`${lerp(20,0,candidateIn)-candidateOut*8}px`,
    '--candidate-r':`${lerp(-10,0,candidateIn)}deg`,
    '--candidate-s':lerp(.95,1,candidateIn)-candidateOut*.03,
    '--candidate-opacity':candidateIn*(1-candidateOut),
    '--accept-wash':.18*(1-p(t,17.2,17.9)),
    '--ghost-reveal':`${100*(1-p(t,7.7,8))}%`,
    '--tab-scale':tabPulse?.88:1,
    '--tab-bg':tabPulse?'#c4492e':'#f2ece0',
    '--tab-fg':tabPulse?'#fffaf1':'#6e6559',
  } as React.CSSProperties;
  return <div className="hello-stage-world">
    {backdrop&&<div className="hello-bookshop-backdrop"><OpeningDemo t={4}/></div>}
    <div className={`hello-host ${sent?'has-sent':''} ${later?'is-later':''}`}>
      <div className="hello-host-bar">
        <div className="hello-traffic"><i/><i/><i/></div>
        <div className="hello-host-title"><span>✳</span><b>Paper &amp; Pine Bookshop</b><small>COMMUNITY BOOK CLUB · MESSAGE</small></div>
        <span className="hello-host-more">···</span>
      </div>
      <div className="hello-recipient">
        <div className="hello-recipient-to"><span>TO</span><b>Paper &amp; Pine Bookshop</b><i>community@paperandpine.books</i></div>
        <div className="hello-recipient-badge">{later?'FOLLOW-UP NOTE':'FRIDAY · 7:30 PM RSVP'}</div>
      </div>
      {!sent&&<div className="hello-body" style={componentMotion}>
        {later?<>
          <div className="hello-prior-note"><span>YOUR EARLIER NOTE · FRIDAY</span><p>{FIRST} {SECOND}</p></div>
          <p className="hello-first-after">Thanks for a lovely evening.</p>
          <p className="hello-last-line">{third}<i className="hello-caret"/></p>
        </>:<>
          <div className={t>=12?'hello-context-line':''}>{t<12?<GhostLine t={t-6} state={ghostAt(t)}/>:FIRST}</div>
          {t>=12&&<div className={`hello-line-two ${t>=18?'hello-context-line':''}`}>{t<18?<ExpressionLine t={t-12} state={expressionAt(t)}/>:SECOND}</div>}
          {t>=18&&<div className="hello-line-three">{third}<i className="hello-caret"/></div>}
          {t>=19&&t<24&&<div className="hello-translation-layer" style={{transform:`perspective(1000px) translateY(${lerp(22,0,p(t,19,19.55))}px) rotateX(${lerp(-10,0,p(t,19,19.55))}deg)`}}><TranslationPreview t={previewTime}/></div>}
        </>}
      </div>}
      {sent&&<div className="hello-thread">
        <div className="hello-sent-bubble" style={{transform:`translateY(${lerp(28,0,sendMotion)}px) scale(${lerp(1.03,1,sendMotion)})`,opacity:p(t,25.2,25.45)}}>
          <small>YOU · SENT JUST NOW ✓</small>
          <p>{FIRST}</p>
          <p>{SECOND}</p>
          <p>I’m <span className={t>=29.4?'hello-saved-phrase':''}>looking forward to</span> sharing my thoughts with everyone.</p>
        </div>
        {reply&&<div className="hello-reply" style={{transform:`translateY(${lerp(26,0,p(t,27,27.6))}px) scale(${lerp(.95,1,p(t,27,27.6))})`,opacity:p(t,27,27.35)}}>
          <span>✳</span>
          <div><small>Paper &amp; Pine Bookshop · Host</small><p>We’d love to have you! Saving you a seat by the window.</p></div>
        </div>}
      </div>}
      {!sent&&<div className="hello-toolbar">
        <button className={t>=25&&t<25.2||(later&&t>=54.5&&t<54.7)?'pressed':''}><span>{later&&t>=54.7?'Sent':'Send note'}</span><b>{later&&t>=54.7?'✓':'↗'}</b></button>
      </div>}
    </div>
    {/* Aim the cursor tip at the replacement control in host-world coordinates so the
        camera scales the pointer and translation card together without shifting the hit. */}
    {!later&&t>=22&&t<23.25&&<Cursor x={lerp(820,732,p(t,22,22.55))} y={lerp(415,391,p(t,22,22.55))} press={t>=22.6&&t<22.85}/>}
    {!later&&t>=24.4&&t<25.3&&<Cursor x={lerp(760,910,p(t,24.4,25))} y={lerp(370,458,p(t,24.4,25))} press={t>=25}/>}
    {later&&t>=54&&t<54.9&&<Cursor x={lerp(780,910,p(t,54,54.6))} y={lerp(380,458,p(t,54,54.6))} press={t>=54.6}/>}
  </div>;
}
