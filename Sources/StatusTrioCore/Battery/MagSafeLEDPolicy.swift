import Foundation

/// The fixed colors available through the privileged `ACLC` key.
enum MagSafeLEDColor: Int, CaseIterable, Sendable {
    case system = 0
    case off = 1
    case green = 6
    case amber = 4
}

/// Pure decision policy for the optional MagSafe LED mirror.
///
/// AlDente's behavior is the reference: green means the charge limit is
/// reached (including a Sailing Mode pause), amber means the Mac is charging
/// or discharging toward the limit, and the system owns the LED otherwise.
enum MagSafeLEDPolicy {
    static func desiredColor(
        isControlEnabled: Bool,
        battery: BatteryStatus,
        sailingEnabled: Bool,
        phase: SailingModePhase?
    ) -> MagSafeLEDColor {
        guard isControlEnabled, battery.isPresent, battery.isConnectedToPower else {
            return .system
        }
        if battery.isCharged {
            return .green
        }

        if sailingEnabled, let phase {
            switch phase {
            case .holding, .sailingDown:
                return .green
            case .chargingToUpper, .lowBatteryOverride, .pausedForChargeToFull:
                return .amber
            case .disabled, .unavailable, .waitingForPower, .restoring, .failed:
                return .system
            }
        }

        return battery.isCharging ? .amber : .system
    }
}
