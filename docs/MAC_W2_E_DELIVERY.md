# Mac 第二波 E：原生内置复习

工作树：`/Users/shadow/.codex/worktrees/mac-wave2-review/lingrove`。
分支：`codex/mac-wave2-review`；固定基线：`615e2164d1d782ecf521e8edd713e64dbd07f7fa`。
未切换/合并 `main` 或兄弟工作树，未 push、部署或修改生产门控。

## 用户闭环与业务边界

- `show(nil)` 打开概览，`show(selection:)` 打开指定义项的准备/参与详情。打开、查阅、
  选择义项、预览、取消及关闭都不选入、不评分。概览的选择器仅列个人已收录义项。
- 「加入复习」明确建立参与并提供默认可用练习。可先选例句、修改提示/答案、预览，
  再将手改与选入在同一引擎事务提交。例句只是原义项的上下文，没有独立复习身份。
- 一个义项可明确附加多个练习；各 Card 独立保留记忆，概览分别显示义项和练习数量。
  队列只来自当前 notebook 的明确参与、有效 link 和可用材料，普通 Card 或仅关联
  而未参与的 Card 不会进入该 Mac 入口。排序复用公共 queue policy。
- 练习经过题面、翻面、1–4 评分、下一题/当前完成；支持持久撤销、关闭重开、查看
  当前进度与最近评分。评分事件保留，撤销记录单列；不从事件重放 FSRS。
- 暂停/退出阻止入队并保留练习和历史；恢复/重新加入沿用尚存练习。缺失来源仍有
  参与详情，可明确使用保存材料继续，也可编辑已保留材料。来源返回仍按三方规则
  跟随未手改字段，调度与评分不重置。
- 原 Anki controller/历史/界面没有改动。没有新后端、schema、独立进度库、账户入口、
  自动模型/语音运行时或远程图片下载。

## 文件与所有权

| 边界 | 责任、所有者与数据流 |
| --- | --- |
| `Services/BuiltInReview/BuiltInReviewController` | app graph 长期拥有的固定挂接 facade，接收同一个 `MacNotebookRepository` 和可选现有 speech owner，拥有一个窗口/会话 |
| `Services/BuiltInReview/BuiltInReviewSession` | MainActor 上的临时导航、冻结问题、草稿、翻面及异步任务身份；观察 repository 通知，实际数据变化后关闭旧草稿/问题，普通 ACK 不丢弃未改草稿 |
| `Services/BuiltInReview/BuiltInReviewIO` | 串行 actor，只接收安全值和不可变 SQL/media URL；短连接访问同一物理库，事务内完成校验/写入后关闭，不跨 actor 传 engine/裸连接，不在 await 期间持事务 |
| `Models/BuiltInReview` | 带原 scope/revision/generation、Card/link/参与快照的材料草稿和窗口会话值；草稿与来源生成基线分开，取消直接丢弃 |
| `Support/BuiltInReview` | 独立键盘准入、保留段落的原生文本投影及小型文案 facade，避免把全局补全输入监听或可选 Anki 文案耦合进复习 |
| `UI/BuiltInReview` | 原生概览、义项选择/详情、材料编辑/预览、题面/答案；只观察会话并把它显示的原快照传回动作 |
| `Services/Presentation/BuiltInReviewWindowController` | 单一 NSWindow、关闭和窗口局部按键生命周期；关闭只取消此窗口 UI/自有朗读，不停止 repository、同步或补全 |
| engine 独立 `*BuiltInReview*` 文件 | notebook-only 只读组合查询、统计/历史/撤销身份，以及强制原 action 的安全命令入口；公共 Card/FSRS/队列/事务/journal 仍是唯一实现 |
| `Resources/BuiltInReview.xcstrings` | 83 个新 Mac 文案，全部既有 15 语言；没有扩大语言集合 |

应用级数据流为：同一个 repository → 冻结窗口 action → IO actor 的同文件短连接 →
公共引擎事务 → repository `publishChange()` → 不可变结果 → SwiftUI。UI preflight
仅用于交互反馈；最终 CAS 在实际 writer 的锁内执行，不能用「刚读过」代替原子检查。

## 公共挂接与父代理接线

```swift
let review = BuiltInReviewController(repository: repository, speech: existingSpeech)
review.onOpenSource = { selection in /* 打开 C 的同一语料窗口 */ }
// C 的 onRequestBuiltInReview 和菜单/命令转发给这个同一实例：
review.show(selection: selection) // nil 为概览
// App shutdown：
review.shutdown()
```

E 没有改 AppEnvironment、AppDelegate、SettingsCoordinator/Container、全局菜单/
commands、MacNotebookRepository、根 project.yml 或 SOURCE_LAYOUT。父代理负责把
C 的 `onRequestBuiltInReview`、全局入口和来源回调接到此实例，并在退出时先 shutdown
此窗口再关闭 repository。工程仅通过 XcodeGen 收敛新增源/资源/测试引用，最终由父代理
统一 regenerate。

