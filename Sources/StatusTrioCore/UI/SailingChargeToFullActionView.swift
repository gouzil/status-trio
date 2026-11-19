import SwiftUI

/// The Sailing Mode surface for the existing Charge to Full Now action.
///
/// The action is only offered while Sailing Mode is on and the Mac is on AC
/// power below full. Once the temporary override is active, the same row
/// becomes its cancel surface even if the adapter is unplugged, so the user
/// can always get the original Charge Limit back.
/// Pure boundary policy for the Sailing Mode charge-to-full row. Keeping it
/// separate from the view makes the "when is this allowed" rules testable
/// without a live Settings window.
enum SailingChargeToFullActionPolicy {
    static func shouldShow(
        isSailingEnabled: Bool,
        isSettingAvailable: Bool,
        battery: BatteryStatus,
        presentation: ChargeToFullNowPresentation
    ) -> Bool {
        guard isSailingEnabled, isSettingAvailable, battery.isPresent else {
            return false
        }

        // An in-flight override remains cancellable even if the adapter is
        // unplugged or the battery reaches full while it is active.
        switch presentation {
        case .applying,
             .chargingToFull,
             .cancelling,
             .cancelConfirmationRequired,
             .cancelPending,
             .cancelFailed,
             .cancelLimitChangedConfirmation:
            return true
        case .hidden, .available, .failed, .unavailable:
            break
        }

        return battery.isConnectedToPower
            && !battery.isCharged
            && battery.percentage < 100
    }
}

struct SailingChargeToFullActionView: View {
    @ObservedObject var controller: ChargeToFullNowController
    let battery: BatteryStatus
    let isSailingEnabled: Bool

    var body: some View {
        if showsAction {
            ChargeToFullNowActionView(
                presentation: controller.presentation,
                onAction: { perform() }
            )
            .onAppear { refreshDemand() }
            .onChange(of: battery) { _ in
                refreshDemand()
            }
        }
    }

    private var showsAction: Bool {
        SailingChargeToFullActionPolicy.shouldShow(
            isSailingEnabled: isSailingEnabled,
            isSettingAvailable: controller.isSettingAvailable,
            battery: battery,
            presentation: controller.presentation
        )
    }

    private func refreshDemand() {
        controller.update(
            ChargeToFullNowDemand(
                popoverVisible: true,
                batterySectionVisible: true,
                battery: battery
            )
        )
    }

    private func perform() {
        // `performPrimaryAction` reads the demand captured by `update`, so make
        // sure the settings surface has refreshed it first.
        refreshDemand()
        controller.performPrimaryAction()
    }
}
