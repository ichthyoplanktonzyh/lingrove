# Lingrove 测试环境与真实客户端验收方案

2026-11-03。用户确认尚无自有 API/Auth/MCP 服务，先完成
[本地双设备验收](MOBILE_FINAL_ACCEPTANCE.md)，再选择测试环境。本方案基于当前源码，
不是部署记录。方案编写时未创建云资源、域名、公开转发或 OpenAI tunnel，未开启生产服务。
后续已在用户授权下完成[真实 ChatGPT 私有 Tunnel 读写与撤销验收](PRIVATE_MCP_LIVE_ACCEPTANCE.md)；
并已补齐[ChatGPT 写入后在普通 iPhone 模拟器同步、浏览和重开的旅程](PRIVATE_MCP_MOBILE_ACCEPTANCE_INTEGRATION.md)。
真实身份提供方、物理设备和自有 HTTPS 环境仍未验收。

## 按验收结果分三步

| 步骤 | 需要取得的证据 | 所需环境 |
| --- | --- | --- |
| 本地 iPhone/iPad 接续 | 两个真实 simulator app 经同一后台接续语料/图片/参与/评分 | 独立 loopback API、PG 和 synthetic 身份；[本地接续已交付](MOBILE_FINAL_ACCEPTANCE_INTEGRATION.md) |
| 真实 ChatGPT 读写 | ChatGPT 实际发现工具、读取/保存合成语料，移动端读到结果；撤销后拒绝访问 | 可达的 MCP 服务与 ChatGPT 连接；可选私有 Secure MCP Tunnel 或自有 HTTPS |
| 真实账户及设备接续 | 实际登录、token 恢复/失效、跨端接续，账户与媒体权限正确 | 自有 API/Auth、真实测试身份提供方、数据库/对象存储、必要 HTTPS |

三步分别保存证据。Synthetic 登录不等于真实 Cognito/邮箱验收，双 simulator 不等于
物理双设备，SDK/HTTP 测试也不等于 ChatGPT 实际调用。

## ChatGPT 可以先使用私有测试连接

