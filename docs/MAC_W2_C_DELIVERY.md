# Mac 第二波 C 交付：统一桌面语料与内容入口

2026-11-03。负责人在 `codex/mac-wave2-corpus` 完整实现并验证；固定基线
`615e2164d1d782ecf521e8edd713e64dbd07f7fa`，工作树
`/Users/shadow/.codex/worktrees/mac-wave2-corpus/lingrove`。没有跟随动态 main、合并兄弟分支、
push 或部署。

实现提交：`eb09ab563281bc49460afee4d07a09f77eff5958`。本报告另成一个提交，最终 ID 随交付消息提供。

## 完成范围与边界

- `VocabularyStore(repository:)` 接 app-owned 的同一个 `MacNotebookRepository`；
  `VocabularyArchive` 只接它的两个不可变 URL，每个同步命令在 actor 内打开同一物理文件的
  短期 engine 连接，返回前关闭。非 Sendable engine/裸 SQL handle 不跨 actor，事务不跨 await。
  删除了 app 的 `VocabularySQLiteDatabase.swift` 旧入口；产品路径没有再打开旧私有 schema。
  `init(archive:)` 与 `VocabularyArchive(url:nil)` 仅保留为显式的 disposable fixture 表面，
  后者也使用当前公共 engine，不发现用户目录。
- 保留现有桌面列表/图谱、语义关系、分类、来源证据、笔记、例句、图片、手动添加、
  CSV/TXT 预览导入、便携导出、ZIP 与完整备份/恢复、普通文本检索和既有 Mac 可选检索能力。
  沿用同一纯领域规则；保存通过 engine 的关系校验、媒体授权、journal 与已有内置材料刷新事务。
  JSON 只用于用户明确请求的便携文件，没有建立持久镜像、新语料主库或独立学习进度。
- 阅读/翻译收藏组件与写作候选收藏沿现有 store 方法进入同一入口；未保存的新内容不创建收藏。
  新的 `connectExplanations(to:)` 在请求开始前捕获持久化 closure 的原 scope，完成后只能给
  当前仍收藏的目标附加解释。取消收藏后，保留的 catalog 证据不授权自动保存新解释。
  账户切换清空解释内存缓存、取消旧 session；没有增加模型请求、改 prompt/采样或发送目的地。
- `VocabularyStore.unavailable(_:)` 不创建替代 archive，显示明确不可用文案并拒绝保存/CLI；
  实测打不开的 synthetic 原数据库字节保持原样。组合根可继续启动补全、阅读与翻译。
- `onRequestBuiltInReview: ((VocabularySelection?) -> Void)?` 已提供，列表工具栏打开概览，
  义项上下文菜单与详情入口传选择。未注入时隐藏；只导航，不收藏、选入或评分；例句没有制卡入口。
  实际准备和复习窗口仍由 E 负责，既有可选 Anki 流程保留且不混写内置历史。

## 作用域、草稿与长期 owner

`VocabularyOperationScope` 复用完整 `LingroveNotebookSnapshot`；archive reply 的
`VocabularyArchiveSnapshot` 将安全文档与该 token 一起交回 MainActor，纯 CLI 规划仍使用公共
便携 `VocabularySnapshot`。这避免把 UI 的 revision 当作账户身份。

编辑、导入/导出 session、图片保存、Anki 操作和异步回调保存原 workspace/notebook/generation。
同一 scope 中保留既有字段三方合并，最后对本次读取的最新 revision 做 engine CAS；旧 scope
不能靠重读新快照给自己换归属。Anki 的 `ReviewOperationScope`/sheet/batch 只增加 notebook
围栏，不改协议、调度、模型模板或历史。迟到回执不能绑定进新账户。

repository 通知后，scope 身份变化立即清空 entries、语义/分类、pending、草稿身份与搜索缓存；
SwiftUI 根按 `scopeIdentity` 重建。相同 scope 的并发通知会保留一次重读请求，旧 snapshot
不能覆盖更新的 revision。窗口 owner 直接订阅 scope，连隐藏窗口的字典/解释目的地也会 reset，
避免重新打开时 Resume 查询上一个账户的内容。

`VocabularyStore.shutdown() async` 取消订阅并排空在途 archive 访问。普通关窗仍只暂停窗口
借用的会话；应用结束必须先排空，再关闭 repository，不删除仍有 worker 使用的 SQLite 文件。

## 媒体与便携文件

图片规范化复用共享 PNG helper；写入/授权和 content-addressed blob cache 复用
`LingroveNotebookMediaStore`。`store.image` 还要求图片被当前文档引用，因而最后一个词库
引用移除后不会继续给 UI 返回旧图片；物理 bytes/map 的保留与清理由共享 engine 的 pins、
复习/同步引用管理，不做旧 archive 的立即物理删除。

