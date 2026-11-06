import {Easing, interpolate} from 'remotion';
import {DemoLocale, filmCopy} from '../demo-copy';
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
const FEATURE_TIMINGS = [[6.8,12],[12.6,18],[18.6,24.4],[30.4,37.2],[37.6,43.2],[43.6,49.2],[49.6,56.4]];
export function featuresFor(locale:DemoLocale):Feature[] {
  return FEATURE_TIMINGS.map(([start,end],i)=>({index:String(i+1).padStart(2,'0'),name:filmCopy(locale).features[i][0],hint:filmCopy(locale).features[i][1],start,end}));
}
export const FEATURES=featuresFor('zh-CN');
export function featureAt(t:number,locale:DemoLocale='zh-CN'){return featuresFor(locale).find(f=>t>=f.start&&t<f.end)??null;}

export function captionAt(t:number,locale:DemoLocale='zh-CN') {
  const ends=[6,12,15.7,18,23.1,25.2,27,30,33.2,37.2,42,43.2,49.2,52.6,56.4,Infinity];
  return filmCopy(locale).captions[ends.findIndex(end=>t<end)];
}
