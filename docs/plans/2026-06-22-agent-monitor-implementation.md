# Agent Monitor 实施计划

日期：2026-06-22

每个阶段保持可构建，并先建立失败用例再实现对应能力。后续阶段不提前加入未被当前阶段使用的抽象。

## 阶段 0：工程初始化

状态：已完成

输出：

- macOS 14+ SwiftUI `MenuBarExtra` 应用目标。
- 不显示 Dock 图标的 `LSUIElement` 配置。
- Hardened Runtime 开启、App Sandbox 关闭。
- 架构设计、ADR 和项目说明。

验证：

```bash
xcodebuild -project AgentMonitor.xcodeproj -scheme AgentMonitor \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## 阶段 1：核心模型与端口解析

状态：已完成

输出：

- `ListeningEndpoint`、`MonitoredProcess`、`MonitoredService` 等不可变模型。
- `PortCollecting` 协议与 `lsof` 字段输出解析器。
- 正常、IPv4、IPv6、UDP、缺失字段和异常退出测试样例。

验证：解析器单元测试通过；测试不依赖本机恰好运行的服务。

## 阶段 2：进程与 LaunchAgent 采集

状态：已完成

输出：

- 基于 `libproc` 的当前用户进程详情和内存采集。
- LaunchAgent plist 扫描与运行状态关联。
- 采集超时、部分失败和进程竞态处理。

验证：

- 启动受控测试子进程，能够读取 PID、工作目录和内存。
- 非当前 UID、已退出进程和无效 plist 被安全忽略。

## 阶段 3：项目识别与服务归并

状态：已完成

输出：

- 项目根目录查找和 manifest 名称解析。
- 按项目、LaunchAgent、普通用户进程归并。
- 同一进程多端口、同一项目多进程的确定性排序。

验证：使用临时目录构造各种项目标记，覆盖嵌套仓库和无 manifest 场景。

## 阶段 4：刷新状态与菜单栏 UI

状态：已完成

输出：

- `MonitorStore` 的 2 秒异步刷新循环，禁止并发刷新叠加。
- 摘要、本地项目、LaunchAgent、其他进程和空状态界面。
- 内存格式化、数据过期提示和手动刷新。

验证：

- Store 使用假采集器进行确定性单元测试。
- 在空状态、多项目、多端口、部分错误下检查菜单栏截图。
- 连续运行刷新，确认任务取消和内存稳定。

## 阶段 5：安全停止服务

状态：已完成

输出：

- 普通进程 `SIGTERM`、退出等待和二次 `SIGKILL` 确认。
- LaunchAgent `launchctl bootout`。
- UID、PID、启动时间复核和受影响端口提示。

验证：

- 只终止测试启动的子进程，并确认端口释放。
- UID 或启动时间不匹配时拒绝执行。
- 多端口进程的确认内容完整。

## 阶段 6：性能、稳定性与分发

状态：开发与本机验收已完成；Developer ID 签名、公证和 8 小时长稳测试属于发布门禁。

输出：

- 采集耗时与应用自身 CPU/内存测量。
- Release 构建及 Developer ID 签名、公证和安装说明。
- 可选的 `SMAppService` 登录启动能力；只有用户确认需要时才实现。

验证：

- 典型开发机单轮采集低于 500 ms。
- 持续运行 8 小时无刷新重入或明显内存增长。
- 干净 macOS 14+ 用户环境可以安装、启动和退出。

本机结果（2026-06-22）：

- Debug 单实例物理内存约 14.8 MB，生命周期平均 CPU 约 0.2%。
- 真实菜单栏运行时单轮采集约 34–47 ms。
- 自动刷新无重入测试、20 次连续命令执行回归测试和全量单元/集成测试通过。
- Debug 与未签名 Release 构建通过；签名、公证、干净 macOS 14+ 安装和 8 小时长稳测试需在持有 Developer ID 凭据的发布环境完成。
- 用户未要求登录启动，因此未加入 `SMAppService`。
