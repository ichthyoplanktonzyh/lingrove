# Mac 第三波 B：Nibomo 账户、同步和复习界面复用交付

工作树：`/Users/shadow/.codex/worktrees/mac-wave3-nibomo-ui/lingrove`。
分支：`codex/mac-wave3-nibomo-ui`；固定基线：
`8a796f9d9cca57b75208e3636b24c9edf188a44e`（含第一轮保存修复）。
实现提交：`5137934dd95a5eb75dc922c525a43ab9a96ec16e`。
本报告另作收尾提交。不跟随动态 main，不合并 main/兄弟树，不 push 或部署。

## 实现结果和来源

已替换原来自行绘制的 Mac 账户/复习展示：采用 Nibomo 实际代码片段、页面结构、原生
Form/List、深色/橙色、820/720 阅读宽度、24-point 卡面、固定底部翻面/评分、独立邮箱/
验证码页、服务器页、workspace 选择页，以及材料选择和正反面分屏编辑。没有设计两套
新样式，也没有只引用“Nibomo 风格”而保留原统计卡片主页。

逐组件的上游路径、原样提取、机械平台适配、业务绑定及不可复用部分见
[`MAC_W3_UI_REUSE_MAP.md`](MAC_W3_UI_REUSE_MAP.md)。实际选择包括：
`ReviewCardSideView`、阅读布局、action styles、answer support/底部评分、queue row/
Later separator、完整文字选择 sheet、account status/server/email/OTP/workspace 的
内容结构，以及 Notebook preparation / CardEditor 的材料表单和独立文字编辑区域。

原 `Nibomo/` 全程只读。提取代码保留 MIT 来源；应用内包含
`Lingrove/Resources/NibomoUI-LICENSE.txt`。没有引入 FlashcardsStore、CloudSessionRuntime、
Premium/支付/社区/AI companion，也没有增加 UI package 或改共享 package manifests。
`project.yml` 无变化；XcodeGen 仅登记新增 app/test/resource 文件。

## 边界和数据流

| 文件/类型 | 为什么单独存在，谁拥有，数据如何流动 |
| --- | --- |
| `UI/NibomoPresentation/` | 提取的展示组件，生命周期由父 SwiftUI 视图拥有；接收 Card/本地图像字节/预测值/闭包，不拥有数据库、网络、账户或调度器。UIKit 的 copy/完整文字选择用 AppKit 替换。 |
| `AccountPaneView`、`UI/Settings/Account/` | Settings 拥有导航、连接草稿和输入焦点；借用 app graph 唯一 AccountSessionService 和 sync controller。保存目的地与可见草稿分开展示，草稿不一致时不发起登录/同步命令。换服务和移除连接先确认。 |
| `AccountNotebookSyncSection` | 保留原 workspace/retain/accept/first-connection/opt-in/retry/cancel 命令。接纳始终传所显示的 expected proposal；补上冲突 Picker 的 local/remote tag，选择可真实绑定。status dot 只投影独立 lane。 |
| `Support/BuiltInReview/LingroveReviewAnswerSupport` | Nibomo 原预测文案投影；仍调用同一个共享 FSRS scheduler，没有复制公式或创建持久调度状态。 |
| `UI/BuiltInReview/` | 原布局的 native binding。题面仍来自已冻结 Card/link/action，材料表单拥有原 draft；选择义项不写库，明确加入或保存才交给 session。最近历史保留为独立列表。 |
| `BuiltInReviewSession` | 原 IO/仓储/生命周期 owner 不变，仅增加一次开窗后进入已有到期题的展示行为。`show(selection:)` 仍打开该义项；`show(nil)` 采用 Nibomo 直接复习入口。完成/空队列可明确结束。 |

App graph、账户/同步/持久化/来源跟随/FSRS/评分和 undo 仍是既有唯一真相。保存语料不
自动选入复习；参与对象仍是义项，例句仅作材料。多练习、暂停/退出/恢复、手改、缺失
来源保留和评分历史都继续通过原引擎命令。Anki 独立，无账户本地复习不受阻。

原 scope/revision/generation、Card/link/参与 CAS、UI expected proposal 不变。Save 已
接收 writer 后禁用 Cancel 与交互关闭，避免 UI 声称取消但写入仍提交；普通窗口关闭及
明确 Quit 的既有 drain 区别仍保留。键盘继续走原 window-local monitor，检查 exact
window、editable responder、sheet、busy 和揭示阶段，不接管全局输入或 Tab。

