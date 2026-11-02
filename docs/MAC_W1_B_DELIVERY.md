# Mac 第一波 B：共享账户与网络同步核心交付

2026-11-03。本报告覆盖第一波 B 的独立可导入模块与宿主薄适配；不代表 Mac 账户采用、
全量语料同步生命周期或桌面内置复习已经接入，也不把合成 HTTP 当作真实云/双设备验收。

## 分支、基线与提交

- 工作树：`/Users/shadow/.codex/worktrees/mac-wave1-cloud-core/lingrove`
- 分支：`codex/mac-wave1-cloud-core`
- 固定基线：`9351fd93b697a145ded9ded6bb008420b864b5d8`
- 实现、测试、Mac 工程接线及模块 README：`9f200a2c1266f2aa65f7b6bf0e22457122f8e3c4`
- 本报告由后续独立文档提交补入；没有 merge main/兄弟分支、push 或部署。

## 已完成的模块与边界

新增 `Packages/LingroveCloud`，产品/模块均为 `LingroveCloud`，支持 macOS 14 与 iOS 18。
只依赖 Foundation 系统能力与既有 `LingroveNotebook`、`LingroveNotebookSync`；无 UI、
SQLite、FSRS、Card store、FlashcardsStore、默认服务或 guest 创建。完整职责/端口义务见
[包 README](../Packages/LingroveCloud/README.md)。源自原生 Mac 账户与 Nibomo 网络实现，
沿用根 AGPL-3.0 并保留 `UPSTREAM-MIT-LICENSE` 原 MIT 声明。

| 文件/类型边界 | 所有权与数据流 |
| --- | --- |
| `Account/AccountModels`、`AccountContracts` | 共享配置、私有凭据、OTP、可信身份、安全状态，以及认证/私有凭据/非秘密 restore gate 注入接口 |
| `AccountConfigurationPolicy`、`AccountOTPExpiryPolicy` | 同一配置规范化/作用域/草稿准入；OTP 时间提示只缩短期限，不认证身份 |
| `AccountAPIClient` | 固定 send-code/verify-code/refresh-token 与 authenticated `/me`；不读取 JWT subject 作为 owner |
| `AccountSession` | 宿主进程长期拥有，唯一 OTP/recovery/refresh 状态机；rotation 先存、单飞、退出/切服务/取消 generation 围栏；`onChange` 给宿主安全状态 |
| `Transport/BoundedHTTPClient` | 不可变 URLSession 边界；无 cookie/cache、逐请求拒绝 redirect、声明与流式解压字节同样封顶 |
| `NotebookValues`、`NotebookStorage` | 既有 NotebookSync scope 与本地 generation 的绑定；冻结上传/状态/重试值；类型化阶段端口；不包含 SQL/journal 真相 |
| `NotebookHTTPTransport` | 原 capabilities/connect/groups/windows/uploads/review 路径、feature header、授权和字节预算 |
| `NotebookNetworkRunner`、`NotebookStagedTransfer` | 一次最多一个 frozen group；media 前置、staged chunk/终态/分页确认、窗口/新 lease、清理债务与迟到响应验证 |
| `NotebookSyncCoordinator` | 显式启动的同账户单飞、report/retry gate 与尝试 epoch；review 结果独立，不回滚已成功 corpus cursor |
| `NotebookReviewNetworkRunner` | 只接 canonical bounded wire Data；最多 16 页；仓储负责 codec、scope/clock、exact ACK 与 cursor 原子提交 |
| `Media/*` | 独立 bounded transport、队列阶段/attempt-CAS/pin ports、每任务取消 registry；无文件目录或 PNG/SQL writer 所有权 |

每个异步存储阶段必须由宿主在自身事务内验证 `NotebookBinding`。网络前后的校验不能
替代事务围栏。owner 用 literal UTF-8 比较；UUID 与 canonical sequence 沿用原包，不造
另一套领域值。共享账户恢复也改用 literal owner 比较来拒绝规范等价但字节不同的身份。

`NotebookPendingUpload` 只投影仓储已经按 baseline/coverage 恢复验证的 batch、exact body、
frozen digest、取消与确认进度。coverage 留在仓储；记录 outcome 不等于清 journal，正向
ACK 只能在覆盖 receipt 的 verified window apply 时退休已发送操作。staged closure 保留
本地意图，先持久化决定再尝试 cleanup。原 direct/staged/window admission 与预算保留。

## 三个存储 ports 与后续桥接

