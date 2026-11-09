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

        Publishers.CombineLatest3(
            settings.$isMagSafeLEDControlEnabled.removeDuplicates(),
            battery.removeDuplicates(),
            phase.removeDuplicates()
        )
        .sink { [weak self] _, battery, phase in
            self?.lastBattery = battery
            self?.lastPhase = phase
            self?.evaluate()
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
