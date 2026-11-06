# Status Trio 电池 / 充电 / 特权 Helper 架构分析与「航海模式」集成方案

> 只读架构分析。本文不修改任何产品源码。
>
> - 分析基线：`main` @ `7acd6341bfc91263c39fd986c0c1c5e83fd04ba4`（2026-11-05）
> - 工具链：Swift 6.4.2 / Xcode 27.2；部署目标 macOS 13.0
> - 分析日期：2026-11-05（Asia/Shanghai）
> - 工作区说明：分析与写作期间可能有其它成员在同一工作区修改产品源码；本文描述的是上述基线的 HEAD，不包含未提交的并发改动。

---

## 0. 结论先行

1. **电池状态链路是事件驱动 + 兜底轮询，不是固定高频采样。**
   `BatteryMonitor` 只安装 IOPS 通知源和低功耗模式通知，并立即读一次；`SystemStatusStore` 默认每 15 秒兜底调用一次 `batteryMonitor.refresh()`（设置范围 5–60 秒）。`BatteryStatus` 通过 `AsyncStream` 进入 `SystemStatusStore.applyBattery(_:)`，再由 `publish(_:)` 写入 `@Published snapshot`。航海模式控制器应订阅 **`store.$snapshot.map(\.battery).removeDuplicates()`**，而不是 `popupSnapshot`（它只在面板打开时更新且经过 500 ms 防抖）。

2. **现有 PowerUI 私有 API 只能做「静态充电上限」，不能做真正的航海模式区间控制。**
   `PowerUIPrivateAPI` 只支持 macOS 26.4+、arm64，且 `setMCLLimit:` / `temporarilyDisableMCL:` / `enableMCL:` 都围绕同一个持久化 MCL 策略；可用上限为 80–95（系统 UI 为 80–100），不能设置任意下限，也不能可靠地按 5% 以外的滞回区间反复开关充电。它和「立即充满（Charge to Full Now）」共用同一份 MCL 状态，天然冲突。

3. **真正的航海模式（用户可配置下限/上限、可低于 80%）需要绕开 MCL，直接写 SMC 充电抑制键。**
   在 macOS 13–26.6 上，常见路径是 root helper 写 `CH0B`（`0x02` 暂停充电、`0x00` 恢复）；在 macOS 26.7+/27 上，`CH0B`/`CH0C`/`CHTE` 已被固件收窄或移除，第三方即使 root 也会收到 `kIOReturnNotPrivileged`，只剩 `CHIE`（切断适配器）这条「用户态适配器门控」路径。**因此不存在一个跨 macOS 13–27 都成立的 SMC 写方案，必须做能力分级。**

4. **最小可行路线有两条，必须先由产品决策：**
   - **路线 A（推荐先做）**：只实现「系统充电上限版航海模式」——macOS 26.4+ Apple Silicon，使用现有 PowerUI MCL，上限 80–95%，依赖系统自带的约 5% 滞回；不新增 Helper 协议、不写 SMC。功能较弱，但风险最低。
   - **路线 B（完整航海模式）**：新增 Helper 协议 v3 + `SMCPowerService`，在 macOS 13–26.6 用 `CH0B` 实现任意区间；macOS 26.7+/27 要么只提供 `CHIE` 适配器门控（高风险，需单独硬件验证），要么把功能标记为不可用。

5. **Helper 扩展方式应是「追加协议版本 3 + 独立 `SMCPowerService` + `PowerModeService` 转发」**。这样 `ListenerDelegate` 可以保持不变，旧的 v1/v2 方法完全兼容；新 App 对旧 Helper 通过 `readProtocolVersion` 识别为「需要更新」，不会调用不存在的 selector。

6. **UI 放置在 `BatterySectionView.fullBatteryContent` 的 `chargeManagementGroup` 之后**，新增一个「航海模式」`SettingsGroup`；控件复用 `SettingsToggleRow` / `SettingsRow` / `Slider`；状态用 `subtitleStatus` 展示，不要把航海状态塞进 `StatusSnapshot`（那会进入图标渲染的相等性路径，造成不必要的重绘）。新增文案需要同步 12 个 `.lproj/Localizable.strings`。

7. **测试不要触碰真实电池/真实 SMC 写。** 控制器测试用假 backend；Helper 测试用假 SMC transport，验证请求字节、键名、值、失败分支和退出恢复；涉及 Helper / Package / 协议版本的变更至少跑 `bash scripts/verify-local.sh full`。

8. **最需要 Lead 决策的三点**见第 11 节：产品语义（是否允许低于 80% / 是否必须支持 macOS 13–26.3 / Intel）、兼容范围（是否接受 macOS 26.7+ 不可用或只做 CHIE）、以及 Helper 授权归属（复用 `controlsLowPowerMode` 还是引入独立的「电源助手」授权）。

---

## 1. 电池状态数据流

### 1.1 BatteryMonitor：何时、因为什么刷新

`Sources/StatusTrioCore/Monitoring/BatteryMonitor.swift`

- `BatteryMonitor` 是 `@MainActor final class`，实现 `BatteryMonitoring`（`Sources/StatusTrioCore/Monitoring/MonitorProtocols.swift`）。
- `start()` 做两件事：
  1. `installNotifications()`：创建 `IOPSNotificationCreateRunLoopSource` 并挂到主 RunLoop 的 `.defaultMode`，同时注册 `.NSProcessInfoPowerStateDidChange`（低功耗模式变化）通知；
  2. 立即调用一次 `refresh()`。
- 之后**没有内部定时器**。电量变化、插拔电源、充电状态变化由 IOPS 通知触发 `refresh()`；低功耗模式变化也会触发一次。`recover()` 用于唤醒后拆装通知源。
- `refresh()` 调用 `IOPSBatteryReader.read()`，把 IOPS 描述解析为 `BatteryReading`，再生成 `BatteryStatus` 并通过 `updates`（`AsyncStream<BatteryStatus>`，`MonitorStream` 使用 `bufferingNewest(1)`）`yield`。
- `BatteryReading` 包含：`currentCapacity`、`maxCapacity`、`isCharging`、`isCharged`、`timeToFullChargeMinutes`、`isConnectedToPower`、`isPresent`。

**刷新频率的完整图景：**

| 触发源 | 频率 | 代码位置 |
| --- | --- | --- |
| IOPS 电源状态通知 | 事件驱动（插拔、充电状态、电量变化） | `BatteryMonitor.installNotifications()` |
| 低功耗模式变化通知 | 事件驱动 | 同上 |
| `SystemStatusStore` 兜底 tick | **默认 15 s**，可设 5–60 s；每个 tick 都刷新电池 | `SystemStatusStore.fallbackRefreshTick()` |
| 面板打开 / 设置窗口打开 / 系统唤醒 | 立即 `refreshAll()` | `SystemStatusStore.setPopoverVisible(true)`、`setSettingsVisible(true)`、wake observer |
| `BatteryDetailsController` | 详情页打开时 2 s（有功率显示）或 15 s | `BatteryDetailsController.startRefreshLoop()`，与 `BatteryMonitor` 无关 |
| `PowerSamplingService` | 2 s，仅在图标/面板/详情页有 demand 时 | `PowerSamplingService` |

> 关键结论：航海模式不需要自己加 timer。它应该消费 `BatteryStatus` 流；15 秒兜底 tick 足以覆盖「电量降到下限」这种慢变化；IOPS 通知会在充电状态变化时立即触发。不要为了航海模式把全局刷新间隔调低。

另外，`SystemStatusStore.fallbackRefreshTick()` 在 `isDisplayAsleep` 时会跳过 tick，最多跳过 `maximumDisplayAsleepSkips`（20 次）后强制刷新一次；系统/屏幕唤醒通知会清空跳过计数并 `refreshAll()`。

### 1.2 `BatteryStatus` 字段与语义

`Sources/StatusTrioCore/Models/StatusSnapshot.swift`

```swift
struct BatteryStatus: Equatable, Sendable {
    let rawPercentage: Int?
    let isPresent: Bool
    let isCharging: Bool
    let isCharged: Bool
    let timeToFullChargeMinutes: Int?
    let isLowPowerMode: Bool
    let isConnectedToPower: Bool

    var percentage: Int {
        guard isPresent else { return 100 }
        let value = rawPercentage ?? 100
        return min(100, max(0, value))
    }
}
```

注意：

- `percentage` 在 `isPresent == false` 时返回 **100**（占位语义），航海模式控制器必须先判断 `isPresent`，否则会把无电池设备误判为满电。
- `isCharging == false` 不代表没接电源：可能是达到 MCL 上限、被 SMC 抑制、或系统正在涓流维护。航海模式判断「是否要暂停充电」应优先看 `isConnectedToPower` + `percentage` + 后端读回的充电抑制状态。
- `isCharged` 表示系统认为已充满；`timeToFullChargeMinutes` 只在充电时有值。
- `BatteryStatus` 是 `StatusSnapshot` 的一部分，`StatusSnapshot` 又在图标渲染的相等性/缓存键路径上。**航海模式自己的瞬时状态（保持中/充电中/失败）不要塞进 `StatusSnapshot`。**

### 1.3 BatteryStatus 如何进入 SystemStatusStore

`Sources/StatusTrioCore/Store/SystemStatusStore.swift`

1. `start()` 中 `batteryMonitor.start()`。
2. 读取 `let batteryUpdates = batteryMonitor.updates`，启动一个长期 `Task`：

```swift
for await value in batteryUpdates {
    guard let self else { return }
    self.applyBattery(value)
}
```

3. `applyBattery(_:)`（约 1668 行）：

```swift
private func applyBattery(_ value: BatteryStatus) {
    publish(snapshot.replacingBattery(value))
}
```

4. `publish(_:immediately:)`（约 1799 行）：
   - 与 `lastPublishedSnapshot` 比较，值没变则不写 `@Published`；
   - 写入 `snapshot`（`@Published private(set)`）；
   - 如果 popover 打开，经 500 ms `popupDebounceInterval` 写入 `popupSnapshot`；`immediately: true` 的交互写入绕过防抖。

5. 下游订阅：
   - **菜单栏图标**：`IconPresentationViewModel` 在 `AppEnvironment` 中以 `store.$snapshot` 为输入；`StatusBarController` 还订阅 `store.$snapshot` 更新可访问性值。
   - **状态面板**：`StatusPanelViewModel` 用 `store.$popupSnapshot` 映射 `PanelSummaryState` / `PanelDetailState`；`BatteryStatusView`、`BatteryDetailsView` 只消费这些 presentation state。
   - **设置界面**：`BatterySectionView` 同时观察 `SettingsStore` 和 `SystemStatusStore`，直接用 `statusStore.snapshot.battery.isPresent` 等字段。
   - **电池详情页**：`BatteryDetailsController` 由 store 持有，`activate(state:)` 后按自己的 2 s/15 s 循环读取 registry + SMC；它是详情页专属，不是全局状态源。

### 1.4 `SailingModeController` 应该订阅什么（以及不该订阅什么）

建议注入/订阅：

```swift
// 只需要电池状态，不需要整个快照
let batteryUpdates = store.$snapshot
    .map(\.battery)
    .removeDuplicates()
    .eraseToAnyPublisher()

// 设置
let sailingSettings = settings.$sailingModeSettings
    .removeDuplicates()
    .eraseToAnyPublisher()

// Helper 就绪度（若使用 SMC backend）
let helperReadiness = PrivilegedHelperManager.shared.readinessPublisher

// 与「立即充满」的互斥
let chargeToFullNowState = chargeToFullNow.$presentation

// 系统生命周期
NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
NSApplication.willTerminateNotification（仅作为 best-effort 恢复）
```

**不要订阅：**

- `store.$popupSnapshot`：只在 popover 可见时更新，且带 500 ms 防抖；航海模式必须在面板关闭时继续工作。
- `BatteryDetailsController.$details`：只有详情页打开才活跃，且会做 SMC 功率采样；与航海模式无关。
- `PowerSamplingService` 的 2 秒采样：那是功率读数，不是充电控制；额外订阅只会增加 SMC 连接次数。
- `StatusSnapshot` 中新增字段：会进入图标渲染的相等性/缓存路径，且图标并不需要知道航海状态。

控制器应实现幂等的 `batteryDidChange(_:)`，因为 `AsyncStream` 是 `bufferingNewest(1)`，连续快速变化可能只保留最后一帧；重复的 `BatteryStatus` 不应产生重复写。

---

## 2. 现有充电控制面

### 2.1 类型职责边界

| 类型 | 位置 | 职责 | 关键限制 |
| --- | --- | --- | --- |
| `BatteryChargeControlling` | `Sources/StatusTrioCore/Battery/BatteryChargeControlling.swift` | 充电上限的读/写抽象：`capability`、`readState()`、`chargeToFullNow()`、`restoreChargeLimit(to:expectedLimit:)` | `@MainActor`；只服务「立即充满」语义，不含任意区间控制 |
| `PowerUIChargeController` | 同上 | 真实 PowerUI 桥接；动态加载 `PowerUI.framework`，调用 `PowerUISmartChargeClient` | 仅 macOS 26.4+ / arm64；MCL 上限 80–95（桥接层 `STIsRestorableChargeLimit` 为 `80..<100`） |
| `ChargeToFullNowController` | `Sources/StatusTrioCore/Battery/ChargeToFullNowController.swift` | 「立即充满」状态机：需求、会话持久化、取消、恢复、确认、错误展示 | 只在 popover 电池区可见时接需求；`session` 可跨启动保存 |
| `ChargeToFullNowSession` / `…SessionStore` | `ChargeToFullNowSession.swift` | 持久化 `originalLimit` + `acceptedAt`，键为 `chargeToFullNow.session.v1` | 用户退出/重启后仍可能提示确认 |
| `SystemChargeLimitReader` | `Sources/StatusTrioCore/Monitoring/SystemChargeLimitReader.swift` | 只读 `/Library/Preferences/com.apple.powerd.charging.plist`，解析 `ChargeCtrlPolicy` | 私有 plist；override 期间 `policies` 可能为空；只用于显示/默认值，不是控制 API |
| `PowerUIChargeController` 使用的 C 桥 | `Sources/PowerUIPrivateAPI/PowerUIPrivateAPI.{h,m}` | ABI 校验、`isMCLSupported`、`isMCLCurrentlyEnabled`、`getMCLLimit`、`availableChargeLimits`、`smartChargingUIState`、`temporarilyDisableMCL`、`enableMCL`、`setMCLLimit` | 私有 API，无兼容承诺；`STPlatformSupported` 仅 26.4+；arm64 条件编译 |

