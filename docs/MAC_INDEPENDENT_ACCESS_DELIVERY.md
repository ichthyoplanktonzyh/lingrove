# Mac 独立账户接入交付

2026-11-02。本报告只覆盖原生 Mac 账户基线，不表示 Mac 语料同步、归属采用或内置复习完成。

## 分支、基线与提交

- 工作树：`/Users/shadow/.codex/worktrees/mac-independent-access/lingrove`
- 分支：`codex/mac-independent-access`
- 固定共享依赖基线：`b608e34ae5049a1336679162f4228ffbd67bd737`
- 范围文档提交：`532216ec`、`d4b0b3e1`，准确契约见 [MAC_INDEPENDENT_ACCESS.md](MAC_INDEPENDENT_ACCESS.md)。
- 实现与测试提交：`74b10c3900c8d3c83a70ad7041b165298bf9fd77`。
- 本报告由后续独立文档提交补入；不 rebase、合并、push 或部署。

实现未修改 `Nibomo/`、`Packages/`、后端、数据库 schema、移动端、补全/OCR/推理算法、
根 `AGENTS.md` 或移动交付报告。`project.yml` 保持原样，新增源文件由现有 XcodeGen 发现，
已提交生成的工程引用。

## 已交付的行为

- 现有原生 Settings 增加 Account 入口及两个搜索目的地，沿用 sidebar、Form 和 row anchor。
  显示未配置、未登录、请求/确认/恢复/刷新中、待验证码、已登录、待恢复与凭据失效。
- 明确配置 API/auth base URL；API 的 `/v1` 或其他 stage 路径由使用者填写。允许 HTTPS，
  合成/本地服务可用 loopback HTTP。拒绝 URL 用户名/密码、query、fragment、路径穿越及公共 HTTP。
  保存配置不会发网络请求；没有官方服务默认值，也没有 cloud guest 创建路径。
- 按固定基线的 `/api/send-code`、`/api/verify-code`、`/api/refresh-token` 原生 wire 协议处理邮箱 OTP。
  CSRF 与签名 OTP session 放在请求体，不依赖浏览器 cookie。错误码、重发、取消、过期、
  消耗过的挑战、错误验证码、限流及网络重试有确定状态。没有 Apple/Google 假入口。
- 使用 authenticated `GET /me` 的 `userId` 确认身份。不会把 JWT subject 当产品 account ID，
  不会仅凭 token 解析发布已登录。忽略 workspace/preferences 等额外字段，不采用到本地语料。
- OTP 换取的凭据可先作为“尚未确认身份”的私有待恢复记录保存；若 `/me` 离线，使用者可重试，
  不必反复使用已消耗的验证码，也不会被显示为已登录。
- 生产凭据只进 Mac 私有 Keychain。bundle、命名空间与规范化 API/auth pair 共同隔离 Dev、正式
  和合成测试；不使用 shared access group、不启用同步，也没有明文文件/UserDefaults 回退。
- 启动仅恢复先前明确允许的保存会话，随后再次访问 `/me`。临近到期/服务端拒绝旧 ID token 时刷新；
  恢复和刷新共享单个在途任务，rotation 先保存，再继续身份检查。网络失败保留待恢复记录，
  失效或身份变更会关闭恢复并清凭据。
- 取消、退出、服务切换和 shutdown 推进 generation，并取消在途工作。迟到的 send/verify、
  `/me` 或 refresh 不能重新激活身份或写回旧会话。单个消费者取消也不会取消其他消费者的刷新。
- 本机退出先关闭非秘密的 restore gate，再清 Keychain。清除失败有可重试的状态；切服务/移除连接
  时若旧 scope 清除失败，会保留旧配置供重试，不会遗留一个无法再寻址的旧 scope。
- 退出沿用现有 iOS 的 local-signout 语义，没有账户删除或全设备撤销调用/承诺。
  登录只表示身份确认，页面明确说明没有接通账户同步。

账户状态没有成为补全、翻译、阅读、生词本或 CLI 的前置条件。AppDelegate 启动账户恢复不等待网络，
错误封闭在账户状态内；本轮未对这些既有本地功能作算法或存储改动。

## 文件边界、所有权与后续 SDK 替换点

