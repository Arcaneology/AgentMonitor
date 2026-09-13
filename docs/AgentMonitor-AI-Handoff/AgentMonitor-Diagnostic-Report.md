---
title: AgentMonitor 综合诊断与执行优化报告
report_version: "1.0"
report_date: "2026-09-13"
audience: 具备代码编辑、macOS 本机诊断和测试能力的 AI 编程工具
repository: Arcaneology/AgentMonitor
reviewed_branch: main
reviewed_commit: f0e5d674006c7035e4cedb8bd06d624fc24fb0ab
status: 诊断与执行交接；尚未完成应用修复或 macOS 实机验收
language: zh-CN
---

# AgentMonitor 综合诊断与执行优化报告

> **执行摘要：需要解决两项用户实际故障。第一，应用持续运行、Dock 中可见，但菜单栏入口缺失。第二，Server 模式下合盖使用外屏时，从电池供电重新接入 Mac 独立 USB-C 充电口，会持续黑屏；移动鼠标后亮屏并出现登录／解锁界面。不是闪退，也不是仅闪一下的显示链路黑屏。**
>
> 本报告合并前述审查、用户后续纠正、源码复核与两项隔离逻辑复现。**最新用户描述覆盖旧报告中的冲突描述；源码中存在缺陷，不等于这些缺陷已经被证明是实机故障的唯一根因。**

## 0. 接手 AI 的任务与完成边界

### 0.1 工作目标

恢复正式应用的菜单栏入口，并避免在用户主动选择的外接显示器 Server 工作场景中，因重新插电产生非预期熄屏、睡眠或锁屏。保留已经可用的“合盖、电池供电、外接显示器和键鼠继续工作”能力，不得通过取消锁屏密码要求、模拟用户活动或降低系统安全保护来掩盖问题。

本报告是执行规格，而不是修复已完成的声明。接手工具应先核实本地代码和实际运行版本，再按实验结果实施最小修改，交付代码、测试、部署与实机证据。当前用户请求是编写报告；本次报告编制没有对远程仓库、正式安装包或用户系统设置执行写操作。

### 0.2 必须遵守的执行原则

1. **先固定运行版本，再改代码。**不能把 DerivedData 中的新产物当作 `/Applications` 中实际运行的版本。
2. **先收集基线，再修复。**不能一边复现一边让另一个 Release 构建终止并替换正在观察的应用。
3. **每次只改变一个主要实验变量。**不得同时更换正式 Bundle ID、重写菜单栏、清空偏好和重签名，然后把偶然恢复称为根因定位。
4. **分别验收两个故障。**菜单栏修复不代表电源修复，电源逻辑单元测试通过不代表实机不黑屏。
5. **明确安全与权限范围。**历史对话中用户允许调整菜单栏设置；这不是修改密码策略、读取受保护隐私数据库、扩展 sudo 权限或绕过当前工具确认规则的通用授权。
6. **没有 macOS 或原硬件时，完成可做的代码与隔离测试，标明实机待验收。**不得伪造截图、日志、测试结果、已部署状态或“完全修复”结论。

### 0.3 非目标

不重构 Token 统计、模型分类、服务发现等与本次问题无关的业务。温度无读数、面板布局、构建安装、电源并发及定时结果处理在本次相关回归范围内；整个 Token 扫描器、私有温度接口及全部系统命令实现不因此被视为已完成全面安全审计。

## 1. 用户事实：采用这一版，避免旧上下文污染

| 编号 | 最新事实 | 对执行的影响 |
|---|---|---|
| U-M1 | App 可以打开，不闪退，持续运行，Dock 中可见。 | 当前不是进程退出问题；Dock 图标是用户描述，执行时仍记录 PID 和运行路径。 |
| U-M2 | 只有菜单栏中没有应用入口；以前可以显示。 | 排查状态项插入、系统显示策略、应用身份和外屏环境。 |
| U-M3 | 用户此前重启电脑后仍未恢复。 | 单纯重启不是已验证有效的解决办法。 |
| U-P1 | MacBook 通常合盖，通过 USB 连接外接显示器和键鼠。 | 必须在合盖外屏条件验收，不能只在开盖时测试。 |
| U-P2 | Server 模式下拔掉充电电源后，外屏已经能连续工作。 | AC→Battery 是必须保留的现有能力。 |
| U-P3 | 充电线插在 Mac 独立 USB-C 口，不是向显示器／扩展坞的 PD 输入插电。 | 不再优先按“插拔扩展坞供电导致视频链路重连”处理。独立口并不排除一切系统或控制器相关性。 |
| U-P4 | 重新接电不是闪黑，而是屏幕持续黑；需要晃鼠标才亮。 | 优先区分显示器休眠、系统睡眠与会话锁定。 |
| U-P5 | 亮屏后出现 login／解锁界面，类似合盖再开盖。 | 说明需核对锁定相关事件；不能仅凭此认定整机睡眠或用户被注销。 |
| U-P6 | 希望与菜单栏问题一并优化。 | 同一交付批次，但分别跟踪根因、补丁和验收证据。 |

**明确作废或降级的旧描述：**“程序随即自行退出”不适用于当前复现；“短暂闪黑”不准确；“充电接在哪不明确”已得到回答；“肯定是扩展坞重新协商”没有证据；“一定错误关联到 ChatGPT”尚未在本机证明。

尚未确认但可由本机诊断补齐的项目：Mac 型号与芯片、当前 macOS 精确版本和 build、Xcode 版本、屏幕分辨率与刷新率、视频连接拓扑、是否有其他显示器供电来源、是否启用菜单栏管理器、AC/Battery 的空闲熄屏设置、系统日志实际睡眠原因。不要重复询问用户已经回答的独立充电口、持续黑屏、需要解锁等事实。

## 2. 版本基线、来源与证据等级

### 2.1 代码基线

本次通过 GitHub 连接器重新确认，读取到的 `main` 最新提交仍为：

```text
f0e5d674006c7035e4cedb8bd06d624fc24fb0ab
2026-09-13T01:55:13Z / 2026-09-13 09:55:13 UTC+8
Refine service monitoring filters and record open menu bar defect
```

该提交消息承认菜单栏缺陷未修复，并包含旧的“进程随即自行退出”描述。**执行时应修正文档中的现状描述，不应为了修改历史说明而重写已发布 Git 历史。**[R01]

历史排查记录写的是 macOS **26.4.1**；这是此前诊断环境记录，不是本报告确认的当前系统版本。执行机应使用 `sw_vers` 重新记录。[R02]

### 2.2 证据分类

| 标记 | 含义 | 使用限制 |
|---|---|---|
| U | 用户直接描述的行为 | 作为目标复现；不自动转换成内核或硬件根因。 |
| C | 已读取源码可直接确认的行为 | 证明代码路径存在，不证明特定事件触发了该路径。 |
| R | 本次重新运行的隔离复现 | 只证明被抽取逻辑，不能代替完整应用测试。 |
| D | 仓库文档或历史对话记录的现场证据 | 原始完整日志／截图未重新采集，需现场复核。 |
| A | Apple 文档、手册等一手资料 | 归档资料需结合当前 SDK 与系统验证。 |
| H | 待验证假设 | 必须附验证方法，不得写成已确认根因。 |
| V | 与本故障直接对应的实机验收证据 | 本次报告尚未获得。 |

### 2.3 本次实际完成的验证

重新读取了仓库版本与关键入口、电源控制器；复核了历史两份交接文档；查询了相关 Apple 文档。另在 **Linux x86_64 / Swift 6.2.1** 环境重新运行了附件中的两项缩减复现，结果见 `evidence/`。

```text
Repository gating logic: maximum concurrent setMode calls = 2
With missing flag restored: maximum concurrent setMode calls = 1

observed=enabled, requested=server, caffeinate=true
observed=disabled, requested=normal, caffeinate=false
observed=enabled, requested=normal, caffeinate=false
PASS: unknown alone does not trigger this branch.
```

复现使用假控制器／注入状态，没有调用真实 `pmset`、`caffeinate`、IOKit 或修改系统设置。**没有重新运行仓库完整的 119 项 macOS 测试，没有运行 AppKit／SwiftUI，没有证明插电时 `SleepDisabled` 实际产生过禁用读数。**历史“119 项通过”仅保留为历史测试记录。[R02][R04][R05][R06]

## 3. 代码定位图与现有运行路径

所有文件引用以第 2 节提交为基准。接手时如果本地 HEAD 已更新，重新定位符号并复核差异，不要机械应用旧行号。