### 2.2 PowerUI private API 能做什么

- 读取 MCL 是否支持、当前是否启用（原始值）、MCL 上限、可用上限列表、Smart Charging UI 状态、`chargingOverrideAllowed`。
- `temporarilyDisableMCL:`：等价于系统「立即充满」，把 MCL 置为临时 override（原始值 3，limit 100），实际开始充电；实测无管理员提示、无 Helper。
- `enableMCL:`：重新启用 MCL；会先恢复 PowerUI 保存的 override 前上限，再应用后续设置。
- `setMCLLimit:`：设置持久化 MCL 上限（项目桥接只接受 80–95 的 5% 步进）。
- 所有操作都作用于**同一个系统 MCL 策略**，由 `powerd` 持久化；App 退出后策略仍在。

### 2.3 PowerUI private API 不能做什么

- **不能设置任意下限/区间**：没有「低于 75% 时恢复充电」的 API；系统只提供约 5% 的固定滞回（见外部资料 BatteryKeeper 2026-10-20 对 macOS 27 的测量）。
- **不能低于 80%**：macOS 27 上原生 MCL 的校验/应用路径硬下限为 80%（batt issue #152 的评论也报告了这一点）；项目桥接同样只接受 80–95。
- **不能在 Intel Mac 或 macOS < 26.4 使用**：`STPlatformSupported` 与 `#if __arm64__` 双重限制。
- **不能保证持久化/恢复语义**：`temporarilyDisableMCL:` 会把持久化上限改成 100 且不会自动恢复；项目因此需要显式「恢复上限」设置。
- **不能与「立即充满」共用同一状态而不冲突**：两者都改 MCL；一个把 limit 设成 80，另一个临时覆盖到 100，取消时又可能恢复到 95，状态会互相覆盖。
- **不能提供 SMC 充电抑制**：完全没有 `CH0B` 之类的接口。

### 2.4 为什么航海模式需要 SMC 写（如果确实需要）

「航海模式（Sailing Mode）」的常见产品定义（参考 AlDente 的 Sailing Mode）是：

> 用户设定一个区间，例如 75%–80%。电池充到 80% 后暂停充电，让电量自然下降到 75%，再恢复充电，循环保持在区间内。

按这个定义：

- PowerUI MCL 只能给出一个**静态上限**（80–95），不能指定下限；系统自带的滞回固定在 5% 左右，且下限不可配置。
- 要在任意电量区间内反复「暂停/恢复」充电，必须直接控制充电开关。macOS 上没有公开 API，`pmset` 也不提供充电上限写入（macOS 26.4 Beta 的社区讨论同样确认 `pmset` 不支持修改 Charge Limit）。
- 因此，**如果产品要求任意区间（尤其低于 80%）或 macOS 13–26.3 / Intel 支持，SMC 写是唯一路径**；如果产品接受“80–95% 静态上限 + 系统 5% 滞回”，则可以完全不做 SMC，只做 PowerUI 包装。

SMC 写路径的硬约束：

- macOS 13–26.6：`CH0B`（部分机型还有 `CH0C`/`CHTE`）可写；AlDente 的公开 `Helper.swift` 使用 `CH0B`：`0x02` 暂停充电、`0x00` 恢复。Intel 与 Apple Silicon 的旧固件都可能支持，但机型差异必须逐机验证。
- macOS 26.7+/27（含对应安全更新）：`CH0B`/`CH0C`/`CHTE` 变成 0 字节占位或直接缺失；`bfF0`/`bfD0`/`bfE0` 以及 `AppleSmartBattery` 的 `SetChargingEnabled` 等接口即使 root 也返回 `kIOReturnNotPrivileged`。原因大概率是私有 entitlement `com.apple.private.iokit.soc-limit`，第三方无法签名获得。`BCLM`/`CHWA` 在更早的 macOS 15 就已经因内核 entitlement 限制而不可用。
- 目前 macOS 27 上仍存在、且外部资料报告可写的充电相关键是 `CHIE`（适配器切断，`0x08` 切断、`0x00` 恢复）；本机只读已确认 `CHIE` 存在（type `hex_`、size 1、当前值 `0x00`），但**第三方 root 写入权限仍未知**。它是「用户态适配器门控」而不是固件充电上限：只在控制进程清醒时有效，切断适配器后 Mac 走电池，控制器崩溃/睡眠时可能持续放电。这是高风险路径，不应作为第一版默认能力。

> 结论：**航海模式不是「一定要 SMC 写」，而是「要做成真正的区间控制就一定需要 SMC 写；只做静态上限则不需要」。** 这是第 11 节第 1 个 Lead 决策。

### 2.5 与 ChargeToFullNow 的互斥设计

`ChargeToFullNowController` 的状态：

```swift
enum ChargeToFullNowPresentation {
    case hidden, available, applying, chargingToFull, failed, unavailable
    case cancelConfirmationRequired(limit: Int), cancelPending, cancelling
    case cancelFailed(reason: ChargeToFullNowFailure)
    case cancelLimitChangedConfirmation(current: Int, target: Int)
    case limitRestored(limit: Int)
}
```

其中 `.chargingToFull` 既可能是本 App 的 session，也可能是 macOS 自己的电池菜单启动的 override；两者都会让 `PowerUI.readState().indicatesTemporaryOverride == true`（`mclEnabledRawValue == 3`）。

**互斥规则（建议写进 `ChargeControlArbiter` / `ChargeModeCoordinator`）：**

1. 同一时刻只有一个「充电控制租约」：
   - `SailingModeController` 持有租约时，`ChargeToFullNowController.update(...)` 必须发布 `.hidden`，`performQuickToggle` 返回 `false`；
   - `ChargeToFullNowController` 处于 `.applying`、`.chargingToFull`、`.cancelling`、`.limitRestored` 或存在 `session` 时，Sailing Mode 不得开始，UI 显示「请先取消立即充满」。
2. **只要检测到 MCL 原始值 3（临时 override）或 `ChargeToFullNowController` 处于 `.chargingToFull`，Sailing Mode 立即进入 `.suspended(.chargeToFullNow)` 并先恢复充电**。这一步必须覆盖 macOS 电池菜单的「立即充满」——用户可能不经过 Status Trio 的 UI。
3. 如果 Sailing Mode 使用 SMC `CH0B` 抑制充电，而 macOS 菜单启动了 CTFN，`CH0B` 仍然会阻止实际充电；所以检测到 override 后必须先写 `CH0B = 0x00`，再让系统充电。
4. 如果 Sailing Mode 使用 PowerUI MCL（路线 A），CTFN 的 `temporarilyDisableMCL:` 会覆盖 MCL；Sailing Mode 检测到 raw 3 后暂停，CTFN 结束后重新应用自己的上限（或让用户确认）。**不要把「Sailing Mode 的 MCL」和「CTFN 的恢复上限」混用同一个 `chargeToFullRestoreLimit` 设置。**
5. 关闭 Sailing Mode / 退出 App 时，先恢复充电，再清租约；恢复失败要显示错误并保留可重试状态。
6. 建议在 `ChargeToFullNowController` 里加一个只读的 `var isEngaged: Bool`（覆盖 `.applying`/`.chargingToFull`/`.cancelling`/`.limitRestored`/`session != nil`），避免 Sailing Mode 直接读 private `session`。
7. 所有入口都要经过同一个 gate：`BatterySectionView` 的开关、`BatteryStatusView` 的 CTFN 按钮、`ChargeToFullNowActionView`、`StatusBarController` 的右键 quick action、以及 macOS 系统电池菜单（只能检测，不能阻止）。

> 关键洞察：**如果两者都使用 PowerUI MCL，互斥只能靠「检测 + 让路 + 重新应用」，无法从根源阻止 macOS 菜单启动的 CTFN。** 如果 Sailing Mode 使用 SMC `CH0B`，控制面分离（MCL vs CH0B），冲突处理更干净；这是 SMC 路线的一个架构优势，代价是 Helper 和 OS 兼容性。

### 2.6 SettingsStore 中与电池 / Helper 相关的键

| 键 / 属性 | 默认值 | 范围 / 说明 |
| --- | --- | --- |
| `chargeToFullRestoreLimit` | `95` | `80...95`，5% 步进；CTFN 取消时恢复的目标；启动时用系统当前 limit 或 95 初始化 |
| `showsChargeToFullNowButton` | `true` | 只控制摘要卡是否显示 CTFN 行；详情页不受它限制 |
| `controlsLowPowerMode` | `false` | 同时是「Low Power Mode 功能开关」和「Helper 用户意图」；`savedLowPowerModeControlPreference` 首次为 nil |
| `autoEnablesLowPowerMode` | `false` | 低于阈值自动开 Low Power Mode；需要 `controlsLowPowerMode` 和 Helper ready |
| `autoLowPowerThreshold` | `20` | `0...100`，与 `batteryCriticalThreshold` 分离 |
| `batteryFullThreshold` | `BatteryIconOptions.defaultFullThreshold` | `50...100`，只影响图标圆环「满格」显示，不是控制 API |
| `batteryCriticalThreshold` | `20` | `0...100`，只影响图标颜色 |
| `refreshIntervalSeconds` | `15` | `5...60`，`SystemStatusStore` 兜底轮询的间隔 |
| 建议新增 `sailingMode.v1` | disabled / upper 80 / lower 75 | 一个 JSON `Data` 键，保存 `SailingModeSettings`；不读取系统 limit，避免启动副作用 |

> 不要把航海模式的下限/上限塞进 `batteryFullThreshold`（显示阈值）或 `chargeToFullRestoreLimit`（CTFN 恢复目标）；三者语义不同，混用会导致取消/退出时写错值。

---

## 3. 特权 Helper 架构

### 3.1 现有文件与职责

| 文件 | 作用 |
| --- | --- |
| `Sources/PowerHelperProtocol/PowerHelperProtocol.swift` | 依赖无关 target：`PowerHelperConstants`（Mach service 名、plist 名、客户端 bundle/team、代码签名 requirement）与 `PowerHelperXPCProtocol`；`PowerHelperProtocolVersion` 当前为 **2** |
| `Sources/PowerHelperProtocol/LowPowerModeCommand.swift` | `pmset -a lowpowermode 0|1` 参数与解析 |
| `Sources/PowerHelperProtocol/HighPowerModeCommand.swift` | `pmset -a powermode 0|2`、`pmset -g cap` 与解析 |
| `Sources/StatusTrioPowerHelper/main.swift` | root daemon 入口：创建 `IdleExitMonitor`、`ListenerDelegate`、`NSXPCListener(machServiceName:)`，设置代码签名要求，`activate()`，`dispatchMain()` |
| `Sources/StatusTrioPowerHelper/ListenerDelegate.swift` | 接受连接、二次校验调用方、`exportedInterface = NSXPCInterface(with: PowerHelperXPCProtocol.self)`、`exportedObject = service`、连接生命周期计数 |
| `Sources/StatusTrioPowerHelper/PowerModeService.swift` | 实现 XPC 方法；`SystemPmsetRunner` 异步跑 `pmset`；`PowerHelperReply` 处理 Objective-C reply 的 `Sendable` |
| `Sources/StatusTrioPowerHelper/ClientAuthorization.swift` | `SecCodeCopyGuestWithAttributes` + `SecRequirementCreateWithString` 二次校验 |
| `Sources/StatusTrioPowerHelper/IdleExitMonitor.swift` | 连接计数、5 秒空闲退出、`ThrottleInterval=1` 配合 launchd 快速重启 |
| `Sources/StatusTrioPowerHelper/ConnectionLifetime.swift` | 把 interruption/invalidation 折叠成一次「客户端结束」事件 |
| `Sources/StatusTrioCore/App/PrivilegedHelperManager.swift` | `SMAppService.daemon(plistName:)` 注册、状态轮询、健康探测、恢复、UI 状态 |
| `Support/StatusTrioPowerHelper.plist` | `Label`、`BundleProgram`、`MachServices`、`AssociatedBundleIdentifiers`、`ThrottleInterval=1`；**没有** `RunAtLoad` / `KeepAlive` |
| `scripts/build-app.sh` | `PRIVILEGED_HELPER=1|0`；复制/签名 Helper 与 plist；写 `STIncludesPrivilegedHelper` |
| `scripts/verify-privileged-helper-bundle.sh` | 校验 minos 13.0 / SDK 26+、签名、Universal slice、Label、BundleProgram、MachServices、AssociatedBundleIdentifiers、ThrottleInterval、内嵌客户端 requirement |

### 3.2 协议版本从 2 升 3 的兼容策略

当前：

```swift
public enum PowerHelperProtocolVersion {
    public static let lowPowerMode = 1   // readLowPowerMode / setLowPowerMode
    public static let highPowerMode = 2  // readProtocolVersion + High Power Mode 方法
    public static let current = highPowerMode
}
```

建议：

```swift
public enum PowerHelperProtocolVersion {
    public static let lowPowerMode = 1
    public static let highPowerMode = 2
    public static let chargeInhibit = 3   // 新增 SMC 充电抑制/恢复方法
    public static let current = chargeInhibit
}
```

兼容矩阵：

| App 版本 | Helper 版本 | 行为 |
| --- | --- | --- |
| 旧 App（只认识 v1/v2） | 新 Helper（v3） | 旧 App 只调用旧 selector；新 Helper 全部保留，正常工作 |
| 新 App（认识 v3） | 旧 Helper（v2） | `readProtocolVersion` 返回 2；新 App 标记「需要更新 Helper」，不调用 v3 selector |
| 新 App | v1 Helper（无 `readProtocolVersion`） | selector 不存在导致连接失效；用「能否读 Low Power Mode」区分「旧 Helper」与「完全没有 Helper」（照抄 `HighPowerModeController.classifyProbeFailure` 的思路） |
| 新 App | 无 Helper / Ad-hoc 签名 | `PrivilegedHelperManager.isReady == false`；功能隐藏或显示未就绪提示 |

