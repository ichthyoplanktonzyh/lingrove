import React from 'react';
import {staticFile} from 'remotion';
import './expression.css';

/** A self-contained, synthetic writing scene. Its caller owns the clock in seconds. */
export default function ExpressionDemo({t}: {t: number}) {
  const query = '想鼓起勇气尝试一下';
  const queryText = Array.from(query).slice(0, Math.max(0, Math.floor((t - 2.2) * 7))).join('');
  const accepted = t >= 9.5;
  const panel = t >= 6.4 && !accepted;
  const loading = t < 7.35;
  const wrapped = queryText.length > 22;
  const cursorVisible = Math.floor(t * 2) % 2 === 0;

  return <div className="expression-demo">
    <div className="expression-window">
      <div className="expression-titlebar">
        <div className="expression-lights"><i/><i/><i/></div>
        <span>给书店发消息</span><span className="expression-more">···</span>
      </div>
      <div className="expression-recipient"><span>收件人：</span> Paper &amp; Pine Bookshop</div>
      <div className="expression-editor">
        <p>Hi! I saw your book club event and I’d love to join.</p>
        <div className="expression-paragraph">I’m a little nervous, but I’d like to{' '}
          {accepted ? <><span className="expression-inserted">give it a try</span><span className="expression-caret expression-host-caret" style={{opacity: cursorVisible ? 1 : 0}}/></> : <>
            {t >= 1 && <span className="expression-trigger">{t < 1.35 ? '?' : '??'}</span>}
            {t >= 1.35 && <div className={wrapped ? "expression-input expression-input-wrapped" : "expression-input"}>
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
            {t < 1.35 && <span className="expression-caret" style={{opacity: cursorVisible ? 1 : 0}}/>}
          </>}
        </div>
      </div>
      <div className="expression-send"><span>✦</span><span className="expression-send-button">↑</span></div>
    </div>
  </div>;
}
