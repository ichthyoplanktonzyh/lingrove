# Mac Wave 4 B delivery — personal Progress

2026-11-03。分支 `codex/mac-wave4-progress`；固定起点
`a151c519369ea7dd4bb423ba127713e7e8e62348`。工作树：
`/Users/shadow/.codex/worktrees/mac-wave4-progress/lingrove`。

实现提交（按顺序接入）：

1. `f19d8b7046a2269c97674c4bff525215687d85df` — 原生只读 SQLite/Engine 初始化。
2. `a306b0327774b679cfe626e722c15aec2bb4035b` — 查询、异步模型、提取 UI、15 locale、测试与验证脚本。

本报告单独提交，最终报告提交 ID 见正式交付消息。未合并 main、未 push、未部署。

## 完成范围与数据流

- `Models/Review/NotebookProgressSnapshot.swift` 定义不可变统计结果、工作区/词本/revision/generation
  身份与连接发布栅栏。`Queries/+NotebookProgress.swift` 在一个 SQL read transaction 内读取完整
  有效评分、撤销、保留的 exercise/enrollment 关系、合并义项及真实可复习练习。
- `Review/Statistics/NotebookProgressAggregation.swift` 在读取 actor 内聚合，复用已有上游 civil-date、
  streak 与 DST 安全的 schedule boundaries。总量与连续天数读取完整历史；原 140 天范围只约束
  显示图表。撤销事件从四种评分分布和总量同时排除；历史不依赖 live Card/source/status。
- `NotebookProgressIO` 为每次操作打开同一物理库的原生只读连接，读取并展开显示值后立即关闭。
  `NotebookProgressModel` 只拥有页面生命周期、订阅、可取消读取与临时状态。repository 通知、
  app activation、日期/时区变化及活动期间两秒一次的轻量 SQL metadata probe 触发刷新。
  发布前同时检查 scope、revision、generation 与原 repository 连接的本地/外部修改计数。
- `UI/NotebookProgress` 提取 Nibomo 个人连续复习五周日历、按周分页/按日选择/四种评分筛选的
  堆叠图，以及原八个区间的可选中环图和图例。保留原颜色、交互和布局关系；使用 AppKit 色值，
  原 AccentColor 橙色局限在进度页。义项数量与练习数量分开，空历史和错误/重试有真实状态。
- `NotebookProgress.xcstrings` 共 37 keys × 15 Mac locales，已有译文从只读上游提取，新增词本
  文案及 Traditional Chinese 由负责人补齐。保留现有 bundled MIT license 与提取来源标记。
  逐组件来源见 `MAC_W4_PROGRESS_REUSE_MAP.md`。

未来安排只包含当前 active、live、material ready/explicitly retained 且 link 匹配的内置练习。
暂停、退出、来源缺失及 Card 删除不抹掉历史；合并后义项合计一次、独立练习和评分都保留。
Anki、普通 Cards、仅有来源链接但未选入的 Cards、其他 workspace/notebook 均不纳入。
冻结奖励策略为零容量/零赚取，界面不生成 freeze bank。

## Interface 与集成

公开 app-module seam 保持契约原样：

```swift
@MainActor
struct NotebookProgressView: View {
    init(repository: MacNotebookRepository, isActive: Bool)
}
```

root 在 A 的可选 factory 中注入同一 repository：

```swift
progressContent: { isActive in
    AnyView(NotebookProgressView(repository: repository, isActive: isActive))
}
```

`isActive` 控制读取、订阅与取消；重新进入重新读存储，退出立即清空快照并撤销晚返回的发布资格。
没有新 app graph、长生命周期 repository、自动同步、写入命令、endpoint 或 schema。
本树没有修改 AppEnvironment、窗口组合根、review writer/session、账户/Cloud、project.yml、
原生词本、菜单栏、设置 UI 或 Nibomo 上游源。生成工程只供本树验证，交付前已恢复。

**公共初始化 seam 说明：** 原 `DatabaseCore` 总会准备目录/WAL，原 Engine（包括 borrowing）
总会执行 `purgeExpired`。为满足真正只读，需要扩展这两个原白名单之外的共享文件。
已主动向 root 询问范围；root 回合当时已结束，普通消息不能唤醒，工具也拒绝对 root follow-up。
按已授权的只读目标完成这项最小扩展，并以 `f19d8b70` 独立提交，供集成者明确审查。
普通 initializer 保留原行为；原生 READONLY 会拒绝误调用的写入。独立只读审查未发现具体缺陷。

## 实际验证证据

所有 Swift/Xcode/native 命令均由 `scripts/validation/validate-mac-notebook-progress.py` 持有
`/tmp/lingrove-mobile-validation.lock` 到证据落盘。本机构建显式 `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`，
DD 仅 `build/DerivedData`。固定输入只读 clone-copy 到本树，使用本树签名配置，没有打印配置内容。