要点：

- **只新增方法时升 minor 版本**；如果只是改实现/修 bug，不升协议版本。
- 新方法必须是**追加**的，不能改变旧方法签名、参数顺序或语义。
- 版本检查应发生在任何新 selector 调用之前；`SailingModeController` 在 `start()` / `refresh()` 时先 `protocolVersion()`。
- `PowerModeService.readProtocolVersion` 返回 `PowerHelperProtocolVersion.current`；`HighPowerModeRunnerTests` 现有断言 `version == current` 会自动覆盖 v3。
- 旧 Helper 的 daemon 二进制可能仍在运行：5 秒 idle exit + `ThrottleInterval=1` 让它在连接结束后退出；App 更新后第一次连接可能仍会遇到旧进程，显示「需要更新」，用户重启 App/等待 idle exit 即可。若产品要求无感升级，可在 `PrivilegedHelperManager` 检测到 v2 时执行一次受控的 `unregisterForRecovery` / `register`（高风险，需单独评审）。

### 3.3 `PowerModeService` 与 `ListenerDelegate` 如何加服务

推荐最小改法（`ListenerDelegate` 保持不动）：

```text
ListenerDelegate(service: PowerModeService(...), idleExit: ...)
        │
        ▼
PowerModeService: NSObject, PowerHelperXPCProtocol
        ├── runner: any PmsetRunning          // 现有 pmset 逻辑
        └── smc: any ChargeInhibiting          // 新增 SMCPowerService
                ├── readChargeInhibitSupport(...)
                ├── readChargeInhibited(...)
                └── setChargeInhibited(...)
```

- `PowerModeService` 增加一个 `init(runner:smc:)`，默认 `smc` 为 `UnsupportedChargeInhibitor()`，这样现有 `SystemPmsetRunnerTests` / `HighPowerModeRunnerTests` 的 `PowerModeService(runner:)` 调用无需改动。
- `SMCPowerService` 单独放在 `Sources/StatusTrioPowerHelper/SMCPowerService.swift`，内部只依赖 Foundation + IOKit，不依赖 `StatusTrioCore`（避免把 AppKit/SwiftUI/Sparkle 链接进 root daemon）。
- `ListenerDelegate` 不需要认识 SMC；它只导出 `PowerModeService`。如果未来要把 pmset 与 SMC 拆成两个对象，也可以加一个 `PowerHelperService` 复合门面，但那会增加文件与测试面，不是最小方案。
- `main.swift` 负责把 `SMCPowerService` 传给 `PowerModeService`，并把「退出前恢复充电」挂到 `IdleExitMonitor` 的 `exitProcess` 闭包：

```swift
let smc = SMCPowerService()
let idleExit = IdleExitMonitor(exitProcess: {
    smc.restoreBeforeExit()   // 关键：root 进程退出前恢复 CH0B / CHIE
    exit(EXIT_SUCCESS)
})
let service = PowerModeService(runner: SystemPmsetRunner(), smc: smc)
let delegate = ListenerDelegate(service: service, idleExit: idleExit)
```

- 如果不想改 `IdleExitMonitor`，也可以在 `ListenerDelegate` 的 `ConnectionLifetime` 结束回调中调用 `smc.restoreBeforeExit()`；但连接结束后到进程真正退出有 5 秒窗口，越早恢复越安全。**建议两处都做：最后一个连接结束时立即恢复，退出闭包再兜底一次。**

### 3.4 SMAppService 注册 / 授权 / 空闲退出

`PrivilegedHelperManager`：

- `SystemPrivilegedHelperService.isSupported` 要求：
  - `Bundle.main.bundleURL.pathExtension == "app"`；
  - `AppMetadata.includesPrivilegedHelper == true`；
  - `Contents/Helpers/StatusTrioPowerHelper` 可执行；
  - `AppSigningIdentity.current()` 的 bundle id / team 与 `PowerHelperConstants.clientBundleIdentifier` / `clientTeamIdentifier` 完全一致。
- 用户第一次开启相关功能时 `setEnabled(true)` → `registerIfNeeded()` → `SMAppService.daemon(plistName:) .register()`。
- 注册后状态可能为 `.requiresApproval`；设置页显示「等待批准」并提供 `openLoginItemsSettings()`；App 回到前台时 `refreshAfterActivation()` 重新探测。
- 状态轮询 2 秒（pending 时）；pending 健康探测默认 60 秒、enabled 健康探测默认 300 秒，避免每次探测都把 root daemon 拉起来又 idle exit。
- `isReady = isEnabled && status != .notRegistered && isHelperResponsive`。原生状态可能长期显示 pending，但 XPC 已可用；UI 用 `isReady` 判断实际可用性。
- 空闲退出：
  - plist 无 `RunAtLoad` / `KeepAlive`；launchd 按需启动；
  - `IdleExitMonitor.start()` 立即启动 5 秒空闲窗口（连「被拒绝的连接」也能退出）；
  - 每个 accepted connection `connectionOpened()` 取消退出；最后一个 connection 结束 `connectionClosed()` 重新起 5 秒窗口；
  - `ThrottleInterval=1` 让下一次 Mach 消息能立即重启。

**对航海模式的影响：**

- Sailing Mode 若使用 Helper，必须复用同一个 `SMAppService` daemon，不要新增第二个 LaunchDaemon（会增加审批、签名、卸载复杂度）。
- 用户关闭 Sailing Mode 不应该 unregister Helper；只停止 XPC 请求即可，和 Low Power Mode 的现有语义一致。
- 若 Helper 未安装/未批准，Sailing Mode 的 Helper 路径必须 **fail-open**：不阻止正常充电，只显示提示。

### 3.5 打包、签名与 entitlements

- `scripts/build-app.sh`：
  - `PRIVILEGED_HELPER` 默认 `1`；
  - `Contents/Helpers/StatusTrioPowerHelper` 从 SwiftPM 产物复制；
  - `vtool -set-build-version macos <minos> <SDK>` 保持 minos 13.0、SDK 26+；
  - `Support/StatusTrioPowerHelper.plist` → `Contents/Library/LaunchDaemons/com.lingsmbp.StatusTrio.PowerHelper.plist`；
  - `AssociatedBundleIdentifiers:0` 改成实际 `BUNDLE_ID`；
  - `Info.plist` 写 `STIncludesPrivilegedHelper`；
  - Helper 先于 App 签名；Ad-hoc 构建会警告「Helper 已打包但无法工作」；
  - 最后执行 `verify-privileged-helper-bundle.sh`。
- 当前仓库**没有 `.entitlements` 文件**：Helper 是不带 sandbox entitlement 的 root LaunchDaemon，Developer ID + hardened runtime 签名。SMC 写不需要额外 entitlement（在键未被 Apple 收窄的旧系统上）；**不要伪造 `com.apple.private.iokit.soc-limit` 等私有 entitlement，也不要要求用户关闭 SIP**。
- `PRIVILEGED_HELPER=0`（App Store 风格）必须完全排除 Helper 和 plist；`PrivilegedHelperManager.isAvailable` 为 false，Sailing Mode 的 SMC 路径必须隐藏/提示不可用。
- 开发版 `BUNDLE_ID=com.lingsmbp.StatusTrio.dev.*` 无法通过 `isSupported` 的 bundle id 检查，因此 **Helper 相关功能的本地端到端测试必须用 Developer ID、正式 bundle id 构建**；普通 Debug/Ad-hoc 只能测 fake。

### 3.6 测试替身位置

- `Tests/StatusTrioPowerHelperTests/`：
  - `SystemPmsetRunnerTests.swift`（`PmsetRunning` 假实现、超时/非零退出/解析）
  - `HighPowerModeRunnerTests.swift`（`StaticHighPowerRunner`，XPC reply 面）
  - `IdleExitMonitorTests.swift`（`ManualDelayedWorkScheduler`、`ExitRecorder`）
- `Tests/StatusTrioCoreTests/`：
  - `PrivilegedHelperManagerTests.swift` 的 `FakePrivilegedHelperService`
  - `HighPowerModeControllerTests.swift` 的 `FakeHighPowerClient`
  - `LowPowerModeControllerTests.swift` 的 `FakeLowPowerModeClient`
  - `ChargeToFullNowControllerTests.swift` 的 `StubBatteryChargeController`
- 新增 SMC 测试应沿用这些位置与风格：
  - `Tests/StatusTrioPowerHelperTests/SMCPowerServiceTests.swift`
  - `Tests/StatusTrioPowerHelperTests/PowerHelperProtocolV3Tests.swift`
  - `Tests/StatusTrioCoreTests/SailingModeControllerTests.swift`

---

## 4. SystemPowerReader 与 AppleSMC 80 字节 ABI

### 4.1 现有只读实现

`Sources/StatusTrioCore/Monitoring/SystemPowerReader.swift`

- 打开 `AppleSMC`：`IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))`；`IOServiceOpen(service, mach_task_self_, 0, &connection)`。
- 每次读取新建一个短连接，读完 `IOServiceClose`；固定键，不扫描键表。
- `exchange` 闭包：80 字节 request/response，`IOConnectCallStructMethod(connection, 2, input, 80, output, &size)`；要求 `KERN_SUCCESS && size == 80`。
- 读取流程：
  1. 填 key（0–3），`request[42] = 9`（read key info）；
  2. 校验 `response[40] == 0`，从 28 取 data size，从 32 取 data type；
  3. 把 28–31 的 size 复制进下一次 request；
  4. `request[42] = 5`（read bytes）；
  5. 从 `response[48...]` 解码：`flt `（4B little-endian Float）、`fpe2`/`sp78`（2B big-endian fixed-point）、`si16`/`ui16`（2B little-endian）。
- 注释明确：**「never issue write command 6」**。`SystemPowerReader` 是纯只读，不能直接复用于写。

### 4.2 80 字节 ABI（以现有代码使用的偏移为准）

| 偏移 | 长度 | 含义 | 备注 |
| --- | --- | --- | --- |
| 0 | 4 | key（FourCC） | 现有代码按 `key >> (offset * 8)` 逐字节写入，即内存中为 little-endian 的 FourCC 字节序 |
| 4–27 | 24 | SMC 版本/限制/属性等保留字段 | 写请求保持 0，除非有完整 ABI 依据 |
| 28 | 4 | data size（UInt32 LE） | key info 返回后复制 |
| 32 | 4 | data type（FourCC） | 现有代码用 `littleEndianUInt32` 读取后与 FourCC 数值比较，如 `0x666c7420` = `flt `、`0x75693820` = `ui8 `、`0x6865785F` = `hex_` |
| 36–39 | 4 | data attributes / 保留 | 保持 0 |
| 40 | 1 | result code | 0 为成功；非 0 是 SMC 错误 |
| 41 | 1 | status | 辅助状态 |
| 42 | 1 | command | 5 = read bytes，6 = write bytes，9 = read key info |
| 43–47 | 5 | 保留 | 0 |
| 48 | 32 | data payload | 读取结果/写入数据 |

> 这是 AppleSMC user client 的长期未公开 ABI。`SystemPowerReader` 已经验证了 9/5 两条命令；**Helper 的写路径需要新增命令 6**，必须独立实现、独立测试，不能假设 5 能写。

### 4.3 为什么 Helper 必须独立实现

- `SystemPowerReader` 在 `StatusTrioCore` target 内，依赖 Foundation + IOKit；`StatusTrioPowerHelper` 只依赖 `PowerHelperProtocol`，不能链接 `StatusTrioCore`，否则会把 AppKit、SwiftUI、Sparkle 等带入 root daemon（现有设计刻意避免）。
- `SystemPowerReader` 没有写命令、没有错误分类、没有连接复用；Helper 需要：
  - 固定键能力探测（`CH0B` / `CHIE`，不枚举键表）；
  - 写前 key info 校验（size/type）；
  - 写后 readback 验证；
  - 串行化（一个 daemon 内同一时刻只允许一个 SMC 事务）；
  - 退出前恢复。
- 因此建议在 `Sources/StatusTrioPowerHelper/SMCPowerService.swift` 内复制一份约 100–150 行的 `SMCConnection` / `SMCKeyCodec`，并用注释指向 `SystemPowerReader` 作为只读参考。不要把 `SystemPowerReader` 改成可写，也不要让 App 进程直接写 SMC。

### 4.4 Helper 内 AppleSMC 读写伪代码

```swift
// 只读探测：命令 9
func keyInfo(_ key: UInt32) -> (size: Int, type: UInt32)? {
    var request = [UInt8](repeating: 0, count: 80)
    writeKey(key, into: &request)          // 0..<4
    request[42] = 9                        // key info
    guard let info = exchange(request),
          info.count == 80, info[40] == 0 else { return nil }
    let size = leUInt32(info, at: 28)
    let type = leUInt32(info, at: 32)
    guard size > 0, size <= 32 else { return nil }
    return (size, type)
}

// 写 1 字节：命令 6，写后命令 5 读回
func writeByte(key: UInt32, value: UInt8) -> Bool {
    guard let info = keyInfo(key),
          info.size == 1,
          (info.type == 0x7569_3820 /* "ui8 " */ || info.type == 0x6865_785F /* "hex_" */) else {
        return false
    }
    var request = [UInt8](repeating: 0, count: 80)
    writeKey(key, into: &request)
    request.replaceSubrange(28..<32, with: leBytes(info.size))
    request[42] = 6                        // write bytes
    request[48] = value
    guard let response = exchange(request),
          response.count == 80, response[40] == 0 else { return false }
    // 不信任写入返回值，必须读回
    guard let readback = readByte(key: key) else { return false }
    return readback == value
}
```

