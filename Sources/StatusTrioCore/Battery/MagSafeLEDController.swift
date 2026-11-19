import AppKit
import Combine
import Foundation

/// Mirrors the charge state onto the fixed MagSafe LED key when the user
/// enables the optional control. The controller owns only transitions; the
/// policy and the privileged helper keep the hardware-specific values out of
/// the view layer.
@MainActor
final class MagSafeLEDController: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var lastError: String?

    private let settings: SettingsStore
    private let client: any MagSafeLEDClienting
    private var cancellables: Set<AnyCancellable> = []
    private var probeTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var lastBattery: BatteryStatus?
    private var lastPhase: SailingModePhase?
    private var lastApplied: MagSafeLEDColor?
    private var powerTransitionTask: Task<Void, Never>?
    private var wakeObservers: [NSObjectProtocol] = []
    private var activity: NSObjectProtocol?
    private var isStopped = false

    init(settings: SettingsStore, client: any MagSafeLEDClienting) {
        self.settings = settings
        self.client = client
    }

    func start(
        battery: AnyPublisher<BatteryStatus, Never>,
        phase: AnyPublisher<SailingModePhase, Never>
    ) {
        guard cancellables.isEmpty else { return }
        probeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let available = try await client.magSafeCapability()
                guard !isStopped else { return }
                isAvailable = available
                if available {
                    evaluate()
                } else {
                    lastError = "This Mac does not expose the MagSafe LED key."
                }
            } catch {
                guard !isStopped else { return }
                lastError = error.localizedDescription
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        wakeObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.forceReapplyAfterWake() }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.forceReapplyAfterWake() }
            },
        ]

        Publishers.CombineLatest3(
            settings.$isMagSafeLEDControlEnabled.removeDuplicates(),
            battery.removeDuplicates(),
            phase.removeDuplicates()
        )
        .sink { [weak self] enabled, battery, phase in
            guard let self else { return }
            self.updateActivity(enabled: enabled)
            let previousConnection = self.lastBattery?.isConnectedToPower
            self.lastBattery = battery
            self.lastPhase = phase

            // macOS resets the MagSafe LED state when the cable is removed or
            // reattached. Drop our cached value so the new power state gets a
            // fresh write, and give the firmware one delayed re-apply after
            // reconnect to cover its own LED initialization.
            if let previousConnection,
               previousConnection != battery.isConnectedToPower {
                self.lastApplied = nil
                if battery.isConnectedToPower {
                    self.scheduleReapplyAfterPowerTransition()
                }
            }
            self.evaluate()
        }
        .store(in: &cancellables)
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        cancellables.removeAll()
        probeTask?.cancel()
        probeTask = nil
        applyTask?.cancel()
        applyTask = nil
        powerTransitionTask?.cancel()
        powerTransitionTask = nil
        for observer in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        wakeObservers.removeAll()
        endActivity()

        guard lastApplied != nil else { return }
        _ = try? await client.restoreMagSafeColor()
        lastApplied = nil
    }

    private func evaluate() {
        guard !isStopped, isAvailable, let battery = lastBattery else { return }
        let desired = MagSafeLEDPolicy.desiredColor(
            isControlEnabled: settings.isMagSafeLEDControlEnabled,
            battery: battery,
            sailingEnabled: settings.isSailingModeEnabled,
            phase: lastPhase
        )
        guard desired != lastApplied else { return }
        // Do not write "system" merely because the feature starts disabled;
        // there is nothing of ours to clear in that case.
        guard settings.isMagSafeLEDControlEnabled || lastApplied != nil else { return }
        apply(desired)
    }

    private func updateActivity(enabled: Bool) {
        if enabled, activity == nil {
            // Keep the LED policy responsive while the display is asleep or the
            // lid is closed but the Mac itself remains awake. This does not
            // prevent system sleep; a sleeping Mac cannot be driven by a
            // user-space app.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "Maintain MagSafe LED state while the display is asleep"
            )
        } else if !enabled {
            endActivity()
        }
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    private func forceReapplyAfterWake() {
        guard !isStopped, settings.isMagSafeLEDControlEnabled else { return }
        lastApplied = nil
        evaluate()
    }

    private func scheduleReapplyAfterPowerTransition() {
        powerTransitionTask?.cancel()
        powerTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, !isStopped else { return }
            // Force a fresh write even when the desired color is unchanged:
            // the charger may have reset ACLC back to its own value.
            lastApplied = nil
            evaluate()
        }
    }

    private func apply(_ desired: MagSafeLEDColor) {
        guard !isStopped, applyTask == nil else { return }
        applyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.applyTask = nil }
            do {
                if desired == .system {
                    _ = try await client.restoreMagSafeColor()
                } else {
                    _ = try await client.setMagSafeColor(desired)
                }
                guard !isStopped else { return }
                lastApplied = desired
                lastError = nil
                evaluate()
            } catch {
                guard !isStopped else { return }
                lastError = error.localizedDescription
            }
        }
    }
}
