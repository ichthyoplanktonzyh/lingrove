# Mac 第二波 D：账户、归属与同步生命周期交付

2026-11-03。本模块从固定基线 `615e2164d1d782ecf521e8edd713e64dbd07f7fa` 开发，
工作树 `/Users/shadow/.codex/worktrees/mac-wave2-account-sync/lingrove`，分支
`codex/mac-wave2-account-sync`。实现提交：
`d925989188e853befa4efbcd0f5a20f25a006b69`。本记录另作交付提交。
没有切换/合并 main、跟随动态 main、修改兄弟工作树、push 或部署。

## 完成的边界与数据流

D 接受父层唯一的 `MacNotebookRepository` 与 `AccountSessionService` 引用。
账户确认、workspace 选择、本地材料归属决定、同步许可是四个不同状态：

1. 邮箱 OTP 和私有 Keychain 继续由原账户服务及共享 SDK 管理。只有可信 `/me.userId`
   确定业务 owner；不解析 JWT subject，不接受手填 owner/workspace。
2. 登录可读取该授权下的 `/me` 与分页 `/workspaces`。服务器的 selected workspace
   只作 metadata；新账户不会因此选择本地库、接纳材料或上传。
3. 用户明确连接实际 metadata 中的 workspace。首次激活前读取服务端真实 FSRS 设置；
   新 shell 直接以这些值及其时钟初始化，已有 shell 复用原 LWW applier。
4. 引擎提出本地语料的 retain/accept。保留不复制；接纳经原 ownership 事务复制已保存
   材料、PNG 和已有内置复习参与/历史，不为未选入的收藏创建新参与。保留后的来源可
   再明确接纳；原来源及旧账户库均保留。已有 Anki 工具和私有状态仍独立。
5. 用户再启用同步，才让共享 `NotebookSyncCoordinator` 使用同一 `cloudStorage` 的
   corpus/media/review 三组 ports。D 没有复制 SQL 同步算法、第二数据库或 Card 历史。

退出、换服务、换账户、换 workspace、取消和 shutdown 同时撤销相应任务/票据；需退休
持久 scope 时以 expected generation CAS 旋转现有 token。旧语料、评分、journal 和远端
cursor 不被删除；旧 callback、UI 选择和旧 generation 无权写入新 scope。
退出切到 fresh local workspace，旧账户内容不可见，再以同一可信账户选择原 workspace
时可恢复。会话失败不抛到应用启动链，补全、翻译、阅读及现有本地材料操作可继续。

## 文件为什么分开

| 文件/类型 | 责任、归属和协作 |
| --- | --- |
| `Services/Notebook/MacNotebookSyncController.swift` | App graph 长期持有一次的 MainActor orchestration。订阅账户及仓储变化，持有 metadata/selection/sync/retry 任务及一个 media registry，输出安全的独立状态；窗口只借用。网络和 SQL 真相仍由公共模块拥有。 |
| `Models/Account/MacNotebookSyncModels.swift` | 安全账户观察值、lane 状态和非秘密许可值。owner 用 literal UTF-8 Data 匹配；状态不承载 token 或 SQL handle。 |
| `Services/Account/MacNotebookSyncConsentStore.swift` | 按 API endpoint + 可信 owner 保存明确 workspace/sync 许可的 UserDefaults adapter。它只保存许可，不镜像 notebook 内容，损坏值关闭准入。 |
| `Services/Account/AccountSessionService.swift` | 原 Combine facade 增加完整赋值后才发送的观察 stream，避免 `@Published` willSet 时读取旧字段。共享 SDK 仍是唯一凭据/刷新 owner。 |
| `LingroveCloud/Account/AccountSession.swift` | 等待 shared recovery 的调用者及 authorization 本身再次检查原 session generation、identity 和 configuration，不能拼旧 identity 与新 token。离线保留身份仅用于既有本地可见 scope，不授权请求。 |
| `LingroveCloud/Account/AccountWorkspaceClient.swift` / `AccountWorkspaceModels.swift` | Foundation-only、bounded、redirect-fenced 的 metadata transport 和短生命周期 wire 值。只读已有 bootstrap 的 rank-zero scheduler entry（`limit: 1`），不下载 generic Card/Deck。 |
| `LingroveNotebookEngine/Commands/LingroveNotebookEngine+MacAccountLifecycle.swift` | 同一主连接的短事务 seam：generation CAS、目标 installation 查询、新 shell 初始化/归属绑定、既有 LWW settings apply、真实 first-connection 读取。网络 await 期间不持事务。 |
| `Support/Account/MacNotebookSyncPresentation.swift` | 纯状态文案和有界的人类文本冲突预览，不把 SQL/UUID/原始 JSON 当普通设置界面。 |
| `UI/Settings/Components/AccountNotebookSyncSection.swift` / `AccountPaneView.swift` | 原生 workspace、本地 retain/accept、opt-in、lane 状态、Retry/Cancel。界面保留实际显示的 proposal/connection snapshot，旧选择不会借最新属性偷换归属。窗口不启停服务。 |
| `Resources/NotebookSync.xcstrings` | 新增 40 个 source keys，原有 15 个 Mac locales 完整翻译；没有扩大语言集合或调用翻译服务。 |

