import SwiftUI

/// Settings for how the battery indicator is drawn in the status icon.
struct BatterySectionView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var statusStore: SystemStatusStore
    @Binding var previewIsDark: Bool
    var chargeToFullNow: ChargeToFullNowController? = nil
    var sailingMode: SailingModeController? = nil
    var magSafeLED: MagSafeLEDController? = nil
    /// When non-`nil` the pane shows only that leaf subtopic beneath the Battery
    /// category; `nil` keeps the original full-pane layout (used by tests and
    /// by any caller that does not drive the two-level sidebar).
    var subtopic: SettingsSubtopic? = nil
    @EnvironmentObject private var localization: Localization
    @ObservedObject private var helper: PrivilegedHelperManager = .shared


    var body: some View {
        // Battery is a single pane now: icon appearance lives under App Icon,
        // and the behaviour controls are grouped by card on one page. The live
        // status-icon preview stays pinned at the top like the other icon pages.
        SettingsPage(pinnedHeader: {
            StatusIconPreviewCard(
                store: store,
                statusStore: statusStore,
                isDarkBackground: $previewIsDark
            )
        }) {
            fullBatteryContent
        }
    }

    @ViewBuilder
    private var fullBatteryContent: some View {
        // Any notice comes first, then the panel show/hide group.
        if !statusStore.snapshot.battery.isPresent {
            noBatteryNoticeGroup
        }
        panelVisibilityGroup
        chargeManagementGroup
        if let magSafeLED {
            MagSafeLEDSettingsGroup(controller: magSafeLED, settings: store)
        }
        sailingModeGroup
        if helper.isAvailable {
            powerModesGroup
        } else {
            SettingsGroup(localization.string(.settingsBatteryGroupPowerModes)) {
                SettingsHintRow(text: localization.string(.lowPowerModeHelperUnavailable))
            }
        }
        powerFlowGroup
    }

    /// Quick show/hide of the battery module in the status panel.
    private var panelVisibilityGroup: some View {
        SettingsGroup(localization.string(.settingsNetworkPanelGroup)) {
            SettingsToggleRow(
                symbol: PopupSection.battery.systemImage,
                tint: .green,
                title: localization.string(.settingsPanelShowBattery),
                subtitle: localization.string(.settingsPanelShowItemDescription),
                isOn: popupSectionBinding(.battery)
            )
        }
    }

    private func popupSectionBinding(_ section: PopupSection) -> Binding<Bool> {
        Binding(
            get: { store.enabledPopupSections.contains(section) },
            set: { store.setPopupSection(section, enabled: $0) }
        )
    }

    /// A Mac without a battery reports 100 as its level; spell that out at the
    /// top of the page so nobody reads the placeholder as a real reading.
    private var noBatteryNoticeGroup: some View {
        SettingsGroup {
            SettingsHintRow(text: localization.string(.settingsBatteryNoBatteryNotice))
        }
    }

    /// "Charging" subtopic: the temporary full-charge action, its restore-limit
    /// control, and the note when the system charge limit cannot be read.
    private var chargeManagementGroup: some View {
        SettingsGroup(localization.string(.settingsBatteryGroupCharging)) {
            chargeManagementContent
        }
    }

    @ViewBuilder
    private var chargeManagementContent: some View {
        SettingsToggleRow(
            symbol: "bolt.badge.clock.fill",
            tint: .green,
            title: localization.string(.settingsBatteryShowChargeToFullNow),
            subtitle: localization.string(.settingsBatteryShowChargeToFullNowDescription),
            isOn: $store.showsChargeToFullNowButton
        )

        if let chargeToFullNow {
            ChargeToFullNowDiagnosticsView(
                controller: chargeToFullNow,
                battery: statusStore.snapshot.battery,
                batterySectionVisible: store.enabledPopupSections.contains(.battery)
                    && store.popupSectionOrder.contains(.battery),
                enabled: store.showsChargeToFullNowButton
            )
        } else if store.showsChargeToFullNowButton {
            Text(localization.string(.settingsBatteryChargeHiddenControllerUnavailable))
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsMetrics.rowPaddingH)
                .padding(.bottom, 8)
        }
        if chargeToFullNow?.isSettingAvailable == true {
            chargeToFullNowContent
        }
        systemChargeLimitUnavailableNote
    }


    @ViewBuilder
    private var chargeToFullNowContent: some View {
        if let chargeToFullNow, chargeToFullNow.isSettingAvailable {
            SettingsDivider()

            // macOS removes the persisted charge limit while the native
            // override runs, so the cancel target is an explicit setting
            // rather than a guess. The link fills it in from the system
            // once; afterwards it stays a plain editable value.
            SettingsRow(
                "arrow.uturn.backward.circle",
                tint: .green,
                title: localization.string(.settingsBatteryRestoreLimit),
                subtitle: localization.string(
                    .settingsBatteryRestoreLimitDescription
                ),
                subtitleLink: Text(
                    localization.string(
                        .settingsBatteryFullThresholdUseChargeLimit
                    )
                )
                .foregroundColor(Color.accentColor),
                subtitleLinkAction: {
                    store.applySystemChargeToFullRestoreLimit()
                },
                trailing: {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { store.chargeToFullRestoreLimit },
                                set: {
                                    store.chargeToFullRestoreLimit =
                                        $0.rounded()
                                }
                            ),
                            in: SettingsStore.chargeToFullRestoreLimitRange,
                            step: 5
                        )
                        .controlSize(.small)
                        .frame(width: 90)
                        .accessibilityLabel(
                            localization.string(.settingsBatteryRestoreLimit)
                        )
                        .accessibilityValue(
                            "\(Int(store.chargeToFullRestoreLimit))%"
                        )

                        Text("\(Int(store.chargeToFullRestoreLimit))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            )
        }
    }


    @ViewBuilder
    private var systemChargeLimitUnavailableNote: some View {
        if !store.canReadSystemChargeLimit {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.secondary)
                Text(localization.string(
                    .settingsBatteryFullThresholdSystemUnavailable
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.bottom, 6)
        }
    }

    /// Sailing Mode: the interval charge-limit controller and its two bounds.
    private var sailingModeGroup: some View {
        SettingsGroup(
            localization.string(.settingsBatterySailingGroup),
            footnote: localization.string(.settingsBatterySailingFootnote)
        ) {
            VStack(alignment: .leading, spacing: 6) {
                SettingsToggleRow(
                    symbol: "sailboat",
                    tint: .blue,
                    title: localization.string(.settingsBatterySailingEnable),
                    subtitle: localization.string(
                        .settingsBatterySailingEnableDescription
                    ),
                    subtitleStatus: sailingStatus,
                    isOn: Binding(
                        get: { store.isSailingModeEnabled },
                        set: { store.isSailingModeEnabled = $0 }
                    )
                )
                .disabled(!sailingFeatureAvailable)

                if !sailingFeatureAvailable {
                    SettingsHintRow(
                        text: localization.string(
                            helper.isAvailable
                                ? .settingsBatterySailingHelperRequired
                                : .settingsBatterySailingHelperUnavailable
                        )
                    )
                } else if !helper.isReady {
                    SettingsHintRow(
                        text: localization.string(.settingsBatterySailingHelperRequired)
                    )
                }

                if sailingMode != nil, !helper.isReady {
                    Button {
                        helper.openLoginItemsSettings()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: helper.requiresApproval
                                ? "exclamationmark.triangle.fill"
                                : "arrow.up.forward.app")
                                .foregroundStyle(
                                    helper.requiresApproval ? Color.orange : Color.accentColor
                                )
                            Text(localization.string(.settingsBatterySailingOpenLoginItems))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        localization.string(.settingsBatterySailingOpenLoginItems)
                    )
                    .padding(.horizontal, SettingsMetrics.rowPaddingH)
                    .padding(.bottom, 6)
                }

                if store.isSailingModeEnabled, sailingFeatureAvailable {
                    SettingsDivider()
                    SettingsRow(
                        "battery.75percent",
                        tint: .blue,
                        title: localization.string(.settingsBatterySailingChargeLimit),
                        subtitle: localization.string(
                            .settingsBatterySailingChargeLimitDescription
                        )
                    ) {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { store.sailingChargeLimit },
                                    set: {
                                        store.sailingChargeLimit = $0.rounded()
                                    }
                                ),
                                in: SettingsStore.sailingChargeLimitRange,
                                step: 5
                            )
                            .frame(width: 120)
                            .controlSize(.small)
                            .accessibilityLabel(
                                localization.string(.settingsBatterySailingChargeLimit)
                            )
                            .accessibilityValue(
                                "\(Int(store.sailingChargeLimit))%"
                            )

                            Text("\(Int(store.sailingChargeLimit))%")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    SettingsDivider()
                    SettingsRow(
                        SymbolFallback.name("water.waves", "drop.fill"),
                        tint: .blue,
                        title: localization.string(.settingsBatterySailingLevel),
                        subtitle: localization.string(
                            .settingsBatterySailingLevelDescription
                        )
                    ) {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { store.sailingLevel },
                                    set: {
                                        store.sailingLevel = $0.rounded()
                                    }
                                ),
                                in: SettingsStore.sailingLevelRange,
                                step: 1
                            )
                            .frame(width: 120)
                            .controlSize(.small)
                            .accessibilityLabel(
                                localization.string(.settingsBatterySailingLevel)
                            )
                            .accessibilityValue(
                                "\(Int(store.sailingLevel))%"
                            )

                            Text("\(Int(store.sailingLevel))%")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    SettingsDivider()
                    HStack(spacing: 6) {
                        Image(systemName: SymbolFallback.name("sailboat.fill", "sailboat"))
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                        Text(localization.format(
                            .settingsBatterySailingWillSailTo,
                            max(
                                20,
                                Int(store.sailingChargeLimit)
                                    - Int(store.sailingLevel)
                            )
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SettingsMetrics.rowPaddingH)
                    .padding(.vertical, 8)

                    if let chargeToFullNow, chargeToFullNow.isSettingAvailable {
                        SettingsDivider()
                        SailingChargeToFullActionView(
                            controller: chargeToFullNow,
                            battery: statusStore.snapshot.battery,
                            isSailingEnabled: store.isSailingModeEnabled
                        )
                        .padding(.horizontal, SettingsMetrics.rowPaddingH)
                        .padding(.vertical, 6)
                    }
                }

                if store.isSailingModeEnabled,
                   helper.isReady,
                   sailingMode?.phase == .failed,
                   let error = sailingMode?.lastError,
                   !error.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(localization.format(
                            .settingsBatterySailingStateFailed,
                            error
                        ))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, SettingsMetrics.rowPaddingH)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var sailingFeatureAvailable: Bool {
        sailingMode != nil && helper.isAvailable
    }

    private var sailingStatus: Text? {
        guard let phase = sailingMode?.phase else { return nil }
        let value: String
        switch phase {
        case .disabled:
            return nil
        case .unavailable:
            value = localization.string(.settingsBatterySailingUnavailable)
        case .waitingForPower:
            value = localization.string(.settingsBatterySailingStateWaitingForPower)
        case let .chargingToUpper(upper):
            value = localization.format(.settingsBatterySailingStateCharging, upper)
        case let .sailingDown(lower):
            value = localization.format(.settingsBatterySailingStateSailing, lower)
        case let .holding(lower, _):
            value = localization.format(.settingsBatterySailingWillSailTo, lower)
        case .lowBatteryOverride:
            value = localization.string(.settingsBatterySailingStateLowBattery)
        case .pausedForChargeToFull:
            value = localization.string(.settingsBatterySailingStatePaused)
        case .restoring:
            value = localization.string(.settingsBatterySailingStatePaused)
        case .failed:
            // The error row below the switch carries the actual message.
            return nil
        }
        return Text(value)
            .foregroundColor(.secondary)
    }

    /// The privileged power-mode control and the low-battery automation.
    private var powerModesGroup: some View {
        SettingsGroup(localization.string(.settingsBatteryGroupPowerModes)) {
            lowPowerModeGroup
        }
    }

    /// Power flow and energy rankings.
    private var powerFlowGroup: some View {
        SettingsGroup(localization.string(.settingsBatteryGroupPower)) {
            powerFlowContent
        }
    }

    @ViewBuilder
    private var powerFlowContent: some View {
        SettingsToggleRow(
            symbol: "chart.bar.fill",
            tint: .teal,
            title: localization.string(.settingsBatteryPowerInfoBar),
            subtitle: localization.string(.settingsBatteryPowerInfoBarDescription),
            isOn: $store.showsBatteryPowerInfoBar
        )

            SettingsDivider()

            SettingsToggleRow(symbol: "arrow.triangle.branch", tint: .orange,
                title: localization.string(.settingsBatteryPowerFlowDiagram),
                subtitle: localization.string(.settingsBatteryPowerFlowDiagramDescription),
                isOn: $store.showsBatteryPowerFlow)
            SettingsDivider()
            SettingsToggleRow(symbol: "app", tint: .purple,
                title: localization.string(.batteryHighEnergyApps),
                subtitle: localization.string(.batteryEnergyMonitoringDescription),
                isOn: $store.showsHighEnergyApps)
            if store.showsHighEnergyApps {
                SettingsDivider()
                SettingsRow(
                    "timer",
                    tint: .purple,
                    title: localization.string(.settingsBatteryEnergyRefreshInterval),
                    subtitle: localization.string(.settingsBatteryEnergyRefreshIntervalDescription)
                ) {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { store.highEnergyAppsRefreshIntervalSeconds },
                                set: { store.highEnergyAppsRefreshIntervalSeconds = ($0 / 5).rounded() * 5 }
                            ),
                            in: SettingsStore.highEnergyAppsRefreshIntervalRange
                        )
                        .frame(width: 130)
                        .controlSize(.small)
                        .accessibilityLabel(
                            localization.string(.settingsBatteryEnergyRefreshInterval)
                        )
                        .accessibilityValue(
                            localization.format(
                                .settingsRefreshIntervalValue,
                                Int(store.highEnergyAppsRefreshIntervalSeconds)
                            )
                        )

                        Text(
                            localization.format(
                                .settingsRefreshIntervalValue,
                                Int(store.highEnergyAppsRefreshIntervalSeconds)
                            )
                        )
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                    }
                }
            }
            SettingsDivider()
            Text(localization.string(.settingsBatteryPowerFlowDescription))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Give the trailing note its own row padding so it is never
                // clipped by the card's bottom edge.
                .padding(.horizontal, SettingsMetrics.rowPaddingH)
                .padding(.vertical, SettingsMetrics.rowPaddingV)
    }

    /// The feature opt-in registers the helper if needed. Turning it off stops
    /// helper contact but keeps registration and system approval intact.
    private var lowPowerModeGroup: some View {
        let needsApproval = helper.requiresApproval && !helper.isReady

        return VStack(alignment: .leading, spacing: 6) {
            SettingsToggleRow(
                symbol: "leaf.fill",
                tint: .green,
                title: localization.string(.lowPowerModeControl),
                subtitle: localization.string(.lowPowerModeControlDescription),
                // Reported on the description's own line: one short state, not
                // a block of rows under the switch.
                subtitleStatus: helper.isEnabled ? lowPowerModeHelperStatus : nil,
                isOn: helper.isEnabledBinding
            )
            .disabled(!helper.isAvailable)

            // Native approval and verified helper access can differ. Keep the
            // pane accessible; only warn when approval is pending and access
            // is unverified.
            if helper.isAvailable {
                Button {
                    helper.openLoginItemsSettings()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: needsApproval
                            ? "exclamationmark.triangle.fill"
                            : "info.circle")
                            .foregroundStyle(needsApproval ? Color.orange : Color.secondary)
                        Text(localization.string(
                            needsApproval
                                ? .lowPowerModeRequiresApproval
                                : (helper.isReady ? .lowPowerModeOpenLoginItems : .lowPowerModeApprovalHint)
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localization.string(.lowPowerModeOpenLoginItems))
                .padding(.horizontal, SettingsMetrics.rowPaddingH)
                .padding(.bottom, 6)
            }

            if helper.didFailLastOperation {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.string(.lowPowerModeFailure))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let message = helper.lastErrorMessage {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, SettingsMetrics.rowPaddingH)
                .padding(.bottom, 6)
            }

            // #246: the automation needs the helper-backed switch, so it stays
            // visible only while the helper can run, and disabled until the
            // user has turned the Low Power Mode control on.
            if helper.isAvailable, HighPowerModeController.supportsCurrentPlatform,
               statusStore.snapshot.battery.isPresent {
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "battery.25",
                    tint: .green,
                    title: localization.string(.lowPowerModeAutoEnable),
                    subtitle: localization.string(.lowPowerModeAutoEnableDescription),
                    isOn: $store.autoEnablesLowPowerMode
                )
                .disabled(!helper.isEnabled)

                // Its own threshold, separate from the critical colour level:
                // a 90% automation threshold must not paint the icon red at 90%.
                if store.autoEnablesLowPowerMode {
                    SettingsDivider()
                    SettingsRow(
                        "slider.horizontal.3",
                        tint: .green,
                        title: localization.string(.autoLowPowerThreshold),
                        subtitle: localization.string(.autoLowPowerThresholdDescription)
                    ) {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { store.autoLowPowerThreshold },
                                    set: { store.autoLowPowerThreshold = $0.rounded() }
                                ),
                                in: SettingsStore.autoLowPowerThresholdRange
                            )
                            .frame(width: 130)
                            .controlSize(.small)
                            .accessibilityLabel(
                                localization.string(.autoLowPowerThreshold)
                            )
                            .accessibilityValue("\(Int(store.autoLowPowerThreshold))%")

                            Text("\(Int(store.autoLowPowerThreshold))%")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }


    /// One state, carried by the description instead of a line of its own.
    ///
    /// The native approval value is deliberately not repeated here: it can stay
    /// "pending" on a system where the helper already answers, and the approval
    /// hint below the row already asks for the one thing the user can do about
    /// it.
    private var lowPowerModeHelperStatus: Text {
        Text(localization.string(
            helper.isReady ? .lowPowerModeHelperReady : .lowPowerModeHelperUnavailable
        ))
        .foregroundColor(helper.isReady ? Color.green : Color.secondary)
    }

}

