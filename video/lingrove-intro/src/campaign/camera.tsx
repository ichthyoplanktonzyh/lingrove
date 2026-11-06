import React from 'react';
import {Img, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {lerp, p} from './timeline';

export type CameraKey={at:number;cx:number;cy:number;zoom:number};
/** Adapted camera grammar from video-shotcraft's cursor-flyover (Apache-2.0): coordinates
 * describe the point being viewed, not a div offset. Repeated destinations form reading holds. */
export function cameraAt(t:number, keys:CameraKey[]) {
  let pose=keys[0];
  for(let i=1;i<keys.length;i++) {
    const a=keys[i-1], b=keys[i], u=p(t,a.at,b.at);
    if(t<a.at)break;
    pose={at:t,cx:lerp(a.cx,b.cx,u),cy:lerp(a.cy,b.cy,u),zoom:lerp(a.zoom,b.zoom,u)};
    if(t<=b.at)break;
  }
  return pose;
}
export function Camera({t,keys,children}:{t:number;keys:CameraKey[];children:React.ReactNode}) {
  const cam=cameraAt(t,keys);
  return <div className="hello-camera"><div style={{position:'absolute',width:1200,height:800,transformOrigin:'0 0',transform:`translate(${640-cam.cx*cam.zoom}px,${360-cam.cy*cam.zoom}px) scale(${cam.zoom})`}}>{children}</div></div>;
}
export function useTime() {const {fps}=useVideoConfig();return useCurrentFrame()/fps;}
export function Mark({light=false}:{light?:boolean}) {
  return <div className={`hello-brand ${light?'on-dark':''}`}><Img src={staticFile('lingrove-logo.svg')}/><span>Lingrove <small>拾语</small></span></div>;
}
export function Caption({children,light=false}:{children:React.ReactNode;light?:boolean}) {
  return <div className={`hello-caption ${light?'on-dark':''}`}><span>{children}</span></div>;
}
export function Cursor({x,y,press=false,opacity=1}:{x:number;y:number;press?:boolean;opacity?:number}) {
  return <svg className="hello-cursor" style={{left:x,top:y,opacity,transform:`scale(${press?.84:1})`}} width="25" height="32" viewBox="0 0 23 29"><path d="M2 1.5v20l5.1-4.8 3.9 9.2 3.4-1.5-3.9-9.1 7.1-.3L2 1.5Z" fill="#252522" stroke="white" strokeWidth="1.7" strokeLinejoin="round"/></svg>;
}
