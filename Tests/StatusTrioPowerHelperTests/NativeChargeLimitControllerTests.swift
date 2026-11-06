import Foundation
import XCTest
@testable import StatusTrioPowerHelper

/// The daemon-side macOS native Charge Limit backend used by Sailing Mode.
///
/// These tests exercise the controller against an injected transport, so no
/// root preference write, Darwin notification, or PowerUI call leaves the test
/// process. The production transport is only compiled, not executed here.
final class NativeChargeLimitControllerTests: XCTestCase {
    // MARK: - Marker codec

    func testMarkerRoundTrip() {
        let original = NativeChargeLimitOriginals(featureState: 0, limit: 100)
        XCTAssertEqual(NativeChargeLimit.markerString(original), "0 100")
        XCTAssertEqual(NativeChargeLimit.parseMarker("0 100"), original)

        let absent = NativeChargeLimitOriginals(featureState: nil, limit: nil)
        XCTAssertEqual(NativeChargeLimit.markerString(absent), "- -")
        XCTAssertEqual(NativeChargeLimit.parseMarker("- -\n"), absent)

        let featureOnly = NativeChargeLimitOriginals(featureState: 1, limit: nil)
        XCTAssertEqual(NativeChargeLimit.markerString(featureOnly), "1 -")
        XCTAssertEqual(NativeChargeLimit.parseMarker("1 -"), featureOnly)
        XCTAssertTrue(NativeChargeLimit.parseMarker("1 80")?.featureWasOn == true)
        XCTAssertFalse(NativeChargeLimit.parseMarker("0 80")?.featureWasOn == true)
    }

    func testMarkerParseRejectsGarbage() {
        XCTAssertNil(NativeChargeLimit.parseMarker(""))
        XCTAssertNil(NativeChargeLimit.parseMarker("1"))
        XCTAssertNil(NativeChargeLimit.parseMarker("on 80"))
        XCTAssertNil(NativeChargeLimit.parseMarker("1 80 extra"))
        XCTAssertNil(NativeChargeLimit.parseMarker("1.5 80"))
    }

    func testValidLimitRange() {
        XCTAssertTrue(NativeChargeLimit.validLimit(1))
        XCTAssertTrue(NativeChargeLimit.validLimit(60))
        XCTAssertTrue(NativeChargeLimit.validLimit(100))
        XCTAssertFalse(NativeChargeLimit.validLimit(0))
        XCTAssertFalse(NativeChargeLimit.validLimit(101))
    }

    // MARK: - Apply

    func testApplySavesOriginalsWritesTheRequestedLimitAndPostsReload() throws {
        let transport = FakeNativeChargeLimitTransport(
            preferences: [
                NativeChargeLimit.featureStateKey: 0,
                NativeChargeLimit.limitValueKey: 100,
            ]
        )
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)

        try controller.apply(percent: 60)

