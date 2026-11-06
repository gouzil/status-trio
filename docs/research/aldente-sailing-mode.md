# AlDente 1.36.2「航海模式（Sailing Mode）」逆向分析

> 分析对象：`/Applications/AlDente.app`（`CFBundleShortVersionString = 1.36.2`，Universal：x86_64 + arm64）
>
> 样本 SHA-256（arm64 slice 所在 fat 文件整体）：
> - `AlDente` 主二进制：`4e9c0dbf10970227748a2354015b2b2ce73a701581008a97d9dd84e7210b2258`
> - `com.apphousekitchen.aldente-pro.helper`：`98cf29547fed08d74549ffe1063053c8482dfb00ae957bbcaecbcfafdf29edac`
>
> 分析目标：还原航海模式的用户语义、状态机、SMC 写入序列、Helper XPC 接口与恢复路径，供 Status Trio 复刻参考。
>
> 分析日期：2026-11-05（Asia/Shanghai）
>
> 分析纪律：本文只修改 `docs/research/aldente-sailing-mode.md` 与 `.build/research/**` 草稿，不修改产品源码。
>
> 证据分级：**观察**＝直接从二进制指令/字符串/元数据读到；**推断**＝由结构、命名、调用关系与外部文档交叉得出；**未知**＝当前证据不足。

---

## 0. 结论摘要

1. AlDente 1.36.2 的航海模式不是“强制放电到下限再充电”的循环，而是**到上限后停止充电、让电池自然回落；回落到 `max(chargeVal - sailingLevel, 20)` 才重新充电**。强制放电（Discharging）只在“电量已经超过上限（overshoot）”且用户开启了 Automatic Discharge 时作为纠偏路径出现，而且只放电回 `chargeVal`，不会放到下限。
2. 关键判定函数是 `Sailing.run(SensorInfo)`，地址 `0x1000fdef8`；它由 Sailing 类元数据（`0x1004499e0`）vtable `+0xd8` 槽的 thunk `0x1000fe50c` 进入，thunk 只有一条 `b 0x1000fdef8`。
3. 20% 是硬下限：`Sailing.run` 在 `currentPercentage < 20` 时直接转 `Charging`，日志为 `SAILING STOPPED BECAUSE OF TOO LOW VALUE -  going to charge again`。`sailingLevel` 在运行时被钳制到最小 1%。
4. 判定流程的四个关键状态对象：`Charging`（`0x10006ffb4`）、`Pause`（`0x1000987b8`）、`Sailing`（`0x1000fdef8`）、`Discharging`（`0x10005f270`）。`StateManager.update`（`0x10010139c`）负责在“充电中/暂停中”时按航海区间重新进入 Sailing。
5. SMC 写序列集中在 `HardwareManager`：`0x1001af2f8`（允许充电）、`0x1001af568`（禁止充电）、`0x1001af934` 所在的异步函数（强制放电）。存在 **Tahoe 固件分支**（Capabilities.TahoeFirmware，偏移 +0x1a）：Tahoe 用 `CHIE/CHTE`，旧固件用 `CH0B/CH0C/CH0I`。
6. 已核实的键值：`CH0B=0x42304843`、`CH0C=0x43304843`、`CH0I=0x49304843`、`CHIE=0x45494843`、`CHTE=0x45544843`（由 `CHIE + 0xb0000` 构造）、`BCLM=0x4D4C4342`、`CHWA=0x41574843`、`CHCC=0x43434843`、`ACLC=0x434C4341`。
7. **最重要的风险**：`CH0C=2` / `CH0I=1`（或 Tahoe 的 `CHTE=0x01000000`）是“持续状态”，不会因为 App 正常退出或拔掉电源而自动恢复；AlDente 的 Helper 只在 `removeHelper`（卸载 Helper）时通过 `modifiedKeysUInt8/UInt32` 回写原值。复刻实现必须有独立的看门狗/退出恢复路径，否则可能留下“插电也不充电”的机器。
8. Helper 协议有 24 个方法，核心 SMC 写入是 `setSMCByteWithKey:value:`（`@16C24`）与 `setSMCByte32WithKey:value:`（`@16I24`）；`setResetValWithKey:value:` 只记录“将来要恢复的值”，不直接写 SMC。

### 0.1 方法与工具限制

- 使用 `otool -tvV -arch arm64` 导出全量反汇编（`.build/research/disasm/aldente-arm64.txt`，877,368 条指令；arm64 slice 起始 `0x5B0000`）。
- 使用 `otool -ov -arch arm64` 导出 ObjC 类/协议/ivar 元数据（App 与 Helper 各一份）。
- 使用 `rea inspect-native-dispatch-metadata` 提取 `objc_classes` / `objc_ivars` / `objc_protocol_records` / `objc_dispatch_implementations`（该命令只读 Mach-O 元数据，不需要 Ghidra/Hopper/IDA 引擎）。
- 使用 `lipo -detailed_info` 确认 fat slice 偏移，`strings -t x` 确认字符串文件偏移。
- **没有使用 Ghidra、Hopper、IDA 或 Binary Ninja 的 headless 反编译**；`rea doctor` 显示 Ghidra/Hopper/IDA provider 均缺失，Binary Ninja Personal 的 headless license 无效。本文所有伪代码均由 ARM64 指令手工重建，不是反编译器输出。
- 没有进行动态调试或真机 SMC 写入实验；所有硬件行为结论都需要真机复核。

---

## 1. 用户可见语义与设置项

### 1.1 文案（来自 App 内 `Localizable.strings`）

| key | en | zh-Hans | 说明 |
| --- | --- | --- | --- |
| `lblSailingMode` | Sailing Mode | 航海模式 | 设置页标题 |
| `lblSailingLevel` | Sailing Level | 航海电量 | 区间宽度（不是绝对下限） |
| `txtHelpSailing` | Sailing Mode is designed to avoid unnecessary micro-charging. This means with a sailing level of 10% and a charge limit of 80%, it will only start charging again as the battery percentage drops to 70%. Also, it is temporarily disabled during Top Up and the Calibration Mode. Recommended value: 5-10% | 航海模式旨在避免不必要的微充电。这意味着，在航行电量为 10%、充电限制为 80% 的情况下，只有当电池电量降至 70% 时才会重新开始充电。此外，在充值和校准模式下，它也会被暂时禁用。建议值：5-10 | 用户语义核心：`chargeVal - sailingLevel` |
| `hlpSailingMinPerc` | Below 20%, AlDente will always charge your battery and Sailing Mode is overridden. | 低于20％时，AlDente 将始终为电池充电，并且航海模式被覆盖。 | 20% 硬下限 |
| `hlpSailingModeSettings` | After AlDente has finished charging your battery to the desired value, it will let your MacBook fall back to the set percentage before it starts charging again. This is done to prevent rapid charging/discharging around the set value. | AlDente 会将电池充电至所需电量后，让 MacBook 放电至设定的百分比再开始充电. 这样做是为了防止在电量变化而反复充放电. | 说明“自然回落”，不是强制放电 |
| `hlpSailingModePopover` | Sailing mode activated. | 航海模式已激活。 | 菜单栏提示 |
| `txtSailingModeDeactivated` | Sailing Mode deactivated. | 航海模式已关闭。 | 关闭提示 |
| `txtWillSailTo` | Will sail to  | 将航海至  | 设置页预览目标值（推断：`chargeVal - sailingLevel`；外部用户报告显示 “Will sail to 70%”） |
| `bpSailingMode` | • Sailing Mode* | • 航海模式* | 付费功能徽标 |

文件位置（观察）：

- `/Applications/AlDente.app/Contents/Resources/en.lproj/Default.strings`
- `/Applications/AlDente.app/Contents/Resources/zh-Hans.lproj/Localizable.strings`

### 1.2 设置项、默认值与数据类型

`AHKSettings` 是一个 496 字节的 Swift 类（`_TtC7AlDente11AHKSettings`，类对象 `0x10043f2e8`），相关 ivar：

| 属性 | ivar 偏移 | UserDefaults key | 类型/底层存储 | 默认值 | 证据 |
| --- | --- | --- | --- | --- | --- |
| `chargeVal` | +8（ivar 描述符 `0x10044ae10`） | `chargeVal` | 属性包装器对象；值位于 wrapper `+0x28`，Float | 80.0（`0x42a00000`，`0x10012ff18`） | 观察（getter `0x10012dd18`，setter `0x10012dd5c`→`0x10012de08`） |
| `sailingMode` | +16（`0x10044ae18`） | `sailingMode` | 属性包装器对象；值位于 wrapper `+0x22`，Bool | false | 观察（getter `0x10012dd68`，setter `0x10012ddac`→`0x10012dfb8`） |
| `sailingLevel` | +24（`0x10044ae20`） | `sailingLevel` | 属性包装器对象；值位于 wrapper `+0x28`，Float | 5.0（`0x40a00000`，`0x100130048`） | 观察（getter `0x10012ddb8`，setter `0x10012ddfc`→`0x10012de08`） |
| `lastSailingCheckpoint` | +312（`0x10044af40`） | `lastSailingCheckpoint` | 属性包装器对象；值位于 wrapper `+0x30`，Int | -1（init 里 `str x23=-1`） | 观察（setter thunk `0x10012e9c0`→`0x10012e818`） |

