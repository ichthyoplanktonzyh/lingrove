# 语料实体同步契约（内部验证阶段）

当前实现包含服务端带类型的语料写入/读取模块与原生纯值转换模块，尚未开放 HTTP/MCP，
也未接入移动端网络上传、分页拉取或账户迁移。完整目标仍按 [移动计划](MOBILE_NOTEBOOK_PLAN.md) 推进。
字段定义以 [`fields.ts`](../Nibomo/apps/backend/src/notebook/corpus/fields.ts) 为准，修改
与身份契约以 [`contract.ts`](../Nibomo/apps/backend/src/notebook/corpus/contract.ts) 为准。
它们没有复用 SQLite codec 的 opaque payload、索引或整本备份格式。

## 身份、顺序与材料

词条、义项、来源、出现位置、解释判断、收藏及意义/分类关系分别拥有身份。子记录
使用有业务含义的 owner 引用；选择、解释和证据连接的组合 key 保留既有身份范围。
`rank` 表示领域数组顺序，同 rank 的独立新增项按稳定身份排序，原生适配须在组装文档
时重新形成连续位置。父记录不复制一个会覆盖并发新增项的完整子 ID 数组。

UUID 使用小写字符串。未知学习语言保持 null，不能因界面语言而改成英语；分类语言
标签是另一种值。明确的 presence 字段区分原文档中的 nil 与空内容/复习卡/模板集合。
设备专用的 Anki binding、active binding、音频回执、provider 地址、缓存文件名和
持久化索引不进入这些字段。计划和模板保留准备材料及用户选择，存在计划不表示
选入内置复习。解释的本地 `occurrenceIdentity` 不作为远程字段；原生转换重建当前已
接受例句的派生键（包括未收藏例句），并保留候选/拒绝判断的本地身份快照。
完整窗口和应用存储提交仍由宿主负责。

时间使用明确的 Foundation reference seconds：自 2001-01-01T00:00:00Z 起的有限
Double 秒数，保留分数精度。它不是 Unix 秒或毫秒。服务器提交序号、实体版本和
分类目录的 Int64 版本使用十进制字符串，避免 JavaScript 数值精度截断；本地文档
revision 继续独立保护本机提交。

## 提交与冲突

[`store.ts`](../Nibomo/apps/backend/src/notebook/corpus/store.ts) 在现有完整操作组事务中
计划所有修改，再校验包含未修改记录的最终图，最后一起写入规范实体、变更身份和
确认。创建不能覆盖已有身份或复活删除记录；删除要求完整的当前实体版本。旧原文
和 occurrence 保持不可变，修正内容通过新的证据身份及明确的引用变更表达。

普通字段按服务器字段版本合并：旧版本请求能修改未被另一端修改的字段，同字段
不同值则冲突。`updatedAt` 只是时间来源信息，不能把编辑器对其他义项的时间戳更新
当成业务变化。明确的 add-only 操作保留独立新增的注释/引用；字段 reset 版本阻止
旧追加请求越过一次明确替换，重新加入另一端刚移除的内容。新例句通过独立来源、
occurrence、解释判断与收藏连接增加，无需重写父义项。

整组校验不替调用者静默删除证据或修理导入。变更已引用的解释证据时，业务命令须
明确撤回并将意义映射标为 proposed，或明确重新确认该证据。内置分类从创建、归属
转换到修改均需要可信服务端目录路径；客户端 JSON 不提供这个权限。用户自定义
分类和覆盖继续单独管理。

## 存储与后续传输

