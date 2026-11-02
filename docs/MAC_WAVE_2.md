# Mac 第二波：原生应用的完整接入

本文件为第一波集成后第二波的派发契约。三个独立 managed worktree 从本契约提交后的
同一固定 checkpoint 建立，准确 SHA/负责人/路径由派发记录补充。继承
[总计划](MAC_INTEGRATION_PLAN.md)与[第一波规则](MAC_WAVE_1.md)，不把 API 可编译
称为用户功能完成。第一波真实执行证据与未验证见 `MAC_WAVE_1_INTEGRATION.md`。

## C：桌面语料及内容获取入口

沿用现有生词本桌面 UI、收藏/笔记/分类/语义关系/来源证据、导入导出与 CLI，底层改为
第一波统一仓储和写入规则；写作/阅读翻译的明确收藏接同一入口。未保存内容保持临时，
普通文本检索可用；手机 embedding/语义搜索不因此变成这轮新增工作。保存、取消、
来源删除、合并/恢复、重启、媒体与多窗口冲突在共享事务中得到一致结果。旧 archive/
JSON/私有 schema 不再作为另一份持久真相；没有用户数据，不做旧开发数据迁移。

## D：账户、归属与同步生命周期

沿用已完成的原生账户设置及私有 Keychain，接第一波会话/网络核心与统一仓储：应用
长期持有一次，窗口只观察。用户明确连接/接纳本地语料后才启用对应 corpus/media/
review 通道；登录、退出、切账户、断网/联网、失败重试和重新启动有可理解状态。
从可信 `/me`/workspace metadata 绑定实际业务身份，不把 token subject 当 owner，
不静默合并不同账户的本地库，不在关闭设置窗口时终止整个应用服务。

## E：Mac 内置复习完整闭环

新增桌面复习窗口/导航，采用第一波队列/FSRS/事务与原生 SwiftUI：从义项明确选入、
默认可用练习、可选材料调整/预览、多练习、开始/翻面/键盘评分/撤销、进度、暂停/
退出/恢复和来源返回。收藏不自动入队，例句无独立制卡；材料变化保留手改和记忆，
义项与练习口径分开。Anki 为可选工具，不能用它代替内置复习或合并两者历史。

## 最终集成与主要验收

三位新 Sol/max 负责人各自集中实现与验证，可用 Luna/max 只读审查/测试；root 不在
实现中轮询/干预。组合根、工程生成/导航和共享接口必须明确单一 owner，其他模块
提供独立 hook 文件；root 最后处理接线与冲突。

必要结果是原生 Mac 仍可独立补全/翻译/阅读/收录，同时可浏览统一语料、同步媒体并
执行内置复习。用真实存储及本地 HTTP 验证两端身份、内容与复习可接续；少量关键
Mac UI 操作单独确认。真实云账户、邮箱、真实双设备与权限不足范围如实列出。无
自动化长链/非关键设备门槛，无部署/推送/生产开关、无社区切割或全套 UI 重设计。

## 三模块共用的固定接口

- `MacNotebookRepository(databaseURL:mediaDirectoryURL:)` 在
  `Lingrove/Services/Notebook/MacNotebookRepository.swift`，由 app graph 长期持有一次。
  其 `engine` 是 A 的唯一主 facade，`cloudStorage` 是组合包的三组 storage ports；
  `snapshot()` 返回当前 workspace 的完整 notebook/revision/generation 快照；
  `publishChange()` 通知已提交的变化，`changeSequence` 不是 SQL revision/owner。
  两个不可变 URL 可供 actor 的短期连接读取；任何连接仍为同一个物理库和媒体根。
- 三位负责人都接受这同一个 repository，不在窗口或各功能里创建第二份持久库、
  新 schema、JSON 镜像或另一套 FSRS。后台操作可以像公共 cloud adapter 一样使用
  同文件短期连接，但每个复合命令必须在一个连接的事务内检查原 generation/CAS。
  不把非 Sendable engine/裸 handle 跨 actor 转移，也不在网络等待时持有 SQL 事务。