## 事务、刷新与键盘细节

- `NotebookBuiltInReviewAction` 保留完整原 scope、整组 enrollment、Card 和 link，以及
  workspace scheduler settings。新写入检查原代次、来源 revision、参与 CAS 和卡片
  operation。旧动作不能因新账户 revision 较小或账户 ABA 自动得到新的 lifetime。
- 初次/附加的手改内容与原 source-generated baseline 分开存储。请求 fingerprint 包含
  原 draft 和 authored input；精确已提交请求先校验原 scope/generation 后重放当前结果，
  不再次写入、附加或恢复后来暂停/退出的状态。
- 撤销仍必传原 generation，并检查原 scope、目标 Card operation 和 rating operation；
  不会把旧按钮改为撤销新评分。只恢复调度字段，保留后续手改和 append-only 历史。
- 经父代理批准，只对既有 `+LingroveNotebookReview.swift`、`+NotebookPreparation.swift`、
  `+NotebookUndo.swift` 增加上述可选参数/事务围栏；现有 Mobile 默认调用保持兼容。
  另在 `+Review.swift` 的现有 writer 内增加可选 `validateCurrentState` 前置 hook，
  E 的安全评分入口强制在 legacy Card read 之前通过原 typed fence。
  所有 E 新写入都执行同一 typed action fence：评分通过此前置 hook，其余命令在各自
  既有 writer 内执行，不依赖界面已刷新作为授权。
- 新 Mac 查询/围栏使用不写库的 `loadOptionalCardIncludingDeleted` 和纯 invalid-state
  检查，发现坏调度明确拒绝；没有修改 legacy Card reader 的旧修复路径或任何 FSRS
  公式、随机/时间策略、源 schema、同步 wire/网络算法。
- 题面保持冻结直到回答；纯队列顺序刷新不会换掉当前题。实际来源、账户、材料、
  评分或调度设置变化会关闭旧问题/草稿并明确刷新；暂时没有 active workspace 也能
  清理 loading 并重试。写任务结果只在原 UI lifetime/operation 仍有效时更新窗口。
- 按键监视器仅在该窗口打开时存在，核对 exact key window、阶段、sheet 和可编辑
  NSTextView/NSTextField；Space/Return 翻面，答案阶段 1–4 评分，⌘Z 撤销。Tab 从未
  被映射，编辑文本时数字/撤销仍交给编辑器；没有改全局输入监听。
- 卡面通过原生 Text 解释保存的 Markdown，媒体只读取当前 scope 下已登记的本地
  PNG，核对大小/摘要并限制实际读取。`source_url`/陌生 HTTPS 图片不触发加载；朗读
  只有显式按钮动作才调用已注入 speech owner。

## 实际验证

证据根：`/Users/shadow/.codex/worktrees/mac-wave2-review/lingrove/build/mac-w2-e/`。
所有 Swift/Xcode/原生编译和执行均由 `scripts/validation/validate-mac-built-in-review.py`
持有 `/tmp/lingrove-mobile-validation.lock` 到日志/结果落盘。DerivedData 固定在本树
`build/DerivedData`；依赖从批准的 `/Users/shadow/lingrove/build` 只读复制到本树。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| E 及受影响引擎 SQLite 回归 | 18 XCTest + 19 Swift Testing = **37 passed**，含 E 新增 7 项；0 failed | `engine-pure-read-final.log` |
| Mac app-hosted build-for-testing | **TEST BUILD SUCCEEDED**，仅构建 | `mac-build-delivered.log/.xcresult` |
| 原生窗口/键盘/恢复/媒体实际执行 | 当前产品覆盖 6 项 Swift Testing / 12 次参数展开；checkpoint 的 5 项通过，媒体 fixture 修正后定向 **1 passed**；恢复分支最后再定向 **1 passed** | `native-summary-checkpoint.log`、`native-summary-media-final.log`、`native-summary-delivered.log` 及对应 xcresult |
| 独立宿主签名 | 同 Team 签名与 deep/strict verify 通过 | `host-sign-delivered.log`、`host-verify-delivered.log` |
| 83 keys × 15 locales | JSON/非空 translated 完整；实际原生资源编译通过 | `localization-proof.json`，native build |
| E 生产 Swift strict lint / whitespace | 通过；未更新既有 baseline | `lint-final-verified.log`，`git diff --check` |