| 边界 | 责任与数据流 |
| --- | --- |
| `Models/Account/AccountModels.swift` | 配置、私有凭据/OTP 值、可信身份和安全 UI 状态；不会携带 notebook owner/workspace 采用行为。 |
| `Models/Account/AccountContracts.swift` | `AccountAuthenticating` 与 `AccountCredentialStoring` 是未来公共账户 SDK 的窄替换点。 |
| `Support/Account/AccountConfigurationPolicy.swift` | 对输入和恢复配置使用相同的 URL 验证/规范化及 scope hash。 |
| `Support/Account/AccountOTPExpiryPolicy.swift` | 读取固定 OTP envelope 的时间提示，只能缩短本地期限；不验证身份。服务端仍验证签名、CSRF、code 和过期。 |
| `Support/Account/AccountPresentation.swift` | 把封闭状态/错误类别映射为固定文案，不显示原始服务端正文。 |
| `Services/Account/AccountAPIClient.swift` | 复用现有 wire 协议的 Mac adapter；ephemeral URLSession 禁止 cookie/redirect，逐步接收时封顶 512 KiB 并取消超限请求。 |
| `Services/Account/AccountConfigurationStore.swift` | UserDefaults 只存 URL 与 restore gate，不存任何 token。 |
| `Services/Account/KeychainAccountCredentialStore.swift` | Mac login Keychain 的当前应用 ACL、禁止交互的 `LAContext`、带 scope 的保存/读取/清除。 |
| `Services/Account/AccountSessionService.swift` | 唯一长期状态/任务 owner，控制 OTP、可信身份、恢复、rotation、generation 与定时器。 |
| `UI/Settings/Panes/AccountPaneView.swift` | 只保留表单草稿、观察服务并发起操作，不创建 transport、Keychain 或刷新 owner。 |
| `Resources/Account.xcstrings` | 独立账户文案，45 条源 key、现有全部 15 个 Mac 界面语言。 |

`LingroveAppEnvironment` 只创建一个账户服务，`AppDelegate` 负责 start/resume/shutdown，
`SettingsCoordinator → SettingsContainerView → AccountPaneView` 传递同一个引用。窗口关闭/重开只重建
presentation，不重建认证服务。完整职责与教学说明已加入 [SOURCE_LAYOUT.md](../SOURCE_LAYOUT.md)。

固定移动 `CloudAuthService` 依赖 Flashcards 日志、错误/本地化与数据库派生类型；本轮采用窄 wire
adapter，没有复制 `FlashcardsStore` 或 `CloudSessionRuntime`。将来统一 SDK 可替换两个 protocol 的实现，
保留 app owner、状态/身份接口和本机退出围栏。Apple/Google provider SDK、应用登记及真实验收留待该阶段。

### Keychain 的明确取舍