| 文件 | 重点符号或内容 | 作用 |
|---|---|---|
| `AgentMonitor/App/AgentMonitorApp.swift` | `init`、`body`、`AppDependencies.make` | `.regular` 激活策略、主窗口、`MenuBarExtra`、采集器启动与测试宿主防护。 |
| `AgentMonitor/App/MenuBarContentView.swift` | `content`、`collapsedContentHeight`、`expandedContentHeight` | 420 点宽面板，内容区固定 960／1200 点，主窗口还包一层滚动。 |
| `AgentMonitor/App/TemperatureChartView.swift` | `TemperatureMenuBarLabel` | 温度无读数仍显示 `--°C`。 |
| `AgentMonitor/Core/State/MonitorStore.swift` | `start`、`refreshServerMode`、`selectPowerMode`、`setPowerMode`、`applyPowerMode` | UI 状态、电源约 30 秒轮询、手动操作协调。 |
| `AgentMonitor/Core/System/ServerModeController.swift` | `refresh`、`reconcileRequestedMode`、`setMode`、`reconcileSchedule` | 全局睡眠设置、用户请求、定时执行、状态协调。 |
| 同上 | `SystemCaffeinateManager`、`IOKitSleepDisabledReader` | `caffeinate` 子进程、`SleepDisabled` 属性读取。 |
| `AgentMonitorTests/ServerModeControllerTests.swift` | `testRefreshClearsStaleServerRequestWhenSleepDisabledIsDisabled` 等 | 有测试明确固化“一次禁用读数就清掉 Server”的旧行为。 |
| `AgentMonitor.xcodeproj/project.pbxproj` | `Install to Applications`、Debug/Release 配置 | 构建阶段自动安装、Bundle ID、`LSUIElement`。 |
| `scripts/install-to-applications.sh` | 暂存、签名、SIGTERM、替换与注册 | 自动部署有副作用，复制发生在最终 CodeSign 前。 |
| `docs/menu-bar-visibility.md` | 故障记录与完成标准 | ControlCenter 阻止显示的历史证据与未证实的归属假设。 |

现有入口结构如下，不存在本次已发现的“局部变量持有 NSStatusItem 后立即释放”错误，因为当前实现是 SwiftUI `MenuBarExtra`。[R03]

```text
AgentMonitorApp
  ├─ Window("Agent Monitor") → ScrollView → MenuBarContentView
  ├─ MenuBarExtra(.window)
  │    ├─ label: 系统图标 + 温度文本（无数据也有占位）
  │    └─ MenuBarContentView
  └─ 依赖与采集器
       └─ MonitorStore
            ├─ 手动选择 → selectPowerMode / setPowerMode
            └─ 电源刷新 → reconcileSchedule 或 refresh
                 └─ ServerModeController
                      ├─ pmset disablesleep
                      ├─ IOKit 读取 SleepDisabled
                      └─ caffeinate -i -m -s -w <App PID>
```

`MonitorStore` 的电源循环是执行后等待约 30 秒再运行，**不是严格整点的 30 秒采样器，也不是已实现的插电事件回调**。事件持续时间、任务延迟及系统睡眠都会影响实际间隔。[R05]

## 4. 已有排查结果：保留证据，不重复无效动作

历史文档记录：应用请求创建菜单栏项，宽度约 69，`isVisible=1`，ControlCenter 收到 `clientRequestsVisibility: true`，随后记录：

```text
Moving host to blocked list;
(bid:com.lumos.AgentMonitor-Item-0-55947)
```

其中 PID 和状态项名称是历史样例，**不是可复制到当前进程的定位值**。系统设置里的 AgentMonitor 开关当时为开启；切换该开关、重新启动应用和 ControlCenter、注销两份临时构建并重新登记安装路径，都没有在记录中证明恢复。[R02]

这支持“系统显示策略处于直接阻断链路中”，不支持“程序、安装、签名、启动身份绝对没有问题”。此前将 Debug 改成 `com.lumos.AgentMonitor.Debug` 是隔离措施，不清除既有错误关联。新增主窗口是兜底入口，不等于菜单栏修复。

CodexBar issue #1945 提供过类似的第一手复现：启动者的菜单栏允许显示归属错误可以覆盖应用自己的开关；报告者做过更换 Bundle ID 的对照。它是可比较的外部案例，不是当前机器的根因证明。不要将该案例中修改私有偏好文件的做法直接用于本机，更不能据此要求用户关闭隐私保护。[A06]

## 5. 已确认代码行为与修复优先级

优先级含义：P1 为本轮必须处理或验证的核心行为／工程风险；P2 为相关可靠性与使用体验修正。优先级不是根因概率。

### F-M01：菜单栏缺少可观察、可恢复的显示生命周期（P1，C）

当前仅声明 `MenuBarExtra`，没有显式插入状态的诊断、恢复入口或完整状态记录。默认 `MenuBarExtra` 本来就能正常工作，**缺少 `isInserted` 绑定不是根因证据**。官方提供绑定版本，用户移除项目时绑定可变化；恢复策略应尊重用户选择，不应循环强制设回 `true`。[R03][A07]

`LSUIElement=YES` 与启动时 `.regular` 并存也不能直接认定非法。当前 Dock 可见与主窗口是可用诊断通道，先保留；是否最终恢复无 Dock 的纯菜单栏体验，属于独立产品决策，不应在故障未收敛时顺带改动。[R03][R07]

### F-D01：普通 Release 构建会终止并替换正式应用（P1，C）

`Install to Applications` 阶段带 `alwaysOutOfDate=1`。脚本在符合条件的 Release 构建中，对 `/Applications/AgentMonitor.app` 对应进程发送 SIGTERM，替换应用，最后只提示重新打开。[R07][R08]

这是实在的部署副作用，会干扰复现；但用户已确认当前进程存活，**不得继续把它作为本次菜单栏缺失的主要解释**。修复要求：普通 build/test 不触碰正式安装，部署成为单独、显式、可回滚的步骤。`SKIP_INSTALL=YES` 本身不能保证阻止自定义脚本；必须移除／显式门控脚本调用并验证。

### F-D02：安装复制发生在最终签名前（P1，C）

脚本注释明确写明运行在 Xcode 最后 CodeSign 前。当前补救只在签名 Identifier 与 Bundle ID 不同时，对暂存包进行 ad-hoc 重签。相同 Identifier 不代表内容封印仍有效；即使签名完整性通过，也不证明 ControlCenter 的归属正确。[R08][A05]

修复要求：完成构建和最终签名后再安装；安装脚本负责验证，不临时创造另一份签名状态。记录源码提交、是否有本地未提交修改、可执行文件哈希、Bundle ID、签名 Identifier、designated requirement、版本号及安装时间。当前 `0.1.0 / build 1` 不足以区分多轮产物。[R07]

### F-P01：未持有显示器防空闲休眠保护（P1，C + H）

当前参数：

```swift
process.arguments = ["-i", "-m", "-s", "-w", String(appPID)]
```

没有 `-d`。Apple 手册将系统空闲、磁盘空闲、交流供电下的系统休眠保护和显示器休眠保护区分开来；`-s` 的供电限制不意味着整个 `caffeinate` 子进程在电池供电时退出。[R04][A01]

对“后台 Server”而言，没有 `-d` 未必是错误；对本用户明确要求的“合盖外屏不中断工作”，它是需要验证的功能缺口。**缺少 `-d` 已确认，缺少 `-d` 导致本次插电黑屏尚未确认。**不要以永久保持所有屏幕亮着为代价默默改变整个 Server 模式。

### F-P02：一次禁用读数会清除用户 Server 请求（P1，C + R）

```swift
if settingsStore.requestedMode == .server, state == .disabled {
    settingsStore.requestedMode = .normal
}
```

`refresh()` 随后停止 `caffeinate`。注入 `enabled → disabled → enabled` 时，请求被清除、子进程保护被停止，后来恢复启用读数也不会恢复原请求。本次隔离复现重现了该行为；`unknown` 单独出现不会触发同一分支。[R04]

现有 `testRefreshClearsStaleServerRequestWhenSleepDisabledIsDisabled` 断言这一行为。因此要先改变需求与状态模型，再改实现和测试；不能把旧测试通过当作符合新场景的证据。[R06]

修复要求：用户意图、系统观测和当前保护会话分离。单个异常样本不应静默清除活跃 Server 请求；持续失败应标注真实失效并有限恢复。不得无限对抗用户在系统／其他工具中的明确更改。后台 30 秒循环存在该风险，不足以证明它能解释“每次插电即刻黑屏”。

### F-P03：异步电源入口的并发门控不完整（P1，C + R）

`selectPowerMode()` 先设置 `isChangingServerMode=true`，异步入口 `setPowerMode()` 却直接进入 `applyPowerMode()`；后者只在退出时清理标记。隔离测试中，两个异步请求可同时进入假控制器；补上标记后该缩减案例的同时执行数从 2 降到 1。[R05]

最低修正是入口门控对齐。完整修正要覆盖手动、定时、重试、健康检查及旧结果写回；`@MainActor` 或一个会在 `await` 时重入的 actor，不能单独保证整项操作互斥。现有 `Task.yield()` 忙等不应成为长期排队方案。这里证明的是 async 操作重叠，不是跨线程内存数据竞争。

### F-P04：定时失败会被成功提示覆盖，并提前记为已执行（P1，C）

