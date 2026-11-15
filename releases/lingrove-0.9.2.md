## [⬇ 下载 macOS 安装包](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.9.2/Lingrove-0.9.2-universal.dmg)

**Lingrove 0.9.2 · macOS 14 或更新版本 · Apple Silicon / Intel**

1. 下载并打开 DMG。
2. 退出旧版 Lingrove，将 **Lingrove.app** 拖入「应用程序」并替换。
3. 推出磁盘映像，再从「应用程序」启动。

此版本使用临时签名，未经 Apple 公证，需手动安装和更新。首次启动与权限设置请看
[安装说明](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.9.2/INSTALL.zh-CN.txt)。

### 本次更新

- 改善 Lingrove 运行时的打字流畅性：普通按键通过独立输入线程放行，减少重复的焦点查询。
- 保留连续 Tab 接受补全和翻译快捷键的校验；实体键盘验收已确认这两项正常工作。
- 优化大语料库的浏览、搜索、批量编辑和保存，减少重复读取与整库准备。
- 改善笔记编辑、复习状态与搜索投影的一致性，保留已有复习记录和手工修改。

本次没有调整本地模型、采样参数或推理调度，不能据此推断功耗下降。机身电气噪声的原因尚未确认；真实拼音组字仍未完成专项验收。

### 更新与验证范围

数据库版本保持 SQLite schema 41，语料同步为 v9。重要数据请先备份；从较早数据库格式更新前请阅读安装说明。

输入修复通过 Release 构建和 238 项回归测试，并有用户实际打字体感及实体快捷键验收。Universal 构建不等于已在 Intel 真机完成运行验收；全新机器的 Gatekeeper 安装路径也未做人工验收。

[SHA-256 校验](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.9.2/SHA256SUMS.txt) · [构建来源与签名信息](https://github.com/ichthyoplanktonzyh/lingrove/releases/download/v0.9.2/build-info.json)