补充观察：

- 本机真实偏好（`~/Library/Preferences/com.apphousekitchen.aldente-pro.plist`）中 `lastSailingCheckpoint = 1`，没有 `sailingMode`/`sailingLevel`/`chargeVal` 键，说明这些键使用默认值且 `lastSailingCheckpoint` 是会被写入的持久标志。
- `lastSailingCheckpoint` 在三处 UI 闭包中被写为 `1`（`bl 0x10012e9c0`：`0x10013ba2c`、`0x10013cb1c`、`0x10013d4f4`）；`Pause.run` 只检查它是否非 0（`ldr x8,[wrapper+0x30]; cbz`，`0x100098a38`-`0x100098a3c`）。它的精确语义是“航海是否已武装/是否有检查点”，**不是电量值**（细节见 §7 未确认项）。
- `chargeVal` 设置页滑杆范围 20–100（`0x10019625c: mov w2,#0x14; mov w3,#0x64`，即 20...100）。
- `sailingLevel` 设置页滑杆最小值 1（`0x100198358: mov w2,#0x1`，上限由当前 charge limit 推导）；运行时还会在 `Sailing.run` 内强制 `if sailingLevel < 1 { sailingLevel = 1 }`（`0x1000fe100`-`0x1000fe118`，调用 setter `0x10012ddfc`）。
- `chargeVal` 默认 80、`sailingLevel` 默认 5、推荐 5–10，和文案一致。

### 1.3 阈值与用户语义

以 `chargeVal = 80`、`sailingLevel = 10` 为例：

- **充电阶段**：从任意低于 80% 的电量充电到 80%。
- **航海阶段**：到达 80% 后停止充电，电池自然回落（`txtHelpSailing`/`hlpSailingModeSettings` 的“fall back”）。
- **重新充电点**：`80 - 10 = 70%`；当电量降到 70% 或以下时重新充电。
- **绝对下限**：若 `chargeVal - sailingLevel < 20`，下限被抬到 20%；若当前电量 `< 20%`，航海模式被完全覆盖，直接充电。
- **上限限制**：`chargeVal` 为 100 时航海模式不会启动（`Charging.run` 的 `cmp x8,#0x63; b.gt` 分支，见 §2.4）；这符合“100% 没有回落空间”的产品直觉。
- **Top Up / Calibration**：文案明确“temporarily disabled during Top Up and the Calibration Mode”。二进制层面，`StateManager.update` 只有在当前状态是 `Charging` 或 `Pause` 时才考虑进入 Sailing（`0x100101570`-`0x10010159c` 的 `swift_dynamicCastClass` 检查）；Top Up / Calibration 会占用当前状态，因此自然绕过航海逻辑。**这一点是“结构推断”，没有单独的函数级 `if topup` 分支。**

---

## 2. 状态机与判定流程

### 2.1 类、状态对象与公共基类

`ChargeState`（`0x100442f80`）是四个状态的基类，实例布局（ivar 元数据）：

| 字段 | 偏移 | 类型 | 含义 |
| --- | --- | --- | --- |
| `nextStateCallback` | +16 | 16 字节闭包 | 状态切换回调 |
| `currentlyActive` | +32 (0x20) | Bool | 是否当前激活 |
| `disconnected` | +33 (0x21) | Bool | 是否已掉电 |
| `asleep` | +34 (0x22) | Bool | 是否睡眠 |

四个状态的类对象、`run` 实现与证据：

| 状态 | 类对象 | vtable `run` 槽 | 实际 `run` 函数 | 证据 |
| --- | --- | --- | --- | --- |
| `Charging` | `0x1004452a0` | `0x100445378` = `0x10007070c`（`b 0x10006ffb4`） | `0x10006ffb4` | 观察（类元数据 + thunk） |
| `Pause` | `0x1004469b0` | `0x100446a88` = `0x100098c78`（`b 0x1000987b8`） | `0x1000987b8` | 观察 |
| `Sailing` | `0x1004499e0` | `0x100449ab8` = `0x1000fe50c`（`b 0x1000fdef8`） | `0x1000fdef8` | 观察 |
| `Discharging` | `0x100444598` | `0x100444670` = `0x10005f270`（直接指针） | `0x10005f270` | 观察 |

> 说明：类元数据中的 `+0xd8` 槽在上述对象里都指向对应 `run`（Charging/Pause/Sailing 是 `b run` thunk，Discharging 是直接代码指针）；Pause/Sailing 在 `+0x148` 还有第二个 `run` 指针/描述符，本文只依赖 `+0xd8`。
>
> 另：`Sailing`、`Pause`、`Discharging` 的 `instance_size` 都是 35 字节（与 `ChargeState` 相同），说明它们没有额外存储字段，所有判断都来自 `AHKSettings` + `SensorInfo`；`Charging` 是 48 字节（额外 `hasReached100` +0x23、`maxLimit` +0x28）。

### 2.2 StateManager.update：重新进入 Sailing 的条件

`StateManager.update` 位于 `0x10010139c`（函数体从 `sub sp, sp, #0x1c0` 开始；`0x10010139c` 是 `stp d9, d8` 之后的入口，按 Swift async/Combine 方法处理）。航海相关片段 `0x10010153c`-`0x100101840`：

```text
0x10010153c  ldr x8, [settings + 0xe18]        ; settings.sailingMode wrapper
0x100101540  ldr x20, [settings, x8]
0x100101558  ldrb w8, [x20, #0x22]             ; sailingMode value
0x100101568  cmp w8, #1
0x10010156c  b.ne 0x100101840                  ; 关闭则跳过
0x100101570  ldr x20, [x26, #0x28]             ; 当前状态对象
0x100101578  bl 0x10006ff94                    ; Charging 类元数据 accessor
0x100101584  bl _swift_dynamicCastClass        ; 当前状态是 Charging?
0x10010158c  bl 0x100098798                    ; 否则试 Pause
0x100101598  bl _swift_dynamicCastClass
0x10010159c  cbz x0, 0x100101840               ; 既不是 Charging 也不是 Pause -> 跳过
0x1001015a8  bl 0x10008e9e0                    ; 取 SensorInfo 的平滑/实际电量（dispatch_sync）
0x1001015c8  ...                               ; 读回 Float
0x100101614  fcmp s8, s0                       ; 当前电量 vs chargeVal
0x100101618  b.hi 0x100101840                  ; 高于 chargeVal 不进入（交给 Discharging/overshoot 逻辑）
0x10010169c  fsub s0, s9, s0                   ; chargeVal - sailingLevel
0x1001016a0  fcmp s0, s8
0x1001016a4  b.pl 0x100101840                  ; lower >= current -> 不进入
0x1001016ac  ldr x8, [settings + 0xf40]        ; lastSailingCheckpoint wrapper
0x1001016c8  ldr x8, [x20, #0x30]
0x1001016cc  cbz x8, 0x100101840               ; 0 -> 不进入
0x1001016f4  bl 0x1000fded8                    ; Sailing 类元数据
0x100101738  ... "trying to change state to: "
```

推断的语义：

```swift
// StateManager.update(sensorInfo) 中航海相关的前置判断（伪代码）
if settings.sailingMode,
   currentState is Charging || currentState is Pause,
   smoothedPercentage <= settings.chargeVal,
   smoothedPercentage > settings.chargeVal - settings.sailingLevel,
   settings.lastSailingCheckpoint != 0 {
       changeState(to: Sailing)
}
```

这段逻辑在每次 `StateManager.update` 时都会评估；满足条件就切到 Sailing，因此也覆盖“设置变更、重启后仍在区间内、从掉电恢复”等重新进入航海的场景。

**Top Up / Calibration 的禁用机制（推断）**：当 `currentState` 是 `Topup` 或 `Calibration` 时，`0x100101584`/`0x100101598` 的两次 `swift_dynamicCastClass` 都不会命中，函数在 `0x10010159c` 直接跳到 `0x100101840`，整段航海判断被跳过。因此“Top Up / Calibration 期间航海模式被暂时禁用”不需要在 `Sailing.run` 内单独判断，而是由状态机当前状态实现。

### 2.3 `Sailing.run` 伪代码（`0x1000fdef8`）

关键指令：

