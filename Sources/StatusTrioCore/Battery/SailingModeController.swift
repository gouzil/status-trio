import Combine
import Foundation

/// The state Sailing Mode publishes for the battery settings and status text.
enum SailingModePhase: Equatable, Sendable {
    /// Sailing Mode is switched off (or the controller has stopped).
    case disabled
    /// The battery or the helper capability is not available.
    case unavailable
    /// The Mac is running on battery; charging resumes when power returns.
    case waitingForPower
    /// The battery is at/below the lower bound and charges back to the upper.
    case chargingToUpper(Int)
    /// Legacy state kept for source compatibility. Sailing Mode never forces
    /// discharge; the current implementation holds the current percentage.
    case sailingDown(Int)
    /// The battery is inside the band and no write is pending.
    case holding(Int, Int)
    /// The battery is at or below 20%; sailing yields to normal charging.
    case lowBatteryOverride
    /// Charge to Full Now is using the system Charge Limit, so sailing paused.
    case pausedForChargeToFull
    /// The controller is restoring the user's original Charge Limit.
    case restoring
    /// The last helper command failed; the next update retries.
    case failed

    /// The lower bound carried by a holding or sailing phase.
    var lowerBound: Int? {
        switch self {
        case let .holding(lower, _): lower
        case let .sailingDown(lower): lower
        default: nil
        }
    }

    /// The upper limit carried by a holding or charging phase.
    var upperLimit: Int? {
        switch self {
        case let .holding(_, upper): upper
        case let .chargingToUpper(upper): upper
        default: nil
        }
    }
}

/// Keeps the battery inside a configurable interval using macOS's native manual
/// Charge Limit through the privileged helper.
///
/// The helper applies a real system charge limit. Inside the sailing band the
/// controller pauses at the current percentage instead of forcing a discharge;
/// the adapter powers the Mac and the battery stays essentially put. When the
/// battery reaches the lower bound the controller applies the upper limit
/// again, which resumes charging until the upper bound. No SMC writes and no
/// forced-discharge command are involved.
///
/// `ChargeToFullNowController` drives the same system Charge Limit through
/// PowerUI. While it is applying, charging to full, or cancelling, sailing
/// restores its own limit and pauses so the two controllers never fight.
@MainActor
final class SailingModeController: ObservableObject {
    @Published private(set) var phase: SailingModePhase = .disabled
    @Published private(set) var lastError: String?

    /// The settings-derived interval.
    var currentUpperLimit: Int { upperLimitValue }
    var currentLowerBound: Int {
        max(20, upperLimitValue - sailingLevelValue)
    }

    private let settings: SettingsStore
    private let client: any SailingChargeLimitClienting
    private let now: () -> Date
    private let minimumCommandInterval: TimeInterval

    private var cancellables: Set<AnyCancellable> = []
    private var helperReadinessCancellable: AnyCancellable?
    private var capabilityTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

    private var isStarted = false
    private var isStopped = false
    private var isCapabilityAvailable = false
    /// Test seam: true once the startup capability probe has answered.
    private(set) var hasProbedCapability = false

    /// True while the persistent helper connection from the capability probe
    /// or `startSession()` is open. It may exist before a sailing session is
    /// active because `readCapability()` uses the same connection.
    private var isHelperConnectionOpen = false

    /// Cached copies of the settings values. `@Published` emits in `willSet`,
    /// so the sink closures must use the value the publisher delivered rather
    /// than reading the still-stale settings property back.
    private var isSailingModeEnabled: Bool
    private var upperLimitValue: Int
    private var sailingLevelValue: Int

    private var lastBattery: BatteryStatus?
    private var lastChargeToFullActive = false
    private var isChargingToUpper = false
    private var lastAppliedLimit: Int?
    private var lastCommandAt: Date?
    private var lastCommandDirection: CommandDirection?
    private var isCommanding = false

    private enum SessionState {
        case idle
        case starting
        case active
    }

    private var sessionState: SessionState = .idle

