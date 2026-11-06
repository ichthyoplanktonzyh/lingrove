import React from 'react';
import {staticFile} from 'remotion';
import './review.css';

/** Small SF-symbol-like outlines keep the filmed controls recognizable at video scale. */
const Glyph = ({name, size = 14}: {name: string; size?: number}) => {
  const paths: Record<string, React.ReactNode> = {
    cards: <><rect x="6" y="6" width="11" height="11" rx="2"/><path d="M14 6V3H3v11h3"/></>,
    library: <><rect x="3" y="5" width="3" height="12" rx=".5"/><rect x="8" y="3" width="3" height="14" rx=".5"/><path d="m13 5 3-1 3 12-3 1z"/></>,
    list: <><path d="M7 5h10M7 10h10M7 15h10"/><path d="M3 5h.1M3 10h.1M3 15h.1"/></>,
    sound: <><path d="M3 8h3l4-3v10l-4-3H3zM13 7c1.5 2 1.5 4 0 6M16 5c3 3 3 7 0 10"/></>,
    plus: <path d="M10 4v12M4 10h12"/>,
    gear: <><path d="m8 2 4 0 .5 2 2 .9 2-.6 2 3.4-1.5 1.5v2.3l1.5 1.4-2 3.5-2-.6-2 .9-.5 2H8l-.5-2-2-.9-2 .6-2-3.5L3 11.5V9.2L1.5 7.7l2-3.4 2 .6 2-.9z"/><circle cx="10" cy="10" r="3"/></>,
    chart: <><path d="M3 17h14M5 14V8M9 14V4M13 14V7M17 14V2"/></>,
    search: <><circle cx="8" cy="8" r="5.5"/><path d="m12 12 5 5"/></>,
    edit: <><path d="m4 13 9-9 3 3-9 9H4zM12 5l3 3"/></>,
    play: <path d="m6 4 10 6-10 6z" fill="currentColor" stroke="none"/>,
    check: <path d="m4 10 4 4 8-8"/>,
    sidebar: <><rect x="2" y="3" width="16" height="14" rx="2"/><path d="M7 3v14M4.5 6v.1M4.5 9v.1"/></>,
    graph: <><circle cx="4" cy="5" r="2"/><circle cx="16" cy="5" r="2"/><circle cx="10" cy="16" r="2"/><path d="m5 7 4 7M15 7l-4 7M6 5h8"/></>,
    sliders: <><path d="M3 5h14M3 10h14M3 15h14"/><circle cx="7" cy="5" r="1.5" fill="white"/><circle cx="13" cy="10" r="1.5" fill="white"/><circle cx="8" cy="15" r="1.5" fill="white"/></>,
    globe: <><circle cx="10" cy="10" r="7"/><ellipse cx="10" cy="10" rx="3" ry="7"/><path d="M3 10h14M4 6h12M4 14h12"/></>,
    tag: <><path d="m3 3 7 .1 7 7-7 7-7-7z"/><circle cx="6.5" cy="6.5" r="1"/></>,
    deck: <><rect x="4" y="6" width="12" height="11" rx="1.5"/><path d="M5 3h10M7 1h6M4 9h12"/></>,
    undo: <><path d="M7 3 3 7l4 4M3 7h9a5 5 0 0 1 0 10H9"/></>,
    history: <><path d="M3 7V3M3 7h4"/><path d="M3 7a7 7 0 1 1-1 6M10 6v5l3 2"/></>,
    refresh: <><path d="M15 5h3V2M18 5a8 8 0 1 0 0 10"/></>,
    external: <><rect x="3" y="4" width="13" height="13" rx="2"/><path d="M9 3h8v8M17 3l-8 8"/></>,
    quote: <><path d="M3 5h5v5H3zM12 5h5v5h-5zM8 10c0 4-3 5-5 5M17 10c0 4-3 5-5 5"/></>,
    dictionary: <><path d="M4 3h12v14H4zM7 6h6M7 9h5M7 13h6M2 4v12"/></>,
    copy: <><rect x="7" y="6" width="9" height="11" rx="1"/><path d="M12 6V3H3v11h4"/></>,
    folder: <path d="M2 6V4h6l2 2h8v10H2zM2 8h16"/>,
    clock: <><circle cx="10" cy="10" r="7"/><path d="M10 5v5l3 2"/></>,
    bolt: <path d="m11 1-7 10h5l-1 8 8-11h-5z" fill="currentColor" stroke="none"/>,
    eye: <><path d="M1 10s3-6 9-6 9 6 9 6-3 6-9 6-9-6-9-6z"/><circle cx="10" cy="10" r="2.5"/></>,
  };
  return <svg width={size} height={size} viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>;
};