- 掉电处理：`0x1000fdf3c` 读 `SensorInfo.chargerConnected`（偏移 +0x1c，见 SensorInfo ivar），`0x1000fdf40` 读 `self.disconnected`（+0x21）；掉电时写日志 `on disconnected!`（`0x1000fdf9c` literal pool → `0x10037b040`）。
- 模式关闭：`0x1000fe0d8` 读 `settings.sailingMode` wrapper 的 `+0x22`；false → `0x1000fe3dc` 调 `Pause` 类 accessor（`0x100098798`）。
- `sailingLevel` 钳制：`0x1000fe13c` 读 wrapper `+0x28`，`0x1000fe140` `fmov s8,#20.0`，`0x1000fe144` `fcmp s9,s8`，`0x1000fe148` `b.pl 0x1000fe1f8`；`0x1000fe100` 读 `sailingLevel`，`0x1000fe104` `fmov s1,#1.0`，`0x1000fe10c` `b.pl`，`0x1000fe118` 调 setter `0x10012ddfc`。
- 20% 分支：`0x1000fe180` literal `going to charge again`；`0x1000fe1b4` `mov x0,#0` + `bl 0x10006ff94`（Charging accessor），随后 `swift_initStaticObject` 并回调 `nextStateCallback`。
- 下限分支：`0x1000fe238` `fsub s0,s10,s0`（chargeVal - sailingLevel），`0x1000fe23c` `fcmp s0,s8`，`0x1000fe240` `b.hi 0x1000fe2f8`；`0x1000fe244` `fmov s0,#20.0`；`0x1000fe248` `fcmp s9,s0`；`0x1000fe24c` `b.hi 0x1000fe2f8`；否则 `0x1000fe284` literal `going to pause again`，`0x1000fe2b8` `bl 0x100098798`（Pause accessor）。
- 高分支：`0x1000fe380` `fcvtzs x8,s8`（current），`0x1000fe384` `fcvtzs x9,s0`（chargeVal），`0x1000fe388` `cmp x9,x8`，`0x1000fe38c` `b.ge 0x1000fe420`（chargeVal >= current → 返回）；否则读 `settings.automaticDischarge`（`0x1000fe394`，offset `0x10044aea8`），为 true 时 `0x1000fe3c0` `bl 0x10005fe94`（Discharging accessor）。

```swift
func Sailing.run(sensorInfo: SensorInfo) {
    // 1) 掉电状态维护
    if sensorInfo.chargerConnected {
        if self.disconnected { self.disconnected = false; onReconnected() }
    } else {
        if !self.disconnected { self.disconnected = true; log("on disconnected!") }
    }

    // 2) 模式被关闭 -> 回到 Pause（Pause 再决定是否 Charging）
    guard settings.sailingMode else {
        transition(to: Pause); return
    }

    // 3) sailingLevel 最小 1
    var level = settings.sailingLevel
    if level < 1.0 { settings.sailingLevel = 1.0; level = 1.0 }

    let pct = sensorInfo.currentPercentage

    // 4) 20% 硬下限：优先于区间计算
    if pct < 20.0 {
        log("SAILING STOPPED BECAUSE OF TOO LOW VALUE -  going to charge again")
        transition(to: Charging); return
    }

    // 5) 回落到下限 -> Pause（Pause 会在 pct < chargeVal 时转 Charging）
    let lower = max(settings.chargeVal - level, 20.0)
    if pct <= lower {
        log("SAILING STOPPED BECAUSE OF TOO LOW VALUE -  going to pause again")
        transition(to: Pause); return
    }

    // 6) 超过上限（overshoot）才考虑强制放电，而且只在上限之上
    if Int(pct) > Int(settings.chargeVal) {
        if settings.automaticDischarge {
            transition(to: Discharging)
        }
    }
}
```

> 注意：`pct <= lower` 时日志是 `going to pause again`，不是 `going to charge again`。`Pause.run` 在 `pct < chargeVal` 时会立刻转 `Charging`，所以用户观察到的仍是“到 70% 开始充电”。这条“Sailing → Pause → Charging”的两跳是此版本的真实实现，复刻时不要简化成 Sailing 直接 Charging（否则会丢失 Pause 在接近上限时的其它判定）。

### 2.4 `Charging.run` 伪代码（`0x10006ffb4`）

关键指令：

- `0x10007018c` `ldr s0,[x21,#0x10]`：`SensorInfo.currentPercentage`。
- `0x1000701c8` `cmp x8,#0x63` + `b.le 0x100070204`：`current > 99` 时先进入特殊日志分支（读 `0x1004a4520` 对象的 +0x27 标志，必要时调用 `0x1001a1de4`）。
- `0x100070248`-`0x1000702b4`：读 `settings.chargeVal`（`0x10044ae10` wrapper `+0x28`）；`fcvtzs x9,s8`（current）、`fcvtzs x8,s0`（chargeVal）；`cmp x9,x8; b.lt 0x100070300`（current < chargeVal 走温度保护检查）。
- `0x1000702b8` `cmp x8,#0x63; b.gt 0x100070300`：chargeVal > 99（即 100）不进入航海/暂停切换。
- `0x1000702e0` `ldrb w8,[x20,#0x22]`：`settings.sailingMode`；false → `0x1000703a4` `bl 0x100098798`（Pause）；true → `0x1000702ec` `bl 0x1000fded8`（Sailing）。
- 温度保护：`0x100070300` 读 `settings.heatProtectMode`（offset `0x10044ae28`）与 `settings.maxTemperature`（`0x10044ae30`），比较 `sensorInfo.batteryTemp`（+0x20）与 `maxTemperature`；超过且 `current > 20` 时 `0x100070384` `bl 0x100063040`（HeatProtect accessor）。
- 结尾 `0x10007041c` `fcvtzs x8,s0; cmp x8,#0x63; cset w8,gt; strb w8,[x19,#0x23]`：维护 `Charging.hasReached100`（ivar +0x23）。

```swift
func Charging.run(sensorInfo: SensorInfo) {
    handleDisconnectState(sensorInfo)   // 同 Sailing 的 chargerConnected/disconnected 逻辑

    let pct = sensorInfo.currentPercentage
    if Int(pct) > 99 {
        // 100% 特殊处理：记录/调试日志（0x1004a4520+0x27 标志）
    }

    let limit = settings.chargeVal
    if Int(pct) >= Int(limit) && Int(limit) <= 99 {
        if settings.sailingMode {
            transition(to: Sailing)
        } else {
            transition(to: Pause)
        }
    } else {
        if settings.heatProtectMode,
           sensorInfo.batteryTemp >= settings.maxTemperature,
           pct > 20 {
            transition(to: HeatProtect)
        }
    }

    self.hasReached100 = Int(pct) > 99
}
```

### 2.5 `Pause.run` 伪代码（`0x1000987b8`）

关键指令：

- `0x10009898c` 读 `settings.sailingMode`；false → `0x100098a54`。
- `0x1000989ac` `s8 = current`；`0x1000989cc` `s9 = settings.chargeVal`；`0x1000989f0` `s0 = settings.sailingLevel`；`0x1000989f4` `fsub s0,s9,s0`；`0x1000989f8` `fmov s1,#20.0`；`0x1000989fc` `fcmp s0,s1`；`0x100098a00` `b.ls 0x100098a10`；`0x100098a04` `fcmp s0,s8`；`0x100098a08` `b.mi 0x100098a18`（`lower < current` → 检查 checkpoint）；`0x100098a10` `fcmp s8,s1; b.le 0x100098a54`（若 lower <= 20 且 current <= 20，不进入 Sailing）。
- `0x100098a18` 读 `settings.lastSailingCheckpoint`（`0x10044af40`）wrapper `+0x30`；`0x100098a3c` `cbz x8, 0x100098a54`；非 0 → `0x100098a44` `bl 0x1000fded8`（Sailing accessor）。
- `0x100098afc` `cmp x8,x9`（current vs chargeVal）；`0x100098b00` `b.ge 0x100098b48`；current < chargeVal → `0x100098b08` `bl 0x10006ff94`（Charging accessor）。
- `0x100098b48` `cmp x9,x8; b.ge 0x100098b9c`（chargeVal >= current → 返回）；current > chargeVal → 读 `settings.automaticDischarge`（`0x10044aea8` wrapper）；true → `0x100098b80` `bl 0x10005fe94`（Discharging accessor）。

```swift
func Pause.run(sensorInfo: SensorInfo) {
    handleDisconnectState(sensorInfo)

    let pct = sensorInfo.currentPercentage

    if settings.sailingMode {
        let lower = max(settings.chargeVal - settings.sailingLevel, 20.0)
        if pct > lower {
            if settings.lastSailingCheckpoint != 0 {
                transition(to: Sailing); return
            }
        }
    }

    if pct < settings.chargeVal {
        transition(to: Charging)
    } else if pct > settings.chargeVal && settings.automaticDischarge {
        transition(to: Discharging)
    }
}
```

