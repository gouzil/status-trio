import Darwin
import Foundation
import ObjectiveC

/// Constants and marker codec for macOS's own Manual Charge Limit.
///
/// On firmware that no longer exposes the CHTE SMC key, macOS keeps the charge
/// limit in PowerUIAgent's preference domain: a feature switch plus a target
/// percentage. The helper writes those preferences as root and posts the
/// notification the agent observes; it never writes SMC keys.
enum NativeChargeLimit {
    /// PowerUIAgent's preference domain. A root process's
    /// `kCFPreferencesCurrentUser` writes land in root's home, i.e.
    /// `/var/root/Library/Preferences/<domain>.plist`.
    static let preferencesDomain = "com.apple.smartcharging.topoffprotection"
    /// 1 while the manual charge limit is on, 0 while off.
    static let featureStateKey = "MCLFeatureState"
    /// The target state of charge, in percent.
    static let limitValueKey = "mclLimitValue"
    /// Darwin notification PowerUIAgent observes to reload its preferences.
    static let reloadNotification = "com.apple.smartcharging.defaultschanged"

    /// The private framework and client class behind System Settings' Charge
    /// Limit, and the manual-charge-limit selectors the release path calls.
    static let clientFrameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"
    static let clientClassName = "PowerUISmartChargeClient"
    static let clientSelectors = ["isMCLCurrentlyEnabled:", "enableMCL:", "disableMCL:"]

    /// Root-owned marker holding the user's pre-override setting.
    static let stateDirectoryPath = "/Library/Application Support/StatusTrio"
    static let markerPath = "\(stateDirectoryPath)/saved-native-limit"

    /// `1...100` are the targets the agent accepts. 100 means "no limit".
    static func validLimit(_ percent: Int) -> Bool {
        (1...100).contains(percent)
    }

    /// The client class, when this macOS has the manual charge limit: the
    /// framework loads, the class exists, and its instances answer every
    /// selector in `clientSelectors`. Class inspection only: this opens no
    /// connection to the agent and changes nothing.
    static func clientClass() -> AnyClass? {
        guard dlopen(clientFrameworkPath, RTLD_NOW) != nil,
              let cls: AnyClass = NSClassFromString(clientClassName),
              clientSelectors.allSatisfy({ class_respondsToSelector(cls, NSSelectorFromString($0)) })
        else { return nil }
        return cls
    }

    /// Marker file format: `<state> <limit>`, with `-` for an absent key, for
    /// example `"0 100"` or `"- -"`.
    static func markerString(_ originals: NativeChargeLimitOriginals) -> String {
        let state = originals.featureState.map(String.init) ?? "-"
        let limit = originals.limit.map(String.init) ?? "-"
        return "\(state) \(limit)"
    }

    /// Parses a marker. Nil for anything but two tokens that are each an
    /// integer or `-`: a corrupt marker must never drive a restore that turns
    /// the user's limit on with a made-up value.
    static func parseMarker(_ raw: String) -> NativeChargeLimitOriginals? {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 2 else { return nil }
        func value(_ token: Substring) -> Int?? {
            if token == "-" { return .some(nil) }
            guard let number = Int(token) else { return nil }
            return .some(number)
        }
        guard let state = value(tokens[0]), let limit = value(tokens[1]) else { return nil }
        return NativeChargeLimitOriginals(featureState: state, limit: limit)
    }
}

/// The agent's pre-override values, captured before the first override so a
/// restore can put the user's own setting back. A key can be absent on a Mac
/// where the Charge Limit feature was never touched.
struct NativeChargeLimitOriginals: Equatable {
    var featureState: Int?
    var limit: Int?

    /// True when the user had a charge limit of their own switched on.
    var featureWasOn: Bool { featureState == 1 }
}

/// Errors the Sailing Mode charge-limit path reports to the app. Kept as
/// short English sentences: the app owns localization.
enum NativeChargeLimitError: LocalizedError, Equatable {
    case unavailable
    case invalidLimit
    case corruptMarker
    case markerWriteFailed
    case preferenceWriteFailed
    case reloadNotificationFailed
    case verificationFailed
    case disableMCLFailed
    case markerRemovalFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "The native charge limit is unavailable on this Mac."
        case .invalidLimit: "The charge limit must be between 1 and 100 percent."
        case .corruptMarker: "The saved charge limit is unreadable."
        case .markerWriteFailed: "The original charge limit could not be saved."
        case .preferenceWriteFailed: "The charge limit preference could not be written."
        case .reloadNotificationFailed: "The charge limit change could not be announced."
        case .verificationFailed: "The charge limit did not read back after the write."
        case .disableMCLFailed: "The system charge limit could not be released."
        case .markerRemovalFailed: "The saved charge limit could not be cleared."
        }
    }
}