- `Packages/LingroveNotebookEngine`、`LingroveCloud`、`LingroveNotebookCloud` 为实际公共
  实现；后者 `NotebookEngineStorage` 已接完整 corpus/media/review ports，包含实际
  canonical codec、exact frozen-body 恢复和 ACK。新的窗口/服务不复制这些算法。
- 各模块在自己完成的写入/同步/作用域切换后 `publishChange()`；C/E 监听后重读，
  丢弃旧 scope 草稿/迟到响应。换账户后不能因新库 revision 较小继续展示旧库缓存。
  UI 只持有安全快照，不持有 token、原生连接或 SQL。

## 具体所有权和交付挂接

### C 负责人：语料、内容获取和 CLI

- 所有权：`Lingrove/Services/Vocabulary/`、对应 Models/Support、`UI/Vocabulary/`、
  `Services/Presentation/VocabularyWindowController.swift`、收藏组件、必要的现有读写
  内容获取调用点与 CLI adapter/对应测试。既有 `LingroveCLI/`、CLI wire/文件安全边界
  尽量保持；不扩张 MCP、模型/OCR/补全算法或账户/复习调度。
  为仓储 scope 透传所必需的既有 Anki controller/`ReviewOperationScope` 薄适配也归 C，
  不改 Anki 协议、调度、历史，不与 E 的内置复习合并。
- 交付 `VocabularyStore(repository: MacNotebookRepository)`（可保留现有 init 作独立
  fixture），内部让 archive actor 与公共 engine 结合；保留其现有供翻译/阅读/收藏/
  Anki/CLI 调用的方法表面。原 `VocabularySQLiteDatabase` 不再是产品的另一份真相。
  既有 UI/笔记/关系/分类、图片、备份导入导出与外部 Anki 业务完整可用。
- 提供 `VocabularyStore.unavailable(_ error: any Error) -> VocabularyStore` 或等价明确
  的失败模式：数据库打开失败时显示不可用、拒绝保存，不能悄悄清空/改写原目录，
  也不能让 AppEnvironment 抛出错误阻断补全/翻译。公共 owner init 本身仍为 throws。
- C 在 `VocabularyStore` 提供
  `var onRequestBuiltInReview: ((VocabularySelection?) -> Void)?`，并将合适的义项/列表
  入口挂该回调。默认未注入时不展示假动作；打开入口不收藏、不选入、不写评分。
  例句没有独立制卡。实际准备/明确选入与复习 UI 归 E，保留现有可选 Anki 入口。
- C 接收 repository 变更，账户/工作区/generation 切换时明确重置缓存与未保存草稿，
  不用最新 snapshot 给旧 draft 偷换归属；CLI 与界面采用同一作用域/业务规则。
- 验证实际 engine/SQLite 的收藏、编辑取消/保存/关闭重开、关联、图片与 CLI 关键
  请求；选一条简短原生语料旅程。原先纯领域/导出 checks 可按受影响范围复用，
  不为遗留开发 schema/旧备份/旧 Anki 数据写迁移套件。
- 交付 `docs/MAC_W2_C_DELIVERY.md`，列捕获/CLI 接入、公开挂接、现有功能回归证据、
  作用域与媒体处理、实际 UI/未验证边界及父代理 AppEnvironment 接线。

### D 负责人：账户、采用与同步生命周期

- 所有权：现有 Mac `Models/Account`、`Services/Account`、`Support/Account` 与
  `UI/Settings/Panes/AccountPaneView.swift`，新增 `Services/Notebook/MacNotebookSyncController`
  及必要独立设置组件/对应测试。公共 `LingroveCloud/Account` 与新增 workspace metadata
  transport 必要增强归 D；engine 的账户/归属命令继续复用，不改 C/E 的模块。
- 交付 `MacNotebookSyncController(repository: MacNotebookRepository, account: AccountSessionService)`，
  同步 `start()`/`shutdown()` 管理订阅、代次和任务；长任务为 async。页面只观察/调用，
  开关窗口不启动第二 owner。根 graph 最后由父代理实例化并接入 AppDelegate。
