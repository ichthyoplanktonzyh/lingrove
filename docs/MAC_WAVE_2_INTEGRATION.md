# 原生 Mac 两波集成 checkpoint

2026-11-03。两波完整模块均已交付，本记录描述最终应用接线及本地验收；真实云账户、
真机双端与系统权限验收不因此视为完成。没有 push、部署或生产门控变更。

## 交付与合并

第一波共享引擎、Cloud 和同库 storage adapter 的集成见
[MAC_WAVE_1_INTEGRATION.md](MAC_WAVE_1_INTEGRATION.md)。第二波从固定 `615e2164` 派出：

| 模块 | 实现 / 交付报告提交 | 集成 merge |
| --- | --- | --- |
| C：桌面语料、捕获、CLI | `eb09ab56` / `7ea218d2`，`MAC_W2_C_DELIVERY.md` | `575d4097` |
| D：账户、归属、同步生命周期 | `d9259891` / `e38c7814`，`MAC_W2_D_DELIVERY.md` | `f2fc3f2f` |
| E：原生内置复习 | `5e5e87af` / `fa386356`，`MAC_W2_E_DELIVERY.md` | `fdce3fc2` |

负责人使用 Sol 6.1/max，独立 worktree 集中实现、验证和修正；root 在正式交付后才
检查并合并源码。新 Luna/max 只读审查没有写实现、测试或脚本。最终工程引用由 root
统一 XcodeGen；没有让项目文件的生成 ID 差异影响产品边界。

## 最终数据流与文件边界

`App/Core/MacNotebookAppServices.swift` 是 `LingroveAppEnvironment` 的语料子组合根。
它单独存在，使仓储打开失败与退出排空可以在不启动 AX、全局键盘或模型的情况下
验证。它长期拥有一个 `MacNotebookRepository`，将同一引用交给三种消费者：

- C 的 `VocabularyStore`：现有桌面 UI、阅读/写作的明确收藏和 CLI。Archive actor
  只在同一文件上开短连接，不另建旧 schema/JSON 镜像。
- D 的 `MacNotebookSyncController`：可信身份、明确 workspace、本地 retain/accept、
  同步 opt-in；corpus/PNG/review/scheduler 状态分开，登录本身不采用或上传材料。
- E 的 `BuiltInReviewController`：原生窗口与会话，调用公共引擎的选入、队列、FSRS、
  评分、撤销与历史。收藏不自动选入，例句只作义项材料，Anki 继续独立。

物理路径是各应用支持目录中的 `Notebook/primary.sqlite` 和 `Notebook/Media`。
Dev/production 仍隔离；旧开发档案原地保留，没有自动清空、复制或迁移。
数据库打开失败时交付不接受写入的 unavailable store，账户表单、补全和翻译可继续
构造，不能把错误当作空库并覆盖原文件。

`LingroveAppEnvironment` 将解释持久化改接 C 的 `connectExplanations`，以请求开始时
的原 scope 围栏写入；没有扩大模型传输或修改提示词、OCR、输入监听与补全算法。
C 工具栏/义项入口打开同一 E 窗口；E 的返回来源回调打开现有 vocabulary window。
菜单与 App commands 增加内置复习入口，Anki 单独命名，复用现有 15 语言文案。
`SettingsCoordinator` / `SettingsContainerView` 将同一 D 控制器传到账户 pane，窗口
出现/消失不创建或停止 app owner。AppDelegate 在账户启动后启动同步 owner。

退出有两条明确路径，避免破坏已有 TCC 规则：

1. 应用自己的菜单、Settings 和 ⌘Q 先同步关闭复习的新写入准入，随后等待 CLI、
   语料 actor 和已接收的复习 writer，再停止同步、退休 scope、关闭主连接，最后
   调用正常 `NSApp.terminate`。期间关闭复习窗口只撤销显示，不取消该待完成 writer。
2. 系统直接终止、系统 Quit & Reopen 和既有 relauncher 仍走同步 native cleanup，
   没有 `terminateLater`。这条路径不承诺等待尚未提交的操作；已提交事务正常持久化。

普通窗口关闭保留原 Cancel 语义，不结束 app 语料/账户服务。新 app-services 检查
实际覆盖评分后立刻进入退出准备、关闭窗口、排空并重开 SQLite。

## 集成修正

- 离线时取消 workspace metadata 票据，阻止在线时发起的迟到响应将 Offline 改回
  Ready。实际延迟 URLSession 回归通过；保留离线身份供本地浏览的规则没有改变。
- 显式保留来源失效的材料时保留 generated baseline。来源返回后手改前面继续保留、
  未手改后面继续更新，FSRS/历史不重置；加强真实 SQLite 三方合并回归。
- 根据独立审查撤回最初的延迟 AppKit termination，使用上述显式 Quit 准备路径，
  并防止 CLI 等待期间/复习排空期间的窗口关闭取消已接收的评分。
- 手机媒体检查不再人为降级到 schema 36 并期待旧迁移。当前没有用户数据和旧版本
  迁移合同；改为验证当前 schema 38 的重开、原图及关联保留，未增加生产迁移代码。

## 实际执行证据

