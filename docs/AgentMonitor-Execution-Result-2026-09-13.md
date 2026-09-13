# AgentMonitor 执行与验收结果（2026-09-13）

## 1. 版本与执行环境

| 字段 | 实际值 |
|---|---|
| 执行日期／时区 | 2026-09-13／Asia/Shanghai |
| macOS 版本／build | 26.4.1／25E253 |
| Mac 型号／架构 | MacBook Air（Mac17,4，Apple M5）／arm64；未记录序列号 |
| Xcode／SDK／Swift | Xcode 26.6（17F113）／macOS SDK 26.5／Swift 6.3.3 |
| 源码基线／最终提交／dirty 状态 | 基线 `f0e5d674006c7035e4cedb8bd06d624fc24fb0ab`；未创建提交；保留本次 tracked 与交付文档变更 |
| 实际安装路径／Bundle ID | `/Applications/AgentMonitor.app`／`com.lumos.AgentMonitor.v2` |
| 版本／构建号／可执行文件 SHA-256 | 0.1.0／4／`dcb9fd8c22bb1501feb881c329777517462667ee0487c76577f40453852688fd` |
| 签名 Identifier／CDHash | `com.lumos.AgentMonitor.v2`／`993b786242204f21dc36bb56109beb3bb1677b5a`；ad-hoc，TeamIdentifier 未设置 |
| 运行 PID／启动时间／启动方式 | 69281／2026-09-13 16:57:30 +0800／从已安装路径后台启动 |
| 显示、电源与合盖状态 | 本轮自动验证时为电池供电、开盖；独立 USB-C、外屏、合盖实机路径未执行 |
| 原始电源环境 | Battery: display sleep 60 分钟、system sleep 1 分钟；AC: display sleep 0、system sleep 0；存在 Antigravity、UURemote、ChatGPT、Claude 等其他断言，不能作为干净的 `-d` A/B 环境 |

## 2. 最终状态

```text
菜单栏：PATCHED_TECHNICALLY_VERIFIED（新正式身份未被 blocked；待用户肉眼点击确认）
插电持续黑屏／解锁：PATCHED_NOT_VERIFIED
既有电池合盖能力：NOT_VERIFIED
安全行为：NOT_VERIFIED
是否已部署：YES_LOCAL（build 4，仅本机；未提交、未推送）
```

## 3. 根因与证据

### 菜单栏

已确认机制：旧正式身份请求显示并成功创建菜单栏实例后，ControlCenter 会立即将该宿主移入 blocked list。关闭再开启 AgentMonitor 自己的系统开关并重启仍无效；相同实现改用 Debug 新身份则正常创建、跟踪且不被阻止。因此根因已收敛为旧 bundle identity 关联的 macOS ControlCenter 异常状态，而非 `MenuBarExtra` 创建失败。build 3 使用新正式身份恢复菜单栏宿主，并迁移已知用户设置。

| 证据 | 时间／产物 | 支持什么 | 不足与限制 |
|---|---|---|---|
| `clientRequestsVisibility: true`、创建 `.menuBar` instance、随后 `Moving host to blocked list` | 2026-09-13 12:50:37，ControlCenter unified log | 状态项创建链路工作，阻止发生在系统宿主层 | 日志不能替代用户肉眼点击验收 |
| AgentMonitor 系统开关执行 off/on 后重启旧标识仍被 blocked | 2026-09-13 13:35，截图与 ControlCenter log | 可逆开关不能修复旧身份状态 | 不解释 macOS 内部状态为何损坏 |
| 相同代码以 `com.lumos.AgentMonitor.Debug` 启动，创建实例且没有 blocked 记录 | 2026-09-13 15:17，ControlCenter log | 实现可工作，身份是决定变量 | Debug 不是正式安装包 |
| build 3 以 `com.lumos.AgentMonitor.v2` 启动，系统记录 `Tracking new application` 且未 blocked | 2026-09-13 15:25，ControlCenter log | 新正式身份的技术恢复链路通过 | 用户肉眼点击仍待确认 |
| AX 可见唯一 `当前温度 44°C` 项 | build 2 启动后 | 应用侧状态项对象存在 | AX 存在不能证明物理菜单栏可见 |

### 电源／屏幕／锁定

用户描述支持“插电触发熄屏或睡眠后锁定”，但本轮没有在合盖外屏环境复现，最早物理事件仍未知。代码层确认了三项会放大问题的缺陷：显示休眠保护缺少 `-d`；一次 disabled 观测会清除 Server 用户意图；手动与定时切换可重叠并覆盖结果。三项均已修复，但不能据此宣称实机故障消失。

`-d` A/B 对照未执行。当前机器有其他应用持有 display/system idle assertions，且本轮为开盖状态，会污染对照结果。

## 4. 代码变更

