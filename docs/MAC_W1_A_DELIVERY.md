# Mac Wave 1 A delivery — portable corpus and built-in review persistence

2026-11-03。固定基线 `9351fd93b697a145ded9ded6bb008420b864b5d8`（包含移动第三波
`e523fc81`）。工作分支 `codex/mac-wave1-notebook-core`；实现提交 `945d43c715f2bda1012c8e203c71bc34db2bd74a`；文档收尾提交随后追加。
本模块已完整实现并通过下述实际检查，可进入第一波 A/B 集成 checkpoint；尚未接第二波
Mac 产品服务图，也未声称真实 provider、服务器或双设备旅程通过。

## 结果与职责

新增 `Packages/LingroveNotebookEngine`，一个可直接由原生 Mac/iOS import 的产品。
它依赖现有 `LingroveNotebook` 的 graph/domain、codec、sync rules、PNG storage 和 study
export；没有第二套 Sense、UUID/UTF-16/wire 规则，没有 SwiftUI/UIKit/AppKit、网络 runner、
默认 guest 或整套 `LocalDatabase` / `FlashcardsStore` 服务图。

`LingroveNotebookEngine` 是单连接 facade。owning initializer 接受宿主明确提供的 SQLite
和媒体目录；borrowing initializer 接受已有 `DatabaseCore`。Core 持有可关闭的 SQLite
handle 和寿命长于 handle 的递归锁，原始 handle 保持包内可见。所有复合操作同步借用
这一个受保护连接；网络等待必须在事务之外。借入 facade 的 `close()` 不关闭宿主连接。
移动 `LocalDatabase` 只拥有一次 Core 和一个 borrowed engine；旧 notebook/Card/review/
sync-persistence 方法转发到共同实现，移动仍拥有路径、旧 schema 初始化/迁移、日志、
first-review-onboarding 回调和应用生命周期。

当前完整 schema 为原移动 version 37。新 owning initializer 只接纳空库或 version 37，
不会自动清除、迁移或重写实际应用目录。移动已有初始化入口继续调用同一共享 schema/
bootstrap。保留移动原来的旧开发迁移不代表本次新增了迁移工作。

详细文件、类型职责、协作者和数据流见
[`Packages/LingroveNotebookEngine/README.md`](../Packages/LingroveNotebookEngine/README.md)。
精确的整文件迁出和部分类型迁出清单在
[`extraction-manifest.json`](../Packages/LingroveNotebookEngine/extraction-manifest.json)。
原 Nibomo MIT 和 ts-fsrs 5.2.3 MIT 许可分别保留在本包 `LICENSE`、`LICENSES/`。

## Public symbols 与事务边界

