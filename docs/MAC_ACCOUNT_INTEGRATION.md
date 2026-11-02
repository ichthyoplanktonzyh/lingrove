# 原生 Mac 独立账户：最终基线整合

2026-11-02。移动主线程第三波已完成，本会话继续负责后续 Mac 两波开发。

- 原交付：实现 `74b10c39`，报告 `2faf8a7a`，见
  [MAC_INDEPENDENT_ACCESS_DELIVERY.md](MAC_INDEPENDENT_ACCESS_DELIVERY.md)。
- 对齐的 main checkpoint：`e523fc8140a5f82de1b5bbf61b0a04e37669c600`。
- 合入当前 Mac 分支：`ed18a675832e8792572ec75d0e97d80b84258c02`；源码无冲突，
  `SOURCE_LAYOUT.md` 自动保留两边的独立职责说明。没有切换/修改主工作树或 push。
- 独立审查收尾修正：`34bc2637`，要求可见的连接草稿与已保存服务 pair 一致后才允许
  请求、提交或重发验证码；Return 键也遵守同一条件，取消保持可用。

## 收尾原因与职责

Keychain 清理失败时，账户服务会保留旧配置以便重试清除，且关闭恢复 gate。这是正确
的存储行为，但窗口可能仍显示用户输入的新服务。原先随后登录会使用旧服务，造成
可见目的地与请求实际目的地不一致。`AccountConfigurationPolicy` 现在对表单草稿和
已保存配置应用同一规范化规则，`AccountPaneView` 据此禁用认证入口并提示保存连接；
服务端身份、token、Keychain 和退出实现不变。回归检查覆盖未保存的 API/auth 变更、
无效草稿、未配置和等价 URL，以及清理失败后仍保留旧 scope 的实际会话场景。

## 本会话实际验证

证据根目录：
`/Users/shadow/.codex/worktrees/mac-independent-access/lingrove/build/mac-account-integration/`。

| 检查 | 结果 |
| --- | --- |
| 合并前后 Mac 编译/测试/资源/package 输入比对 | 第三波整合没有改变这些输入；原交付 24 个非说明文件指纹逐项匹配 |
| 修正后的固定 workspace/native helper 准备 | 通过，自己树的副本，原缓存只读 |
| `Lingrove Dev` Debug build | 通过，`dev-build.log` / `.xcresult` |
| app-hosted build-for-testing | 通过，`build-for-testing.log` / `.xcresult`；不是执行测试的证据 |
| 配置与目的地准入、会话竞态、原生表单重开 | 12 项执行通过，`affected-tests.log` / `.xcresult` |
| 改动四个 Swift 文件 strict lint / diff whitespace | 通过 |
| 新的 Luna/max 独立只读复查 | 首次指出目的地问题；另一位复查修正后未发现可复现实质缺陷；未代跑测试 |

没有重跑不受此次改动影响的 protocol/Keychain/移动端套件；原交付对应执行证据继续
保留。初始 `integration-proof.json` 记录修正前的合并输入比对，最终修正验证与指纹
记录在 `final-proof.json`，不能把修正后的文件称为与原交付完全相同。

所有 Apple 操作由共享 flock 串行执行，宿主与测试使用同一开发团队签名；无模拟器、
真实邮箱/云账户、用户应用操作或权限变更。本树 DerivedData 与此次准备的依赖缓存
已清理，见 `validation-cleanup.json`。独立表单渲染与数据检查已执行；完整 Settings
鼠标/键盘登录、真实 provider、真正跨进程冷启动/跨设备手动验收仍未执行。

本 checkpoint 完成的是原生账户基线。语料采用、同步/媒体和 Mac 内置复习继续按
[两波计划](MAC_INTEGRATION_PLAN.md) 推进；当前登录页面不能宣称已同步。
