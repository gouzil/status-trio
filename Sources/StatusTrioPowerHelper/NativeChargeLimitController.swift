import Foundation

/// The privileged operations the charge-limit controller needs. Injected so
/// the daemon's decision logic can be exercised without root, PowerUI, or a
/// real preference domain.
protocol NativeChargeLimitTransport: Sendable {
    /// Reads an integer preference from PowerUIAgent's domain.
    func readPreference(_ key: String) -> Int?
    /// Writes preferences to PowerUIAgent's domain and synchronizes them to
    /// disk. Returns false if any value could not be persisted.
    func writePreferences(_ values: [String: Int]) -> Bool
    /// Posts the Darwin notification PowerUIAgent reloads its preferences on.
    func postReload() -> Bool
    /// Asks PowerUIAgent, through its own client, to clear the registered
    /// charge limit. Returns false if the agent refused or is unavailable.
    func disableMCL() -> Bool
    /// Whether this Mac has both the PowerUI charge-limit client and a
    /// working `pmset -g battlimit`.
    func isAvailable() -> Bool
}

/// Applies and restores the macOS native charge limit for Sailing Mode.
///
/// The controller is synchronous and serialized with an `NSLock`: the XPC
/// service hands each call to its own task, so concurrent app requests must
/// not interleave a marker write, a preference write, and a restore.
///
/// The first `apply(percent:)` saves the user's current setting to a marker.
/// Later applies override the limit without touching that marker, and
/// `restore()` uses it to put the user's setting back. The marker is consumed
/// only after every restore step succeeds, so a failed restore can be retried.
final class NativeChargeLimitController: @unchecked Sendable {
    private let transport: any NativeChargeLimitTransport
    private let markerPath: String
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        transport: any NativeChargeLimitTransport = SystemNativeChargeLimitTransport(),
        markerPath: String = NativeChargeLimit.markerPath,
        fileManager: FileManager = .default
    ) {
        self.transport = transport
        self.markerPath = markerPath
        self.fileManager = fileManager
    }

    /// Whether this Mac can enforce a manual charge limit through PowerUI.
    func capability() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return transport.isAvailable()
    }

    /// The limit currently applied by Sailing Mode, or `-1` when the system's
    /// manual charge limit is off (or has no target).
    func readAppliedLimit() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard transport.readPreference(NativeChargeLimit.featureStateKey) == 1,
              let limit = transport.readPreference(NativeChargeLimit.limitValueKey)
        else { return -1 }
        return limit
    }

    /// Applies `percent` as the system's manual charge limit.
    ///
    /// The first call saves the user's original switch and target; subsequent
    /// calls keep that marker so a later restore always returns to the setting
    /// the user had before Sailing Mode. The write is read back so a rejected
    /// preference write is reported as a failure instead of a silent no-op.
    func apply(percent: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard NativeChargeLimit.validLimit(percent) else {
            throw NativeChargeLimitError.invalidLimit
        }
        guard transport.isAvailable() else {
            throw NativeChargeLimitError.unavailable
        }

        if fileManager.fileExists(atPath: markerPath) {
            // Do not overwrite the originals on a second apply, but refuse to
            // engage while the existing marker is unreadable: restoring it
            // later would be impossible.
            _ = try readMarker()
        } else {
            let originals = NativeChargeLimitOriginals(
                featureState: transport.readPreference(NativeChargeLimit.featureStateKey),
                limit: transport.readPreference(NativeChargeLimit.limitValueKey)
            )
            try writeMarker(NativeChargeLimit.markerString(originals))
        }

        let values = [
            NativeChargeLimit.featureStateKey: 1,
            NativeChargeLimit.limitValueKey: percent,
        ]
        guard transport.writePreferences(values) else {
            throw NativeChargeLimitError.preferenceWriteFailed
        }
        guard transport.postReload() else {
            throw NativeChargeLimitError.reloadNotificationFailed
        }
        guard transport.readPreference(NativeChargeLimit.featureStateKey) == 1,
              transport.readPreference(NativeChargeLimit.limitValueKey) == percent
        else {
            throw NativeChargeLimitError.verificationFailed
        }
    }

    /// Restores the charge-limit setting that was active before Sailing Mode.
    ///
    /// Success with no marker is a no-op: nothing of ours is in force.
    /// `disableMCL:` is called first because a preference write that turns the
    /// feature off leaves the limit registered with powerd; the agent's own
    /// client interface is the only path that clears that registration.
    func restore() throws {
        lock.lock()
        defer { lock.unlock() }
        try restoreLocked()
    }

    /// A non-throwing restore used when the last XPC client disconnects and the
    /// daemon is about to idle-exit. Returns true when there was nothing to do
    /// or the restore completed; false when the saved setting is still in
    /// force, so a later connection can retry.
    func restoreIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: markerPath) else { return true }
        do {
            try restoreLocked()
            return true
        } catch {
            NSLog(
                "StatusTrioPowerHelper could not restore the saved charge limit: %@",
                error.localizedDescription
            )
            return false
        }
    }

    private func restoreLocked() throws {
        guard fileManager.fileExists(atPath: markerPath) else { return }
        let originals = try readMarker()

        guard transport.disableMCL() else {
            throw NativeChargeLimitError.disableMCLFailed
        }

        var values = [NativeChargeLimit.featureStateKey: originals.featureWasOn ? 1 : 0]
        if let limit = originals.limit {
            values[NativeChargeLimit.limitValueKey] = limit
        }
        guard transport.writePreferences(values) else {
            throw NativeChargeLimitError.preferenceWriteFailed
        }
        guard transport.postReload() else {
            throw NativeChargeLimitError.reloadNotificationFailed
        }

        do {
            try fileManager.removeItem(atPath: markerPath)
        } catch {
            throw NativeChargeLimitError.markerRemovalFailed
        }
    }

    // MARK: - Marker

    private func readMarker() throws -> NativeChargeLimitOriginals {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: markerPath)),
              let raw = String(data: data, encoding: .utf8),
              let originals = NativeChargeLimit.parseMarker(raw)
        else {
            throw NativeChargeLimitError.corruptMarker
        }
        return originals
    }

    private func writeMarker(_ text: String) throws {
        let directory = (markerPath as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            // `createDirectory` ignores the attributes when the directory
            // already exists, so set them explicitly as well.
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
            // Atomic write: the marker either contains the complete original
            // setting or is absent, never a half-written value.
            try text.write(toFile: markerPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: markerPath)
        } catch {
            throw NativeChargeLimitError.markerWriteFailed
        }
    }
}