`reconcileSchedule()` 先写 `lastAppliedScheduleEventID`，再执行 `setMode()`，最后无条件覆盖为“已按定时规则切换”。失败可能被隐藏，同一事件也可能不再处理。[R04]

修复要求：返回结构化执行结果；区分 attempted 与 succeeded；保留错误；定义有限重试。`sleepnow` 是有副作用的一次性动作，响应丢失或超时不等于未执行，不可自动重复睡眠。

### F-P05：全局观测与本应用所有权存在混用风险（P2，C）

首次没有保存请求、但系统 `SleepDisabled` 已启用时，`refresh()` 会把请求迁移到 Server。这可能是旧版迁移设计，也可能接管了其他工具造成的全局状态；当前证据无法区分。[R04]

进入／退出 Server、重启应用、恢复旧配置时，必须区分“由本应用主动设置”和“仅观察到系统如此”。`caffeinate -w` 的进程绑定与 `pmset` 修改不是同一种资源生命周期；不要假定应用退出后全部全局设置自动还原。退出恢复前先验证当前状态与所有权，避免覆盖另一个工具后来的修改。[A01][A02]

### F-U01：面板高度没有总视口上限（P2，C）

内容固定为 960／1200 点，还要叠加头部、底部、确认区；主窗口外层另有 ScrollView。部分外屏可用区域无法容纳，可能产生截断或多层滚动。**它不是已证实的菜单栏图标缺失根因。**[R03][R09]

修复要求：区分总高度和可滚动内容高度，依据实际承载屏幕的 `visibleFrame` 限制总视口；保留一层主体滚动。不能无条件用 `NSScreen.main` 推定状态项所在显示器。

### 5.1 本次未发现／不得凭空追加的“根因”

温度无读数已有 `--°C` 占位，且还有系统图标；不支持“温度为空所以没有任何标签”。`SystemCaffeinateManager.start()` 有运行保护，不支持“每次刷新都重启 caffeinate”。当前入口没有手写状态项局部引用，不支持“确定是 NSStatusItem 被释放”。这些都可以在最小实验中排除，但不能当作源码已证实的问题。[R03][R04][R10]

## 6. 菜单栏故障：假设与分支判定

| 假设 | 现有支持 | 最有区分力的验证 | 不能推出什么 |
|---|---|---|---|
| H-M1：应用身份相关显示归属异常 | 历史 ControlCenter blocked-list、应用自身开关开启。[R02] | 相同实现，原 Bundle ID 与临时诊断 ID 对照；记录启动者、签名和安装路径。 | 不能直接认定关联到 ChatGPT，也不能只凭换 ID 成功宣称正式版修复。 |
| H-M2：SwiftUI 场景／插入状态／状态恢复异常 | 当前缺乏相关日志；历史曾合并两个入口。[R03][R11] | 固定文字的最小 MenuBarExtra，与相同实验条件下的 NSStatusItem 对照。 | 没有 `isInserted` 不是定罪证据；AppKit 不能绕过系统禁止显示。 |
| H-M3：空间不足、外屏／Space／隐藏管理器导致不可见 | 用户经常合盖外屏；现场拓扑未完整记录。 | 各屏幕可用区域、前台 App 菜单长度、全屏和菜单栏管理器状态的受控对照。 | App 自身 AX 树缺条目不等于系统全局不存在；也不能把全部缺失都归为刘海遮挡。 |
| H-M4：运行的不是预期修复版本 | 自动安装、最终签名前复制、固定版本号。[R07][R08] | 安装路径、PID、可执行文件 hash、源码构建指纹一一对应。 | 代码已经保存／构建成功不代表安装包已更新。 |
| H-M5：复杂标签或内容初始化触发异常 | 仅为待排除项；标签有有效占位。 | 最小固定标签成功后逐一恢复温度、内容、采集器。 | 巨大面板尺寸不等于已解释入口消失。 |

**停止无信息量循环：**相同版本、相同身份、相同开关状态下反复重启 ControlCenter，不能代替上述分支实验。每次重复必须改变一个明确条件或获取新的证据。

## 7. 电源故障：把“黑屏”拆成可验证事件

### 7.1 三种主要事件及一种次要分支

| 分类 | 预期证据 | 与当前描述的关系 | 下一步 |
|---|---|---|---|
| H-P1：显示器空闲休眠后锁定 | 屏幕睡眠事件，整机仍运行；防显示器断言缺失；锁屏设置要求密码。 | 优先验证；当前没有 `-d`，移动鼠标后要求解锁与此相容，但尚不证明。 | 等空闲条件的 `-d` 对照；捕获屏幕事件与断言。 |
| H-P2：合盖或其他原因导致整机睡眠 | 系统 Sleep/Wake 时间线、原因、休眠期间相关事件中断。 | 用户感觉像合盖再开盖，与此也相容。 | 记录 `SleepDisabled`、系统睡眠原因、合盖状态和命令顺序。 |
| H-P3：会话主动锁定／屏保／策略 | 会话锁定或屏保证据，可能没有整机睡眠。 | login 界面不等于整机睡眠，更不必然是注销。 | 检查同时间的应用操作、系统策略和用户动作；保留安全设置。 |
| H-P4：显示拓扑或 USB-C 控制器重配置 | 显示器离线／重新上线、模式变化、USB 设备变化与事件同步。 | 独立充电口和持续黑屏后解锁，使纯链路闪断优先级下降；不绝对排除。 | 仅在对应日志支持时深入，避免先建议购买线材或重置显示器。 |

Apple 提供电池与电源适配器各自的闲置熄屏设置，以及显示器关闭／屏保后要求密码的设置。因此 login 界面不能作为整机睡眠的单一证据。[A03]

Apple 归档 QA 区分 idle sleep 与 forced sleep；通用空闲断言不能被当作所有合盖、主动睡眠或安全性睡眠路径的拦截器。该文档不是对 macOS 26.4.1 或其他现代版本内部实现的逐条保证，需本机验证。[A04]

### 7.2 需要验证的应用层事件链

```text
分支 A（假设）：电源来源改变
→ 屏幕空闲策略重新生效 / 对应显示器保护不足
→ 屏幕睡眠 → 原有安全策略锁定 → 鼠标唤醒后解锁界面

分支 B（假设）：电源来源改变
→ 实际读到 SleepDisabled=disabled
→ 本应用清掉 Server → 停止 caffeinate
→ 显示器或系统睡眠 → 解锁界面

分支 C（假设）：系统直接触发合盖／睡眠／锁定
→ App 的轮询只在事后读到状态变化
```

**注意因果方向。**如果保护停止发生在黑屏之后，不能把它当作黑屏起因。系统日志时间精度和缓冲延迟可能不一致；应用事件要同时记录墙上时钟、单调时间和事件序号。没有读取到日志／属性，记录 unknown，不可写“绝对没有发生”。

## 8. 第一阶段：固定基线并建立证据采集

### 8.1 安全启动顺序

先检查本地 `git status`，保留用户未提交修改，不执行硬重置、强制切分支或覆盖。读取实际安装包，确认 PID 和可执行路径。**不要先运行 Release build**，因为原工程的安装阶段可能终止正式应用。

推荐先在单独分支或工作树中移除普通 build 的安装副作用，并确认 Debug 保持独立身份。单独记录这个工程修正；随后才做菜单栏和电源实验。诊断版本禁止自动执行真实电源计划、扫描真实敏感数据或安装 sudoers。

现有 `AGENT_MONITOR_QA` 不代表完全无副作用：入口在非测试宿主下仍会启动温度和进程采集；测试宿主的 start 防护也不等于所有真实对象都没有被初始化。最小诊断构建要从依赖创建路径明确注入空实现，而不是只沿用 QA 标志。[R03]

### 8.2 使用附件的只读采集脚本

```bash
# 在 macOS 上运行。脚本路径按解压位置填写。
bash tools/capture-diagnostics-readonly.sh \
  --app /Applications/AgentMonitor.app \
  --repo "/实际的/AgentMonitor/源码路径"

# 如需记录一次插电复现，启动有界采集：
bash tools/capture-diagnostics-readonly.sh \
  --app /Applications/AgentMonitor.app \
  --repo "/实际的/AgentMonitor/源码路径" \
  --seconds 180
```

脚本默认写入一个新的私有临时目录，不安装、不启动 App、不调用 sudo、不修改显示或电源设置、不终止应用。启用 `--seconds` 后会启动只读日志命令，结束时仅停止脚本自己创建的日志子进程。默认 0 秒只做快照；最大 600 秒。目录、版本、签名、哈希、有限范围实时日志和电源历史分别保留。

**该脚本本次只通过 Bash 语法、参数和 Linux 拒绝运行检查，尚未在 macOS 实机运行。**权限拒绝、不可用命令或不存在的属性都需要查看 stderr，不得自动提升权限。日志可能含其他应用名、用户名和路径；原始证据留本地，向第三方交付前制作脱敏副本，不上传原始 Token 会话、密钥、环境变量或完整业务目录。

