# 航海模式（Sailing Mode）

## 结论

Status Trio 的航海模式复刻 AlDente 1.36.2 的**用户可见语义**：进入航海区间后**停止充电并停在当前电量**；只有电量降到下限（例如 80/10 配置下的 70%）才重新充到上限。它不会主动放电，插电时由电源适配器供电，电池基本保持不动。

实现上，当前项目**不写 SMC**。在 macOS 27（以及 macOS 26.7 安全更新）的固件里，`CH0B` / `CH0C` / `CHTE` 等充电控制键已被移除或收进私有 entitlement，第三方 root Helper 也写不了；这与 AlDente 1.36.2 的旧固件路径不同。Status Trio 使用 macOS 自带的 Manual Charge Limit（`com.apple.smartcharging.topoffprotection`）作为暂停/充电开关：Helper 以 root 写入 PowerUIAgent 的偏好并 post `com.apple.smartcharging.defaultschanged`。航海区间内把目标设成**当前电量**，系统停止充电但不主动放电；到下限时把目标设回上限，系统恢复充电。这样既保留航海区间语义，也不依赖被系统移除的 SMC 键。

> 依据：`docs/research/aldente-sailing-mode.md`（AlDente 反汇编）与 `docs/research/status-trio-charge-architecture.md`（本项目架构与现场核对）。现场机器为 Apple M3 Max / macOS 27.2 (26B123)。

## 用户语义

设置项位于 **设置 › 电池 › 航海模式**：

- **充电上限**：航海模式的区间上限，默认 80%，范围 20–95%，5% 步进。
- **航海电量**：从上限向下回落的幅度，默认 5%，范围 1–15%。
- **下限**：`max(20, 充电上限 - 航海电量)`。例如上限 80、航海电量 10 → 下限 70；电量到 70% 或以下时恢复充电。
- **20% 硬下限**：电量低于或等于 20% 时，航海模式让位于普通充电，始终允许充电。
- **上限 100%**：不支持；UI 上限为 95%，避免“没有回落空间”的航海区间。

状态文案会显示 `正在充电至 80%`、`正在航海至 70%`、`等待连接电源适配器`、`电量低于 20%——正在充电`、`立即充满电进行中，航海模式已暂停` 等。

Helper 未就绪时，航海模式分组下方会出现「打开登录项设置」按钮，点击调用 `SMAppService.openSystemSettingsLoginItems()` 跳转到系统设置；如果当前是 ad-hoc 构建，该页面不会出现可用的 Helper 条目，原因见下方兼容性说明。

## 状态机

控制器 `SailingModeController` 消费 `SystemStatusStore.$snapshot.battery`（不消费 `popupSnapshot`，因此面板关闭时也工作），并由 `AppEnvironment` 把 `ChargeToFullNowController.$presentation` 一起合并输入。

| 条件（按优先级） | 动作 | 发布状态 |
| --- | --- | --- |
| 航海模式关闭 | 若曾应用过限制，恢复原始 Charge Limit | `.disabled` |
| Charge to Full Now 正在 applying / chargingToFull / cancelling | 暂停航海，**不 restore**（restore 会取消临时充满 override） | `.pausedForChargeToFull` |
| 电池不存在或无可读百分比 | 结束 helper 会话 | `.unavailable` |
| 未接电源 | 把目标设为当前电量并清空“正在充电”状态；重新插电在区间内不会续充 | `.waitingForPower` |
| 电量 ≤ 20% | 确保系统限制等于上限 | `.lowBatteryOverride` |
| 电量 ≥ 上限 | 把系统限制设为当前电量（停止充电，不主动放电） | `.holding(lower, upper)` |
| 电量 ≤ 下限 | 把系统限制设为上限（恢复充电到上限） | `.chargingToUpper(upper)` |
| 下限 < 电量 < 上限 | 把系统限制设为当前电量（停止充电，不主动放电） | `.holding(lower, upper)` |

命令去抖：同一方向 5 秒内不重复写；同值不重复写；命令失败时 `lastError` 可见，下一次 battery update 会重试。

这对应 AlDente 官方示例：

- 当前 77%、插电、充电上限 80%、航海区间 70–80：立即停止充电，因为 77% 在区间内。
- 继续使用或拔电后降到 74%，重新插电：仍然暂停，因为 70% 下限还没到。
- 继续降到 62%（或 ≤ 70%）：开始充电，并一直充到 80%。
- 80% 插电时目标就是 80%，不会主动放电；电池基本维持不动，主要由适配器供电。