OpenAI 当前文档支持公共 HTTPS MCP 或 Secure MCP Tunnel。后者由本机向 OpenAI 建立
出站连接，可让 ChatGPT 调用私有 MCP，不需要先把本机端口公开；它仍会把被调用工具的
请求/结果送到 OpenAI，并不意味着数据留在本机。见
[连接与测试](https://developers.openai.com/apps-sdk/deploy/connect-chatgpt)及
[Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)。

本地验收结束后，先确认用户的 ChatGPT workspace 是否允许自定义 MCP，以及 Platform
组织的 tunnel 权限和关联：创建需要 Read+Manage，运行需要 Read+Use；具体权限以账户
实际页面为准。若具备条件，可先用仅含合成语料的隔离后台验证 ChatGPT 的读写路径，
减少对公网 MCP 服务的前置依赖。Secure MCP Tunnel 只转发 MCP，并不替 Auth 建立通道；
现有 OAuth challenge 仍指向 Auth origin，OAuth 模式需要 ChatGPT 可达的 Auth 服务。
若保持全部服务私有，需另行验证受支持的 bearer/API-key 接线与隔离测试身份，不能
预先称其为现成方案，也不替代真实身份提供方或正式公网服务验收。

届时需要用户协助选择目标组织/workspace，并在 ChatGPT 中建立连接、确认实际写入。
密钥在本机受限配置中使用，不放入对话、命令参数、截图或报告；无需把验证码发给助手。
以上是方案阶段的授权前置条件；后续实际创建、连接与清理结果以真实连接验收记录为准。

最小的真实客户端旅程是：读取 notebook guide→搜索/读取某条合成义项→明确保存一条新
语料→移动端同步读回→确认保存没有隐式选入复习→撤销连接并确认后续请求被拒绝。
记录实际工具名、request ID、实体 ID 与结果；不把原始 token 或完整私有语料记入日志。
这是一条业务旅程，不做所有字段与工具组合的 E2E 矩阵。

## 自有服务的最小拓扑

沿用仓库现有账户/权限、corpus/media/review 和 MCP，实现同一后端/数据库的多个入口，
不为 MCP 建第二本语料库，也不复制评分调度实现。先不选择云厂商或购买资源。

| 服务 | 拟定的地址形状（占位，未注册） | 责任 |
| --- | --- | --- |
| API | `https://api.test.<自有域名>/v1` | 原生账户工作区、语料、媒体与复习同步 |
| Auth | `https://auth.test.<自有域名>` | 真实测试账户登录、会话、OAuth 授权/PKCE/token |
| MCP | `https://mcp.test.<自有域名>/mcp` | Streamable HTTP、认证 discovery、已授权工具 |
| PostgreSQL | 私网、独立测试数据库与角色 | 工作区权限、事务、幂等、持久语料与评分 |
| 图片存储 | 私有 bucket/测试 namespace | API 媒体路由代理读写，服务端存取对象存储；客户端不直连 bucket |

仓库 MCP Lambda 以 `MCP_BASE_DOMAIN` 推导 MCP 主机和 PRM 中的 `auth.<base>` origin；
Auth 服务自身的 issuer 来自 `PUBLIC_AUTH_BASE_URL`，resource 可由 `MCP_RESOURCE` 覆盖。
只设置 `MCP_BASE_DOMAIN` 不会自动配置另一服务。上表采用 `test.<自有域名>` 时，需要
同时配置并核对这些值；API 客户端配置使用实际含 `/v1` 的地址。Auth 的 issuer、PRM、
授权/token URL 和 MCP resource/audience 必须相互匹配。浏览器回调需与动态注册的
`redirect_uri` 精确匹配，但无需与 API/Auth/MCP 同域。不能依赖重定向纠正配置。
当前实现见
[Lambda MCP](../Nibomo/apps/backend/src/entrypoints/lambda-mcp.ts)、
[OAuth metadata](../Nibomo/apps/auth/src/routes/oauth/metadata.ts)和
[Auth 服务](../Nibomo/docs/auth-service.md)。

真实账户优先复用既有 Cognito/邮箱认证路径，只配置测试用户与测试 provider，不另写
认证系统。首轮不把 Apple/Google、社区、计费、AI 生成和应用商店发布串入这条验收；
这些功能若要发布，另有各自的运行条件。

## 从当前代码到可用测试服务还需要的接线

1. **部署入口。** 当前根 `.github/workflows` 没有 Lingrove backend/AWS 发布任务。
   `Nibomo/.github/workflows/aws-web-release.yml` 是 vendored 上游方案，路径、stack、
   域名和 secrets 都不能当作本项目已经配置的 CI。若选择 AWS，按本项目建立独立
   staging CI；遵守 Nibomo 规定，不在本机构建 AWS bundles 或直接执行 AWS 部署。
2. **普通 corpus。** `createApp` 已挂载 corpus/media，能力通过 schema 就绪检查，
   没有一个现成的 `CORPUS_ENABLED` 总开关。部署完整迁移并开放 API 会使认证工作区
   能用该通道，不能声称另有未实现的默认关闭环境变量。
3. **复习通道。** `createApp` 尚未传 `privateReviewTransport`，正常服务会对该路径
   返回 404。需要独立 staging composition 的显式接线及当前 migration `0246`，
   不能把 test fixture 的 opt-in 冒充真实服务已可用。应保持 production 原有组合不变。
4. **MCP 通道。** `LINGROVE_NOTEBOOK_MCP_ENABLED=1` 才注册四个 notebook 工具；
   还要具备 `0245` 的 durable command 表和真实 OAuth/API-key connection、membership
   及 workspace scope。该开关是在既有工具库存中增加 notebook 工具，不等于整个
   服务只暴露四个工具。验收前核对完整 `tools/list` 与实际连接权限。
5. **图片。** 移动端经授权的 `/notebook/media/bytes` API 传 PNG，服务端访问私有
   对象存储，不签发 notebook bucket 直连 URL。当前图片上限 4 MiB，本地 fixture
   不能证明真实存储配置；浏览器需要的 CORS 属于 API 来源策略。`privateStagedTransport`
   分块的是大 corpus group，不是 PNG 字节；打开它不能解决超 4 MiB 图片。普通规模
   验收不必同时放开大 group 暂存能力。
6. **零遥测。** 当前 API/MCP 及 Auth 中初始化 Sentry 的 Lambda 在空 DSN 时拒绝
   启动，不能概括到所有后台 Lambda。评分后的 `review_answered` 另经 best-effort 路径
   写内部产品分析库，并非直接发到 Sentry；仅关闭 Sentry 不能实现零产品遥测。
   部署前需做有界的 Lingrove 服务组合/配置改造，确认不向 Sentry 等第三方发送数据，
   不收集产品行为遥测；只保留必要、脱敏的服务运维错误与授权诊断。当前代码证据：
   [backend config](../Nibomo/apps/backend/src/observability/sentry/config.ts)、
   [auth config](../Nibomo/apps/auth/src/server/sentry.ts)、
   [review events](../Nibomo/apps/backend/src/productAnalytics/serverFacts/reviewAnswers.ts)。

这些是代码核对得到的部署差距，不表示要在本地双设备模块内顺带重做托管服务。
无用户数据，测试环境使用新建库，不安排旧开发数据库或 Anki 历史兼容迁移。

## 真正部署前需要用户提供的信息

本地验收与环境方案完成后再确定：采用私有 MCP 测试连接还是直接建设 HTTPS staging、
自有域名、云项目/账号和地域、可用测试邮箱，以及哪些设备参与真实操作。凭据通过
本机受限存储或 CI secrets 使用。具体资源、成本、配置 diff 和运行步骤准备成可审查
结果后，再进行对应环境操作；当前未创建或更改任何外部资源。


私有 MCP 本地服务、SDK/HTTP/PG 验证、官方客户端与最终隔离修正现已交付，见
[私有 MCP 整合](PRIVATE_MCP_INTEGRATION.md)。这不等于真实 Tunnel 或 ChatGPT 已连接；
后续账户授权与运行步骤按该记录执行。
