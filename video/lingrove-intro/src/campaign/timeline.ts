import {Easing, interpolate} from 'remotion';
import type {ExpressionFrame} from '../components/ExpressionDemo';
import type {GhostFrame} from '../components/GhostDemo';

/** Editorial time is the sole owner of synthetic story state. One message is written, sent,
 * revisited and learned; changing the camera cannot reset its text or silently accept a result. */
export const STORY = {
  duration:60, fps:30, write:6, expression:12, translation:18,
  replace:23.1, send:25.2, reply:27, collect:30, save:34.8,
  notebook:36, enroll:41, review:42, reveal:45.4, rate:47.8,
  later:49.2, nextSend:54.7, end:55.2,
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

/** Feature kicker: captions tell the story, but a first-time viewer also needs to know which
 * Lingrove capability just happened. Windows match the beat where the capability is on screen;
 * `null` keeps story-only beats (invitation, reply, later, end) free of product labels. */
export type Feature={index:string;name:string;hint:string;start:number;end:number};
export const FEATURES:Feature[]=[
  {index:'01',name:'行内自动补全',hint:'按 Tab 逐词接受',start:6.8,end:12},
  {index:'02',name:'表达求助',hint:'输入 ?? 描述想说的话',start:12.6,end:18},
  {index:'03',name:'原地翻译',hint:'先写母语，确认后替换',start:18.6,end:24.4},
  {index:'04',name:'收藏表达',hint:'连同这次的语境一起保存',start:30.4,end:36},
  {index:'05',name:'个人语料库',hint:'随时找回，一键加入复习',start:36.4,end:42},
  {index:'06',name:'间隔复习',hint:'在语境中回想',start:42.4,end:49.2},
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
  if(t<34.8)return '这句刚用过的表达，想留下来。';
  if(t<36)return '连同这一次的语境。';
  if(t<42)return '下次想用时，还能找到它。';
  if(t<45.4)return '再给自己一次回想的机会。';
  if(t<49.2)return '记住的，还有当时想说的话。';
  return '读书会之后，这句话自己写了出来。';
}
