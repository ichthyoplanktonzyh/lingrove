# Mac Wave 4：保留生词本页面，扩展复习与进度

2026-11-03。用户已授权两名新负责人并行推进。起点为 Mac W3 checkpoint 6c36c382
及派发前已合入的 mobile acceptance。准确冻结 SHA 与 worktree 见 MAC_WAVE_4_DISPATCH.md。
本契约取代原型中额外语料分组及菜单栏调整建议，原型不是实现范围清单。

## 已确认的产品范围

- 扩展点击现有“生词本”打开的独立窗口，主侧栏仅个人语料库、复习、进度。
- VocabularyNotebookRoot 与其分类、列表、详情、工具栏、编辑器和交互完整复用。
  Lingrove/UI/Vocabulary/** 只读，不用原型的简化语料页替换现有页面。
- 不新增“我的语料 / 全部语料 / 尚未加入复习 / 写作积累 / 阅读摘录”外层分组。
- 菜单栏界面、分组、文字、开关和快捷动作保持现状。UI/MenuBar/**、菜单栏控制器、
  全局补全与翻译算法均不修改。原公开复习动作可经 facade 路由统一窗口，菜单构建不变。
- 设置入口打开现有 SettingsCoordinator 窗口；底部账户状态借用已有 account/sync，
  点击定位设置中的账户页。不另造设置/账户 UI、登录流程或 app service graph。
- 收藏不自动选入复习，例句仅作义项材料；Anki 保持可选、独立。
- 无账户可使用语料、内置复习、个人统计；同步沿用原工作区/接纳/opt-in。
- 复习、进度先用 Nibomo 实际组件/UI/交互，只做必要平台与业务适配。
  深色/橙色等外观仅限这两页，不能通过祖先视图改变原生词本外观。
- 不做手机、embedding、AI 对话、社区/排行榜/好友、付费、遥测、生产部署或许可重构。
  用户已明确自有学习代码授权权利，本波不重开版权讨论或修改 LICENSE。

## A：窗口导航与复习接入（唯一组合根 owner）

负责完整实现、必要测试、集中验证和修正：

- 新 UI/NotebookWorkspace、Models/NotebookWorkspace、Support/NotebookWorkspace 及必要
  Services/Presentation/NotebookWorkspace*；VocabularyWindowController.swift。
- Services/BuiltInReview/**、BuiltInReviewWindowController.swift、
  UI/BuiltInReview/BuiltInReviewWindowView.swift 及必要 presentation helper 的最小接入适配。
  已提取的卡面、材料编辑、评分与引擎语义继续使用；不重新设计子页面。
- App/Core/LingroveAppEnvironment.swift 的唯一 owner；SettingsCoordinator.swift 可加
  直接打开既有账户页的导航方法。AppDelegate 仅在路由确需时最小改动，不改菜单栏构建。
- 新 NotebookWorkspace.xcstrings、对应 tests、自己的验证脚本和 MAC_W4_A_DELIVERY.md。

Interface 与不变量：保持既有 VocabularyWindowController init/show(selectedID:senseID:)
调用源码兼容。原页面作为完整目的地，不丢浏览/筛选/选中状态；编辑器/sheet 导航不能
悄悄提交、取消或丢草稿。原来源回跳、CLI open、entry+sense 深链仍选中真实语料。

将现有 review UI 接入复习目的地，走通明确选入、准备/取消、翻面、评分、撤销、
来源返回。BuiltInReviewController.show(selection:) 保持公开行为可用并统一呈现；
不出现两个同时可写的复习会话或按键 monitor。

键盘只在精确活动窗口、可见复习目的地和正确阶段处理；语料编辑、搜索、sheet、
设置及其他应用中的数字/Space/Enter/Tab/Cmd-Z 保持原用途。
关闭窗口不关闭补全、账户/同步、repository；Quit 仍排空已接收写入。
原页面的阅读/搜索/语音工作跟随可见性，避免隐藏页继续工作。

保留 hosting root 和嵌入方式由 A 决定。检查新增侧栏后的有效宽度，可合理调整窗口
初始/最小尺寸；不能通过修改原页面解决外层布局问题。

## B：个人统计与 Nibomo Progress UI

负责真实只读查询、异步加载、组件提取、测试、修正和报告：

- 新 engine Models/Review/NotebookProgress*、Queries/LingroveNotebookEngine+NotebookProgress*、
  Review/Statistics/NotebookProgress*。可复用既有 Progress 值，不改变其公共语义。
- 新 app Models/NotebookProgress、Services/NotebookProgress、Support/NotebookProgress、
  UI/NotebookProgress、NotebookProgress.xcstrings，维持现有 15 Mac locales。
- 自己的 engine/storage/app integration tests、验证脚本、MAC_W4_B_DELIVERY.md，
  及 docs/MAC_W4_PROGRESS_REUSE_MAP.md。

唯一对接 Interface（完整目的地，app module 内）：

    @MainActor
    struct NotebookProgressView: View {
        init(repository: MacNotebookRepository, isActive: Bool)
    }

它借用同一 repository，内部拥有只读 IO/model。isActive 控制加载、订阅和取消；
不显示时不写库，重新进入读取当前合法 scope。B 不拥有窗口/账户/Settings 导航。
真实无历史是空态，加载失败是错误/重试，不允许硬编码样例计数。

- 提取原个人连续复习/日历、按日复习量及四种评分分布、未来安排区间分布。
  沿用原 Charts 交互和 schedule buckets，不根据原型再画另一套七天柱图。
- 从当前 workspace+notebook 的真实内置评分、撤销、Card/保留关联历史统计；
  不混入 Anki、非语料 Cards、其他账户/工作区，不用有限 recentHistory 代替全量统计。
- 有效评分/分布口径一致，撤销不重复计数。暂停/退出、来源缺失/合并仍保留历史；
  未来安排仅纳入当前真正可复习的练习。区分义项数量与练习数量。
- 日边界、当前/最长连续天数、DST/时区和到期区间复用上游纯规则；每次快照冻结
  now/calendar/timezone。不凭空生成服务端 streak-freeze 奖励或不可用按钮。
- 真实 SQL read snapshot 与 scope/revision/generation 一致后才发布；切账户、外部
  commit、退出页面和晚返回不能展示旧账户数据。评分/撤销/参与变化/同步应用后刷新。
  重新进入/重启从存储读取，聚合远离 MainActor，不增加云统计 endpoint 或写 schema。
- Nibomo 原项目只读；提取用到的 Progress Sections/Model/Presentation/Aggregation
  子图，适配 FlashcardsStore/UIKit 依赖，保留 MIT 来源与 bundled license。
  reuse map 逐项写明上游→实际代码、原样/机械适配/业务绑定和未纳入部分。

## 公共 seam 与冲突规则

A 给 VocabularyWindowController 追加可选注入参数（旧调用兼容）：

    progressContent: (@MainActor (Bool) -> AnyView)? = nil

容器按可见性调用，B 通过上述 View init 接入。A 单独构建时可显示明确的未提供状态，
不能添加与 B 同名的 stub 或虚构统计。root 在正式交付后唯一组合修改为：

    progressContent: { isActive in
        AnyView(NotebookProgressView(repository: repository, isActive: isActive))
    }

repository 来自既有 notebookServices，失败时维持真实不可用状态。A 拥有其他 app
组合根接线，B 不修改 AppEnvironment、VocabularyWindowController、review writer/session、
Account/Cloud、schema、project.yml 或现有 UI。需突破 ownership 时主动询问 root。

现有 UI/Vocabulary、UI/MenuBar、UI/Settings、Account UI/catalog、上游 Nibomo 只读；
SettingsCoordinator 的导航方法不属于 Settings UI。根 AGENTS/SOURCE_LAYOUT/计划由
root 收尾。双方仅在自己树生成工程用于编译，交付前只还原自己生成的 pbxproj，
保留全部真实源码修改；root 最终统一 XcodeGen。不要跟随动态 main 或合兄弟分支。

## 工作模式、测试与宿主资源

- 两名新的 gpt-6.1-sol / max，独立 managed worktree。完整实现→集中验证→修正。
  你不是唯一开发者，不撤销他人修改，不扩大 scope。负责人编写全部实现/必要测试。
- 每名负责人最多两名新的 gpt-6-luna / max 辅助者，仅只读审查/执行测试，不能编写
  实现、测试或脚本，不能再下派。文案提取/补译由负责人自行完成，不用外部翻译服务。
- root 在实现中不轮询、不看工作 diff、不主动指导/接管，只响应主动问题及接收交付。
  负责人主动报告 branch/commit、scope、实际执行/失败/未验、接口、风险和清理。
- 数据/查询/历史/取消/晚返回用聚焦真实存储检查；A 覆盖一条相关原生关键旅程和必要
  布局，B 覆盖真实查询/图表/空态/刷新。不把每字段排列串成强制长 E2E。
- 自动化设施一项故障最多两次修正或 20 分钟，先到则止。先看截图/实际状态分类，
  脚本问题记录后形成 scoped checkpoint。编译成功与实际测试通过分开报告。
- 所有 Swift/Xcode/native/Simulator 操作持 Python fcntl.flock(LOCK_EX)
  /tmp/lingrove-mobile-validation.lock 至证据落盘，不嵌套、不在同树并发构建。
  DD 仅各树 build/DerivedData，结束删除并核对。
- 只读复制固定输入 /Users/shadow/lingrove/build/lingrove-dependencies/CotabbyInference、
  tts-native/llama.cpp、nibomo-validation/source-packages 到自己 build，不写共享缓存。
- A 合成端口 19880–19882，B 19980–19982，先检查空闲；适配旧 fixture port env，
  不硬用前波端口，不终止他人进程。私有 host bundle ID/name 各自唯一。
- 私有宿主只在 XCTest 标记下启动。先检查 fixture PID 存活，再 CUA 附着；getApp
  在 app 不运行时会启动完整 graph，不可盲目重启过期 fixture。
- 本机构建明确 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES；安全使用本树签名配置，不打印
  私钥/团队内容。保护用户 Dev、真实 corpus/账户/邮箱/服务/权限，仅合成数据与宿主。
- 不执行耗时 benchmark、Instruments、模型 eval、无关手机/HTTP/Postgres大套件，
  不 push/部署。关闭后清理 DD、复制 native/SPM/module caches、私有宿主/数据，
  保留必要日志/xcresults/source hashes/proof，未做的人工/真云/旧系统验收明确未验证。
- root 正式接收两份交付后集中整合、必要修正、组合验证和 Dev 包/checkpoint；
  负责人不合 main、不 push。
