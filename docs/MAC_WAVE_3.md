# Mac 第三波：保存内部优化与 Nibomo 原界面复用

2026-11-03。用户同意两名新的完整模块负责人并行推进。共同源码起点包含
`8c921730`（第一轮收藏重复读取修复）；本契约提交后冻结派发 SHA，准确路径及 agent
写入 `MAC_WAVE_3_DISPATCH.md`。不跟随正在变化的 main，不干扰另一会话的移动验收。

本契约及用户最新要求覆盖历史 Mac 第二波中“自行新增原生 UI”的实现方向。保留现有
原生 Mac 应用和 Lingrove 业务模型；账户/同步/复习优先采用 Nibomo 现成组件及交互。

## 统一产品规则

- 没有 Lingrove 账户也能使用本地补全、翻译、语料管理和内置复习。账户是云端同步/
  身份/授权入口，不新增本地功能登录门槛，也不引入 guest 请求或默认 Nibomo 服务。
- 收藏不自动加入复习；参与对象是义项，例句只作材料；Anki 仍是独立可选工具。
- 保存成功反馈来自真实提交，保留取消不落库、原子性、媒体归属、CLI 幂等、账户/
  notebook/generation 围栏、外部写入失效、手改保护和复习历史。
- 用户已明确不要继续测试收藏耗时。停止 latency benchmark、Instruments、前后耗时
  数字和性能阈值门槛，直接完成结构性优化；必要正确性/存储集成检查和可运行构建保留。
- 无旧开发数据迁移、自动擦除、生产部署/push/门控、遥测、真实账户/邮箱/权限操作。
  用户正在运行本地 Dev 查看效果；模块验证不操作该进程或真实支持目录。

## 固定公共接口与唯一所有者

两名负责人均接受既有 app graph，不能复制另一套数据库、账户、同步或调度器。

1. `MacNotebookRepository(databaseURL:mediaDirectoryURL:)`，保留 `engine`、`cloudStorage`、
   两个 URL、`snapshot()`、`version()`、`publishChange()`、`changeSequence`、`shutdown()`。
   `LingroveNotebookVersion` 的 workspace/book/revision/generation 是缓存与准入边界，
   完整 snapshot 仍是需要内容的草稿/保存边界。A 可优化该资源内部，公开签名保持稳定。
2. `VocabularyStore(repository:)` 的现有收藏、编辑、CLI、scope、load/shutdown 表面保持
   源码兼容，`onRequestBuiltInReview: ((VocabularySelection?) -> Void)?` 不变。A 拥有
   私有存储实现；B 不修改这个 store，也不直接写 SQL。
3. 账户继续使用现有 `AccountSessionService` 的 published 安全状态与 configure/OTP/
   signOut/retry 等方法，同步继续使用 `MacNotebookSyncController` 的既有显式 workspace/
   retain/accept/opt-in/retry/cancel 命令。B 用展示 adapter 接原组件，不重写认证和网络。
4. B 保留 `AccountPaneView(account:syncController:)`；保留
   `BuiltInReviewController(repository:speech:)`、`show(selection:)`、`onOpenSource`、
   `prepareForShutdown()`、`shutdown()`、`shutdownAfterDraining()`。这些是父层现有挂接。
   Account/Review 窗口不拥有 app-wide 服务生命周期，退出仍保护已接收 writer。
5. A 保持已有 engine/codec/同步协议的调用表面及语义；可在自己模块新增内部快路径/
   helper。B 用同一 engine 的 existing query/command 完成所有参与、材料、评分和撤销。
   如果必须改共同公开接口，负责人先主动提问，root 决定最小 seam，不能私自制造分叉。

root 独占 AppEnvironment、AppDelegate、MacNotebookAppServices、SettingsCoordinator/
Container、全局菜单/命令及跨模块导航，最后接线。当前 hooks 已可用于独立完整模块验证；
新接线需求写入交付报告。根 SOURCE_LAYOUT、总计划、派发契约也归 root。

## A：保存事务内部优化

目标：第一轮修复之后，普通单项收藏/编辑仍会走完整文档读取、校验、编码与差异处理。
直接减少对未变化语料与内置分类目录的重复工作，形成完整可用的保存快路径。

所有权：