脚本不截图、不监控鼠标、不伪造活动；不会证明菜单栏可见。快照按命令顺序采集，不是同时刻原子采样。原有应用日志缺失时，下面的应用内观测仍然必须补充。

### 8.3 基线清单

| 维度 | 必须记录 |
|---|---|
| 安装 | 路径、Bundle ID、Executable、版本、构建号、hash、签名、构建源码提交和 dirty 状态。 |
| 进程 | App PID、启动时间、实际 bundleURL、可执行路径、启动方式。仅 PPID 不等于 macOS 的 responsible-process 归属。 |
| 软件 | `sw_vers`、系统 build、架构、Xcode/SDK、同类防休眠工具和菜单栏管理工具是否运行。 |
| 显示 | 开盖／合盖、各屏幕在线状态、可用区域、主屏、分辨率、刷新率、Space／全屏、菜单栏是否自动隐藏。 |
| 电源 | 实际 power source（不是只看是否正在充电）、电量、当前 Server 请求、SleepDisabled、断言和相关命令。 |
| 复现 | 插电与拔电时间、黑屏时间、鼠标唤醒时间、解锁时间；记录自然空闲时长。 |
| 安全 | 原有锁屏与密码设置、主动锁屏／睡眠是否保持可用；不修改它们来做“修复”。 |

电量优化导致“已连接适配器但未充电”不应被错误归为电池供电。使用电源来源字段，并把连接状态与 charging 状态分别记录。[A08]

### 8.4 应用内事件记录建议

建议新增 `PowerEventRecorder` / `MenuBarDiagnostics`，名称可调整，不要求引入大型框架。使用本地受限日志或明确诊断开关；默认不上传。Swift 与 C 回调边界应遵守当前工具链并发规则，回调只快速拷贝必要数据，再交给串行协调器，不在回调中等待 shell 命令。

| 事件来源 | 记录什么 | 约束 |
|---|---|---|
| `IOPSNotificationCreateRunLoopSource` | 电源来源快照、连接／充电状态、电量 | 通知不等于 AC 真发生变化；比较前后值，去重；保留并正确移除 RunLoop source。 |
| `NSWorkspace.shared.notificationCenter` | `willSleep`、`didWake`、`screensDidSleep`、`screensDidWake` | 不要错订阅到默认 NotificationCenter；屏幕睡眠与整机睡眠分开。 |
| `CGDisplayRegisterReconfigurationCallback` | 显示 ID、变化标志、在线状态、模式变化 | 回调可以多次触发；不要每次立即重建状态项或电源保护。 |
| 电源控制器 | desired、observed、session、operation revision、命令开始/结束/退出码、重试原因 | 不记密码与其他敏感参数；保护创建和释放要有明确原因。 |
| 菜单栏控制器 | 创建／插入请求、状态变化、状态项保留、尺寸、激活策略、屏幕关联 | `isVisible` 与窗口位置只作辅助证据，不能等同物理可见。 |

上述通知和公开接口的用途见 [A08]–[A12]。锁屏没有在本报告中假定一个能跨版本可靠使用的通用“已锁定”回调；不要把 session inactive 通知直接等同锁屏。若无可靠公开观测，采用用户动作标记、现场截图和有限系统日志，并标注能力缺口。

示例事件字段（结构建议，不是运行日志）：

```json
{
  "schemaVersion": 1,
  "eventSequence": 42,
  "wallTime": "ISO-8601 with timezone",
  "monotonicTime": 123.45,
  "source": "app.powerCoordinator",
  "event": "powerSourceChanged",
  "appPID": 1234,
  "buildFingerprint": "commit+dirty+executableHash",
  "operationRevision": 7,
  "desiredMode": "server",
  "observedSleepDisabled": "enabled|disabled|unknown",
  "powerSource": "AC|Battery|Unknown",
  "sessionActive": true,
  "displayPolicy": "externalWorkKeepAwake",
  "displayAssertionOwned": true,
  "systemAssertionOwned": true,
  "reason": "observationOnly"
}
```

## 9. 菜单栏诊断实验：从最小实现收敛

### 9.1 实验前置条件

正式包备份及指纹已保存；普通构建不再隐式安装；一次只运行一个实验实例；诊断程序不持有真实电源控制权限。先从 Finder 手动启动已安装路径，作为启动方式基线，之后才比较 Terminal、开发工具和登录项。`open -a` 不应被无条件视为可消除启动归属影响。[A06]

### 9.2 最小 2×2 对照

两个实现都仅显示固定 `AM`，提供一个可点击的小菜单，不加载 Charts、Token、温度、电源或服务发现。

| 组 | 实现 | Bundle ID |
|---|---|---|
| M-A | 最小 SwiftUI `MenuBarExtra` | `com.lumos.AgentMonitor` |
| M-B | 与 M-A 相同 | 一次性诊断 ID，例如 `com.lumos.AgentMonitor.Diagnostics` |
| M-C | 最小 AppKit `NSStatusItem` | `com.lumos.AgentMonitor` |
| M-D | 与 M-C 相同 | 与 M-B 对应的诊断身份 |

保持 OS、启动方式、安装位置管理、激活策略、签名方式和桌面环境可比；记录每个产物的不同 hash。原身份实验会触及该身份的状态持久化，必须备份、隔离、逐次验证，不能同时注册一堆同 ID 副本。先做新身份的最低风险实验，再决定是否需要原身份替换；不是强制第一步就覆盖正式包。

**实验并非数学上的绝对单变量：**换实现会改变二进制、ad-hoc 签名可能带来不同代码要求，换 Bundle ID 会改变偏好域。需要记录这些伴随变化，结论用“支持／优先调查”，不武断写“排除所有其他原因”。

| 观察结果 | 下一动作 |
|---|---|
| M-A/M-C 不显示，M-B/M-D 显示 | 查原身份相关系统登记、允许显示归属、签名与已有偏好；保留临时身份仅作诊断。 |
| M-A 不显示，M-C 显示 | 检查 SwiftUI 场景和插入恢复；复核两组其他条件，再评估 AppKit 是否是合理修复。 |
| 最小实现正常，完整程序失败 | 按“静态标签→动态温度→简单面板→业务面板→采集器”逐项恢复，找到首个失败增量。 |
| 全部不显示 | 检查全局设置、可用空间、不同屏幕和菜单栏管理工具；不能继续只改温度标签。 |
| 工具报告可见，但人眼／点击不成立 | 记录指标矛盾，判为未通过，不以 isVisible 或 AX 单值覆盖实际结果。 |

### 9.3 如需验证启动者开关

历史曾提出临时打开启动者在系统设置中的菜单栏开关。若依然需要，先确认本轮实际启动者及界面名称，记录原状态，仅改变相关一个开关；恢复失败时还原，无效即结束该分支。不能把历史显示名称“ChatGPT”当作当前 Codex 的必然映射。更不能批量开启全部应用来制造“似乎好了”的状态。

### 9.4 历史回归边界

`81996673` 为双菜单栏入口；`20cde501` 合并入口；`13a660c3` 为合并后版本；`f0e5d674` 添加主窗口、激活策略与若干部署／身份隔离措施。这些是可测试边界，不是已确认的引入故障提交。[R11]

回滚旧程序后仍失败，可能受持久化系统状态影响；不能仅凭旧程序失败就判定代码改动无关。为每个版本记录相同实验条件。

## 10. 电源诊断实验：确认是不是显示器保护缺口

### 10.1 保留原拓扑，先做基线

使用用户已有独立 USB-C 充电口，保持视频、键鼠、刷新率及合盖状态不变。Server 已开启、当前桌面已解锁。提前打开日志，不在插电瞬间操作终端或频繁移动鼠标。用外部时钟／口述标记时间，避免输入行为本身重置 idle timer。

至少分别记录 AC→Battery 与 Battery→AC。不要在合盖电池状态下直接关闭所有保护作为对照，否则普通合盖睡眠会混入实验。需要关闭 App 或 Server 的系统基线时，使用开盖安全条件，并明确该对照不能完全等价替代原场景。

### 10.2 有界 `-d` 对照

下列命令不是只读查询，它会建立临时显示器防休眠断言；不修改永久配置，不取消密码策略。应在执行用户已同意的故障复现时单独运行，并记录创建／释放。

```bash
/usr/bin/caffeinate -d -t 180
```

保持原有 Server 实现，仅补充显示器保护；180 秒后自动结束，必要时在对应终端使用 Ctrl+C。不要使用 `-u`，不要模拟鼠标，不要调用显示唤醒命令作为“预防”。手册含义见 [A01]。

建议 A/B 各至少 3 次，交替测试；这只是本项目初始验收数量，不是统计证明。两组都使用相近闲置时长、相近电量和相同插电步骤。必要时延长到更接近用户正常工作的 idle 时长；只在刚动过鼠标的条件下成功，不能证明故障消失。

