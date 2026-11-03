# Mac Wave 4 A：窗口导航与复习接入交付

2026-11-03。按 [MAC_WAVE_4.md](MAC_WAVE_4.md) 实现 A 固定范围，交付为可集成 checkpoint。
可见玻璃点击旅程仍因 Mac 锁定而未验证，不将其计为通过。

- 分支：`codex/mac-wave4-workspace`。
- 固定起点：`a151c519369ea7dd4bb423ba127713e7e8e62348`，未跟随 main 或兄弟分支。
- 实现、必要测试和验证脚本提交：`90510192034248c7bce45b987c16308aa76723cc`。
- 工作树：`/Users/shadow/.codex/worktrees/mac-wave4-workspace/lingrove`。
- 证据：本树 ignored `build/mac-w4-a/`；归档本树前需由 root 保全该目录。

## 完成范围与边界

现有生词本窗口增加且仅增加“个人语料库、复习、进度”三个外层目的地。原
`VocabularyNotebookRoot` 作为完整目的地嵌入，没有修改 `Lingrove/UI/Vocabulary/**`。
分类、列表、详情、工具栏、编辑器和交互仍来自原页面。普通切页与重开保留同一个
corpus hosting 实例；只有明确的 entry+sense 来源／CLI 请求在草稿安全结束后按原行为
建立请求选中状态，避免已有筛选遮住真正的来源。

`UI/MenuBar/**`、菜单栏控制器、`UI/Settings/**`、AppDelegate、project.yml、上游 Nibomo、
AGENTS.md 和 SOURCE_LAYOUT.md 均未修改。窗口初始内容尺寸为 1240×760，最小窗口尺寸
1000×620；原页面的有效内容宽度在原生检查中仍至少为 760pt。

| 边界 | 责任、所有者与数据流 |
| --- | --- |
| `Models/NotebookWorkspace/NotebookWorkspaceNavigation.swift` | 窗口持有的三个目的地与暂态 sheet 状态；侧栏发请求，窗口决定能否转场；不持有存储或账户行为 |
| `UI/NotebookWorkspace/NotebookWorkspaceSidebar.swift` | 仅外层导航与底部入口；借用原 account/sync 的安全发布状态和原文案，不创建服务或启动同步 |
| `Support/NotebookWorkspace/NotebookWorkspaceCopy.swift` 与新 catalog | 外层文案独立于原生词本／账户 UI；5 个键覆盖现有 15 Mac locales，负责人自行补译 |
| `NotebookWorkspaceHostController.swift` | 保留独立 hosting controller、只挂载可见目的地的原生 split 宿主；负责原工具栏桥接和 780pt 目的地区域下限 |
| `VocabularyWindowController.swift` | 唯一生词本窗口、sheet／深链仲裁、可见性生命周期、借用复习和可选 Progress 注入；关闭不停止 app graph |
| `BuiltInReviewController`／既有 window controller | 原公开 show hook 路由到统一窗口；复用一个 session、IO writer 和本地按键 monitor；独立客户端仍可使用原 standalone host |
| `BuiltInReviewSession.swift` | 区分隐藏、关闭与 Quit；保留冻结 scope/card/link 防护、已接收写入及显式的迟到 UI 结果围栏 |
| `SettingsCoordinator.showAccount()`／AppEnvironment | 账户入口直接定位原账户页；所有其余组合根接线已完成，仍借用 notebookServices 的单一 repository、account、sync、speech、review |

只在复习自身的 SwiftUI subtree 和其 native hosting view 设置深色／橙色。没有祖先
`.preferredColorScheme` 或 tint 改变原页面。原 corpus 的 native appearance 在往返后保持一致。