> `Pause` 的语义是“充电暂停/等待”，不是“暂停航海”。它在 `pct < chargeVal` 时恢复充电，在高于上限且开启自动放电时进入放电纠偏。

### 2.6 `Discharging.run` 伪代码（`0x10005f270`）

关键指令：

- `0x10005f2e0` 读 `SensorInfo.currentPercentage`；`0x10005f33c` 读 `settings.chargeVal`；`0x10005f388` `fcvtzs x8,s8`（current）、`0x10005f38c` `fcvtzs x9,s0`（chargeVal）；`0x10005f390` `cmp x9,x8`；`0x10005f394` `b.lt 0x10005f424`（`chargeVal < current` → 继续放电，返回）。
- 否则（current <= chargeVal）：`0x10005f3b8` 读 `settings.sailingMode`；true → `0x10005f3c8` `bl 0x1000fded8`（Sailing）；false → `0x10005f3e8` `bl 0x100098798`（Pause）。

```swift
func Discharging.run(sensorInfo: SensorInfo) {
    handleDisconnectState(sensorInfo)
    let pct = sensorInfo.currentPercentage
    let limit = settings.chargeVal

    if Int(limit) < Int(pct) {
        // 仍高于上限：保持强制放电
        return
    }
    // 已回到上限以内：停止放电
    if settings.sailingMode { transition(to: Sailing) }
    else { transition(to: Pause) }
}
```

### 2.7 完整时序：与任务中“先充电到上限→强制放电到下限→再充电”的差异

按二进制还原，正常的航海循环是：

```text
[Charging]
  电量 < chargeVal: 持续充电（SMC 处于 allow 状态）
  电量 >= chargeVal 且 chargeVal <= 99:
      sailingMode == true  -> [Sailing]
      sailingMode == false -> [Pause]

[Sailing]
  充电已停（推断：状态机在离开 Charging 时调用 HardwareManager.disableCharging；
           本报告未逐条追到 Swift async 的调用点，但 SMC 序列语义与状态名一致）
  电池自然回落（macOS 从适配器取电，电池仅因负载有小的自放电）
  电量 <= max(chargeVal - sailingLevel, 20) -> [Pause]（日志 going to pause again）
  电量 < 20 -> [Charging]（日志 going to charge again）
  电量 > chargeVal（overshoot）且 automaticDischarge == true -> [Discharging]

[Pause]
  电量 < chargeVal -> [Charging]（重新充电）
  电量 > chargeVal 且 automaticDischarge -> [Discharging]
  否则保持暂停（例如正好停在 chargeVal）

[Discharging]
  电量 > chargeVal: 保持强制放电（只放到 chargeVal 附近）
  电量 <= chargeVal: sailingMode ? [Sailing] : [Pause]
```

因此：

- **“先充电到上限”**：成立（`Charging` → 上限）。
- **“强制放电到下限”**：**不成立**。正常航海的回落是自然放电；`Discharging` 只用于 `current > chargeVal` 的 overshoot 纠偏，且目标是 `chargeVal`。
- **“再充电”**：成立（下限 → `Pause` → `Charging`）。
- 如果复刻实现把“强制放电到 `chargeVal - sailingLevel`”作为默认行为，会比 AlDente 激进得多，也会显著增加电池循环与发热；这是本文最重要的语义纠正。

### 2.8 断开电源 / 重新连接 / 睡眠

- `SensorInfo` 有 `chargerConnected`（偏移 +0x1c）和 `lidClosed`（+0x1d）等字段（来自 `_TtC7AlDente10SensorInfo` ivar 表）。
- 四个 `run` 方法开头都用同一段逻辑维护 `disconnected`：
  - `chargerConnected == true` 且 `self.disconnected == true` → `self.disconnected = false`，调用 `0x10001b4ac`（日志 `on connected!`，并记录时间戳）。
  - `chargerConnected == false` 且 `self.disconnected == false` → `self.disconnected = true`，写日志 `on disconnected!`。
- `0x10001b4ac` 本身只记录时间戳/日志（调用 `NSDate`、`timeIntervalSince1970`、`0x10006f814`；日志字符串由 `0x10001b500`-`0x10001b520` 拼成 `on connected!`），**没有 SMC 写**。因此“掉电恢复 SMC”不是在这里完成的；推断它依赖状态机随后回到 `Charging` 时执行 `enableCharging`（§7 未确认项）。
- 睡眠：`asleep` 标志在 `ChargeState` +0x22；`0x10001a4f8` 设置 `asleep=true`，`0x10001b0a4` 清除 `asleep` 并写日志。`Sailing.run` 本身不检查 `asleep`，睡眠/唤醒后的状态重建由 `StateManager.update` 负责（推断）。
- 复刻要求：**断开电源时必须主动把充电抑制键恢复为 allow（至少 `CH0C=0/CH0I=0` 或 `CHTE=0`）**，不能依赖“下一次插电再恢复”，否则用户在拔电期间无法判断机器处于什么状态，且异常退出可能永久留下抑制。

---

## 3. SMC 键值与写入序列

### 3.1 常量表

| 键 | 小端值 | 字节（ASCII） | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| `CH0B` | `0x42304843` | `43 48 30 42` = `C H 0 B` | 旧固件充电允许/禁止（经典键） | `0x1001af43c` 等 |
| `CH0C` | `0x43304843` | `43 48 30 43` = `C H 0 C` | 旧固件充电控制/放电配置（0/1/2） | `0x1001af4d0`、`0x1001af704`、`0x1001afa68` |
| `CH0I` | `0x49304843` | `43 48 30 49` = `C H 0 I` | 放电/电流控制（0/1/8） | `0x1001af488`、`0x1001af6b8`、`0x1001afab0` |
| `CHIE` | `0x45494843` | `43 48 49 45` = `C H I E` | Tahoe 固件充放电控制（写 0；外部文档称 0x08 为 active discharge） | `0x1001af3a0`、`0x1001af610`、`0x1001af9e8` |
| `CHTE` | `0x45544843` | `43 48 54 45` = `C H T E` | Tahoe 固件充电抑制（0x01000000 禁止，0 允许） | `0x1001af3ec`（`CHIE + 0xb0000`）、`0x1001af65c`、`0x1001af9e8` |
| `BCLM` | `0x4D4C4342` | `42 43 4C 4D` = `B C L M` | 旧版/Intel 最大充电值（0–100） | `0x1001af120`、`0x1001b13c0` 附近的 reset |
| `CHWA` | `0x41574843` | `43 48 57 41` = `C H W A` | 调试读取（`0x100096864` 只读） | 观察（只读） |
| `CHCC` | `0x43434843` | `43 48 43 43` = `C H C C` | 调试读取（`0x1001b04c0` 走 read helper `0x10005b15c`） | 观察（只读） |
| `ACLC` | `0x434C4341` | `41 43 4C 43` = `A C L C` | MagSafe LED 控制（写 6/1 等），与航海无关 | `0x1001b5748`、`0x1001b57a8` |

> `CHTE` 不是直接 `movk` 常量，而是 `mov w21,#0x4843; movk w21,#0x4549,lsl16` 得到 `CHIE`，再 `add x0, x21, #0xb0, lsl #12`（`0x1001af3ec`）得到 `0x45544843`。这是本文还原 `CHTE` 的关键指令。

### 3.2 三个写序列（地址、顺序、值）

> 二进制已被 strip，没有函数符号；下面的“允许充电/禁止充电/强制放电”名称是根据键、值、分支与状态语义命名的**推断-强**，不是二进制中的符号名。所有键、值、顺序都是观察。

#### A. 允许充电 / 恢复充电（`0x1001af2f8`）

函数入口 `0x1001af2f8`（`sub sp, sp, #0x60`），先取 `HardwareManager.shared`（`0x1004a44e8`）与 `mbModel` 偏移（`0x10044ad98` = +16），判断 `Capabilities.TahoeFirmware`（`ldrb w8,[x19,#0x1a]; cmp #1; b.ne 0x1001af408`）。

Tahoe 分支（`0x1001af364`-`0x1001af404`）：

| 顺序 | 键 | 值 | 指令位置 |
| --- | --- | --- | --- |
| 1 | `CHIE` | `0`（`SMCByte`） | `0x1001af3a0`（`mov w0,#0x4843; movk #0x4549`），`0x1001af3c4` `mov w3,#0` |
| 2 | `CHTE` | `0`（`SMCByte32`，4 字节） | `0x1001af3ec` `add x0,x21,#0xb0,lsl12`，`0x1001af400` `setSMCByte32WithKey:value:`，`0x1001af4f0` `mov w3,#0` |

旧固件分支（`0x1001af408`-`0x1001af508`）：

