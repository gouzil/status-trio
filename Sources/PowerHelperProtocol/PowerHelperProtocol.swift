import Foundation

/// The Mach service the privileged power helper listens on. Kept in a
/// dependency-free target so both the app and the daemon can name it without
/// pulling AppKit, SwiftUI, or Sparkle into the root daemon.
public enum PowerHelperConstants {
    /// Must match `MachServices` in the LaunchDaemon property list and the
    /// `SMAppService.daemon(plistName:)` registration in the app.
    public static let machServiceName = "com.lingsmbp.StatusTrio.PowerHelper"
    /// The LaunchDaemon property list's file name, relative to
    /// `Contents/Library/LaunchDaemons/`.
    public static let launchDaemonPlistName = "com.lingsmbp.StatusTrio.PowerHelper.plist"
    /// The app bundle identifier and signing team the daemon authorizes.
    ///
    /// Defined once here rather than in the requirement string and again in the
    /// daemon's authorization code: the requirement the daemon enforces and the
    /// identity the app checks itself against must never drift apart.
    public static let clientBundleIdentifier = "com.lingsmbp.StatusTrio"
    public static let clientTeamIdentifier = "HCB7JKMQ2F"

    /// The daemon's signing requirement, used by the daemon to authorize a
    /// connecting client and by the app to describe the helper it expects.
    public static let clientRequirement = clientRequirementString()

    /// Builds the same requirement for an injected identity.
    ///
    /// `build-app.sh`/`build-worktree.sh` can change the bundle identifier, so
    /// the pieces are named values a caller can compare against instead of
    /// parsing them back out of the requirement string.
    public static func clientRequirementString(
        bundleIdentifier: String = clientBundleIdentifier,
        teamIdentifier: String = clientTeamIdentifier
    ) -> String {
        "anchor apple generic and identifier \"\(bundleIdentifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

/// The version of the XPC surface the daemon implements.
///
/// Bumped whenever the protocol gains a method the app may call. The app reads
/// this before using a newer method: a daemon built before the bump cannot
/// answer `readProtocolVersion` at all, which the app surfaces as "the helper
/// needs updating" instead of a silent failure.
public enum PowerHelperProtocolVersion {
    /// `readLowPowerMode` and `setLowPowerMode`.
    public static let lowPowerMode = 1
    /// Adds `readProtocolVersion` plus the High Power Mode capability probe,
    /// read and write (issue #235).
    public static let highPowerMode = 2
    /// readDisableSleep / setDisableSleep (issue #295).
    public static let disableSleep = 3
    /// Adds the Sailing Mode manual charge-limit capability probe, read, apply
    /// and restore. These methods drive macOS's own charge-limit preferences
    /// through the privileged helper; they never expose arbitrary SMC writes.
    public static let sailingMode = 4

    /// Adds the fixed-key MagSafe LED status and control methods. The daemon
    /// only writes the ACPI/SMC `ACLC` key with system/off/green/amber values;
    /// it does not expose arbitrary SMC writes.
    public static let magSafeLED = 5

    /// What the daemon in this build implements.
    public static let current = magSafeLED
}

/// Cross-process timing contract for helper commands (#383).
///
/// The app must wait longer than the daemon can take for one `pmset` child,
/// otherwise the app times out first, retries, and runs a second `pmset`
/// while the first is still alive — and reports a transport failure (`DS-H1`)
/// instead of the daemon's precise diagnostic code.
///
/// Daemon worst case for a single command is
/// `pmsetProcessTimeout` (a hung child) plus the two bounded pipe drains (1s
/// each when a descendant holds the pipe), so `clientRequestTimeout` is set
/// above that sum with margin.
public enum PowerHelperTiming {
    /// How long the daemon lets one `pmset` child run before killing it.
    public static let pmsetProcessTimeout: TimeInterval = 3
    /// How long the app waits for one helper reply. Must exceed the daemon's
    /// worst case (3s process + 2×1s drain = 5s) with margin.
    public static let clientRequestTimeout: TimeInterval = 6
}

/// The XPC surface the privileged helper exposes.
///
/// Deliberately small: one boolean read and one boolean write for Low Power
/// Mode, and the same shape for High Power Mode. Every operation is a separate
/// call so a failed write cannot be mistaken for a successful read, and the
/// reply carries the state the daemon observed *after* the change rather than
/// echoing the request.
@objc public protocol PowerHelperXPCProtocol {
    /// Reads the current Low Power Mode state.
    ///
    /// `enabled` is the observed value; `errorDescription` is non-nil only when
    /// the state could not be read, in which case `enabled` is meaningless.
    func readLowPowerMode(withReply reply: @escaping (Bool, String?) -> Void)

    /// Sets Low Power Mode and replies with the state the daemon observed
    /// afterwards, so the caller never has to guess whether the write took.
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)

    /// Replies with `PowerHelperProtocolVersion.current` for this daemon.
    ///
    /// A daemon built before this method existed invalidates the connection for
    /// this selector, which is exactly how the app detects an outdated helper.
    /// Added in protocol version 2.
    func readProtocolVersion(withReply reply: @escaping (Int, String?) -> Void)

    /// Whether this Mac reports High Power Mode support (`pmset -g cap`).
    ///
    /// Added in protocol version 2. The app hides the High Power Mode control
    /// when this is false or unknown, so an unsupported Mac never shows a switch
    /// that can only fail.
    func readHighPowerModeSupport(withReply reply: @escaping (Bool, String?) -> Void)

    /// Reads the current High Power Mode state.
    ///
    /// Added in protocol version 2. `enabled` is the observed value;
    /// `errorDescription` is non-nil only when it could not be read.
    func readHighPowerMode(withReply reply: @escaping (Bool, String?) -> Void)

    /// Sets High Power Mode and replies with the state the daemon observed
    /// afterwards. Enabling High Power Mode clears Low Power Mode first, because
    /// the two are mutually exclusive states of one system switch.
    ///
    /// Added in protocol version 2.
    func setHighPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)

