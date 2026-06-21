# Agent Monitor

Agent Monitor 是一个面向 macOS 14+ 的原生菜单栏应用，用于自动发现当前用户的本地服务、开发服务器和监听端口，并展示实时内存占用。

当前仓库处于项目初始化阶段，只包含可运行的菜单栏应用骨架。监控能力会按照实施计划分阶段加入。

## 本地构建

```bash
xcodebuild \
  -project AgentMonitor.xcodeproj \
  -scheme AgentMonitor \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

也可以直接使用 Xcode 打开 `AgentMonitor.xcodeproj` 并运行 `AgentMonitor` scheme。

## 文档

- [架构设计](docs/plans/2026-06-22-agent-monitor-design.md)
- [实施计划](docs/plans/2026-06-22-agent-monitor-implementation.md)
- [架构决策记录](docs/adr/README.md)

