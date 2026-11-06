import React, {createContext, useContext} from 'react';

/** Display language belongs to the film, not to the learner's source/target language.
 * FirstHello owns this provider for one render; shared demos default to the approved Chinese
 * cut outside it. Chinese queries, translations and saved answers remain fictional learner
 * content. Only interface/editorial copy is localized here, with no app or corpus access. */
export type DemoLocale = 'zh-CN' | 'en';
const DemoLocaleContext = createContext<DemoLocale>('zh-CN');
export function DemoLocaleProvider({locale, children}: {locale: DemoLocale; children: React.ReactNode}) {
  return <DemoLocaleContext.Provider value={locale}>{children}</DemoLocaleContext.Provider>;
}
export const useDemoLocale = () => useContext(DemoLocaleContext);

/** Source strings identify the existing filmed controls so the Chinese cut keeps its exact
 * wording. A typed lookup makes missing English UI copy a compile error at each call site. */
const englishUI = {
  '给书店发消息': 'Message the bookshop', '收件人：': 'To:',
  '描述想表达的意思或概念…': 'Describe the idea you want to express…',
  '正在查找表达…': 'Finding an expression…',
  '尝试一下；勇敢迈出第一步': 'Make an attempt; take the first step',
  '查找': 'Find', '取消': 'Cancel', '插入': 'Insert',
  'English → 中文': 'English → Chinese', '语境释义': 'In context', '词典': 'Dictionary',
  '详解': 'Details', '正在解释…': 'Explaining…',
  '内置表达词库': 'Built-in expressions', '英语 → 英语': 'English → English',
  '词典词形：': 'Dictionary form: ', '词典释义': 'Dictionary meaning', '本次例句': 'This example',
  '拾语': 'Lingrove', '复习': 'Review', '个人语料库': 'Personal Corpus', '进度': 'Progress',
  '在这台 Mac 上': 'On this Mac', '仅本地': 'Local only', '设置': 'Settings',
  '词条': 'Entries', '语义': 'Senses', '编辑': 'Edit', '短语': 'Phrase',
  '添加解释': 'Add explanation', '上下文': 'Context', '移动用例': 'Move example',
  '此处含义': 'Meaning here', '已加入复习': 'Enrolled in review', '未加入复习': 'Not enrolled',
  '复习内容': 'Review items', '加入复习': 'Add to review', '添加到 Anki': 'Add to Anki',
  '今天': 'Today', '练习': 'Practice', '待复习': 'Due', '结束复习': 'End review',
  '现在可复习': 'Due now', '开始复习': 'Start review', '从语料库添加': 'Add from corpus',
  '练习卡': 'Practice cards', '表达与语境': 'Expression & context', '卡片模板': 'Card template',
  '复习队列': 'Review queue', '当前': 'Current', '新卡': 'New', '英语 · 写作': 'English · Writing',
  '今日 Lingrove 复习': 'Today’s Lingrove review', '本次练习已回答': 'Answered',
  '本轮复习完成': 'Session complete', '每一次回想，都让表达更熟悉。': 'Every recall makes the expression more familiar.',
  '本次已回答': 'Answered', '返回待复习': 'Back to due', '查看进度': 'View progress',
  '语境理解卡': 'Context card', '背面': 'Back', '正面': 'Front', '打开来源': 'Open source',
  '显示答案': 'Show answer', '再来一次': 'Again', '困难': 'Hard', '良好': 'Good', '简单': 'Easy',
  '1 分钟后': '1 min', '6 分钟后': '6 min', '10 分钟后': '10 min', '1 周后': '1 week',
  '按 Space 或 Return 显示答案 · 显示后按 1–4 评分 · 按 ⌘Z 撤销评分': 'Space / Return: reveal · 1–4: rate · ⌘Z: undo',
  '大小': 'Size',
} as const;
export function useDemoText() {
  const locale = useDemoLocale();
  return (key: keyof typeof englishUI): string => locale === 'en' ? englishUI[key] : key;
}

/** Editorial copy explains the unchanged Chinese-to-English story to international viewers.
 * The two packs share shot timing; shorter English lines leave room for the same reading holds. */
const chineseFilm = {
  invitation: ['想去。', '但怎么开口？'],
  later: '读书会之后',
  finish: ['从这一次敢说，', '到下一次', '会说。'],
  tagline: '在读写的地方顺手学语言',
  local: '补全可完全在本机运行，不打断心流，不偷走焦点',
  shortcut: '指向目标 · 按快捷键即查',
  gloss: '期待；盼望', grammar: '后接名词或动名词',
  source: '来自 · Paper & Pine Bookshop 留言',
  features: [
    ['行内自动补全', '按 Tab 逐词接受'], ['表达求助', '输入 ?? 描述想说的话'],
    ['写作翻译', '先写母语，确认后替换'], ['阅读翻译', '鼠标指向目标，按快捷键即查'],
    ['收藏表达', '连同这次的语境一起保存'], ['个人语料库', '随时找回，一键加入复习'],
    ['间隔复习', '在语境中回想'],
  ],
  captions: [
    '看到一场很想参加的读书会。', '先写下第一句。',
    '“想鼓起勇气试试看”，该怎么说？', 'give it a try',
    '最后一句，先用熟悉的语言。', '看过译文，确认使用。', '好了，发出去。',
    '“当然，欢迎你来！”', '读读他们的活动手记，鼠标指向不熟的表达。',
    '按下快捷键，直接弹出此处的释义。', '刚学会的表达，想留下来。', '连同这一次的语境。',
    '下次想用时，还能找到它。', '再给自己一次回想的机会。',
    '记住的，还有当时想说的话。', '读书会之后，这句话自己写了出来。',
  ],
};
const englishFilm: typeof chineseFilm = {
  invitation: ['I’d love to go.', 'What do I say?'],
  later: 'After the book club',
  finish: ['Find the words now.', 'Make them ', 'yours.'],
  tagline: 'Learn a language where you read and write.',
  local: 'Autocomplete can run entirely on your Mac. Keep your flow. Keep your focus.',
  shortcut: 'Point at a phrase · Press to look up',
  gloss: 'anticipate with pleasure', grammar: 'followed by a noun or -ing form',
  source: 'From · Paper & Pine Bookshop message',
  features: [
    ['Inline autocomplete', 'Tab to accept each word'], ['Expression help', 'Type ?? to describe an idea'],
    ['Writing translation', 'Preview, then replace'], ['Reading lookup', 'Point and press a shortcut'],
    ['Save expressions', 'Keep the original context'], ['Personal corpus', 'Find it. Add it to review.'],
    ['Spaced review', 'Recall it in context'],
  ],
  captions: [
    'A book club worth finding the words for.', 'A Chinese speaker starts a note in English.',
    'In Chinese: “I want to find the courage to try.”', 'The words: “give it a try.”',
    'In Chinese: “I look forward to sharing my thoughts.”', 'Read the English. Confirm the replacement.',
    'Ready. Send.', '“We’d love to have you!”',
    'Reading their journal, an unfamiliar phrase appears.', '“Come together”: to gather in one place.',
    'Keep “look forward to” for another day.', 'Save the expression with this context.',
    'Find it in your corpus. Choose to add it to review.', 'What does “look forward to” mean here?',
    'To anticipate with pleasure. Remember the moment, too.', 'After the book club, the words come from you.',
  ],
};
export const filmCopy = (locale: DemoLocale) => locale === 'en' ? englishFilm : chineseFilm;