    private enum CommandDirection: Equatable {
        case charge
        case discharge
        case restore
    }

    private enum SailingCommand {
        case apply(Int)
        case restore
    }

    init(
        settings: SettingsStore,
        client: any SailingChargeLimitClienting,
        now: @escaping () -> Date = Date.init,
        minimumCommandInterval: TimeInterval = 5
    ) {
        self.settings = settings
        self.client = client
        self.now = now
        self.minimumCommandInterval = minimumCommandInterval
        self.isSailingModeEnabled = settings.isSailingModeEnabled
        self.upperLimitValue = Self.clampedUpperLimit(settings.sailingChargeLimit)
        self.sailingLevelValue = Self.clampedSailingLevel(settings.sailingLevel)
    }

    deinit {
        // `AnyCancellable` cancels itself when released, and it is not
        // `Sendable`, so it cannot be reached from this nonisolated deinit.
        // `stop()` cancels the readiness subscription explicitly.
        capabilityTask?.cancel()
        sessionTask?.cancel()
        commandTask?.cancel()
    }

    /// Reads the helper capability and starts listening for settings changes.
    func start() {
        guard !isStarted, !isStopped else { return }
        isStarted = true
        isSailingModeEnabled = settings.isSailingModeEnabled
        upperLimitValue = Self.clampedUpperLimit(settings.sailingChargeLimit)
        sailingLevelValue = Self.clampedSailingLevel(settings.sailingLevel)
        // Keep the shared LaunchDaemon alive while Sailing Mode is wanted,
        // including while an administrator approval is still pending.
        PrivilegedHelperManager.shared.setSailingModeDemand(isSailingModeEnabled)
        subscribeToSettings()
        subscribeToHelperReadiness()
        probeCapability()
    }

    /// Main entry point from the status store. It only caches the snapshot and
    /// evaluates the state machine; helper writes are issued from a `Task`.
    func update(battery: BatteryStatus, chargeToFullActive: Bool) {
        guard !isStopped else { return }
        lastBattery = battery
        lastChargeToFullActive = chargeToFullActive
        evaluate()
    }

    /// Re-evaluates after a settings change. The sink closures update the
    /// cached values first, then call this.
    func applySettings() {
        guard !isStopped else { return }
        evaluate()
    }

    /// Stops sailing for app termination: restore the original Charge Limit,
    /// then close the persistent helper connection.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        isStarted = false
        capabilityTask?.cancel()
        capabilityTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        helperReadinessCancellable?.cancel()
        helperReadinessCancellable = nil
        cancellables.removeAll()

        // Let an in-flight apply/restore settle so its result cannot race the
        // final restore below.
        while isCommanding {
            try? await Task.sleep(for: .milliseconds(5))
        }

        if hasApplied {
            phase = .restoring
            do {
                try await client.restore()
                lastAppliedLimit = nil
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                lastAppliedLimit = nil
            }
        }