const IconButton = ({name, children}: {name: string; children?: React.ReactNode}) => <button className="review-icon-button"><Glyph name={name}/>{children}</button>;
const Whale = ({tail = false}: {tail?: boolean}) => <img alt="" className={tail ? 'review-tail' : 'review-logo'} src={staticFile(tail ? 'fish-filled.svg' : 'lingrove-logo.svg')}/>;

/** The sidebar is shared by corpus and review, just as it is in the native workspace. */
function Sidebar({review}: {review: boolean}) {
  return <aside className="review-nav">
    <div className="review-brand"><Whale/><div><b>拾语</b><small>{review ? '复习' : '个人语料库'}</small></div></div>
    <div className={`review-nav-item ${!review ? 'selected' : ''}`}><Glyph name="library"/><span>个人语料库</span></div>
    <div className={`review-nav-item ${review ? 'selected' : ''}`}><Glyph name="cards"/><span>复习</span></div>
    <div className="review-nav-item"><Glyph name="chart"/><span>进度</span></div>
    <div className="review-nav-footer"><div className="review-account"><div className="review-avatar"><Whale/></div><div><b>在这台 Mac 上</b><small>仅本地</small></div><span>›</span></div><div className="review-settings"><Glyph name="gear"/>设置</div></div>
  </aside>;
}

/** All notebook text is synthetic; only the app's hierarchy and controls follow the references. */
function Notebook({enrolled}: {enrolled: boolean}) {
  const entries = ['look forward to', 'keep in touch', 'make time for', 'a fresh start', 'take a moment', 'on the same page', 'little by little', 'give it a try'];
  return <><div className="review-list">
    <div className="review-list-tools"><div className="review-list-tabs"><b>词条</b><span>语义</span></div><span><Glyph name="globe"/>⌄</span><span><Glyph name="tag"/>⌄</span><small>8</small><Glyph name="list" size={11}/></div>
    <div className="review-entry-list">{entries.map((entry, index) => <div key={entry} className={`review-entry ${index === 0 ? 'selected' : ''}`}><strong>{entry}</strong><small>English</small></div>)}</div>
  </div><main className="review-detail">
    <div className="review-detail-heading"><h2>look forward to <Glyph name="sound" size={12}/></h2><div className="review-detail-actions"><Glyph name="copy" size={11}/><Glyph name="folder" size={13}/><button><Glyph name="edit" size={10}/>编辑</button><span>···</span><Whale tail/></div></div>
    <div className="review-badges"><span>English</span><span>短语</span></div>
    <div className="review-add-explanation"><Glyph name="plus" size={10}/>添加解释</div>
    <section className="review-context-panel"><div className="review-context-label"><Glyph name="quote" size={11}/><span>上下文</span><small>移动用例⌄</small></div><p>I’m <mark>looking forward to</mark> sharing my thoughts with everyone.</p><div className="review-context-translation">我很期待和大家分享我的想法。<Glyph name="sound" size={11}/></div><div className="review-local-meaning"><small><Glyph name="tag" size={9}/>此处含义</small><b>期待；盼望</b><span>✧</span></div><div className="review-source"><i/>Google Chrome</div></section>
    <div className="review-section-title">复习</div>
    <div className={`review-enrollment ${enrolled ? 'enrolled' : ''}`}><Glyph name="deck"/><div><b>拾语</b><small>{enrolled ? '已加入复习' : '未加入复习'}</small></div><button>{enrolled ? <><Glyph name="check" size={10}/>复习内容</> : '加入复习'}</button></div>
    <div className="review-anki"><Glyph name="deck" size={12}/><b>Anki</b><button><Glyph name="plus" size={10}/>添加到 Anki</button></div>
    <div className="review-dictionary"><Glyph name="dictionary" size={12}/><b>词典释义</b><span>›</span></div>
    <div className="review-created"><Glyph name="clock" size={9}/>今天</div>
  </main></>;
}

