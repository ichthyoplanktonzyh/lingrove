import React from 'react';
import './translation.css';

const source = '我很期待和大家分享我的想法。';
const translation = "I’m looking forward to sharing my thoughts with everyone.";
const whale = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADYAAAA2CAYAAACMRWrdAAAACXBIWXMAAAsTAAALEwEAmpwYAAAETElEQVRo3u1ZaUhVQRR+z8zMFrX1h5Rtj0LJgqKibF9MbKXFooWiKKGoCGmBFtBoL4ssC1MiKFAyE2lBqaB+9CcqKtulIknN12KUlqWvM/FdOF3m6rv3vvd6yj3wgZ6ZOTPf3Jkz55xns1liiSWWWGJJy5GTBBdDHaGUkEUYIuk/lJCNPnWqsen+ROyJanEc9YS9hABCK8IB6LT6P/InYo+wqDmEcEJPQjwhjy04jXAMfzcQcglxhB4Yk4i2BybXYieEaejD9Rq7ikVtlrQtBxEXI7VY0m872gsNEgomHCZ8gZ0qQgqhPeEg4TP0TkIqobU7Rtdi0AdChKQ9gxE7KmkXX/gj2lcZ/EpXNI72Jw39eXd36xkjl0wYC8chsIgZTGT6cfjKTrQ9JgQZIDYV42sJswjtMOcv6H8QZuPrcf0Id4z3ZeSMoITQy+Ax3Asbp1X6XOizVfoL0G91d4K2hHWEYsJzuPOvMPKbUMN2sBQbUYSj3MaEw1iIeeJV+iOYb5dKn4j+08x4qUswvpEwBn+LixzoA299VIOYR+QyjC/DW1aF/2e0JGL8PpTg6HpTDmGunb4g1oVQDt1Fg17QXemDSCfCF8SETIBrFvr7hPHNMUCWERMyCW+e4u7fEvIJp3wMEepNNkKsEAtfIWnrjvjxu4n3z1M4pJdYDgZuaeL9E7u2BpGIL5HJso1heoilY9ARP7siwmnFEnawJyhZj4ENGFTg5YV2IkS5Gfod1AiOV+uZcBQGVatcewAC4VYeIGVHiNYgCats7JnJUiW5lYjyFV2U3k9ejYETmH49dPs9ROwliMVpxJJOltELhzYRmzuFkbTrnfgsBmcx3WRWH4nxALlQgkOlEwvfw77QXYmDUNaWYWTS0YxEH6bPh17sdmcP3zlB6hzL2lMlx743KyYNNDrRHRg4o7rwrxg5hweJpbHNnK/RRyF+3cxEI7FzDchyFYkmVGCCCtwHu0lSSSwHXKDRZzojPtDsLh6HMZHkDWB6B6t0KXch2uAckSy53aTRpz9zJvs8cTxCEPS6kD1HqqKPrazKZPRBv4bxRbhnssJRKfrcMpm5/yOijvgGht8TBkveG/FQdjNgezg7Xv0k7YMI79DnhRcc1t/86DEm+IayQaAb9ZQkyUZwKYDNYyp9axzLGpYq9fBmCFTM7tU9OBUZQfGYvka/m41sVj2ck4MREh7xIZunAGU4r4rwfkvZRRYoI+wmJBC6ovao7PRT1CtlspJtUALSkDJm14loJ8CXkXZ3PKCVksBUKW7mNHHR8zTyrHJsVNj/TCWC8e5k4nLzX2BCGhkXy0oN9SgUiUBgpo/KfLpFcctLNILreap7Kur3Hfy9VhLKFhyuchIprNIl8JNwgtCxORSBItibZIfTyFX9Aiqcwzbc0WYjQYj1XJJfTIXLn+uv98cduc3I1CJ3irG1ABHZ8A3UTUJtllhiiSWWWGJJo/IHdP7HqJxbWD8AAAAASUVORK5CYII=';
const fish = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9Ii0yMCAtMjAgNTUyIDU1MiI+PHBhdGggZmlsbD0ibm9uZSIgc3Ryb2tlPSJibGFjayIgc3Ryb2tlLXdpZHRoPSIyNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBkPSJNNDkzLjY5MSw0MzcuNTMxYy03LjQ4MiwzLjA1NC0xMi4xNTIsNy4xMzQtMTYuNDUxLDkuNTljLTQuMzYzLDIuNDgxLTguMjksNC4xOTQtMTYuNTQ4LDQuMjc0IGMtNS40NzgtMC4wMTYtOS4wNDktMC44NzItMTIuMDg4LTIuMDg0Yy00LjU0LTEuNzYyLTguMjc0LTQuOTEzLTE0LjE4OS04LjQ4NGMtNS44NjUtMy41MzktMTMuOTYyLTYuNjQxLTI0LjkzNC02LjU2MSBjLTcuMzIxLTAuMDE2LTEzLjM0OCwxLjI2OS0xOC4zMSwzLjI3MmMtNy40NjYsMy4wNDYtMTIuMTUzLDcuMTI3LTE2LjQzNSw5LjU5MWMtNC4zNDYsMi40NzItOC4yNDEsNC4xODYtMTYuNDY3LDQuMjY2IGMtNS4yNTItMC4wMTYtOC43NDItMC44MDgtMTEuNy0xLjkzOGMtNC4zOTYtMS42NTYtNy45NTEtNC41MjUtMTMuMzY1LTcuOTM1Yy01LjMxNy0zLjM1NC0xMi42MjEtNi42MjYtMjIuNDMtNy4xMzV2LTAuMDE2IGMtMC4wODEtMC4wMDgtMC4xMTMsMC0wLjE5NC0wLjAwOGgtMC4wMTZjLTAuNjYzLTAuMDQ5LTEuMTQ4LTAuMDQtMS43MTMtMC4wNDljLTUuMjg0LTQwLjI4NywwLjk1My05Mi40NTIsODYuMTQ5LTEzMS4xODggYzEzMi42MjYtNjAuMzk4LDk4LjEyNC0yMDkuMTY4LDk0LjMyNi0yMzkuNTMzYy0zLjMxMy0yNS44OTctMTYuMjI1LTIyLjY3Mi0yOS4xMzctOS43NjEgYy00Ni43MzUsNjIuOTYtMTYwLjQyMSwzNS40OTYtMjA0LjY4NCwxMjYuMjU5QzIxMS4yMjgsODkuMzI5LDk3LjYzOSwxMTYuNzkzLDUwLjgwOCw1My44MzMgYy0xMi45MTItMTIuOTEyLTI1LjgyNC0xNi4xMzYtMjkuMDQsOS43NjFjLTMuODE0LDMwLjM2NC0zNC40MjEsMTcxLjEwMyw5NC4yMywyMzkuNTMzIGM4NC4yNzQsNDQuNzE1LDkxLjY2LDkzLjUwMiw4Ni43NDcsMTMxLjE4OGMtMC41ODIsMC4wMTYtMS4xMTUsMC0xLjc5NCwwLjA0OWMwLDAtMC4wMTYsMC0wLjAzMiwwIGMtMC4wNDgsMC4wMDgtMC4wNjQsMC0wLjExMiwwLjAwOHYwLjAxNmMtNi40OCwwLjQxMi0xMS44NzgsMS45MzEtMTYuMjksMy45NjhjLTYuNzA2LDMuMTI3LTEwLjk4OSw2Ljg0My0xNS4wNzgsOS4xMDYgYy00LjEyLDIuMjc4LTguMDE1LDMuODYyLTE1Ljg2OSwzLjkzNGMtNS41MS0wLjAxNi05LjA5OC0wLjg3Mi0xMi4xNTMtMi4wODRjLTQuNTQxLTEuNzctOC4yNzQtNC45MTMtMTQuMTg4LTguNDY4IGMtNS44NS0zLjU0OC0xMy45My02LjY1OC0yNC44ODYtNi41NzhjLTcuMzA0LTAuMDE2LTEzLjMxNiwxLjI2OS0xOC4yNjIsMy4yNzJjLTcuNDQ5LDMuMDU1LTEyLjEyLDcuMTM1LTE2LjQwMiw5LjU5MSBjLTQuMzMsMi40NzItOC4yNDIsNC4xODYtMTYuNDY3LDQuMjY2Yy01LjQ3OC0wLjAxNi05LjA1LTAuODcyLTEyLjA4OC0yLjA4NGMtNC41NC0xLjc2Mi04LjI1Ny00LjkxMy0xNC4xODgtOC40NjggYy01Ljg2Ni0zLjU1Ni0xMy45NjItNi42NTgtMjQuOTM1LTYuNTc4djE2LjU0OGM1LjUxLDAuMDE2LDkuMDk4LDAuODczLDEyLjE1MywyLjA4NSBjNC41NDEsMS43NjIsOC4yNzQsNC45MTIsMTQuMTcyLDguNDc2YzUuODY2LDMuNTM5LDEzLjk0Niw2LjY1LDI0Ljg4Niw2LjU2OWM3LjMwNCwwLjAxNiwxMy4zMTYtMS4yNjgsMTguMjc3LTMuMjcyIGM3LjQ1LTMuMDU0LDEyLjEyLTcuMTM0LDE2LjQwMi05LjU5YzQuMzMtMi40OCw4LjIyNS00LjE4NiwxNi40NTEtNC4yNjdjNS40OTQsMC4wMTYsOS4wNjYsMC44NzMsMTIuMTA0LDIuMDc3IGM0LjUyNCwxLjc3LDguMjU3LDQuOTIsMTQuMTg4LDguNDg0YzUuODY2LDMuNTQ3LDEzLjk2Miw2LjY1LDI0LjkzNSw2LjU2OWM2Ljk2NSwwLjAwOCwxMi43NjYtMS4xNTUsMTcuNTgyLTMuMDEzIGM3LjI3Mi0yLjgyLDExLjk1OC02Ljc1NSwxNi4xMTEtOS4yNjhjNC4yMTgtMi41NTMsNy43NTctNC4yODIsMTQuNzIyLTQuNzg0bDAuMTEzLTAuMDA3bDAuMDQ5LTAuMDA4IGMwLjUxNy0wLjA0LDEuMzg5LTAuMDQ5LDIuNTU0LTAuMDQ5YzUuNDk0LDAuMDE2LDkuMDk4LDAuODczLDEyLjE1MiwyLjA4NWM0LjU0LDEuNzYyLDguMjc0LDQuOTEyLDE0LjE3Miw4LjQ3NiBjNS44NjYsMy41MzksMTMuOTQ2LDYuNjUsMjQuODg2LDYuNTY5YzcuMzA0LDAuMDE2LDEzLjMxNi0xLjI2OCwxOC4yNzctMy4yNzJjNy40NS0zLjA1NCwxMi4xMi03LjEzNCwxNi40MDItOS41ODMgYzQuMzQ3LTIuNDgsOC4yNzQtNC4xOTMsMTYuNTMyLTQuMjc0YzEuMDAyLDAsMS43NjIsMC4wMDgsMi4zMTEsMC4wNDlsMC4wOCwwLjAwOGwwLjE0NiwwLjAwNyBjNC43MTgsMC4yNzUsNy44NTQsMS4yMDUsMTAuNjgyLDIuNDczYzQuMjE4LDEuODQyLDcuOTY3LDUuMDI2LDEzLjc4NCw4LjQyN2M1Ljc3LDMuMzg2LDEzLjY0LDYuMjMsMjQuMTQ0LDYuMTY1IGM3LjMwNCwwLjAxNiwxMy4zMTYtMS4yNjgsMTguMjYtMy4yNzJjNy40NS0zLjA1NCwxMi4xMi03LjEzNCwxNi40MTktOS41ODNjNC4zNDctMi40OCw4LjI1OC00LjE5MywxNi41MzItNC4yNzQgYzUuNDk0LDAuMDE2LDkuMDk4LDAuODczLDEyLjE1MiwyLjA4NWM0LjU0MSwxLjc2Miw4LjI3NCw0LjkxMiwxNC4xNzIsOC40NzZjNS44NjYsMy41MzksMTMuOTQ2LDYuNjUsMjQuODg2LDYuNTY5IGM3LjMyMSwwLjAxNiwxMy4zNDgtMS4yNjgsMTguMzEtMy4yNzJjNy40NjYtMy4wNDYsMTIuMTUzLTcuMTI2LDE2LjQ1MS05LjU4M2M0LjM0Ny0yLjQ4LDguMjc0LTQuMTkzLDE2LjU0OC00LjI3NHYtMTYuNTQ4IEM1MDQuNjc5LDQzNC4yNSw0OTguNjUyLDQzNS41MzUsNDkzLjY5MSw0MzcuNTMxeiIvPjwvc3ZnPgo=';
const clamp = (value: number) => Math.max(0, Math.min(1, value));