备份与导出使用 `LingroveNotebookBackupStore` / `LingroveNotebookStudyExportStore`，
在一致的读事务里冻结文档和已授权图片。恢复先完整验证，再进入共同事务。输出先在私有临时
文件编码/fsync，最终 scope 检查与 rename 只短暂借 writer lock，账户切换不能发布旧 scope
准备的文件。数据库/WAL/媒体根和 hard-link 目标保护沿用现有文件边界。

## CLI 与必要 schema 扩展

纯值 `CLINotebookScope` 只含 `workspaceID`、`notebookID`、`generation`；CLI executable
不依赖 engine。所有 notebook read/status 回复给出 `result.notebookScope`。对既有对象的
append/update/resource 操作、带 expectedRevision 的批次，以及显式引用已有 sense/meaning
ID 的 capture，必须保留读取时的 `notebookScope`。纯新 v1 add/capture 可以省略，由 app
admission 固定一次当前 scope。输入白名单、batch/capture 发布 schema、文档和 skill references
已同步，路径读取/授权、被动 mailbox 和图片字节安全边界没有扩张。

父代理明确批准的必要 ledger 位于同一本 engine SQLite，当前 fresh schema 从 **37 → 38**：

| 文件/接口 | 单一职责 |
| --- | --- |
| `Persistence/NotebookStore/LingroveNotebookCLIStore.swift` | `notebook_cli_receipts`、有界 fingerprint/UTF-8 JSON 结果、原业务身份；结果上限 32 MiB，与 CLI envelope 上限一致 |
| `LingroveNotebookEngine.notebookCLIReceipt(key:basedOn:)` | 在当前 durable scope 下只读查询完成结果；首次 owner/workspace/notebook/endpoint 不匹配则拒绝 |
| `saveNotebookCLI(_:basedOn:images:receipt:)` | 同一 Core writer 事务内做 scope/CAS、复用原 corpus writer、写成功 receipt；取消/失败整体回滚 |
| `LingroveNotebookStore.saveInTransaction` | 仅从 private 改为 module-internal，给上述复合命令借用；未复制 writer |
| `LingroveNotebookSchema` / `LocalDatabaseSchema` | 将私有 receipt 表纳入 fresh create/reset，版本 38；mobile 的 import shim 也取同一 fresh 定义 |

ledger 不进入公共 sync journal。key 在本安装库中唯一，不能在另一账户当成新命令执行。
完成结果在原业务 scope 重启/ABA 后可以只读重放；generation 围栏约束新执行/迟到写，不禁止
合法完成结果查询。新回执/业务写不会只完成一半，journal ACK 不会丢掉 CLI 成功回执。

没有写旧 schema、开发快照或 Anki 历史迁移，没有自动删除真实应用目录。37 或其他旧开发库
由 owning initializer 明确拒绝，不偷偷创建空库；父整合验证应使用新的 disposable fixture。

## 实际验证与证据

证据根：`/Users/shadow/.codex/worktrees/mac-wave2-corpus/lingrove/build/mac-w2-c/`。
所有 Swift/Xcode/native 操作均通过 Python fcntl LOCK_EX 持有
`/tmp/lingrove-mobile-validation.lock`。没有手机/Simulator、真实云账户、邮箱或权限操作。

| 检查 | 实际结果 | 主要证据 |
| --- | --- | --- |
| 真实 engine CLI atomic/CAS/cancel/跨 scope/关闭重开/ACK 后回执 | **3 passed** | `engine-cli-final.log/.json` |
| 广泛 Mac 语料、媒体、导入/导出、关系/来源、CLI、Anki stateful fake、解释服务 | **138 total：128 passed / 2 failed / 8 opt-in skipped**；两项失败在下列定向执行关闭 | `corpus-regressions-r2.log/.xcresult` |
| 修正空媒体根预期后的真实 CLI dry-run→commit→replay→portable read | **该方法 1 passed**；同次另一方法仍因 fixture 缺语言失败，不算整轮通过 | `affected-cli-executed.log/.xcresult` |
| 最终边界 CLI、旧 scope/不可用、大于 256 KiB 的回执重放、未收藏解释、原解释存储/采用 | **8 passed / 0 failed** | `affected-content-executed.log/.xcresult` |
| 隐藏窗口 reset 后 Resume 不再查询旧目的地 | **1 passed** | `window-scope-executed.log/.xcresult` |
| 独立原生窗口 Cancel→Create→Save→Edit，以及关闭/重新打开 SQLite | **1 passed**，实际 CUA 鼠标/文字操作 | `native-corpus-journey.log/.xcresult`、`native/ui-steps.json`、`native/stored-proof.json` |
| 最终 Mac app-hosted build-for-testing | **通过，仅编译**；最后 scope reset hook 另编译通过 | `final-host-build`、`window-scope-build` logs/xcresults |
| 最终 app strict codesign | 通过 | `final-signature.log/.json` |
| 修改的 Mac app Swift 严格 lint、whitespace | 通过 | `lint-scope-final.log/.json`、git diff check |
| 现有本地化检查 | **5 passed**；两条新 UI 文案覆盖原有 15 个语言 | `localization-proof.json` |

