# Mac 预览卡收藏等待修复

2026-11-03。用户在实际开发版中反馈：预览卡点击加入生词本有明显等待，旧版近乎立即完成。
用户明确要求停止额外耗时测量，直接修复。本修复没有延迟基准、耗时数字或性能阈值结论。

## 原因与修正

统一仓储接入时丢失了旧 archive 的 revision 缓存。`VocabularyStore` 在准入、写入后、
应用结果和收到变更通知时反复调用完整 `repository.snapshot()`；这些调用位于 MainActor，
会读出所有语料行、解码分类目录并校验完整文档。Archive 的 perform/load 又重复读取。
收藏实际仍是本地保存，没有等待登录、模型生成或云端 ACK。

- `Queries/LingroveNotebookEngine+NotebookVersion.swift` 新增不可变 Sendable 值
  `LingroveNotebookVersion`：workspace、notebook、revision、generation。共享引擎在一个
  deferred read transaction 中读出四个字段，不读取内容行，也不申请 writer lock。
  它是读取准入/缓存标识，不能替代文档或事务内写入授权。
- app 长期持有的 `MacNotebookRepository.version()` 为 UI 提供该轻量边界；新工作区
  尚无 notebook 时才初始化空 notebook。完整文档读取保留在需要内容的原入口。
- `VocabularyArchive` actor 复用已提交的完整 snapshot，仅在四个版本字段全部一致时
  命中。另一连接保存、换 book、切账户以及切走再返回都会失效；原 SQL writer 继续读取
  当前文档、检查完整 baseline 和 CAS，缓存不允许覆盖并发修改。
- `VocabularyStore` 的准入和提交后检查改读元数据。收到通知时先比较身份/版本；本地
  成功结果已经应用的情况下，排队的重复 reload 直接结束。旧 lifetime 的任务不改新
  lifetime 的 task tracking。按钮仍在实际事务成功后变为已收藏。

这些文件分别拥有共享 SQL 元数据、app 资源入口、后台内容快照和 UI 通知职责；没有把
数据库 handle 或事务跨 actor 传递，也没有把业务数据改为第二份缓存持久化。

## 必要正确性验证

证据：本集成工作树 `build/mac-save-fix/`。

| 实际检查 | 结果 |
| --- | --- |
| `EngineScopedCommandIntegrationTests` | 9 passed；新增 metadata/内容验证分离及 generation 检查，已有 CAS、取消、评分/撤销保护继续通过 |
| 选定的 Mac archive/store 集成 | 3 passed / 0 failed / 0 skipped；外部连接写入后的缓存失效、无通知账户切换拒绝、收藏/编辑/媒体/备份/重启及旧 draft/Anki/解释回调隔离 |
| 完整 Mac app-hosted build-for-testing | 通过，只计编译 |
| 三个改动的 Mac 生产文件 strict lint | 通过 |

独立 Luna/max 只读审查未发现实质问题，没有写代码或运行测量。首次 package 编译发现
新查询缺少 `import LingroveNotebook`，补齐后以上检查实际执行通过，原失败日志保留。

Release Dev 构建、签名、开发包路径和清理见同目录 `app.json`、`cleanup.json`。
用户的体感由更新后的开发版实际使用确认；不把正确性检查或 Release 构建当作耗时测量。
没有重新运行手机 E2E、全套业务检查、模型 eval，也没有 push、部署或数据库迁移。
