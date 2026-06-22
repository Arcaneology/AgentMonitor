# Agent Monitor

Agent Monitor 是一个面向 macOS 14+ 的原生菜单栏应用，用于自动发现当前用户的本地服务、开发服务器和监听端口，并展示实时内存占用。

## 已实现

- 每 2 秒发现当前用户的 TCP 监听端口和 UDP 本地端点。
- 展示进程 PID、可执行文件、工作目录和实时 physical footprint 内存。
- 识别正在运行的 `~/Library/LaunchAgents` 用户 daemon。
- 根据 `.git`、`package.json`、`pyproject.toml`、`go.mod` 和 `Cargo.toml` 自动识别并归并本地网页项目。
- 普通进程先发送 `SIGTERM`，超时后才提供经二次确认的 `SIGKILL`；LaunchAgent 使用 `launchctl bootout`。
- 停止前重新校验 UID、PID 和进程启动时间，避免 PID 复用导致误操作。

应用只监控和操作当前登录用户的进程，不处理 root、其他用户或系统 daemon。停止一个进程会释放该进程拥有的全部端口，不能只关闭其中一个 socket。

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

也可以直接使用 Xcode 打开 `AgentMonitor.xcodeproj` 并运行 `AgentMonitor` scheme。

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

本机测试覆盖真实随机端口网页服务的自动发现、`lsof` 解析、项目归并、定时状态、安全停止和命令超时。

## 文档

- [架构设计](docs/plans/2026-06-22-agent-monitor-design.md)
- [实施计划](docs/plans/2026-06-22-agent-monitor-implementation.md)
- [签名、公证与发布](docs/release.md)
- [架构决策记录](docs/adr/README.md)