第二轮的 8 个 skip 是真实 Anki/其 native opt-in、旧 native 导出，以及本次 native gate。
本次独立 native gate 随后实际执行通过；没有运行真实 Anki 客户端、额外长 UI 链或 15 语言 UI
矩阵。按契约没有因纯测试 fixture/文本变更重跑未变的整批业务套件，以上逐方法证据没有合称
“一次全绿 138 项”。`validation-proof.json` 保存原始统计、final source hashes 与最终 binary hash。

原生流程实际观察到：取消后仍为 “No saved expressions”；保存后仅 1 条 serendipity / a happy
discovery；编辑后详情显示 “Mac native edit”。关窗和新 engine 连接重读后仍为该 1 条，revision=3。
视觉核查使用 CUA 实际窗口截图，未声称进行了全应用菜单级重启或双设备 UI 接续。
native 结束后仅补了隐藏窗口 scope reset hook，并执行对应组件检查，没有重复未变化的保存编辑流程。

## 原失败、审查与未验范围

两名新的 Luna/max 只读 reviewer 没写代码或测试。集中修正了公开 scope validator/schema、
existing-ID capture 准入、snapshot 失败时的 fail-open、重读通知丢失、媒体读范围及隐藏窗口
目的地。未采用“完成 receipt 必须匹配旧 generation”的意见，因为父契约明确允许同业务
scope 的完成结果只读恢复。

原始失败均保留：包资源签名缺显式本地 team；一个闭包显式 self 与测试类型/actor 隔离编译；
旧测试直接打开旧表/旧媒体路径、立即物理删图预期；边界 fixture 超字段长度/缺必填语言。
`affected-cli-final` 虽退出 0，但实际 **0 tests**（Swift Testing 方法筛选缺 `()`），已纠正并
实际执行，不计为通过。首次 fixture 提前删库暴露在途 worker，新增 shutdown drain 后不再
出现该 vnode/API violation。

`native/offscreen-render-unusable.png` 是 NSHostingView.cacheDisplay 的透明/缺内容输出，
没有当作视觉通过证据；实际 CUA 截图中已检查详情和笔记。没有为这个非产品截图问题扩建
自动化框架或重跑业务。

全库 lint 首跑另外报出四处未修改文件既有问题：`VocabularyClassificationPolicy` 的两处
参数对齐、`VocabularyPolicy` 与 `VocabularyMeaningLabelPolicy` 的空行。没有改无关文件
或更新 baseline；交付检查针对修改的 Mac app 文件并全部严格通过。

真实 cloud/provider/邮箱、真实 object store/设备同步、真实 Anki 人工、global menu/Settings
最终组合根均不在本 C 模块的已执行声明内。D/E 的实际同步/内置复习组合与父整合验收继续
使用同一 repository；没有移动 embedding、AI 对话、发布门控或遥测工作。

## 父组合根接线

1. AppEnvironment 只构建一次 `MacNotebookRepository(databaseURL:mediaDirectoryURL:)`，将同一
   引用给 C/D/E。成功时 `VocabularyStore(repository:)`；失败时捕获 error，使用
   `VocabularyStore.unavailable(error)`，不改路径建第二个空库，也不让补全/翻译图初始化失败。
2. 用 `vocabularyStore.connectExplanations(to: explanationService)` 替换旧
   didExplain/loadPersisted/lookupSaved/enrich 的手写接线，不能同时保留旧无 scope didExplain。
   翻译/阅读/写作/CLI/Anki 继续借用这个 store。
3. `vocabularyStore.onRequestBuiltInReview = { [weak review] in review?.show(selection: $0) }`。
   E 的 `onOpenSource` 可沿现有 `VocabularyWindowController.show(selectedID:senseID:)` 返回。
4. App termination 在各 owner 停止接收新操作后，先 `await vocabularyStore.shutdown()`，
   再 `try notebookRepository.shutdown()`；不能用同步阻塞等待 MainActor，也不能在普通关窗做此事。
5. 本分支已重新生成 Mac 工程引用；父整合最后统一 XcodeGen。新增/移除的 source layout 条目
   可从 commit diff 与本报告取得，根 project.yml / SOURCE_LAYOUT / AppEnvironment / AppDelegate /
   SettingsCoordinator / SettingsContainer / 全局 menus/commands 均未抢改。

## 清理

`cleanup.json` 记录本树 DerivedData、Swift scratch/cache、SourcePackages、复制的 inference/TTS
与 native helper build roots 已移除并核对，证据目录保留。自己的 native test host 已退出，
disposable notebook 已移除。没有启动本地 HTTP 服务、停别人的进程、改变 Simulator/系统授权、
删除真实应用目录或修改共享固定依赖源缓存。
