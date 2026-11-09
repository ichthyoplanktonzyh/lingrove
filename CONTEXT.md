# Lingrove language learning

Lingrove connects expressions encountered while writing or reading with their contextual meaning,
saved examples and later learning. Autocomplete remains an equally core product capability.

## Language

**Personal corpus (Notebook) / 个人语料库（生词本）**:
The user's intentionally saved language material, contextual understanding and organization,
usable for browsing and retrieval independently of any review tool. Saving to the corpus does
not enroll its contents in review.
_Avoid_: equating the notebook with a flashcard collection or an Anki collection.

**Expression / 词头与表达**:
An expression groups the same normalized word, phrase, pattern or sentence in one language.
_Avoid_: using “word” for every saved phrase or sentence.

**Sense / 义项**:
One core meaning or interpretation of an expression. Its identity remains the same when its label
is reworded, translated or explained again; different wording alone does not establish a new sense.
_Avoid_: treating a generated definition string as the sense itself.

**Meaning category / 意义类别**:
A reusable organizing class containing meaning nodes, such as degree or minimal degree.
Categories may have several parents, and a meaning node may belong to several categories.
_Avoid_: equating category membership with synonymy or an expression's sense.

**Classification framework / 分类框架**:
The maintained default organization of content categories and communicative-function categories.
Its identities remain stable when its names are translated or its definitions are refined.

**Custom category / 自定义类别**:
A user-defined meaning category that extends existing categories or stands independently.
It participates in the same classification relationships as a built-in category.

**Category membership / 类别归属**:
The explicit relationship placing a meaning node in an organizing category.
It remains distinct from the association connecting an expression sense to that meaning node.

**Meaning node / 意义节点**:
An independently identified content concept or communicative function that can connect several
expression senses. Its names and aliases can be written in multiple languages.
_Avoid_: equating a meaning node with a word's definition string or a personal tag.

**Content concept / 内容概念**:
What is expressed: an entity, event, state, property or relation, optionally with semantic roles.

**Communicative function / 交际功能**:
What a speaker does with an utterance, such as requesting, proposing or refusing. It can combine
with different content concepts; a request is not a synonym of the event being requested.

**Usage pattern / 具体用法**:
A reusable syntactic realization of one sense, with optional slots, collocations and usage features.
It is distinct from an original example sentence and does not replace that sentence.

**Meaning association / 意义关联**:
A claim that a particular sense, optionally restricted to one usage pattern, expresses a content
concept or realizes a communicative function. Conditions, nuances, confirmation and evidence belong
to the association. Removing an association does not remove the expression.

**Adoption / 采用状态**:
Whether a language assertion participates in notebook navigation and retrieval. Authorized agent
organization is adopted by default while retaining model authorship. The persisted `confirmed`
status means adopted for use, not necessarily human-reviewed. Explicit tentative claims remain
`proposed`; changing evidence can invalidate an assertion independently of its author.

**Search cue / 检索线索**:
A paraphrase, familiar expression or personal wording that may lead to several meaning nodes.
_Avoid_: treating an ambiguous cue as a strict synonym or an automatically confirmed meaning.

**Source snapshot / 来源快照**:
The retained wording and provenance of a source. Several occurrences may refer to one snapshot;
correcting one occurrence's source wording creates a new snapshot and does not rewrite other occurrences' evidence.
Sources and occurrences can exist before a lexical destination or interpretation is known.

**Occurrence / 出现位置**:
An immutable source reference and exact UTF-16 spans, independent of an interpretation.

**Interpretation / 解释判断**:
An independently identified claim about an occurrence, optionally linked to a sense. Several
candidates or rejected readings may coexist; at most one accepted reading owns a sense destination.
_Avoid_: identifying a claim with its source or requiring uncertain material to have a sense.

**Capture / 收录**:
Saving language material to the personal corpus. A saved expression and its senses can be
browsed and edited immediately. An accepted interpretation attached to a sense is a use
example. Removing one example leaves its sense available for editing.