| 结果 | 合理解释 | 后续 |
|---|---|---|
| 原版可复现，补 `-d` 后重复不再熄屏和解锁 | 支持显示器空闲保护不足参与了问题。 | 在明确工作会话中实现显示断言，再重复真实场景及退出回归。 |
| 加 `-d` 仍有 Sleep/Wake 事件 | 可能不是单纯屏幕 idle。 | 核对实际系统睡眠原因、合盖、电源命令及保护有效性。 |
| 加 `-d` 仍锁屏，没有可靠睡眠证据 | 不足以认定整机睡眠；也可能日志缺失。 | 查屏保／会话策略／其他软件；不取消安全策略。 |
| 显示器离线和 USB 重配置清晰出现 | 应深入显示／控制器分支。 | 只根据实际记录判断，不预先怪罪扩展坞。 |
| 两组都无法复现 | 未收敛。 | 保留配置和事件记录；不宣布“已经修复”，增加自然闲置与重复次数。 |

### 10.3 判定顺序

先确认真实电源来源已变化，再定位最早的屏幕／系统事件，然后比对应用是否先执行了模式改变、释放断言或全局命令。`pmset -g log` 的 Sleep/Wake reason 以本机原文为准，不能只匹配某个旧版关键词；完整相关时间窗留存后再筛选。[A02]

即使观测到 `SleepDisabled=1`，也不能单值证明显示器保持唤醒、不会被策略锁定或一定处于公开支持的合盖工作状态。反之，日志里出现 power-source change 本身，也不证明是应用主动触发睡眠。

## 11. 电源优化的实现规格

本节是拟实施设计，不是对现有系统行为的断言。优先选择最小实现；仅当诊断证明有必要时增加组件，避免为了“架构完整”重写整个应用。

### 11.1 状态模型必须表达四件不同的事

```text
UserIntent        用户最后明确选择的模式和显示策略
ObservedState     当前读到的系统状态，可为 unknown
OwnedSession      本应用当前拥有的保护会话、资源及恢复权限
OperationState    当前操作、revision、排队请求及真实执行结果
```

现有 `requestedMode`、`effectiveMode` 已有部分表达能力，但 `reconcileRequestedMode()` 把一次观测反向写成意图，破坏了分离。修复时也要避免 UI 的乐观预览被当作已生效状态：用户点 Server 时可以显示“切换中”，但真实 `effective` 应由执行与复核结果确认，而不是直接假装成功。[R04][R05]

**核心不变量：**

- 仅用户明确操作、有效且已授权的定时动作、明确的安全退出或既定恢复策略能改变 desired intent；单次 `.disabled`／`.unknown` 不是用户撤销授权。
- 处于活跃、已授权 Server 会话时，单次异常先标记不一致、保留已有合理保护并复查；持续不一致不能继续显示“已生效”。
- 临时无法观测与实际禁用分别记录；unknown 不冒充 false，也不无限维持“肯定安全”。
- 上次保存的 Server 请求不是无限恢复全局设置的授权；重启恢复规则必须明确，尤其外屏已断开、低电量或另一工具已改设置时。
- 用户明确选择 Normal／Sleep 后，旧检查、旧重试或旧完成回调不能重新开启 Server。

### 11.2 串行协调，不以 actor 名称替代互斥

所有有副作用的电源操作集中到一个协调器。可采用显式操作队列／单消费者任务、进行中状态和 revision；`@MainActor` 负责 UI 状态安全，不代替跨 `await` 的事务边界。

建议流程：

```text
收到请求 → 分配 revision → 验证授权与会话
→ 入单一队列／合并可合并的模式请求
→ 执行一个受控操作
→ 读取实际结果
→ 检查 revision 是否仍相关
→ 发布真实 outcome / 处理较新请求
```

Normal 与 Server 的连续选择可以按定义采用“最后一次明确用户意图优先”。Sleep 是一次性动作，不应被作为可无限重放的状态；用户改变意图时要取消尚未执行的 Sleep。已经向系统提交的命令不一定能取消，不能仅用 Task cancellation 伪装未发生；应记录已提交事实，避免旧结果覆盖新状态。

持续 `Task.yield()` 等待应替换成结果等待／队列通知。状态读取可以并行准备，但发布时带 revision，任何会改变保护或全局电源设置的路径不能绕过队列。恢复动作要有上限、退避、取消条件和错误说明；具体次数／窗口是待测参数，不是已验证修复诀窍。

### 11.3 显示器保护与后台 Server 保活分离

产品应区分两种策略：后台保活允许屏幕按系统设置关闭；外接工作会话在用户明确需要时保持显示器不因空闲关闭。该用户的目标是后者，但不能不经说明将所有 Server 场景永久改成所有屏幕常亮。

低侵入做法是为当前 Server 外接工作会话单独管理一个显示器保护 lease。已有 system／disk 保护保持不变，只增加／释放对应显示资源，避免改一次显示选项就终止整个 `caffeinate` 进程而产生保护间隙。

实现可以选用公开 IOPM display-idle assertion 或独立有生命周期管理的 `caffeinate -d`。优先保证可观察与正确释放，而不是强制某一种技术。公开 `kIOPMAssertionTypePreventUserIdleDisplaySleep` 是显示器空闲策略保护，不是对某一物理外屏指定“始终保持信号”的接口。[A01][A10]

| 条件 | 预期行为 |
|---|---|
| 已授权外接工作会话开始 | 创建所需保护，记录所有权和成功／失败；失败不显示完全有效。 |
| AC↔Battery | 记录来源变化，保持已持有资源；不要无意义释放再重建。 |
| 单次状态不一致 | 复查并提示；不直接清掉会话，不立即撤销保护。 |
| 显示器短暂重配置 | 使用有界去抖确认外屏确实断开；不能首个回调就释放全部保护。 |
| 用户 Normal／Sleep | 取消后续恢复，按序退出当前会话；Sleep 只能有受控的一次执行。 |
| 主动锁屏 | 保留密码要求和锁定状态，不自动解锁、不模拟输入、不反复宣告 user active。锁屏后的显示 lease 策略需显式定义与验证。 |
| 外屏确实断开、结束工作、应用正常退出 | 清理本应用资源，评估是否需要恢复本应用改动的全局设置；不盲目覆盖其他工具状态。 |
| 低电量／热保护／系统强制睡眠 | 遵循系统保护，禁止用全局禁睡或无限重试对抗；无法观测时暴露能力限制。 |

保留已经有效的电池合盖能力，不能删除现有机制后仅以普通 idle assertion 替代。`pmset disablesleep` 的具体全局效果、持久性与系统支持范围，应结合本机结果和工具手册核对；**不要因它没有 `-a` 参数，就未经验证判为“只对当前供电生效”，也不要盲目加 `-a` 当作修复。**[A02][A04]

### 11.4 结果与定时语义

建议让 `setMode()` 返回明确 outcome，例如 succeeded、failed、superseded、indeterminate，并附实际快照。名称仅供设计，不能直接声称仓库已有这些类型。

定时记录至少区分尝试与确认完成；错误不覆盖成成功。失败是否可重试取决于动作：设置可验证的状态通常能做幂等复核；`sleepnow` 命令返回超时／响应不明时，不可据此重复发送。手动请求与定时事件必须共享同一个串行协调层。

时区、夏令时、应用错过定时点、睡眠后恢复时是否补执行，需明确既有语义和本轮是否变更。诊断阶段可以暂停用户同意的相关计划，但记录原值并恢复；不得在测试中执行真实睡眠计划来“验证单元测试”。

### 11.5 权限与全局状态所有权

现有 sudoers 规则虽限制到具体 `pmset` 命令和参数，但授予的是该用户名的调用能力，不是只允许 AgentMonitor 二进制。不要根据脚本注释误写“其他同用户进程无法使用”。本轮不得扩展成任意 `pmset *` 或任意 shell 命令免密。[R04]

健康检查、插电通知、菜单栏重建和诊断程序不应偷偷发起管理员认证或安装 sudoers。已有授权失效时，应给出明确状态，等待适当的用户驱动操作。不能从“用户允许调整菜单栏”推导出新的 root 权限授权。

如需恢复 `SleepDisabled`，记录进入会话前的值、是否由本应用实际改变、退出时的当前值和是否有竞争修改。单纯保存一个布尔值无法排除外部修改，不能无条件写回。应用崩溃也可能来不及 cleanup，必须把恢复能力和残余全局状态写进发布说明，不夸大进程绑定保护。

## 12. 菜单栏与面板的实现规格

### 12.1 首选最小修复，而非预先决定重写

若最小 SwiftUI 实验可正常工作，优先保留 SwiftUI，增加可诊断的插入状态、明确的手工恢复入口，以及共享运行状态的稳定生命周期。用户主动隐藏时保留该选择；诊断识别不出来时显示“未确认”，不能自动将一切不可见都判成系统阻止。[A07]