| 需求 | 修改文件与符号 | 行为变化 | 对应验证 |
|---|---|---|---|
| F-P01 保留用户意图 | `ServerModeController.changeMode`、`reconcileRequestedMode` | 短暂 disabled 或切换未生效不再把 Server 请求改回 Normal | transient disabled、Server mismatch 测试 |
| F-P02 显示保护 | `SystemCaffeinateManager.arguments` | Server 会话使用 `-d -i -m -s -w <pid>` | 精确参数测试 |
| F-P03 串行化 | `MonitorStore` power mode queue | 手动请求、刷新和定时协调；副作用不并发，最新请求获胜 | 并发请求、定时重叠测试 |
| F-P04 定时错误 | `reconcileSchedule` | 只在已确认成功后记录事件；失败信息保留且可重试 | schedule failure retry 测试 |
| F-M01 用户恢复入口 | `AgentMonitorApp.restoreMenuBarItem` | 主窗口提供一次性“恢复菜单栏入口”；不循环强制恢复 | 编译、完整项目测试；实屏待验 |
| F-M02 正式身份恢复 | Xcode project、`LegacyUserDefaultsMigrator` | 正式包迁移到 `com.lumos.AgentMonitor.v2`，只迁移已知设置且不覆盖新值 | Debug/Release 身份 A/B、设置迁移测试、ControlCenter log |
| F-M03 仅菜单栏运行 | `AgentMonitorApp.init`、Xcode `LSUIElement` | 激活策略由 `.regular` 恢复为 `.accessory`；运行时不再显示 Dock 图标 | 构建产物 Info.plist、进程与 Dock AX 实机检查 |
| F-D01 构建隔离 | Xcode project、`install-to-applications.sh` | 普通 build/test 不再安装、杀进程或覆盖正式包 | build 前后 hash、mtime、PID 不变 |
| F-D02 显式安装 | `build-and-install-release.sh` | 完成 Release 构建和签名验证后才显式替换，并保留旧包 | 本地 build 4 安装与签名/hash 校验 |

新增脚本不属于 Xcode target，已设为可执行。没有修改采集、Token 统计或其他业务功能。普通 build 已确认不再有自动安装副作用。

## 5. 自动化验证

完整项目测试命令退出码为 0；125 项通过、0 失败、0 跳过。xcresult：`/tmp/AgentMonitorFinalV2/Logs/Test/Test-AgentMonitor-2026.09.13_15-22-31-+0800.xcresult`（临时路径）。

新增回归覆盖 UT-P01、UT-P04、UT-P05 的主要竞争路径、UT-P10 和 UT-D01 的核心条件，以及 `-d` 参数约束。报告中其余计划用例没有被自动等同为已覆盖。

| 用例组 | 实际状态 | 证据 |
|---|---|---|
| 新增电源回归 | PASS（6 项新增/调整） | `ServerModeControllerTests`、`MonitorStoreTests` |
| 构建安装隔离 | PASS | 普通 Release build 前后安装包 hash、mtime、PID 均不变 |
| 显式 Release 安装 | PASS | build 4 产物与安装包可执行文件 hash 一致，codesign strict 通过 |
| 设置迁移 | PASS | 只迁移旧正式域的已知键、不覆盖新域已有值、Debug 不迁移 |
| 既有项目测试 | PASS | 本轮完整套件共 125 项，无失败或跳过 |
| UI 自动化／物理插拔 | NOT_RUN | 不能用单元测试替代 |

只读诊断脚本已修复 macOS 自带 Bash 3.2 下空数组触发 `unbound variable` 的问题，复跑后正常结束。

## 6. 实机结果

| 用例 | 状态 | 证据／限制 |
|---|---|---|
| RT-M01 正式启动与点击 | PASS_TECHNICAL／待用户确认 | 正式 build 4 持续运行；ControlCenter 创建新正式状态项且未 blocked；AX 唯一状态项为 `当前温度 46°C`。用户肉眼可见和点击尚未记录 |
| RT-M09 仅菜单栏运行 | PASS | 已安装 Info.plist 为 `LSUIElement=true`；PID 69281 正在运行，但只枚举 regular app 的系统 UI 列表将其报告为未运行且 PID 0，证明其激活策略不是 regular；菜单栏状态项仍存在 |
| RT-M02..M08 | NOT_RUN | 需用户确认菜单栏可见、可点，并覆盖关闭窗口、重启、外屏与合盖 |
| RT-P01..P08 | NOT_RUN | 需要合盖、外屏、独立 USB-C 充电器与受控闲置条件 |
| RT-J01 联合使用 | NOT_RUN | 两项基础用例未完成 |

## 7. 部署、回滚与权限

build 4 已安装至 `/Applications/AgentMonitor.app`；直接回滚的 build 3 位于 `/Applications/.AgentMonitor-install.wbivna/AgentMonitor.previous.backup`，build 2 位于 `/Applications/.AgentMonitor-install.1EKbtE/AgentMonitor.previous.backup`。正式进程当前路径为安装包内可执行文件。

没有修改密码要求、隐私、安全策略、sudoers 或全局电源配置；没有模拟鼠标活动。临时 `-d` 实验未启动。经用户明确同意，仅将 AgentMonitor 自己的菜单栏开关关闭再开启，并恢复为开启状态。

## 8. 剩余缺陷与下一步

1. 用户确认顶部菜单栏出现唯一温度入口并实际点击，随后覆盖关闭窗口、退出重启和外屏/合盖后的可见性。
2. 在合盖外屏场景执行 Battery→独立 USB-C 插电至少三次，记录插电前后 `pmset`、assertions 和应用命令时间线；其他持有 display sleep 断言的应用需先退出或明确作为混杂因素。
3. 验证主动锁屏、主动 Sleep、退出应用仍能正常释放保护，不能用取消安全设置换取通过。

发布判定：菜单栏技术链路已恢复，等待用户可见/点击验收；电源修复已部署但仍等待合盖、外屏和独立 USB-C 物理验收。代码尚未提交或推送。
