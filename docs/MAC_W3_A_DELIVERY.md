# Mac Wave 3 A：保存内部优化交付

2026-11-03。完整模块 A 已实现、正确性验证并完成本树清理。没有进行延迟基准、
Instruments、前后耗时测量或性能阈值验收；没有操作用户运行中的 Lingrove Dev。

## 分支与集成入口

- 工作树：`/Users/shadow/.codex/worktrees/mac-wave3-save-pipeline/lingrove`
- 分支：`codex/mac-wave3-save-pipeline`
- 冻结起点：`8a796f9d9cca57b75208e3636b24c9edf188a44e`（已含 `8c921730` 首轮修复）
- 实现、测试和验证脚本提交：`ff7a4928b2ca66be7a4afaf6ca08838615761092`
- 本文独立提交；其准确提交 SHA 见正式交付消息 / 分支 HEAD。

未跟随或合并 main / 兄弟工作树。没有改 UI、账户/网络/Cloud、FSRS、协议、schema、
迁移、CLI 公开表面、模型/OCR/补全或根 `project.yml`。B 使用的既有 Repository、
VocabularyStore、engine 查询/命令签名保持源码兼容。新增 `saveNotebookEntry` 仅由 A 的
普通收藏/编辑路径使用，不要求 B 改调用。

集成时先合入实现，再由 root 结合 B 的依赖统一执行 XcodeGen。新 app helper
`Lingrove/Support/Vocabulary/VocabularySaveLiteralEquality.swift` 需要被生成工程收录；
本树验证时已生成并编译，交付前只还原了本次生成的 `Lingrove.xcodeproj/project.pbxproj`，
避免和 root / B 的工程生成发生合并冲突。没有还原其他开发者改动。

## 保存路径的结构变化

首轮修复减少了 MainActor 的完整 snapshot 读取，但普通收藏/编辑仍重建多次 joined
entries，writer 再读出/解码完整 corpus、重复校验目录、编码前后完整持久化行，并对
前后完整 public wire projection 做哈希比较。

本次普通路径为：

1. `VocabularyPolicy.entryForSave` / archive editor 只准备目标 joined entry 和该 entry 的
   personal collections。编辑保留三方字段合并；新例句、新义项、取消收藏与目录保留仍
   按既有业务语义处理。其他 entry 不再经 `entries` 的全量 setter 回写。
2. archive actor 持有一条自己的 engine connection，直到 `VocabularyStore.shutdown()`
   排空已接收操作后关闭。它仍使用同一个 repository 文件，未创建第二份数据库或持久化。
   单独的 actor 版本缓存不再绕过 writer 的 external-write token 检查。
3. connection-owned cache 保存最后 SQL 验证过的 snapshot、joined entries、entry ID 校验
   集合与持久化 row projection。每次读取仍检查 workspace / book / revision / generation，
   同时检查 SQLite `data_version` 与本连接 `total_changes64`。前后两次 token 检查保护
   deferred reader 的快照一致性；其他连接写入、同连接写入、账户 ABA 或原始损坏均失效。
4. writer 从自己的当前 SQL/cache 状态建立 `VocabularyEntrySaveChange`。调用者 baseline
   仅提供 CAS 身份，任意构造的 baseline.document 不能替代当前文档。该 change 只能通过
   已完整验证的 save state 的单 entry 命令创建，不能携带任意 dirty-ID 声明。
5. 单 entry preparation 只整理/校验目标 entry 的解释、内容和 review 草稿；其他 entry
   复用已校验 ID 集。它仍检查跨 entry ID、重复词条、全局 evidence/claim/collection
   关系以及语义引用/证据 reconciliation。未改变的分类目录、节点与模板沿用已有证明。
6. codec 重建目标 entry / interpretation / collection 行组及新增不可变 evidence，并处理
   删除后的 rank 移动与必要的 semantic reconciliation 行。未改变的 corpus、分类和模板
   行被复用，不再编码/比较前后两个完整 row projection。Unicode 相等但字节不同的目标
   payload 仍比较字节并持久化。
