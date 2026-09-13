# 菜单栏入口消失的排查与验收

## 2026-09-13 本机排查

环境：macOS 26.4.1，已安装应用 `/Applications/AgentMonitor.app`。旧正式标识为 `com.lumos.AgentMonitor`，build 3 起使用 `com.lumos.AgentMonitor.v2`。

已确认：

- 应用启动后主窗口与采集器正常工作，已安装包通过 `codesign --verify --deep --strict`。
- 菜单栏项已创建，系统日志记录宽度为 69、`isVisible=1`，控制中心收到 `clientRequestsVisibility: true`。
- 控制中心随后记录 `Moving host to blocked list; (bid:com.lumos.AgentMonitor-Item-0-55947)`，并开始跟踪 blocked host。
- 系统设置“菜单栏 → 允许在菜单栏显示 → AgentMonitor”是开启状态。重新切换、重新启动应用及控制中心均未解除阻止。
- 取消两份临时构建的 LaunchServices 注册，并重新登记正式安装路径后，单独切换 AgentMonitor 的开关仍未恢复。

## 2026-09-13 build 2 复验

已通过显式 Release 安装流程部署 build 2，并从 `/Applications/AgentMonitor.app` 启动。安装包与 Release 构建产物的可执行文件 SHA-256 一致：`2a0aa02ad490eaa384375e7b54fec721bc5498f048a410a3723748b08ab8bfdc`，签名校验通过。

build 2 启动后的 ControlCenter 时间线仍然是：

```text
12:50:37.003 clientRequestsVisibility: true
12:50:37.008 Created instance ... in .menuBar
12:50:37.026 Moving host to blocked list
```

对应宿主为 `com.lumos.AgentMonitor-Item-0-29519`。系统设置中的独立 `AgentMonitor` 开关仍为开启，因此目前不能把菜单栏故障标记为已修复。build 2 新增了主窗口中的“恢复菜单栏入口”按钮，它只在用户主动操作时重新插入一次状态项，不循环重建。

12:57:10 已实际点击一次该按钮。ControlCenter 记录同一宿主的 `clientRequestsVisibility` 从 `false` 恢复为 `true`，但没有重新创建 displayable instance，也没有停止 blocked host 跟踪。因此，这个应用内恢复动作本身不能清除系统侧 blocked 状态。

这次复验同时否定了“AgentMonitor 没有独立系统开关”的假设。下一项系统侧对照应优先切换 `AgentMonitor` 自己的开关并记录前后日志；只有该对照无效且启动链路证据支持错误归属时，才测试启动者开关。

这将故障定位到系统菜单栏宿主的显示策略。不能据此将 `MenuBarExtra`、温度标签、主窗口或代码签名判定为根因。

[CodexBar 的第一手问题报告 #1945](https://github.com/steipete/CodexBar/issues/1945) 记录了同样的日志与开关表现：开发工具或终端启动的应用可能被错误归到启动者的 `trackedApplications.menuItemLocations`，启动者的关闭状态覆盖应用本身的开启状态。本机是否存在该错误关联，仍待确认；系统拒绝读取受保护的控制中心偏好文件，未修改该文件或绕过保护。

下一项验证是在用户允许后，临时开启系统设置中启动者的菜单栏显示。本次启动者为 Codex，在系统设置中显示为“ChatGPT”。记录开关前后的控制中心日志，并实际点击 AgentMonitor 图标。如果没有改善，恢复启动者原设置，不批量开启其他应用。

## 系统开关与身份 A/B

用户授权后，已将系统设置中的 AgentMonitor 菜单栏开关关闭再开启，并重启旧正式标识。旧标识仍在创建菜单栏实例后被 ControlCenter 移入 blocked list，排除了“开关界面显示为开启但尚未重新应用”这一解释。

随后用相同代码、独立 Debug 标识 `com.lumos.AgentMonitor.Debug` 做对照。ControlCenter 创建 `.menuBar` instance 并记录 `Tracking new application`，没有出现 `Moving host to blocked list`。这证明 `MenuBarExtra` 实现能够正常工作，异常与旧正式身份的系统宿主状态绑定。

build 3 将正式标识迁移为 `com.lumos.AgentMonitor.v2`。2026-09-13 15:25:28 从 `/Applications/AgentMonitor.app` 启动后，ControlCenter 记录：

```text
Host properties initialized ... clientRequestsVisibility: true
Starting to track host
Created instance ... in .menuBar
Tracking new application .bundle(com.lumos.AgentMonitor.v2)
```

新 PID 41853 的启动时间线没有 `Moving host to blocked list`。Accessibility 树中同时只有一个状态项 `当前温度 41°C`。技术链路已恢复；菜单栏的最终肉眼可见、可点击以及重启/合盖场景仍需用户实机确认。

## 开发构建隔离

Debug 使用 `com.lumos.AgentMonitor.Debug`，Release 使用 `com.lumos.AgentMonitor.v2`。测试宿主仍按构建产物路径加载，不依赖正式 bundle identifier。

这种隔离可避免后续 Debug/测试运行继续使用正式应用的菜单栏身份；它不清理已经存在的系统关联，也不能单独证明当前菜单栏问题修复。

最终验证：125 项 Debug 测试通过，0 失败、0 跳过；生成的 Debug `Info.plist` 使用独立标识。Release build 4 已安装，使用新正式标识并以 `.accessory` 激活策略运行，不再进入 Dock；菜单栏状态项仍由 ControlCenter 正常创建。

## 完成标准

1. 从已安装路径启动正式应用，菜单栏出现唯一的信号图标与温度。
2. 点击图标后，原有电源、Token、温度和服务监控面板可交互。
3. 关闭主窗口、收起面板后，菜单栏入口仍存在。
4. 退出并重新启动，入口恢复，控制中心不再将该项移入 blocked list。

编译成功、签名通过、应用自身 AX 树或 `isVisible` 单一标记均不能替代以上运行验收。macOS 26 的菜单栏项可能由 ControlCenter 托管。