| 顺序 | 键 | 值 | 指令位置 |
| --- | --- | --- | --- |
| 1 | `CH0B` | `0` | `0x1001af43c`，`0x1001af460` `mov w3,#0` |
| 2 | `CH0I` | `0` | `0x1001af488`，`0x1001af4a8` `mov w3,#0` |
| 3 | `CH0C` | `0` | `0x1001af4d0`，`0x1001af4f0` `mov w3,#0` |

#### B. 禁止充电 / 暂停充电（`0x1001af568`）

Tahoe 分支（`0x1001af5d4`-`0x1001af680`）：

| 顺序 | 键 | 值 | 指令位置 |
| --- | --- | --- | --- |
| 1 | `CHIE` | `0`（`SMCByte`） | `0x1001af610`，`0x1001af634` `mov w3,#0` |
| 2 | `CHTE` | `0x01000000`（`SMCByte32`） | `0x1001af65c`，`0x1001af67c` `mov w3,#0x1000000` |

旧固件分支（`0x1001af684`-`0x1001af750`）：

| 顺序 | 键 | 值 | 指令位置 |
| --- | --- | --- | --- |
| 1 | `CH0I` | `0` | `0x1001af6b8`，`0x1001af6dc` `mov w3,#0` |
| 2 | `CH0C` | `2` | `0x1001af704`，`0x1001af724` `mov w3,#2` |

#### C. 强制放电（`0x1001af934` 为异步 continuation；非 Tahoe 分支在 `0x1001afa30`）

Tahoe 分支（`0x1001af9ac`-`0x1001afaf0`）：

| 顺序 | 键 | 值 | 指令位置 |
| --- | --- | --- | --- |
| 1 | `CHTE` | `0x01000000`（`SMCByte32`） | `0x1001af9e8` `add x0,x20,#0xb0,lsl12`，`0x1001afa08` `mov w3,#0x1000000` |
| 2 | `CH0I` | `8`（`SMCByte`） | `0x1001afa28` `mov w19,#8`，`0x1001afab0` `mov w20,#0x4843; movk #0x4930`，`0x1001afadc` `mov x3,x19` |

旧固件分支（`0x1001afa30`-`0x1001afaf0`）：

| 顺序 | 键 | 值 | 指令位置 |
| --- | --- | --- | --- |
| 1 | `CH0C` | `1` | `0x1001afa68`，`0x1001afa8c` `mov w3,#1` |
| 2 | `CH0I` | `1` | `0x1001afab0`，`0x1001afadc` `mov x3,x19`（`w19=1`） |

> 推断（强）：`Discharging` 进入前通常会先执行 `disableCharging`（写 `CH0I=0, CH0C=2` / `CHIE=0, CHTE=0x01000000`），再执行上述强制放电序列；因为强制放电的 Tahoe 分支自己也写 `CHTE=0x01000000`，最终状态是：
> - 旧固件：`CH0C=1`、`CH0I=1`
> - Tahoe：`CHTE=0x01000000`、`CH0I=8`
> 这与外部资料中“Tahoe 用 `CHIE=0x08` 放电”的写法存在版本/机型差异（见 §7）。

### 3.3 平台分支（Tahoe 固件）

分支条件：

```text
HardwareManager.shared (0x1004a44e8)
  + [0x10044ad98] = +16  -> mbModel 字段
  + 0x20                 -> 某个 Capabilities 对象
  + 0x1a                 -> Bool
  cmp #1                 -> Tahoe 分支
```

`_TtC7AlDente12Capabilities` 的 ivar 表显示：`TahoeFirmware` 位于 **+0x1a (26)**（`Magsafe3=16, Magsafe2=17, PowerFlow=18, HardwareBatteryPercentage=19, Intel=20, AdvancedIntel=21, AppleSilicon=22, Thunderbolt=23, AppleHardwareHealth=24, LowPowerMode=25, TahoeFirmware=26, Desktop=27, HighPowerMode=28`）。因此可合理推断该 Bool 是 `Capabilities.TahoeFirmware`（强度：推断-中；路径 `HardwareManager.mbModel + 0x20` 的字段名无法从二进制直接恢复）。

平台行为：

- **旧固件（TahoeFirmware = false）**：`CH0B`、`CH0C`、`CH0I` 三个经典键；允许充电写 `CH0B=0, CH0I=0, CH0C=0`；禁止充电写 `CH0I=0, CH0C=2`；强制放电写 `CH0C=1, CH0I=1`。
- **Tahoe 固件（TahoeFirmware = true）**：`CHIE` + `CHTE`；允许充电写 `CHIE=0, CHTE=0`；禁止充电写 `CHIE=0, CHTE=0x01000000`；强制放电写 `CHTE=0x01000000, CH0I=8`（注意：不是 `CHIE=8`，见 §7）。

### 3.4 恢复路径

1. **允许充电序列就是恢复路径**：`0x1001af2f8` 会清 `CH0B/CH0I/CH0C`（旧）或 `CHIE/CHTE`（Tahoe）。
2. **独立 reset 例程**：`0x1001b11a8` 开始的异步函数（`0x1001b11a8`-`0x1001b1538`）：
   - 读 `Capabilities.TahoeFirmware`；
   - 按 `HardwareManager` 当前 `mbModel`/参数（`[x22+0x58]`）决定是否写 `CHTE=0x01000000`；
   - 写 `CH0B=0`（`0x1001b13c0`）；
   - 写 `CH0C = w19`（`0x1001b1410`，`w19` 来自 `[x22+0x58]`，0 或 1）；
   - 写 `CH0I=0`（`0x1001b1470`）。
   该函数没有直接调用者（async 函数指针调用），具体入口未完全确认；从指令看它是“把充电恢复到可控状态”的 reset，而不是普通退出路径的唯一实现。
3. **Helper 的 modifiedKeys 回写**：
   - `PrivilegedHelper` 有 `modifiedKeysUInt8`（+8）和 `modifiedKeysUInt32`（+16）两个字典。
   - `setResetValWithKey:value:`（Helper `0x100007c60`）把值写入 `modifiedKeysUInt8`；`setResetVal32WithKey:value:`（`0x100007d28`）写入 `modifiedKeysUInt32`。
   - `removeHelper`（Helper `0x1000069bc`）先打日志 `trying to uninstall helper`，再调用 `0x100006388`：遍历两个字典并把记录的 UInt8/UInt32 值写回 SMC（`0x100007198` / `0x100006b80`），然后 `exit(0)`。
   - **重要**：`setResetVal` 只是“记录将来要恢复的值”，不是立即写入；`removeHelper` 才执行恢复。正常 App 退出 / 崩溃不会自动触发 helper 的这个 reset（除非 App 显式调用 `removeHelper`）。
4. **App 终止路径**：`AppDelegate` 的终止处理只看到 `App is terminating, Topup will be disabled`（`0x10008f6d8`），以及调用 `0x10001bc7c`（`StateManager.setChargeLimit`，把充电上限改回某值）——**没有看到对 SMC 恢复键的明确调用**。因此“退出时恢复”在 1.36.2 中可能依赖状态机把状态切回 `Charging`，或依赖 `HardwareManager` 的 reset 异步任务；证据不足，复刻必须自行补全。

### 3.5 `BCLM`、`ACLC`、`CHWA`、`CHCC` 与航海的关系

- `BCLM` 是旧版/Intel 模式的最大充电值键（`0x1001ae264`、`0x1001ae31c`、`0x1001ae37c` 一带写 100 或按设置值；`0x1001ae330` 处还调用 `setResetVal` 记录恢复值）。航海模式路径没有写 `BCLM`；航海的边界由 `CH0B/CH0C/CH0I` 或 `CHIE/CHTE` 控制。
- `ACLC` 在 `0x1001b5748`-`0x1001b57c8` 写 6/1，属于 MagSafe LED 颜色控制，不是航海。
- `CHWA`/`CHCC` 仅出现在调试字符串读取（`0x100096864` / `0x1001b04c0`），不是航海写路径。

---

## 4. Helper XPC 接口

### 4.1 Mach service 与协议

- Helper 路径：`/Applications/AlDente.app/Contents/Library/LaunchServices/com.apphousekitchen.aldente-pro.helper`（`CFBundleVersion = 19`）。
- Mach service：`com.apphousekitchen.aldente-pro.helper`（由 Helper 的 `Info.plist`/`launchd` 配置与 App 内 `initWithMachServiceName:` 字符串共同确认）。
- App 侧 `HelperConnector`（`_TtC7AlDente15HelperConnector`，类对象 `0x10043d988`）持有：
  - `helperMonitor` +8
  - `helperToolConnection` +16（XPC proxy）
  - `xpcConnection` +24
  - `isInitialized` +32
  - `disableInflowID` +36
  - `currentlyInstalling` +41
  - `dischargeQueryInProgress` +42
