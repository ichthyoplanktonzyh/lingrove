import React from 'react';
import './bookshop.css';

const clamp = (value: number, min = 0, max = 1) => Math.max(min, Math.min(max, value));

/**
 * A fictional bookshop supplies the story around the writing demo. Its local clock comes from the
 * film, so the same scene can be rendered at any frame without timers or persistent state.
 */
function BookshopShell({children}: {children: React.ReactNode}) {
  return <div className="bookshop">
    <div className="bookshop-browser"><div className="bookshop-lights"><i/><i/><i/></div><div className="bookshop-address">paperandpinebooks.com / community</div><span>↗</span></div>
    <div className="bookshop-page">
      <header className="bookshop-header"><div className="bookshop-brand"><span className="bookshop-mark">✳</span><span>paper &amp; pine<small>INDEPENDENT BOOKSHOP</small></span></div><nav><span>Our story</span><span>Visit us</span><b>Community</b></nav><div className="bookshop-menu">☰</div></header>
      {children}
    </div>
  </div>;
}

/** Opening invitation: a small editorial illustration gives the fictional event a tangible place. */
export function OpeningDemo({t}: {t: number}) {
  const pointerOpacity = clamp((t - 2.6) / .35);
  const pointerX = 36 * (1 - clamp((t - 2.7) / 1.1));
  const pointerY = 20 * (1 - clamp((t - 2.7) / 1.1));
  return <BookshopShell><main className="bookshop-opening">
    <section className="bookshop-copy"><div className="bookshop-eyebrow"><span/> A LITTLE SPACE FOR BIG STORIES</div><h1>Community<br/><em>Book Club</em></h1><p>Come read, share, and connect.</p><div className="bookshop-detail"><span>✳</span><div>GOOD BOOKS. GOOD PEOPLE.<small>Everyone is welcome at the table.</small></div></div><div className="bookshop-cta">Send us a message <span>↗</span></div><div className="bookshop-pointer" style={{opacity:pointerOpacity, transform:`translate(${pointerX}px, ${pointerY}px)`}}>↖</div></section>
    <div className="bookshop-art"><div className="bookshop-art-label">A STORY IS BETTER<br/>WHEN SHARED <span>↗</span></div><div className="bookshop-sun"/><div className="bookshop-arch"/><div className="bookshop-shelf"><div className="bookshop-books"><i/><i/><i/><i/><i/><i/><i/></div><div className="bookshop-vase"><span/></div><div className="bookshop-plant"><i/><i/><i/><i/><i/></div></div><div className="bookshop-art-caption">A little more room<br/><em>for connection.</em></div><div className="bookshop-art-num">01 / 03</div></div>
    <div className="bookshop-bottom"><span>INDEPENDENT BOOKS · SHARED STORIES</span><span>SCROLL TO EXPLORE ↓</span></div>
  </main></BookshopShell>;
}

/** The reply closes the same fictional exchange; typing is derived from elapsed scene time. */
export function ReplyDemo({t, message = 'Thank you! See you there.'}: {t: number; message?: string}) {
  const count = Math.floor(clamp((t - 1.35) / 2.3) * message.length);
  const replyOpacity = clamp((t - .35) / .5);
  return <div className="bookshop-reply-host"><div className="bookshop-reply-window">
    <div className="bookshop-reply-title"><div className="bookshop-reply-lights"><i/><i/><i/></div><span>给书店发消息</span><b>···</b></div>
    <div className="bookshop-reply-recipient"><span>收件人：</span>Paper &amp; Pine Bookshop</div>
    <div className="bookshop-reply-thread"><div className="bookshop-reply-original">Hi! I saw your book club event and I’d love to join.</div><div className="bookshop-reply-from" style={{opacity:replyOpacity}}><div className="bookshop-reply-avatar">✳</div><div><strong>Paper &amp; Pine Bookshop</strong><small>刚刚</small><p>We’d love to have you!</p></div></div></div>
    <div className="bookshop-reply-writing">{message.slice(0,count)}<i className="bookshop-caret"/></div>
    <div className="bookshop-reply-tools"><span>A<small>⌄</small></span><b>↑</b></div>
  </div></div>;
}
