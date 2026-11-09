## [⬇ 下载 macOS 安装包](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.9.0/Lingrove-0.9.0-universal.dmg)

**Lingrove 0.9.0（build 7） · macOS 14 或更新版本 · Apple Silicon / Intel 通用**

### 安装

1. 下载并打开 **Lingrove-0.9.0-universal.dmg**。
2. 将 **Lingrove.app** 拖入 **Applications（应用程序）**。
3. 推出磁盘映像，从“应用程序”启动 Lingrove。

包内应用使用 ad-hoc 签名，未经过 Apple 公证。更新采用手动安装。[详细安装说明](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.9.0/INSTALL.zh-CN.txt)

### 本次更新

- 个人语料库取消“全量词条”和“已收藏”的区分。通过应用或外部工具保存的表达进入同一个语料库，可统一浏览、搜索和管理。
- AI 捕获和 CLI 共用语料写入规划。保存语料后，仍可按需将义项加入复习。
- 支持按义项展开语料搜索结果，并可从义项的右键菜单删除。

### 升级与同步

本版使用 SQLite schema 41。旧版正式应用的数据库会保留，0.9.0 无法直接打开它。已有旧版语料的用户请保留旧应用及数据备份。Lingrove Dev 的语料迁移已单独执行，正式版和 Dev 版使用各自的数据目录。

语料同步使用 v9，须搭配支持 v9 的客户端和服务端。安装包未预置账户服务地址。

<details>
<summary>校验文件与构建信息</summary>

[SHA-256 校验](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.9.0/SHA256SUMS.txt) · [构建信息](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.9.0/build-info.json)

</details>