| 检查 | 实际结果 | 本树证据 |
| --- | --- | --- |
| 新 Progress 真实 SQLite integration | 7 tests 实际通过 | `build/mac-w4-progress/engine-1.log` |
| 聚焦相关 engine regression | 18 XCTest + 27 Swift Testing = 45 tests，全部实际通过 | `engine-2.log` |
| Native build-for-testing | arm64 Debug 成功（第 3、4 次） | `mac-build-3.log`、`mac-build-4.log` 与对应 xcresult |
| Native model/storage/error/render integration | 5 通过、0 失败、0 跳过 | `native-summary-1.log`、`native-result-1.xcresult` |
| 视觉修正后单独图表复验 | 仅 `nativeChartRendering()`：1 通过、0 失败、0 跳过 | `native-summary-2.log`、`native-result-2.xcresult` |
| SwiftLint strict（新增 app 模块） | 通过 | `lint-3.log` |
| 15 locale/格式占位符/源码 hashes | 37 × 15 完整，placeholders 一致，21 个本地输入 hash 与 21 个上游输入 hash 已保存 | `catalog-proof.json` |
| 生成工程恢复 | 与 HEAD 原工程相同 | `project-restoration.json` |
| 清理 | 列出的 DD/native/SPM/module caches/私有宿主均不存在，私有偏好不存在、无剩余宿主进程 | `cleanup.json` |

新存储检查覆盖：完整历史超过 12 条 recent list、undo/re-rate、不计普通/仅链接 Cards、暂停/
withdrawal、missing source/explicit retain、Card deletion、merge、140 天之外的最长 streak、记录
时区、DST 23 小时边界、全部八个 half-open schedule buckets、同 revision 外部评分和 account ABA。
应用检查实际运行生产 read-only actor：保存后刷新、undo、隐藏后更改与重进、已完成 SQL 结果晚到、
切换账户/工作区、无 repository 通知的外部提交、失败/重试及真实原生图表。

私有宿主 bundle ID/name 为 `io.ichthyoplanktonzyh.lingrove.progress.w4.validation` /
`Lingrove Progress W4 Validation`；仅通过 XCTest app-hosted runner 启动，使用其
`XCTestConfigurationFilePath` 标记，未通过 CUA/getApp 启动 graph。
`host-1.json`、`host-2.json` 保留宿主身份、binary SHA 与计划来源。

## 视觉检查、修正与边界

已实际打开并查看 `native-ui/progress-loaded.png`、`progress-rating-chart.png`、
`progress-schedule-chart.png`、`progress-error.png`、`progress-empty.png`。最终 loaded/rating/
schedule 图片来自单项复验，完整页面显示真实 10 次评分、1 个义项、8 个练习以及八个有值区间。
error/empty 图片来自首轮 5-test 执行，早于仅强调色/Longest 标题的视觉修正。

初次独立组件图片有透明背景，黑色预览背景使标签不易读；这是截图宿主问题，已在测试宿主补背景，
仅重跑相关渲染旅程一次并查看结果。另固定上游橙色，使 Mac 系统蓝色不改变 streak 样式。
两次早期编译失败分别为目的地缺少显式 Engine import、测试仍调用提取前的 paging helper 名称；
均已修正并成功重新编译。严格 lint 的上游数值 `count` 误报在两张提取图表内作有说明的局部规则
抑制；没有修改 lint baseline。首次失败日志保留，不计为测试通过。

本次没有执行前台人工鼠标/VoiceOver 交互、root 与 A 的组合窗口旅程、Dev 包、旧 macOS、真云或
十五语言逐页视觉验收。Charts 交互为原组件提取并经源码审查/编译；原生证据是隔离窗口渲染与真实
存储模型操作，不声称人工点击通过。实际运行系统 macOS 26.6.2；部署目标 macOS 14 编译成功。
没有手机、HTTP/Postgres 大套件、模型 eval、latency benchmark 或生产数据/账户/权限操作。

## 清理与接收

`cleanup.json` 的 `allAbsent=true`、`ownedPreferencesAbsent=true`，无私有宿主进程残留。
已删除本树 DD、复制的 inference/llama.cpp/SPM 输入、Swift/Clang module caches 与私有宿主。
只保留约 7.4 MB 的日志、xcresults、PNG、hash 和 proof；合成数据库由每项 fixture 关闭并删除。
`Lingrove.xcodeproj/project.pbxproj` 已恢复到本树 HEAD，根集成统一生成工程。

root 接收时先按上列两项实现提交顺序接入，再接报告提交并注入 factory。本树不跟随 main 或 A 的
分支；未执行合并或推送。根 AGENTS/SOURCE_LAYOUT 的新增目录登记和最终 Dev/checkpoint 由 root 收尾。