试验性的 data-protection entitlement 会要求当前 Dev bundle 尚无的 Mac provisioning profile，
该 entitlement 与相应 project 设置均未提交。现有非沙盒宿主使用 login Keychain 的应用 ACL，
`SecAccessCreate` 只信任当前 executable 的代码要求，读取不弹授权，未失败回退到别的存储。
依据为 Apple 的 [ACL 说明](https://developer.apple.com/documentation/security/access-control-lists) 与
[`kSecAttrAccess`](https://developer.apple.com/documentation/security/ksecattraccess)。

`SecTrustedApplicationCreateFromPath` 和 `SecAccessCreate` 各有一条平台弃用警告；实际签名 Keychain
检查通过。这是后续 SDK/签名能力对齐时应替换的独立边界。Security 也输出了同步 Keychain 调用的
main-thread performance advisory；本轮没有做性能测量或作延迟保证。同步保存/清除使 generation 检查与
本机持久化之间没有 suspension，若后续迁出 UI actor，必须继续保证串行写入/退出清除顺序。

## 实际验证与证据

环境：Apple Silicon，macOS `26.6.2 (25G83)`，Xcode `27.1 (27A9275)`，Apple Swift `6.4`。
沿用开发者本地签名配置，没有自动申请 profile、修改系统授权或安装/终止使用者的 Lingrove/Dev。
全部 Xcode、原生 helper 编译、签名与 Apple 工具操作都由 Python `fcntl.flock(LOCK_EX)` 持有
`/tmp/lingrove-mobile-validation.lock`，无 Simulator/手机操作。

证据根目录：
`/Users/shadow/.codex/worktrees/mac-independent-access/lingrove/build/mac-account-validation/`

主要结果的绝对路径：

- `/Users/shadow/.codex/worktrees/mac-independent-access/lingrove/build/mac-account-validation/dev-build-verified.xcresult`
- `/Users/shadow/.codex/worktrees/mac-independent-access/lingrove/build/mac-account-validation/account-protocol-verified.xcresult`
- `/Users/shadow/.codex/worktrees/mac-independent-access/lingrove/build/mac-account-validation/account-tests-r2.xcresult`

| 检查 | 实际结果 | 证据文件（相对于证据根目录） |
| --- | --- | --- |
| 固定依赖及 native helper 准备 | 通过；参考源复制到本树，由准备脚本校验 pinned revision/patch 后构建 | `dependency-provenance.json`、`prepare.log` |
| 现有 `Lingrove Dev` Debug 构建 | 通过；最终 binary 时间戳/哈希已记录 | `dev-build-verified.log`、`dev-build-verified.xcresult`、`compiled-account-resources.json` |
| Dev 完整签名校验 | `codesign --verify --deep --strict` 通过 | `dev-codesign-verify.log`、`dev-codesign-verify-exit.txt` |
| app-hosted build-for-testing | 通过；这是编译结果，与下方执行结果分开 | `account-build-for-testing-verified.log`、对应 `.xcresult` |
| 配置/OTP 期限规则 | 2 项通过 | `account-protocol-verified.log`、对应 `.xcresult` |
| 真实 URLSession/loopback 协议 | 1 项通过，含原生 body、`/me`、错误类别、307 拒绝、未知长度 2 MiB 响应封顶 | 同上 |
| 真实私有 synthetic Keychain | 1 项通过；保存/读回、不同 bundle/config 隔离、实例重开/恢复、rotation/无 rotation、离线恢复、退出后读回 nil | 同上 |
| 会话及竞态 | 8 项通过；单飞、消费者取消、迟到 verify/identity/refresh、退出、服务切换清除失败、网络与失效分离 | `account-tests-r2.log`、`account-tests-r2.xcresult` |
| 原生账户表单 | 1 项通过；真实 NSHostingView/NSPanel 关闭重建、同一服务引用与 5 个状态 PNG | `account-tests-r2.log`、`renders/account-*.png` |
| Settings 搜索/导航 | 14 项通过 | `account-tests-r2.log`、对应 `.xcresult` |
| 改动的 16 个 production Swift 文件严格 lint | 通过 | `changed-swift-lint.log`、`changed-swift-lint-exit.txt` |
| 本地化与可重复工程生成 | 45 个 compiler-extracted key 无缺失/多余；15 个编译语言资源逐项匹配；XcodeGen 再生成不变 | `compiled-account-resources.json`、`xcodegen-final.log`、`cleanup.json` |
| 独立只读审查 | 首轮三项发现已修正；新的最终审查未发现可复现实质问题 | `independent-review.md` |

共 **27 个不同定向检查通过**，这是相应运行结果的并集，不宣称有一次完整组合运行全部绿色。
最后受影响的 protocol/Keychain/policy 运行实际执行 4 项并以 exit 0 结束；其余未改动的通过项目没有重复跑。
具体命令、source fingerprints 与汇总见 `*-command.txt`、`validation-summary.json`。

### 已修复失败与未执行项

- 首轮产品/测试编译中的 getter 返回值和测试宏 `try` 位置错误均已修复，最终构建通过。
- 初次测试加载被 ad-hoc test bundle 与签名宿主的 Team ID 不一致拒绝，执行了 0 项。
  第一次签名修正还缺 SwiftPM resource bundle 的 team；第二次按本地同一 team 签名后宿主正常执行。
  未改产品 entitlement、hardened runtime 或系统授权。
- 首次组合运行在 Keychain 测试末尾把 UserDefaults 的 `Data` 当 JSON 对象序列化，导致 test host
  Objective-C 异常退出。已改为直接检查该记录文本，修正后的完整 Keychain 场景执行通过。
  原失败保留在 `account-tests-r2.xcresult`、`test-keychain-crash.ips`；该组合运行整体结果仍记为失败。
- PNG 已人工查看验证码和已登录页，布局无截断。它们是合成原生表单渲染，**没有**实际在全量
  Settings 窗口用鼠标/键盘操作完整登录，也没有手工跑既有补全/翻译/阅读/CLI 真实用户旅程。
- **未执行**真实 Cognito、真实验证码邮箱、Apple/Google provider、真实应用登记、跨实际进程的
  全量 app 冷启动交互、非英语/RTL 的人工视觉验收或旧 macOS 实机检查。合成服务不代表这些通过。
- 未运行模型 eval、性能研究、手机/iPad/Duo 测试；未接通 notebook 同步、归属采用或 review。

## 环境与缓存清理

`cleanup.json` 已确认本树 `build/DerivedData` 不存在；本树准备的 inference/native dependency caches
（`tts-native`、`ocr-native`、`dictionary-native`、`lingrove-dependencies`）也已清除。证据目录单独保留。
崩溃留下的一个本模块 Python fixture 进程已按精确脚本路径识别并终止，剩余数为 0；相应 synthetic
偏好域已清理。成功测试在退出后验证 Keychain 读回 nil，未枚举或清理真实账户条目。

gitignored 的 worktree-local `Config/Signing.local.xcconfig` 保留供本树以后构建，未打印内容或提交。
未写主树 cache、未 symlink DerivedData、未改使用者真实设置/账户 Keychain 条目、未捕获用户输入或私人屏幕。

## 主线程集成建议

1. 在第三波最终 checkpoint 上审查并整合本实现提交及本报告提交；本分支没有追随进行中的共享变更。
2. 若生成工程文件与主线程新增文件冲突，以主线程最终 `project.yml` 为准重新运行 XcodeGen，
   保留 Account 源/测试/catalog 引用。本轮没有 target、scheme 或 package dependency 改动。
3. 集成后优先重新编译 `Lingrove Dev`，必要时复用本报告的少量账户检查。签名测试使用宿主与 test
   bundle 相同开发团队；不要用全局权限放宽来处理测试加载问题。所有 Apple 操作继续用共享锁。
4. 后续公共 SDK/provider 工作从两个 Account protocol 和 app-owned service 接口对齐；继续保持
   可信身份与语料归属/同步分离，不能把本次账户完成描述为完整 Mac 同步或复习完成。