App 的旧账户表单、保存连接草稿准入仍保留：可见 API/auth 草稿不等于真实保存连接时，
发送/验证 OTP 继续被阻止。`AccountPaneView(account:)` 仍可编译，新增的可选
`syncController` 默认 nil（Swift memberwise optional default）。

## 生命周期与 public hooks：父层必须接线的部分

```swift
let sync = MacNotebookSyncController(repository: repository, account: accountSession)

// AppDelegate 启动，不能放到窗口 onAppear：
accountSession.start()
sync.start()

// 经 SettingsCoordinator / SettingsContainer 传同一引用：
AccountPaneView(account: accountSession, syncController: sync)

// App 退出，不能放到窗口 onDisappear，顺序要保留：
sync.shutdown()
accountSession.shutdown()
try repository.shutdown()
```

`start()` / `shutdown()` 是同步入口；长网络任务由 controller 自己持有。父层保留根 graph
owner，不让 Settings、CLI 或复习窗口另造仓储、session 或 media registry。主库打开失败
时不构造 controller；父层继续提供账户表单/补全/翻译并展示语料不可用，不用第二库兜底。

界面命令包括 `refreshWorkspaces()`、`chooseWorkspace(_:)`、
`resolveLocalCorpus(accept:choices:expected:)`、`resolveFirstConnection(combine:expected:)`、
`setSynchronizationEnabled(_:)`、`retry()`、`cancel()`。UI 必传它显示的 expected snapshot。
`cancel()` 同时关闭持久 opt-in，重开窗口或重启不会自行恢复用户取消的同步。

提交后调用 `repository.publishChange()`，C/E 可重新读取 snapshot/revision/generation。
本地变化经短 debounce 合并；已许可的后台同步有 30 秒轮询、明确 Retry 和 SDK 单次刷新。
离线 session 恢复后会继续已有许可，选择 workspace 期间不会重启旧 scope 的同步。
corpus、PNG、review 和 scheduler 分别报告；corpus 成功不代表 review endpoint 可用。

本树只提交自己生成的 `Lingrove.xcodeproj` 新引用，没有编辑父层独占的 AppEnvironment、
AppDelegate、SettingsCoordinator/Container、全局菜单/命令、根 project.yml 或 SOURCE_LAYOUT。
父层合并 C/D/E 后统一 XcodeGen，并把上述引用沿实际设置链传递。

## 必要的 macos 服务合同增强

原 legacy scheduler bootstrap 的 platform 和 installation/replica CHECK 只接受旧三平台；
notebook connect 还硬编码 iOS。root 已明确授权本模块补最小兼容，独占新增 0247：

- `sync/contracts/input.ts`、`sync/identity/replica.ts` 接受真实 `macos`；
  `0247_native_macos_sync_platform.sql` 只扩展两个现有 CHECK，不改变 owner/RLS。
- `NotebookAccount.nativePlatform = .macos` 通过原有 `X-Client-Platform` header 传递，
  也参与 coordinator 同一 flight 的身份比较。没有改变 corpus body 或 protocol version。
- backend notebook connect 在明确 macos header 下复用同一 Mac installation/replica；
  未声明平台的既有调用继续原 iOS 行为，未知 header 拒绝，Mac guest 明确拒绝。
- 没有新 provider、guest 创建、默认 Nibomo 请求、客户端遥测、生产门控或部署产物。

这些改动位于原 shared NotebookValues/HTTPTransport、backend notebook route、sync input/
identity/guest guard，以及显式 opt-in 的 PostgreSQL boundary `249-macos-bootstrap`。
不是迁移旧开发数据，不顺带修改 billing/community/analytics。

## 实际验证与证据

证据根：
`/Users/shadow/.codex/worktrees/mac-wave2-account-sync/lingrove/build/mac-w2-d/`。
所有 Swift/Xcode/native 执行均持 Python `fcntl.flock(LOCK_EX)` 共享锁
`/tmp/lingrove-mobile-validation.lock` 到证据落盘；没有 Simulator、真实账户/邮箱、用户应用、
私人输入或系统权限操作。签名使用已有 task-local team，不降低签名或 concurrency 设置。