7. public-intent 通过原有 public leaf encoder 比较受影响片段；结构变化直接视为公开变化。
   private Anki binding/audio receipt 与 timestamp-only bookkeeping 继续排除，保留取消和
   frozen-ACK 的语义。没有新增或改变 wire 字段。
8. SQL 排序写入、revision CAS、pending journal、media ownership/pins 与内置 review source
   refresh 仍在同一 writer transaction。缓存仅在成功路径推进；任意外层 CLI/account
   rollback 会清空 prepared cache。UI 仍在真实提交后反馈成功。

目录 installer 还会先确认 app 内已解码 manifest 的 framework/version，避免在每次收藏
与 commit 时重复构造全部 bundled category key 集。媒体扫描改从 canonical collection /
retained plans 读取，不再为找图像引用构造完整 joined corpus；writer 仍对整个 notebook
的唯一图像引用检查总量，并逐一校验当前 workspace 的所有权。

## 文件与类型边界

| 边界 | 责任、所有者与数据流 |
| --- | --- |
| `VocabularyEntrySaveState` / `VocabularyEntrySaveChange` | Notebook 的纯验证状态；由 SQL cache 持有。完整验证值进入，受限的单 entry 变更与新验证状态输出，不能写数据库。 |
| `VocabularyEntryRowProjection` / `VocabularyEntryRowChange` | Codec 的可复用 typed rows 与行组差异；由同一 cache 持有，消费受限 change，输出真正变化/删除行供 writer 和 journal 共用。 |
| `LingroveNotebookSaveCache` / `LingroveNotebookCacheToken` | 单个 DatabaseCore 的派生内存状态，受现有 connection lock/transaction 串行保护；不是账户权限或调用者可提交的持久真相。 |
| `LingroveNotebookEngine+EntrySave` | 新增的保存命令入口，负责 SQL 当前权威、CAS、媒体、公共意图与共同提交尾部。它不拥有 UI、网络或调度器。 |
| `VocabularyArchive` / `VocabularyPolicy` | app 的 actor 生命周期与纯 capture/editor preparation。既有 store 输入经 actor 到同一 engine，成功 immutable snapshot 返回 UI。 |
| `VocabularySaveLiteralEquality` | 小编辑子树的字节级三方合并。对既有 Set/enum-keyed Dictionary 字段排序，保留普通数组顺序和 NFC/NFD、NUL 等文字字节。 |

权衡：连接与一个有界的完整派生快照会留到 archive shutdown，换取普通保存不再重复
解码/校验/投影未变化内容。全局关系、必要媒体授权、review source refresh 与 rank 维护
仍有线性扫描；本交付不宣称保存为常数时间，也不提出未经测量的速度数值。

## 保留的完整边界

通用 `saveLingroveNotebook`、结构编辑、CLI 批量命令、import/restore、remote apply 等
仍使用各自既有完整验证与协议边界。新命令不能编辑任意分类、模板、语义节点或别的
entry；跨 entry accepted interpretation ID 不可被夺取。原始 source/occurrence 的改动
会保留旧证据并产生新身份，手改的 review material、Anki 元数据和评分历史继续保留。
没有增加迁移、旧开发数据兼容、自动擦除或本地功能登录门槛。

## 实际执行证据

证据根：本工作树 `build/mac-w3-a/`，最终 `proof.json`、`source-inputs.json`、
`cleanup.json` 及各日志/xcresult。所有 Swift/Xcode/native 操作通过
`scripts/validation/validate-mac-save.py` 持 Python `fcntl.flock(LOCK_EX)`
`/tmp/lingrove-mobile-validation.lock`，持锁到证据落盘。本树没有并发构建。

