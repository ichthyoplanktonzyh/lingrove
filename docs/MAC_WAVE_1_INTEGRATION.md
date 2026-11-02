# Mac 第一波整合：共享仓储、账户与同步核心

2026-11-03。第一波固定基线 `9351fd93`；本会话在 `codex/mac-independent-access`
整合 A/B 并完成本地组合验证，没有切换/修改 main、push 或部署。

- A：实现 `945d43c7`，交付 `ef686c15`，合并 `f4eeb500`；见
  [A 报告](MAC_W1_A_DELIVERY.md)与公共 engine README/extraction manifest。
- B：实现 `9f200a2c`，交付 `05efa57a`，合并 `6b8b6017`；见
  [B 报告](MAC_W1_B_DELIVERY.md)与公共 cloud README。
- 组合适配/修正：`6846b1be4865670f02fe6a74dc944069810d8c4b`。
- 第二波从本记录及 `MAC_WAVE_2.md` 提交后的同一 checkpoint 建工作树，准确 SHA
  由派发记录保存；负责人不跟随进行中的 main 或兄弟实现。

## 实际接通与修正

新增 `Packages/LingroveNotebookCloud`，由 `NotebookEngineStorage` 实现 B 的 corpus、
media、review 三组 ports。冻结上传通过 A 的 frozen digest/原字节恢复私有 coverage；
response/ACK/游标通过 A 的 canonical codec 和事务应用，不在 runner 运行 SQL。
后台阶段只传 URL/不可变值，短期连接始终指向同一主文件，网络等待不持有事务，
原 primary engine 的 close/generation 在前后分别检查。各写事务保留自己的作用域/CAS。

移动 NetworkRunner/ReviewRunner 已变为共享 runner 的薄 adapter；原 CloudSessionRuntime
继续管理移动宿主生命周期。移动取消控件与公共 runner 使用同一个 media transfer
registry，原 guest session 的 storage kind 明确透传，Mac 没有新增 guest 路径。
移动工程已引用 Cloud/NotebookCloud；Mac 工程引用全部公共产品。新
`MacNotebookRepository` 固定第二波三个消费者共用的 engine/ports/变更通知接口；
现有 Mac 语料 UI/CLI 和内置复习尚未挂它，不能把本波称作完整 Mac 同步/复习交付。

三个新的 Luna/max 只读审查者分别审查 A、B 与组合适配，未写实现/测试或运行 Apple
工具。集中修正三项实质发现：

1. 精确接受 HTTP 200 的 notebook/media 协议，对其他 2xx 也使用 8 KiB 错误体预算；
   保持 auth 的既有 2xx 合约。真实 socket 的 206 大响应回归通过。
2. NFC/NFD 字节所有权与 Card 写入门一致，生成基线不会推进到未落库的拼写；两次
   连续来源更新仍跟随，已有手改仍保留。真实 SQLite 回归通过。
3. 公共与 mobile notebook undo 必传原 generation，在 writer 内检验；旧快照跨账户
   ABA 不能撤销当前评分。原正常撤销与实际跨副本/服务端历史检查通过。

完整宿主编译另暴露 package 分拆后的显式 module import 和 media `perform` 访问级别
接线，已集中补齐，没有降低 Swift concurrency/signing/系统权限。

## 组合验证证据

证据根：
`/Users/shadow/.codex/worktrees/mac-independent-access/lingrove/build/mac-w1-integration/`。
HTTP/PG 完整场景输出还保留在同树 `build/wave3-review-validation/http/`。