## 实际验证

证据根：`/Users/shadow/.codex/worktrees/mac-wave3-nibomo-ui/lingrove/build/mac-w3-b/`。
所有 Swift/Xcode/native 命令均持 Python `fcntl.flock(LOCK_EX)` 共享锁
`/tmp/lingrove-mobile-validation.lock` 到证据落盘。实际 Xcode **27.1 (27A9275)**，
执行 Mac 为 **macOS 26.6.2 (25G83), arm64e**。没有 Simulator、模型 eval 或耗时 benchmark。

| 检查 | 实际结果与范围 | 证据 |
| --- | --- | --- |
| app-hosted build-for-testing | 当前交付源码与测试 **TEST BUILD SUCCEEDED**；只算编译 | `mac-build-artifacts.log/.xcresult` |
| checkpoint native execution | **18 named tests passed，1 locator test failed**；含参数展开为 24 passing runs / 1 failing run。没有冒称整套通过 | `native-summary-checkpoint.log`、`native-result-checkpoint.xcresult` |
| 一次局部宿主修正后执行 | AppKit 键盘/真实 SQLite 主旅程 **1 passed**；同一 offscreen locator **1 failed**，停止该自动化路径 | `native-summary-native-host-correction.log/.xcresult` |
| 最终局部执行 | **2 passed / 0 failed**：真实键盘/存储主旅程 + artifact-only 评分栏捕获。后者不算鼠标动作或 glass 外观通过 | `native-summary-artifacts.log`、`native-result-artifacts.xcresult` |
| 私有 host 签名 | 重新签名和 `codesign --verify --deep --strict` 通过 | `host-sign-artifacts.log`、`host-verify-artifacts.log` |
| 生产 Swift strict lint | 本模块生产文件通过，没有更新 lint baseline | `lint-final.log` |
| 文案 | 原 Account/NotebookSync/BuiltInReview 仍完整；新 27 account + 30 review keys × 15 locales 全部 translated | `localization-proof.json` |
| 输入/清理 | 所验证 Swift/catalog/project 哈希仍匹配交付文件；本树 DD/复制缓存移除并复核 | `input-manifest.json`、`validation-proof.json`、`cleanup.json` |

checkpoint 中已实际通过：八项账户服务取消/重试/刷新/过期/离线与旧 callback 围栏；账户
表单关闭重开；workspace/ownership/独立 lane 原生设置；新增原邮箱/OTP 页不重复发码、
可见 draft 不授权发送；workspace chooser 不连接/不启用同步；四项真实 SQLite review
场景，以及两组参数化键盘准入。

真实 review 主旅程执行了准备后取消不写、明确手改选入、Space 翻面、窗口键盘 1–4 评分、
editable NSTextView 中数字和 Tab 不评分、关闭重开、持久撤销、来源导航。另已通过 scope
暂不可用恢复、外部来源变化与账户 ABA 围栏、本地 PNG 字节/摘要/像素和陌生 URL 不加载。
改动仅涉及截图宿主后，只重跑相应旅程；没有因测试文件指纹变化重跑未改的业务套件。

私有 bundle 为 `io.ichthyoplanktonzyh.lingrove.mac.wave3.ui.validation`；XCTest 启动保护
跳过 app-wide production graph。同步 fixture 使用实际 SQLite/URLSession、私有 prefs/
Keychain 和 **19780–19782** 合成端口，执行前检查空闲，最后复核可绑定。没有接触用户
正在运行的 Dev、真实 corpus、账户、邮箱或权限，也没有导入默认 Nibomo URL/guest/
遥测/自动 CDN 图片。

## 实际查看的原生图片和视觉限制

图片仅含合成值，由 AppKit/SwiftUI 内容区域实际绘制；不是设计稿，也不是完整鼠标长 E2E。

- [服务器目的地与连接草稿](/Users/shadow/.codex/worktrees/mac-wave3-nibomo-ui/lingrove/build/mac-w3-b/native-ui/extracted-server-draft.png)：
  原 Current Server 分组和单独输入分组；必要差异是保留 Lingrove 的显式 API/auth URL。
- [OTP 原页面](/Users/shadow/.codex/worktrees/mac-wave3-nibomo-ui/lingrove/build/mac-w3-b/native-ui/extracted-otp.png)：
  原 Email/One-time code 内容和输入，不提供不可用的 Apple/Google 或 guest 动作。
