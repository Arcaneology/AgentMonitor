# AgentMonitor

一款专为本地 AI 与开发工作流设计的 macOS 菜单栏监控工具。

AgentMonitor 把电源模式、AI Token 用量、设备温度和本地服务集中在一个菜单栏面板里。它没有 Dock 图标，也不会在启动时弹出主窗口；需要查看状态或处理本地服务时，点一下菜单栏图标即可。

> 当前公开版本：**1.0.0** · 需要 **macOS 14 Sonoma 或更高版本**

## 主要功能

### 一处查看日常状态

- **电源模式**：在 Normal、Sleep 与 Server 模式之间切换，并为 Sleep、Server 设置每天或工作日定时规则。
- **AI Token 用量**：汇总 Claude、Codex、Grok 和 Gemini 的本地会话记录，可查看今天、近 24 小时与近 30 天，并按模型筛选。
- **温度监测**：直接在面板与菜单栏查看设备温度，并查看最近一小时的变化。
- **服务监测**：自动识别当前用户启动的本地网页项目、监听端口、应用进程与 LaunchAgent，并展示内存占用。

四个模块都可以折叠。折叠后仍保留最重要的状态和操作，面板会随内容自动调整高度。

### 更安全地管理本地服务

- 点击 TCP 端口即可在浏览器打开对应的本地网页。
- 停止普通进程时先请求正常退出；只有进程未响应时，才会在二次确认后提供强制停止。
- 操作前会再次核对用户、进程 ID 与启动时间，降低误停其他进程的风险。
- 只监控当前登录用户的项目和服务，不操作 root、其他用户或系统守护进程。

### 中英文界面

应用默认跟随系统语言，也可以在面板底部随时切换中文或英文；选择会自动保存。

## 安装

AgentMonitor 1.0.0 目前以源码形式公开。请先安装 Xcode，然后：

1. 克隆本仓库并用 Xcode 打开 `AgentMonitor.xcodeproj`。
2. 选择 `AgentMonitor` scheme。
3. 点击 Run 运行，或在 Product 菜单中选择 Archive 生成自己的应用。

也可以在仓库目录运行：

```bash
xcodebuild \
  -project AgentMonitor.xcodeproj \
  -scheme AgentMonitor \
  -configuration Release \
  -derivedDataPath /tmp/AgentMonitorRelease \
  CODE_SIGNING_ALLOWED=NO \
  build
```

构建结果位于 `/tmp/AgentMonitorRelease/Build/Products/Release/AgentMonitor.app`。

由于应用需要读取本机进程、端口、温度与 AI 工具的本地会话记录，当前版本没有启用 App Sandbox。请只运行来自本仓库或由你自行构建的版本。

## 使用说明

启动后，AgentMonitor 会出现在 macOS 顶部菜单栏。菜单栏图标会同时显示当前电源模式与温度；点击它即可打开完整面板。

- Token 数据来自本机已有的 Claude、Codex、Grok 与 Gemini 会话日志，不会上传到远端。
- Token 统计会保留原始记录；确定重复的数据只计算一次，无法确认的重叠记录不会计入主图。
- 服务列表聚焦本地项目、当前用户的 LaunchAgent 和本地监听端口。系统进程以及仅使用 Unix Domain Socket 的普通后台进程不会显示。
- 停止某个进程会释放它拥有的全部端口，无法只关闭其中一个 socket。

## 权限与注意事项

- 首次启用电源模式可能需要管理员授权。AgentMonitor 只会为必需的电源命令安装有限规则。
- Server 模式会阻止系统睡眠；Sleep 模式会立即让 Mac 进入睡眠。两类定时规则都只在 AgentMonitor 正在运行时执行。
- 强制停止进程可能丢失尚未保存的数据，请在确认前先保存工作。
- 部分 Mac 机型不会向应用暴露可用的温度传感器，此时温度会显示为 `--°C`。
- Token 数据依赖各 AI 工具的本地日志格式，用于本机使用分析，不等同于服务商账单。

## 隐私

AgentMonitor 在本机读取和处理监控数据，不提供云端账号、遥测或数据上传功能。Token 统计数据库保存在用户的 Application Support 目录中。项目不包含、也不需要任何 AI 服务 API 密钥。

## 从源码参与开发

运行测试：

```bash
xcodebuild \
  -project AgentMonitor.xcodeproj \
  -scheme AgentMonitor \
  -configuration Debug \
  -derivedDataPath /tmp/AgentMonitorDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

欢迎通过 Issue 报告问题，或提交 Pull Request。

## 许可协议

AgentMonitor 使用 [MIT License](LICENSE) 开源。