- `CH0B`：建议值 `0x02` 暂停充电、`0x00` 恢复；写入前先 `keyInfo` 验证存在且 size==1。若机型返回 size 0 / `kIOReturnNotPrivileged` / type 不符，直接判定 `.unsupported`，不要尝试其他未知键。
- `CHIE`：外部资料报告 `0x08` 切断适配器、`0x00` 恢复，类型 `hex_`、1 字节。此路径必须单独 capability 标记，不能和 `CH0B` 混为同一个「充电抑制」语义。
- 不要写 `BCLM`、`CHWA`、`bfF0/bfD0/bfE0`：这些键在新系统要么不存在，要么需要私有 entitlement。
- 所有 SMC 访问串行化：`SMCPowerService` 内部用专用 `DispatchQueue` 或 `NSLock`；XPC 请求可能并发到达，不能并发 `IOConnectCallStructMethod` 同一连接。

### 4.5 能力矩阵（建议实现为 capability，而不是版本 if/else）

| 能力 | OS / 硬件 | 控制方式 | 区间 | 持久性 | Helper | 风险 |
| --- | --- | --- | --- | --- | --- | --- |
| `.nativeMCL` | macOS 26.4+ / arm64 | PowerUI `setMCLLimit` | 80–95（系统 UI 80–100） | `powerd` 持久化 | 否 | 私有 API；与 CTFN 共用 MCL |
| `.smcChargeInhibit` | macOS 13–26.6 / Intel + Apple Silicon（逐机验证） | SMC `CH0B` 0x02/0x00 | 任意 5% 步进 | 不持久，依赖 App/Helper | 是 | 键可能不存在/语义差异；退出必须恢复 |
| `.smcAdapterGate` | macOS 26.7+/27（`CHIE` 存在；本机已只读确认，写权限待验证） | `CHIE` 0x08/0x00 | 任意（需 MCL 或纯适配器循环） | 不持久，且只在清醒时 | 是 | 切断适配器、睡眠/崩溃风险；不推荐首版 |
| `.unsupported` | 其他 | — | — | — | — | 隐藏功能 |

`SailingModeController` 不应自己判断 `ProcessInfo.operatingSystemVersion`；应由 backend 的 `capability` 给出上述枚举，UI 根据 capability 决定显示哪些控件和文案。

---

## 5. 设置 UI 架构与放置

### 5.1 现有组件

`Sources/StatusTrioCore/UI/Settings/SettingsChrome.swift`：

- `SettingsPage`：滚动页面，可带 pinned header（电池页用 `StatusIconPreviewCard` 固定在顶部）。
- `SettingsGroup(title:footnote:content:)`：带标题/脚注的圆角卡片组。
- `SettingsRow`：图标 + 标题 + 副标题 + trailing 控件；支持 `subtitleStatus`（把状态文本拼到描述末尾，带颜色）和 `subtitleLink`。
- `SettingsToggleRow`：`SettingsRow` + 右侧 `.toggleStyle(.switch)`。
- `SettingsHintRow`：整行说明/警告。
- `Slider` 用法参考 `BatterySectionView` 的 restore limit 和 high-energy refresh interval：`HStack(spacing: 8) { Slider(...).frame(width: 130).controlSize(.small); Text("\(value)%").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing) }`。
- `SettingsDivider()`：卡片内分隔线。

现有电池/充电 UI 入口：

| 视图/控制器 | 现有内容 | 与航海模式的关系 |
| --- | --- | --- |
| `BatterySectionView` | `chargeManagementGroup`（CTFN 开关、restore limit）、`powerModesGroup`、`powerFlowGroup` | 新增 `sailingModeGroup` 的唯一主入口 |
| `BatteryStatusView` | 电池摘要行、Power Info Bar、CTFN action、快捷 Low/High Power 按钮 | 首版不改；若要显示航海状态需新增只读字段 |
| `BatteryDetailsView` | 详情行、Power Mode 控制、CTFN action、打开系统/App 电池设置 | 可选增加只读航海状态行 |
| `ChargeToFullNowActionView` | 摘要与详情页共用的 CTFN 按钮/确认/错误行 | 不改；由 `ChargeToFullNowController` 的 conflict gate 控制 |
| `GeneralSectionView` | 右键快捷动作选择器；`rightClickActionAvailability.chargeToFullNow` 只看 `isSettingAvailable` | 若 Sailing 活跃，建议把 CTFN quick action 标记不可用；否则 `performQuickToggle` 回退菜单仍安全 |
| `SettingsWindowController` | `show(section: .battery)` 打开电池页；`show()` 时 `PrivilegedHelperManager.shared.refresh()` | 打开设置页即可看到航海分组；Helper 状态在打开时刷新 |

`BatterySectionView` 结构：

- `SettingsPage(pinnedHeader: StatusIconPreviewCard)` + `fullBatteryContent`。
- `fullBatteryContent` 当前顺序：
  1. `noBatteryNoticeGroup`（无电池时）
  2. `panelVisibilityGroup`
  3. `chargeManagementGroup`（充电：CTFN 开关 + restore limit + 无法读系统上限提示）
  4. `powerModesGroup`（Helper 可用时；否则提示 `lowPowerModeHelperUnavailable`）
  5. `powerFlowGroup`
- `subtopic` 参数存在但**BatterySectionView 未使用**；Battery 是单页，`SettingsSubtopic` 只服务 App Icon。新增航海模式不需要新增 subtopic。

### 5.2 放置位置

按任务要求与现有信息架构，放在 **`chargeManagementGroup` 之后、`powerModesGroup` 之前**：

```swift
panelVisibilityGroup
chargeManagementGroup
sailingModeGroup          // 新增
if helper.isAvailable {
    powerModesGroup
} else {
    SettingsGroup(...) { SettingsHintRow(...) }
}
powerFlowGroup
```

这样「充电相关」的两个卡片相邻：上面是「立即充满」，下面是「航海模式」；用户能直观看到二者互斥。

### 5.3 航海模式分组建议

建议把子视图单独放 `Sources/StatusTrioCore/UI/Settings/SailingModeSettingsGroup.swift`，`BatterySectionView` 只加一行调用，减少与其它电池 UI 任务的冲突。

```swift
SettingsGroup(localization.string(.settingsBatteryGroupSailing)) {
    SettingsToggleRow(
        symbol: "sailboat.fill",                 // 用 SymbolFallback.name(_, "battery.75")
        tint: .blue,
        title: localization.string(.settingsBatterySailingEnabled),
        subtitle: localization.string(.settingsBatterySailingEnabledDescription),
        subtitleStatus: sailingStatusText,        // 见下
        isOn: sailingMode.enabledBinding
    )
    .disabled(!sailingMode.isAvailable)

    if sailingMode.isEnabled {
        SettingsDivider()

        SettingsRow(
            "arrow.up.to.line",
            tint: .blue,
            title: localization.string(.settingsBatterySailingUpperLimit),
            subtitle: localization.string(.settingsBatterySailingUpperLimitDescription)
        ) {
            HStack(spacing: 8) {
                Slider(value: upperBinding, in: sailingMode.upperLimitRange, step: 5)
                    .controlSize(.small)
                    .frame(width: 90)
                Text("\(sailingMode.upperLimit)%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }

        if sailingMode.supportsCustomLowerLimit {
            SettingsDivider()
            SettingsRow(
                "arrow.down.to.line",
                tint: .blue,
                title: localization.string(.settingsBatterySailingLowerLimit),
                subtitle: localization.string(.settingsBatterySailingLowerLimitDescription)
            ) {
                HStack(spacing: 8) {
                    Slider(value: lowerBinding, in: sailingMode.lowerLimitRange, step: 5)
                        .controlSize(.small)
                        .frame(width: 90)
                    Text("\(sailingMode.lowerLimit)%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }

        if sailingMode.needsHelper {
            helperStatusRow   // 等待批准 / 打开登录项 / 需要更新
        }
        if let error = sailingMode.lastError {
            SettingsHintRow(text: error) // 或带重试按钮
        }
        SettingsHintRow(text: localization.string(.settingsBatterySailingCaveat))
    }
}
```

控件与文案要点：

- 开关默认关闭；关闭时不显示滑杆，避免页面膨胀。
- 上限/下限都按 5% 步进；下限必须至少比上限低 5%，否则禁用保存并提示。
- `subtitleStatus`：保持状态用绿色/次要色，例如：
  - `.holding`：`保持中 · 当前 78% / 上限 80%`
  - `.chargingToUpper`：`充电中 · 目标 80%`
  - `.waitingForPower`：`等待连接电源`
  - `.suspended(.chargeToFullNow)`：`已暂停：立即充满正在运行`
  - `.suspended(.sleep)`：`已暂停：系统睡眠`
  - `.helperUnavailable`：`电源助手未就绪`
  - `.needsHelperUpdate`：`需要更新电源助手`
  - `.unsupported`：`此 Mac / 系统不支持航海模式`
  - `.failed`：`航海模式写入失败` + 详细错误（caption2，红色）
- `SettingsHintRow` 的说明要诚实：SMC 路线只在 macOS 13–26.6 的多数机型可用；macOS 26.7+/27 不可用或仅适配器门控。不要写「支持所有 Mac」。
- 电池详情页可选增加只读状态行（不提供操作），但首版建议只放在设置页，避免 `PanelDetailState` / `BatteryDetailsView` 的模型扩展。

### 5.4 状态展示建议

- **设置页**：唯一主入口；用 `subtitleStatus` + 一行 `SettingsHintRow`。helper 未就绪时显示 `lowPowerModeRequiresApproval` 风格的提示和「打开登录项」按钮（复用 `BatterySectionView` 现有的 helper 提示）。
- **电池详情页**：如果产品希望可见，建议在 `BatteryDetailsView` 的 power mode 控制下方加一行只读文案 `航海模式：保持 75%–80%`；需要新增 `PanelDetailState` 字段或直接注入 `SailingModeController`，属于额外共享文件改动。首版可不做。
- **popover 摘要 / 菜单栏图标**：首版不改。航海状态不是图标渲染输入，且菜单栏没有空间；如果要显示，后续单独评审。
- **右键 quick action**：`StatusBarController.quickActionAvailability.chargeToFullNow` 目前只看能力，不看冲突；`performQuickToggle` 返回 false 会回退到菜单，所以功能上安全。若 Sailing Mode 正在保持，建议同时把 `chargeToFullNow` 标记为不可用（需要把 `sailingMode.isActive` 传入 `StatusBarController`；非最小改动）。

### 5.5 本地化：12 种语言与添加流程

仓库实际语言（`AppLanguage.allCases` / `Sources/StatusTrioCore/Resources/`）：

`en`、`zh-Hans`、`zh-Hant`、`ja`、`ko`、`es`、`fr`、`de`、`it`、`pt-BR`、`ru`、`ar`（12 种；阿拉伯语为 RTL）。

添加 key 的步骤：

1. 在 `Sources/StatusTrioCore/Localization/LocalizationKey.swift` 增加 case，例如：
   ```swift
   case settingsBatteryGroupSailing = "settings.battery.group.sailing"
   case settingsBatterySailingEnabled = "settings.battery.sailing.enabled"
   case settingsBatterySailingEnabledDescription = "settings.battery.sailing.enabledDescription"
   case settingsBatterySailingUpperLimit = "settings.battery.sailing.upperLimit"
   // ...
   ```
   建议所有 key 以 `settings.battery.sailing` 为前缀，避免与其它功能冲突。
2. 在 **12 个** `Sources/StatusTrioCore/Resources/*.lproj/Localizable.strings` 中为每个新增 key 各加一行：
   ```text
   "settings.battery.group.sailing" = "航海模式";
   ```
   注意 `%d` / `%@` 占位符必须与英文一致；不要出现重复 key。
3. 视图统一用 `localization.string(.settingsBatterySailingEnabled)` / `localization.format(.settingsBatterySailingStatusValue, current, upper)`。
4. 运行：
   ```bash
   bash scripts/test.sh 'LocalizationTests'
   bash scripts/test.sh 'LocalizationParityTests'
   bash scripts/verify-local.sh docs
   ```
   - `LocalizationTests.testEveryLanguageHasEveryNonEmptyKey` 检查所有 `LocalizationKey.allCases` 在每种语言都有非空值；
   - `LocalizationParityTests` 检查 12 个 `.strings` 与英文 key 集合完全一致、无重复、占位符一致；
   - `verify-local.sh docs` 还会跑 `ChargingEffectLocalizationTests`、`MenuBarHelpLocalizationTests` 和 workflow policy。
5. 阿拉伯语 RTL 布局需要单独截图/布局检查；设置页固定宽度 `SettingsView.width = 720`，侧栏 `196`，内容区约 524 pt。

---

## 6. 测试架构

### 6.1 现有风格

- **XCTest**：`Tests/StatusTrioCoreTests` 中约 232 个文件使用 `import XCTest`（含 `@MainActor final class ...: XCTestCase`）；`Tests/StatusTrioPowerHelperTests` 全部是 XCTest。
- **Swift Testing**：约 116 个文件使用 `import Testing` / `@Suite` / `@Test`，多用于纯逻辑/渲染快照。
- 新控制器/Helper 测试建议沿用 **XCTest**，与 `ChargeToFullNowControllerTests`、`HighPowerModeRunnerTests` 邻近风格一致。
- 异步等待使用 `XCTestExpectation` / 自定义 `waitUntil`（如 `ChargeToFullNowControllerTests` 末尾的 `waitUntil`），不要引入第三方测试库。
- UI 测试默认跳过；不要新增会显示真实窗口/菜单栏项的测试，除非用 `VisibleUITestCase` 明确标注。

### 6.2 现有充电相关测试样本

- `Tests/StatusTrioCoreTests/ChargeToFullNowControllerTests.swift`
  - `StubBatteryChargeController`：可配置 `capability`、`deviceState`、`restoreResult`、`restoreState`、`suspendsRestore`，记录 `readCount`/`writeCount`/`restoreTargets`；用 `CheckedContinuation` 控制异步完成。
  - 覆盖能力不可用、重复请求、取消确认、restore 验证、外部 limit 变化、重启 session、快速切换等分支。
- `Tests/StatusTrioCoreTests/ChargeToFullNowPanelIntegrationTests.swift`
  - `PanelChargeBackend`：验证 summary 只在设置开启时显示、详情页始终显示、stop 清 demand。