| 入口 | 对集成负责的行为 |
| --- | --- |
| `LingroveNotebookEngine(databaseURL:mediaDirectoryURL:)`、`init(borrowing:)`、`DatabaseCore` | 宿主注入位置/连接；非 Sendable owner，同步事务与关闭串行，媒体根可独立于 SQL 目录 |
| `LingroveNotebookSnapshot`、`loadLingroveNotebook`、`saveLingroveNotebook` | 工作区/notebook/revision/generation CAS；同事务 rows、图片授权、private values、journal 和材料刷新 |
| `LingroveNotebookAccountStore`、`preserveNotebookWorkspaceForLink`、`switchActiveWorkspace` | 账户字节隔离、明确本地接纳提议/采用/保持独立、来源保留；登录本身不复制语料或历史 |
| `LingroveNotebookWindowBinding`、`LingroveNotebookWindowStore` | owner/workspace/notebook/replica + durable generation；有界 raw-byte windows/pages，完成只返回 proof |
| `LingroveNotebookSyncStore`、`LingroveNotebookApplyPlan` | confirmed shadow、prepare/commit、private overlay/remainder、CAS/rebase/cursor 原子提交 |
| `LingroveNotebookUploadStore`、`LingroveNotebookPendingUpload` | journal→冻结 bounded body；exact receipt/ACK，不删除迟到的新写或未发送操作 |
| staged/closure/terminal/retry/conflict stores | 原第三波 staging、确认、取消、显式重试、拒绝和冲突规则，rotation/冻结持久化后才继续 |
| `LingroveNotebookMediaStore`、`LingroveNotebookMediaQueueStore`、Media job/state/direction/descriptor | 原 PNG 校验、独立根目录、工作区授权、pin/lease、持久化队列、控制/重试/清理；不把物理去重当授权 |
| `LingroveNotebookCardSource/Draft/Link/Material`、`Card`、`Deck`、`ReviewEvent` | 同一来源/练习值；Card、Anki 与内置复习的调度/历史不混写 |
| `enrollNotebookSenses(_:basedOn:)`、`setNotebookReviewStatus(_:enrollments:basedOn:requestID:)` | 明确选入/暂停/退出/恢复；SQLite writer 内校验 saved snapshot generation，含幂等 replay 前的校验 |
| `submitNotebookRating(_:basedOn:expectedCardOperationID:)`、`undoLastNotebookRating` | 独立 immutable event + 当前 Card schedule + journals 同事务；因果 head 撤销只恢复调度，保留后续卡面手改 |
| prepare/retain/add/refresh/unlink notebook exercise commands | 材料/来源和 Card writer 共用连接；字段三方刷新、缺失材料 quarantine、历史归属和新 exercise admission 保留 |
| `LingroveNotebookReviewRequest/Response/Undo`、`LingroveNotebookReviewSyncStore` | 唯一纯 review codec、held lane 请求/应用；原 7 MiB/批次依赖/有限历史接纳；失败不改变 corpus cursor |
| `Fsrs*`、scheduler settings、`ReviewQuery*`、Card/deck/history/statistics queries | 现有 FSRS-6、fuzz、严格时间戳、队列顺序/时区；Card 调度快照为真相，不从 event replay 修复 |

原移动方法名仍可作为内部兼容入口使用。新 Mac screens 应保留 saved snapshot 并使用上述
带 `basedOn` 的 scoped commands。A 不依赖尚未交付的 `LingroveCloud`；B-to-A 的具体 port
adapter 在主集成完成：在同步 read/prepare 边界冻结/编码 request 或 bounded Data，放开
SQLite 后等待 HTTP，返回后再使用原 binding 进行 apply/ACK。不要从 runner 运行 SQL。

## 旧宿主迁移和必要薄适配

- `Database/{Core,NotebookStore,CardStore,DeckStore,Workspace,MediaAssetStore,MediaTransferStore}`
  的共同实现与必要 `Database/Sync` stores 已迁出，旧文件保留 import shim。
- `Database/LocalDatabase` 的 notebook、Card mutation、review、undo、preparation、read 和
  sync-persistence facade 保留调用标签/defaults，转发同一个 engine；first-review-onboarding
  使用同步 transaction callback，仍在评分事务里完成。
- `Review/Scheduling`、必要 queue 纯规则、Card/Deck/Review/Progress 纯值已迁出；移动原入口
  继续使用同一实现。通知专用/AI 查询、社区/付费/guest 服务图留在宿主。
- `Notebook/LingroveNotebookIO.swift` 的 enroll/status 把已有 snapshot 直接传给 scoped engine；
  `LingroveNotebookReviewActions.swift` 只透传既有 scope。没有 UI/导航/网络行为重组；移除了
  无调用者且不能携带 generation 的 draft-only IO overload。原生新增 IO ABA 回归检查。
- mobile `.xcodeproj` 为 app 和 native tests 添加本地 engine product 引用，保留原 Notebook/
  StudyExport 等产品；未编辑 Mac source、根 `project.yml`、共享 AGENTS/SOURCE_LAYOUT 或 B 包。

