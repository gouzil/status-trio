import Darwin
import Foundation
import ObjectiveC

/// Production transport for the macOS native Charge Limit path.
///
/// This is the only type in the helper that touches root preferences, the
/// Darwin notification center, or the private PowerUI framework. It stays
/// small and stateless; `NativeChargeLimitController` owns the sequencing.
struct SystemNativeChargeLimitTransport: NativeChargeLimitTransport {
    /// Reads a value from PowerUIAgent's domain. `kCFPreferencesCurrentUser`
    /// resolves to root's home because the daemon runs as root, which is where
    /// the agent reads its settings.
    func readPreference(_ key: String) -> Int? {
        let value = CFPreferencesCopyValue(
            key as CFString,
            NativeChargeLimit.preferencesDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return (value as? NSNumber)?.intValue
    }

    /// Writes values to PowerUIAgent's domain and flushes them to disk.
    func writePreferences(_ values: [String: Int]) -> Bool {
        for (key, value) in values {
            CFPreferencesSetValue(
                key as CFString,
                NSNumber(value: value),
                NativeChargeLimit.preferencesDomain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        return CFPreferencesSynchronize(
            NativeChargeLimit.preferencesDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    /// Posts the Darwin notification PowerUIAgent observes to reload its
    /// preferences. `notify_post` has no Swift module of its own, so the symbol
    /// is resolved at runtime like the PowerUI selectors.
    func postReload() -> Bool {
        typealias NotifyPost = @convention(c) (UnsafePointer<CChar>) -> UInt32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "notify_post") else {
            return false
        }
        return unsafeBitCast(symbol, to: NotifyPost.self)(NativeChargeLimit.reloadNotification) == 0
    }

    /// Asks PowerUIAgent to clear the registered charge limit through its own
    /// client interface.
    ///
    /// The agent ignores a disable request while it believes the feature is
    /// off, so a stale registration left by an earlier preference write is
    /// cleared by enabling the feature first. This mirrors the reference
    /// implementation's release path; it does not write any SMC key.
    func disableMCL() -> Bool {
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        typealias BoolErrFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>) -> Bool
        typealias U64ErrFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>) -> UInt64

        guard let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend"),
              let cls = NativeChargeLimit.clientClass()
        else { return false }

        let instance = unsafeBitCast(msgSend, to: AllocFn.self)(
            cls,
            sel_registerName("alloc")
        ).takeUnretainedValue()
        guard let client = unsafeBitCast(msgSend, to: InitFn.self)(
            instance,
            sel_registerName("initWithClientName:"),
            "StatusTrioPowerHelper" as NSString
        )?.takeUnretainedValue()
        else { return false }

        var error: Unmanaged<NSError>?
        return withUnsafeMutablePointer(to: &error) { errorPointer -> Bool in
            let enabled = unsafeBitCast(msgSend, to: U64ErrFn.self)(
                client,
                sel_registerName("isMCLCurrentlyEnabled:"),
                errorPointer
            )
            if enabled == 0 {
                errorPointer.pointee = nil
                _ = unsafeBitCast(msgSend, to: BoolErrFn.self)(
                    client,
                    sel_registerName("enableMCL:"),
                    errorPointer
                )
            }
            errorPointer.pointee = nil
            return unsafeBitCast(msgSend, to: BoolErrFn.self)(
                client,
                sel_registerName("disableMCL:"),
                errorPointer
            )
        }
    }

    /// Whether this Mac has the PowerUI charge-limit client and a working
    /// `pmset -g battlimit`. Both belong to macOS's own Charge Limit feature;
    /// the probe never depends on a macOS version number.
    func isAvailable() -> Bool {
        guard NativeChargeLimit.clientClass() != nil else { return false }
        return Self.pmsetCanReadBattlimit()
    }

    private static func pmsetCanReadBattlimit() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "battlimit"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