| 检查 | 实际结果 | 主要证据 |
| --- | --- | --- |
| 修改后的 engine scoped SQLite commands | **8 passed** | `engine-scoped-r2.log` |
| Cloud 真实 HTTP/port checks | **12 passed** | `cloud-boundary-final.log` |
| Engine + Cloud 真实 SQLite ports/codec | **3 passed** | `combined-ports-final.log`，收尾后 `combined-ports-post-format.log` |
| 原生 `Lingrove Dev` Debug 构建 | 通过，含全部公共包/host imports；最终 strict codesign 通过 | `checkpoint-mac-build.log/.xcresult`、`checkpoint-codesign.log` |
| Mac app-hosted build-for-testing | 通过，仅编译 | `mac-test-build.log/.xcresult` |
| Mac 账户实际 app-hosted checks | **14 passed**，真实 synthetic Keychain/HTTP/表单渲染 | `mac-account-tests.log/.xcresult` |
| 移动完整宿主 build-for-testing | 通过，仅编译 | `native/signed-build-for-testing.log` |
| 普通 iPhone native execution | **16 passed / 0 failed / 0 skipped**（设备动态参数实例另计 21） | `native/result-summary.log`、`native/result.xcresult` |
| 两 SQLite → URLSession → Hono/PG → PNG/评分/撤销/重开 | **1 passed / 0 failed** | `native/real-http-postgres.log`、`native/http-result-summary.log`、HTTP 目录 proof/xcresult |
| 集成新增/账户生产代码 strict lint | 通过，14 个文件；whitespace 通过 | `integration-lint-verified.log`、git diff check |

PG 实际为 18.6/aarch64（`postgres-version.log`）。终态核对 1 份参与、1 个练习、4 条
评分、2 次撤销、1 份 PNG，Card reps=2；保留上海/洛杉矶/奥克兰三个时区，未授权返回
401。Corpus 成功/Review lane 故障独立报告并恢复也在原旅程内执行。没有修改 backend/
迁移/生产门控，未重跑不受提取影响的全部服务端 suites 或移动 UI 矩阵。

`integration-proof.json` 保存各部分实际执行、最终 Mac binary/hash/signature 与 801 个
native 编译输入。Native/PG 执行后只改三份组合 adapter 的格式和等价 typed media-error
分类拆分，按影响补跑 3 项真实 SQLite ports 与最终 Mac 编译，未因文本指纹变化重复
整套 native/PG 旅程；该差异清单与原始执行指纹均明确保留。

## 失败记录与未验证

- 初始 engine 回归的测试期望未考虑 Markdown 对 `!` 的转义；改为无标点的新释义，
  仍以字节断言 Card/生成基线及后续跟随，修正后执行通过。原失败日志保留。
- 初始组合 fixture 尝试编码仅 Decodable 的 response，编译失败；改成真实 wire JSON
  fixture 后通过。没有为测试而扩大生产 response 的编码接口。
- 前两次 Mac 编译因新 module 的显式 import 不全失败，首次 mobile 编译因 shared
  media perform 的 internal 可见性失败；原日志/xcresult 与最终通过证据分开保留。
- Docker 远端 pull 停滞，停止本次任务自己的 pull client，改用本机已缓存的同一
  18.6 镜像继续；实际版本核对通过。没有反复换镜像/设备或调整产品导航。
- 未执行真实 Cognito/邮箱/Apple/Google、真实 object store、真正双设备界面接续或
  完整 Mac 鼠标键盘账户流程；局部原生渲染、两 SQLite/真实本地 HTTP 不替代这些。
- Mac 完整语料/同步/复习产品接线属于第二波；本波没有构建新 UI、社区切割、手机
  embedding/语义搜索、AI 对话或发布。原 Anki 仍独立可选。

## 环境清理

全部 Apple/Swift/Xcode/Simulator 操作持有共享 flock。专用 ordinary iPhone fresh
automation PID 为 **72461**，app/runner 原来无安装，验证后均卸载，Shutdown 恢复。
没有操作用户 17 Pro/Duo/iPad、正在运行的 Mac 应用、真实账户或系统授权。

自己的 PG compose 已 down，18880/19282 无监听；临时 backend dependency 只读链接已
移除。本树 `build/DerivedData`、三套 Swift scratch、复制的 mobile source packages 与
prepared native/inference caches 全部移除并核对，见 `cleanup.json`。证据目录、私有
gitignored 本地签名配置保留。A/B 的单模块缓存/设备恢复证据见各自报告。
