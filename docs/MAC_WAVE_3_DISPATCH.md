# Mac 第三波派发记录

2026-11-03（Asia/Shanghai）。用户授权一个波次、两名独立完整模块负责人并行执行。
共同固定基线：`8a796f9d9cca57b75208e3636b24c9edf188a44e`，包含 `8c921730` 第一轮
收藏读取修复、更新后的 AGENTS 和 [MAC_WAVE_3.md](MAC_WAVE_3.md) 全部契约。
本派发记录是基线之后的 root 元数据，不要求负责人跟随 root/main 的新提交。

| 模块 / 新负责人 | managed worktree / branch | 正式交付 |
| --- | --- | --- |
| A 保存内部优化：`/root/mac_wave3_save_lead` | `/Users/shadow/.codex/worktrees/mac-wave3-save-pipeline/lingrove`；`codex/mac-wave3-save-pipeline` | `docs/MAC_W3_A_DELIVERY.md` |
| B Nibomo 原 UI 复用：`/root/mac_wave3_ui_reuse_lead` | `/Users/shadow/.codex/worktrees/mac-wave3-nibomo-ui/lingrove`；`codex/mac-wave3-nibomo-ui` | `docs/MAC_W3_B_DELIVERY.md`、`docs/MAC_W3_UI_REUSE_MAP.md` |

两位均使用 `gpt-6.1-sol`、effort `max`、不继承历史对话，以固定契约和自己的 checkout
作为完整上下文。已在派发前核对两树 HEAD/clean 状态，创建各自分支，复制私有
`Config/Signing.local.xcconfig`（未打印内容）。root 仍在原集成树
`/Users/shadow/.codex/worktrees/mac-independent-access/lingrove`，分支
`codex/mac-independent-access`，没有改变另一个对话的移动验收工作区。

## 派发时已明确的实现边界

- A 可以新增仅其保存路径消费的源码兼容 additive command/helper；不能破坏 B 消费的
  既有 Repository/Store/engine 签名。受信缓存/增量方案由 A 决定；不得以任意 baseline
  文档为真相跳过 writer 校验。用户要求不再测收藏开销：本波不做 latency benchmark/
  Instruments/耗时对比或性能门槛，保留必要实际存储正确性和构建检查。
- B 已知 Nibomo 的 Mac 为 Catalyst、部分 UI 依赖 UIKit。原组件提取、既有 Mac 分支、
  保持原效果所需的 UIKit→AppKit/SwiftUI 桥接和业务展示 adapter 均已授权，不需要为
  常规机械适配再等待 root。没有授权新的 Lingrove 视觉/交互重设计或只仿写相似风格。
- B 如需 UI 包，新增独立展示包；不修改 A 所在的既有共享包 manifests。第一方新
  module/adapter 使用 Lingrove 命名；提取的上游原组件保留来源及许可说明。
- `Nibomo/` 源码是冻结只读参考，不与当前移动验收争改文件。新增展示资源不带入
  上游默认服务/guest/遥测、不可用的假登录方法或任意自动远程媒体请求。
- root 保留唯一组合根、全局导航和最终集成所有权。必要跨边界问题由负责人主动提问；
  root 不轮询状态、不看工作 diff、不发主动指导/接管，实现与验证均由负责人完成。
- 两位可使用新的 Luna/max 只读审查/测试辅助者；辅助者不得写实现/测试/脚本。B 确需
  独立文案 helper 时遵守用户既有自译授权，不调用翻译服务/模型或再下派。

## 宿主资源和退出条件

所有 Apple/native 编译、执行和 UI 检查使用同一 flock
`/tmp/lingrove-mobile-validation.lock`；每树只用自己的 `build/DerivedData`。
固定输入仅只读/复制，私有验证 host 建议分别为
`io.ichthyoplanktonzyh.lingrove.mac.wave3.save.validation` 和
`io.ichthyoplanktonzyh.lingrove.mac.wave3.ui.validation`。不使用会终止用户 Dev 的
`scripts/build_and_run.sh`，不触及用户实际语料、账户、系统权限或正在查看的开发版。

两位主动交付完整 commit/report/真实证据、失败和未验证以及已核对的清理。root 收到
正式交付后才检查分支并集中整合、必要组合验证和修正；最后再按 main 的实际状态安全
整合。主线程移动验收在其他分支执行期间，不直接改动该 checkout 或其未提交文件。