因此“区间内插电不充电”和“充电过程中拔掉、在区间内重新插电也不充电”都是正确的。

`ChargeToFullNowController` 恢复/取消期间也不会与航海抢同一个 MCL 状态；航海已应用的限制在临时充满期间保留，取消后从当前电量重新建立暂停/充电目标。

## 为什么不是 SMC

- macOS 13–26.6 的旧固件路径（`CH0B=0` 允许、`CH0B=2` 禁止；Tahoe 的 `CHIE`/`CHTE`）已被 AlDente 的 Helper 使用，但这台 macOS 27.2 的 SMC key-info 探测显示 `CH0B`、`CH0C`、`CH0I`、`CHTE`、`CHWA`、`BCLM` 均不存在；`CHIE` 虽存在，但把它当作适配器门控会让 Mac 走电池，存在 clamshell/睡眠与崩溃残留风险。
- 原生 Manual Charge Limit 由 `powerd`/PowerUIAgent 持久化并跨睡眠执行；它能在当前电量低于目标时充电。Status Trio 通过把目标设为当前电量来暂停充电，因此不会主动放电。Helper 只写这一个固定的偏好域，**不暴露任意 SMC 键写入**。
- macOS 会在使用 Charge Limit 时周期性做一次校准充电（到 100%）；这是系统行为，航海模式无法阻止，UI 不把它误报为失败。

## Helper 协议 v4 与安全

`PowerHelperProtocolVersion.current = 4`。Sailing Mode 在 v3 新增四个方法：

- `readSailingChargeLimitCapability(withReply:)`
- `readSailingChargeLimit(withReply:)`（`-1` 表示没有由航海模式应用的限制）
- `applySailingChargeLimit(_:withReply:)`
- `restoreSailingChargeLimit(withReply:)`

MagSafe LED 在 v4 新增 `readMagSafeLEDCapability` / `readMagSafeLEDState` / `setMagSafeLED` / `restoreMagSafeLED`，固定写 `ACLC=0/1/3/4`。

Helper 只在第一次 `apply` 时把用户原有的 `MCLFeatureState` / `mclLimitValue` 写入 `/Library/Application Support/StatusTrio/saved-native-limit`，之后恢复时先调用 PowerUI 的 `disableMCL:` 清掉已注册的 limit，再写回原设置并 post reload。恢复成功后删除 marker。

恢复路径：

1. 用户关闭航海模式 → `SailingModeController.stop()` / 设置 sink → `restoreSailingChargeLimit`。
2. App 正常退出 → `AppEnvironment.stop()` 发起 `Task { await sailingMode.stop() }`；同时 App 持有的持久 XPC 连接关闭。
3. App 崩溃 → Helper 在最后一个 XPC 连接关闭时（`ListenerDelegate.onAllConnectionsClosed`）调用 `restoreSailingLimitOnClientDisconnect()`，`NativeChargeLimitController.restoreIfNeeded()` 恢复并删除 marker，然后 Helper idle exit。
4. Helper 的 `IdleExitMonitor` 仍按原有 5 秒空闲策略退出；launchd 在下次请求时重新拉起。

App 侧的 `XPCPrivilegedSailingChargeLimitClient` 在航海期间保持**一条**持久 `NSXPCConnection`；单次请求超时不会让连接 invalidate，否则 Helper 会误以为 App 已退出并提前恢复限制。`endSession()` 在停止/关闭时调用。

## 兼容性与限制

- **需要 macOS 26.4 或更高版本、Apple Silicon、系统 Charge Limit 可用**。Helper 通过 `PowerUISmartChargeClient` 类与 `pmset -g battlimit` 探测，不按 macOS 版本硬编码。
- **需要签名构建和已批准的 Helper**。默认发布配置把客户端团队固定为 `HCB7JKMQ2F`；本机可用同 Team 的 Apple Development 证书重新签名做本地验证。Sailing Mode 与 Low Power Mode 共用同一个 LaunchDaemon；`PrivilegedHelperManager` 用独立的 `sailingModeDemand` 保持注册和健康检查，不改变 Low Power Mode 的开关状态。ad-hoc 构建（TeamIdentifier 为空）无法满足 Helper 的团队校验，航海模式会显示 Helper 不可用；设置页会提供「打开登录项设置」按钮。
- **运行时会修改系统 Charge Limit**。关闭航海模式/退出 App 会恢复原始设置；如果 App 被强制杀死且 Helper 也无法运行时，marker 会在下一次 Helper 连接时恢复。建议用户在系统设置中确认 Charge Limit。
- 原生 Charge Limit 由 `powerd`/PowerUIAgent 持久化，睡眠期间也会按系统策略执行；但如果 App 与 Helper 同时被强制杀死，恢复依赖下一次 Helper 连接时的 marker 清理。
- **校准充电可能临时覆盖**：macOS 每几周会为电量计校准充到 100%，这段时间系统可能忽略 Charge Limit，Status Trio 不强行干预。
- **Intel / macOS < 26.4**：功能在 UI 中不可用，不会退化成旧的 SMC 写路径。后续如要支持旧系统，需要单独引入 AlDente 的 `CH0B`/`CHTE` 能力分级和逐机验证（见研究文档），不能复用本实现。