- AccountPaneView 接可选 `syncController: MacNotebookSyncController? = nil`（或等价
  默认参数），现有账户表单/连接草稿准入不能回退。父代理最终沿 SettingsCoordinator/
  Container 传同一 controller；D 不抢改这些共享导航/组合根文件。
- 使用 `AccountSessionService.authorization(forceRefresh:)` 的可信身份、配置、token
  与 session generation；按现有 backend `/me`/workspace 契约取得真实 metadata，
  不从 JWT subject/用户输入伪造 workspace。任何 await 中退出/切服务/重登后，不得
  拼接旧 identity 与新 token/新 generation；必要时收紧公共 authorization 返回围栏
  并补定向竞态检查，不能绕过 SDK 直接读 Keychain 刷新。
- 明确 workspace 选择、local retain/accept 决策和同步 opt-in。登录不上传语料、不
  默认接纳本地内容。退出/切账户取消 coordinator、推进 durable generation、隔离
  当前可见库；保留旧账户持久内容以便以后同一账户恢复，不能归入新账户。
- 使用 `NotebookSyncCoordinator` + 同一个 `cloudStorage`/`NotebookMediaTransfers`，
  支持 corpus/media/review 分别状态、明确 Retry/取消、断网/恢复和重启。corpus 成功
  与 review unavailable 分别展示；没有服务/权限时不能声称同步成功。
  工作区调度设置也按已有服务契约读取/同步，E 从同一 engine settings 查询；不能让
  Mac 对同一工作区默默使用另一组 FSRS 默认参数，也不因此搬入无关 generic Card UI。
- Mac 只提供既有邮箱 OTP；Apple/Google 真正应用登记/账号和服务部署不在本轮，
  不能破坏 mobile 既有 provider。没有默认 Nibomo 请求/guest/遥测或额外托管输入。
- 验证实际私有测试 Keychain/会话（未改部分复用证据）、SQLite 两账户/明确接纳与
  退出隔离、真实本地 HTTP token/workspace/同步/断网重试。使用你自己的合成服务，
  真实云登记和跨设备人工操作留作最终验收，不冒充已通过。
- 交付 `docs/MAC_W2_D_DELIVERY.md`：可信 metadata、storage/同步状态、授权/持久化、
  竞态与恢复证据、设置/生命周期父接线、失败/未验与环境清理。

### E 负责人：原生内置复习

- 所有权：新增 `Services/BuiltInReview/`、`Models/BuiltInReview/`、`Support/BuiltInReview/`、
  `UI/BuiltInReview/`、`Services/Presentation/BuiltInReviewWindowController.swift`、独立
  `Resources/BuiltInReview.xcstrings` 与对应测试。现有 Anki controller/语料 UI 归原
  模块，不能把其行为偷改成内置复习。必要新增 engine query/helper 以独立文件提供，
  不改 FSRS/源 schema/同步算法；跨已有文件核心改动主动询问。
- 交付 `BuiltInReviewController(repository: MacNotebookRepository, speech: LearningSpeechController? = nil)`，
  `show(selection: VocabularySelection? = nil)`、`shutdown()` 和
  `var onOpenSource: ((VocabularySelection) -> Void)?`。父代理挂菜单/命令和 C 回调；
  E 不改 AppDelegate/SettingsCoordinator/现有 Vocabulary UI 或全局输入监控。
- nil selection 打开复习概览；指定义项打开材料准备/已有参与详情，只有用户明确
  确认才选入。默认练习可直接使用，支持可选材料/手改与附加练习、暂停/退出/恢复、
  来源失效/保留材料。复用第三波已有 command/query，不另存本地独立进度。
- 只将个人语料明确参与的可用练习加入该入口的队列；不是所有任意 Card 的入口。
  义项与练习数量分开；队列/评分/撤销/统计来自公共引擎。保存/收藏与例句不触发选入。