证据根：本集成树 `build/mac-w2-integration/`。`integration-proof.json` 汇总结果，
`final-source-inputs.json` 保存 3148 个源码/文案输入 SHA-256。完整日志和 xcresult 均
保留；所有 Apple/Swift/Xcode/Simulator 操作持共享 flock 到证据落盘。

| 检查 | 实际结果 |
| --- | --- |
| 公共引擎的 scope、复习、来源材料/选入/历史 | 18 XCTest + 19 Swift Testing，**37 passed** |
| Mac 选定的组合、账户、同步、原生复习/设置/键盘 | 初轮 **26 passed / 1 failed / 0 skipped**；受影响 C/E 复验 **6 passed**；最后退出准备/窗口关闭修正复验 **2 passed**。并集为 27 项，不声称一次整套全绿 |
| 普通 iPhone 当前语料、scope、复习与媒体 | 初轮 **15 passed / 1 failed**；只重跑修改的当前 schema 重开用例 **1 passed**，并集 16 项 |
| 两份独立 SQLite → URLSession → 实际 Hono → PostgreSQL 18.6 + PNG | Node **1 passed**，内部 native HTTP 旅程 **1 passed**；1 参与、1 练习、4 评分、2 撤销、1 PNG、最终 reps=2、三个时区、未授权 401 |
| 完整 Mac app-hosted 与 mobile host build-for-testing | 通过，仅计编译 |
| 最终 Lingrove Dev Debug 构建与签名 | build 通过；复制出的开发包 `codesign --verify --deep --strict` 通过 |
| root 改动的 11 个生产 Swift 文件 | strict lint 通过；`git diff --check` 通过 |

Mac 检查使用私有 `io.ichthyoplanktonzyh.lingrove.review.validation` 宿主，启动日志确认
跳过生产服务；真实 SQLite、私有测试 Keychain、loopback HTTP、AppKit/SwiftUI 组件
实际执行。root 已查看 `native-answer.png` 和 `native-overview-minimum.png`，答案段落、
四评分按钮及小窗口统计清晰。该证据是原生组件/会话检查，不是全局菜单长 E2E。

最终开发包保留于本集成树 `build/mac-w2-integration/Lingrove Dev.app`；
`dev-app-proof.json` 记录 binary SHA-256。没有替换或启动用户已安装/运行中的应用。

手机仅使用专用普通 iPhone `4F71C81A-36CD-4BE6-BCAE-8F60B05F86D7`；实际新 PID 69549
确认 `isAutomation=true`。应用/runner 原先未安装，结束卸载并恢复 Shutdown，
两次执行各有 `restoration.json`。没有操作用户 iPhone 17 Pro、Duo 或额外 iPad。

真实 HTTP 用例只替换证据输出目录后执行，原始/实际 TS 和 SHA 存于根证据目录；
断言未变，临时 adjacent test 已删除。它使用合成身份 loader 与真实 route/runtime
role/RLS，不冒充真实 JWT provider。D 的 macos bootstrap/同 replica/拒绝未知平台
PG 检查与 tsc 已在正式交付中通过，root 没有修改 backend 后机械重跑那套检查。

## 失败与未验证

- 两次原生编译定位缺少显式 Logging / LingroveNotebook import，补齐后通过。
  一次新测试的 throwing `&&` 表达式拆出 throwing read 后通过。原失败日志保留。
- 最初组合用例未等待 C 的首次 projection load，就进入 E 选入阶段；真实旧快照
  围栏拒绝了动作。fixture 改为先完成实际 `load()`，增加阶段断言后通过；没有
  放宽产品 generation/CAS，也没有为找不到按钮增加手势、等待或导航机器。
- 手机失败是仍在验证已不要求的旧 schema 迁移，修正测试范围后单独通过。没有将
  这类失败伪报成产品导航问题，也没有因此重跑其余已通过业务检查。
- 最后 prepare/close 排空修正只重跑相关 2 个 Mac 检查，不机械重跑未变化的 Cloud、
  SQLite 37 项或普通 iPhone 全部用例。各模块原始证据分别见三份交付报告。
- 尚未执行真实云账户/邮箱/provider/对象存储、Mac+手机真机云界面接续、系统 TCC
  Quit & Reopen、实际语音播放、完整生产 app graph 的新菜单/设置鼠标流程、全部语言
  和旧 macOS 矩阵。这些是后续实际验收边界；本轮没有已知未修复的数据/主旅程失败。

## 清理与后续

第一波 managed worktree 已归档。第二波三树证据先复制到
`build/mac-w2-archived-worktrees/`，逐文件 SHA-256 一致：C 7079、D 4533、E 4473 文件；
源码及提交均已合并后通过 managed archive 清理。证据保留而不是随工作树丢失。
root 的 `cleanup.json` 记录 DerivedData、Swift/package/module/native caches、私有宿主
清理、端口和工作树检查；仅保留开发包与验证证据。共享固定缓存未修改。

两小时一次性提醒 `mac` 已在本次唤醒开始删除，没有继续轮询正在实现的负责人。
这不暂停项目目标。两波已完成；下一步是在实际部署/账户条件具备时进行短人工验收，
不把真实 provider、生产开关或额外功能混进这个本地集成 checkpoint。