        XCTAssertEqual(try markerText(at: markerPath), "0 100")
        XCTAssertEqual(transport.preferences[NativeChargeLimit.featureStateKey], 1)
        XCTAssertEqual(transport.preferences[NativeChargeLimit.limitValueKey], 60)
        XCTAssertEqual(transport.writeCalls, [[
            NativeChargeLimit.featureStateKey: 1,
            NativeChargeLimit.limitValueKey: 60,
        ]])
        XCTAssertEqual(transport.postCount, 1)
    }

    func testApplyCreatesTheMarkerDirectoryAndFileWithExpectedPermissions() throws {
        let transport = FakeNativeChargeLimitTransport()
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)

        try controller.apply(percent: 60)

        let directory = (markerPath as NSString).deletingLastPathComponent
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: markerPath)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testSecondApplyDoesNotOverwriteSavedOriginals() throws {
        let transport = FakeNativeChargeLimitTransport(
            preferences: [
                NativeChargeLimit.featureStateKey: 0,
                NativeChargeLimit.limitValueKey: 100,
            ]
        )
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)

        try controller.apply(percent: 60)
        try controller.apply(percent: 70)

        XCTAssertEqual(try markerText(at: markerPath), "0 100")
        XCTAssertEqual(transport.preferences[NativeChargeLimit.limitValueKey], 70)
        XCTAssertEqual(transport.postCount, 2)
    }

    func testApplyRejectsUnavailableTransport() {
        let transport = FakeNativeChargeLimitTransport()
        transport.available = false
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)

        XCTAssertThrowsError(try controller.apply(percent: 60)) { error in
            XCTAssertEqual(error as? NativeChargeLimitError, .unavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
        XCTAssertTrue(transport.writeCalls.isEmpty)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testApplyRejectsOutOfRangePercentWithoutSavingAMarker() {
        let transport = FakeNativeChargeLimitTransport()
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)

        XCTAssertThrowsError(try controller.apply(percent: 0)) { error in
            XCTAssertEqual(error as? NativeChargeLimitError, .invalidLimit)
        }
        XCTAssertThrowsError(try controller.apply(percent: 101)) { error in
            XCTAssertEqual(error as? NativeChargeLimitError, .invalidLimit)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
        XCTAssertTrue(transport.writeCalls.isEmpty)
    }

    func testApplyFailsAndKeepsTheMarkerWhenTheWriteCannotBeVerified() throws {
        let transport = FakeNativeChargeLimitTransport(
            preferences: [
                NativeChargeLimit.featureStateKey: 0,
                NativeChargeLimit.limitValueKey: 100,
            ]
        )
        // Accept the write but discard it, as a rejected CFPreferences write
        // would look to the controller's read-back verification.
        transport.writeResult = true
        transport.dropWrites = true
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)

        XCTAssertThrowsError(try controller.apply(percent: 60)) { error in
            XCTAssertEqual(error as? NativeChargeLimitError, .verificationFailed)
        }
        XCTAssertEqual(try markerText(at: markerPath), "0 100")
    }

    // MARK: - Restore

    func testRestoreCallsDisableAndRestoresAFeatureThatWasOn() throws {
        let transport = FakeNativeChargeLimitTransport(
            preferences: [
                NativeChargeLimit.featureStateKey: 1,
                NativeChargeLimit.limitValueKey: 80,
            ]
        )
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)
        try controller.apply(percent: 60)

        try controller.restore()

        XCTAssertEqual(transport.disableCount, 1)
        XCTAssertEqual(transport.preferences[NativeChargeLimit.featureStateKey], 1)
        XCTAssertEqual(transport.preferences[NativeChargeLimit.limitValueKey], 80)
        XCTAssertEqual(transport.postCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }

    func testRestoreWritesStateOffAndRebuildsTheOriginalLimitWhenFeatureWasOff() throws {
        let transport = FakeNativeChargeLimitTransport(
            preferences: [
                NativeChargeLimit.featureStateKey: 0,
                NativeChargeLimit.limitValueKey: 100,
            ]
        )
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)
        try controller.apply(percent: 60)

        try controller.restore()

        XCTAssertEqual(transport.disableCount, 1)
        XCTAssertEqual(transport.preferences[NativeChargeLimit.featureStateKey], 0)
        XCTAssertEqual(transport.preferences[NativeChargeLimit.limitValueKey], 100)
        XCTAssertEqual(transport.postCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }

    func testRestoreWritesStateOffWhenNoOriginalLimitExisted() throws {
        let transport = FakeNativeChargeLimitTransport()
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)
        try controller.apply(percent: 60)

        try controller.restore()

        XCTAssertEqual(transport.preferences[NativeChargeLimit.featureStateKey], 0)
        // There was no original target to restore; the feature switch is what
        // matters, and a stale target is inert while it is off.
        XCTAssertEqual(transport.writeCalls.last, [NativeChargeLimit.featureStateKey: 0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }

    func testRestoreWithoutAMarkerSucceedsWithoutWriting() throws {
        let transport = FakeNativeChargeLimitTransport(
            preferences: [
                NativeChargeLimit.featureStateKey: 1,
                NativeChargeLimit.limitValueKey: 80,
            ]
        )
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)

        try controller.restore()

        XCTAssertEqual(transport.disableCount, 0)
        XCTAssertTrue(transport.writeCalls.isEmpty)
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertEqual(transport.preferences[NativeChargeLimit.featureStateKey], 1)
    }

    func testRestoreRejectsACorruptMarkerWithoutWriting() throws {
        let transport = FakeNativeChargeLimitTransport()
        let markerPath = makeMarkerPath()
        try FileManager.default.createDirectory(
            atPath: (markerPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("not a marker".utf8).write(to: URL(fileURLWithPath: markerPath))
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)

        XCTAssertThrowsError(try controller.restore()) { error in
            XCTAssertEqual(error as? NativeChargeLimitError, .corruptMarker)
        }
        XCTAssertEqual(transport.disableCount, 0)
        XCTAssertTrue(transport.writeCalls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath))
    }

    func testRestoreKeepsTheMarkerWhenDisableFails() throws {
        let transport = FakeNativeChargeLimitTransport(
            preferences: [
                NativeChargeLimit.featureStateKey: 0,
                NativeChargeLimit.limitValueKey: 100,
            ]
        )
        transport.disableResult = false
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)
        try controller.apply(percent: 60)

        XCTAssertThrowsError(try controller.restore()) { error in
            XCTAssertEqual(error as? NativeChargeLimitError, .disableMCLFailed)
        }
        XCTAssertEqual(try markerText(at: markerPath), "0 100")
        XCTAssertEqual(transport.preferences[NativeChargeLimit.featureStateKey], 1)
    }

    func testRestoreIfNeededWithoutAMarkerReturnsTrueWithoutWriting() {
        let transport = FakeNativeChargeLimitTransport()
        let controller = NativeChargeLimitController(transport: transport, markerPath: makeMarkerPath())

        XCTAssertTrue(controller.restoreIfNeeded())
        XCTAssertEqual(transport.disableCount, 0)
        XCTAssertTrue(transport.writeCalls.isEmpty)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testRestoreIfNeededRestoresTheSavedOriginalAndRemovesTheMarker() throws {
        let transport = FakeNativeChargeLimitTransport(
            preferences: [
                NativeChargeLimit.featureStateKey: 0,
                NativeChargeLimit.limitValueKey: 100,
            ]
        )
        let markerPath = makeMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)
        try controller.apply(percent: 60)

        XCTAssertTrue(controller.restoreIfNeeded())

        XCTAssertEqual(transport.disableCount, 1)
        XCTAssertEqual(transport.preferences[NativeChargeLimit.featureStateKey], 0)
        XCTAssertEqual(transport.preferences[NativeChargeLimit.limitValueKey], 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }

    // MARK: - Read and capability

    func testCapabilityFollowsTheTransportProbe() {
        let transport = FakeNativeChargeLimitTransport()
        let controller = NativeChargeLimitController(transport: transport, markerPath: makeMarkerPath())
        XCTAssertTrue(controller.capability())

        transport.available = false
        XCTAssertFalse(controller.capability())
    }

    func testReadAppliedLimitReturnsMinusOneUnlessTheFeatureIsOn() {
        let transport = FakeNativeChargeLimitTransport()
        let controller = NativeChargeLimitController(transport: transport, markerPath: makeMarkerPath())

        XCTAssertEqual(controller.readAppliedLimit(), -1)
        transport.replacePreferences([
            NativeChargeLimit.featureStateKey: 0,
            NativeChargeLimit.limitValueKey: 80,
        ])
        XCTAssertEqual(controller.readAppliedLimit(), -1)
        transport.replacePreferences([
            NativeChargeLimit.featureStateKey: 1,
            NativeChargeLimit.limitValueKey: 80,
        ])
        XCTAssertEqual(controller.readAppliedLimit(), 80)
        transport.replacePreferences([NativeChargeLimit.featureStateKey: 1])
        XCTAssertEqual(controller.readAppliedLimit(), -1)
    }

    // MARK: - Helpers

    private func makeMarkerPath() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusTrioNativeLimit-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("saved-native-limit").path
    }

    private func markerText(at path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The XPC reply surface for the v3 Sailing Mode methods.
final class PowerModeServiceSailingReplyTests: XCTestCase {
    func testReadSailingChargeLimitCapabilityUsesTheController() {
        let transport = FakeNativeChargeLimitTransport()
        transport.available = true
        let controller = NativeChargeLimitController(transport: transport, markerPath: temporaryMarkerPath())
        let service = PowerModeService(runner: SilentPmsetRunner(), sailing: controller)
        let replied = expectation(description: "reply arrives")

        service.readSailingChargeLimitCapability { capability, errorDescription in
            XCTAssertTrue(capability)
            XCTAssertNil(errorDescription)
            replied.fulfill()
        }

        wait(for: [replied], timeout: 2)
    }

    func testApplySailingChargeLimitRepliesWithFailureAndTheReason() {
        let transport = FakeNativeChargeLimitTransport()
        transport.available = false
        let controller = NativeChargeLimitController(transport: transport, markerPath: temporaryMarkerPath())
        let service = PowerModeService(runner: SilentPmsetRunner(), sailing: controller)
        let replied = expectation(description: "reply arrives")

        service.applySailingChargeLimit(60) { applied, errorDescription in
            XCTAssertFalse(applied)
            XCTAssertEqual(errorDescription, NativeChargeLimitError.unavailable.localizedDescription)
            replied.fulfill()
        }

        wait(for: [replied], timeout: 2)
    }

    func testReadSailingChargeLimitReportsTheAppliedValue() {
        let transport = FakeNativeChargeLimitTransport(
            preferences: [
                NativeChargeLimit.featureStateKey: 1,
                NativeChargeLimit.limitValueKey: 60,
            ]
        )
        let controller = NativeChargeLimitController(transport: transport, markerPath: temporaryMarkerPath())
        let service = PowerModeService(runner: SilentPmsetRunner(), sailing: controller)
        let replied = expectation(description: "reply arrives")

        service.readSailingChargeLimit { percent, errorDescription in
            XCTAssertEqual(percent, 60)
            XCTAssertNil(errorDescription)
            replied.fulfill()
        }

        wait(for: [replied], timeout: 2)
    }

    func testRestoreOnClientDisconnectClearsASavedLimit() throws {
        let transport = FakeNativeChargeLimitTransport(
            preferences: [
                NativeChargeLimit.featureStateKey: 0,
                NativeChargeLimit.limitValueKey: 100,
            ]
        )
        let markerPath = temporaryMarkerPath()
        let controller = NativeChargeLimitController(transport: transport, markerPath: markerPath)
        try controller.apply(percent: 60)
        let service = PowerModeService(runner: SilentPmsetRunner(), sailing: controller)

        service.restoreSailingLimitOnClientDisconnect()

        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in transport.disableCount == 1 },
            object: nil
        )
        wait(for: [restored], timeout: 2)
        XCTAssertEqual(transport.preferences[NativeChargeLimit.featureStateKey], 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }

    private func temporaryMarkerPath() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusTrioNativeLimitService-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("saved-native-limit").path
    }
}