嵌入 controller 的 `sceneBridgingOptions` 默认为空，因此原工具栏不能仅依赖“页面源码未改”。
验证捕获了这个实际宿主缺口后，在统一 destination host 工厂显式启用 `.toolbars`，不启用
窗口 title 桥接；侧栏不参与桥接。首次挂载、切到复习／进度再返回的检查均通过，原生
metadata 记录 18 个工具栏项，含原导航、动作与搜索。依据为
[Apple sceneBridgingOptions 文档](https://developer.apple.com/documentation/swiftui/nshostingcontroller/scenebridgingoptions)。

## 生命周期与复习不变量

- `BuiltInReviewController.show(selection:)`、原 corpus callbacks、menu facade 和来源返回
  保持可用；AppEnvironment 把 show 路由到同一个 VocabularyWindowController。原卡面、
  准备、编辑、评分、撤销和来源解析 UI／引擎语义继续复用。
- 外层导航不能拆掉 sheet。手动切页和窗口关闭在 sheet／未保存复习 draft 存在时被阻止；
  外部 entry+sense／review 请求保留为待处理请求，原 sheet 自己 Save／Cancel 并结束后才应用。
  取消准备的真实数据库检查确认没有创建 Card。
- 隐藏 corpus 取消原 reading session、暂停 search/index 并停止其语音；隐藏 review 暂停
  read/image/speech 与按键处理，保留练习／导航状态。返回时重新验证 repository scope。
  Progress 的注入 active 标记在离页／关闭时传 false。
- 评分／保存已被接收后，普通 Close 也保留 writer task，供稍后的 Quit drain 等待；不再
  因 UI 关闭丢失对该任务的所有权。新 session 不会接受另一个并发 writer。
- admitted task identity 与 UI publication identity 分开。外部 scope／Card 变化可取消并
  撤销 UI 结果，而原任务仍可被排空；一个已进入同步 SQL 的迟到成功只发布 repository
  change，不能恢复无效的 route／draft。关闭／重开还有独立 lifetime 围栏。
- 本次写入的待刷新标记一直保留到读取实际发布；取消 post-write read 后重新进入仍会
  推进同一练习，不会把自己的评分误判为外部编辑而回到 overview。
- 数字、Space、Enter、Cmd-Z 仅由同一个 monitor 在精确 key window、可见复习目的地和
  正确 practice phase 处理；可编辑 NSTextView／NSTextField、sheet、busy、其他窗口均被挡住。
  Tab 无复习映射。窗口关闭不关闭补全、repository、账户或同步。

## Progress 公共 seam 与 root 集成

保持原 init／`show(selectedID:senseID:)` 调用源码兼容，新增参数完全按契约：

```swift
progressContent: (@MainActor (Bool) -> AnyView)? = nil
```

A 没有定义 NotebookProgressView stub 或提供虚构计数。未注入时展示明确的未提供状态。
root 合入 B 后，只需在现有 AppEnvironment 的窗口构建处按契约注入 B 的
`NotebookProgressView(repository:isActive:)`，repository 取自既有 notebookServices；失败时
维持 nil 与真实不可用状态。此处使用 AnyView 需要 AppEnvironment 导入 SwiftUI。
其余 account／sync／Settings／review 组合接线已由 A 完成，B 不需要修改这些文件。

本树为验证临时生成的 pbxproj 已恢复为固定起点版本；生成副本保留在证据目录。
root 收尾时统一 XcodeGen，并更新 SOURCE_LAYOUT 等根文档。

## 实际执行证据

所有 Swift/Xcode/native 操作由 Python `fcntl.flock(LOCK_EX)` 持有
`/tmp/lingrove-mobile-validation.lock`；同树没有并行构建。仅复制批准的 CotabbyInference、
llama.cpp 和 source-packages 固定输入到本树；本机构建明确 arm64 与 ONLY_ACTIVE_ARCH。
没有运行手机、HTTP／PG 大套件、模型 eval、延迟 benchmark 或 Instruments。

| 检查／尝试 | 实际结果 | 证据（相对 build/mac-w4-a/） |
| --- | --- | --- |
| 最终完整 app-hosted 编译 | build-for-testing 通过，仅计编译 | `mac-build-toolbar-bridge.log/.xcresult` |
| 最终生产 SwiftLint | strict 通过 | `production-lint-toolbar-bridge.log` |
| 原复习／键盘／app 组合检查 | 首轮 8 个命名检查实际通过；设备分项为 14 次参数化执行。随后另一 UI 检查被中断，因此没有把整轮报绿 | `native-summary-initial.log`、`native-result-initial.xcresult`、`native-test-initial.log` |
| 最终新窗口＋原窗口兼容检查 | **6 passed / 0 failed / 0 skipped** | `native-summary-final-workspace.log`、`native-result-final-workspace.xcresult` |
| 工具栏／宽度／设置复用 metadata | 原工具栏 18 项；1000×620 内容尺寸；设置与账户入口复用同一原生窗口 | `native-ui/corpus-minimum-window.json`、`settings-open-windows.json`、`settings-account-windows.json` |
| 私有宿主签名与启动隔离 | strict codesign verify 通过；日志确认 XCTest 跳过完整生产 graph | `host-verify-final-workspace.log`、`host-final-workspace.json`、最终 native log |
| 独立审查 | 1 名新的 gpt-6-luna/max，只读；两项状态竞态修正后及工具栏适配复查均无遗留可复现问题 | `review-final.txt`；审查者未写实现／测试／脚本，未执行 native 操作 |
| 只读范围与源证据 | 17 个产品／测试／脚本 SHA-256；受保护路径与固定基线无 diff | `source-hashes.json`、`integration-proof.json` |

六项最终窗口检查包括：完整 corpus hosting 保留、active 标记和最小宽度／原工具栏；
未保存 sheet 的导航／关闭保护及排队 entry+sense；隐藏页不重启 read、评分／撤销落盘与
Close→Quit 排空；精确窗口／可编辑控件／sheet／phase 按键围栏；评分后取消刷新再返回的
多卡练习；原 ordinary library command 兼容检查。它们借用真实 SQLite 与生产窗口组件。

历史尝试保留，没有混为最终通过：

1. 两轮初始编译分别纠正 AppKit `willBeginSheetNotification` 名称和测试中的同步
   `beginSheet(..., completionHandler: nil)` overload；这些失败未计为测试执行。
2. 首轮新 UI 断言触发 Swift Testing 对 fixture 完整服务图的递归反射。2 秒 debug stack
   sample 定位到断言行，而非产品 UI；只停止了本次私有宿主及其 xcodebuild，并保存中断
   结果。新测试 helper 在调用点计算真实表达式，仅向 macro 传 Bool，源位置仍保留。
3. 修正后是 5 passed / 1 locator failure：原测试按 Settings 标题找窗，但实际既有标题是
   Lingrove Settings。按新建窗口身份／host type 定位后，该项单独通过；没有改产品导航来
   迎合定位器，原生 window metadata 保留了实际窗口身份。
4. 后续新增工具栏检查确认一个产品适配缺口，`native-summary-toolbar.log` 为实际失败。
   按 Apple 的公开 bridge API 修正宿主后，最终上述六项整轮全通过。没有因此重跑不受
   宿主变化影响的存储套件。

## 可见验收限制与后续

可见原生关键旅程**未执行**。先确认私有 XCTest PID 51920 存活，再调用 CUA 附着；工具
返回 Mac 已锁定且无法自动解锁，要求用户手动解锁。没有盲目重新启动过期 fixture，没有
启动用户 Dev 或完整生产 graph，也没有更改系统权限。

离屏 cacheDisplay PNG 已检查，但玻璃层下缺少可靠的实际文字／对比度，因此这些图片仅
保留为布局辅助，绝不是屏幕点击或 glass 对比度通过证据。实际点击的“原窗口→明确选入→
复习→回到语料／设置”以及最终组合后的真实 Progress UI，必须由 root 在 Mac 解锁后补验。
已提供显式启用的 `NotebookWorkspaceOnscreenAcceptanceTests` 与 `onscreen` 脚本阶段：初始
只有合成收藏、0 Card；实际操作完成后检查真实 enrollment、rating、reps 和来源／设置状态。
每次 CUA 附着前仍须先核对 ready.json 中的 PID 存活。

不登录的本地持久化／复习已由真实存储检查覆盖；真云、真实账户／邮箱、系统语音、Anki、
旧 macOS 矩阵没有在此交付中重新验收。A 不把未验证行为宣称为手工通过。

## 清理与交付状态

`cleanup.json` 核对以下均已清除且不存在：本树 `build/DerivedData`、复制的 native／SPM
输入、module caches、私有宿主、私有 app support／cache／saved state／preferences；首轮
中断遗留的一个合成数据库目录和 preference domain 也按记录清除。没有存活的私有宿主
进程；共享固定输入保持只读，用户 Dev、真实语料／账户／邮箱／权限均未操作。

证据目录保留必要 logs、xcresults、源哈希、native metadata、stack sample 和 proof。
未 push／部署／合 main。代码与必要原生／存储检查已经完成，可由 root 接收并集成；
完整视觉接受度仍以上述解锁后旅程为边界。