function ReviewToolbar({practice, rated}: {practice: boolean; rated: boolean}) {
  return <div className="review-main-header">{practice ? <span>练习</span> : <div className="review-segment"><b>待复习</b><span>复习内容</span></div>}<div className="review-header-actions">{practice && !rated && <button className="review-end">结束复习</button>}<IconButton name="undo"/><IconButton name="deck">⌄</IconButton><IconButton name="list"/><IconButton name="history"/><IconButton name="refresh"/><i/><div className="review-target"><b>拾语</b><span>Anki</span></div></div></div>;
}

function Overview() {
  return <div className="review-overview"><section className="review-hero"><div className="review-hero-top"><div className="review-hero-icon"><Glyph name="cards" size={24}/></div><div><strong>现在可复习 <i>1</i></strong><small>现在可复习　1</small></div><div className="review-brand-pill"><Whale/>拾语</div></div><div className="review-hero-divider"/><div className="review-hero-buttons"><button className="review-start"><Glyph name="play" size={11}/>开始复习</button><button className="review-secondary"><Glyph name="plus" size={11}/>从语料库添加</button></div></section>
    <div className="review-metrics"><div><span className="review-metric-icon"><Glyph name="bolt" size={17}/></span><p><strong>1</strong><small>现在可复习</small></p></div><div><span className="review-metric-icon"><Glyph name="deck" size={17}/></span><p><strong>1</strong><small>练习卡</small></p></div><div><span className="review-metric-icon purple"><Glyph name="edit" size={17}/></span><p><strong className="review-template-name">表达与语境</strong><small>卡片模板</small></p><Glyph name="sliders" size={11}/></div></div>
    <div className="review-queue-title"><Glyph name="list" size={12}/>复习队列<span>1</span></div><div className="review-queue-card"><b>look forward to</b><span>当前</span><p>look forward to<br/>期待；盼望</p><small><Glyph name="clock" size={9}/>新卡<Glyph name="tag" size={9}/>英语 · 写作</small></div>
  </div>;
}

function Practice({revealed, rated}: {revealed: boolean; rated: boolean}) {
  return <><div className="review-practice-header"><div><b><Glyph name="deck" size={12}/>今日 Lingrove 复习</b><span><i className="review-status-dot"/>本次练习已回答: {rated ? 1 : 0}<Glyph name="clock" size={10}/>现在可复习: {rated ? 0 : 1}</span></div><div className="review-progress"><i style={{width: rated ? '100%' : '4px'}}/></div></div>
    {rated ? <div className="review-finished"><div className="review-finished-panel"><div className="review-finished-icon"><Glyph name="check" size={25}/></div><strong>本轮复习完成</strong><small>每一次回想，都让表达更熟悉。</small><div className="review-finished-stats"><span>本次已回答<b>1</b></span><span>现在可复习<b>0</b></span></div><div className="review-finished-actions"><button>返回待复习</button><button>查看进度</button></div></div></div> : <><div className="review-card-area"><div className="review-card-meta"><span className="review-template"><Glyph name="cards" size={10}/>语境理解卡</span><span className="review-side">{revealed ? '背面' : '正面'}</span><div/><IconButton name="sound"/><IconButton name="external">打开来源</IconButton><IconButton name="sliders">卡片模板</IconButton></div>
    <div className={`review-web-card ${revealed ? 'revealed' : ''}`}><div className="review-expression">look forward to</div>{revealed && <><div className="review-answer-divider"/><div className="review-answer">期待；盼望</div><div className="review-context">I’m looking forward to sharing my thoughts with everyone.<small>我很期待和大家分享我的想法。</small></div></>}</div></div>
    <div className="review-controls">{!revealed ? <button className="review-reveal"><Glyph name="eye" size={14}/>显示答案</button> : <div className="review-ratings">{[['再来一次', '1', 'red', '1 分钟后', 'undo'], ['困难', '2', 'orange', '6 分钟后', 'clock'], ['良好', '3', 'green', '10 分钟后', 'check'], ['简单', '4', 'blue', '1 周后', 'bolt']].map(([label,key,color,interval,icon]) => <button key={key} className={`review-rating ${color}`}><span className="review-interval">{interval}</span><span className="review-rating-number">{key}</span><b><Glyph name={icon} size={10}/>{label}</b></button>)}</div>}<div className="review-hint">按 Space 或 Return 显示答案 · 显示后按 1–4 评分 · 按 ⌘Z 撤销评分</div></div></>}
  </>;
}

