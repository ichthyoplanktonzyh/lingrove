import type {ExpressionFrame} from './components/ExpressionDemo';
import type {GhostFrame} from './components/GhostDemo';

/** Editorial timing is separate from UI rendering. Every state is calculated from absolute film
 * time, so scrubbing backwards and parallel frame rendering produce exactly the same result. */
export const OPENING = {
  fps: 24,
  duration: 15,
  suggestion: 1.05,
  acceptChunks: [2.05, 2.65, 3.25, 3.85],
  expression: 4.8,
  trigger: 7.2,
  query: 7.55,
  lookup: 9.8,
  result: 10.25,
  insert: 12.7,
} as const;

const typeText = (text: string, t: number, start: number, duration: number) =>
  Array.from(text).slice(0, Math.floor(Math.max(0, Math.min(1, (t - start) / duration)) * Array.from(text).length)).join('');

export function ghostFrame(t: number): GhostFrame {
  const chunks = ['I’d', ' love', ' to', ' join.'];
  const count = OPENING.acceptChunks.filter(at => t >= at).length;
  return {
    typed: 'Hi! I saw your book club event' + typeText(' and ', t, 0, .65),
    accepted: chunks.slice(0, count).join(''),
    remaining: t >= OPENING.suggestion ? chunks.slice(count).join('') : '',
  };
}

export function expressionFrame(t: number): ExpressionFrame {
  return {
    leadText: typeText('I’m a little nervous, but I’d like to ', t, OPENING.expression, 1.65),
    queryText: typeText('想鼓起勇气尝试一下', t, 7.9, 1.3),
    triggerText: t < OPENING.trigger ? '' : t < OPENING.query ? '?' : '??',
    phase: t >= OPENING.insert ? 'accepted' : t >= OPENING.result ? 'candidate'
      : t >= OPENING.lookup ? 'loading' : t >= OPENING.query ? 'query' : 'writing',
  };
}

/** These are film annotations outside the recreated app, never invented product controls. */
export function openingCaption(t: number) {
  if (t < OPENING.expression) return {title: '让想法，接着写。', detail: '自动补全 · 按 Tab，逐词接纳建议'};
  if (t < OPENING.result) return {title: '想不起表达？先说出意思。', detail: '输入 ??，用自己的语言描述'};
  if (t < OPENING.insert) return {title: '原来，可以这样说。', detail: 'give it a try · 尝试一下'};
  return {title: '继续说你想说的。', detail: '确认插入，回到你的句子'};
}