若对照实验支持切换 AppKit，则通过 AppDelegate／长生命周期控制器强引用状态项、稳定的 `autosaveName` 和明确的按钮行为管理入口。只创建一个逻辑状态项，既不能在每次温度更新时重建，也不能在每次屏幕重配置通知时创建新项。保留 SwiftUI 业务视图作为面板内容，避免无关重写。

AppKit 是可控性更强的实现选择，不是越过 ControlCenter 的通道。看不到状态项时有限重试或给出恢复指导；不得无限清偏好、不断换 autosaveName／Bundle ID，或反复抢回用户主动隐藏的图标。

### 12.2 独立于业务数据的入口

标签无温度时仍展示固定图标及 `--°C`；读取 Token、服务或温度失败不能决定状态项是否存在。将入口创建与采集启动适当解耦；必要时先让最小 UI 可用再启动采集，但不能随意增加固定延时作为“修复”而不证明竞争关系。

关闭主窗口和面板不应终止需要继续工作的监控进程；明确退出则正确清理。激活策略的选择应保持一致、可解释，在正式菜单栏问题解决前保留可访问主窗口，避免用户再次完全失去操作入口。

### 12.3 外屏与视口

面板总高度由当前承载屏幕可用区域约束；头部、底部、确认操作区与内容区分别测量。主体只保留必要的一层滚动。折叠／展开、高温样式、服务数量变化和无数据状态都不能将退出、错误信息或确认按钮推出可达区域。

全屏、独立 Spaces、多屏、合盖与再开盖之后，入口按系统当前允许展示菜单栏的屏幕规则可见；“唯一”指一个逻辑状态项、同一菜单栏没有重复，不是强迫多屏系统全局只能出现一次。面板应跟随实际点击所在位置，而不是旧的主屏坐标。

### 12.4 可见性验收不能只依赖单个 API

应同时保留状态创建日志、当前 PID／产物指纹、屏幕上实际可见证据和点击结果。当前应用 AX 树缺条目不是定论；macOS 上菜单栏宿主可能不属于应用窗口的 AX 子树，历史记录也特别提示 ControlCenter 托管情况。[R02]

工具只能看到 App 窗口、不能看到全局菜单栏时，标注观察范围；不得把没有观察权限误写成项目不存在。对窗口列表／代理窗口几何的启发式检查，应兼容系统版本及菜单栏管理器，不能当作公开的“被系统 block”判定 API。[A06]

## 13. 构建、部署与代码变更清单

### 13.1 逐文件执行要求

| 文件／拟新增组件 | 修改要求 | 必须覆盖的验证 |
|---|---|---|
| `project.pbxproj` 与安装脚本 | 从普通 target build 移除隐式安装；只部署最终签名产物；保留 Debug 身份隔离。 | Debug/Release build 与 test 均不改变正式包、不结束正式 PID；显式安装可回滚。 |
| `AgentMonitorApp.swift` | 接入必要的入口日志／恢复控制；最小诊断依赖隔离；保留窗口兜底。 | 采集异常不移除菜单栏；诊断构建不运行真实电源计划。 |
| `MenuBarContentView.swift` | 总视口上限、滚动层次、切换中／生效／失败区分。 | 多分辨率及确认区可达性；不扩大无关 UI 改动。 |
| `MonitorStore.swift` | 修补异步入口门控；统一结果写回与排队；避免旧快照覆盖新意图。 | 同时请求、定时重叠、取消及请求合并。 |
| `ServerModeController.swift` | 意图／观测／所有权分离；有限恢复；保留真实 outcome。 | 暂态读数、持续失败、未知状态、外部更改、幂等性。 |
| `SystemCaffeinateManager` 或显示保护组件 | 持有显示工作会话保护，跨电源切换连续；有界清理。 | 不重复启动、不释放重建、不泄漏、不覆盖主动睡眠／锁屏。 |
| 拟新增 `PowerEventRecorder` 等 | 事件时间线、source、revision、能力缺口。 | 回调注销、无敏感数据、无高频重命令、失败可见。 |
| 现有及新增 XCTest | 更新错误旧预期，加入新需求回归。 | mock 不碰用户真实电源；测试名和覆盖矩阵对应。 |
| `docs/menu-bar-visibility.md` 等 | 更正现状，标注已证实／假设，更新验收。 | 不再称应用闪退或短暂闪黑；不把方案写成成果。 |

工程目前显式列出 Sources／Tests。新增 Swift 文件后要确认已加入正确 target 的 Sources phase；仅将文件放进目录，不保证参与构建或测试。[R07]

### 13.2 安装流程目标

```text
构建完成 → 最终签名完成 → 验证签名与产物指纹
→ 明确部署授权 → 完整暂存 → 验证 → 停止对应旧实例
→ 替换并保留可回滚副本 → 验证实际安装产物
→ 启动已安装版本 → 菜单栏与电源分别实机验收
```

安装目录、备份目录和签名策略必须明确。不要让备份以可被当作另一份正式 App 的方式反复注册。不要只修安装脚本的正则表达式而保留错误的签名时序。安装失败时保留原包、日志和明确失败状态，不能静默留下半安装版本。

无需把购买 Developer ID 当作此次自用故障的必要条件；采用明确的一致签名策略即可进入实验，但签名完整性和系统显示允许归属仍是独立证据。[A05]

### 13.3 执行顺序与任务依赖

| 阶段 | 任务 | 交付与退出条件 |
|---|---|---|
| S0 基线 | 固定 U-M/U-P 描述、读取 HEAD、dirty 状态、安装指纹和现场配置。 | 保存 baseline；未知项列明；不启动无保护的 Release 构建。 |
| S1 工程隔离 | 去除自动安装副作用，确保测试与诊断不运行真实电源计划。 | 普通 build/test 不改变正式包和 PID；独立提交或可审查 diff。 |
| S2 观测 | 只读采集＋最小应用事件日志。 | 能关联插电、断言、睡眠和菜单栏事件；权限缺口单列。 |
| S3-M 菜单栏实验 | 最小实现与身份对照、显示环境验证。 | 给出实验表和证据支持的修复分支。 |
| S3-P 电源实验 | 原拓扑基线、等闲置 `-d` 对照与事件判定。 | 明确支持／未支持哪个分支；不把未复现视为已修复。 |
| S4 实施 | 先修确定逻辑问题，再应用与实验证据相符的最小菜单栏／电源补丁。 | 单一目的 diff、无权限扩张、无无关业务重写。 |
| S5 自动化回归 | XCTest、隔离测试、构建与安装脚本检查。 | 新测试覆盖映射、原有回归、实际测试产物。 |
| S6 正式部署与实机 | 显式安装，真实菜单栏点击，AC↔Battery、锁屏与退出回归。 | 两项主故障分别达到验收；未通过则标明仍未完成。 |
| S7 收尾 | 回滚准备、诊断设置还原、文档与发布记录。 | 指纹、结果、已知限制、恢复操作可复核。 |

S3-M 和 S3-P 可以分工，但物理复现期间不能同时部署或改动另一条链路。每个 AI 应有明确文件所有权，避免多个代理同时修改 App 入口、控制器或 pbxproj 后丢失因果关系。

### 13.4 本地构建与测试命令模板

先完成 S1，并确认实际可用 scheme；不要用命令模板覆盖用户签名、团队或全局 Xcode 设置。以下运行在项目根目录：

```bash
git status --short
git rev-parse HEAD
xcodebuild -list -project AgentMonitor.xcodeproj

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/AgentMonitor-validation.XXXXXX")"
xcodebuild \
  -project AgentMonitor.xcodeproj \
  -scheme AgentMonitor \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$RUN_DIR/DerivedData" \
  -resultBundlePath "$RUN_DIR/tests.xcresult" \
  test > "$RUN_DIR/tests.log" 2>&1
TEST_EXIT=$?
printf 'test_exit=%s\nresults=%s\n' "$TEST_EXIT" "$RUN_DIR"

git diff --check
```

不要默认把 `CODE_SIGNING_ALLOWED=NO` 作为正式安装策略；若仅隔离逻辑测试需要使用，必须区分测试产物和正式产物。完整测试成功后，Release 构建仍只是构建，不应自动部署。具体签名失败应分析当前错误，不自动降低 Hardened Runtime、SIP 或认证要求。

## 14. 自动化回归矩阵

以下是拟新增／调整的测试要求，不表示当前仓库已经有这些测试，也不表示已经通过。基于依赖注入、假命令执行器和可控制时钟，避免使用真实电源副作用。

