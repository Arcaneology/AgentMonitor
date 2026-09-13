# Agent Monitor

Agent Monitor 是一个面向 macOS 14+ 的原生菜单栏应用，用于自动发现当前用户的本地服务、开发服务器和监听端口，并展示实时内存占用。

## 已实现

- 每 2 秒发现当前用户的 TCP 监听端口和 UDP 本地端点。
- 展示进程 PID、可执行文件、工作目录和实时 physical footprint 内存。
- 识别正在运行的 `~/Library/LaunchAgents` 用户 daemon。
- 根据 `.git`、`package.json`、`pyproject.toml`、`go.mod` 和 `Cargo.toml` 自动识别并归并本地网页项目。
- 独立扫描 Claude / Codex / Grok / Gemini 会话日志统计 Token 用量；今天、近 24 小时和近 30 天均可查看总览或单模型。柱子每格为 1 亿 Token，颜色表示模型族，同族深浅表示预设的相对强弱。输入、缓存、输出在悬浮详情中查看。
- CC Switch 数据库只在手动校准时读取，不参与日常监测。历史原始记录保留；确定重复的记录只计一次，疑似重叠记录单列待核对，不计入主图。
- 普通进程先发送 `SIGTERM`，超时后才提供经二次确认的 `SIGKILL`；LaunchAgent 使用 `launchctl bootout`。
- 停止前重新校验 UID、PID 和进程启动时间，避免 PID 复用导致误操作。

应用只监控和操作当前登录用户的进程，不处理 root、其他用户或系统 daemon。服务监测只列出本地项目与用户 LaunchAgent，无法归属到其中任一的监听端口不再展示；进程列表只包含应用进程，来自 `/System`、`/usr/libexec`、`/usr/bin` 等系统目录的进程会被过滤。未注册为用户 LaunchAgent、且只监听 Unix Domain Socket 的普通后台进程不会进入列表。停止一个进程会释放该进程拥有的全部端口，不能只关闭其中一个 socket。

## 本地构建

```bash
xcodebuild \
  -project AgentMonitor.xcodeproj \
  -scheme AgentMonitor \
  -configuration Debug \
  -derivedDataPath /tmp/AgentMonitorDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

也可以直接使用 Xcode 打开 `AgentMonitor.xcodeproj` 并运行 `AgentMonitor` scheme。`Release` 构建成功后会把 `AgentMonitor.app` 安装到 `/Applications`；Debug / 测试构建不会覆盖日常使用的应用。

Debug 构建使用独立的 bundle identifier `com.lumos.AgentMonitor.Debug`，避免 Xcode 临时实例与 `/Applications` 中的 Release 应用共享 LaunchServices 和菜单栏状态记录；Release 仍使用 `com.lumos.AgentMonitor`。

## 测试

```bash
xcodebuild \
  -project AgentMonitor.xcodeproj \
  -scheme AgentMonitor \
  -configuration Debug \
  -derivedDataPath /tmp/AgentMonitorDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

本机测试覆盖真实随机端口网页服务的自动发现、`lsof` 解析、项目归并、Token 用量聚合、定时状态、安全停止和命令超时。

Token 的数据口径、数据库副本核查和隔离界面验收见 [Token 用量验收说明](docs/token-usage-acceptance.md)。

## 文档

- [架构设计](docs/plans/2026-06-22-agent-monitor-design.md)
- [实施计划](docs/plans/2026-06-22-agent-monitor-implementation.md)
- [签名、公证与发布](docs/release.md)
- [架构决策记录](docs/adr/README.md)