**Usage / 用例**:
An expression occurrence in a specific sentence or fragment, interpreted under one sense. It
retains its source, exact text spans, translations and contextual explanation.
_Avoid_: treating a different translation of the same occurrence as a different meaning.

**Contextual meaning / 此处含义**:
The interpretation of the chosen expression given the available sentence or fragment. It may
remain uncertain when the evidence does not support a single interpretation.
_Avoid_: presenting it as the expression’s only general definition.

**General meaning / 通用释义**:
An explanation requested without an encountered sentence or fragment. It may describe several
common meanings and does not create an example sentence.
_Avoid_: inventing a context to make a general lookup appear precise.

**Context completeness / 上下文完整度**:
Whether the acquired reference is a whole sentence, a fragment, or absent. A complete sentence
does not necessarily provide enough evidence to resolve irony, reference or ambiguity.

**Lexical recognition / 词组识别**:
Identification of words and reusable expressions within one text. It defines which expression a
lookup targets, independently of correspondence between two languages.
_Avoid_: “chunk alignment” when only identifying a phrase in one sentence.

**Chunk alignment / 语块对齐**:
Correspondence between exact excerpts in an original sentence and its translation.
_Avoid_: equating a bilingual correspondence with a word’s contextual definition.

**Review tool / 复习工具**:
A product or system that owns exercises, grading, scheduling and review history. Lingrove's
built-in review and optional external tools such as Anki can use the same corpus independently.
_Avoid_: using “Anki” as the general name for all review capabilities.

**Review enrollment / 复习选入**:
The user's explicit choice to practice a corpus sense in a review tool, with its participation
state. Collecting or preparing material alone does not create this choice.
_Avoid_: equating enrollment with saving, adopting an interpretation or preparing a review draft.

**Paused review participation / 暂停复习**:
Temporarily stopping a selected sense from entering practice while retaining its exercises and
memory progress. Pausing does not remove the material from the personal corpus.

**Withdrawn review participation / 退出复习**:
The user's explicit removal of a sense from their current practice selection. Prior exercises
and history remain available; practicing it again requires another explicit choice.

**Built-in review / 内置复习**:
Lingrove's own practice, scheduling and history, accessed from Mac and mobile as one system.
Its progress is independent of an optional external tool's scheduling and history.

**Review card / 复习卡片**:
A persistent practice instance of one note under one card template, with its own ratings,
schedule and history. Source content and presentation definitions remain shared.
_Avoid_: equating a card with a copied prompt/answer document or the source sense itself.

**Review link / 复习关联**:
The connection between a notebook sense and an exercise in one review tool; an example supplies
context rather than its own review identity. A sense may have several links with independent
histories, and removing a link or its source preserves those exercises and histories.
_Avoid_: using “Anki association” as the general name for every review link.

**Generated card content / 来源生成卡面**:
A question or answer produced from current note fields and its referenced template. It is a
presentation of shared content, not a second editable corpus source.

**Anki association / Anki 关联**:
The relationship between a saved sense and an identified note in an Anki profile. Synchronization
describes agreement of their exported content, independently of learning progress.
An Anki association is one optional, tool-specific kind of review link.

## Note-based review / 笔记式复习

**复习笔记（Note）**：一份面向复习的字段集合，关联一个语料义项和一种笔记类型。来源字段跟随语料，自定义字段属于笔记。
_Avoid_：卡片正文副本

**笔记类型（Note Type）**：字段定义、卡片模板及共享样式的组合。修改类型会影响引用它的笔记所生成的题面。
_Avoid_：一次性制卡预设

**卡片模板（Card Template）**：一种提问方式的问题面和答案面定义，有独立稳定身份。

**来源字段（Source Field）**：由语料的指定内容提供的笔记字段。

**自定义字段（Custom Field）**：用户为复习单独填写、不会被来源更新覆盖的笔记字段。
