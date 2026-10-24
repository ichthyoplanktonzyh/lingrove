<div align="center">

<img src=".github/assets/readme/logo.png" width="120" alt="Lingrove 拾语 Logo" />

# 拾语 · Lingrove

**macOS 本地优先的行内自动补全与伴随式语言学习工具。**  
在任意输入框的光标旁获取续写建议、即时翻译句子、查询地道表达与词典，并将生词一键同步至 Anki——全程无需离开你正在写作的应用。

[**English**](README.md) · [**简体中文**](README.zh-CN.md) · [**版本发布 (Releases)**](https://github.com/ichthyoplanktonzyh/lingrove/releases) · [**常见问题 (FAQ)**](FAQ.md) · [**语言学习机制详解**](docs/LANGUAGE_LEARNING.md) · [**问题反馈**](https://github.com/ichthyoplanktonzyh/lingrove/issues)

[![Platform](https://img.shields.io/badge/系统要求-macOS%2014%2B-blue?style=flat-square&logo=apple)](#安装指南)
[![Architecture](https://img.shields.io/badge/架构-Apple%20Silicon%20%7C%20Intel-success?style=flat-square)](#安装指南)
[![Inference](https://img.shields.io/badge/AI%20推理-本地设备端%20%7C%20自定义%20Endpoint-purple?style=flat-square)](#引擎与模型支持)
[![License: AGPL v3](https://img.shields.io/badge/开源协议-AGPLv3-orange?style=flat-square)](LICENSE)

</div>

> [!NOTE]
> **开发预览版 (v0.5)**：Lingrove 正在 `main` 分支积极开发中。你可以直接下载最新的 [v0.5.1-test.1 预发布测试包 (DMG)](https://github.com/ichthyoplanktonzyh/lingrove/releases/tag/v0.5.1-test.1) 体验，或从源码编译构建。

---

## 界面预览

<!-- 将主宣传动图或截图放置在 .github/assets/readme/hero-demo.gif -->
<div align="center">
  <img src=".github/assets/readme/hero-demo.gif" width="860" alt="Lingrove 拾语演示 — 行内自动补全与伴随式语言学习" />
</div>

<table align="center">
  <tr>
    <td width="50%" align="center">
      <!-- 将补全截图放置在 .github/assets/readme/autocomplete-demo.png -->
      <img src=".github/assets/readme/autocomplete-demo.png" alt="行内幽灵文字自动补全" />
      <br />
      <sub><b>行内自动补全</b> — 光标旁低延迟幽灵文字续写，按 Tab 逐词或整句采纳</sub>
    </td>
    <td width="50%" align="center">
      <!-- 将翻译截图放置在 .github/assets/readme/translation-demo.png -->
      <img src=".github/assets/readme/translation-demo.png" alt="行内翻译与地道表达下划线识别" />
      <br />
      <sub><b>伴随式翻译</b> — 输入停顿即预览译文，支持快捷键一键替换原文或展开地道表达</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <!-- 将词典与朗读截图放置在 .github/assets/readme/dictionary-tts-demo.png -->
      <img src=".github/assets/readme/dictionary-tts-demo.png" alt="多源词典查询、AI 语境解析与本地语音朗读" />
      <br />
      <sub><b>多源词典与朗读</b> — 内置短语库、macOS 系统词典、导入 MDX 词典与本地 Qwen3-TTS 发音</sub>
    </td>
    <td width="50%" align="center">
      <!-- 将生词本与 Anki 截图放置在 .github/assets/readme/vocabulary-anki-demo.png -->
      <img src=".github/assets/readme/vocabulary-anki-demo.png" alt="生词本管理与 Anki 制卡同步" />
      <br />
      <sub><b>生词本与 Anki 复习</b> — 点击“鱼尾”连同上下文例句收藏，通过 AnkiConnect 批量制卡并附带音频</sub>
    </td>
  </tr>
</table>

---

## 核心能力

拾语（Lingrove）将**行内自动补全**与**伴随式语言学习**作为同等核心的两大支柱，在 macOS 原生应用、浏览器及 Electron 编辑器中无缝协作：

### 1. 行内自动补全 (Inline Autocomplete)

- **光标旁幽灵续写：** 在你输入的停顿间隙，于光标右侧直接渲染灰字补全建议。支持通过 `Tab` 及自定义快捷键按单词、短语或整段采纳。
- **三种推理后端任选：** 支持 **Apple Intelligence**、应用内原生 **`llama.cpp` (GGUF 本地模型)**，或你自行配置的 **OpenAI 兼容 API 端点**。
- **多维上下文与精细控制：** 自由调节建议长度、词内补全与流式输出；可选开启本地屏幕 OCR 视觉上下文与剪贴板参考；支持全局暂停或按指定 App 独立开关。

### 2. 边写边学语言 (Language Learning While Writing)

- **行内即时翻译与一键替换：** 用母语或外语写作时稍作停顿，光标旁即会浮现不抢焦点的目标语言预览卡片。按 `Control+Option+T` 可直接用译文替换原句，按 `Option+T` 展开双语详情。
- **离线短语识别与多源词典：** 内置 11.5 MB Wiktionary/Kaikki 离线短语词库，无需额外请求大模型即可自动为固定搭配和习语标注下划线。双击任意单词或短语，即可联查**内置短语库**、**macOS 系统词典**、**导入的 `MDX`/`MDD` 词典**，或发起结合当前句子的 **AI 语境释义**。
- **无打扰语音朗读 (TTS)：** 点击卡片上的小喇叭即可朗读句子或词条（不抢占打字焦点）。支持 **macOS 系统语音**、基于 `llama.cpp` 的本地 **Qwen3-TTS Base 模型**（支持参考音频音色克隆与流式 PCM 播放），或兼容 `/audio/speech` 的远程接口。
- **“鱼尾”生词本：** 点击卡片上的鱼尾图标，即可将词条连同当前遇到的原句与译文作为例句一键收藏。在菜单栏生词本窗口中按稳定词义（Sense）归类管理、编辑笔记、打标签或导出 JSON。
- **Anki 制卡与批量同步：** 预览识别卡（Recognition）与填空卡（Gap），一键复用 TTS 生成词条与例句发音，并通过 [AnkiConnect](https://ankiweb.net/shared/info/2055492159) 单条或批量发送/更新至 **Anki Desktop**（保留已有复习进度与卡片 ID）。

### 辅助写作工具

- **快捷输入增强：** 内置本地**拼写自动纠错 (Autocorrect)**、`:emoji:` 表情快速插入，以及用于行内数学计算与单位换算的 `/` **斜杠宏 (Slash Macros)**。
- **15 种界面语言：** 在 **设置 → 通用 → 界面语言** 中支持简体中文（显示为“拾语”）、繁体中文（“拾語”）、English 等 15 种语言切换，与补全及翻译的目标语言互不干扰。

> 想了解提示词模板、模型 Token 预算、词典优先级规则或输入法（IME）兼容细节？请查阅 [**语言学习机制与模型详解 (docs/LANGUAGE_LEARNING.md)**](docs/LANGUAGE_LEARNING.md)。

---

## 引擎与模型支持

每项能力均可**独立配置**本地模型或远程服务——为翻译配置远程 API 绝不会将你的自动补全按键发送到云端，反之亦然。

| 任务类型 | 本地设备端方案 (On-Device) | 自定义远程接口 (Endpoint) |
| :--- | :--- | :--- |
| **自动补全** | • 内置 `llama.cpp`（基座 GGUF 模型）<br>• Apple Intelligence *（需受支持的 Mac 及 macOS 26+）* | 兼容 OpenAI 的 `/v1/completions` 或 `/v1/chat/completions` |
| **句子翻译** | • 内置 `llama.cpp`（支持 `Hy-MT2 1.8B / 7B`、`TranslateGemma 4B`） | 兼容 OpenAI 的 Chat 接口 |
| **AI 语境解析** | • 内置 `llama.cpp`（通用指令微调 GGUF 模型） | 兼容 OpenAI 的 Chat 接口 |
| **语音朗读 (TTS)** | • Apple macOS 系统语音<br>• 本地 `Qwen3-TTS Base`（`llama.cpp`，约 1.48 GB，支持参考音频） | 兼容 OpenAI 的 `/audio/speech` 接口 |
| **短语识别与 OCR** | • 始终在本地运行（Wiktionary/Kaikki 离线词库 + macOS Vision OCR） | — |

---

## 安装指南

### 系统要求

- **操作系统：** macOS 14.0 (Sonoma) 或更高版本 *（仅在使用 Apple Intelligence 补全时需 macOS 26+）*。
- **硬件架构：** 推荐使用 Apple Silicon (`arm64`) 运行本地 GGUF 与 TTS 推理；安装包为同时支持 Apple Silicon 与 Intel (`x86_64`) 的通用二进制版本。

### 方式一：下载测试版安装包（普通用户）

1. 前往 [**v0.5.1-test.1 预发布页面**](https://github.com/ichthyoplanktonzyh/lingrove/releases/tag/v0.5.1-test.1) 下载 `Lingrove-0.5.1-test-universal.dmg`。
2. 双击打开 DMG，将 **Lingrove.app** 拖入 **Applications（应用程序）** 文件夹，推出磁盘映像后从“应用程序”启动。
3. 由于当前测试版使用临时签名（尚未进行 Apple 公证），首次打开若提示“无法验证开发者”，请前往 **系统设置 → 隐私与安全性**，在底部安全性区域点击 **仍要打开 (Open Anyway)**。
4. 详细图文与功能体验步骤请参阅 [**简体中文安装与快速体验指南**](assets/testing/INSTALL.zh-CN.txt)（DMG 内亦附带为 `INSTALL.txt`）。

### 方式二：从源码编译（开发者）

```sh
git clone https://github.com/ichthyoplanktonzyh/lingrove.git
cd lingrove
scripts/dev-setup.sh
scripts/prepare_lingrove_workspace.sh
open build/lingrove-dependencies/Lingrove.xcworkspace
```

- 在 Xcode 中选择 **Lingrove Dev** Scheme 可编译 **Lingrove Dev.app**（拥有独立的偏好设置、钥匙串与日志目录，避免污染日常使用环境）；选择 **Lingrove** Scheme 则编译正式版 **Lingrove.app**。
- 本地开发签名使用你自己的 Apple 开发者团队配置（保存在已被 gitignore 的 `LocalSigning.xcconfig` 中）。
- 更多构建与测试说明请参考 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [RELEASING.md](RELEASING.md)。

---

## 系统权限说明

拾语仅在对应功能启用时请求必要的 macOS 系统权限。**所有密码框与安全输入字段均被严格拦截，绝不读取或插入任何内容。**

| 权限名称 | 是否必需 | 用途说明 |
| :--- | :--- | :--- |
| **辅助功能 (Accessibility)** | **必需** | 读取当前焦点输入框上下文、定位光标位置，以及将采纳的补全或译文写回输入框。 |
| **输入监控 (Input Monitoring)** | **必需** | 在不抢占焦点的情况下感知打字停顿、取消键 (`Esc`) 与采纳快捷键 (`Tab`)。 |
| **屏幕录制 (Screen Recording)** | *可选* | 仅在开启“屏幕视觉上下文”、“框选区域 OCR 翻译”或“鼠标取词 OCR 回退”时按需使用。 |

---

## 隐私与数据安全

- **默认本地运行：** Apple Intelligence、本地 `llama.cpp` GGUF 模型、屏幕截图与 Vision OCR、离线短语识别与词典查询均在 Mac 本机完成。
- **远程请求严格受限：** 只有当你主动将某项任务配置为远程 Endpoint 时，该任务的有限文本上下文才会发送至你指定的服务端。语言学习请求绝不附带无关剪贴板内容或打字历史。
- **输入历史加密且默认关闭：** 输入历史记录默认关闭；开启后数据以加密归档形式存储在本地，密钥保存在 macOS 钥匙串（Keychain）中，可随时在设置中一键清空。
- **零遥测与追踪：** 无需注册账号，无内置数据统计（Analytics）或远程崩溃上传。
- **应用数据完全隔离：** `Lingrove`、`Lingrove Dev` 与原 `Cotabby` 使用各自独立的偏好设置、钥匙串服务与存储目录，互不覆盖。详见 [FORK.md](FORK.md)。

---

## 项目文档与社区

- [**FAQ.md**](FAQ.md) — 关于安装、离线使用、权限与更新机制的常见问题解答
- [**docs/LANGUAGE_LEARNING.md**](docs/LANGUAGE_LEARNING.md) — 翻译交互细节、多源词典机制、TTS 生命周期与模型 Token 预算说明
- [**ARCHITECTURE.md**](ARCHITECTURE.md) & [**SOURCE_LAYOUT.md**](SOURCE_LAYOUT.md) — 架构边界设计与源码目录导航
- [**CONTRIBUTING.md**](CONTRIBUTING.md) & [**CODE_OF_CONDUCT.md**](CODE_OF_CONDUCT.md) — 参与贡献、运行评测套件与提交 Issue / PR 指南

---

## 维护者、项目渊源与开源协议

**Lingrove（拾语）** 由 [ichthyoplanktonzyh](https://github.com/ichthyoplanktonzyh) 独立维护。  
本项目衍生自 [FuJacob/Cotabby](https://github.com/FuJacob/cotabby)（由 [FuJacob](https://github.com/FuJacob) 创建，并与 [jam-cai](https://github.com/jam-cai)、[akramj13](https://github.com/akramj13)、McHamster 等贡献者共同开发），原作著作权与贡献均予以完整保留和致谢。

项目基于 [CotabbyInference](https://github.com/FuJacob/cotabbyinference)、[llama.cpp](https://github.com/ggml-org/llama.cpp)、[Sparkle](https://github.com/sparkle-project/Sparkle)、[swift-log](https://github.com/apple/swift-log)、[LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin-Modern)、[SymSpell](https://github.com/wolfgarbe/SymSpell) 及 [GitHub gemoji](https://github.com/github/gemoji) 等优秀开源组件构建。内置词典与短语数据的许可说明详见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) 与 [learning-expressions.NOTICE.md](Lingrove/Resources/learning-expressions.NOTICE.md)。

本项目遵循 [**GNU Affero General Public License v3.0 (AGPLv3)**](LICENSE) 开源协议。第三方库、词典数据与模型权重保留其各自的原始许可条款。
