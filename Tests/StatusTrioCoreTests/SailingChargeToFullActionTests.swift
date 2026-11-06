import XCTest
@testable import StatusTrioCore

final class SailingChargeToFullActionTests: XCTestCase {
    func testOnlySailingEnabledAvailableBatteryCanShowTheAction() {
        XCTAssertFalse(policy(isSailingEnabled: false))
        XCTAssertFalse(policy(isSettingAvailable: false))
        XCTAssertFalse(policy(isPresent: false))
        XCTAssertTrue(policy())
    }

    func testActionNeedsPowerAndAnUnfinishedCharge() {
        XCTAssertTrue(policy(percentage: 79, connectedToPower: true))
        XCTAssertFalse(policy(percentage: 79, connectedToPower: false))
        XCTAssertFalse(policy(percentage: 100, connectedToPower: true))
        XCTAssertFalse(policy(isCharged: true, connectedToPower: true))
    }

    func testActiveOverrideStaysVisibleSoItCanBeCancelled() {
        XCTAssertTrue(
            policy(
                percentage: 79,
                connectedToPower: false,
                presentation: .chargingToFull
            )
        )
        XCTAssertTrue(
            policy(
                percentage: 100,
                connectedToPower: true,
                presentation: .chargingToFull
            )
        )
    }

    private func policy(
        isSailingEnabled: Bool = true,
        isSettingAvailable: Bool = true,
        isPresent: Bool = true,
        percentage: Int = 79,
        isCharged: Bool = false,
        connectedToPower: Bool = true,
        presentation: ChargeToFullNowPresentation = .available
    ) -> Bool {
        let battery = BatteryStatus(
            rawPercentage: percentage,
            isPresent: isPresent,
            isCharging: false,
            isCharged: isCharged,
            isLowPowerMode: false,
            isConnectedToPower: connectedToPower
        )
        return SailingChargeToFullActionPolicy.shouldShow(
            isSailingEnabled: isSailingEnabled,
            isSettingAvailable: isSettingAvailable,
            battery: battery,
            presentation: presentation
        )
    }
}