- `Tests/StatusTrioCoreTests/SystemChargeLimitReaderTests.swift`
  - 用构造的 keyed archive 测试 plist 解析。
- `Tests/StatusTrioPowerHelperTests/HighPowerModeRunnerTests.swift`
  - 版本 handshake、capability、互斥写顺序、XPC reply。
- `Tests/StatusTrioPowerHelperTests/IdleExitMonitorTests.swift`
  - 空闲退出/连接取消/不重复退出。
- `Tests/StatusTrioPowerHelperTests/SystemPmsetRunnerTests.swift`
  - 子进程超时、非零退出、stdout 解析。

### 6.3 脚本过滤方式

- `bash scripts/test.sh [filter]`：
  - 先无条件跑 `scripts/check-forbidden-patterns.sh`；
  - 有 filter 时 `swift test --filter "$1"`，若输出 `No matching test cases were run` 则失败；
  - 无 filter 时跑全量 `swift test`。
- `bash scripts/verify-local.sh <quick|docs|full> [swift-test-filter]`：
  - `quick`：shell syntax + forbidden patterns + focused filter（默认 `ForbiddenPatternGuardTests|Issue30WiFiAlignmentTests|IconSurfaceIntegrationTests`）；
  - `docs`：shell syntax + forbidden patterns + 4 个本地化过滤 + workflow policy；
  - `full`：全量 Swift tests + Release build + 非 Universal 本地 app bundle + platform/SDK 契约 + Helper bundle 契约 + 原生兼容/依赖检查 + 离线 release 流程模拟。
- 示例：
  ```bash
  bash scripts/test.sh 'SailingModeControllerTests'
  bash scripts/test.sh 'SailingModeControllerTests|SailingModeSettingsTests'
  bash scripts/verify-local.sh quick 'SailingModeControllerTests|SMCPowerServiceTests'
  bash scripts/verify-local.sh full
  ```
- 按 AGENTS.md：Helper / XPC / LaunchDaemon / `Package.swift` / 部署目标相关变更必须 `full`；普通控制器/设置 UI 可先 `quick`，交付前 `full`。

### 6.4 建议的测试文件与分支

**`Tests/StatusTrioCoreTests/SailingModeControllerTests.swift`**

使用 `FakeSailingChargeController`（记录 `setChargingEnabled` 调用、可挂起、可失败）：

1. capability `.unsupported` → `.off`/`.unsupported`，`readCount == 0`，无写。
2. 开关打开但 Helper not ready → `.helperUnavailable`，无写，充电不被阻断。
3. 接电、`percentage >= upper` → 请求暂停一次；连续重复 `batteryDidChange` 不重复写。
4. `percentage <= lower` → 请求恢复一次；区间内 → 不写（滞回）。
5. 未接电 → `.waitingForPower`，恢复充电；重新接电 → 重新评估。
6. 关闭开关 → 先恢复充电，再 `.off`；恢复失败 → `.failed` 并保留重试。
7. 系统睡眠 → 恢复充电并 `.suspended(.sleep)`；唤醒且仍启用 → 重新评估/重新暂停。
8. CTFN 进入 `.chargingToFull` → `.suspended(.chargeToFullNow)` + 恢复；CTFN 结束后不自动写，等下次 tick 或用户确认。
9. 外部 MCL raw 3（macOS 菜单启动 CTFN）→ 同上。
10. 外部 MCL limit 变化（非自己写入）→ `.suspended(.externalLimitChanged)`，不回写覆盖。
11. 上下限非法（lower >= upper、非 5% 步进）→ 拒绝并保持旧值。
12. 持久化：`SailingModeSettings` 默认值、round-trip、迁移/损坏数据回退。
13. `stop()`/`applicationWillTerminate` → 调用恢复；helper 连接关闭 → `.suspended(.helperUnavailable)`。

**`Tests/StatusTrioCoreTests/SailingModeSettingsTests.swift`**

- 默认 `disabled / upper 80 / lower 75`；
- upper/lower 夹取与 5% 对齐；
- `lower < upper` 校验；
- 编码/解码 round-trip；
- 旧版本缺失 key 时默认值。

**`Tests/StatusTrioPowerHelperTests/SMCPowerServiceTests.swift`**

用 `FakeSMCTransport`（不打开真实 IOKit）：

- `CH0B` keyInfo 返回 size 1 / `ui8 ` → `readSupport == .ch0b`；
- `setChargingInhibited(true)` 写 `CH0B`、值 `0x02`；`false` 写 `0x00`；
- keyInfo 缺失 / size 0 / type 不符 → `.unsupported`，不写；
- 写返回 `result != 0` / `kIOReturnNotPrivileged` → 抛错；
- 写后 readback 不一致 → 失败，不返回成功；
- `CHIE` 路径仅在 capability 允许时尝试，`0x08` / `0x00` 验证；
- `restoreBeforeExit()` 无论当前状态都写回 `0x00`；连续调用幂等；
- 并发请求串行化（多个 `set` 不交错）。

**`Tests/StatusTrioPowerHelperTests/PowerHelperProtocolV3Tests.swift`**

- `PowerHelperProtocolVersion.current == .chargeInhibit`（3）；
- `lowPowerMode == 1`、`highPowerMode == 2` 保持不变；
- `PowerModeService.readProtocolVersion` 回 3；
- 新方法 reply 语义：成功返回 daemon 观察到的状态；失败返回 `false` + 错误描述；
- 旧 `PowerModeService(runner:)` 默认 SMC 为 unsupported，所有旧测试仍通过。

**`Tests/StatusTrioCoreTests/SettingsViewTests.swift`**

- 新增 `BatterySectionView` 在 `sailingMode != nil` 时能渲染（`NSHostingView` 不崩溃）；
- 12 种语言下文案非空（由 `LocalizationTests` 覆盖）；
- 新增 key 在源码中被使用（可用现有 source-scanning 测试风格）。

---

## 7. 最小集成方案

### 7.1 路线 A：PowerUI 静态上限版（推荐先做，最小）

**定位**：在 macOS 26.4+ Apple Silicon 上，复用系统 MCL，把「航海模式」实现为「可配置的充电上限 + 系统固定滞回」。不做 SMC、不改 Helper、不改协议。

**新增文件：**

| 文件 | 作用 |
| --- | --- |
| `Sources/StatusTrioCore/Sailing/SailingModeController.swift` | 状态机、订阅电池/设置/CTFN、启停、错误状态 |
| `Sources/StatusTrioCore/Sailing/SailingChargeControlling.swift` | `SailingChargeControlling` 协议 + `PowerUISailingChargeController`（包装现有 `PowerUIChargeController` / `STPowerUIChargeBridge`） |
| `Sources/StatusTrioCore/Settings/SailingModeSettings.swift` | `Codable/Equatable/Sendable` 设置结构、默认值、范围/步进校验、UserDefaults 编解码 |
| `Sources/StatusTrioCore/UI/Settings/SailingModeSettingsGroup.swift` | 设置页分组视图 |
| `Tests/StatusTrioCoreTests/SailingModeControllerTests.swift` | 状态机测试 |
| `Tests/StatusTrioCoreTests/SailingModeSettingsTests.swift` | 设置测试 |

**修改文件：**

| 文件 | 改动 | 冲突风险 |
| --- | --- | --- |
| `Sources/StatusTrioCore/Battery/BatteryChargeControlling.swift` | 给协议加 `setChargeLimit(_:)` / `disableChargeLimit()`（默认实现返回 `.failure`），`PowerUIChargeController` 实现 | 中：与 CTFN 共用；需严格校验 MCL |
| `Sources/PowerUIPrivateAPI/PowerUIPrivateAPI.{h,m}` | 暴露 `setMCLLimit:` / `disableMCL:` 的桥接方法；把 `disableMCL:` 作为可选 selector 校验 | 高：私有 API ABI；需要新增 fake ABI 测试 |
| `Sources/StatusTrioCore/Settings/SettingsStore.swift` | 增加一个 `@Published var sailingModeSettings` + 一个 `sailingMode.v1` 默认 key + init 解码 | 高：2301 行大文件；尽量只加 2–3 个插入点 |
| `Sources/StatusTrioCore/UI/Settings/BatterySectionView.swift` | 增加 `sailingMode: SailingModeController?` 参数 + `sailingModeGroup` 一行 | 高：电池 UI 常被改 |
| `Sources/StatusTrioCore/UI/Settings/SettingsView.swift` | 传递 `sailingMode` | 中 |
| `Sources/StatusTrioCore/UI/Settings/SettingsWindowController.swift` | 持有并传入 `sailingMode` | 中 |
| `Sources/StatusTrioCore/App/AppEnvironment.swift` | 创建 `SailingModeController`，`start()`/`stop()` 调用 | 高：集中 wiring |
| `Sources/StatusTrioCore/Localization/LocalizationKey.swift` + 12 个 `.strings` | 新增航海模式 key | 高：13 个文件 |
| `Sources/StatusTrioCore/Battery/ChargeToFullNowController.swift` | 增加 `isEngaged`；`update` 在 Sailing 活跃时 `.hidden`；`performQuickToggle` 返回 false | 中：CTFN 状态机复杂 |
| `Sources/StatusTrioCore/Presentation/Panel/StatusPanelViewModel.swift` | 把 Sailing 活跃传给 CTFN demand 或 gate | 高：面板 wiring 复杂 |

**路线 A 的构建影响**：无 Helper、无 `Package.swift` 改动。

**路线 A 的限制（必须写进 UI 文案）**：

- 仅 macOS 26.4+ Apple Silicon；
- 上限 80–95%（沿用桥接范围）；
- 下限不可配置，系统固定约 5% 滞回；
- 与 CTFN 共用 MCL，必须互斥；
- 本质上是「系统充电上限」的另一种呈现，产品价值需要确认（用户已可在系统设置中设置 Charge Limit）。

### 7.2 路线 B：Helper v3 + SMC 完整版

> 现场核对后，路线 B 细化见第 16 节：当前 M3 Max / macOS 27.2 上应优先尝试 `PowerUI MCL + CHIE=0x08` 的组合，而不是 `CH0B`。

**定位**：支持 macOS 13–26.6（Intel/Apple Silicon，逐机验证）的任意区间；macOS 26.7+/27 需要单独决定是否支持 `CHIE` 适配器门控；否则标记不可用。

**新增文件：**

| 文件 | 作用 |
| --- | --- |
| `Sources/StatusTrioCore/Sailing/SailingModeController.swift` | 同上，但 backend 可切换 `.smcChargeInhibit` / `.smcAdapterGate` |
| `Sources/StatusTrioCore/Sailing/SailingChargeControlling.swift` | `SailingChargeControlling` 协议 + `SMCSailingChargeController`（XPC 客户端） |
| `Sources/StatusTrioCore/Monitoring/SailingModeClient.swift` | `SailingModeClienting` 协议 + `XPCSailingModeClient`（3 秒超时、OneShotReply 复用） |
| `Sources/StatusTrioCore/Settings/SailingModeSettings.swift` | 同上 |
| `Sources/StatusTrioCore/UI/Settings/SailingModeSettingsGroup.swift` | 同上 |
| `Sources/StatusTrioPowerHelper/SMCPowerService.swift` | SMC 连接、key info、读/写、capability、退出恢复 |
| `Sources/StatusTrioPowerHelper/SMCConnection.swift`（可选，若与 service 分离） | 80 字节 ABI 封装 |
| `Tests/StatusTrioCoreTests/SailingModeControllerTests.swift` | 状态机 |
| `Tests/StatusTrioCoreTests/SailingModeSettingsTests.swift` | 设置 |
| `Tests/StatusTrioPowerHelperTests/SMCPowerServiceTests.swift` | 假 SMC transport |
| `Tests/StatusTrioPowerHelperTests/PowerHelperProtocolV3Tests.swift` | 版本/回复 |

**修改文件：**

| 文件 | 改动 | 冲突风险 |
| --- | --- | --- |
| `Sources/PowerHelperProtocol/PowerHelperProtocol.swift` | 增加 v3 常量 + 3 个新方法（见 7.3） | 高：协议是 Helper 契约 |
| `Sources/StatusTrioPowerHelper/PowerModeService.swift` | 注入 `smc: any ChargeInhibiting`，转发 3 个新方法；默认 unsupported 保持旧测试 | 中 |
| `Sources/StatusTrioPowerHelper/main.swift` | 创建 `SMCPowerService`；`IdleExitMonitor` 退出闭包恢复；注入 `PowerModeService` | 中 |
| `Sources/StatusTrioPowerHelper/ListenerDelegate.swift` | 理论上不变；若复合服务则改导出对象 | 低–中 |
| `Package.swift` | `StatusTrioPowerHelper` target 增加 `.linkedFramework("IOKit")` | 低 |
| `Sources/StatusTrioCore/App/AppEnvironment.swift` | 创建 controller，按 capability 选择 backend；`start()/stop()` | 高 |
| `Sources/StatusTrioCore/Settings/SettingsStore.swift` | 同路线 A | 高 |
| `Sources/StatusTrioCore/UI/Settings/BatterySectionView.swift` | 同路线 A + Helper 提示 | 高 |
| `Sources/StatusTrioCore/UI/Settings/SettingsView.swift` / `SettingsWindowController.swift` | 传递 controller | 中 |
| `Sources/StatusTrioCore/Localization/LocalizationKey.swift` + 12 `.strings` | 同路线 A，额外 Helper/不支持文案 | 高 |
| `Sources/StatusTrioCore/Battery/ChargeToFullNowController.swift` / `StatusPanelViewModel.swift` | 互斥 gate | 中/高 |
| `scripts/verify-privileged-helper-bundle.sh` | 如需验证 Helper 新能力/新二进制符号，可追加检查（可选） | 低 |

**不修改：** `Support/StatusTrioPowerHelper.plist`（service 名不变）、`Support/Info.plist`、`scripts/build-app.sh`（Helper 打包路径不变）。

### 7.3 协议 v3 建议接口

