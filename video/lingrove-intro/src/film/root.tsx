import React from 'react';
import {Composition, interpolate, Sequence, useCurrentFrame, useVideoConfig} from 'remotion';
import {Audio} from '@remotion/media';
import {staticFile} from 'remotion';
import {Hesitation, InvitationOpening, Writing} from './openings';
import {EndCard, FindWords, IntoNotebook, KeepExpression, NextTime, Remember, TranslateThought} from './story-scenes';
import './film.css';
import {FirstHello} from '../campaign/FirstHello';

function OpeningScore() {
  const frame=useCurrentFrame(), {fps}=useVideoConfig();
  return <Audio src={staticFile('audio/lingrove-score.m4a')} durationInFrames={9.6*fps}
    volume={interpolate(frame,[9.3*fps,9.6*fps],[1,0],{extrapolateLeft:'clamp',extrapolateRight:'clamp'})}/>;
}

/** Explicit scene nodes keep the editorial beats separately visible in Remotion Studio. */
function OpeningA() { const {fps}=useVideoConfig(); return <>
  <Sequence name="想说，却卡住" durationInFrames={4.8*fps}><Hesitation/></Sequence>
  <Sequence name="补全接住想法" from={4.8*fps} durationInFrames={4.8*fps}><Writing/></Sequence>
  <OpeningScore/>
</>; }
function OpeningB() { const {fps}=useVideoConfig(); return <>
  <Sequence name="书店邀请" durationInFrames={4.8*fps}><InvitationOpening/></Sequence>
  <Sequence name="写下第一句话" from={4.8*fps} durationInFrames={4.8*fps}><Writing/></Sequence>
  <OpeningScore/>
</>; }
/** A single synthetic exchange carries both core promises: assistance now and learning for
 * the next encounter. Musical bars and independent JSX scene nodes make the edit reviewable. */
function ProductFilm() { const {fps}=useVideoConfig(); return <>
  <Sequence name="想说，却卡住" durationInFrames={4.8*fps}><Hesitation/></Sequence>
  <Sequence name="接住想法" from={4.8*fps} durationInFrames={4.8*fps}><Writing/></Sequence>
  <Sequence name="找到表达" from={9.6*fps} durationInFrames={7.2*fps}><FindWords/></Sequence>
  <Sequence name="完整说出来" from={16.8*fps} durationInFrames={4.8*fps}><TranslateThought/></Sequence>
  <Sequence name="留下一句表达" from={21.6*fps} durationInFrames={7.2*fps}><KeepExpression/></Sequence>
  <Sequence name="带着语境进入语料库" from={28.8*fps} durationInFrames={4.8*fps}><IntoNotebook/></Sequence>
  <Sequence name="再次想起" from={33.6*fps} durationInFrames={7.2*fps}><Remember/></Sequence>
  <Sequence name="几天后自己写出来" from={40.8*fps} durationInFrames={4.8*fps}><NextTime/></Sequence>
  <Sequence name="品牌落点" from={45.6*fps} durationInFrames={4.8*fps}><EndCard/></Sequence>
  <Audio src={staticFile('audio/lingrove-score.m4a')}/>
</>; }
export const FilmRoot=()=> <>
  <Composition id="Lingrove-FirstHello" component={FirstHello} width={1280} height={720} fps={30} durationInFrames={2016} defaultProps={{bgm:true}}/>
  <Composition id="Lingrove-FirstHello-English" component={FirstHello} width={1280} height={720} fps={30} durationInFrames={2016} defaultProps={{bgm:true,locale:'en'}}/>
  <Composition id="Lingrove-NextTime" component={ProductFilm} width={1280} height={720} fps={30} durationInFrames={1512}/>
  <Composition id="OpeningA-Thought" component={OpeningA} width={1280} height={720} fps={30} durationInFrames={288}/>
  <Composition id="OpeningB-Invitation" component={OpeningB} width={1280} height={720} fps={30} durationInFrames={288}/>
</>;
