# AgentMonitor AI 诊断与优化交付包

**先阅读 `AgentMonitor-Diagnostic-Report.md`。该文件是自包含的主报告，可单独交给其他 AI。**

基线：`Arcaneology/AgentMonitor @ f0e5d674006c7035e4cedb8bd06d624fc24fb0ab`。编制日期：2026-09-13。

## 当前故障

- 应用不闪退、持续运行且在 Dock 可见；菜单栏没有入口。
- Server 模式下合盖外接显示器和键鼠，拔电后可正常工作；重新接入 Mac 独立 USB-C 充电口后持续黑屏，晃鼠标后亮屏并进入登录／解锁界面。不是短暂视频闪断。

## 执行顺序

报告 S0/S1：固定版本、保留本地修改、消除普通构建的自动安装副作用。
随后补充观测，分别进行菜单栏最小对照与等闲置条件的显示器保护实验。
按证据实施修改、更新单元测试，最后显式部署并执行实机回归。
使用 `EXECUTION-RESULT-TEMPLATE.md` 汇报两个问题的独立状态。

这不是预先完成的修复补丁包。本包没有修改正式应用、提交远程仓库或调整用户系统设置；物理拔插、菜单栏点击及 macOS 运行验收仍需具备本机访问能力的执行工具与用户完成。

## 附件使用

只读诊断快照（在 macOS、解压目录中运行）：

```bash
bash tools/capture-diagnostics-readonly.sh --app /Applications/AgentMonitor.app
```

有界日志采集（不改变电源或锁屏设置）：

```bash
bash tools/capture-diagnostics-readonly.sh --seconds 180 \
  --app /Applications/AgentMonitor.app --repo "/实际的源码路径"
```

脚本只在本地写证据目录。可包含其他应用名称、路径或用户名；分享前审阅并脱敏副本。脚本没有在 macOS 实机运行，本次仅通过 Bash 语法、帮助／参数入口及 Linux 拒绝运行检查。

两个隔离复现没有真实电源操作，可使用现有 Swift 工具链运行；它们是缩减逻辑案例，不是 App 本身的测试：

```bash
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/AgentMonitor-repro.XXXXXX")"
swiftc -parse-as-library -swift-version 6 repro/power-mode-race-repro.swift \
  -o "$BUILD_DIR/race-repro"
"$BUILD_DIR/race-repro"
swift repro/server-mode-transient-state-repro.swift
```

`evidence/` 包含本次在 Linux / Swift 6.2.1 的真实运行输出。不把这些输出当作 macOS 的菜单栏或电源故障已经修复的证据。

## 安全边界

不得取消密码要求、模拟输入、自动修改受保护系统偏好、扩展 sudoers 或无限对抗系统睡眠。保留主动锁屏和主动 Sleep；保留现有电池合盖能力。历史菜单栏设置授权不等于所有系统写操作授权，执行工具仍需遵守自己的确认与权限规则。

## 文件验证

`SHA256SUMS.txt` 使用常规 SHA-256 清单格式；在交付包目录可运行 `shasum -a 256 -c SHA256SUMS.txt` 检查文件未损坏。清单验证完整性，不验证代码行为、来源信任或实机修复效果。
