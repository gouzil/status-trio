import XCTest
@testable import StatusTrioCore

@MainActor
final class SailingModeSettingsTests: XCTestCase {
    func testDefaultsMatchTheSailingSpecification() {
        let suite = makeSuite()
        let store = SettingsStore(defaults: suite.defaults)

        XCTAssertFalse(store.isSailingModeEnabled)
        XCTAssertEqual(store.sailingChargeLimit, 80, accuracy: 0.001)
        XCTAssertEqual(store.sailingLevel, 5, accuracy: 0.001)
        XCTAssertEqual(
            SettingsStore.sailingChargeLimitRange,
            20...95
        )
        XCTAssertEqual(SettingsStore.sailingLevelRange, 1...15)
    }

    func testMagSafeLEDControlDefaultsOffAndPersists() {
        let suite = makeSuite()
        let first = SettingsStore(defaults: suite.defaults)
        XCTAssertFalse(first.isMagSafeLEDControlEnabled)

        first.isMagSafeLEDControlEnabled = true
        let second = SettingsStore(defaults: suite.defaults)
        XCTAssertTrue(second.isMagSafeLEDControlEnabled)
    }

    func testSailingValuesPersistAcrossRelaunch() {
        let suite = makeSuite()
        let first = SettingsStore(defaults: suite.defaults)
        first.isSailingModeEnabled = true
        first.sailingChargeLimit = 75
        first.sailingLevel = 10

        let second = SettingsStore(defaults: suite.defaults)
        XCTAssertTrue(second.isSailingModeEnabled)
        XCTAssertEqual(second.sailingChargeLimit, 75, accuracy: 0.001)
        XCTAssertEqual(second.sailingLevel, 10, accuracy: 0.001)
    }

    func testSailingChargeLimitClampsAndStepsByFiveWithoutRecursing() {
        let suite = makeSuite()
        let store = SettingsStore(defaults: suite.defaults)

        store.sailingChargeLimit = 99
        XCTAssertEqual(store.sailingChargeLimit, 95, accuracy: 0.001)

        store.sailingChargeLimit = 1
        XCTAssertEqual(store.sailingChargeLimit, 20, accuracy: 0.001)

        store.sailingChargeLimit = 72
        XCTAssertEqual(store.sailingChargeLimit, 70, accuracy: 0.001)
    }

    func testSailingLevelClampsToOneThroughFifteen() {
        let suite = makeSuite()
        let store = SettingsStore(defaults: suite.defaults)

        store.sailingLevel = 0
        XCTAssertEqual(store.sailingLevel, 1, accuracy: 0.001)

        store.sailingLevel = 99
        XCTAssertEqual(store.sailingLevel, 15, accuracy: 0.001)

        store.sailingLevel = 7.4
        XCTAssertEqual(store.sailingLevel, 7, accuracy: 0.001)
    }

    private func makeSuite() -> (defaults: UserDefaults, name: String) {
        let name = "StatusTrioCoreTests.SailingModeSettings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("could not create isolated user defaults suite")
        }
        defaults.removeTestSuite(named: name)
        addTeardownBlock { TestUserDefaults.removeSuite(named: name) }
        return (defaults, name)
    }
}
