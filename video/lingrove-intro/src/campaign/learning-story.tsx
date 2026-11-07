import React, {createContext, useContext} from 'react';

/** Fictional learner content is independent of the film's display locale. FirstHello owns
 * this immutable scenario for one render; shared demos outside that film keep their original
 * English-learning examples. No application settings, account or corpus enters this boundary. */
export const chineseStory = {
  target: 'Chinese', bookshop: '松间书店', address: 'songjian.example / community',
  recipient: 'hello@songjian.example',
  first: '你好，我看到你们的读书会活动，想报名参加。',
  prefix: '你好，我看到你们的读书会活动，',
  chunks: ['想', '报名', '参加。'],
  second: '我有点紧张，不过想试试看。', expressionLead: '我有点紧张，不过想',
  query: 'give it a try, even though I’m nervous', candidate: '试试看',
  candidateHint: 'give it a try',
  source: 'I’m looking forward to hearing everyone’s thoughts.',
  third: '很期待听听大家的想法。',
  term: '期待', gloss: 'look forward to', meaning: 'to look forward to something',
  beforeTerm: '很', afterTerm: '听听大家的想法。',
  next: '期待下次再见！', thanks: '谢谢，今晚聊得很开心。',
  reply: '欢迎你来！周五见。',
  entries: ['期待', '保持联系', '抽空', '新的开始', '慢慢来', '一起', '一点一点', '试试看'],
  reading: {
    title: ['带一本书，', '一起聊聊。'],
    intro: '每周五晚上，我们在书店见面。带一本喜欢的书，分享你的想法。',
    before: '', after: '和大家一起聊聊最近读的书。',
    sentence: '期待和大家一起聊聊最近读的书。',
    translation: 'We look forward to chatting with everyone about our recent reads.',
    outro: '正在学中文？也欢迎你来。',
  },
} as const;

const StoryContext = createContext(false);
export function ChineseLearningStory({children}: {children: React.ReactNode}) {
  return <StoryContext.Provider value={true}>{children}</StoryContext.Provider>;
}
/** A null scenario preserves earlier studies; the current campaign supplies Chinese content. */
export const useLearningStory = () => useContext(StoryContext) ? chineseStory : null;
