# AgentMonitor

macOS 14+ 原生菜单栏应用（SwiftUI，纯菜单栏附件模式，无 Dock 图标），用于发现当前用户的本地服务、监听端口和进程内存，并统计各 Agent 的 Token 用量。功能说明见 [README.md](README.md)。

## 目录

- `AgentMonitor/App` — 应用入口与菜单栏界面
- `AgentMonitor/Core` — 服务发现、进程采集、Token 统计、电源模式等核心逻辑
- `AgentMonitorTests` — XCTest 测试
- `scripts` — 发布安装与 Token 审计脚本
- `docs` — 设计、ADR、发布流程、验收说明与执行记录

## 构建与测试

```bash
xcodebuild -project AgentMonitor.xcodeproj -scheme AgentMonitor -configuration Debug \
  -derivedDataPath /tmp/AgentMonitorDerivedData CODE_SIGNING_ALLOWED=NO build

xcodebuild -project AgentMonitor.xcodeproj -scheme AgentMonitor -configuration Debug \
  -derivedDataPath /tmp/AgentMonitorDerivedData CODE_SIGNING_ALLOWED=NO test
```

- 普通构建和测试不得改动 `/Applications`。只有用户明确要求时才运行 `./scripts/build-and-install-release.sh` 安装正式版。
- Debug 与正式版使用不同 Bundle ID（`com.lumos.AgentMonitor.Debug` / `com.lumos.AgentMonitor.v2`），不要合并。

## 约束

- 只监控和操作当前登录用户的进程；停止进程前必须重新校验 UID、PID 和启动时间。
- CC Switch 数据库只在手动校准时读取，不参与日常监测。
- 新增 Swift 文件需同步登记到 `AgentMonitor.xcodeproj/project.pbxproj`。
- 行为或口径变化时同步更新 README 与 `docs/` 下对应文档；架构级决策补充 ADR。

## 自动提交（Auto Commit）

由 AI 自行判断提交时机，无需每次询问用户。

**应当提交的时机** — 满足以下全部条件时立即提交：

1. 完成了一个逻辑完整、可独立描述的变更单元（一个功能、一个缺陷修复、一次重构、一组文档更新）。
2. 已通过验证：代码改动至少 `build` 成功，涉及逻辑的改动 `test` 通过；纯文档改动无需构建。
3. 相关文档已随代码同步更新。

**不应提交的情况**：

- 构建失败、测试失败，或改动处于半成品状态。
- 仍在探索、调试或等待用户确认方案。
- 变更中包含密钥、令牌、个人数据或构建产物（`build/`、`DerivedData/`、`.DS_Store`、`xcuserdata/` 等）。

**提交规范**：

- 一个提交只包含一个逻辑单元；多个不相关改动拆成多个提交。
- 只暂存本次任务自己修改的文件，逐个 `git add <path>`，不使用 `git add -A` / `git add .`。会话开始前已存在的未提交改动属于用户，不得混入提交，也不得回退。
- 提交信息用英文祈使句，首行不超过 72 字符，风格与现有历史一致（如 `Restore menu bar identity and serialize power mode switching`）；必要时正文说明原因与验证方式。
- 不使用 `--amend`、`--no-verify`，不改写历史。
- 自动提交仅限本地 commit：`push`、建分支合并、打 tag、发布等操作仍需用户明确要求。
- 提交后在回复中简要告知提交哈希与内容。