- `NotebookStorage`：installation/capture/validate、initial/state/ownership/sequence/conflict、
  next/existing/control、outcome/confirmation/page/closure record、authorize、window
  begin/receive/discard/references/apply。主仓储继续拥有 shadow/rebase/coverage/原子 apply。
- `NotebookMediaStorage`：enqueue/pin、claim/check attempt、owned PNG、complete/fail/available、
  release/prune/acknowledgeRelease。宿主继续做 PNG/digest 验证和 durable revision-CAS。
  网络等待不持有连接；只有 apply 成功后才 unpin window 消费者。
- `NotebookReviewStorage`：独立 revision、request、apply。request 是宿主已有纯 codec
  编出的 frozen Data（至多 7 MiB）与 afterSequence/hasWork；hasWork 必须包含 history
  adoptions 等所有 held 类型。apply 接原请求和至多 8 MiB 原响应，宿主解码/校验/精确
  ACK 后返回经过验证的 hasMore。包没有复制 `LingroveNotebookReviewWire.swift`。

`AccountSession.generation` 是进程内 UInt64；`NotebookBinding.generation` 是仓储持久化的
String。它们各保护自己的 owner，不能直接强行互换。下一波 D 在账户/工作区切换时
取消共享 coordinator，并推进 A 的 durable generation；每次请求都由可信 `/me` identity
和明确选定的 workspace 构造 `NotebookAccount`。登录不会自动接纳、上传或选择工作区。

显式 Retry 由宿主先捕获已存在的取消/拒绝 revision 及媒体队列重试授权，再调用
`requestRetry(authorization)`；B 不在内存里创造持久化授权。`NotebookMediaTransfers`
应由服务图创建一个实例，runner 与 Cancel 控件借同一个实例。

## 旧入口迁移与工程引用

Mac 的既有 Models/Contracts/Policy/APIClient 名字现在是共享实现 typealias；
`AccountSessionService` 是观察共享 `AccountSession` 的 Combine facade。原
`KeychainAccountCredentialStore` 内容未改，仍本机私有 ACL、无同步/共享组/明文 fallback。
`AccountConfigurationStore` 适配共享非秘密 record/port，仍只保存 URL 与 restore gate。
Mac UI、AppEnvironment/AppDelegate 及连接草稿准入视图未改，先前修好的
`matchesSavedConnection` 规则继续使用相同实现。

移动端 `CloudAuthService` 使用公共 bounded transport，保留成功邮箱提示、native OTP
body 与既有错误映射；Apple/Google providers、social/account-method 流程没有改动。
`LingroveNotebookHTTPTransport` 与 `LingroveNotebookMediaTransport` 变成共享实现的薄
value/error adapter。原移动 runner/SyncIO 仍在宿主，最终接 A 仓储 ports 由主集成者集中
完成，没有搬整个 CloudSessionRuntime 或 FlashcardsStore，也没有重复执行两套同步。

根 `project.yml` 与生成的 `Lingrove.xcodeproj` 已给 prod/Dev app 加入本地包 product。
生成工程的 package build-file IDs 随 dependency 插入重排，未改变其他依赖版本。
按所有权没有编辑移动工程。主集成者需在
`Nibomo/apps/ios/Flashcards/Flashcards Open Source App.xcodeproj` 加本地引用
`../../../../Packages/LingroveCloud` 与相应 app product dependency，合并 A/B 后补完整
移动编译，必要时让测试 target 也显式依赖该 product。

A 所有的原 DTO/错误/纯 codec 保持原字段和定义；B 端口中的 `Notebook*` 值是网络投影，
不是迁移/重定义原 CloudLinkedSession、Card、Deck、ReviewEvent 或持久化类型。主集成者
根据 A 的准确公共清单做机械转换，可收敛别名，不能另造业务规则。

## 端点、权限与一次小修正

没有新增官方地址、自动联网、guest、hosted 数据、真实邮箱/provider 登记或生产门控。
配置为明确的 API/auth pair；HTTPS 或明确 loopback HTTP，拒绝 credential/query/fragment/
encoded traversal base。传输只发送显式授权的认证请求与保存语料 wire，不包含补全、OCR、
未保存翻译、日志或屏幕。401/410 沿用会话恢复出口，review 503 保留独立 lane 状态。

