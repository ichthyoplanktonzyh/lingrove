# Mac 第一波：共享持久化、复习及网络核心

本契约继承 [MAC_INTEGRATION_PLAN.md](MAC_INTEGRATION_PLAN.md)，覆盖旧 mobile wave 的
Mac 范围禁令，但不授权改动服务端协议、部署或无关功能。起点为本契约提交后的固定
Mac 集成 checkpoint，其中已含 main 的 `e523fc81` 与原生账户实现。

## 共同接口与不可变条件

1. 继续使用 `Packages/LingroveNotebook` 的 domain/codec/sync/text rules/export；不要
   重建另一套 Expression/Sense/UUID/UTF-16/私有内容和公开内容划分。
2. A 的仓储拥有 SQLite 真相，借用同一受保护连接执行复合事务；B 的 network runner
   不运行 SQL、不在网络等待期间保持数据库事务。宿主注入数据库位置、媒体目录、
   凭据/设置与连接配置，包不猜测用户路径、官方服务、Bundle 身份或运行中的应用。
3. 一次作用域绑定包含实际 owner/workspace/notebook/replica 与 generation。异步结果
   返回时仍须验证；owner 字节比较、UUID wire 格式和第三波 canonical 时钟保持原样。
4. A 暴露类型化的 load/save/command、pending/prepare/apply/ACK、媒体 pin/queue、review
   command/query 能力；B 的存储 ports 表达相同阶段与绑定。跨包适配放在主智能体集成，
   独立实现不可依赖兄弟工作树中未交付的代码。不要为少量命名差异发明第二套业务。
5. 仅由用户明确授权启动同步/本地接纳。认证、语料、媒体和 review 状态独立，review
   失败不回滚已经成功的 corpus cursor；exact ACK 不删未发送操作，rotation 先保存。
6. Review 使用 Nibomo 现有 FSRS、队列顺序/时区和 immutable event；Card 调度快照为
   真相，不从历史重放/修复。来源手改三方规则、历史接纳 intent、因果撤销及 batch
   依赖/字节 admission 全部以 `e523fc81` 为准。原有可选 Anki 与内置复习不混写。
7. 公共接口必须可由 Mac 与 iOS 直接 import，运行时不依赖 SwiftUI/UIKit/FlashcardsStore
   或默认 cloud guest。包应有职责/所有权/数据流教学说明及许可/出处记录。

## A 负责人：共享语料与复习持久化

建议新增独立 `Packages/LingroveNotebookEngine/`（包内可按稳定职责拆 target），拥有
整个包/测试/README；必须沿用现有实现而非自行再写一套简化版 schema、FSRS 或同步
冲突规则。名称可小调但不能占用 B 的 `Packages/LingroveCloud/`。

- 提取 mobile notebook 存储及所需最小 SQLite/Foundation 依赖，包含账户归属/明确
  接纳、窗口绑定、CAS、private overlay、source/material/review 的原子变更、同步
  shadow/journal/ACK/rebase/重试/staging、图片 pin/持久化队列及清理规则。
- 提取内置复习 domain/材料准备、Card/Deck 所需值、FSRS/队列选择、选入/暂停/退出/
  恢复、提交评分/撤销/历史/统计等可共享核心；保留历史、手改和多工具独立性。
  最终 public facade 应能让 Mac 不创建整个移动 LocalDatabase/FlashcardsStore。
- 移动宿主改成消费公共实现或很薄的 host adapter；消除已提取逻辑的重复执行路径。
  保留移动现有功能与 UI。若最小公共连接/模型提取需要改旧 Card store 入口，可在此
  模块内完成，但不要把社区/付费/guest/整套应用 service graph 搬进公共包。
- 所有权：新 engine 包；`Packages/LingroveNotebook/` 中必要 domain/codec/storage
  公共契约；mobile `Database/`、`Review/Scheduling` 与必要 queue 纯规则；相应 Models/
  Support 纯类型及原有测试。移动 `.xcodeproj` 的包引用/源引用接线归 A，B 不编辑它。
  `Cloud/Notebook/LingroveNotebookReviewWire.swift` 是持久化与 wire 共同使用的纯 codec，
  其提取归 A（可放现有 NotebookSync target），B 只读取、不另造 codec。除此以外不改
  Cloud/Auth、Cloud/Notebook 网络实现、Mac sources 或根 project.yml。
- 对不可避免的 imports/typealiases 只做机械宿主适配；功能/界面重组不是本波目标。
  新安装 schema 直接自洽，不做旧开发快照迁移，也不自动删除原应用真实目录。
- 验证：实际 SQLite 关闭重开、关系/取消/原子保存、归属/迟到写隔离、媒体 pin、明确
  review 选入、来源手改保护、评分撤销/独立事件；执行现有 FSRS parity cases。编译
  公共包及 mobile 宿主，定向现有 native module tests；无 UI 改动不再跑完整手机流程。
- 交付 `docs/MAC_W1_A_DELIVERY.md`，列 public symbols、旧宿主调用迁移、事务归属、
  精确文件/提交、实际运行证据、未完成项与 B/C/D/E 需要的接线信息。

## B 负责人：共享账户与网络同步/媒体

建议新增独立 `Packages/LingroveCloud/`，依赖现有 Notebook/Sync 公共值，不依赖尚未
交付的 A 包；以存储 ports 注入数据库，不复制 notebook SQL。包/测试/README 归 B。