## 验证

已执行（本地、无真实 root 写入）：

```bash
swift build
bash scripts/test.sh 'NativeChargeLimitControllerTests'   # 19/19
bash scripts/test.sh 'PowerModeService'                  # 10/10
bash scripts/test.sh 'SailingModeControllerTests'        # 27/27
bash scripts/test.sh 'SailingChargeToFullActionTests'     # 3/3
bash scripts/test.sh 'LocalizationParityTests'           # 9/9
```

只读现场探测（macOS 27.2 / M3 Max）：

```bash
pmset -g battlimit
# Battery level limits:
#   chargeSocLimitSoc = 80; chargeSocLimitDrain = 1; chargeSocLimitReason = manualChargeLimit;
```

SMC key-info 探测：`CH0B`/`CH0C`/`CH0I`/`CHTE`/`CHWA`/`BCLM` 不存在；`CHIE` 存在（`hex_`/1 字节/当前 0x00）；`ACLC` 存在（`ui8 `/0x04）。PowerUI 类 `PowerUISmartChargeClient` 及 `isMCLCurrentlyEnabled:` / `enableMCL:` / `disableMCL:` 选择器存在。

**NOT RUN（需要 Developer ID 签名的 App + 已批准 Helper 的真实会话）**：

- root 的 CFPreferences 实际写入 `/var/root/Library/Preferences/com.apple.smartcharging.topoffprotection.plist`；
- 真实 `notify_post("com.apple.smartcharging.defaultschanged")` 到 PowerUIAgent；
- 真实 `PowerUISmartChargeClient` 的 `disableMCL:`；
- `/Library/Application Support/StatusTrio/saved-native-limit` 的 root 权限、跨睡眠/重启、系统实际执行 1...100 上限；
- App 崩溃后 Helper 最后连接恢复的端到端链路。

上述项目必须用 Developer ID 构建并在真机手动验证后才能称为“已发布功能可用”。

## 参考资料

- [AlDente Sailing Mode 逆向分析](research/aldente-sailing-mode.md)
- [Status Trio 电池/充电/Helper 架构分析](research/status-trio-charge-architecture.md)
- [AlDente Features: Sailing Mode](https://apphousekitchen.com/aldente-overview/features/#sailing-mode)
- [Ampere: How it works（macOS 27 native charge limit 路径）](https://amperebattery.app/tech.html)
- [batt issue #152: macOS 27 SMC charge-control keys gated](https://github.com/charlie0129/batt/issues/152)


## MagSafe 指示灯

航海模式联动可选的 MagSafe LED 指示：开启后，`holding`（航行区间内暂停）显示绿色，`chargingToUpper` / 低电量 / 立即充满显示橙色；未插电或关闭时把 `system`（0）写回，让 macOS 接管。该功能与 AlDente 的 MagSafe LED 语义一致，使用固定 `ACLC` SMC 键，不提供任意 SMC 写入。

## 直接充满（Charge to Full Now）

Sailing Mode 分组内复用现有的 Charge to Full Now 动作，不新增第二套 MCL 控制路径：

- **显示条件**：航海模式开启、当前 Mac 支持 Charge to Full Now、电池存在、已连接电源，并且电量未达到 100%/未处于已充满状态。
- **不显示**：航海模式关闭、没有电池、未连接电源、电量已满或已充满；此时应使用原有的「电池 → 充电」分组中的入口。
- **例外保留**：一旦临时充满已经处于 `applying` / `chargingToFull` / `cancelling` / 取消确认状态，按钮会继续显示为「取消立即充满」，即使这时拔掉电源或电量到达 100%，确保用户始终能恢复原充电上限。
- **与航海互斥**：Charge to Full Now 使用 PowerUI 的临时 MCL override；SailingModeController 在它活跃时只进入 `.pausedForChargeToFull`，**不会**调用自己的 `restore`，否则会把临时 override 取消。临时充满结束/取消后，航海控制器从上次的滞回目标继续。