// MARK: - Doubles

private final class FakeNativeChargeLimitTransport: NativeChargeLimitTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Int]
    private var _writeCalls: [[String: Int]] = []
    private var _postCount = 0
    private var _disableCount = 0

    var available = true
    var writeResult = true
    /// Accepts a write but leaves the stored values untouched, emulating a
    /// preference domain that drops a write the way `CFPreferences` can.
    var dropWrites = false
    var postResult = true
    var disableResult = true

    init(preferences: [String: Int] = [:]) {
        stored = preferences
    }

    var preferences: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var writeCalls: [[String: Int]] {
        lock.lock()
        defer { lock.unlock() }
        return _writeCalls
    }

    var postCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _postCount
    }

    var disableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _disableCount
    }

    func replacePreferences(_ preferences: [String: Int]) {
        lock.lock()
        stored = preferences
        lock.unlock()
    }

    func readPreference(_ key: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return stored[key]
    }

    func writePreferences(_ values: [String: Int]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard writeResult else { return false }
        _writeCalls.append(values)
        guard !dropWrites else { return true }
        for (key, value) in values {
            stored[key] = value
        }
        return true
    }

    func postReload() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _postCount += 1
        return postResult
    }

    func disableMCL() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _disableCount += 1
        return disableResult
    }

    func isAvailable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return available
    }
}

private struct SilentPmsetRunner: PmsetRunning {
    func setLowPowerMode(enabled: Bool) async throws {}
    func currentLowPowerMode() async -> Bool? { false }
    func highPowerModeSupported() async -> Bool? { false }
    func setHighPowerMode(enabled: Bool) async throws {}
    func currentHighPowerMode() async -> Bool? { false }
}