经父代理确认的 Cloud 纯类型例外，准确清单如下；这些文件仅移出共同纯值/增加 import，
未改认证或网络执行逻辑：

| 原文件 | 共同值 |
| --- | --- |
| `Cloud/Types/CloudTypes.swift` | `CloudAccountState`, `CloudAuthorization`, `CloudLinkedSession`, `CloudWorkspaceSummary`, `CloudServiceConfigurationMode`, `CloudSettings` |
| `Cloud/Sync/Contracts/CloudSyncTypes.swift` | `SyncEntityType/Action`, Card/Deck/WorkspaceSchedulerSettings/ReviewEvent/MediaAsset sync payload，必要 operation/bootstrap/change/persisted-outbox 值与 legacy deck 编码辅助；不用的 network response DTO 留在原文件 |
| `Cloud/Notebook/LingroveNotebookReviewWire.swift` | `LingroveNotebookReviewRequest/Response/Undo` 及嵌套纯 codec 值，位于 engine `Review/Sync`，避免 NotebookSync 反向依赖 engine |
| `Cloud/Notebook/Media/LingroveNotebookMediaTypes.swift` | 持久化 job/state/direction/error 和 binding 校验 descriptor |
| `Cloud/Notebook/LingroveNotebookHTTPTransport.swift` | `LingroveNotebookNetworkError`；transport 仅新增 engine import |
| `Cloud/Sync/Runner/MediaUploads/MediaUploadTransferSupport.swift` | 原确定性的 `mediaUploadWorkspaceReplicaId`；上传执行保持原位 |

`CloudLinkedSession` 的 bearer/guest 值为原有内存契约；storage 只读取身份/endpoint/kind，
不保存凭据、不刷新或发送请求。日志接入通过 `NotebookStorageDiagnostic` callback 留给移动宿主，
原生 SQLite handle 不因公共提取而暴露给 production consumers。

## 实际验证

证据根目录（本工作树，保留于 gitignored `build/`）：
`/Users/shadow/.codex/worktrees/mac-wave1-notebook-core/lingrove/build/mac-w1-a/`。
所有 Swift/Xcode/Simulator 命令均由 Python `fcntl.flock(LOCK_EX)` 持有
`/tmp/lingrove-mobile-validation.lock`；Swift scratch、Xcode DerivedData 与复制的固定包输入
均在本树 build 下。没有写共享固定 package cache，没有打开可见 Simulator。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| Mac SwiftPM build + 实际 package tests | 40 XCTest + 33 Swift Testing = **73 passed**，0 failed；含 12 个既有 FSRS tests 与 exact vector bytes | `package-tests-final.log` |
| 移动宿主 `build-for-testing` | `TEST BUILD SUCCEEDED`；最终包含 LocalFull、公共 product、原生 tests 与新增 IO ABA test | `mobile-build-for-testing-final.log` |
| 指定手机签名构建 | ad hoc simulator `build-for-testing` exit 0 | `native/signed-build-for-testing.log` |
| 指定手机真实 `test-without-building` | 9 suites，xcresult 顶层 **60 passed / 0 failed / 0 skipped**；设备行另计 65 dynamic parameter instances | `native/result-summary.log`, `native/result.xcresult` |
| 新进程自动化标识 | fresh PID **9073**，`2026-11-03 00:31:50.901940+0800`，`isAutomation=true` | `native/fresh-markers.json`, `native/automation-markers.json` |
| 设备/安装/数据恢复 | 指定 UDID，app/runner 原本均未安装，验证后已卸载；Shutdown→Shutdown；source 指纹不变 | `native/restoration.json`, `native/installation-before.json`, `native/source-inputs.json` |
| FSRS 提取静态核对 | 38 个函数 body/signature 忽略 public 后与固定基线逐字相等；fixture SHA-256 `88b167b27462f6f8897932ca33297ad559f061f598ce04b72a18ee49a32ba6da` | `fsrs-extraction-proof.json` |
| 工程/source 边界 | PBX 无重复 object IDs；无分配前缀之外的改动；`git diff --check` 通过 | final audit / 本提交 |