规范行一次只保存一个实体，字段由完整 schema 校验。正文使用 PostgreSQL `json`，
以保留原模型允许的转义字符；`jsonb` 会拒绝 U+0000，见 [PostgreSQL 18 JSON 文档](https://www.postgresql.org/docs/18/datatype-json.html)。
本实现不在 SQL 中提取或转换正文 JSON；字段合并和关系检查由带类型模块负责。

提交日志只保留变更身份，避免建立永久的私人正文编辑历史。后续 pull 必须先固定、
物化并原子应用完整当前状态窗口，不能把身份日志当作历史值回放，见
[ADR 0002](adr/0002-corpus-current-state-windows.md)。内部固定窗口、原生分阶段暂存及
本地原子应用已实现；网络/媒体传输、上传确认、受管理练习及真实客户端验收仍需完成。
不得把超过
单组上限的语料简单拆成会暴露半个关系图的独立提交。

## 原生文档边界

[`LingroveNotebookSync`](../Packages/LingroveNotebook/Sources/LingroveNotebookSync/VocabularyWireProjection.swift)
直接读取规范领域数组，以明确的公开字段形成远程实体；不借用本地 SQL payload 或备份。
重组入口只接受宿主已确认完整的窗口，拒绝缺根、未消费的子行、未知字段和无效领域图，
不调用会修理/裁剪内容的 `prepare`。它无法自行判断传输是否遗漏一个无引用的独立记录。

私有状态按服务端生词本归属单独返回。绑定保留原始义项身份并可沿 `mergedFrom` 追溯；
音频回执仅在计划身份与公开材料均匹配时附着。远端已删除或改写的计划不会被私有状态
重建，未匹配值作为 `unattachedPrivateState` 返回，宿主必须将它与文档一起持久保存。
这个状态和整体 projection 刻意不提供 Codable，公开实体不能意外夹带工具地址、绑定
或音频文件名。当前模块没有网络、数据库、账户接管、复习选入或 UI 副作用。

历史本地校验允许同一 owner 下重复解释 UUID，而远程身份为 `ownerID:explanationID`。
这种文档在投影时明确报 `duplicateEntity`，不会自动去重、改 UUID 或丢掉一条解释；
后续接管流程必须向用户呈现无法表示的输入，保留原本地数据。不同 owner 复用解释
UUID 仍合法。转换成功也不替代服务端组大小、权限、版本与最终图校验。

## 固定读取窗口

[`windows/store.ts`](../Nibomo/apps/backend/src/notebook/corpus/windows/store.ts) 在与写入相同
的生词本锁内捕获当前值与高水位。bootstrap 返回全部规范记录，包括 tombstone；
incremental 返回 `(afterSequence, highWaterSequence]` 内受影响身份的当前记录，每个
身份只出现一次。只含 key 的日志从不充当历史正文。未来日志裁剪须另加保留水位与
bootstrap 回退，目前不会悄悄跳过旧 key。

页是 typed `CorpusRecord[]` JSON 的连续 UTF-8 字节流，固定最多 256 KiB，通过 base64
传输，可跨 JSON token/实体/码点。下载者先验证并拼接原始字节，再解码 JSON；不能
逐页当成实体数组解析。`CorpusRecord` 包含版本、删除身份和字段时钟，与原生公开
`VocabularyWireEntity` 不同。宿主先完整更新自己的服务端 shadow，再提取 live entities
给领域重组器；本地未上传变更、私有状态和游标仍须在同一提交边界保留。

页 SHA 使用原始 bytes。顺序描述符是 `ordinal:sha256:byteCount` 加一个换行，按从零
开始的连续 ordinal 拼接后求 SHA256。manifest 使用
[`contract.ts`](../Nibomo/apps/backend/src/notebook/corpus/windows/contract.ts) 中固定 ASCII
行顺序，包含账户（UTF-8 base64url）、工作区、生词本、replica、窗口身份、模式、起止
游标、initialized、到期毫秒、记录/页/字节总数和描述符 SHA；最后也有换行。全部页和
完整 manifest 校验成功之前，不得推进本地游标。相同参数的未过期窗口可以重放，
重放不续期；release 只是幂等缓存删除，不能证明客户端下载或本地提交成功。

空书也有 `[]` 的一页两字节，`initialized` 只由不可删除的规范根决定；它为 false 时
不能清空已有本地书。十五分钟 lease 到期后拒绝读取；membership 删除立即级联清理。
维护任务每批最多处理 128 页（32 MiB）和 100 个已空 header，不清活窗口。代码复用
既有每分钟任务，尚未部署；失败会保留重试，同时继续原媒体工作负载，不上传语料遥测。
单次服务端物化仍持有书锁，内存包含当前实体及其 JSON/UTF-8 表示；没有宣称大规模
吞吐或真实多设备同步已验收。

原生 `VocabularyWireWindowAccumulator` 只验证分块与记录 framing，返回不可自行构造
的 `VocabularyWireVerifiedWindow`。`VocabularyWireServerShadow` 另行验证增量基线、
已知身份/字段时钟单调性与最终完整图；它不是本地编辑文档。iOS schema 29 的
`LingroveNotebookWindowStore` 仅持久暂存页，完成后复核绑定 generation 和租约；
该返回值不代表本地 apply、book 采用、pending 确认或游标已经提交。

## 原生三方合并与原子应用

`VocabularyWireRebase` 以已确认的服务端 shadow 为祖先，将本地公开投影的变化叠加到
新窗口。未初始化服务端仅以空文档充当逻辑祖先，不因此清空本地语料或虚构服务端根。
不同字段可合并；同字段不同值、并发创建同一身份、已更改对象的删除均明确冲突。
字段改后恢复原值仍保留版本边界，不能只比较当前文本来放过旧编辑。add-only 字段
只有在两端保留原前缀且服务端没有越过基线版本进行 reset 时才合并追加；不把任意
数组并集当成移除/重排的替代。合并后的完整图仍须严格验证，不自动修复孤儿关系。

iOS `LingroveNotebookSyncStore` 将准备与提交分开：准备读取文档和远端基线，事务外
计算候选及验证/暂存给定图片；提交再次比较本地与远端修订，检查账户/workspace
generation 和租约，再原子保存实体、文档修订、服务端记录/删除身份、游标和私有余项。
schema 30 的本地完整性摘要绑定这些远端头部、记录数量和原始存储字节，拒绝缺失
独立行或损坏游标。完成写入后再检查租约；过期或失败时全部数据库改动回滚。

本地 notebook ID 保持不变，另存可信账户/工作区下的远端 book/replica 对应，保留
卡片来源和复习归属。既有绑定不同的远端书须走明确迁移，不能借一次 pull 换绑。
相同 manifest 的重复提交返回最新本地文档，包含首次提交后的本地编辑。Anki/音频
未附着状态通过宿主私有格式保存；公开实体仍不含这些值。

普通下载应用不等于上传确认：历史本地语料日志、受管理 Card/评分 hold 和旧 outbox
保持原样，远端变化也不作为新用户编辑写入语料日志。下节的确认覆盖分支仅在完整
服务端确认与覆盖窗口都验证后清理已捕获的语料日志；受管理复习 lane 继续独立保留。
当前边界尚未接入 HTTP、账户迁移或冲突处理界面，也不证明多设备同步已经完成。

## 冻结上传与确认覆盖

`VocabularyWireUploadPlanner` 比较确认基线与当前公开投影，为 create、patch、delete
选择明确实体版本；追加只取原数组之后的后缀，替换/移除保持显式 set。不可变来源
不能换正文沿用旧身份。私有 Anki/audio 状态和 SQLite 索引/行 payload 不进入请求。
当前单组仍受服务端 10,000 成员/2 MiB 契约及本机编码上限约束，超限整组报错；
尚未建设大图上传暂存，不能拆成会露出半图的任意批次。

iOS schema 31 只保留一份未完成的冻结组，保存精确请求字节、公开发送目标、基线
游标和本地 journal 头部覆盖，并以摘要绑定账户、两端 book、replica 和全部字节。
超时/重启/同账户重连复用同一请求和 IDs；迟到回调仍须持有有效 generation ticket。
没有 receipt 时阻止普通 apply 推进旧基线；另一个任务已准备好的普通 apply 也会被
提交阶段的冻结组比较拒绝。无公开差异时返回 nil，局部日志尚保留，不冒充上传确认。

receipt 须精确匹配 group/book、有序完整成员和大于发送基线的 Int64 序号。持久保存
receipt 仍不删日志；随后窗口须覆盖该序号及每个成员的规范记录。尚未被后续写入
替换的已知字段须与请求相符。append 保留旧基线前缀和已发送项，允许另一副本先有
某个相同追加值：例如旧 `[a]`、另一端先加 `c`、本端 add `[b,c]`，规范值为 `[a,c,b]`。
这与任意数组并集不同，较晚的 reset 仍是不能跨过的边界。

合并使用冻结发送目标作为逻辑祖先、原始确认基线作为真实 shadow，并只对已写字段
使用 receipt 的时钟边界；发送后的本地编辑和追加继续保留。未发送的 timestamp-only
变化不写入逻辑祖先，恢复冻结数据也重新验证这一点。规范值始终来自覆盖窗口，
不根据 receipt 伪造服务端字段或游标。

最终事务原子完成文档/私有余项/shadow 更新、精确捕获 journal 头部的退役、简短
receipt ledger 插入和冻结组删除。较新的 journal、受管理 Card/评分 hold 及旧 outbox
不在该退役集合。完成 ledger 不留语料正文；下一组已存在时，旧确认仍可幂等返回。

当前只实现正向确认的内部边界，生产 HTTP 调度尚未接入。权限、超时或未知失败
必须保留冻结请求；单次冲突响应也不能证明旧请求永远不会提交。接调度前还需建设
服务端可验证的终态拒绝/撤销协议，防止超时重试仍在服务端执行时过早改组。冲突
处理界面、无公开差异日志的本地收口、大图暂存和完整多端网络验收继续按 M3 推进。
终态决定必须与该 book 的提交串行，绑定原 group/replica/请求摘要，并阻止同一旧组
后续再提交；保留可回放的状态元数据即可，不新增永久语料正文历史。