- Helper 侧 `PrivilegedHelper`（`_TtC38com_apphousekitchen_aldente_pro_helper16PrivilegedHelper`）实现 `HelperProtocol`；类 ivar 包括 `modifiedKeysUInt8` +8、`modifiedKeysUInt32` +16、`openAssertions` +24、`debugStrings` +32、`connectionCount` +40、`runningAppsCallback` +48、`sleepWhenClosedEnabled` +64。

### 4.2 协议方法表（24 个）

类型编码来自 Helper 二进制的 `otool -ov`（`HelperProtocol` 协议 `instanceMethods`），地址为 Helper 实现 IMP：

| # | Selector | ObjC 类型编码 | Swift 语义（推断） | IMP（Helper） |
| --- | --- | --- | --- | --- |
| 1 | `getVersionWithReply:` | `v24@0:8@?16` | `(String) -> Void` reply | `0x100006748` |
| 2 | `removeHelper` | `v16@0:8` | 卸载 Helper，恢复 modifiedKeys 后 exit | `0x1000069bc` |
| 3 | `checkIfKeyExistsWithKey:withReply:` | `v32@0:8@16@?24` | `(String, (Bool)->Void)` | `0x100006abc` |
| 4 | `setSMCByteWithKey:value:` | `v28@0:8@16C24` | `(String, UInt8)` | `0x100007570` |
| 5 | `setSMCByte32WithKey:value:` | `v28@0:8@16I24` | `(String, UInt32)` | `0x100007138` |
| 6 | `readSMCByteWithKey:withReply:` | `v32@0:8@16@?24` | `(String, (UInt8)->Void)` | `0x1000075d0` |
| 7 | `readSMCByte16WithKey:withReply:` | `v32@0:8@16@?24` | `(String, (UInt16)->Void)` | `0x100007720` |
| 8 | `readSMCByte32WithKey:withReply:` | `v32@0:8@16@?24` | `(String, (UInt32)->Void)` | `0x10000772c` |
| 9 | `readSMCsp78WithKey:withReply:` | `v32@0:8@16@?24` | `(String, (Float)->Void)`（sp78 定点） | `0x100007738` |
| 10 | `readSMCDataWithKey:withReply:` | `v32@0:8@16@?24` | `(String, (Data)->Void)` | `0x100007744` |
| 11 | `readFloatWithKey:withReply:` | `v32@0:8@16@?24` | `(String, (Float)->Void)` | `0x100007750` |
| 12 | `createAssertionWithAssertion:withReply:` | `v32@0:8@16@?24` | `(String, (IOPMAssertionID)->Void)` | `0x1000077ec` |
| 13 | `releaseAssertionWithAssertionID:withReply:` | `v28@0:8I16@?20` | `(UInt32, (Void)->Void)` | `0x1000078f8` |
| 14 | `disableSleepWhenClosedWithDisabled:withReply:` | `v28@0:8B16@?20` | `(Bool, (Void)->Void)` | `0x100007bf8` |
| 15 | `setResetValWithKey:value:` | `v28@0:8@16C24` | `(String, UInt8)`：记录待恢复值 | `0x100007c60` |
| 16 | `setResetVal32WithKey:value:` | `v28@0:8@16I24` | `(String, UInt32)`：记录待恢复值 | `0x100007d28` |
| 17 | `findAssertionsWithReply:` | `v24@0:8@?16` | `([Any]) -> Void` | `0x100007960` |
| 18 | `setSystemSleepEnabledWithIsEnabled:` | `v20@0:8B16` | `(Bool)` | `0x100007df0` |
| 19 | `sleepNow` | `v16@0:8` | 立即睡眠 | `0x100007df8` |
| 20 | `getDebugInfoWithReply:` | `v24@0:8@?16` | `(String) -> Void` | `0x100006910` |
| 21 | `setLowPowerModeOldWithIsEnabled:` | `v20@0:8B16` | `(Bool)`（旧 pmset 路径） | `0x100006a44` |
| 22 | `setLowPowerModeWithMode:` | `v24@0:8q16` | `(Int64)` | `0x100006ab4` |
| 23 | `setEnergyModeOnAdapterWithMode:` | `v24@0:8q16` | `(Int64)` | `0x100006aa4` |
| 24 | `setEnergyModeOnBatteryWithMode:` | `v24@0:8q16` | `(Int64)` | `0x100006aac` |

> 依据：`/Applications/AlDente.app/Contents/Library/LaunchServices/com.apphousekitchen.aldente-pro.helper` 的 `otool -ov -arch arm64` 输出（`HelperProtocol` 段，文件行 737-790），以及 `rea inspect-native-dispatch-metadata` 的 `objc_dispatch_implementations`（IMP 地址）。类型编码中 `C` = `unsigned char`，`I` = `unsigned int`，`q` = `long long`，`B` = `bool`。

### 4.3 对复刻的接口含义

- 复刻不需要 1:1 复制全部 24 个方法；航海模式只需要：
  - `setSMCByte(key:value:)`（UInt8：`CH0B/CH0C/CH0I/CHIE`）
  - `setSMCByte32(key:value:)`（UInt32：`CHTE`）
  - 可选：`readSMCByte` / `readSMCByte32` 用于写后回读验证；
  - 可选：`getVersionWithReply` 做协议版本检查。
- 必须保留 `setResetVal*` 的语义：**记录原值**，而不是立即写；否则恢复路径会写错值。
- 必须实现“写前记录/写后校验/失败回滚”，并且 Helper 的 XPC 接口要限制调用方签名（AlDente 使用 `SMAuthorizedClients` 限定 `identifier "com.apphousekitchen.aldente-pro"`）。

---

## 5. 证据表

> 文件 offset 为 arm64 slice 内的偏移（Arm64 slice 在 fat 文件中的起始偏移为 `0x5B0000`；`file_offset = 0x5B0000 + (VA - 0x100000000)`）。
>
> 强度：观察 / 推断 / 未知。

