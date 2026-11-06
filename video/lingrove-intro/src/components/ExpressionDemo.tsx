import React from 'react';
import {staticFile} from 'remotion';
import './expression.css';

/** A frame value owned by the director, not interactive application state. Keeping the phase
 * explicit lets the film trim idle time without accidentally skipping a confirmation step. */
export type ExpressionFrame = {
  leadText: string;
  queryText: string;
  triggerText: string;
  phase: 'writing' | 'query' | 'loading' | 'candidate' | 'accepted';
};

/** The component owns UI fidelity; the caller optionally owns the narrative's text and timing. */
export default function ExpressionDemo({t, state}: {t: number; state?: ExpressionFrame}) {
  return <div className="expression-demo">
    <div className="expression-window">
      <div className="expression-titlebar">
        <div className="expression-lights"><i/><i/><i/></div>
        <span>给书店发消息</span><span className="expression-more">···</span>
      </div>
      <div className="expression-recipient"><span>收件人：</span> Paper &amp; Pine Bookshop</div>
      <div className="expression-editor">
        <p>Hi! I saw your book club event and I’d love to join.</p>
        <ExpressionLine t={t} state={state}/>
      </div>
      <div className="expression-send"><span>✦</span><span className="expression-send-button">↑</span></div>
    </div>
  </div>;
}

/** The quiet input and candidate panel remain one anchored unit while the film camera moves. */
export function ExpressionLine({t, state}: {t: number; state?: ExpressionFrame}) {
  const query = '想鼓起勇气尝试一下';
  const queryText = state?.queryText ?? Array.from(query).slice(0, Math.max(0, Math.floor((t - 2.2) * 7))).join('');
  const accepted = state ? state.phase === 'accepted' : t >= 9.5;
  const panel = state ? ['loading', 'candidate'].includes(state.phase) : t >= 6.4 && !accepted;
  const loading = state ? state.phase === 'loading' : t < 7.35;
  const inputVisible = state ? ['query', 'loading', 'candidate'].includes(state.phase) : t >= 1.35;
  const trigger = state?.triggerText ?? (t >= 1 ? (t < 1.35 ? '?' : '??') : '');
  const wrapped = queryText.length > 22;
  const cursorVisible = Math.floor(t * 2) % 2 === 0;

  return <div className="expression-paragraph">{state?.leadText ?? 'I’m a little nervous, but I’d like to '}
          {accepted ? <><span className="expression-inserted">give it a try</span><span className="expression-caret expression-host-caret" style={{opacity: cursorVisible ? 1 : 0}}/></> : <>
            {trigger && <span className="expression-trigger">{trigger}</span>}
            {inputVisible && <div className={wrapped ? "expression-input expression-input-wrapped" : "expression-input"}>
              <span className={queryText ? 'expression-query' : 'expression-placeholder'}>{queryText || '描述想表达的意思或概念…'}</span>
              <span className="expression-caret" style={{opacity: cursorVisible ? 1 : 0}}/>
              {panel && <div className="expression-panel">
                {loading ? <div className="expression-loading"><span className="expression-spinner" style={{transform: `rotate(${Math.floor(t * 8) * 45}deg)`}}>✳</span>正在查找表达…</div> : <div className="expression-selected">
                  <span className="expression-arrow">↵</span>
                  <div className="expression-answer">give it a try</div>
                  <div className="expression-hint">尝试一下；勇敢迈出第一步</div>
                  <div className="expression-actions">
                    <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 8h3l3-3v10l-3-3H3zM12 7c1.7 1.5 1.7 4.5 0 6M14 5c3 2.6 3 7.4 0 10"/></svg>
                    <img src={staticFile('fish-outline.svg')} />
                  </div>
                </div>}
                <div className="expression-panel-footer"><span>{loading ? <><b>↵</b> 查找　 <b>esc</b> 取消</> : <><b>↵</b> 插入　 <b>⇥</b> 插入　 <b>esc</b> 取消</>}</span></div>
              </div>}
            </div>}
            {!inputVisible && <span className="expression-caret" style={{opacity: cursorVisible ? 1 : 0}}/>}
          </>}
        </div>;
}