- `Lingrove/Services/Vocabulary/`、必要的 `Support/Vocabulary/` 保存相关 helper、
  `Services/Notebook/MacNotebookRepository.swift` 及对应测试。保持 UI/公开表面稳定。
- `Packages/LingroveNotebookEngine/Sources` 中直接服务 corpus 保存的 Commands、Queries、
  NotebookStore、必要 Core cache/transaction seam，以及对应存储集成检查。
- `Packages/LingroveNotebook/Sources/LingroveNotebookPersistenceCodec/`，以及 Notebook/
  Sync target 中直接相关的文档校验、规范化、public-intent/delta helper。只改保存所需
  部分，不扩大到模型字段、UI、词典/搜索、网络协议、FSRS 或无关兼容性删除。

具体算法由 A 完整负责，可采用受信缓存、可复用持久化行和增量变更等适合现有深模块的
方式。不能信任调用者随意构造的 baseline 文档而跳过事务内授权/当前状态验证；不能
破坏 Unicode 原字节手改、关联/媒体、review source refresh、journal/frozen ACK 的语义。
保留 full import/restore 的必要完整校验，不能把所有操作简化成不受控的局部写。

正确性验收覆盖受影响的实际 SQLite 保存、并发/外部写入、取消、账户 ABA、关系/媒体、
Unicode 与相关历史/CLI 原子性；优先复用和扩展已有 focused integration。按改动选择
少量检查，不扩 E2E，不进行耗时测量或等待新的性能复现。

交付 `docs/MAC_W3_A_DELIVERY.md`：实现/提交、普通保存路径结构变化、实际减少的重复
工作、保留的完整边界、真实正确性执行证据、构建/未验证/清理。不能只写“移到后台”
或“SQL 仅写改变行”（已有行为）而宣称已经优化内部计算。

## B：账户、同步、复习的 Nibomo 原 UI 复用

用户选择是直接采用 Nibomo 已有组件、页面结构、视觉和交互；本波不制定新的 Lingrove
设计语言，不先做两套新设计稿，不把原 UI 仿写成另一套简易 Form/卡片统计页。

所有权：

- `Lingrove/UI/BuiltInReview/`、`UI/Settings/Panes/AccountPaneView.swift`、
  `UI/Settings/Components/AccountNotebookSyncSection.swift`；可增加独立 Nibomo 展示组件/
  adapter 目录或必要展示包。
- `Services/BuiltInReview/`、对应 Models/Support、
  `Services/Presentation/BuiltInReviewWindowController.swift`；账户展示 adapter 可新增
  独立文件，不能更改 AccountSessionService/MacNotebookSyncController 的业务语义。
- 必要的 Account/NotebookSync/BuiltInReview 文案、上游视图资源及来源/许可说明，和
  对应展示/边界检查。保留现有 Mac 15 个语言，优先沿用上游已有翻译，不扩语言集合。
- 为提取展示组件所需的 `project.yml` 最小 additive 依赖归 B（本波没有第二位修改者）；
  可在自己的树 XcodeGen，父层最后统一生成。A 不改根 project.yml。

首先对照本基线 Nibomo 实际源文件，并在交付中记录组件映射。参考入口包括：

- `Settings/Account/AccountStatusView.swift`、`ServerSettingsView.swift`、
  `AccountMethodsView.swift`、`CloudSignIn/CloudSignInSheet.swift`、
  `CloudOtpVerificationSheet.swift`、`CloudWorkspaceSelectionSheet.swift` 等相关子组件。
- `Review/View/ReviewView.swift`、`ReviewAnswerSupport.swift` 及题面/答案、底部评分/
  工具栏/队列预览组件；`Review/Queue/Preview/ReviewQueuePreviewScreen.swift`；
  `Cards/CardEditorScreen.swift` 及已存在的制卡/媒体展示组件；已加入 Lingrove 的
  `Notebook/UI/LingroveNotebookPreparationScreen.swift` 可作为业务结合参考。

这些入口不是要求全量搬入其依赖图。Nibomo 的 Mac 是 Catalyst，不是独立 AppKit 目标，
原 ReviewView 含 UIKit 与 FlashcardsStore/导航等依赖。优先提取/使用实际无状态组件和
既有 Mac 分支，再做保留原效果所需的 UIKit→AppKit/SwiftUI 桥接以及展示状态 adapter。
不得把全部 FlashcardsStore、CloudSessionRuntime、Premium/社区/支付/AI companion
生态搬入 Mac，也不复制第二套账户/调度/持久化来满足 UI 的环境依赖。

