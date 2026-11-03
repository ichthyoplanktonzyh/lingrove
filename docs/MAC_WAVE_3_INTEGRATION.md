# Mac Wave 3 integration

2026-11-03。两模块已集中合入 `codex/mac-independent-access`，交付报告分别为
[A 保存内部优化](MAC_W3_A_DELIVERY.md) 和 [B 原界面复用](MAC_W3_B_DELIVERY.md)。
用户要求的本波范围为普通收藏/编辑保存内部优化，以及直接采用 Nibomo 的账户、同步和
复习组件及交互。没有进行 Lingrove 风格重设计、保存延迟基准或 Instruments 验收。

## 合并与模块结果

- 固定派发基线：`8a796f9d9cca57b75208e3636b24c9edf188a44e`，包含首轮保存修复。
- A 实现：`ff7a4928b2ca66be7a4afaf6ca08838615761092`；交付 `89e34a4d`；合并 `3270bbdb`。
- B 实现：`5137934dd95a5eb75dc922c525a43ab9a96ec16e`；交付 `8b01c01b`；合并 `ad81a256`。
- 合入已完成的移动端验收 `main`：`a973a19a`，没有源码冲突。后续主线变化另见最终提交。
- root 重新生成 Xcode 工程，将 A 的保存 helper 和可见窗口检查加入目标；未改产品行为。

普通保存现在只准备目标 entry，由 writer 自己已验证的 SQL/cache 状态建立受限变更，
复用未改变的行投影，再进入同一原子 CAS/journal/media/review-refresh 事务。缓存由单个
连接持有，外部写入、同连接写入、账户 generation、回滚和损坏均不能沿用旧证明。
批量/结构/导入/恢复/远端写入仍走完整验证。保留一个派生快照及连接是减少重复全量
解码与投影的权衡；仍存在必要的全局关系/媒体检查，不宣称常数开销或任何速度倍数。

UI 采用实际提取的 Nibomo 阅读布局、24-point 卡面、固定翻面/评分栏、队列行、原生
Form/List、邮箱/验证码分屏、服务器和 workspace 页面、材料准备与正反面编辑结构。
AppKit 仅替换 UIKit 的剪贴板、文字选择和宿主适配；原始深色/橙色沿用。来源和必要
差异见 [逐组件映射](MAC_W3_UI_REUSE_MAP.md)，MIT 许可已放入应用资源。

这些视图接收已有 session/service 的状态与命令，不创建第二套仓储、账户或调度。
收藏不自动加入复习，例句只提供材料；本地语料与内置复习不要求登录。Anki 仍独立。

## 集成检查

root 证据目录：`build/mac-w3-integration/`。所有 Swift/Xcode/原生/Simulator 操作持
`/tmp/lingrove-mobile-validation.lock`，DD 只在本树 `build/DerivedData`。

| 检查 | 实际结果及证据 |
| --- | --- |
| 完整 Mac app-hosted 编译 | `mac-build-combined.log/.xcresult` 通过；只计编译 |
| 合并后的存储/服务/键盘/展示检查 | **8 passed / 0 failed / 0 skipped**，`native-summary-combined.log`；包含 app graph 唯一归属、真实 SQLite 复习旅程、保存与外部 commit/generation、展示组件 |
| 可见原生窗口 + 实际鼠标操作 | **1 passed / 0 failed / 0 skipped**，`native-summary-onscreen-visible.log` 和 `native-result-onscreen-visible.xcresult`；见下文 |
| 普通 iPhone Simulator 共享存储检查 | **10 passed / 0 failed / 0 skipped**，`mobile/result-summary.log` 和 `mobile/result.xcresult`；scope ABA、有效草稿、被动复习读取、批量原子性、队列刷新、字面内容和媒体持久化 |
| Release Dev 应用 | **arm64 Release build + strict codesign verification 通过**，`dev-release-arm64-build.log/.xcresult`、`dev-release-codesign.log` 和 `dev-app-proof.json` |
| 集成生产 Swift lint / diff | 所有本波改动生产 Swift strict lint 通过，`root-production-lint.log`；`root-diff-check.log` 通过 |
| 独立审查 | 两名新的 Luna/max 只读审查 A/B 交付，最终均无可复现的遗留阻塞；未写实现或测试 |

可见检查使用显式启用的 `MacWave3OnscreenAcceptanceTests`，只创建私有宿主及合成
SQLite/loopback 服务。CUA 实际完成 Show answer → Good → Nothing Due，随后进入账户
服务页。实际屏幕中的 front/back 材料、四个橙色评分按钮及浅色文字可见，可用鼠标
操作；账户原 Form 页面可见。截图在本会话的 CUA 输出中，未把离屏缓存图冒充 glass
合成结果，也未在报告目录伪造一张屏幕 PNG。

`onscreen/stored-result.json` 确认评分事件为 1、reps 为 1。随后通过 A 的保存路径把
义项改为 `a safe anchorage`，卡背跟随新来源，同时 reps/due 保留。这条组合旅程同时
跨过本波两个模块；不登录即可完成复习。

