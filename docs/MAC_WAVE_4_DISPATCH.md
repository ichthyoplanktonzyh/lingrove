# Mac Wave 4 dispatch

2026-11-03。用户授权以两个完整模块并行推进，保留现有生词本内部 UI 和菜单栏。
契约为 [MAC_WAVE_4.md](MAC_WAVE_4.md)。两名新负责人已正式派出，均为
gpt-6.1-sol / max，fork_turns=none，在各自 managed worktree 实现、验证和修正。

固定起点：a151c519369ea7dd4bb423ba127713e7e8e62348。
该起点包含 Mac Wave 3 集成 checkpoint 6c36c382、后续 mobile acceptance 主线提交，
以及当前 Wave 4 范围、ownership、接口和验证纪律；没有复制未提交的工作。
本派发记录是 root 后续元数据提交，负责人无需合入此提交或跟随动态主线。

| 模块 | 负责人 | 分支 | managed worktree |
| --- | --- | --- | --- |
| A：窗口导航与复习接入 | /root/mac_w4_workspace_lead | codex/mac-wave4-workspace | /Users/shadow/.codex/worktrees/mac-wave4-workspace/lingrove |
| B：个人统计与 Nibomo Progress UI | /root/mac_w4_progress_lead | codex/mac-wave4-progress | /Users/shadow/.codex/worktrees/mac-wave4-progress/lingrove |

A 为唯一 AppEnvironment/窗口接线 owner，提供可选 progressContent 闭包。
B 提供 NotebookProgressView(repository:isActive:) 完整只读目的地，不改 A 的文件。
root 正式接收两份交付后再组合该闭包，统一生成工程、集中验证、修正并构建 Dev 包。

交付报告分别为 docs/MAC_W4_A_DELIVERY.md、docs/MAC_W4_B_DELIVERY.md；B 另附
docs/MAC_W4_PROGRESS_REUSE_MAP.md。报告必须带 commit、实际执行/失败/未验证和清理证据。

root 不轮询、不看未交付源码/diff、不主动指导或接管；只响应负责人主动提问并被动
接收正式交付。负责人可用新的 Luna/max 只读审查与测试助手，不编写实现/测试/脚本、
不再下派。两棵工作树的本地签名配置在派发前已单独复制，不在报告中输出配置内容。
共享 Apple flock、各树 DD、合成端口、时间盒与清理规则按契约执行。

本会话集成树仍为 /Users/shadow/.codex/worktrees/mac-independent-access/lingrove，
分支 codex/mac-independent-access；primary main 本轮派发未改动，不 push 或部署。