| 实际检查 | 结果 | 证据 |
| --- | --- | --- |
| 账户/OTP/Keychain/连接草稿及新增 authorization 竞态 | **16 passed**；在初次 21-test 执行中独立通过；包括真实私有测试 Keychain/HTTP 和关闭重开表单 | `native-tests-initial.log/.xcresult` |
| 最终 Mac 同步/作用域/原生设置 | **8 passed / 0 failed**：7 条真实 SQLite/URLSession 旅程 + 1 条真实 AppKit/SwiftUI 渲染 | `delivery-native-tests.log/.xcresult` |
| shared Cloud HTTP/ports/平台 single-flight | **13 passed / 0 failed** | `swift-cloud-final.log` |
| Node 24 TypeScript `tsc --noEmit` | 通过，没有生成 AWS/dist 产物 | `backend-tsc-final.log` |
| 实际本地 Postgres / runtime-role / RLS / HTTP | **1 passed / 0 failed**；249 迁移边界、macos bootstrap + 同 installation/replica connect + window open、旧三平台兼容、越界/未授权/未知平台/guest 拒绝 | `postgres.log/.receipt.json` |
| 原生完整 test host build-for-testing | 通过；这一步只算编译，不冒充执行 | `delivery-build.log/.xcresult` |
| 最终 binary 签名 | `codesign --verify --deep --strict` 通过 | `delivery-codesign.log` |
| 本次主体生产文件 strict lint | **12 files passed**；只追加 header 的旧 HTTPTransport 保留原 lint 基线，未顺带重排 | `delivery-lint.log`、`lint-inputs.txt` |
| 文案完整性 | 40 keys × 15 locales；JSON/translated units 完整 | `localization-proof.json` |
| whitespace | 最终相对固定基线检查通过 | `git diff --check` |

7 条 Mac 流程实际覆盖：登录不自动选库/上传；retain 后明确 accept；原来源、PNG、1 条已选入
练习与评分保留；收藏不创建参与；corpus 成功/review unavailable 独立呈现及恢复；401
经 SDK refresh；断网重试；真实远端 FSRS 0.87→0.93 写入同 engine 并在重建 graph/重开
SQLite 后保留；Cancel 的许可退休；两个账户隔离；实际延迟 HTTP callback 无权写新 scope；
换 workspace 的旧 first-connection 和旧 UI proposal 拒绝；选择中认证离线不会卡住；刷新
成功不会重启旧 workspace flight；凭据失效清空旧控件且保留旧账户持久内容。

`render/notebook-sync-{workspace,ownership,reopened,lanes}.png` 来自 disposable test host
离屏渲染，已查看实际图像。它证明组件布局及独立 lane 文案，不等于完整鼠标键盘账户旅程。
`delivery-inputs.json` 记录最终 binary hash 和 1320 个 Swift 输入；
`delivery-proof.json` / `delivery-runtime-inputs.json` 保存合成环境与实际执行摘要。
执行后仅删测试文件 EOF 多余空行，非空白字节未变，差异见 `post-validation-format.json`；
没有因此重跑未改变的业务套件。

## 初始失败、审查与未验证范围

- 初始 native 编译遇到 actor-isolated default argument、拆包后的显式 import 和 fixture
  使用不存在的 Kind；分别改为 MainActor init 内构造、明确 import、实际 `.expression`。
  原日志 `native-build-initial/r2/r3` 与最终成功分开保留。
- 首次 PG fixture 将 JSONB 学习步骤写成 SQL 数组，修正 fixture 后通过；未降低 schema。
  见 `initial-postgres.log`、最终 `postgres.log`。
- 初始 workspace-choice fixture 声称 initialized 却未给 notebookSettings 根记录。
  实际状态为 unavailable、first-connection SQL 0 行；补正确 canonical fixture 后通过。
  没有把它当产品导航错误。单方法 Swift Testing filter 曾执行 0 tests，明确不算通过；
  后续用整 suite 实际执行，最终 8 项均通过。
- 两轮 Luna/max 只读审查没有写实现/测试。指出的旧 workspace prompt、离线 selection
  清理、凭据失效控件残留均修正；进一步对成功 refresh 期间旧 flight 和旧 UI snapshot
  采用补了定向回归。文案 helper 只写它负责的 catalog，没有调用翻译服务。
- 没有验证真实 Cognito/邮箱/Apple/Google、真实 object store、生产部署/0247 上线、真正
  Mac+手机双设备界面接续或完整 Mac 键鼠登录。Mac 合成 HTTP 是轻量协议 peer；PG 检查
  使用生产 route/runtime role/RLS，但身份 loader 是合成的，不能冒充真实 JWT provider。
- 共享同步/PNG/评分/撤销算法继续复用第一波已验证实现；没有为 D 重建另一套 FSRS、
  Card/history 或大型 E2E 框架。父层应用/设置接线与 C/E 组合验证仍由 root 完成。

## 清理

`cleanup.json` 已核对移除本树 `build/DerivedData`、Swift scratch、私有 source-package
复制件、prepared inference/TTS/OCR/dictionary 构建目录；没有移到全局 DerivedData。
临时 backend node_modules 只读链接已移除，D compose/network 已 down，19480–19482
无监听/可绑定，自己的 test host 已退出，合成 fixture 目录无残留。保留本树小型证据目录
与已提供的私有签名/validation config；没有停止他人的应用、进程或容器。