手机检查使用专属普通 iPhone `4F71C81A-36CD-4BE6-BCAE-8F60B05F86D7`，没有操作用户
17 Pro 或 Duo。`mobile/restoration.json` 确认最初未安装的 validation app/runner 已移除，
电源状态从 Shutdown 恢复为 Shutdown。没有运行手机 E2E、真实服务或本波无关的 HTTP/
Postgres 套件。手机构建出现 codec 依赖扫描 warning；Package.swift 已声明对应依赖，
实际编译与执行通过，未将 warning 当作新的功能改造范围。

此前模块证据没有被重复算作 root 的新执行：A 为 23 项共享引擎检查的并集及 6 项原生
检查；B 为 18 named pass / 1 locator fail 的 checkpoint，另有两项局部最终 pass。
详细失败和参数化计数按原报告保留，不声称所有历史执行全绿。

## 自动化问题、边界与产品余项

- B 的离屏 glass AX 定位失败依原 timebox 停止。root 用一条可见窗口旅程补上鼠标及
  实际对比度证据，没有重构产品导航来迎合定位器。
- root 第一次给可见 fixture 注入环境变量只处理新版 xctestrun 结构，实际旧版目标被
  skip；未计通过。随后 180 秒外部交接期限耗尽，只有翻面完成，未计评分通过。修正
  目标注入、把显式手工交接预算改为 10 分钟后，只重编译该检查并补跑此旅程，最终
  上述 1 项通过；没有重跑未变化的 8 项组合检查。
- 检查超时后，CUA `getApp` 曾重新启动私有宿主而非附着旧 fixture，误进入完整 app
  graph。随即在该私有应用中关闭其新增登录启动项并正常退出；没有操作用户 Dev。
  私有偏好与应用数据在最终清理中移除。后续先检查 fixture PID 存活再附着。
- 端口前置检查曾受 TCP TIME_WAIT 影响，实际没有监听进程。检查改为与合成服务一致
  的 SO_REUSEADDR 语义后继续；未停止其他进程，也未改网络产品实现。
- Dev Release 初次构建沿用默认 universal 架构，发现与本机 arm64 native 输入不匹配的
  目标后，只终止本会话持有的 xcodebuild，保留 `dev-release-build.log` 及停止记录；
  明确 `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` 后本机 Release 通过。未把停止的构建算通过，
  未重跑此前已通过的手机或 Mac 业务检查。
- 760-point 最小复习窗口中英文 Selected senses 按钮标题截断，仍可点击并有完整 AX
  标签。这是已观察到的非阻塞布局细节，未为了本波验收扩大 UI 重设计范围。
- 原 Nibomo UIKit/MarkdownUI/RaTeX 富渲染图未引入，数学/表格排版不具备完整等价性。
  保留安全的原生 Markdown 和本地 PNG 边界；不存在自动远端图片加载。
- Nibomo 独立的 Progress 模块没有整体接入 Mac。当前只有义项/练习/队列计数、评分/
  撤销计数与最近历史；连续复习、日历、按日复习量/评分分布、未来安排图仍未接入。
  排行榜/好友统计属于未引入的社区能力，不能把当前复习操作 UI 称为完整统计系统。
- 本波未重做真实邮箱/身份 provider、真实云双端、真实 Anki、系统语音及旧 macOS 矩阵
  验收；合成服务结果不代表生产服务验收。没有任何保存耗时数值或体感速度承诺。

## 证据保全与清理

两个模块的 ignored 证据先复制到 `build/mac-w3-archived-worktrees/`，按全部文件 SHA-256
核对后才通过 managed worktree 工具归档。A 149 文件、B 3910 文件；完整清单为该目录
`preservation.json`。归档可恢复，报告中的旧证据路径可按此目录找到保全副本。

## 最终验证记录

`build/mac-w3-integration/integration-proof.json` 汇总 root 的 8 + 1 项 Mac 检查和 10 项
手机检查，均 0 failed / 0 skipped，另记录 Release 二进制 SHA-256、严格签名和清理。
这些计数不包括被跳过、超时或主动停止的历史尝试，也不包括独立交付的重复执行。

保留的新本机包：
`/Users/shadow/.codex/worktrees/mac-independent-access/lingrove/build/mac-w3-integration/Lingrove Dev.app`。
它是显式 `Lingrove Dev` scheme 的 arm64 Release 产物，未替换或启动用户运行中的旧包。
当前报告不代表用户对新版保存体感或真实账户的验收。

`cleanup.json` 确认本树 DD、复制的 inference/TTS/OCR/dictionary/SPM 输入、module cache、
私有宿主、私有应用目录和缓存已清除；合成端口可复用；两个模块工作树已归档。
932 个已验证产品/测试/工程文件的哈希在最终清理前保持一致。原生构建保留既有 Swift
并发/尾随闭包等 warning，未扩展本波范围去重构补全与运行时。

checkpoint 提交同时登记工程、显式启用的可见旅程及本报告。主线接入只允许在 primary
checkout 仍为干净的 `main` 且可快进时完成，不覆盖另一会话的工作；实际 Git 结果另存
`build/mac-w3-integration/main-integration.json`，不进行 push。