```swift
@objc public protocol PowerHelperXPCProtocol {
    // v1
    func readLowPowerMode(withReply reply: @escaping (Bool, String?) -> Void)
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)

    // v2
    func readProtocolVersion(withReply reply: @escaping (Int, String?) -> Void)
    func readHighPowerModeSupport(withReply reply: @escaping (Bool, String?) -> Void)
    func readHighPowerMode(withReply reply: @escaping (Bool, String?) -> Void)
    func setHighPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)

    // v3：只暴露固定的充电抑制能力，绝不暴露通用 SMC 键读写
    func readChargeInhibitSupport(withReply reply: @escaping (Int, String?) -> Void)
    // 0 = unsupported, 1 = CH0B, 2 = CHIE；错误时 errorDescription 非空
    func readChargeInhibited(withReply reply: @escaping (Bool, String?) -> Void)
    func setChargingInhibited(_ inhibited: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}
```

- 返回 `Int` 而不是 Swift enum，避免 Objective-C 互操作和未来扩展问题；App 侧映射为 `SailingChargeControlBackend`。
- 不提供 `readSMCKey` / `writeSMCKey` 的通用接口：root daemon 绝不能变成任意 SMC 写服务。
- `setChargingInhibited` 必须回复「daemon 写后读回观察到的状态」，而不是回声请求；这与现有 pmset 方法的语义一致。
- 错误字符串只用于日志/诊断；UI 显示本地化通用文案（参考 `ChargeToFullNowFailure` 的做法）。
- 现场核对后建议把 `CHIE` 从 `setChargingInhibited` 中拆出，使用显式的 `setAdapterGateCut` 方法，避免把「适配器切断」伪装成「充电抑制」；见第 16.3 节。

### 7.4 共享文件冲突风险与缓解

| 文件 | 风险等级 | 原因 | 缓解 |
| --- | --- | --- | --- |
| `SettingsStore.swift` | **高** | 2301 行，所有电池/Helper/刷新设置都在这里；多个任务会同时加 key | 把航海设置封装在 `SailingModeSettings.swift`，SettingsStore 只加 1 个 `@Published` 属性 + 1 个 key + init 解码；不要改动现有 battery 常量 |
| `BatterySectionView.swift` | **高** | 电池 UI 是当前重构热点 | 新建 `SailingModeSettingsGroup.swift`，BatterySectionView 只加一个参数和一行 call |
| `LocalizationKey.swift` + 12 `.strings` | **高** | 每个功能都要加 key，13 个文件 | 用 `settings.battery.sailing` 前缀，追加在电池段末尾；提交前跑 `LocalizationParityTests` |
| `PowerHelperProtocol.swift` | **高** | 一个文件同时定义 v1/v2/v3 契约 | 只追加，不改旧方法；版本常量按 `lowPowerMode/highPowerMode/chargeInhibit` 顺序保留 |
| `AppEnvironment.swift` | **高** | 所有 controller 的创建点 | 在现有 `ChargeToFullNowController` 旁边加一个 block；先与其它改动协调 |
| `StatusPanelViewModel.swift` | **高** | 面板 demand/presentation wiring 复杂 | 首版只在 CTFN `update` 内部加 gate，不改 `StatusPanelViewModel` 的发布结构 |
| `PowerModeService.swift` | **中** | XPC service 与测试 fake 多 | 注入 `smc`，默认 unsupported；旧测试不动 |
| `SettingsView.swift` / `SettingsWindowController.swift` | **中** | 参数传递链 | 使用 `sailingMode: SailingModeController? = nil` 默认参数，保持预览/测试兼容 |
| `Package.swift` | **低** | 只加 IOKit | 与其它 Package 改动协调顺序 |
| `ChargeToFullNowController.swift` | **中** | 现有 509 行状态机 | 只加 `isEngaged`/conflict 判断，不重构现有分支 |

### 7.5 生命周期与 fail-safe

**启动：**

1. App 启动，`SailingModeSettings` 解码；若 `isEnabled == true`，控制器进入 `.checkingCapability`。
2. 选择 backend：
   - 若 `.nativeMCL` 可用 → `PowerUISailingChargeController`；
   - 否则若 Helper ready 且 `.smcChargeInhibit` 可用 → `SMCSailingChargeController`；
   - 否则 `.unsupported` / `.helperUnavailable`，不写任何硬件。
3. 读取当前电池状态和（SMC 路径）充电抑制状态；按当前电量决定暂停/恢复。

**运行：**

- 每次 `BatteryStatus`：
  - `isPresent == false` → 不动作；
  - `!isConnectedToPower` → 若之前抑制，恢复充电；状态 `.waitingForPower`；
  - `percentage >= upper` 且未抑制 → 暂停；
  - `percentage <= lower` 且已抑制 → 恢复。
- 设置变更：重新校验上下限；若当前状态越界，立即重新评估。
- CTFN 检测：每次电池 tick / CTFN presentation 变化时检查；冲突则恢复并 `.suspended`。

**退出/睡眠：**

- 系统将睡眠：`willSleep` → 恢复充电（fail-open），状态 `.suspended(.sleep)`；
- 唤醒：`didWake` → 如果仍启用且接电，重新评估；若 Helper 尚未就绪，等待 readiness；
- App 退出：`applicationWillTerminate` → `sailingMode.stop()` 发恢复请求（异步，不能保证完成）；**真正的保证靠 Helper 的最后连接/退出恢复**；
- Helper 退出：`restoreBeforeExit()` 写 `CH0B=0x00` / `CHIE=0x00`；
- Helper 启动：可先读 `CH0B`，若为非 0 则恢复 0（防止上次崩溃遗留抑制）；此操作发生在 app 发请求之前。

**失败策略：**

- 任何不确定状态一律 **允许充电**（fail-open），而不是继续抑制。
- 写失败 → 状态 `.failed`，显示本地化错误，保留「重试」；不要无限自动重试。
- 读回不一致 → 视为失败，不更新「保持中」状态。
- Helper 掉线 → 立即 `.suspended(.helperUnavailable)`；若之前发过抑制，尝试通过重连恢复；无法恢复则明确提示用户。

### 7.6 状态机建议

```swift
enum SailingModeState: Equatable {
    case off
    case unsupported(SailingUnsupportedReason)
    case needsHelperUpdate
    case helperUnavailable
    case waitingForPower
    case chargingToUpper(current: Int, upper: Int)
    case holding(current: Int, upper: Int, lower: Int)
    case suspended(SailingSuspendReason)   // chargeToFullNow / sleep / externalChange / userDisabled
    case restoring
    case failed(SailingFailure)
}
```

建议不变量：

1. `.holding` 时后端必须确认「充电已抑制」；`.chargingToUpper` 时必须确认「充电未被抑制」。
2. 不在 `.holding` 与 `.chargingToUpper` 之外写硬件。
3. 同一状态/同一电量不重复写；两次写之间至少间隔一个电池 tick（>=5 秒）。
4. `lower < upper` 且差 >= 5%；上限 <= 95%（避免 100% 无意义）。
5. 任何停止路径先尝试恢复充电，再清状态。
6. CTFN 活跃时 Sailing 永不写「暂停」；已经暂停时先恢复。

---

## 8. 风险清单

| # | 风险 | 影响 | 可能性 | 缓解/检测 |
| --- | --- | --- | --- | --- |
| 1 | **macOS 13 兼容** | 路线 A 不可用（PowerUI 26.4+）；路线 B 需要 SMC 旧键 | 确定 | capability 分级；13–26.3 仅 SMC；UI 明确显示支持范围；`verify-platform-version.sh` 保证 minos 13 |
| 2 | **Intel / Apple Silicon 差异** | `CH0B` 键语义/存在性不同；PowerUI 只 arm64 | 高 | 逐机 capability probe；Universal build 必须含 x86_64 slice；Intel 真机单独验证；不支持时隐藏 |
| 3 | **SMC 写失败** | 充电不受控、用户以为已暂停 | 高 | 写前 keyInfo、写后 readback；失败 fail-open；`kIOReturnNotPrivileged`/size 0 直接 unsupported；不重试循环 |
| 4 | **Helper 未安装 / 未批准 / 版本旧** | SMC 功能不可用 | 高 | `PrivilegedHelperManager.isReady` gate；显示登录项/更新提示；`readProtocolVersion` 先检查；Ad-hoc 构建明确提示 |
| 5 | **睡眠 / 唤醒** | SMC 抑制在睡眠期间继续或失效，电量过充/过放 | 中 | `willSleep` 恢复；`didWake` 重新评估；Helper 退出恢复；不依赖睡眠期间控制 |
| 6 | **退出恢复** | App/Helper 崩溃后 `CH0B=0x02` 遗留，电池无法充电 | 中–高 | Helper 最后连接关闭 + 退出闭包 + 启动自愈；App 终止 best-effort；日志审计 |
| 7 | **与 ChargeToFullNow 互斥** | 两套写入互相覆盖，充电行为不可预测 | 高 | `ChargeControlArbiter` 单租约；检测 raw 3；CTFN 活跃时 Sailing 恢复/暂停；所有入口 gate |
| 8 | **系统菜单启动 CTFN** | App 无法阻止 macOS 菜单，SMC 抑制会导致 CTFN 不充电 | 中 | 每次电池 tick 读 PowerUI state；检测 raw 3 后恢复 SMC；状态显示「已暂停：立即充满」 |
| 9 | **外部充电上限变化** | 用户/其它 App 改了 MCL，Sailing 覆盖或误判 | 中 | 记录自己设置的上限；读到不同值视为 external change 并暂停；不盲目回写 |
| 10 | **macOS 26.7+/27 键被收窄** | SMC 路径整体不可用；CHIE 风险高 | 确定（新系统） | capability 探测；26.7+ 不支持时明确提示；不要把 CHIE 作为默认路径 |
| 11 | **App Store / 签名** | root Helper 无法上架；Ad-hoc Helper 被拒绝 | 高 | `PRIVILEGED_HELPER=0` 构建隐藏功能；不伪造 entitlement；Developer ID 手动验证 |
| 12 | **过度充放电/循环次数** | 航海区间过窄导致频繁充放，反而伤电池 | 中 | 下限与上限至少 5%；最小 dwell（如 5 分钟）；默认 75–80；UI 说明 |
| 13 | **无谓后台工作** | 额外 timer/SMC 读增加功耗 | 中 | 复用 `BatteryStatus` 流；只在启用时读 PowerUI/Helper；Helper idle exit；不新增全局轮询 |
| 14 | **12 语言布局/RTL** | 文案溢出、设置页破版 | 中 | `LocalizationParityTests` + 12 语言布局测试；Sliders 固定宽度；阿拉伯语截图检查 |
| 15 | **`StatusSnapshot` 污染** | 航海状态进入图标渲染相等性路径，频繁重绘 | 中 | 状态放独立 `ObservableObject`；不改 `StatusSnapshot`/`BatteryStatus` |
| 16 | **SMC ABI 变化** | 新 macOS 上 80 字节结构/命令语义变化 | 中 | 固定键 + 严格校验；不支持就失败；不扫描/不枚举；外部资料和真机验证 |

---

## 9. 验收与人工验证建议

自动化测试只能证明状态机和假实现；真机行为必须单独记录：

| 项目 | 方式 | 预期 |
| --- | --- | --- |
| 控制器状态机 | `SailingModeControllerTests`（fake backend） | 全分支通过，无真实硬件 |
| SMC 字节/协议 | `SMCPowerServiceTests`（fake transport） | 请求 key/value/顺序正确；失败分支正确 |
| Helper bundle | `bash scripts/verify-local.sh full` → `verify-privileged-helper-bundle.sh` | minos 13.0 / SDK 26+、签名、plist、协议字符串 |
| macOS 13 静态契约 | `verify-platform-version.sh` / 夜间 native check | 二进制 slice minos 13.0 |
| macOS 13 真机 | 手动 Developer ID 构建 | SMC `CH0B` 可用性/读写/恢复；**NOT RUN until tested** |
| Apple Silicon macOS 26.4+ | 手动 Developer ID 构建 | PowerUI MCL 上限、CTFN 互斥、睡眠/退出恢复 |
| macOS 26.7+/27 | 手动 Developer ID 构建 | `CH0B` 不可用；`CHIE` 仅实验，不默认启用 |
| Intel | 手动 Developer ID 构建 | 旧固件 `CH0B`/`BCLM` 行为逐机确认；不得假设可用 |
| 退出恢复 | 手动：启用→保持→强杀 App/Helper | 充电恢复（`CH0B=0x00`/`CHIE=0x00`），电池能继续充电 |
| 睡眠/唤醒 | 手动：保持中睡眠 10 分钟→唤醒 | 睡眠前恢复；唤醒后重新进入保持或显示等待 |
| CTFN 冲突 | 手动：Sailing 保持→系统菜单「立即充满」→取消 | Sailing 暂停并恢复充电；CTFN 结束后按策略恢复 |
| 12 语言 UI | 截图/布局测试 | 无截断、无重叠、RTL 正常 |

> 自动化测试绝不执行真实 `CH0B`/`CHIE`/PowerUI 写。所有真实写操作只在授权的手动验证中进行，并记录 OS build、机型、SMC 键返回值、PowerUI 状态。

---

## 10. 与现有文档/边界的关系

- `docs/charge-to-full-now-poc.md` 明确记录：产品当前**不**使用 Helper/XPC/LaunchDaemon、不写 SMC、不重写 charging plist、不运行后台 watcher。航海模式如果走路线 B，会**改变这个产品边界**，属于需要单独安全/产品评审的变更。
- `docs/privileged-helper.md` 明确：现有 Helper 只服务 Low Power Mode；`pmset` 是唯一写路径；Helper idle exit 设计为 5 秒。航海模式会扩展这个 Helper 的职责，必须同步更新该文档（本文只分析，不修改它）。
- `docs/known-limitations.md` 已提示：Charge Limit 是私有/版本相关行为，不能保证跨 macOS；SMC 写路径同样应列入 known limitations。
- 所有 `AGENTS.md` 的约束仍然适用：macOS 13 部署目标、Universal `arm64 + x86_64`、最低 SDK 26、Helper 签名/打包契约、禁止伪造 entitlement、测试不得真实写电池。

