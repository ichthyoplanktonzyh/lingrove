# Note 与卡片模板：当前实现与视觉迭代边界

2026-11-04。此实现取代此前仅供讨论的结构化区域草图；默认卡片和编辑器的最终视觉设计仍可独立迭代。

## 日常路径

语料库中加入复习，留在语料库继续阅读；在复习首页开始一轮。加入使用当前默认笔记类型，
自动绑定义项及一条完整例句。默认仅生成「表达 → 含义与语境」这一张卡。
模板编辑与自定义字段编辑均为可选入口，不在加入流程中增加制卡步骤。

## 数据与职责

| 边界 | 责任 | 修改的影响 |
| --- | --- | --- |
| 义项 | 语料内容的唯一来源 | 来源字段跟随更新 |
| Note | 义项、笔记类型、例句绑定和自定义字段 | 同一 Note 的所有卡片共享内容 |
| Note Type | 字段定义、多个卡片模板、共享 CSS | 所有引用该类型的 Note 使用新定义 |
| Card Template | 稳定 ID、名称、正面和背面 HTML、启用状态 | 定义提问方式；改名和样式不重建 Card |
| Card | Note × Template 的持久实例、调度与历史 | 每种提问方式独立复习 |
| Renderer | 字段替换、条件渲染、原生 WebKit 显示 | 预览与复习使用同一实现 |

来源字段包括表达、含义、绑定例句、翻译、笔记和义项富内容。富内容保留段落、标题、列表、粗斜体和图片。
自定义字段按稳定字段 ID 存储 HTML；来源更新不覆盖它们。字段改为来源绑定时保留其原有自定义值。

空正面不生成新卡；已有卡片变空或模板停用时退出可复习队列，保留其身份和评分历史。
带历史的模板不能直接删除，可停用。来源更新、Note 编辑、类型编辑与卡片生成使用同一 SQLite 事务。
不转换既有练习为 Note；数据库增加空的新模型表，不清理用户语料。

## 可以交给后续视觉模型修改的文件

- `Packages/LingroveNotebook/Sources/LingroveNotebook/ReviewNotes/ReviewNoteProjection.swift`：默认字段、HTML 与 CSS。
- `Lingrove/UI/BuiltInReview/ReviewNoteTypeEditor.swift`：Mac 编辑器布局、字段映射、模板列表和实时预览。
- `Lingrove/UI/BuiltInReview/ReviewNoteEditor.swift`：单条 Note 的例句与自定义字段编辑。
- `Lingrove/UI/BuiltInReview/Rendering/ReviewNotePracticeView.swift`：卡面外部的原生来源/模板操作。
- `Lingrove/UI/BuiltInReview/Rendering/ReviewNoteWebView.swift`：可替换的显示宿主。

视觉修改不需要更改 SQLite、同步协议或 FSRS。默认 CSS 是正常模板数据，不在 SwiftUI 中硬编码卡面布局。
WebKit 宿主只接收 HTML、CSS 和有限的本地图片字节，不依赖账户、调度、仓库或应用服务。
共享 `ReviewNoteHTMLDocument` 统一文档边界；移动端采用同一模板和字段解释器。
仅在变更字段/模板身份、内容归属或同步结构时才需要两端协调调整。

## 模板语法与 Anki 边界

当前支持 `{{Field}}`、`{{text:Field}}`、嵌套 `{{#Field}}` / `{{^Field}}` 条件和背面 `{{FrontSide}}`。
未知字段、未闭合条件和未支持的过滤器会报错。字段值在模板解析后插入，内容中的花括号不会被当成代码。
参考 [Anki 字段替换](https://docs.ankiweb.net/manual/templates/fields) 和
[条件生成](https://docs.ankiweb.net/manual/templates/generation)；这是常用语法子集，不承诺完整 Anki 引擎兼容。
不支持 Cloze、任意 JavaScript、插件、远程资源或 Anki 专有音频/TTS 过滤器。

`ReviewNoteAnkiExport` 保留命名字段、模板和 CSS。Mac 的单条及批量发送已经通过
`NoteAnkiSession` / `NoteAnkiSender` 接入现有 AnkiConnect 连接设置；新发送使用共享 Note，
不再先构造 Front/Back 卡片副本。旧的逐卡 Anki 关联仍可单独编辑，不做自动转换。
发送更新相同 Note 的字段和共享模型；两种工具的评分与调度保持独立。详情见
[ANKI_NOTE_SYNC.md](ANKI_NOTE_SYNC.md)。

## 原生操作与同步

Mac 编辑器支持修改正面/背面/CSS、多个模板、字段来源、自定义字段、复制类型和设为默认。
保存使用原始 Note/类型版本与仓库范围进行校验；取消只丢弃草稿。
移动端此次接入自动选入、共享卡面渲染、同步和排队评分的题目版本校验；完整类型编辑器仍由 Mac 提供。

Review 协议 v3 同步 Note、类型、成员关系和默认类型，并确认精确发送摘要。
服务端按已确认基线合并整份实体；冲突失败，不用任意客户端计数覆盖其他设备的编辑。
只改 CSS 也推进复习同步游标并使旧题目的评分失效。传输期间新发生的本地编辑保持待同步。
定义目录受限于有界请求，不提供无限量目录分页。账户接纳复制 Note 关联并保留目标账户已有定义。

后端迁移和移动适配位于私有 `lingrove-mobile` 仓库；部署是独立步骤。本地验证使用合成数据和隔离宿主，
没有替换安装中的 Dev 应用或接触其真实语料。

## 验证记录

- 共享模板解释器：4 项通过。
- 共享存储全量：73 项中初次仅旧 schema 版本断言失败；更新断言后该项和 6 项 Note 测试通过。
- 后续题目版本/停用状态检查：7 项通过，包含账户接纳后 Note/Card 历史关联。
- Cloud storage adapter：4 项通过，覆盖精确确认、发送后评分保留和媒体确认。
- Mac 私有宿主：5 个测试、6 个用例通过；包含 Aqua/Dark Aqua 下真实 WebKit 卡面、编辑保存和评分。
  已查看卡面与编辑器的原生缓存截图。编辑器缓存截图中的原生按钮层不能用于判断最终合成颜色；
  compositor 窗口截图未取得，不宣称已完成最终视觉验收。
- 后端隔离 PostgreSQL 18.6：真实 HTTP/事务测试通过，覆盖 Notes/卡片一起回滚、成功发布、重复请求、
  CSS 游标变化、首次拉取和冲突拒绝。TypeScript 检查及 3 项合并规则测试通过。
- 移动端：iOS 27.0 / 私有 iPhone 17 Pro 模拟器编译及 1 项宿主 IO/评分集成测试通过，模拟器已删除。
  该检查验证自动选入与题目版本校验，不代表移动端完整交互/最终视觉验收。