9 个实际 native suites：`DatabaseCoreTransactionIntegrationTests`、`FsrsSchedulerParityTests`、
`LingroveNotebookLocalScopeIntegrationTests`、`LingroveNotebookAccountPreflightIntegrationTests`、
`LingroveNotebookReviewCompletionTests`、`LingroveNotebookCardLinkIntegrationTests`、
`LingroveNotebookDatabaseLifetimeIntegrationTests`、`LingroveNotebookMobileReviewIntegrationTests`、
`LingroveNotebookReviewEnrollmentIntegrationTests`。

使用契约指定的专用 `4F71C81A-36CD-4BE6-BCAE-8F60B05F86D7`，名称
`Lingrove Ordinary iPhone Acceptance`（xcresult model metadata 为 iPhone 18 Pro）。没有操作
用户 17 Pro `7ECD…`、Duo `8367…`、iPad 或运行中的 Mac Lingrove/Dev。未跑 UI/E2E 矩阵。
原生日志出现一次 StoreKit `noAccount` 环境提示，xcresult `testFailures=[]`，不构成测试失败。

## 发现、修正与未验证

1. 初始编译暴露被隐含导入的纯依赖、公开值 initializer/Sendable 和工程 ID 冲突；已收敛到
   实际存储依赖并修正。失败日志保留在 `package-build-*.log` / `package-tests-*.log` 与早期
   `mobile-build-for-testing-*.log`，最终执行结果以上表为准。
2. 部分旧测试要求 source merge/tag refresh 后整个 Card/全部 link journal 字节不变；固定
   基线已自动刷新材料，独立只读审查确认这不是提取回归。测试改为保护完整 FSRS/immutable
   event/enrollment/provenance 进度，并另断言生成材料确实跟随；失败原子性测试仍比较全表。
3. 新的真实边界检查发现独立媒体根尚未建立、borrowed facade 会关闭宿主 Core；已修正，
   关闭重开/借入寿命/独立目录检查通过。raw handle 保持 internal。
4. 原有三方手改比较使用 Swift canonical String equality，会把 NFC/NFD 字节不同的手改
   当作原生成字段。改用 UTF-8 literal ownership comparison（tags 同理），真实 SQLite 保存
   后 source refresh 保留手改的检查通过；FSRS 与 wire 规则未改变。
5. scoped 参与命令在幂等 replay 前验证原 generation；移动 IO 透传同一快照，实际 ABA 检查
   通过。无新增云传输、遥测、官方账户请求或生产门控变化。

没有未解决的编译/执行/产品数据失败。未验证：A/B ports 联合 runner、第二波 Mac UI/CLI
接线、真实 Apple/Google/provider、真实服务端/PG 和双设备最终旅程；这些不由本次单包
存储提取的本地执行结果代替。两位辅助者分别只读审查、执行由负责人编写的验证脚本，
未写实现/测试/脚本，也未下派。

## 环境清理与提交记录

最终清理记录见 `build/mac-w1-a/cleanup.json`：已确认 `build/DerivedData`、SwiftPM scratch
`build/notebook-engine`、本树复制输入 `build/mac-w1-a-source-packages` 均已移除；原共享
`/Users/shadow/lingrove/build/nibomo-validation/source-packages` 保持原位。日志、xcresult、
manifest、验证脚本和恢复证据保留；没有后台 server、Docker 项目、可见模拟器、部署、push
或 main/兄弟分支合并。

实现提交：`945d43c715f2bda1012c8e203c71bc34db2bd74a`（`Extract shared notebook storage and built-in review engine`）。
本文档收尾提交只补充提交号/已完成清理，不修改已验证实现。工作树以此报告为交付入口；
共享总计划/SOURCE_LAYOUT/AGENTS 和 A/B 接线由主智能体集成。
