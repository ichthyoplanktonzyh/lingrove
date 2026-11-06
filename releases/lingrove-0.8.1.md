## [⬇ 下载 macOS 安装包](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.8.1/Lingrove-0.8.1-universal.dmg)

**Lingrove 0.8.1 · macOS 14 或更新版本 · Apple Silicon / Intel 通用 · 59.5 MB**

自动补全与写作中的语言学习，让表达、收藏和复习连在一起。

### 安装

1. 点击上方链接，下载并打开 **Lingrove-0.8.1-universal.dmg**。
2. 将 **Lingrove.app** 拖入 **Applications（应用程序）**。
3. 推出磁盘映像，从“应用程序”启动 Lingrove。更新前请先退出旧版并备份重要数据。

[详细安装说明](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.8.1/INSTALL.zh-CN.txt)

> 当前安装包使用临时签名，尚未经过 Apple Developer ID 签名或公证。首次启动可能需要在
> “系统设置 → 隐私与安全性”中选择“仍要打开”。目前采用手动更新。

**升级说明：**0.7.2 及更早版本的旧语料库目前不会自动迁移，原文件会保留。
已使用新存储结构的 1.0.0 用户可继续沿用同一份语料库；此次版本号调整不会重建数据库。

## 本次更新

- 保留本地优先的自动补全、逐词接受、写作翻译、阅读翻译、鼠标取词、区域 OCR、词典和朗读。
- 语料库统一为“个人语料库 / 复习 / 进度”三个入口，保留原有表达、义项、分类、图谱和检索。
- 新增 Lingrove 内置复习：明确加入后生成卡片，支持笔记、笔记类型及卡片模板编辑；保存表达
  不会自动加入复习。Anki 作为独立可选目标，可经 AnkiConnect 发送相同笔记和模板。
- 新增当前工作区的内置复习统计、历史与计划，保留撤销及历史记录，Anki 进度单独管理。
- 新增原生账户入口、邮箱验证码登录、服务配置和可选同步，完善账户隔离、持久化重试及媒体同步。
  本安装包未预置账户服务；使用账户功能需明确配置可用服务。登录不会自动启用同步或上传本地语料。
- 改进语料保存性能、共享存储与导出、复习材料和媒体持久化，统一原生设置与窗口导航。
- 完善 CLI 捕获回执、服务身份验证和持久 MCP 适配器，修复表达候选解析、导航与插入。
- 更新品牌呈现、复习预设本地化和产品文档。

## 数据与网络

本地语料库、复习和进度无需账户即可使用。模型、语义索引和 OCR 在 Mac 上运行。
明确选择 Endpoint 或网络词典后，相应任务内容会发送至所配置服务；明确开启账户同步后，
所选语料、相关媒体及复习数据会发送至所配置服务。自动补全上下文和未保存的翻译不进入语料同步。

Lingrove 与 Lingrove Dev 的数据、设置及权限独立，本包不会自动导入 Dev 数据。
临时签名更新后可能需要重新授予辅助功能、输入监控或屏幕录制权限。

<details>
<summary>校验文件、构建信息与验证结果</summary>

[下载 SHA-256 校验文件](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.8.1/SHA256SUMS.txt) · [查看构建信息](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.8.1/build-info.json)

## 验证

此次调整将产品版本号统一为 0.8.1（build 6），功能代码、数据目录和数据库结构沿用此前已验证的版本。
本次已通过双架构 Release 构建与 17 项打包回归测试；安装包的挂载内容、嵌套签名、
所有可执行文件的双架构及本地 SHA-256 检查均通过。四个远端附件的 SHA-256 均与本地文件一致。
此次未重复执行业务测试；此前功能回归记录见仓库 RELEASING.md。

build-info.json 记录精确源码提交、版本、架构和签名状态；源码构建输入干净，单独进行的
视频工程编辑不进入安装包。SHA256SUMS.txt 提供安装包下载完整性校验。

Intel 实机与其他 Mac 下载后的首次安装流程未完成本次验收。Apple Intelligence 需要受支持的
Mac 和 macOS 26 或更新版本。安装包不包含模型权重、用户数据或服务商凭据。

</details>

反馈请至 [GitHub Issues](https://github.com/ichthyoplanktonzyh/lingrove/issues)，请勿上传私人输入或密钥。