真实 SQLite 覆盖：打开/准备/取消不落库、无效手改整笔回滚、一次确认的手改选入、精确
重试、明确附加练习、普通/未参与 Card 排除、暂停/退出/恢复、Card 调度/历史关闭重开、
workspace 设置用于同一评分、手改后的因果撤销、过时/错配 undo 拒绝、来源三方刷新、
缺失/保留/返回、同代次评分后的 stale edit/retain/status/add、账户 ABA、坏 FSRS 状态
的纯读/评分失败与整行/事件/journal 不变。没有用模拟调度器替代持久结果。

原生检查是在 `io.ichthyoplanktonzyh.lingrove.review.validation` 独立 bundle 中实际执行，
日志确认跳过 production service startup。使用真实 AppKit window/field editor、NSEvent
窗口路由、SwiftUI/原生位图和真实 repository；没有启动用户 Lingrove/Dev。它们是
offscreen 组件与会话检查，不是全局菜单或可见鼠标键盘长 E2E。已实际查看准备页、
答案、关闭重开概览、760×560 最小内容布局和本地 PNG 像素。答案段落分开，最小宽度
下四个评分按钮同排可见；蓝色 PNG 确实显示，陌生 HTTPS 图片只留原文 alt 文本。
图片原字节另在 `native-ui/saved-asset.png`，初始渲染保存在 `native-ui-before-render-fix/`。

最后两次定向执行各只跑受影响恢复/媒体方法；RGB fixture 变化没有重新执行不相关
SQLite suites。`validation-proof.json`、`input-manifest.json` 汇总实际结果与 27 个 E
源码/资源/工程/测试/脚本输入摘要。未将 build-for-testing 当成已执行测试。

## 失败记录与未验证

- 首次 SwiftPM 编译因 Commands/Queries 的新文件同 basename 冲突失败；改为独立
  `+BuiltInReviewRead.swift` 后通过，原失败日志 `engine-initial.log` 保留。
- 首次 native 构建错误使用 mobile validation config，package targets 缺开发团队。
  改用已提供的私有 `Config/Signing.local.xcconfig` 让 host/tests/packages 同 Team，
  没有打印或提交私有配置。下一次编译定位到新增测试嵌套 `#require`，已拆开；
  局部 key monitor 也改为返回 Sendable Bool 后再返回 NSEvent，消除新增警告。
- 两次只读审查发现的精确重放顺序、undo 目标归属、scope 暂不可用的 loading 恢复
  均已修正并覆盖实际检查。审核者没有写实现/测试/脚本或运行 Apple 工具。
- 首轮 native 6 项/12 展开全部通过，但测试注入 NSTextView 到 NSHostingView 产生
  一条层级警告；fixture 改为临时独立 content view 后，后续原生结果 runtimeWarnings
  均为空。静态 lint 的参数数量/布局和单条复杂度限制亦已按局部值/等价表达收敛。
- 像素检查发现完整 Markdown 的段落属性在原生 Text 中被合并；新增纯 inline/保留
  空白投影，准备页补原生背景，并把四评分按钮固定为四列。对应原生主旅程执行通过。
- checkpoint 的 1 项失败属于合成 PNG fixture：NSBitmapImageRep 无法把动态系统色
  写成 device RGB，alpha 仍为零。日志与图片确证后改用固定 device RGB；只重跑
  媒体方法，实际 **1 passed**，alpha/蓝色像素/NSImage 解码和窗口蓝色图块均已核对。
  原 `native-summary-checkpoint.log` 的失败保留，未冒称它整套一次全绿。
- 未执行真实账户/provider、真实云/对象存储、完整双设备 UI 接续或全局菜单/C 入口
  的最终接线，也没有实际播放语音或逐语言/旧 macOS 布局矩阵。这些由父代理组合验证；
  独立组件不声称已经完成整合后的真实跨端旅程。没有已知未修正的 E 产品数据/主流程失败。
- 该模块不操作手机/Simulator、不启动服务端、不占用合成 HTTP 端口、不操作用户运行
  中的 Lingrove/Dev、真实账户、私人文本、邮箱或系统授权。没有模型 eval/延迟结论。

## 提交与环境清理

文案 helper 仅自己翻译所分配的 catalog；两位 Luna/max 审查者均只读，没有写实现/
测试/脚本、运行 Apple 工具或再下派。全部产品、测试和验证脚本由 E 负责人完成。

证据/log/xcresult/PNG 留在本树 gitignored `build/mac-w2-e`。同一持锁脚本已经删除
DerivedData、Swift scratch/module caches、复制的 source packages/native inputs 与
临时 validation host，`cleanup.json` 实际核对 **allAbsent=true**，没有自有宿主进程
剩余；测试专用 preferences 也已清除。私有本地签名配置和原共享输入保留。
实现提交：`5e5e87af0adc0b280e4ff4bb8cc0058c7b876cde`（`Add native built-in review with scoped notebook actions`）。
本报告收尾提交只填写提交号与已完成的清理记录，不修改上述已验证源码。
