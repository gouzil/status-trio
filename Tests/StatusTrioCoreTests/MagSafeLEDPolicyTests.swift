import XCTest
@testable import StatusTrioCore

final class MagSafeLEDPolicyTests: XCTestCase {
    func testOffAndDisconnectedUseSystemControl() {
        XCTAssertEqual(policy(isControlEnabled: false), .system)
        XCTAssertEqual(policy(isConnectedToPower: false), .system)
        XCTAssertEqual(policy(isPresent: false), .system)
    }

    func testSailingHoldingIsGreenAndChargingIsAmber() {
        XCTAssertEqual(
            policy(sailingEnabled: true, phase: .holding(70, 80)),
            .green
        )
        XCTAssertEqual(
            policy(sailingEnabled: true, phase: .chargingToUpper(80)),
            .amber
        )
        XCTAssertEqual(
            policy(sailingEnabled: true, phase: .lowBatteryOverride),
            .amber
        )
        XCTAssertEqual(
            policy(sailingEnabled: true, phase: .pausedForChargeToFull),
            .amber
        )
    }

    func testFullAndNormalChargeStatesUseAlDenteColors() {
        XCTAssertEqual(policy(isCharged: true), .green)
        XCTAssertEqual(policy(isCharging: true), .amber)
        XCTAssertEqual(policy(), .system)
    }

    private func policy(
        isControlEnabled: Bool = true,
        isPresent: Bool = true,
        isConnectedToPower: Bool = true,
        isCharging: Bool = false,
        isCharged: Bool = false,
        sailingEnabled: Bool = false,
        phase: SailingModePhase? = nil
    ) -> MagSafeLEDColor {
        let battery = BatteryStatus(
            rawPercentage: 77,
            isPresent: isPresent,
            isCharging: isCharging,
            isCharged: isCharged,
            isLowPowerMode: false,
            isConnectedToPower: isConnectedToPower
        )
        return MagSafeLEDPolicy.desiredColor(
            isControlEnabled: isControlEnabled,
            battery: battery,
            sailingEnabled: sailingEnabled,
            phase: phase
        )
    }
}