    /// Reads whether the lid-close sleep is disabled (`pmset -g` `SleepDisabled`).
    ///
    /// Added in protocol version 3. `enabled` is the observed value;
    /// `errorDescription` is non-nil only when the state could not be read, in
    /// which case `enabled` is meaningless.
    func readDisableSleep(withReply reply: @escaping (Bool, String?) -> Void)

    /// Sets `pmset -a disablesleep` and replies with the state the daemon
    /// observed afterwards, so the caller never has to guess whether the write
    /// took.
    ///
    /// Added in protocol version 3.
    func setDisableSleep(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
    /// Whether this Mac can enforce a manual charge limit through PowerUI.
    ///
    /// Added in protocol version 4. The daemon checks for the private
    /// `PowerUISmartChargeClient` class and the `pmset -g battlimit` tool; both
    /// belong to macOS's own Charge Limit feature (macOS 26.4 or later).
    func readSailingChargeLimitCapability(withReply reply: @escaping (Bool, String?) -> Void)

    /// The charge limit currently applied for Sailing Mode.
    ///
    /// Added in protocol version 4. `percent` is `1...100`, or `-1` when
    /// Sailing Mode has not applied a limit in this session. This reads the
    /// same preference the system's Charge Limit UI uses.
    func readSailingChargeLimit(withReply reply: @escaping (Int, String?) -> Void)

    /// Applies `percent` as the system's manual charge limit for Sailing Mode.
    ///
    /// Added in protocol version 4. The daemon captures the user's original
    /// Charge Limit setting the first time this is called; the value is
    /// restored by `restoreSailingChargeLimit`. `percent` must be `1...100`.
    func applySailingChargeLimit(
        _ percent: Int,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// Restores the Charge Limit setting that was active before Sailing Mode.
    ///
    /// Added in protocol version 4. Idempotent: when no saved setting exists,
    /// the call succeeds without writing anything.
    func restoreSailingChargeLimit(withReply reply: @escaping (Bool, String?) -> Void)

    /// Whether this Mac exposes the fixed `ACLC` MagSafe LED key.
    ///
    /// Added in protocol version 5. The daemon checks the SMC key metadata;
    /// it does not enumerate or write arbitrary SMC keys.
    func readMagSafeLEDCapability(withReply reply: @escaping (Bool, String?) -> Void)

    /// The current `ACLC` byte, or `-1` when the key cannot be read.
    ///
    /// Added in protocol version 5. Values follow the fixed set
    /// `0 = system`, `1 = off`, `3 = green`, `4 = amber`.
    func readMagSafeLEDState(withReply reply: @escaping (Int, String?) -> Void)

    /// Sets the fixed `ACLC` LED state. Only `3` (green) and `4` (amber) are
    /// accepted by the daemon; `restoreMagSafeLED` hands control back to macOS.
    ///
    /// Added in protocol version 5.
    func setMagSafeLED(_ value: Int, withReply reply: @escaping (Bool, String?) -> Void)

    /// Writes `ACLC = 0`, returning LED control to macOS.
    ///
    /// Added in protocol version 5. Idempotent.
    func restoreMagSafeLED(withReply reply: @escaping (Bool, String?) -> Void)
}
