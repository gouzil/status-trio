import Combine
import XCTest
@testable import StatusTrioCore

@MainActor
final class MagSafeLEDControllerTests: XCTestCase {
    func testHoldingPhaseMirrorsGreenToTheHelper() async {
        let suite = "MagSafeLEDControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.isMagSafeLEDControlEnabled = true
        settings.isSailingModeEnabled = true

        let client = FakeMagSafeLEDClient()
        let controller = MagSafeLEDController(settings: settings, client: client)
        let battery = CurrentValueSubject<BatteryStatus, Never>(
            BatteryStatus(
                rawPercentage: 77,
                isPresent: true,
                isCharging: false,
                isLowPowerMode: false,
                isConnectedToPower: true
            )
        )
        let phase = CurrentValueSubject<SailingModePhase, Never>(.holding(70, 80))

        controller.start(
            battery: battery.eraseToAnyPublisher(),
            phase: phase.eraseToAnyPublisher()
        )
        await waitUntil { client.colors == [.green] }

        XCTAssertEqual(controller.lastError, nil)
        XCTAssertTrue(controller.isAvailable)
        await controller.stop()
    }

    func testReconnectForcesAFreshGreenWrite() async {
        let suite = "MagSafeLEDControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.isMagSafeLEDControlEnabled = true
        settings.isSailingModeEnabled = true

        let client = FakeMagSafeLEDClient()
        let controller = MagSafeLEDController(settings: settings, client: client)
        let connected = BatteryStatus(
            rawPercentage: 77,
            isPresent: true,
            isCharging: false,
            isLowPowerMode: false,
            isConnectedToPower: true
        )
        let disconnected = BatteryStatus(
            rawPercentage: 77,
            isPresent: true,
            isCharging: false,
            isLowPowerMode: false,
            isConnectedToPower: false
        )
        let battery = CurrentValueSubject<BatteryStatus, Never>(connected)
        let phase = CurrentValueSubject<SailingModePhase, Never>(.holding(70, 80))

        controller.start(
            battery: battery.eraseToAnyPublisher(),
            phase: phase.eraseToAnyPublisher()
        )
        await waitUntil { client.colors == [.green] }

        battery.send(disconnected)
        await waitUntil { client.colors.contains(.system) }

        battery.send(connected)
        await waitUntil { client.colors.last == .green }
        XCTAssertTrue(client.colors.contains(.system))
        await controller.stop()
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for MagSafe LED state")
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

private final class FakeMagSafeLEDClient: MagSafeLEDClienting, @unchecked Sendable {
    var colors: [MagSafeLEDColor] = []

    func magSafeCapability() async throws -> Bool { true }
    func magSafeState() async throws -> Int { 6 }
    func setMagSafeColor(_ color: MagSafeLEDColor) async throws -> Bool {
        colors.append(color)
        return true
    }
    func restoreMagSafeColor() async throws -> Bool {
        colors.append(.system)
        return true
    }
}