| # | 结论 | 虚拟地址（arm64） | 指令/字符串片段 | 文件 offset | 强度 |
| --- | --- | --- | --- | --- | --- |
| 1 | 航海模式文案：回到 `chargeVal - sailingLevel` 才充电 | 字符串 `0x1003810d0` / `0x100381120` | `SAILING STOPPED BECAUSE OF TOO LOW VALUE -  going to pause again` / `... going to charge again` | `0x9310d0` / `0x931120` | 观察 |
| 2 | 20% 硬下限指令 | `0x1000fe140`-`0x1000fe148` | `fmov s8,#20.0; fcmp s9,s8; b.pl 0x1000fe1f8` | `0x6ae140` | 观察 |
| 3 | `sailingLevel` 最小 1% | `0x1000fe100`-`0x1000fe118` | `fmov s1,#1.0; fcmp; b.pl; bl 0x10012ddfc` | `0x6ae100` | 观察 |
| 4 | 下限计算 `max(chargeVal-sailingLevel,20)` | `0x1000fe238`-`0x1000fe24c` | `fsub s0,s10,s0; fcmp s0,s8; b.hi; fmov s0,#20.0; fcmp s9,s0; b.hi` | `0x6ae238` | 观察 |
| 5 | 低于 20 → Charging | `0x1000fe1b4` | `mov x0,#0; bl 0x10006ff94`（Charging accessor） | `0x6ae1b4` | 观察 |
| 6 | 到下限 → Pause | `0x1000fe2b8` | `mov x0,#0; bl 0x100098798`（Pause accessor） | `0x6ae2b8` | 观察 |
| 7 | 超上限且自动放电 → Discharging | `0x1000fe394`-`0x1000fe3c0` | `ldr x8,[x8,#0xea8]`（automaticDischarge）；`ldrb w8,[x20,#0x22]; cmp #1; bl 0x10005fe94` | `0x6ae394` | 观察 |
| 8 | `Sailing.run` 入口及类 vtable | `0x1004499e0` + `0xd8` → `0x1000fe50c` | 类元数据 `_TtC7AlDente7Sailing`；`0x1000fe50c: b 0x1000fdef8` | `0x9f99e0`（类元数据）/ `0x6ae50c`（thunk） | 观察 |
| 9 | `Charging.run`：到上限且 sailingMode → Sailing | `0x1000702b4`-`0x1000702f0` | `cmp x9,x8; b.lt; cmp x8,#0x63; b.gt; ldrb w8,[x20,#0x22]; cmp #1; b.ne; bl 0x1000fded8` | `0x6202b4` | 观察 |
| 10 | `Pause.run`：当前电量高于下限且 checkpoint 非 0 → Sailing | `0x1000989f4`-`0x100098a44` | `fsub; fcmp; b.mi; ldr x8,[x8,#0xf40]; ldr x8,[x20,#0x30]; cbz; bl 0x1000fded8` | `0x6489f4` | 观察 |
| 11 | `Discharging.run`：只放到 `chargeVal` | `0x10005f390`-`0x10005f394` | `cmp x9,x8; b.lt 0x10005f424`（chargeVal < current → 继续） | `0x60f390` | 观察 |
| 12 | `StateManager.update` 航海入口 | `0x10010139c`、`0x10010153c`-`0x1001016f4` | `settings.sailingMode`、Charging/Pause 动态检查、`chargeVal-sailingLevel`、`lastSailingCheckpoint` | `0x6b139c` | 观察 |
| 13 | 允许充电 Tahoe：`CHIE=0` + `CHTE=0` | `0x1001af3a0`-`0x1001af4f0` | `mov w0,#0x4843; movk #0x4549`；`add x0,x21,#0xb0,lsl12`；`setSMCByte32` | `0x75f3a0` | 观察 |
| 14 | 允许充电旧固件：`CH0B=0, CH0I=0, CH0C=0` | `0x1001af43c`-`0x1001af4f0` | 三个 `movk #0x4230/#0x4930/#0x4330` 与 `mov w3,#0` | `0x75f43c` | 观察 |
| 15 | 禁止充电 Tahoe：`CHIE=0` + `CHTE=0x01000000` | `0x1001af610`-`0x1001af67c` | `mov w3,#0x1000000` | `0x75f610` | 观察 |
| 16 | 禁止充电旧固件：`CH0I=0` + `CH0C=2` | `0x1001af6b8`-`0x1001af724` | `mov w3,#2` | `0x75f6b8` | 观察 |
| 17 | 强制放电 Tahoe：`CHTE=0x01000000` + `CH0I=8` | `0x1001af9e8`-`0x1001afadc` | `mov w3,#0x1000000`；`mov w19,#8`；`movk #0x4930` | `0x75f9e8` | 观察 |
| 18 | 强制放电旧固件：`CH0C=1` + `CH0I=1` | `0x1001afa68`-`0x1001afadc` | `mov w3,#1`；`mov w19,#1` | `0x75fa68` | 观察 |
| 19 | SMC `CHTE` 由 `CHIE + 0xb0000` 构造 | `0x1001af3ec` / `0x1001af65c` / `0x1001af9e8` | `add x0, x21, #0xb0, lsl #12` | `0x75f3ec` | 观察 |
| 20 | 平台分支 Bool（Capabilities.TahoeFirmware +0x1a） | `0x1001af358` / `0x1001af5c8` / `0x1001af9a0` | `ldrb w8,[x19,#0x1a]; cmp #1` | `0x75f358` | 推断-中 |
| 21 | `AHKSettings` 字段布局 | `0x10044ae10` / `0x10044ae18` / `0x10044ae20` / `0x10044af40` | ivar offset 8/16/24/312 | `0x9fae10` | 观察 |
| 22 | `chargeVal` 默认 80、`sailingLevel` 默认 5 | `0x10012ff18` / `0x100130048` | `mov w8,#0x42a00000` / `#0x40a00000` | `0x6dff18` | 观察 |
| 23 | Helper `setResetVal` 记录待恢复值 | Helper `0x100007c60` / `0x100007d28` | `modifiedKeysUInt8` / `modifiedKeysUInt32` 字典写入 | Helper offset `0x7c60` 等 | 观察 |
| 24 | Helper `removeHelper` 写回并退出 | Helper `0x1000069bc` → `0x100006388` | 遍历 modifiedKeys、写 SMC、`exit(0)` | Helper offset `0x69bc` / `0x6388` | 观察 |
| 25 | Helper 协议 24 方法及类型 | Helper `otool -ov` `HelperProtocol` 段 | 见 §4.2 | — | 观察 |
| 26 | 外部资料：Tahoe `CHTE` 抑制/允许 | https://github.com/actuallymentor/battery/pull/388 | `CHTE 01000000` 禁止、`00000000` 允许；`CHIE 08` 放电 | — | 外部来源（交叉验证） |
| 27 | 外部资料：Sailing 是自然回落区间 | https://apphousekitchen.com/aldente-overview/ `Sailing Mode` 段 | “set a range… lets the battery drift down to 75%…” | — | 外部来源 |
| 28 | 外部资料：20% 覆盖 | App 内 `hlpSailingMinPerc`（同 #1 的 strings 文件） | 见 §1.1 | — | 观察（本地化文件） |
| 29 | 外部资料：Sailing Mode 扩展 Charge Limiter，暂停在充电上限，电池仅小额自放电 | https://apphousekitchen.com/aldente-overview/features/ | “Sailing Mode extends the Charge Limiter… small discharges of the battery still occur…” | — | 外部来源 |
| 30 | 外部资料：第三方 SMC 键表（CHTE/CHIE） | https://amperebattery.app/tech.html | `CHTE ui32 0x01000000 paused / 0x00000000 allowed`；`CHIE 0x08 discharging / 0x00 normal` | — | 外部来源（需真机复核） |

> 说明：所有 `file_offset` 均由脚本 `0x5B0000 + (VA - 0x100000000)` 计算（arm64 slice 起始 `0x5B0000`）；例如 `0x1000fdef8 → 0x6adef8`、`0x1000fe50c → 0x6ae50c`、`0x1001af2f8 → 0x75f2f8`、`0x100381120 → 0x931120`、`0x1004499e0 → 0x9f99e0`。

---

## 6. 对复刻实现的“必须做到”清单与风险

### 6.1 必须做到（MUST）

1. **状态语义**
   - 到 `chargeVal`（且 `chargeVal <= 99`）后停止充电；若 `sailingMode` 开启进入航海状态；否则进入 Pause。
   - 下限 = `max(chargeVal - sailingLevel, 20)`；到下限后先回 Pause，再由 Pause 转 Charging。
   - `currentPercentage < 20` 时无条件 Charging，优先于任何区间计算。
   - `sailingLevel` 必须钳制到 `>= 1`；`chargeVal` 为 100 时不启动航海。
2. **默认值与边界**
   - `chargeVal` 默认 80，范围 20–100（UI 滑杆）。
   - `sailingLevel` 默认 5，推荐 5–10；UI 最小 1；上限应保证 `chargeVal - sailingLevel >= 20`（或按 AlDente 的 max() 语义自动抬到 20）。
   - `lastSailingCheckpoint` 默认 -1/0 语义必须明确；`Pause.run` 只有在它非 0 时才允许回到 Sailing。
3. **状态机与模式互斥**
   - Top Up / Calibration 必须在状态机层面优先于 Sailing；不要只在 UI 上灰掉开关。
   - 关闭航海模式时：Sailing 必须立刻退出到 Pause/Charging，并写“允许充电”SMC 序列。
   - 充电中/暂停中才允许进入 Sailing；Discharging/TopUp/Calibration/HeatProtect 中不得进入。
4. **SMC 写入**
   - 旧固件：允许充电 `CH0B=0, CH0I=0, CH0C=0`；禁止充电 `CH0I=0, CH0C=2`；强制放电 `CH0C=1, CH0I=1`。
   - Tahoe 固件：允许充电 `CHIE=0, CHTE=0`；禁止充电 `CHIE=0, CHTE=0x01000000`；强制放电 `CHTE=0x01000000, CH0I=8`（或按实测机型验证 `CHIE=0x08`）。
   - 必须按本报告的顺序写（尤其是 Tahoe 先 `CHIE` 再 `CHTE`；强制放电先 `CHTE` 再 `CH0I`）。
   - 写入前读取原值并记录（Helper `setResetVal*` 的语义），写入后回读校验。
5. **恢复/安全**
   - 关闭航海、退出 App、Helper 卸载、断电源、App 崩溃 → 必须恢复为允许充电（`CH0B=0/CH0I=0/CH0C=0` 或 `CHIE=0/CHTE=0`）。
   - 独立看门狗（例如 launchd/Helper 监控 App PID）是**必须**的；不能依赖应用内 `deinit`/`applicationWillTerminate`。
   - 对 `CH0C=2` / `CH0I=1` 的残留状态有开机/启动自检和修复。
6. **Helper / XPC**
   - 协议方法名、参数类型、reply block 类型必须与 §4.2 一致（至少 `setSMCByteWithKey:value:`、`setSMCByte32WithKey:value:`、`readSMCByte*`、`getVersionWithReply:`）。
   - 写 SMC 的 Helper 必须校验调用方代码签名（`SMAuthorizedClients` 类似限制）。
   - `setResetVal*` 不得直接写 SMC；必须只记录。
7. **UI/产品**
   - “Will sail to `chargeVal - sailingLevel`”预览；航海模式开关和航海电量滑杆。
   - 关闭时文案 `Sailing Mode deactivated.`；激活时 `Sailing mode activated.`。
   - 20% 提示、Top Up/Calibration 禁用提示。
8. **日志/可观测性**
   - 至少记录：进入/退出 Sailing、进入/退出 Charging、SMC 写入失败、回读失败、恢复失败；日志不要包含用户隐私数据。