| 实际检查 | 结果与证据 |
| --- | --- |
| 共享 Engine focused regression | **6 XCTest + 16 Swift Testing passed**，见 `engine-final-coherence.log`。包含既有 scope/CAS/cancel、literal review retention、账户交接及通用 SQL rollback/key exchange。 |
| 新增 deferred read / external commit 边界 | **1 passed**，见 `engine-pinned.log`。与上一行并集为 **23 项**，不声称一次整套执行了 23 项。 |
| 单 entry 集成覆盖 | 前两行中共 8 项新检查；实际 SQL/cache lineage 复用，伪 baseline.document 不被信任，完整 codec 行/字节与 public-intent 等价，来源/范围/选择/rank，外部写入/原始损坏/rollback/ABA，取消/关系拒绝，媒体/journal 原子性，手改 material 与历史。 |
| 完整 Mac app-hosted build-for-testing | `mac-build-verified.xcresult` / `.log` **通过**，只计编译。 |
| 私有 Mac test host 实际执行 | **6 passed / 0 failed / 0 skipped**，见 `native-result-verified.xcresult` 和 `native-summary-verified.log`。新 capture/Unicode/editor membership 检查，外部 commit/ABA，收藏/编辑/媒体/备份/重开，旧 draft/Anki/解释回调围栏，CLI dry-run/replay 与 receipt/media rollback。 |
| 签名与隔离 | 私有 `io.ichthyoplanktonzyh.lingrove.mac.wave3.save.validation` host，`host-verify-verified.log` 通过。实际日志确认跳过 production service startup；`host-verified.json` 保存 binary SHA-256。 |
| app 生产改动 strict lint / diff | 四个改动生产 Swift 文件 strict lint 通过，见 `lint-final.log`；`git diff --check` 通过。 |
| 独立审查 | 一名新的 Luna/max 只读 reviewer；未写代码/测试/脚本、未运行 Swift/Xcode。媒体总量与 archive token 绕过风险已关闭，最终 cache coherence spot check 无遗留问题。 |

测试只用 disposable SQLite / media / prefs、合成身份及私有宿主。无真实账户、邮箱、
生产服务、TCC grant、Simulator、模型 eval、部署、push 或用户 Dev 进程操作。

## 失败记录与未验证边界

- 新 changed-range 测试曾使用不存在的 `VocabularyTextRange(location:length:)` initializer，
  改为既有 `NSRange` initializer 后目标检查通过。原编译失败在 `engine-final.log`。
- 首轮 strict lint 的长行/复杂度/空行已整理后通过，保留 `lint-first.log`。
- 初次原生 method filter 缺少 Swift Testing 的 `()`，Xcode 返回成功但实际 **0 tests**；
  验证脚本的数量断言拒绝此结果。仅修正 filter 后执行相同六项并通过，原证据保留在
  `native-result-app.xcresult` / `native-summary-app.log`。这不是产品导航故障。
- 最终保守 token coherence guard 后，执行了上述共享引擎检查、一个新的 pinned-reader
  检查，并重编译和执行同样六项原生检查。未因测试 fingerprint 改变重跑整套手机业务。
- 没有在用户生产 app graph 做鼠标流程/截图或体感耗时复验，没有真实云账户、跨设备、
  真实 Anki、手机或旧 macOS 矩阵验证。共享代码仍需 root 按整合影响选择后续跨端检查。
- 无已知未修复的数据或保存主路径失败。通用批量/结构编辑仍保留完整路径；全局关系和
  material refresh 的线性工作保留，这是明确的正确性边界，不是未经验证的延迟承诺。

## 清理

`cleanup.json` 已确认本树 `build/DerivedData`、Swift package scratch/cache、module cache、
私有 host、复制的 source-packages / inference / TTS / OCR / dictionary native 构建输入均
不存在，私有 host 无残留进程，自己的 Python bytecode 也已删除。共享固定缓存未改。
仅保留少量日志、源码 SHA、proof 与 xcresult 证据；未保留一个可误启动的开发 app 包。

Root 可按上述提交合入并统一生成工程；无需新增生命周期挂接或向 B 提出接口变更。