---

## 11. 待 Lead 决策（3 个）

### 决策 1：航海模式的产品语义

- **A. 只做「静态充电上限 + 系统滞回」**：上限 80–95%，不做下限；实现成本最低（无 Helper/SMC），但功能与系统设置 Charge Limit 高度重叠。
- **B. 做真正的区间航海**：用户可设下限/上限（例如 75–80%），需要 SMC 写；实现和验证成本高，且 macOS 26.7+/27 受限。
- 建议：**先确认用户是否真的需要低于 80% 或自定义下限**；如果不需要，路线 A 足够；如果需要，进入路线 B 的硬件 spike。

### 决策 2：兼容范围 / macOS 26.7+ 策略

- **A. 只支持 macOS 26.4+ Apple Silicon（路线 A）**：干净、可维护，但放弃 macOS 13–26.3 与 Intel。
- **B. 支持 macOS 13–26.6 的 SMC `CH0B`，26.7+/27 标记不可用**：覆盖大部分现有用户，但需要 Helper v3 + 逐机验证。
- **C. 同时做 26.7+/27 的 `CHIE` 适配器门控**：功能最全，但风险最高（睡眠/崩溃/放电），不建议首版。
- 建议：**B 作为完整版目标，A 作为首版可交付范围；C 单独做安全评审和硬件 spike，不默认开启。**

### 决策 3：Helper 授权归属

- 现有 `controlsLowPowerMode` 同时是「Low Power Mode 功能开关」和「Helper 用户意图」；`LowPowerModeControlSynchronizer` 会把 `helper.$isEnabled` 镜像到这个键。
- 航海模式若使用 Helper，是否：
  - **A. 复用同一个 Helper opt-in**（推荐最小改动）：开启航海模式时调用 `helper.setEnabled(true)`，会同时把 Low Power Mode 控制标记为开启；UI 文案需说明「共用电源助手」。
  - **B. 新增独立的「电源助手」授权概念**：更清晰，但要重构 `PrivilegedHelperManager` 的 `isEnabled` 为多 feature 引用计数，改动大、风险高。
- 建议：**首版用 A，并在设置页把 Helper 行描述为「电源助手（Low Power Mode / 航海模式共用）」；后续再考虑独立授权。**

---

## 12. 关键源码索引

| 主题 | 文件 |
| --- | --- |
| 电池监控 | `Sources/StatusTrioCore/Monitoring/BatteryMonitor.swift` |
| 电池状态模型 | `Sources/StatusTrioCore/Models/StatusSnapshot.swift` |
| 全局 store | `Sources/StatusTrioCore/Store/SystemStatusStore.swift` |
| 电池详情 | `Sources/StatusTrioCore/Monitoring/BatteryDetailsController.swift`、`BatteryDetailsReader.swift` |
| 充电控制协议 | `Sources/StatusTrioCore/Battery/BatteryChargeControlling.swift` |
| 立即充满状态机 | `Sources/StatusTrioCore/Battery/ChargeToFullNowController.swift`、`ChargeToFullNowSession.swift` |
| PowerUI 桥 | `Sources/PowerUIPrivateAPI/PowerUIPrivateAPI.{h,m}` |
| SMC 只读 | `Sources/StatusTrioCore/Monitoring/SystemPowerReader.swift` |
| 系统充电上限读取 | `Sources/StatusTrioCore/Monitoring/SystemChargeLimitReader.swift` |
| Helper 协议 | `Sources/PowerHelperProtocol/PowerHelperProtocol.swift` |
| Helper 实现 | `Sources/StatusTrioPowerHelper/{main,ListenerDelegate,PowerModeService,IdleExitMonitor,ConnectionLifetime,ClientAuthorization}.swift` |
| Helper 管理 | `Sources/StatusTrioCore/App/PrivilegedHelperManager.swift`、`LowPowerModeControlSynchronizer.swift` |
| Helper 打包 | `Support/StatusTrioPowerHelper.plist`、`scripts/build-app.sh`、`scripts/verify-privileged-helper-bundle.sh` |
| 设置存储 | `Sources/StatusTrioCore/Settings/SettingsStore.swift` |
| 设置 UI | `Sources/StatusTrioCore/UI/Settings/{BatterySectionView,SettingsView,SettingsWindowController,GeneralSectionView}.swift`、`SettingsChrome.swift` |
| 电池 UI | `Sources/StatusTrioCore/UI/{BatteryDetailsView,BatteryStatusView,ChargeToFullNowActionView}.swift` |
| 本地化 | `Sources/StatusTrioCore/Localization/LocalizationKey.swift`、`Sources/StatusTrioCore/Resources/*.lproj/Localizable.strings` |
| 测试脚本 | `scripts/test.sh`、`scripts/verify-local.sh` |
| 现有设计文档 | `docs/charge-to-full-now-poc.md`、`docs/privileged-helper.md`、`docs/known-limitations.md` |

---

## 13. 外部资料（用于 SMC/OS 限制判断，非本项目实测）

以下为公开资料，用于判断 macOS 27 / Apple Silicon 的 SMC 键现状；本项目自己的真机验证仍需单独记录：

- BatteryKeeper 研究（2026-10-20）：macOS 27 上 `CH0B`/`CH0C`/`CHTE`/`CHWA`/`BCLM` 不存在；`CHIE` 仍可写（`0x08` 切断适配器、`0x00` 恢复）；原生 Charge Limit 80–100、自带约 5% 滞回、由 `powerd` 持久化。  
  <https://github.com/nervouna/batterykeeper/blob/main/docs/research.md>
- batt issue #152：macOS 27 Beta 4+ / macOS 15.8 / 26.7 安全更新后，SMC charge-control 键被 entitlement 门控，root 也返回 `kIOReturnNotPrivileged`；原生 SOC limit 路径需要 `com.apple.private.iokit.soc-limit`。  
  <https://github.com/charlie0129/batt/issues/152>
- batt issue #151：macOS 26.7 也应用了同类变更。  
  <https://github.com/charlie0129/batt/issues/151>
- bclm README：`BCLM`/`CHWA` 在 macOS >= 15 因内核 entitlement 限制不可用；Apple Silicon 仅支持 80/100，Intel 可写但会超调。  
  <https://github.com/zackelia/bclm>
- AlDente `Helper.swift`：`CH0B` 写入 `0x02` 暂停充电、`0x00` 恢复（Intel 与 Apple Silicon 共用该键）。  
  <https://github.com/davidwernhart/AlDente/blob/master/AlDente/Helper.swift>
- AlDente Features：Sailing Mode 的区间示例（75–80%：到 80% 停止，降到 75% 再充）。  
  <https://apphousekitchen.com/aldente-overview/features>
- Apple 支持文档：macOS 26.4+ Apple Silicon 的 Charge Limit 与 Charge to Full Now。  
  <https://support.apple.com/en-us/102338>

---

## 14. 一句话总结

**BatteryMonitor → SystemStatusStore 的链路足够支撑航海模式，不需要新定时器；但真正的区间航海模式超出了 PowerUI MCL 的能力边界，必须引入 SMC 写和 Helper v3。现场核对（M3 Max / macOS 27.2）确认：`CH0B`/`CH0C` 不存在，`CHIE` 存在但写权限未知；若 `CHIE=0x08` 写实验通过，最小路径是「PowerUI MCL 上位 + CHIE 主动放电到下位」，见第 16 节；若写不可用，则退化为 PowerUI MCL 静态上限版（路线 A）。**

---

## 15. 现场核对（2026-11-05，Apple M3 Max / macOS 27.2 26B123）

> 本节由 Lead 在本机实测补充，优先级高于前文对 macOS 27 的概括。前文关于 macOS 13–26.6 的 `CH0B` 兼容性判断仍然成立；本节只覆盖这台 Mac / 这个 OS build 的现场事实与后续验证建议。
>
> 分类约定：**观察** = 本机实测直接看到；**推断** = 由观察、外部资料或指令重建得到，尚未在本项目验证；**未知** = 必须再做实验才能确定。

### 15.1 现场观察

| # | 分类 | 内容 |
| --- | --- | --- |
| 1 | **观察** | `pmset -g battlimit Bottla` 输出两条 `manualChargeLimit`：`chargeSocLimitSoc = 80`、`chargeSocLimitDrain = 1`。即 macOS 27.2 上原生手动充电上限 + 自动回落到目标（hold）均存在。 |
| 2 | **观察** | 用 `IOConnectCallStructMethod(conn, 2, ...)` 的 key-info（command 9）逐键探测：`CH0B`、`CH0C`、`CH0I`、`CHTE`、`CHWA`、`BCLM` 均**不在** key 表中（未找到）。 |
| 3 | **观察** | `CHIE` 存在：type `hex_`、size 1、当前读值 `0x00`。`ACLC` 存在：type `ui8 `、当前读值 `0x04`。 |
| 4 | **观察** | 枚举所有 `CH` / `BC` / `AC` 前缀键后，仅剩 `CHIE`、`CHCC`、`CHVT`、`ACVB`、`AC1D`…`ACND`、`BCLP`、`BCNB` 等；**没有 `CH0*` 系列**。 |
| 5 | **观察/结论** | 这台 macOS 27.2 上 `CH0B`/`CH0C` 路线不可用：即使 root 能写，键也不存在；`CHTE` 也不存在。Sailing 的「拉低充电」只能靠 `CHIE = 0x08`（适配器门控 / 主动放电），且 `CHIE` 需要 root。 |
| 6 | **未知** | `CHIE` 的第三方写入权限。可能存在 App Store 限制、沙盒限制或 `com.apple.private.*` entitlement 要求；本机只证明「键存在且当前值为 0」，未证明「普通 root helper 能成功写 0x08」。 |

### 15.2 观察、推断、未知（含 AlDente 反汇编对照）

Lead 在 AlDente 二进制中反汇编到的关键序列如下。**这些是「从指令重建」的对照证据，不是本项目实测事实，也不代表 Apple 的稳定 ABI；不能直接照抄到产品代码。**

| 操作 | AlDente 侧重建序列（推断） | 置信度 / 备注 |
| --- | --- | --- |
| enable | `CH0B = 0x00`，之后对 `CH0B + 0x0B`（即拼接出的 `CH0E`）写 `0x0100_0000`（4 字节）；只在某个状态位 == 1 且 `CH0B` 存在时执行 | **推断**：`CH0E` 的键名/长度/语义未在本机验证；当前 macOS 27.2 没有 `CH0B`，该分支不会执行 |
| disable | `CH0I = 0x00`、`CH0C = 0x02`（顺序按分支不同） | **推断**：本机 `CH0I` / `CH0C` 不存在，无法验证；可能是旧固件的多键组合 |
| discharge | `CH0I = 0x01`，之后对 `CHTE` 写 `0x0080`（2 字节，值 128？） | **推断/未知**：`CHTE` 本机不存在；`0x0080` 是原始字节还是数值 128 尚未确认；绝不可直接作为产品写入依据 |

需要特别标注：

- **AlDente 侧证据不完整，来自指令重建，只能作为对照，不是事实来源。**
- `CH0B + 0x0B = CH0E` 是重建者按 ASCII 字节拼接的推断；AppleSMC 键是 4CC，不能保证这种算术拼接在别的固件成立。
- `CH0I` / `CH0C` / `CHTE` 的写入顺序、值宽度、读回语义都可能随固件变化；本机没有这些键，任何「兼容代码」都必须先做 key-info 探测，探测不到就直接 `.unsupported`。
- 当前 macOS 27.2 上唯一值得继续验证的充电相关写键是 `CHIE`（适配器切断），但它的写权限也还是未知。

### 15.3 建议的只读检查（安全，可随时执行）

目标：确认 `CHIE` 的键信息、当前值、以及在不同电源状态下的变化；**不写任何键**。

1. 用固定键 `CHIE` 做 key-info（command 9）：
   - 期望 `result == 0`、`size == 1`、`type == "hex_"`；
   - 若 key-info 失败、size 0 或 type 不符 → `CHIE` 不可用。
2. 用 command 5 读 `CHIE` 当前值，记录为 `0x00` / `0x08` / 其他；重复 3 次确认稳定。
3. 在以下边界各读一次（只读）：
   - 接电、未充电（MCL 保持 80%）；
   - 接电、正在充电；
   - 拔掉适配器；
   - 合盖/睡眠前、唤醒后；
   - 执行一次系统「立即充满」前后（只读 PowerUI/MCL 状态，不写 SMC）。
4. 同时记录 `ExternalConnected`、`ExternalChargeCapable`、`IsCharging`、`CurrentCapacity`、`Amperage`、`Voltage` 和 `pmset -g batt`，用于建立 `CHIE` 与适配器/充电状态的对应关系。
5. 只读检查建议做成一次性诊断命令（不进入产品、不常驻），输出 JSON/表格并人工审阅；不要在产品中做全键表枚举。

### 15.4 一次可回滚的 `CHIE = 0x08` 写入实验（需明确授权）

目标：验证「适配器门控（主动放电）」在 macOS 27.2 / M3 Max 上是否真的生效，以及 root helper 是否能写 `CHIE`。**只做一次写入，必须可立即回滚；不得自动化，不得在无人值守时运行。**

前置条件：

- 已获得机器所有者/用户对「一次真实 SMC 写 + 可能切换到电池供电」的明确授权；
- 使用 Developer ID 签名的开发构建与已批准的 Helper（或一个独立的、非产品的 root 诊断工具）；
- 电池电量高于将要设置的 lower bound（建议 >= 60%），已接电，当前不在 CTFN override（PowerUI MCL raw 值不是 3）；
- 关闭 Sailing Mode / ChargeToFullNow，记录基线：`pmset -g battlimit`、`pmset -g batt`、`CHIE` 当前值（应为 `0x00`）、PowerUI MCL 状态；
- 准备一个外部可见的恢复手段：实验脚本/工具无论成功失败，结束时都必须执行 `CHIE = 0x00`；如果进程崩溃，Helper 的退出恢复/人工命令必须能补写。

步骤：

