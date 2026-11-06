import Foundation
import Testing
@testable import StatusTrioCore

/// The Sailing Mode controller owns the interval policy that keeps the battery
/// between a configurable upper limit and `upper - sailingLevel`. These tests
/// pin the state machine, the write de-duplication, the helper failure path,
/// and the lifetime of the persistent helper session without touching the real
/// Charge Limit preference.
@MainActor
struct SailingModeControllerTests {
    // MARK: - State machine

    @Test("Disabled sailing mode never writes to the helper")
    func disabledNeverWrites() async throws {
        let (settings, suite) = try makeSettings(enabled: false)
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }

        controller.update(battery: battery(75), chargeToFullActive: false)
        await settle()

        #expect(controller.phase == .disabled)
        #expect(client.startSessionCount == 0)
        #expect(client.appliedLimits.isEmpty)
        #expect(client.restoreCount == 0)
    }

    @Test("Enabling below the lower bound applies the upper limit")
    func enablingBelowLowerAppliesUpper() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(55), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [80] }

        #expect(controller.phase == .chargingToUpper(80))
        #expect(client.startSessionCount == 1)
    }

    @Test("Enabling inside the band pauses at the current level")
    func enablingInsideBandPauses() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78] }

        #expect(controller.phase == .holding(75, 80))
    }

    @Test("Reaching the upper limit pauses without forcing discharge")
    func reachingUpperPauses() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(69), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [80] }

        controller.update(battery: battery(80), chargeToFullActive: false)
        await settle()

        #expect(client.appliedLimits == [80])
        #expect(controller.phase == .holding(75, 80))
    }

    @Test("Reaching the lower limit applies the upper limit again")
    func reachingLowerAppliesUpper() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78] }

        controller.update(battery: battery(75), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78, 80] }

        #expect(controller.phase == .chargingToUpper(80))
    }

    @Test("Twenty percent or below overrides sailing with the upper limit")
    func lowBatteryOverrides() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(15), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [80] }

        #expect(controller.phase == .lowBatteryOverride)

        // A second low-battery tick must not repeat the same write.
        controller.update(battery: battery(18), chargeToFullActive: false)
        await settle()
        #expect(client.appliedLimits == [80])
    }

    @Test("Running on battery pauses at the level where it was unplugged")
    func unpluggedWaitsForPower() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(69), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [80] }
        controller.update(battery: battery(80), chargeToFullActive: false)
        await settle()

        controller.update(
            battery: battery(78, connectedToPower: false),
            chargeToFullActive: false
        )
        await waitUntil { client.appliedLimits == [80, 78] }

        #expect(controller.phase == .waitingForPower)
    }

    @Test("Replugging inside the band does not top the battery up")
    func replugInsideBandDoesNotCharge() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(69), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [80] }
        controller.update(battery: battery(80), chargeToFullActive: false)
        await settle()

        controller.update(
            battery: battery(76, connectedToPower: false),
            chargeToFullActive: false
        )
        await waitUntil { client.appliedLimits == [80, 76] }
        controller.update(battery: battery(76), chargeToFullActive: false)
        await settle()

        #expect(client.appliedLimits == [80, 76])
        #expect(controller.phase == .holding(75, 80))

        controller.update(battery: battery(69), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [80, 76, 80] }
        #expect(controller.phase == .chargingToUpper(80))
    }

    @Test("Inside the band charging starts only at the lower bound")
    func chargingStartsOnlyAtLowerBound() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78] }

        controller.update(battery: battery(69), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78, 80] }

        #expect(controller.phase == .chargingToUpper(80))
    }

    @Test("Unplugging during charge and replugging in the band does not resume")
    func unplugDuringChargeReplugDoesNotResume() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(69), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [80] }
        controller.update(battery: battery(76), chargeToFullActive: false)
        await settle()
        #expect(controller.phase == .chargingToUpper(80))

        controller.update(
            battery: battery(76, connectedToPower: false),
            chargeToFullActive: false
        )
        await waitUntil { client.appliedLimits == [80, 76] }
        #expect(controller.phase == .waitingForPower)

        controller.update(battery: battery(76), chargeToFullActive: false)
        await settle()
        #expect(client.appliedLimits == [80, 76])
        #expect(controller.phase == .holding(75, 80))
    }

    @Test("Charge to Full Now pauses sailing without cancelling the override")
    func chargeToFullPausesAndRestores() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(69), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [80] }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await settle()

        controller.update(battery: battery(78), chargeToFullActive: true)
        await settle()
        #expect(controller.phase == .pausedForChargeToFull)

        controller.update(battery: battery(78), chargeToFullActive: true)
        await settle()
        #expect(client.restoreCount == 0)
        #expect(client.endSessionCount == 0)
        #expect(client.appliedLimits == [80])

        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [80, 78] }
        #expect(controller.phase == .holding(75, 80))
        #expect(client.restoreCount == 0)
    }

    @Test("Absent or unreadable battery is unavailable and never written")
    func absentOrUnreadableBatteryIsUnavailable() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }

        controller.update(
            battery: battery(75, present: false),
            chargeToFullActive: false
        )
        #expect(controller.phase == .unavailable)

        controller.update(
            battery: battery(nil, present: true),
            chargeToFullActive: false
        )
        #expect(controller.phase == .unavailable)

        await settle()
        #expect(client.appliedLimits.isEmpty)
        #expect(client.restoreCount == 0)
    }

    @Test("An unavailable helper surfaces unavailable without writing")
    func unavailableCapabilityNeverWrites() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        client.capabilityResult = .success(false)
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }

        #expect(controller.phase == .unavailable)

        controller.update(battery: battery(78), chargeToFullActive: false)
        await settle()

        #expect(controller.phase == .unavailable)
        #expect(client.startSessionCount == 0)
        #expect(client.appliedLimits.isEmpty)
    }

    @Test("A capability read failure surfaces the helper error")
    func capabilityFailureSurfacesError() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        client.capabilityResult = .failure(SailingFakeError("helper is down"))
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }

        #expect(controller.phase == .unavailable)
        #expect(controller.lastError?.contains("helper is down") == true)
        #expect(client.appliedLimits.isEmpty)
    }

    @Test("A failed helper session keeps sailing unavailable")
    func failedSessionSurfacesError() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        client.startSessionError = SailingFakeError("session refused")
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { controller.phase == .failed }

        #expect(controller.lastError?.contains("session refused") == true)
        #expect(client.appliedLimits.isEmpty)
    }

    // MARK: - De-duplication and cooldown

    @Test("The same limit is never written twice")
    func sameLimitIsNotRewritten() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78] }

        controller.update(battery: battery(79), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78, 79] }
        controller.update(battery: battery(79), chargeToFullActive: false)
        await settle()

        #expect(client.appliedLimits == [78, 79])
        #expect(controller.phase == .holding(75, 80))
    }

    @Test("Same-direction commands inside the minimum interval are deferred")
    func sameDirectionCooldown() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        var clock = Date(timeIntervalSince1970: 1_000)
        let controller = makeController(
            settings: settings,
            client: client,
            now: { clock },
            minimumCommandInterval: 5
        )

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(69), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [80] }

        // A higher upper limit wants another charge-direction write, but the
        // previous one is only a moment old.
        settings.sailingChargeLimit = 90
        await settle()
        #expect(client.appliedLimits == [80])

        clock = clock.addingTimeInterval(6)
        controller.applySettings()
        await waitUntil { client.appliedLimits == [80, 90] }

        #expect(controller.phase == .chargingToUpper(90))
    }

    @Test("A direction reversal bypasses the same-direction cooldown")
    func reversalBypassesCooldown() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78] }

        controller.update(battery: battery(69), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78, 80] }

        #expect(controller.phase == .chargingToUpper(80))
    }

    @Test("Enabling after a rejected probe re-probes the helper")
    func enablingReprobesUnavailableHelper() async throws {
        let (settings, suite) = try makeSettings(enabled: true)
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        client.capabilityResult = .success(false)
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        #expect(controller.phase == .unavailable)

        // The helper becomes usable while the feature is switched off; turning
        // it on again must retry capability instead of staying unavailable.
        client.capabilityResult = .success(true)
        settings.isSailingModeEnabled = false
        await settle()
        settings.isSailingModeEnabled = true
        await waitUntil { client.capabilityReadCount >= 2 }

        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78] }

        #expect(controller.phase == .holding(75, 80))
    }

    @Test("A failed apply reports the error and retries on the next update")
    func failedApplyRetries() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        client.applyError = SailingFakeError("charge limit write failed")
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { controller.phase == .failed }

        #expect(client.appliedLimits.isEmpty)
        #expect(controller.lastError?.contains("charge limit write failed") == true)

        client.applyError = nil
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil {
            client.appliedLimits == [78] && controller.lastError == nil
        }

        #expect(controller.phase == .holding(75, 80))
        #expect(controller.lastError == nil)
    }

    @Test("Changing the sailing level and upper limit recomputes the band")
    func settingsChangeRecomputesBand() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78] }
        #expect(controller.phase == .holding(75, 80))

        settings.sailingLevel = 15
        await settle()
        #expect(controller.phase == .holding(65, 80))

        settings.sailingChargeLimit = 90
        await settle()
        #expect(controller.phase == .holding(75, 90))

        // The current level is already the pause target, so no extra write is
        // needed while the battery stays inside the new band.
        #expect(client.appliedLimits == [78])
    }

    @Test("Disabling sailing restores once and closes the helper session")
    func disablingRestores() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78] }

        settings.isSailingModeEnabled = false
        await waitUntil { client.restoreCount == 1 }
        #expect(controller.phase == .disabled)
        await waitUntil { client.endSessionCount == 1 }

        controller.update(battery: battery(78), chargeToFullActive: false)
        await settle()
        #expect(client.restoreCount == 1)
        #expect(client.appliedLimits == [78])
        #expect(client.endSessionCount == 1)
    }

    @Test("Stopping restores an applied limit, closes the session, and ends disabled")
    func stoppingRestores() async throws {
        let (settings, suite) = try makeSettings()
        defer { TestUserDefaults.removeSuite(named: suite) }
        let client = FakeSailingChargeLimitClient()
        let controller = makeController(settings: settings, client: client)

        controller.start()
        await waitUntil { controller.hasProbedCapability }
        controller.update(battery: battery(78), chargeToFullActive: false)
        await waitUntil { client.appliedLimits == [78] }

        await controller.stop()

        #expect(client.restoreCount == 1)
        #expect(client.endSessionCount == 1)
        #expect(controller.phase == .disabled)
    }

    @Test("A capability false without an error is not a failure")
    func capabilityFalseIsNotAnError() throws {
        let value = try SailingChargeLimitReply.capability(
            supported: false,
            error: nil
        ).get()
        #expect(value == false)
    }

    @Test("A helper error fails the capability read")
    func capabilityErrorFails() {
        let result = SailingChargeLimitReply.capability(
            supported: true,
            error: "not available"
        )
        #expect(throws: SailingChargeLimitClientError.self) {
            try result.get()
        }
    }

    @Test("A read limit of -1 means no applied limit")
    func readMinusOneMeansNoLimit() throws {
        #expect(
            try SailingChargeLimitReply.appliedLimit(-1, error: nil).get() == nil
        )
        #expect(
            try SailingChargeLimitReply.appliedLimit(80, error: nil).get() == 80
        )
    }

    @Test("A false write result throws even without an error string")
    func falseWriteResultThrows() {
        let result = SailingChargeLimitReply.writeSucceeded(
            false,
            error: nil,
            failureDescription: "The helper did not apply the sailing charge limit."
        )
        #expect(throws: SailingChargeLimitClientError.self) {
            try result.get()
        }
    }

    // MARK: - Fixtures

    private func makeSettings(
        enabled: Bool = true,
        limit: Double = 80,
        level: Double = 5
    ) throws -> (SettingsStore, String) {
        let suite = "SailingModeControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults, systemChargeLimit: { nil })
        settings.isSailingModeEnabled = enabled
        settings.sailingChargeLimit = limit
        settings.sailingLevel = level
        return (settings, suite)
    }

    private func makeController(
        settings: SettingsStore,
        client: FakeSailingChargeLimitClient,
        now: @escaping () -> Date = Date.init,
        minimumCommandInterval: TimeInterval = 0
    ) -> SailingModeController {
        SailingModeController(
            settings: settings,
            client: client,
            now: now,
            minimumCommandInterval: minimumCommandInterval
        )
    }

    private func battery(
        _ percentage: Int?,
        present: Bool = true,
        connectedToPower: Bool = true,
        charging: Bool = false
    ) -> BatteryStatus {
        BatteryStatus(
            rawPercentage: percentage,
            isPresent: present,
            isCharging: charging,
            isLowPowerMode: false,
            isConnectedToPower: connectedToPower
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline {
                Issue.record("Timed out waiting for the sailing controller state")
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Give queued commands a chance to run without waiting for a state change.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }
}

private struct SailingFakeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private final class FakeSailingChargeLimitClient: SailingChargeLimitClienting, @unchecked Sendable {
    var capabilityResult: Result<Bool, any Error> = .success(true)
    var appliedLimitResult: Result<Int?, any Error> = .success(nil)
    var startSessionError: (any Error)?
    var applyError: (any Error)?
    var restoreError: (any Error)?
    private(set) var capabilityReadCount = 0
    private(set) var appliedLimitReadCount = 0
    private(set) var startSessionCount = 0
    private(set) var endSessionCount = 0
    private(set) var appliedLimits: [Int] = []
    private(set) var restoreCount = 0

    func startSession() async throws {
        startSessionCount += 1
        if let startSessionError {
            throw startSessionError
        }
    }

    func endSession() {
        endSessionCount += 1
    }

    func readCapability() async throws -> Bool {
        capabilityReadCount += 1
        return try capabilityResult.get()
    }

    func readAppliedLimit() async throws -> Int? {
        appliedLimitReadCount += 1
        return try appliedLimitResult.get()
    }

    func applyLimit(_ percent: Int) async throws {
        if let applyError {
            throw applyError
        }
        appliedLimits.append(percent)
    }

    func restore() async throws {
        if let restoreError {
            throw restoreError
        }
        restoreCount += 1
    }
}