/**
 * A deterministic reconstruction of the compact writing-translation preview.
 * The caller owns time in seconds, so rendering any frame does not depend on timers or prior frames.
 */
export default function TranslationDemo({t}: {t: number}) {
  const typed = Math.floor(clamp((t - 0.45) / 2.65) * source.length);
  const preview = clamp((t - 3.8) / 0.14) * (1 - clamp((t - 8.65) / 0.25));
  const translated = Math.floor(clamp((t - 4.25) / 1.65) * translation.length);
  const isComplete = translated >= translation.length;
  const replaced = t >= 8.5;
  const pointer = clamp((t - 6.6) / 1.25);
  const clicked = t >= 8.1 && t < 8.5;

  return <div className="translation-demo">
    <div className="translation-window">
      <div className="translation-window-bar">
        <div className="translation-traffic"><i/><i/><i/></div>
        <span>给书店发消息</span>
        <div className="translation-window-spacer"/>
      </div>
      <div className="translation-editor">
        <div className="translation-address"><span>收件人：</span><b>Paper &amp; Pine Bookshop</b></div>
        <div className="translation-body">
          <div className="translation-greeting">Hi! I saw your book club event and I’d love to join.<br/><br/>I’m a little nervous, but I’d like to give it a try.</div>
          <div className="translation-writing">{replaced ? translation : source.slice(0, typed)}<span className="translation-caret" style={{opacity: Math.floor(t * 2) % 2 === 0 ? 1 : 0}} /></div>
          
        </div>
      </div>
      <div className="translation-card" style={{opacity: preview}}>
        <div className="translation-card-header">
          <div className="translation-language"><span className={`translation-whale ${!isComplete ? 'active' : ''}`} style={{maskImage: `url(${whale})`, WebkitMaskImage: `url(${whale})`}}/>{!isComplete && <span className="translation-generating"/>} English</div>
          <div className="translation-card-actions">
            <span className="translation-action" aria-label="AI explanation"><svg viewBox="0 0 20 20"><path d="M10 2.5c.4 3.2 1.3 4.2 4.4 4.6-3.1.4-4 1.4-4.4 4.6-.4-3.2-1.3-4.2-4.4-4.6C8.7 6.7 9.6 5.7 10 2.5ZM4.5 11.5c.2 1.7.7 2.2 2.3 2.4-1.6.2-2.1.8-2.3 2.5-.2-1.7-.7-2.3-2.3-2.5 1.6-.2 2.1-.7 2.3-2.4Zm10.2.4c.2 1.3.5 1.7 1.8 1.8-1.3.2-1.6.6-1.8 1.9-.2-1.3-.6-1.7-1.9-1.9 1.3-.1 1.7-.5 1.9-1.8Z" fill="currentColor"/></svg></span>
            {isComplete && <span className="translation-action translation-favorite" aria-label="Save to vocabulary"><span style={{maskImage: `url(${fish})`, WebkitMaskImage: `url(${fish})`}}/></span>}
            {isComplete && <span className="translation-action" aria-label="Play translation aloud"><svg viewBox="0 0 20 20"><path d="M3.5 8h2.6l3.2-2.8v9.6L6.1 12H3.5zM12 7.1c1.6 1.6 1.6 4.2 0 5.8m2.2-8c2.8 2.8 2.8 7.4 0 10.2"/></svg></span>}
            <span className="translation-divider" />
            <span className={`translation-action translation-replace ${isComplete ? 'enabled' : ''} ${clicked ? 'pressed' : ''}`} aria-label="Replace"><svg viewBox="0 0 20 20"><path d="M3 7h12m-3-3 3 3-3 3M17 13H5m3-3-3 3 3 3"/></svg></span>
            <span className="translation-action" aria-label="Expand"><svg viewBox="0 0 20 20"><path d="m6 8 4 4 4-4"/></svg></span>
            <span className="translation-action" aria-label="Dismiss"><svg viewBox="0 0 20 20"><path d="m6.5 6.5 7 7m0-7-7 7"/></svg></span>
          </div>
        </div>
        <div className="translation-result">{translated ? translation.slice(0, translated) : 'Generating expression…'}</div>
      </div>
      {t >= 6.6 && t < 8.65 && <div className="translation-pointer" style={{left: `${78 - pointer * 8}%`, top: `${56 - pointer * 14}%`, transform: `scale(${clicked ? 0.85 : 1})`}}>
        <svg width="23" height="29" viewBox="0 0 23 29" fill="none"><path d="M2 1.5v20l5.1-4.8 3.9 9.2 3.4-1.5-3.9-9.1 7.1-.3L2 1.5Z" fill="#17191d" stroke="white" strokeWidth="1.7" strokeLinejoin="round"/></svg>
      </div>}
    </div>
  </div>;
}