1. 只读确认 `CHIE` key-info 为 `hex_`/1 字节，当前值 `0x00`。
2. 通过 root helper 写 `CHIE = 0x08`；记录返回码和写后 command 5 读回值。
3. 在 1 秒、5 秒、30 秒观察并记录：
   - `ExternalConnected` 是否变成 `No`；
   - `ExternalChargeCapable` 是否变成 `No`；
   - `IsCharging` 是否变成 `false`；
   - 电池电流是否变为放电（符号/方向按 IOKit 字段解释）；
   - `pmset -g batt` 是否显示 `Battery Power`；
   - `AdapterDetails` 是否仍列出适配器（预期仍列出，只是被门控）；
   - `CHIE` 读回是否仍为 `0x08`。
4. 无论结果如何，立即写 `CHIE = 0x00`，再次读回 `0x00`；确认 `ExternalConnected`/`ExternalChargeCapable` 恢复、系统重新可由适配器供电。
5. 若写入返回 `kIOReturnNotPrivileged` / `kIOReturnError` / result 非 0，或写后读回不是 `0x08`，记录为「CHIE 写不可用」，**不要重试**，不要尝试关闭 SIP 或添加私有 entitlement。
6. 若写成功但 30 秒内没有任何适配器/充电状态变化，记录为「键存在但语义不符/需要其他前置条件」，仍恢复 `0x00` 并停止。

判定：

- **PASS（能力可用）**：`CHIE=0x08` 后 `ExternalConnected=No`、`ExternalChargeCapable=No`、电池放电；`0x00` 后完全恢复。
- **PARTIAL**：写入成功但状态变化延迟/不完整；只能作为实验能力，不进入产品默认路径。
- **FAIL/UNKNOWN**：写入被拒绝、读回不一致、或无法恢复；产品把 `CHIE` 标记为不可用。

> 该实验是「适配器门控」验证，不是「充电抑制」验证。即使 PASS，也只证明「可以让 Mac 用电池」，不证明 Apple 允许第三方长期这样控制，也不证明 App Store 可接受。

### 15.5 其他验证建议

- `ACLC` 只读：记录当前值 `0x04` 在不同充电状态下的变化；可作为 MagSafe LED 状态参考，但**不要写**。
- `CH0B` / `CH0C` / `CH0I` / `CHTE` / `CHWA` / `BCLM`：本机已确认不存在，产品侧在每次启动时用 key-info 探测，不存在就 `.unsupported`；不要用「版本号猜测」代替探测。
- 若要验证 AlDente 的 `CH0E` / `CH0I` / `CHTE` 推断：只能在确认 key 存在、type/size 匹配、且每个键都能单独回滚的前提下，一次只写一个键；当前 M3 Max / 27.2 上没有这些键，因此在本机无法验证，也不应写入。
- 所有真实写实验必须记录：机器型号、OS build、SMC 键、type/size、写入值、返回码、写后读回、`pmset -g battlimit`、`pmset -g batt`、PowerUI MCL 状态、实验开始/结束时间。

---

## 16. 现场核对后的最小实现路径

### 16.1 能力分级（替代前文「路线 A/B」的二选一）

```text
Capability 探测顺序（helper 每次启动 / App 每次启用 Sailing 时）：
1. CH0B 存在且可写（旧固件 / macOS 13–26.6）
   → .smcChargeInhibit：直接暂停/恢复充电，任意区间；SMC 写失败则降级。
2. CHIE 存在且可写（本机 macOS 27.2 的候选）
   → .powerUIMCLWithAdapterGate：PowerUI MCL 作为上限 + CHIE=0x08 主动放电到下限。
3. 只有 PowerUI MCL 可用（CHIE 写不可用或无 CHIE）
   → .powerUIMCLOnly：只提供 80–95% 静态上限 + 系统固定约 5% 滞回，不提供自定义下限。
4. 都没有 → .unsupported，隐藏功能。
```

这与前文的区别：**路线 B 不再只依赖 `CH0B`**。在当前 M3 Max / macOS 27.2 上，`CH0B` 不存在，但 `CHIE` 存在；如果 `CHIE` 写实验 PASS，就用 `PowerUI MCL + CHIE` 组合实现区间航海。

### 16.2 组合方案：PowerUI MCL 作为「上限/持久天花板」，CHIE 作为「主动放电开关」

目标区间：`[lower, upper]`，例如 75–80%。

- **启动/进入保持**
  1. 通过 PowerUI 读取当前 MCL 状态，记录原上限 `originalLimit`（用于退出恢复；如果系统无 MCL，则记录 `nil`）。
  2. 通过 PowerUI `setMCLLimit` 设 `upper`（80–95；本机 80 可用）。
  3. 若当前电量 >= upper：不立即充；进入「等待放电/保持」。
  4. 若当前电量 < upper：保持 `CHIE=0x00`，让系统充电到 upper。
- **充电到上限后**
  1. 确认 `CHIE` 可用且当前 `0x00`；
  2. 写 `CHIE=0x08`，状态 `.adapterGatedDischarging(current, lower, upper)`；
  3. Mac 使用电池，电量自然下降；`BatteryStatus.isConnectedToPower` 会变成 `false`，**控制器必须知道这是自己切断的适配器，不能当成用户拔电而退出**。
- **降到下限**
  1. 读回 `CHIE`，确认仍为 `0x08`；
  2. 写 `CHIE=0x00`，状态 `.chargingToUpper`；
  3. 系统重新接电，MCL 上限仍为 `upper`，充电到上限。
- **停止/关闭**
  1. 先写 `CHIE=0x00`（恢复适配器）；
  2. 恢复 `originalLimit`（如果本来有 MCL）或 `disableMCL`（如果原来没有 MCL）；
  3. 清状态、清租约。
- **睡眠/退出**
  - 睡眠前：`CHIE=0x00`，避免睡眠期间持续放电；唤醒后重新评估。
  - App/Helper 退出：Helper 最后连接关闭 + idle exit 前写 `CHIE=0x00`；App 终止路径也 best-effort 发恢复请求。
- **CTFN 冲突**
  - 检测到 PowerUI MCL raw 值 3 或 `ChargeToFullNowController.isEngaged`：立即写 `CHIE=0x00`，状态 `.suspended(.chargeToFullNow)`；CTFN 结束且 Sailing 仍开启后再重新设置 MCL upper。
- **失败策略**
  - `CHIE` 写失败/读回不一致：立即恢复 `CHIE=0x00`，降级到 `.powerUIMCLOnly` 或 `.failed`；**绝不继续主动放电**。
  - MCL 写失败：不要用 CHIE 代替；保持正常充电，显示错误。
  - 任何不确定状态：`CHIE=0x00`（接回适配器）是默认安全状态。

**为什么这样组合：**

- PowerUI MCL 是 `powerd` 持久化的上限，App 崩溃/退出后仍然生效（本机 `pmset -g battlimit` 已证明 `manualChargeLimit 80` 存在）；它提供「不会充过 upper」的 fail-safe 天花板。
- CHIE 只在需要「从 upper 放电到 lower」时短暂使用，且只在 App/Helper 清醒时有效；它不承担长期安全边界。
- 如果 CHIE 写不可用，系统仍可退化为「MCL 静态上限 + 系统 5% 滞回」，不会阻断充电。

### 16.3 对 `SMCPowerService` / 协议 v3 的细化

建议把前文的「单一 `setChargingInhibited`」拆成显式的两条能力，避免把 CHIE 伪装成 CH0B：

```swift
// v3：能力位图；0 = unsupported，bit0 = CH0B，bit1 = CHIE
func readChargePathSupport(withReply reply: @escaping (Int, String?) -> Void)

// 当前状态位图：bit0 = chargeInhibited，bit1 = adapterCut
func readChargePathState(withReply reply: @escaping (Int, String?) -> Void)

// 仅 CH0B 路径
func setChargeInhibited(_ inhibited: Bool, withReply reply: @escaping (Bool, String?) -> Void)

// 仅 CHIE 路径：true = 写 0x08，false = 写 0x00
func setAdapterGateCut(_ cut: Bool, withReply reply: @escaping (Bool, String?) -> Void)
```

- `PowerModeService` 注入 `SMCPowerService` 并转发这四个方法；旧测试用默认 unsupported 的 `SMCPowerService` 即可。
- `SMCPowerService` 启动时只探测固定键（`CH0B`、`CH0C`、`CH0I`、`CHTE`、`CHIE`），不枚举全表；每个键都做 key-info 验证 size/type。
- `CH0B` 写值：`0x02` 抑制 / `0x00` 恢复；`CH0C` 如存在是否写 `0x02` 需要单独实验，首版可只写主键。
- `CHIE` 写值：`0x08` 切断 / `0x00` 恢复；写后必须读回。
- `ACLC` 只读，不实现写。

### 16.4 最小文件清单（现场核对版）

新增/修改与第 7.2 节基本一致，但增加以下明确点：

- `Sources/StatusTrioPowerHelper/SMCPowerService.swift`：同时支持 `.ch0b` 与 `.chieAdapterGate`；`restoreBeforeExit()` 必须写 `CHIE=0x00`（如果曾使用）和 `CH0B=0x00`（如果存在）。
- `Sources/StatusTrioCore/Sailing/SailingChargeControlling.swift`：
  - `SailingChargeBackend` 增加 `.powerUIMCLWithAdapterGate`；
  - 控制器必须区分「用户拔电」与「自己 CHIE 切断适配器」：`adapterCutByUs` 状态位。
- `Sources/StatusTrioCore/Sailing/SailingModeController.swift`：
  - 状态机增加 `.adapterGatedDischarging(current, lower, upper)`；
  - 退出/停止/睡眠优先 `restoreAdapter()`。
- `Sources/StatusTrioCore/Settings/SailingModeSettings.swift`：默认 `upper 80 / lower 75`；当能力为 `.powerUIMCLOnly` 时隐藏下限滑杆并显示「系统固定滞回」。
- `Sources/StatusTrioCore/UI/Settings/SailingModeSettingsGroup.swift`：增加「主动放电中（使用电池）」状态文案；`CHIE` 不可写时禁用区间模式。
- 测试新增：
  - `SailingModeControllerTests`：CHIE 切断后 `isConnectedToPower=false` 不得被当作拔电退出；到 lower 恢复适配器；睡眠/退出恢复；CHIE 写失败降级。
  - `SMCPowerServiceTests`：CHIE key-info/read/write/readback；CH0B 与 CHIE 能力位；`restoreBeforeExit` 双键清理。
- 文档：`docs/privileged-helper.md` 后续需补充「Helper 现在可能控制 CHIE/CH0B」和风险评估（本次任务只写研究文档，不改它）。

### 16.5 现场验收清单（当前 M3 Max / macOS 27.2）

| 项目 | 方法 | 通过标准 |
| --- | --- | --- |
| MCL 存在 | 只读 `pmset -g battlimit` | 看到 `manualChargeLimit`、`chargeSocLimitSoc=80`、`chargeSocLimitDrain=1`（现场已观察） |
| CH0B 不可用 | key-info `CH0B` | result 失败/size 0/不存在 → 不启用 CH0B 路径 |
| CHIE 存在 | key-info `CHIE` | `hex_` / size 1 / result 0 |
| CHIE 写权限 | 一次可回滚的 `CHIE=0x08` 实验 | PASS：`ExternalConnected=No`、`ExternalChargeCapable=No`、放电；`0x00` 后恢复 |
| PowerUI MCL 80 | `pmset -g battlimit` + PowerUI read | MCL limit 80 / 系统显示 80% |
| 组合 Sailing | 手动：80 上限 / 75 下限 | 到 80 后切适配器放电到 75；到 75 恢复适配器并充回 80；循环稳定 |
| 退出恢复 | 保持中强杀 App/Helper | `CHIE=0x00`、适配器恢复、电池可充电 |
| 睡眠/唤醒 | 保持中睡眠 10 分钟 | 睡眠前 `CHIE=0x00`；唤醒后重新进入保持 |
| CTFN 冲突 | Sailing 保持中从系统菜单「立即充满」 | 先 `CHIE=0x00`、Sailing 暂停；CTFN 结束后按策略恢复 |
| CHIE 写拒绝 | 若返回 `kIOReturnNotPrivileged` | 标记 `.powerUIMCLOnly` 或 `.unsupported`，不重试、不关 SIP |

> 若 `CHIE` 写实验 FAIL，这台机器上的最小实现路径退化为：**PowerUI MCL 80–95 静态上限 + 系统约 5% 滞回**，无法真正主动放电到自定义下限；此时 UI 应隐藏「主动放电/区间」控件，而不是显示一个无法工作的开关。

---

## 17. 最终实施决策（2026-11-05 晚）

本文 §15–16 在“只有 PowerUI 客户端 API”这一前提下提出了 `CHIE` 适配器门控的备选方案。实际实现前又核对到 Ampere 的公开实现路径：PowerUIAgent 的 root 偏好域 `com.apple.smartcharging.topoffprotection` 支持任意 `1...100` 目标；Helper 以 root 写 `MCLFeatureState=1` 与 `mclLimitValue=percent` 并 post `com.apple.smartcharging.defaultschanged`，系统固件会在目标低于当前电量时自行放电到目标。该路径不需要 `CHIE`，因此没有 PD 重协商、clamshell 睡眠和适配器残留风险。

最终 Status Trio 采用：**Helper v3 + macOS 原生 Manual Charge Limit 偏好路径**（不写 SMC、不写 CHIE）。控制器的目标不是 `upper` / `lower` 二选一，而是：区间内把目标设为**当前电量**以暂停充电；电量到达下限时把目标设为 `upper` 恢复充电；充电到 `upper` 后目标保持 `upper`，不主动放电。实现与验证见：

- `docs/sailing-mode.md`
- `Sources/StatusTrioCore/Battery/SailingModeController.swift`
- `Sources/StatusTrioPowerHelper/NativeChargeLimitController.swift`
- `Sources/StatusTrioPowerHelper/SystemNativeChargeLimitTransport.swift`

§15–16 的 CHIE 方案保留为历史备选，不是本实现路径。