- 复用 mobile auth 协议与已交付 Mac 的可信 `/me`、bounded/无 redirect transport、
  单飞 refresh/rotation、generation 及状态语义，抽出可跨端使用的认证/会话核心。
  Keychain/设置/宿主 UI 留在平台 adapter，生产不得 fallback 明文。若需要 Mac
  原 AccountSessionService/Models/transport 的薄适配可由 B 修改；不改 Mac UI/App
  composition，第二波 D 才接入同步生命周期。
- 提取现有 corpus normal/staged/window、媒体 upload/download/retry/cleanup 和独立
  review lane 的 transport/runner；保留明确授权、scope检查、exact ACK、幂等、失败
  分类、退避、取消、读取/写入预算、同一 account single-flight。需持久化步骤通过
  注入的 types/ports 执行，不建临时第二主库、不从 network 层改调度。
- 保持 wire/endpoint/生产门控不变。真实账户 provider 注册/发送邮件不在本波；已有
  mobile Apple/Google 登录不能破坏。公开包不自动连官方端点或创建 guest。
- 所有权：新 cloud 包；mobile `Cloud/Auth`、`Cloud/Notebook` 及必要私有 Cloud DTO/
  transport 纯辅助；Mac `Models/Account`、`Services/Account`、`Support/Account` 必要
  adapter 及对应 tests；根 `project.yml` 与 Mac 生成工程包接线。不得编辑 mobile
  `.xcodeproj`、`Database/`、FSRS、现有 Notebook package、Mac UI/App 组合根。
  例外：`LingroveNotebookReviewWire.swift` 纯 codec 归 A；B 的 review 传输 ports 可接收
  已冻结/验证的 bounded wire body，由 A 在存储适配中编码/解码，避免两个并行包互依赖。
  mobile 宿主需要的 project package wiring 写入交付报告，由主智能体最终加入。
- 尽量在移动原入口接薄 adapter 复用公开实现；不复制/迁移整个 CloudSessionRuntime
  或 FlashcardsStore，也不在未接通 A 仓储时宣称全链同步完成。
- 验证：公共包/mac adapter 编译；实际 URLSession→合成 HTTP 认证、refresh、/me
  和 media/corpus/review 协议；记录型持久化 adapter 验证阶段次序、独立 lane 状态、
  取消/旧 generation/ACK 幂等和权限失败。不要用纯 mock 取代 transport，也不自建
  大型测试框架。真实 provider/PG 不是此分包重构的必测，沿用既有已通过协议证据。
- 交付 `docs/MAC_W1_B_DELIVERY.md`，列 storage ports、auth/身份接口、迁移入口、
  project 引用、端点/权限不变证据、运行结果、残留与下一波 app-owned owner 接线。

## 独立工作树、资源和交付规则

- A/B 各由新的 `gpt-6.1-sol / max` 开发，集中实现→集中验证修正，不派其他开发者。
  可各用最多两位新的 `gpt-6-luna / max` 只读 reviewer/test executor，阶段切换轮换。
- 你们不是代码库唯一开发者：只改分配目录，不修改兄弟树，不撤销别人改动。共享
  `SOURCE_LAYOUT.md`/根计划/AGENTS 由主智能体集成，不在自己的分支抢改公共说明。
- 负责人主动提出跨所有权阻塞；主智能体只回应问题和最终交付。无需对方实现状态，
  不轮询兄弟工作。各树集中提交自己的模块，不 merge main/兄弟，不 push、不部署。
- 允许验证用空库/合成身份/受控 loopback。A 端口建议 19080–19082，B 19180–19182；
  启动前检查空闲，不结束其他进程/容器。不要使用旧波次的 18880–18882/18980–18981。
- 全部 Apple/Xcode/swift/simctl/原生工具操作加同一个 Python `fcntl.flock(LOCK_EX)`
  `/tmp/lingrove-mobile-validation.lock`；脚本内已加锁不重复嵌套。DerivedData 每树只用
  `build/DerivedData`，包 build artifacts 也在本树 build 下，完成删除并验证；证据保留。
- 不要占用用户运行的 Lingrove/Dev。Mac app-hosted tests 读取
  `docs/MAC_INDEPENDENT_ACCESS_DELIVERY.md` 的同 Team 签名经验；不能降低系统权限/
  runtime protections 解决环境问题。固定 inference/native 输入仅复制/只读使用。
- mobile compile 使用根保留的固定依赖只读输入；若需 native tests，使用共享锁和
  `docs/MOBILE_WAVE_3.md` 的专用 ordinary iPhone，保留/恢复原 app/数据/开关机状态。
  不开可见 Simulator，不碰用户 17 Pro 或 Duo；iPad/Duo 本波无需新 E2E。
- Node24 固定路径：`/Users/shadow/lingrove/build/nibomo-validation/node-runtime/node-v24.22.1-darwin-arm64/bin/node`。
  iOS package cache：`/Users/shadow/lingrove/build/nibomo-validation/source-packages`；禁止
  多树同时写此目录；有需要复制到自己树。先验证缓存实际存在，不假设已删除旧树可用。
- 交付报告区分编译/已执行检查/未验证/失败、保留证据、环境恢复与清理，主动报告
  分支及 commit IDs。不要用未执行的“人工通过”或“看起来一样”代替真实数据证据。

主智能体在两小时定时节点允许检查是否全部完成；未完工不检查源码或发送实现建议。
第一波集成负责把 A ports 接 B runner、补宿主 imports/project 引用、定向组合验证
Mac/iOS 可 import/运行同一实现，完成 checkpoint 后才冻结第二波具体接线所有权。
