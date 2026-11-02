# Mac 第一波派发记录

2026-11-02 23:53（Asia/Shanghai）开始派发。共同固定基线：
`9351fd93b697a145ded9ded6bb008420b864b5d8`。实际范围见
[MAC_WAVE_1.md](MAC_WAVE_1.md)，两波整体目标见
[MAC_INTEGRATION_PLAN.md](MAC_INTEGRATION_PLAN.md)。

| 负责人 | managed worktree / branch | 交付报告 |
| --- | --- | --- |
| `/root/mac_wave1_notebook_core_lead`，Sol 6.1 / max | `/Users/shadow/.codex/worktrees/mac-wave1-notebook-core/lingrove`，`codex/mac-wave1-notebook-core` | `docs/MAC_W1_A_DELIVERY.md` |
| `/root/mac_wave1_cloud_core_lead`，Sol 6.1 / max | `/Users/shadow/.codex/worktrees/mac-wave1-cloud-core/lingrove`，`codex/mac-wave1-cloud-core` | `docs/MAC_W1_B_DELIVERY.md` |

主智能体回到 `/Users/shadow/.codex/worktrees/mac-independent-access/lingrove`，
`codex/mac-independent-access` 作为本会话集成树。没有主树 main 修改、推送或部署。
两位负责人各自完整实现/验证，辅助者只能为 Luna/max 只读审查与测试执行。

## 负责人主动询问后确认的所有权补充

A 的真实持久化依赖比目录名更宽，已主动提出并获得必要的纯类型/机械 import 许可；
B 已被明确告知这些纯值归 A，避免两边提取同段。

- A 可以在移动 Cloud/Auth、Cloud/Notebook 仅为编译增加
  `import LingroveNotebookEngine`；不改 B 拥有的认证/网络/runner 行为。
- Database/NotebookStore/Review 实际依赖闭包中的无 IO DTO、枚举、错误及纯 codec，
  统一由 A 最小原样提取，保持名字、wire 字段及语义；宿主只留薄 alias/展示 extension。
  不因传递类型依赖不断扩大成整个 Cloud 服务图，也不复制同名 DTO。
- 已识别的例子包括 CloudAccountState/CloudSettings/CloudLinkedSession/
  CloudWorkspaceSummary、CloudAuthorization/CloudServiceConfigurationMode、
  Card/Deck/ReviewEvent 的存储 wire 值、MediaTypes 中实际使用的 job/state/direction/
  error 以及 LingroveNotebookNetworkError。ReviewWire 与所需纯 Card/Link/Enrollment
  值可以放 engine，避免 NotebookSync 反向依赖 engine。
- A 交付准确类型/文件清单；B 不需要等待/读取 A 工作树，用固定基线和存储 ports
  完成独立模块。两个包之间最终类型/port/import/project 适配由主智能体集中整合。
- 若遇到有真实服务/IO 行为的跨所有权改动，仍须主动提出，不受纯值许可覆盖。

## 定时继续

用户要求派出第一波后两小时检查，已创建本会话 heartbeat `mac`，名称
“检查 Mac 第一波并推进第二波”，创建于 2026-11-02 23:56 左右。

调度器使用两小时间隔提供下一次未来唤醒；任务内容明确只作一次完成状态检查，并在
唤醒时先暂停自身。预计检查时间为北京时间 2026-11-03 01:56 左右。未完工不检查工作
源码/diff、不发实现建议/打断负责人；没有可行动变化时保持安静。全部正式交付后，
继续整合/修正/必要组合验证、提交 checkpoint，再按第二波契约派出三个新负责人。
定时任务不是两个小时的开发期限，也不能把检查未完工当成暂停项目目标。
