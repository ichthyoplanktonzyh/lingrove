import React from 'react';
import {AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';

/** The director's shared motion vocabulary. It owns no playback state: local scene frames flow
 * into these helpers and produce poses, so seeks and parallel rendering stay deterministic. */
export const ease = Easing.bezier(.22, 1, .36, 1);
export const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: ease} as const;
export const move = (t: number, start: number, end: number, from = 0, to = 1) =>
  interpolate(t, [start, end], [from, to], clamp);
export const typed = (text: string, t: number, start: number, duration: number) =>
  Array.from(text).slice(0, Math.floor(Math.max(0, Math.min(1, (t - start) / duration)) * Array.from(text).length)).join('');
export function useSeconds() { return useCurrentFrame() / useVideoConfig().fps; }

/** Masked line reveals carry editorial copy, separate from the simulated product's controls. */
export function Title({lines, at = 0, className = ''}: {lines: string[]; at?: number; className?: string}) {
  const t = useSeconds();
  return <div className={`launch-title ${className}`}>{lines.map((line, i) =>
    <div className="launch-title-mask" key={line}><div style={{transform: `translateY(${move(t, at + i * .13, at + .65 + i * .13, 110, 0)}%)`}}>{line}</div></div>)}</div>;
}

export function Brand({light = false}: {light?: boolean}) {
  return <div className={`launch-brand ${light ? 'light' : ''}`}><Img src={staticFile('lingrove-logo.svg')}/><span>Lingrove <small>拾语</small></span></div>;
}

/** The large line motifs give each editorial world depth without changing any product UI. */
export function World({tone, children}: {tone: 'ink' | 'aqua' | 'paper' | 'blue'; children: React.ReactNode}) {
  const t = useSeconds();
  return <AbsoluteFill className={`launch-film launch-${tone}`}>
    <svg className="launch-orbits" viewBox="0 0 1280 720" aria-hidden="true" style={{transform:`translateX(${move(t,0,2,30,0)}px)`}}>
      <ellipse cx="1150" cy="250" rx="440" ry="430"/><ellipse cx="1150" cy="250" rx="375" ry="365"/><ellipse cx="1150" cy="250" rx="310" ry="300"/>
    </svg>{children}
  </AbsoluteFill>;
}

/** A cinematic camera poses an existing 900×520 interface, then holds still for reading. */
export function UIStage({children, x, y, scale = 1, rotate = 0, className = '', opacity = 1}: {
  children: React.ReactNode; x: number; y: number; scale?: number; rotate?: number; className?: string; opacity?: number;
}) {
  return <div className={`launch-ui ${className}`} style={{left:x,top:y,opacity,transform:`scale(${scale}) rotate(${rotate}deg)`}}>{children}</div>;
}

/** A visible confirmation cue for shots whose editorial camera relocates the native panel. */
export function Pointer({x,y,pressed=false,opacity=1}:{x:number;y:number;pressed?:boolean;opacity?:number}) {
  return <div style={{position:'absolute',left:x,top:y,opacity,zIndex:8,transform:`scale(${pressed?.83:1})`,filter:'drop-shadow(0 2px 3px #0003)'}}><svg width="25" height="32" viewBox="0 0 23 29"><path d="M2 1.5v20l5.1-4.8 3.9 9.2 3.4-1.5-3.9-9.1 7.1-.3L2 1.5Z" fill="#17191d" stroke="white" strokeWidth="1.7" strokeLinejoin="round"/></svg></div>;
}