现有 `Nibomo/` 及 mobile 原文件本波作为固定只读参考，避免和另一个会话的移动验收
冲突。允许将选定上游源提取到本模块负责的展示位置，保留来源/许可和必要修改说明；
若必须改上游原文件或公共业务接口，先主动询问。新展示包不得让 Foundation/SQLite
核心依赖 SwiftUI/UIKit，也不能改成 Catalyst 宿主或重写整个原生 Mac 应用。

必要业务适配：义项明确选入、例句仅作材料、多练习/参与状态/来源跟随与手改、独立
Anki 和本地无账户复习。仅支持当前真正可用的登录方法；不展示不可完成的假动作。
不得沿用上游的默认服务 URL、guest、遥测或陌生网络图片/CDN 自动加载。UI 不因关闭
停止同步，未保存的连接草稿不能偷偷向旧地址请求，旧操作保留 generation。

额外交付 `docs/MAC_W3_UI_REUSE_MAP.md`：上游 path/组件 → 实际采用的 path/组件，
分清原样提取、机械平台适配、业务绑定及确实不能复用的原因。保存少量实际 Mac 截图，
逐一说明相对原组件必要差异；仅“参考了风格”不算交付。

交付 `docs/MAC_W3_B_DELIVERY.md`：可运行账户/同步/复习 UI、公开 hooks、实际原生
展示/短旅程与必要持久化/绑定检查、来源表、文案、依赖、失败/未验/清理。保留原来的
收藏与明确选入区别、键盘编辑/评分安全及关闭/退出的写入排空。

## 验证、宿主资源与交付规则

- 两名新负责人均为 `gpt-6.1-sol` / `max`，各自新 managed worktree，从相同冻结 SHA
  建分支。完整模块集中实现，再集中验证和修正；不扩大 scope、不跟随 main、不合并
  main/兄弟树。你们不是唯一开发者，不撤销别人修改，按公共契约适应集成。
- 可各用最多两位新的 `gpt-6-luna` / `max` 辅助者，只读独立审查/执行测试；不得写
  实现/测试/脚本或再下派。确有新文案需求时，可按用户既有授权使用独立 Luna/max
  文案 helper，只能自己完成自己负责的翻译，不调用翻译服务/模型/其他子代理。
- root 在实现期间不轮询状态、不看工作 diff、不发主动建议/接管，只响应负责人主动
  问题并被动接收正式报告。必要接口请求及决定写入派发记录；正式交付后才整合检查。
- 所有 Apple/Swift/Xcode/Simulator/native 操作使用 Python fcntl.flock(LOCK_EX)
  `/tmp/lingrove-mobile-validation.lock`，持锁到证据落盘。同树不并发构建，DD 仅放
  各树 `build/DerivedData`。辅助者不与负责人并发持同一树资源，也不嵌套同一锁。
- 使用自己的 disposable 数据/Keychain/prefs/private test host，不操作用户 Dev、原有
  数据、真实服务/邮箱或权限，不启动模型 eval。模块本波不需要 Simulator；root 集成
  时再按影响选择普通 iPhone/现有跨端证据，Duo 非门槛。
- 如果需合成服务，A 用 19680–19682、B 用 19780–19782，先检查空闲；不停止别的任务。
  只读/复制固定输入 `/Users/shadow/lingrove/build/lingrove-dependencies/CotabbyInference`、
  `tts-native/llama.cpp`、`nibomo-validation/source-packages`，不写共享缓存。
  准备脚本/签名经验见前两波报告及现有 bounded validation scripts。
- 自动化基础设施一项故障最多两次修正或二十分钟，先到则止损；截图/真实状态先区分
  产品失败。取消、损坏、崩溃或用户也无法完成主旅程阻塞对应 readiness；定位/滚动/
  等待故障单独记录，不让全字段 E2E 拖住模块。compile 不能冒充执行，不能虚报人工通过。
- 交付完整 commit/branch、已完成 scope、实际检查和未验证、集成说明、证据及清理。
  `build/DerivedData`、自己复制的构建/module caches 最后删除并核对；保留必要证据。
  主动发送正式交付通知，root 不通过轮询判断你是否结束。