- [workspace 选择](/Users/shadow/.codex/worktrees/mac-wave3-nibomo-ui/lingrove/build/mac-w3-b/native-ui/extracted-workspace-chooser.png)、
  [归属和同步](/Users/shadow/.codex/worktrees/mac-wave3-nibomo-ui/lingrove/build/mac-w3-b/native-ui/extracted-sync-ownership.png)：
  实际 workspace row 和本地明确选择。没有 create-new capability，因而没有假按钮。
- [材料准备](/Users/shadow/.codex/worktrees/mac-wave3-nibomo-ui/lingrove/build/mac-w3-b/native-ui/native-preparation.png)：
  原 example Picker、front/back navigation rows、预览，仍用冻结草稿及原 CAS 保存。
- [题面/答案内容](/Users/shadow/.codex/worktrees/mac-wave3-nibomo-ui/lingrove/build/mac-w3-b/native-ui/native-answer.png)：
  原阅读宽度、material surfaces、copy 行和底栏位置可见，答案段落分开。

**offscreen capture 不证明 glass 的最终外观。** `NSHostingView.cacheDisplay` 没有绘出
compositor glass 背景，题面截图中的黑色评分标签不能据此认定真实屏幕上的对比度通过；
独立评分栏 cached image 为空，已作为 artifact 限制保留。没有为让测试截图变绿而改成
另一套产品样式。最终 on-screen glass 对比度及真实鼠标按压需要父层集成时确认。

完整富文本 renderer 依赖 Nibomo 的 UIKit/MarkdownUI/RaTeX 图谱。本波卡面使用已存在的
安全 native Markdown text/local PNG 边界，**math/table 渲染不宣称与上游等价**。Account
methods 的 provider linking/reauth、AI companion、社区/付费、通知等没有业务能力，不
复制环境依赖，也不展示空操作。旧 macOS 14/15、逐语言布局、实际语音播放、真实 provider/
对象存储及双设备 UI 接续均未执行。

## 自动化失败和修正

初次编译发现提取 helper 名称不一致；随后测试 helper 的递归闭包缺显式 `self`。已集中
修正，失败日志保留。只读 Luna/max reviewer 还发现完成后缺退出、保存中 Cancel、移除
连接缺确认，均已修正；reviewer 没有写代码、执行 Apple 工具或再下派。

新增 in-process accessibility locator 不能在 offscreen SwiftUI glass host 找到 reveal。
一次宿主 realization/protocol 修正后仍失败，两个失败 xcresult 都保留；未按它改产品导航。
已停止并移除不可靠 locator，保留有用的 artifact 生成。最终 artifact-only 方法的通过
不冒充原点击 probe 通过，鼠标路线仍明确未验。已执行的键盘和持久化主旅程没有失败。

## 父层集成

现有 hooks 全部保留，无新业务接口请求：

```swift
AccountPaneView(account: accountSession, syncController: notebookSync)
let review = BuiltInReviewController(repository: repository, speech: existingSpeech)
review.show(selection: selection) // nil 直接打开当前已有复习队列；指定义项仍为详情
review.onOpenSource = { selection in /* existing corpus navigation */ }
review.prepareForShutdown()
await review.shutdownAfterDraining()
```

父层继续唯一拥有 graph、service start/shutdown、全局菜单和 corpus 导航。B 没有编辑
AppEnvironment、AppDelegate、MacNotebookAppServices、SettingsCoordinator/Container、
全局命令、VocabularyStore/Repository/Archive、engine/persistence 包或 SOURCE_LAYOUT。
父层合并后统一 XcodeGen，并把 `UI/NibomoPresentation`、`UI/Settings/Account` 加入根
placement map。需要的组合检查是实际 Settings/全局 Review 入口，以及上面明确未验的
鼠标/glass 外观；不需要新数据库、账户 owner 或 sync owner。

## 清理

`cleanup.json` 已实查 **allAbsent=true**：本树 `build/DerivedData`、module/Swift scratch
caches、复制的 source packages/native inputs 和临时签名宿主都已删除；没有移到全局
DerivedData。自己的 host 无残留、private prefs 已删除、19780–19782 可绑定，原共享
固定输入及私有签名配置保留。日志、xcresults、PNG、哈希和失败记录保留在上述 evidence
目录；如父层归档此 worktree，应先复制需要长期保留的证据。