- 原生窗口适应 Mac 布局和键盘：翻面/评分/撤销只在正确阶段和窗口响应，编辑文本时
  数字/Tab 不得误评分；不重绑全局补全输入监听。使用已保存材料/媒体与当前 speech
  owner，不能为显示卡面自动下载陌生远程图片或创建新的推理/语音运行时。
- 当前练习/编辑草稿保留完整 saved snapshot + card operation 身份；后台同步改变
  账户、来源或评分后，旧动作失败关闭并明确刷新。undo 必传原 generation。手改卡面、
  来源跟随与评分历史继续保持；窗口关闭不停止整个应用的语料/账户服务。
- 验证真实 SQLite 下明确选入/评分/撤销/关闭重开/来源变化/暂停恢复；少量原生窗口
  键盘/布局组件或一个短主旅程。不扩张全字段 E2E/最大字号矩阵或全部移动 UI 重写。
- 交付 `docs/MAC_W2_E_DELIVERY.md`：用户闭环、公共命令/队列、窗口与键盘、数据和
  历史验证、源导航 hook、实际 UI/未验证范围及父组合根接线。

## 共享文件、工作树与宿主资源

- 三位新的 Sol 6.1/max 负责人各自编写全部实现/测试/脚本，完整实现后集中验证修正。
  可各使用最多两位新的 Luna/max 只读 reviewer/test executor，阶段间轮换，不能让其
  写实现/测试/脚本或再下派。已授权的独立文案 helper 只可自己翻译自己负责 catalog，
  不调用翻译服务/模型；所有 Mac 现有 15 个语言保持可编译/完整，不扩大语言集合。
- 你们不是唯一开发者，不改兄弟工作树、不撤销他人修改。父代理独占 AppEnvironment、
  AppDelegate、SettingsCoordinator/SettingsContainer、全局菜单/命令接线、上述共享
  MacNotebookRepository 基础文件、根 project.yml/SOURCE_LAYOUT/总计划。负责人交付
  独立 hook。各树可为构建重生成并提交自己的 `Lingrove.xcodeproj`，父代理最后统一
  XcodeGen 收敛生成引用；不要为生成 ID 的差异修改产品架构。
- 只有 D 修改公共账户 SDK；C/E 必要新 engine helpers 放各自独立命名文件，已有
  schema/网络/FSRS/公共核心的行为变化主动提问。无新 backend migration/部署/MCP
  工具/Cloud guest/社区切割，也不做旧开发数据迁移。
- 实现期间 root 不轮询、不看工作 diff、不主动指导/接管，只回应负责人主动问题；
  各模块主动完整交付。不能自己合 main/兄弟、跟随动态 main 或提前同步对方代码。
- 三名负责人共享同一 Apple flock `/tmp/lingrove-mobile-validation.lock`。Xcode/Swift/
  Apple 编译与执行持锁到证据落盘，DD 各树 `build/DerivedData`，结束清理并核对。
  不重复嵌套已持锁 supervisor，不互相停止进程/服务，不同时写固定依赖缓存。
- C/D/E 合成服务端口分别建议 19380–19382 / 19480–19482 / 19580–19582；先查空闲。
  所有 Native/Mac UI 验证用自己的 disposable 目录/Keychain namespace/测试宿主，
  不操作运行中的用户 Lingrove/Dev、私人文本、真实账户/邮箱或系统权限。
  本波不需手机/Simulator E2E；最终跨端确认由 root 组合验证。
- 一项自动化基础设施故障最多两次修正或二十分钟，先到则止损并记录截图/状态/
  数据，人工/定向可验证的继续形成 checkpoint。数据损坏/崩溃/用户实际无法完成
  主旅程仍需解决；不把 locator 错误、编译成功或未执行的人工验收叫通过。
- 交付完整 commit IDs、实际运行/失败/未验、证据、接口与父接线建议和清理；无 push/
  部署/生产门控修改、模型 eval 或额外托管传输。第一波 build 经验与缓存路径可从其
  交付/集成报告读取，不重建大型验证框架。