只读审查指出一项继承问题并已在公共与移动 media coordinator 同时修正：全部图片已有
远端 ready mapping 时，无须传输字节，却先探测 media capabilities；探测失败会阻断
corpus-only 编辑。现在只有实际待传任务才探测，实际上传仍走原有完整准入与预算。
新增真实 HTTP 故障场景已通过。另一项关于 Swift if comma 优先级的疑虑由审查者撤回，
未作为产品缺陷统计；条件加括号仅为清晰。

## 实际验证与证据

证据根目录：
`/Users/shadow/.codex/worktrees/mac-wave1-cloud-core/lingrove/build/mac-w1-b-validation/`

所有 Swift/Xcode/XcodeGen/原生编译及 lint 操作都由 Python `fcntl.flock(LOCK_EX)` 持有
`/tmp/lingrove-mobile-validation.lock`。没有操作真实用户应用、手机或可见/运行的 Simulator。

| 检查 | 实际结果 | 证据文件 |
| --- | --- | --- |
| 公共包编译与 HTTP/port 模块执行 | 11 项执行通过，exit 0；URLSession 真实 loopback，非 URLProtocol mock | `package-tests-verified.log`、对应 `-command.json` |
| Mac 全部 9 个 Account 生产文件 typecheck | 通过；原私有 Keychain 仅原有 2 条弃用警告 | `mac-adapter-typecheck.log` |
| Mac facade/服务/规则编译、既有检查执行 | 原样生产 Account 文件与既有会话/配置测试复制到隔离 SwiftPM harness，11 项执行通过；非 app-hosted 全量 UI 测试 | `mac-adapter-tests-verified.log`、`mac-harness-inputs.json` |
| 公共包 iOS SDK 导入/链接 | generic iOS Simulator SDK framework build 通过，未启动设备；非完整移动 app 构建 | `ios-package-import-verified.log`、`.xcresult`、对应 command |
| Mac 工程生成 | XcodeGen 成功 | `xcodegen.log` |
| 9 个 Mac Account 文件 strict lint | 0 violations | `mac-account-lint.log` |
| 范围与 whitespace | diff check 通过；禁止目录/移动工程/门控无改动 | `ownership-audit.json`、`final-source-fingerprints.json` |
| 两位新的 Luna/max 独立只读审查 | account 无实质发现；network 一项修复后复查通过；审查者没有编写代码或运行 Apple 工具 | `independent-review.md` |

11 个公共模块场景实际覆盖：OTP/refresh/可信 `/me`；redirect、声明/未知长度超限；
单飞/消费者取消/rotation 先存/退出；direct exact ACK 保留 later intent；window 页证明
与 media pin 次序；staged chunk/分页确认；staged abort 保留本地意图；意外 ACK 拒绝；
PNG upload/download/release；review 独立失败/恢复及 401；backoff/迟到 generation 与
lifecycle Cancel；ready 图片绕过无须的 capability 探测。review 数据使用冻结的现有
version-one envelope 形状，canonical codec/SQL 的组合验证仍归集成 checkpoint。

初始一次 `swift build` 因提取时遗漏 staged transfer 的 storage 参数而编译失败，已修正；
后续所有模块编译与已执行检查均通过。早期日志保留，不把该初始构建称为成功。
没有测试执行失败、基础设施 timebox 延期或被掩盖的崩溃。

未执行：完整 Lingrove/Dev app build 或 app-hosted UI/真实 Keychain 再验、完整移动宿主
编译、真实云/邮箱/Apple/Google provider、PG/真实 object store、两 SQLite engine 组合、
真实跨设备或桌面旅程。此前 Keychain 的固定基线证据仍有效，本次只编译其未改实现；
不宣称这些未执行项通过。没有因合成验证去改服务器、FSRS、生产门控或系统权限。

## 清理与下一波 owner

`cleanup.json` 确认本树 `build/DerivedData`、两套 SwiftPM scratch、adapter module cache
及临时 harness 均已删除。19180–19182 无监听，合成 fixture 无剩余进程。证据目录保留，
没有读取签名密钥内容或操作主树缓存、用户数据/真实凭据，签名配置仍是 gitignored。

本 B 模块的实现与独立验证完成。主集成 checkpoint 尚需将 A 的单一仓储接三组 ports、
补 mobile project 引用并做实际组合编译/同步验证；随后 D 在同一 AppEnvironment 建立
账户/工作区/明确采用/同步生命周期，C/E 继续使用同一仓储与内置复习。B 不提前建立
Mac 第二数据库或 App 根接线，不把原生账户页面的登录成功描述为已经同步。
