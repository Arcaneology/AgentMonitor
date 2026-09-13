# 菜单栏入口消失的排查与验收

## 2026-09-13 本机排查

环境：macOS 26.4.1，已安装应用 `/Applications/AgentMonitor.app`，正式标识 `com.lumos.AgentMonitor`。

已确认：

- 应用启动后主窗口与采集器正常工作，已安装包通过 `codesign --verify --deep --strict`。
- 菜单栏项已创建，系统日志记录宽度为 69、`isVisible=1`，控制中心收到 `clientRequestsVisibility: true`。
- 控制中心随后记录 `Moving host to blocked list; (bid:com.lumos.AgentMonitor-Item-0-55947)`，并开始跟踪 blocked host。
- 系统设置“菜单栏 → 允许在菜单栏显示 → AgentMonitor”是开启状态。重新切换、重新启动应用及控制中心均未解除阻止。
- 取消两份临时构建的 LaunchServices 注册，并重新登记正式安装路径后，单独切换 AgentMonitor 的开关仍未恢复。

这将故障定位到系统菜单栏宿主的显示策略。不能据此将 `MenuBarExtra`、温度标签、主窗口或代码签名判定为根因。

[CodexBar 的第一手问题报告 #1945](https://github.com/steipete/CodexBar/issues/1945) 记录了同样的日志与开关表现：开发工具或终端启动的应用可能被错误归到启动者的 `trackedApplications.menuItemLocations`，启动者的关闭状态覆盖应用本身的开启状态。本机是否存在该错误关联，仍待确认；系统拒绝读取受保护的控制中心偏好文件，未修改该文件或绕过保护。

下一项验证是在用户允许后，临时开启系统设置中启动者的菜单栏显示。本次启动者为 Codex，在系统设置中显示为“ChatGPT”。记录开关前后的控制中心日志，并实际点击 AgentMonitor 图标。如果没有改善，恢复启动者原设置，不批量开启其他应用。

## 开发构建隔离

Debug 使用 `com.lumos.AgentMonitor.Debug`，Release 保持 `com.lumos.AgentMonitor`。测试宿主仍按构建产物路径加载，不依赖正式 bundle identifier。

这种隔离可避免后续 Debug/测试运行继续使用正式应用的菜单栏身份；它不清理已经存在的系统关联，也不能单独证明当前菜单栏问题修复。

本次验证：119 项 Debug 测试通过，0 失败；生成的 Debug `Info.plist` 使用独立标识，Release 构建设置仍为正式标识。未重新安装正式版。

## 完成标准

1. 从已安装路径启动正式应用，菜单栏出现唯一的信号图标与温度。
2. 点击图标后，原有电源、Token、温度和服务监控面板可交互。
3. 关闭主窗口、收起面板后，菜单栏入口仍存在。
4. 退出并重新启动，入口恢复，控制中心不再将该项移入 blocked list。

编译成功、签名通过、应用自身 AX 树或 `isVisible` 单一标记均不能替代以上运行验收。macOS 26 的菜单栏项可能由 ControlCenter 托管。