### 6.2 风险清单

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| **SMC 键语义/机型差异** | `CHIE`/`CHTE`/`CH0I` 在不同 macOS 26.x 固件/机型上行为可能不同；AlDente 1.36.2 的 Tahoe 强制放电写 `CH0I=8`，而外部资料有 `CHIE=0x08` 的写法（§7） | 先用只读探测确认键存在与属性；在真机逐机型验证；把写序列做成可配置表 |
| **残留抑制导致不充电** | `CH0C=2` / `CH0I=1` / `CHTE=0x01000000` 是持续状态；App 崩溃/强杀可能留下 | 看门狗 + 启动自检 + Helper `modifiedKeys` 回写 + 退出恢复 |
| **强制放电的 PD 重协商** | 外部资料（Ampere）指出 `CHIE=0x08` 会导致 USB-C PD 重协商，clamshell 下可能黑屏 | 只在必要时短时放电；放电期间禁用系统睡眠；恢复休眠设置 |
| **20% 与 chargeVal 边界** | 浮点/整数比较边界（`<20`、`<= lower`）容易差 1%；UI 显示百分比 vs 硬件百分比可能不同 | 用整数百分比做业务判断；明确 `floor/round` 规则 |
| **`lastSailingCheckpoint` 语义** | 默认 -1，UI 写 1；`Pause.run` 只判断非 0；真实语义未完全确认 | 复刻时用显式枚举/布尔替代，不要照搬魔数；把“航海已武装”和“上次电量”分开建模 |
| **Top Up/Calibration 互斥** | 二进制只在状态机层避免进入 Sailing，没有看到全局 `if topup` 检查；如果复刻允许从任意状态进入 Sailing 会冲突 | 在状态机中显式建模优先级：Calibration > TopUp > Sailing > Charging/Pause |
| **SMC 写入并发** | AlDente 的 Helper 是单连接串行处理；复刻若并发写多个键可能出现中间态 | 用 actor/serial queue 串行化 SMC 写序列；一次事务写完再回读 |
| **100% 边界** | `chargeVal=100` 时 AlDente 不启动航海；复刻若允许 100% 会导致“永远不放电/永远满电” | 在 UI 和状态机都禁止 `sailingMode && chargeVal==100` |
| **Helper 权限/签名** | 复制 AlDente 的 24 方法接口会扩大攻击面 | 只暴露航海所需最小方法集；限制调用方签名；拒绝任意 key 的 SMC 写（白名单键） |

---

## 7. 未确认项（明确标注）

1. **`CHIE=0x08` vs `CH0I=8` 的 Tahoe 强制放电差异**：AlDente 1.36.2 的指令明确写 `CH0I` 键值 8（`0x1001afab0` 的 `movk #0x4930`），而 actuallymentor/battery PR #388 与 Ampere 文档称 Tahoe 用 `CHIE=0x08`。可能是 1.36.2 仍使用旧键名/特定机型路径，或外部资料对应更新版本；**未在真机验证**。
2. **`Capabilities.TahoeFirmware` 的路径推断**：`HardwareManager.mbModel +0x20` 指向的对象在二进制中没有直接类型名；`+0x1a` 与 Capabilities.TahoeFirmware 偏移一致，但无法排除是另一个 26 字节布局的类。建议在真机用 lldb 断在 `0x1001af358` 读取对象类型确认。
3. **`lastSailingCheckpoint` 的精确生命周期**：只看到默认 -1、UI 三处写 1、Pause 读非 0；没有找到“何时清零/何时写回电量”的路径。可能是旧版本遗留字段，或在 UI 开关逻辑里被设置为 1 作为“已启用”标志。复刻建议不要依赖它，改用显式状态。
4. **`HardwareManager.reset`（`0x1001b11a8`）的调用入口**：没有直接 `bl` 调用者（async 函数指针调用），无法确认是正常退出、启动清理还是 Helper 安装过程调用。§3.4 只描述其写入内容，不声称调用时机。
5. **Top Up/Calibration 的精确禁用实现**：文案明确禁用，但二进制中没有发现 `Sailing.run` 内的 `topup`/`calibration` 判断；推断是通过 `StateManager` 当前状态类型（TopUp/Calibration 占据状态）实现。需要动态调试确认。
6. **`sailingLevel` UI 上限**：只确认最小值为 1；上限由 `chargeVal` 推导（`0x100198358` 前有 `bic` 计算），未精确还原公式。
7. **x86_64 版本**：本报告所有地址/offset 均为 arm64 slice；x86_64 版本的函数布局与地址不同。若复刻只支持 Apple Silicon，可忽略；若要支持 Intel，需对 x86_64 二进制单独做同样的 `otool -tvV -arch x86_64` 分析。
8. **百分比来源**：`SensorInfo` 同时有 `currentPercentage`(+0x10)、`osPercentage`(+0x14)、`hwPercentage`(+0x18) 三个字段；`Sailing.run` 读的是 `currentPercentage`，但其填充/选择逻辑（是否受 “Use real percentage” 影响、取整规则）没有在本报告中还原。AlDente 官方说明 1.39 起统一使用 macOS 百分比，1.36.2 的行为可能不同，复刻应以实际 `SensorInfo` 构造路径为准。

---

## 附录 A：关键地址/文件 offset 速查

| 名称 | 虚拟地址 (arm64) | file offset |
| --- | --- | --- |
| `Sailing.run` | `0x1000fdef8` | `0x6adef8` |
| `Sailing` 类元数据 | `0x1004499e0` | `0x9f99e0` |
| `Sailing.run` thunk | `0x1000fe50c` | `0x6ae50c` |
| `Pause.run` | `0x1000987b8` | `0x6487b8` |
| `Charging.run` | `0x10006ffb4` | `0x61ffb4` |
| `Discharging.run` | `0x10005f270` | `0x60f270` |
| `StateManager.update` | `0x10010139c` | `0x6b139c` |
| `HardwareManager.enableCharging` | `0x1001af2f8` | `0x75f2f8` |
| `HardwareManager.disableCharging` | `0x1001af568` | `0x75f568` |
| `HardwareManager.forceDischarge`（continuation） | `0x1001af934` | `0x75f934` |
| `AHKSettings` chargeVal ivar descriptor | `0x10044ae10` | `0x9fae10` |
| `AHKSettings` sailingMode ivar descriptor | `0x10044ae18` | `0x9fae18` |
| `AHKSettings` sailingLevel ivar descriptor | `0x10044ae20` | `0x9fae20` |
| `AHKSettings` lastSailingCheckpoint descriptor | `0x10044af40` | `0x9faf40` |
| `HardwareManager.shared` global | `0x1004a44e8` | `0xa544e8` |
| `AHKSettings.shared` global | `0x1004a44f0` | `0xa544f0` |
| `HelperConnector.shared` global | `0x1004a4380` | `0xa54380` |
| `lastSailingCheckpoint` 字符串 | `0x1003825b0` | `0x9325b0` |
| `SAILING STOPPED ... pause again` | `0x1003810d0` | `0x9310d0` |
| `SAILING STOPPED ... charge again` | `0x100381120` | `0x931120` |

> **File offset 计算说明**：arm64 slice 起始 `0x5B0000`；`file_offset = 0x5B0000 + (VA - 0x100000000)`。例如 `0x1000fdef8 - 0x100000000 = 0x0fdef8`，加 `0x5B0000` 得 `0x6adef8`。正文以虚拟地址为准，offset 仅作辅助。

---

## 附录 B：复刻验收用例（建议）

1. 设置 `chargeVal=80, sailingLevel=10`，电量 60% → 应充电到 80 后停止；模拟电量 79→70 → 在 70 触发充电；模拟 69→20 → 20 触发充电（不是 70 的下限值）。
2. 设置 `chargeVal=80, sailingLevel=10`，模拟电量 81（overshoot）且 `automaticDischarge=false` → 不强制放电；`automaticDischarge=true` → 进入 Discharging，放电到 80 后退出。
3. 设置 `chargeVal=100`，开启 sailingMode → 不进入航海；保持正常充电/暂停。
4. 开启 Top Up / Calibration → 航海不参与；退出后恢复航海。
5. 关闭 sailingMode（在 Sailing 状态）→ 立即退出 Sailing 并恢复允许充电。
6. 强杀 App（Sailing 保持中）→ 看门狗在 N 秒内写回 allow；重新启动 App 后自检修复。
7. 旧固件 / Tahoe 固件分别验证 SMC 写序列与回读值；不支持的键应记录错误而不是静默成功。

---

*本文所有逆向结论来自本地二进制静态分析；没有使用 Ghidra/Hopper/IDA 的引擎分析，也没有进行真机 SMC 写入实验。涉及硬件行为的结论在交付给产品实现前应做真机验证。*
