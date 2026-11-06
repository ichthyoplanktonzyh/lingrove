import {Easing, interpolate} from 'remotion';
import type {ExpressionFrame} from '../components/ExpressionDemo';
import type {GhostFrame} from '../components/GhostDemo';

/** Editorial time is the sole owner of synthetic story state. One message is written, sent,
 * followed by hover-reading the bookshop's journal, collecting an expression, reviewing it,
 * and writing again after the event; changing the camera cannot reset text or silently accept. */
export const STORY = {
  duration:67.2, fps:30, write:6, expression:12, translation:18,
  replace:23.1, send:25.2, reply:27, reading:30, collect:37.2, save:42.0,
  notebook:43.2, enroll:48.2, review:49.2, reveal:52.6, rate:55.0,
  later:56.4, nextSend:61.9, end:62.4,
} as const;
export const FIRST='Hi! I saw your book club event and I’d love to join.';
export const SECOND='I’m a little nervous, but I’d like to give it a try.';
export const THIRD='I’m looking forward to sharing my thoughts with everyone.';
export const SOURCE='我很期待和大家分享我的想法。';
export const NEXT='I’m looking forward to our next meeting.';
export const ease=Easing.bezier(.55,0,.18,1);
export const p=(t:number,a:number,b:number)=>interpolate(t,[a,b],[0,1],{extrapolateLeft:'clamp',extrapolateRight:'clamp',easing:ease});
export const lerp=(a:number,b:number,t:number)=>a+(b-a)*t;
export const type=(text:string,t:number,a:number,b:number)=>Array.from(text).slice(0,Math.floor(Array.from(text).length*Math.max(0,Math.min(1,(t-a)/(b-a))))).join('');

export function ghostAt(t:number):GhostFrame {
  const chunks=['I’d',' love',' to',' join.'];
  const count=[8.4,9.1,9.8,10.5].filter(at=>t>=at).length;
  return {typed:'Hi! I saw your book club event'+type(' and ',t,6.6,7.2),accepted:chunks.slice(0,count).join(''),remaining:t>=7.7?chunks.slice(count).join(''):''};
}
export function expressionAt(t:number):ExpressionFrame {
  return {leadText:type('I’m a little nervous, but I’d like to ',t,12,13.15),queryText:type('想鼓起勇气尝试一下',t,13.75,15.15),triggerText:t<13.35?'':t<13.55?'?':'??',phase:t>=17?'accepted':t>=15.7?'candidate':t>=15.3?'loading':t>=13.55?'query':'writing'};
}
export function translationAt(t:number) {
  return interpolate(t,[18,19,19.5,21.1,22.6,23.1,24],[.45,3.8,4.25,5.95,8.1,8.6,9.3],{extrapolateLeft:'clamp',extrapolateRight:'clamp'});
}

/** Feature kicker: captions tell the story, while the editorial header folio tells a first-time
 * viewer which Lingrove capability is on screen. All seven capabilities appear in story order. */
export type Feature={index:string;name:string;hint:string;start:number;end:number};
export const FEATURES:Feature[]=[
  {index:'01',name:'行内自动补全',hint:'按 Tab 逐词接受',start:6.8,end:12},
  {index:'02',name:'表达求助',hint:'输入 ?? 描述想说的话',start:12.6,end:18},
  {index:'03',name:'写作翻译',hint:'先写母语，确认后替换',start:18.6,end:24.4},
  {index:'04',name:'阅读翻译',hint:'鼠标指向目标，按快捷键即查',start:30.4,end:37.2},
  {index:'05',name:'收藏表达',hint:'连同这次的语境一起保存',start:37.6,end:43.2},
  {index:'06',name:'个人语料库',hint:'随时找回，一键加入复习',start:43.6,end:49.2},
  {index:'07',name:'间隔复习',hint:'在语境中回想',start:49.6,end:56.4},
];
export function featureAt(t:number){return FEATURES.find(f=>t>=f.start&&t<f.end)??null;}

export function captionAt(t:number) {
  if(t<6)return '看到一场很想参加的读书会。';
  if(t<12)return '先写下第一句。';
  if(t<15.7)return '“想鼓起勇气试试看”，该怎么说？';
  if(t<18)return 'give it a try';
  if(t<23.1)return '最后一句，先用熟悉的语言。';
  if(t<25.2)return '看过译文，确认使用。';
  if(t<27)return '好了，发出去。';
  if(t<30)return '“当然，欢迎你来！”';
  if(t<33.2)return '读读他们的活动手记，鼠标指向不熟的表达。';
  if(t<37.2)return '按下快捷键，直接弹出此处的释义。';
  if(t<42.0)return '刚学会的表达，想留下来。';
  if(t<43.2)return '连同这一次的语境。';
  if(t<49.2)return '下次想用时，还能找到它。';
  if(t<52.6)return '再给自己一次回想的机会。';
  if(t<56.4)return '记住的，还有当时想说的话。';
  return '读书会之后，这句话自己写了出来。';
}