| ID | 测试输入 | 应满足的断言 |
|---|---|---|
| UT-P01 | 活跃 Server 下 enabled→disabled→enabled | 单次读数不清掉用户意图；保护不被不必要停止；恢复后状态正确。 |
| UT-P02 | enabled→unknown→enabled | unknown 独立表示；无误判禁用、无盲目重写系统。 |
| UT-P03 | 持续 disabled / 不可恢复 | 有限复查／重试后进入明确失败或降级，不能假成功或无限重试。 |
| UT-P04 | 两个 async `setPowerMode` 同时进入 | 有副作用操作不重叠；最终结果符合明确定义的请求顺序。 |
| UT-P05 | 手动 Normal 与定时 Server 重叠 | 新的明确用户选择不被旧任务覆盖；定时 outcome 真实。 |
| UT-P06 | 旧 Server 回调晚于新 Normal | revision 防止旧结果写回和重新开启保护。 |
| UT-P07 | AC→Battery→AC 反复事件 | 已有保护不重复创建、不无故释放；来源重复通知不产生副作用风暴。 |
| UT-P08 | 仅改变显示保护选项 | 不重启已有 system/disk 保护；显示资源正确获取和释放。 |
| UT-P09 | 用户主动 Sleep | 退出必要保护后只发送一次动作；超时结果不自动重发。 |
| UT-P10 | 定时命令失败 | 失败信息保留；attempted/succeeded 区分；无“已成功切换”覆盖。 |
| UT-P11 | 外部工具已有 SleepDisabled | 不仅凭全局观测就声明资源归本应用所有；退出不盲目还原他人状态。 |
| UT-P12 | 旧持久化 Server + 重启 + 外屏缺失／低电量 | 按显式恢复策略处理，不将旧配置视作无限授权。 |
| UT-P13 | 权限缺失、命令 launch fail、超时 | 准确失败，后台观察不安装 sudoers、不重复弹认证。 |
| UT-P14 | 显示拓扑连续回调／通知重复 | 去抖有界，保护和菜单栏对象不泄漏，用户退出可立即取消恢复。 |
| UT-M01 | 温度 nil／读取失败 | 固定可读入口仍然存在，不依赖业务数据成功。 |
| UT-M02 | 反复 show/restore 及数据更新 | 一个逻辑状态项；更新标签不重建条目。 |
| UT-M03 | 用户主动隐藏 | 不循环强制恢复；状态反馈准确。 |
| UT-M04 | 关闭主窗口／收起面板 | 不意外结束需要继续工作的应用；明确退出则清理。 |
| UT-U01 | 小视口、展开列表、错误／确认区 | 计算的总高度不超可用区域，重要操作可达。 |
| UT-D01 | Debug/Release 普通 build 与 test | 正式包 hash、安装时间和已有 PID 不被构建副作用改变。 |
| UT-D02 | 显式安装签名无效／移动失败 | 拒绝替换或正确回滚，不发布半安装包。 |

资源计数、队列 revision 和尺寸计算可以单元测试；**条目真正显示、合盖电源行为、物理屏幕和登录界面必须实机验证**。测试覆盖范围要注明，不用内部对象数量代替屏幕上的数量。

## 15. 实机验收矩阵与发布门槛

所有用例默认状态为 **NOT_RUN**。PASS 必须附具体版本、PID、时间、配置和观察证据；FAIL 必须保留原始相关日志；BLOCKED 要列出缺失的权限／硬件／操作能力。建议核心用例至少重复 3 次，并报告实际次数与失败数。

| ID | 场景 | 通过标准 |
|---|---|---|
| RT-M01 | Finder 启动正式安装版本 | App 持续运行；当前应展示的菜单栏实际有入口；点击打开正确面板。 |
| RT-M02 | 关闭主窗口、收起面板 | 菜单栏仍存在，重新点击可用。 |
| RT-M03 | 明确退出后重启 App | 入口恢复，无重复逻辑项，无错误旧实例。 |
| RT-M04 | 登录／电脑重启后 | 通过既有支持的启动方式打开后入口可用；未实现登录自启动时不凭空新增要求。 |
| RT-M05 | 开盖→合盖外屏→再开盖 | 在系统当前显示规则允许的位置可见，面板不跑到不可达旧屏幕。 |
| RT-M06 | 多屏／主屏变化／全屏和 Spaces | 不重复、不错误定位；符合系统菜单栏显示配置。 |
| RT-M07 | 无温度／服务读取失败 | 菜单栏入口和退出／诊断功能仍可用。 |
| RT-M08 | 用户隐藏／菜单栏管理工具隐藏 | 尊重主动隐藏；恢复操作可解释，不反复抢回或伪报修复。 |
| RT-P01 | Server、合盖外屏、AC→Battery | 原本可用的电池合盖工作能力不回退，桌面不中断。 |
| RT-P02 | 同条件 Battery→独立 USB-C 接电 | 不发生非预期持续黑屏；不需要晃鼠标唤醒；不因插电进入解锁界面。 |
| RT-P03 | 较长自然闲置后重复 RT-P02 | 不只在刚操作鼠标后成功；报告 idle 时长与策略设置。 |
| RT-P04 | 连续多轮拔插 | 保护不中途丢失，不积累 caffeinate／断言，不出现状态项重复。 |
| RT-P05 | 用户主动锁屏 | 正常锁定，密码要求不变，无自动解锁、无模拟输入。 |
| RT-P06 | 用户主动 Normal／Sleep | 正确退出保护；睡眠不被旧重试或 Server 会话抢回。安全条件下执行。 |
| RT-P07 | 断开外屏／结束会话／正常退出应用 | 按既定策略释放本应用资源，必要全局恢复可审计，避免合盖带包仍异常保活。 |
| RT-P08 | 系统睡眠再唤醒 | 不错误重放 sleepnow，不覆盖新用户选择，菜单栏按预期恢复。 |
| RT-J01 | 原故障条件下联合运行 | RT-M 与 RT-P 同时成立；电源切换不使菜单栏消失，菜单栏恢复不重启电源保护。 |

低电量／热保护等危险边界主要用假数据和安全观察测试，不为了验收故意让机器过热或耗尽电量。主动 Sleep、拔插物理线缆等应由具备本机操作能力的工具或用户完成；没有能力时如实标为待执行。

### 15.1 不能作为发布通过的替代物

编译成功、119 项历史业务测试通过、codesign verify 通过、App 进程存在、Dock 可见、状态项 `isVisible=true`、自己的窗口 AX 树正常、加 `-d` 的单次实验成功、重新换个 Bundle ID 能显示，**任何一项单独都不代表完成了本报告的验收**。

“插电后又主动唤醒回来了”不满足 RT-P02；“取消密码后不再出现登录界面”不满足安全要求；“只能在新身份的诊断 App 显示”不满足正式版菜单栏修复。

## 16. 回滚、禁止事项与失败处理

### 16.1 回滚材料

部署前保留旧正式包、hash／签名／版本、局部代码 diff 和相关应用设置导出；导出内容仅限任务相关，不采集密钥或用户业务数据。记录原有菜单栏开关、显示策略及为实验临时调整的项目。

代码回滚采用明确 revert／恢复已保存包，不执行会丢失用户未提交修改的硬重置。恢复旧包后仍需重新验证实际安装指纹和启动路径。不要仅因为回滚后菜单栏仍失败就否定新旧代码差异；系统身份状态可能持久存在。

### 16.2 立即停止继续叠加修改的条件

出现无法访问 UI、已有电池合盖能力丢失、持续重复睡眠、无法退出 Server、不可控命令重试、权限意外扩张、安装签名不一致或无法安全恢复旧包时，暂停部署，保留证据，执行对应回滚。不要继续同时重置系统设置和增加“补救”命令。

### 16.3 明确禁止的捷径

不得关闭“唤醒后要求密码”、自动解锁、周期性模拟鼠标／键盘或反复 `caffeinate -u`；不得关闭 SIP、FileVault、认证或系统热／低电量保护；不得自动修改受保护 ControlCenter 私有数据库；不得全局删除用户偏好、批量重置所有菜单栏项目或反复强杀系统显示服务；不得永久更换正式 Bundle ID 作为掩盖；不得把签名校验、重建图标或恢复窗口本身说成根因修复。

普通诊断不需要新管理员权限。需要权限的新操作须按当前工具规则和用户实际授权处理；报告中的历史授权说明不应被视为新的确认令牌。

## 17. 接手 AI 的最终交付格式

必须提交可审查变更、测试结果与实际部署指纹，分别给出两项主故障状态。建议使用附件 `EXECUTION-RESULT-TEMPLATE.md`，至少包含：

| 项目 | 必须回答 |
|---|---|
| 版本 | 基线、最终提交、是否有未提交修改、安装包 fingerprint、系统与硬件环境。 |
| 根因 | 已证实机制、证据链、已排除项、仍存在的假设；菜单栏与电源分开。 |
| 修改 | 每个 F-编号对应哪些文件、为何必要、是否有接口／行为变化。 |
| 测试 | 实际命令、退出码、测试数量、xcresult／日志路径；不能沿用旧的 119 当本次结果。 |
| 实机 | 每个 RT 用例状态、次数、具体配置、截图／点击证据与事件时间线。 |
| 部署 | 是否真的替换正式包并启动；构建产物与实际运行包是否一致。 |
| 安全 | 是否保持锁屏密码和主动睡眠；是否新增权限；临时设置是否恢复。 |
| 限制 | 未验证、被阻塞或只做了隔离复现的部分；如实保留已知缺陷。 |
| 回滚 | 可用旧包／提交、相关设置恢复方式和执行记录。 |

