import SwiftUI

/// Settings row for the optional fixed-key MagSafe LED mirror.
struct MagSafeLEDSettingsGroup: View {
    @ObservedObject var controller: MagSafeLEDController
    @ObservedObject var settings: SettingsStore
    @EnvironmentObject private var localization: Localization

    var body: some View {
        SettingsGroup(localization.string(.settingsBatteryGroupMagSafeLED)) {
            SettingsToggleRow(
                symbol: "lightbulb.led.fill",
                tint: .green,
                title: localization.string(.settingsBatteryMagSafeLEDControl),
                subtitle: localization.string(.settingsBatteryMagSafeLEDDescription),
                isOn: $settings.isMagSafeLEDControlEnabled
            )
            .disabled(!controller.isAvailable)

            if !controller.isAvailable {
                SettingsHintRow(
                    text: localization.string(.settingsBatteryMagSafeLEDUnavailable)
                )
            } else if settings.isMagSafeLEDControlEnabled,
                      let error = controller.lastError,
                      !error.isEmpty {
                SettingsHintRow(
                    text: localization.format(
                        .settingsBatteryMagSafeLEDError,
                        error
                    )
                )
            }
        }
    }
}