        if isHelperConnectionOpen {
            client.endSession()
            isHelperConnectionOpen = false
        }
        sessionState = .idle
        phase = .disabled
        PrivilegedHelperManager.shared.setSailingModeDemand(false)
    }

    // MARK: - Settings

    private func subscribeToSettings() {
        settings.$isSailingModeEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.isSailingModeEnabled = enabled
                PrivilegedHelperManager.shared.setSailingModeDemand(enabled)
                self.applySettings()
                if enabled, self.hasProbedCapability, !self.isCapabilityAvailable {
                    self.probeCapability()
                }
            }
            .store(in: &cancellables)

        settings.$sailingChargeLimit
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] limit in
                guard let self else { return }
                self.upperLimitValue = Self.clampedUpperLimit(limit)
                self.applySettings()
            }
            .store(in: &cancellables)

        settings.$sailingLevel
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] level in
                guard let self else { return }
                self.sailingLevelValue = Self.clampedSailingLevel(level)
                self.applySettings()
            }
            .store(in: &cancellables)
    }

    /// The helper can become usable after the app launches (the user approves
    /// it in System Settings). Re-probe when that readiness flips on so the
    /// sailing controls do not stay unavailable for the rest of the session.
    private func subscribeToHelperReadiness() {
        helperReadinessCancellable = PrivilegedHelperManager.shared.readinessPublisher
            .removeDuplicates()
            .sink { [weak self] ready in
                guard let self,
                      ready,
                      self.isSailingModeEnabled,
                      !self.isCapabilityAvailable else {
                    return
                }
                self.probeCapability()
            }
    }

    // MARK: - Capability probe

    private func probeCapability() {
        guard !isStopped, capabilityTask == nil else { return }
        hasProbedCapability = false
        capabilityTask = Task { [weak self] in
            guard let self else { return }
            defer { self.capabilityTask = nil }
            do {
                let available = try await self.client.readCapability()
                guard !Task.isCancelled, !self.isStopped else { return }
                // The capability read runs on the persistent connection too.
                self.isHelperConnectionOpen = true
                self.isCapabilityAvailable = available
                self.hasProbedCapability = true
                if available {
                    self.lastError = nil
                    if self.isSailingModeEnabled {
                        self.ensureSessionStarted()
                    } else {
                        self.phase = .disabled
                        self.endSessionIfOpen()
                    }
                } else {
                    self.phase = .unavailable
                    self.lastError = nil
                    self.endSessionIfOpen()
                }
            } catch {
                guard !Task.isCancelled, !self.isStopped else { return }
                self.isCapabilityAvailable = false
                self.hasProbedCapability = true
                // Kept for diagnostics; the settings view hides it while the
                // helper itself is not ready, so it cannot look like a stale
                // red error after disabling or approving.
                self.lastError = error.localizedDescription
                self.phase = .unavailable
            }
        }
    }

    // MARK: - State machine

    private var hasApplied: Bool {
        lastAppliedLimit != nil
    }

    private func evaluate() {
        guard !isStopped, !isCommanding else { return }

        if !isSailingModeEnabled {
            isChargingToUpper = false
            phase = .disabled
            lastError = nil
            // Charge to Full Now owns the MCL override. If the user disables
            // sailing while it is active, leave the override alone and defer
            // our restore until the override has ended.
            if lastChargeToFullActive { return }
            if hasApplied {
                perform(.restore)
            } else {
                endSessionIfOpen()
            }
            return
        }

        if lastChargeToFullActive {
            // Charge to Full Now disables MCL with its own temporary override;
            // restoring the Sailing limit here would cancel that override.
            // Keep our marker and persistent session intact, issue no further
            // sailing commands, and resume from the last target when the
            // override ends.
            isChargingToUpper = false
            phase = .pausedForChargeToFull
            return
        }

        guard isCapabilityAvailable else {
            // Before the startup probe answers, keep the last phase instead of
            // flashing "unavailable" for every snapshot that arrives first.
            guard hasProbedCapability else { return }
            isChargingToUpper = false
            phase = .unavailable
            endSessionIfOpen()
            return
        }

        // The first battery snapshot may not have arrived yet; do not treat
        // that as an absent battery or tear the session down.
        guard let battery = lastBattery else { return }

        // `BatteryStatus.percentage` substitutes 100 for an absent battery or
        // a missing raw reading, so both have to be checked before the value.
        guard battery.isPresent, battery.rawPercentage != nil else {
            phase = .unavailable
            return
        }

        guard sessionState == .active else {
            if sessionState == .idle {
                ensureSessionStarted()
            }
            return
        }

        let upper = upperLimitValue
        let lower = currentLowerBound
        let percent = battery.percentage

        if !battery.isConnectedToPower {
            // A replug is a fresh session. Reset any in-progress charge and
            // pause at the current percentage so plugging back in inside the
            // band does not resume charging.
            isChargingToUpper = false
            if lastAppliedLimit != percent {
                perform(.apply(percent))
            }
            phase = .waitingForPower
            return
        }

        if percent <= 20 {
            isChargingToUpper = true
            if lastAppliedLimit != upper {
                perform(.apply(upper))
            }
            phase = .lowBatteryOverride
            return
        }

        if isChargingToUpper {
            if percent >= upper {
                isChargingToUpper = false
                if lastAppliedLimit != percent {
                    perform(.apply(percent))
                }
                phase = .holding(lower, upper)
            } else {
                if lastAppliedLimit != upper {
                    perform(.apply(upper))
                }
                phase = .chargingToUpper(upper)
            }
            return
        }

        if percent <= lower {
            isChargingToUpper = true
            if lastAppliedLimit != upper {
                perform(.apply(upper))
            }
            phase = .chargingToUpper(upper)
            return
        }

        // Inside the band (and above it) stop charging at the current level.
        // Sailing Mode is not a forced-discharge feature: the adapter powers
        // the Mac and the battery should stay essentially put until it is used
        // unplugged and falls to the lower bound.
        if lastAppliedLimit != percent {
            perform(.apply(percent))
        }
        phase = .holding(lower, upper)
    }

    // MARK: - Helper session

    private func ensureSessionStarted() {
        guard !isStopped,
              isSailingModeEnabled,
              isCapabilityAvailable,
              sessionState == .idle else {
            return
        }
        sessionState = .starting
        sessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.startSession()
                guard !Task.isCancelled, !self.isStopped else { return }
                self.isHelperConnectionOpen = true
                self.sessionState = .active
                self.lastError = nil
                self.evaluate()
            } catch {
                guard !Task.isCancelled, !self.isStopped else { return }
                self.sessionState = .idle
                self.lastError = error.localizedDescription
                self.phase = .failed
            }
        }
    }

    private func endSessionIfOpen() {
        sessionTask?.cancel()
        sessionTask = nil
        sessionState = .idle
        guard isHelperConnectionOpen else { return }
        isHelperConnectionOpen = false
        client.endSession()
    }

    // MARK: - Commands

    private func perform(_ command: SailingCommand) {
        guard !isCommanding, sessionState == .active else { return }

        let direction = commandDirection(for: command)
        if let lastCommandAt,
           now().timeIntervalSince(lastCommandAt) < minimumCommandInterval,
           lastCommandDirection == direction {
            return
        }

        isCommanding = true
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch command {
                case let .apply(limit):
                    try await self.client.applyLimit(limit)
                    self.lastAppliedLimit = limit
                case .restore:
                    try await self.client.restore()
                    self.lastAppliedLimit = nil
                }
                guard !Task.isCancelled else { return }
                self.lastCommandAt = self.now()
                self.lastCommandDirection = direction
                self.lastError = nil
                self.isCommanding = false
                self.evaluate()
            } catch {
                guard !Task.isCancelled else { return }
                self.lastAppliedLimit = nil
                self.lastCommandAt = nil
                self.lastCommandDirection = nil
                self.lastError = error.localizedDescription
                self.phase = .failed
                self.isCommanding = false
            }
        }
    }

    private func commandDirection(for command: SailingCommand) -> CommandDirection {
        switch command {
        case .restore:
            return .restore
        case let .apply(limit):
            guard let lastAppliedLimit else { return .charge }
            return limit > lastAppliedLimit ? .charge : .discharge
        }
    }

    // MARK: - Clamping

    private static func clampedUpperLimit(_ value: Double) -> Int {
        guard value.isFinite else {
            return Int(SettingsStore.defaultSailingChargeLimit)
        }
        let range = SettingsStore.sailingChargeLimitRange
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        // Step 5, never above the range's upper bound.
        let stepped = (clamped / 5).rounded(.down) * 5
        return Int(min(range.upperBound, max(range.lowerBound, stepped)))
    }

    private static func clampedSailingLevel(_ value: Double) -> Int {
        guard value.isFinite else {
            return Int(SettingsStore.defaultSailingLevel)
        }
        let range = SettingsStore.sailingLevelRange
        return Int(min(range.upperBound, max(range.lowerBound, value.rounded())))
    }
}