建议最终状态格式：

```text
菜单栏：FIXED_AND_VERIFIED / PATCHED_NOT_VERIFIED / NOT_FIXED / BLOCKED
插电黑屏与解锁：FIXED_AND_VERIFIED / PATCHED_NOT_VERIFIED / NOT_FIXED / BLOCKED
既有电池合盖能力：PRESERVED_AND_VERIFIED / REGRESSED / NOT_VERIFIED
安全行为：UNCHANGED_AND_VERIFIED / CHANGED / NOT_VERIFIED
```

若系统原因无法由当前公开接口消除，仍应交付可复现最小案例、系统版本、事件时间线、已尝试且可回滚的方案；注明该项未解决。不能仅因外部 issue 相似就结束诊断，也不能把系统原因的可能性变成对用户的无证据结论。

## 18. 可直接粘贴给接手 AI 的启动指令

```text
请阅读 AgentMonitor-Diagnostic-Report.md，并以第 1 节的最新用户事实为准。
当前 App 不闪退，Dock 可见，只缺菜单栏入口。Server 模式可在电池供电时
合盖使用外屏；重新将电源接入 Mac 独立 USB-C 口后持续黑屏，需晃鼠标
才能亮屏，并出现登录/解锁界面，不是短暂闪断。

先执行 S0 和 S1，保留本地改动及正式安装，不让普通构建自动覆盖应用。
按照报告收集基线、区分屏幕睡眠/整机睡眠/锁定，再做菜单栏最小对照和
等闲置条件下的临时 -d 对照。对确定的电源并发、意图覆盖、定时失败提示
问题实施有测试的最小修改；菜单栏实现选择由证据决定，不预先强制重写。

不要取消密码验证、模拟输入、自动改私有系统偏好、无限重建状态项或
扩大 sudo 权限。保留电池合盖工作能力。普通测试使用假依赖，不运行真实
电源计划。最终按 EXECUTION-RESULT-TEMPLATE.md 分别报告两项故障状态，
附实际安装版本、测试产物和 RT 实机证据。没有本机或物理操作能力的项目
标为待验证，不声称修复完成。
```

## 19. 来源、附件与适用性

### 19.1 项目一手来源

以下项目链接固定到本次基线；主分支日后变化不改变本报告引用的版本。正文 [Rxx] 引用用于帮助其他 AI 直接定位，不依赖当前聊天工具的临时引用标记。

- **[R01] 当前审查提交与提交说明。** `https://github.com/Arcaneology/AgentMonitor/commit/f0e5d674006c7035e4cedb8bd06d624fc24fb0ab`
- **[R02] 历史菜单栏诊断记录。** `https://github.com/Arcaneology/AgentMonitor/blob/f0e5d674006c7035e4cedb8bd06d624fc24fb0ab/docs/menu-bar-visibility.md`
- **[R03] App 入口与依赖构建。** `https://github.com/Arcaneology/AgentMonitor/blob/f0e5d674006c7035e4cedb8bd06d624fc24fb0ab/AgentMonitor/App/AgentMonitorApp.swift`
- **[R04] 电源控制器、caffeinate 管理及系统读取。** `https://github.com/Arcaneology/AgentMonitor/blob/f0e5d674006c7035e4cedb8bd06d624fc24fb0ab/AgentMonitor/Core/System/ServerModeController.swift`
- **[R05] Store 电源刷新与操作协调。** `https://github.com/Arcaneology/AgentMonitor/blob/f0e5d674006c7035e4cedb8bd06d624fc24fb0ab/AgentMonitor/Core/State/MonitorStore.swift`
- **[R06] 电源控制器测试。** `https://github.com/Arcaneology/AgentMonitor/blob/f0e5d674006c7035e4cedb8bd06d624fc24fb0ab/AgentMonitorTests/ServerModeControllerTests.swift`
- **[R07] 工程构建、文件 target 归属与身份配置。** `https://github.com/Arcaneology/AgentMonitor/blob/f0e5d674006c7035e4cedb8bd06d624fc24fb0ab/AgentMonitor.xcodeproj/project.pbxproj`
- **[R08] 安装脚本。** `https://github.com/Arcaneology/AgentMonitor/blob/f0e5d674006c7035e4cedb8bd06d624fc24fb0ab/scripts/install-to-applications.sh`
- **[R09] 菜单栏面板与高度设置。** `https://github.com/Arcaneology/AgentMonitor/blob/f0e5d674006c7035e4cedb8bd06d624fc24fb0ab/AgentMonitor/App/MenuBarContentView.swift`
- **[R10] 温度标签与占位。** `https://github.com/Arcaneology/AgentMonitor/blob/f0e5d674006c7035e4cedb8bd06d624fc24fb0ab/AgentMonitor/App/TemperatureChartView.swift`
- **[R11] 待测历史边界，不是已确认故障引入点。** `https://github.com/Arcaneology/AgentMonitor/commit/81996673c70d48846cc776c54474641205d827b8`；`https://github.com/Arcaneology/AgentMonitor/commit/20cde501abdbe8334b5ad68798f562d4d2354368`；`https://github.com/Arcaneology/AgentMonitor/commit/13a660c3143c24d4f4164c00898f72102d21f542`

### 19.2 外部一手资料

本报告编制日期为 2026-09-13。官方文档与 open-source main 可能更新；接手时以实际 macOS 手册、当前 SDK 的接口可用性及现场证据为最终依据。Apple 归档文档用来解释概念边界，不作为现代系统内部实现的保证。

- **[A01] Apple 开源 caffeinate 手册：参数及生命周期。** `https://github.com/apple-oss-distributions/PowerManagement/blob/main/caffeinate/caffeinate.8`
- **[A02] Apple 开源 pmset 手册：电源配置、断言、事件日志。** `https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.1`
- **[A03] Apple Lock Screen 设置：不同供电熄屏及密码要求。** `https://support.apple.com/guide/mac-help/change-lock-screen-settings-on-mac-mh11784/mac`
- **[A04] Apple QA1340：睡眠／唤醒通知、idle 与 forced sleep；归档文档。** `https://developer.apple.com/library/archive/qa/qa1340/_index.html`
- **[A05] Apple TN2206：代码签名完整性、身份与子系统策略；归档文档。** `https://developer.apple.com/library/archive/technotes/tn2206/_index.html`
- **[A06] CodexBar #1945：菜单栏归属错误的一手外部复现，仅作对照。** `https://github.com/steipete/CodexBar/issues/1945`
- **[A07] Apple MenuBarExtra 插入绑定接口。** `https://developer.apple.com/documentation/swiftui/menubarextra/init(isinserted:content:label:)`
- **[A08] Apple 电源来源通知 API。** `https://developer.apple.com/documentation/iokit/1523868-iopsnotificationcreaterunloopsou`
- **[A09] Apple NSWorkspace 及屏幕睡眠通知。** `https://developer.apple.com/documentation/appkit/nsworkspace`；`https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification`
- **[A10] Apple 显示器防空闲休眠 assertion。** `https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep`
- **[A11] Apple 显示重配置回调。** `https://developer.apple.com/documentation/coregraphics/cgdisplayregisterreconfigurationcallback(_:_:)`
- **[A12] Apple assertion 创建与状态读取接口。** `https://developer.apple.com/documentation/iokit/1557134-iopmassertioncreatewithname`；`https://developer.apple.com/documentation/iokit/1557072-iopmcopyassertionsstatus`

### 19.3 随附文件

```text
AgentMonitor-AI-Handoff/
  README.md                                  交付包入口与验证范围
  AgentMonitor-Diagnostic-Report.md          本报告，可单独交给其他 AI
  EXECUTION-RESULT-TEMPLATE.md                接手工具填写的结果模板
  tools/capture-diagnostics-readonly.sh       macOS 只读采集脚本，未实机验证
  repro/power-mode-race-repro.swift           并发门控缩减复现
  repro/server-mode-transient-state-repro.swift  暂态读数缩减复现
  evidence/local-toolchain.txt               本次隔离测试环境
  evidence/race-repro-output.txt              本次实际运行结果
  evidence/transient-repro-output.txt         本次实际运行结果
  evidence/artifact-validation.txt           报告／脚本检查范围
  SHA256SUMS.txt                              交付文件完整性校验
```

旧的 `REVIEW.md` 与 `FOLLOWUP-menu-bar-and-power.md` 是历史推导材料；后者中的“短暂黑屏／接电位置未知”已过时，因此不作为交付包的执行规格重复附带。前述文件里的历史复现本次已实际重跑，但它们依然不是 macOS 实机证据。

**本报告结束时的真实状态：诊断规格和可执行交接材料已完成；菜单栏与插电黑屏均尚未通过本次 macOS 实机修复验收。**