/** The scene owns only film state: the parent supplies time, with no access to the user's app. */
export default function ReviewDemo({t}: {t: number}) {
  const enrolled = t >= 3.2;
  const overview = t >= 5.4 && t < 7.3;
  const practice = t >= 7.3;
  const revealed = t >= 10;
  const rated = t >= 13.5;
  const stops = [{at:0,x:700,y:334},{at:2.5,x:808,y:371},{at:3.2,x:808,y:371},{at:4.6,x:87,y:169},{at:5.4,x:87,y:169},{at:6.8,x:249,y:229},{at:7.3,x:249,y:229},{at:9.4,x:510,y:447},{at:10,x:510,y:447},{at:12.8,x:618,y:447},{at:13.5,x:618,y:447}];
  let from = stops[0], to = stops[0];
  for (let i=0;i<stops.length-1;i++) if(t>=stops[i].at){from=stops[i];to=stops[i+1];}
  const fraction=Math.max(0,Math.min(1,(t-from.at)/Math.max(.001,to.at-from.at)));
  const smooth=fraction*fraction*(3-2*fraction);
  const click=[3.2,5.4,7.3,10,13.5].find(at=>t>=at && t<at+.3);
  return <div className="review-demo"><div className="review-window"><div className="review-titlebar"><div className="review-lights"><i/><i/><i/></div><b className="review-window-title">{overview || practice ? '复习' : '个人语料库'}</b><div className="review-sidebar-toggle"><Glyph name="sidebar" size={15}/></div>{!overview && !practice && <div className="review-corpus-toolbar"><div className="review-view-toggle"><b><Glyph name="list" size={15}/></b><Glyph name="graph" size={15}/></div><div><Glyph name="plus" size={15}/><Glyph name="sliders" size={15}/></div><div className="review-size">大小⌄</div><div>···⌄</div><div><Glyph name="search" size={16}/></div></div>}</div>
    <div className="review-workspace"><Sidebar review={overview || practice}/>{!overview && !practice ? <Notebook enrolled={enrolled}/> : <main className="review-main"><ReviewToolbar practice={practice} rated={rated}/>{overview ? <Overview/> : <Practice revealed={revealed} rated={rated}/>}</main>}</div></div>
    {!rated && <div className="review-pointer" style={{left:`${(from.x+(to.x-from.x)*smooth)/9}%`,top:`${(from.y+(to.y-from.y)*smooth)/5.2}%`}}>{click!==undefined && <i className="review-click" style={{transform:`translate(-50%,-50%) scale(${.5+(t-click)*3})`,opacity:1-(t-click)/.3}}/>}<svg width="18" height="23" viewBox="0 0 20 25"><path d="M2 1v18l5-4 3.5 8 3-1.4-3.6-8H17z" fill="#263630" stroke="white" strokeWidth="1.5" strokeLinejoin="round"/></svg></div>}
  </div>;
}
