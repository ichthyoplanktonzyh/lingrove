# Mac 第二波派发与接口决策

2026-11-03 03:23–03:30（Asia/Shanghai）。共同固定基线
`615e2164d1d782ecf521e8edd713e64dbd07f7fa`；第一波组合实现 `6846b1be`。
第一波实际证据与未验证见 [MAC_WAVE_1_INTEGRATION.md](MAC_WAVE_1_INTEGRATION.md)。
总 scope / hooks / 所有权以 [MAC_WAVE_2.md](MAC_WAVE_2.md) 为准。

| 负责人（均新的 Sol 6.1 / max） | managed worktree / branch | 交付报告 |
| --- | --- | --- |
| `/root/mac_wave2_corpus_lead`（C） | `/Users/shadow/.codex/worktrees/mac-wave2-corpus/lingrove`，`codex/mac-wave2-corpus` | `docs/MAC_W2_C_DELIVERY.md` |
| `/root/mac_wave2_account_sync_lead`（D） | `/Users/shadow/.codex/worktrees/mac-wave2-account-sync/lingrove`，`codex/mac-wave2-account-sync` | `docs/MAC_W2_D_DELIVERY.md` |
| `/root/mac_wave2_review_lead`（E） | `/Users/shadow/.codex/worktrees/mac-wave2-review/lingrove`，`codex/mac-wave2-review` | `docs/MAC_W2_E_DELIVERY.md` |

主代理仍在 `codex/mac-independent-access` 集成树，不修改 main 或部署。各模块独立完整
实现/验证，辅助者仅 Luna/max 只读审查/测试及已授权独立自译文案。实现中不轮询状态/
检查 working diff/发主动实现指导；只回答负责人主动提出的问题，等待正式完整交付。
AppEnvironment/AppDelegate/settings navigation/menus 与统一资源基础文件仍归主集成者。

## 回应负责人主动问题后确认的最小跨文件授权

这些是完成原模块所需的接口扩展，不授权重写算法/另建库/增加托管数据或迁移旧开发快照。

### C：CLI 与内容获取作用域

- 持久 CLI receipt 原先只在旧 VocabularySQLiteDatabase。允许 C 在同一本 engine 中
  添加 host-private、workspace/notebook/owner 隔离的 bounded fingerprint/结果 ledger，
  与真实业务写入/CAS 同一个 Core 事务；必要 NotebookStore writer 借事务 seam 归 C。
  Receipt 不进 cloud journal，不作另一份语料真相。当前 fresh schema 可直接升 **38**，
  无旧 37 开发库迁移/自动擦除，fresh Mac/mobile 定义须自洽。
- 已完成请求在同一业务作用域可跨重启只读重放，不能在新 owner 下当新命令执行；
  原 generation 约束执行和迟到写，不能因此不合理地禁止已完成结果查询。
- CLI batch additive `notebookScope` 与 read/status scope 回复获准；旧对象编辑/append/
  resource 保留原 scope；纯新收藏可沿用 v1 并在 app admission 固定当前作用域。
  纯值不能强迫 CLI executable 导入整个 engine，不扩新 CLI/MCP 命令/文件授权。
- LearningExplanationService 薄 hook 可在生成开始捕获既有持久化 closure 的原 scope，
  切 scope 清相关 cache/待保存结果；C 交付 `VocabularyStore.connectExplanations(to:)`，
  root 替换旧组合根 didExplain/loadPersisted/lookupSaved/enrich。不得改推理/提示词/
  发送目的地，也不自动新增收录/复习或模型请求。

### D：代次、工作区设置与明确 macOS 平台

- 允许 D 独占新增 `Commands/LingroveNotebookEngine+MacAccountLifecycle.swift`。
  `retireLingroveNotebookScope(expectedGeneration:)` 在事务内 CAS 旋转现有
  notebook_window_binding 随机 token，与原 trigger 语义一致，不清 corpus/journal/
  history/cursor。调度 settings apply 在同事务检查 workspace/generation 并复用 SyncApplier。
- 首次新 shell 不能用本机当前时间的默认设置压过远端较早的真实配置；允许薄
  `connectMacWorkspace` 复合 helper 以真实 remote scheduler 初始化新 shell，再沿用
  原 proposal/switch/后续 LWW。Bootstrap limit:1 的 rank0 settings 足够，不下载
  generic Card/Deck。原本本地内容仍需明确接纳。
- 不将原生 Mac 伪装 web/ios：采用 **macos**。D 可最小增加 backend SyncClientPlatform/
  input/installation/workspace replica 约束和直接 typed 依赖/测试；若按仓库规则需要
  migration，**0247 归 D**。权限、RLS、生产门控/遥测不变，不顺带建设 analytics/
  billing/community。要求 tsc 与一个实际 PG/macOS bootstrap 合同检查。
- D 不修改 C 的 schema38/CLI receipt 定义，独立 helper 合并后由 root 做组合验证。

### E：事务内的准备、附加练习与因果撤销

- E 可窄增强现有 `+NotebookPreparation.swift`、`+LingroveNotebookReview.swift`、
  `+NotebookUndo.swift`，不改 schema/FSRS/wire。Mac 安全入口必须强制携带原 saved
  scope；底层 optional typed action fence 可保留既有调用表面，新 Mac 不得遗漏。
  必要 mobile 旧调用只作最小 scope 参数透传/测试适配，交付准确清单，不重写 UI。
- Undo 保持 generation 必传，并在同一 writer 内检查原 scope/预期 Card 与 rating
  operation，避免旧界面撤销后来评分；不可外层嵌套 BEGIN。评分复用既有事务 hook
  做校验，失败整笔回滚，不另写评分算法。
- Enroll/add 可接可选手改 CardEditorInput，与明确选入/附加练习在原事务一次提交；
  nil 沿用生成内容，纯投影仍是 generated baseline，不重置已有调度/历史。
- E 以独立新文件提供 notebook-only 队列/统计，与 C receipt/NotebookStore writer 和
  D 账户 helper 不重叠。必须覆盖取消不落库、原子创建、ABA/参与 CAS 和过时 undo。

## 定时任务

第一波的两小时提醒 `mac` 已在本次唤醒时删除，避免重复执行同一检查。第一波全部
正式交付后已按用户授权完成整合/验证并派出这三个模块；不把停止提醒当作暂停项目。
