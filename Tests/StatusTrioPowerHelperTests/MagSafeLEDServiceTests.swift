import XCTest
@testable import StatusTrioPowerHelper

final class MagSafeLEDServiceTests: XCTestCase {
    func testCapabilityAndReadPassThroughTransport() {
        let transport = FakeMagSafeLEDTransport()
        transport.available = true
        transport.value = 2
        let service = MagSafeLEDService(transport: transport)

        XCTAssertTrue(service.isAvailable)
        XCTAssertEqual(service.read(), 2)
    }

    func testApplyUsesOnlyFixedMagSafeValues() throws {
        let transport = FakeMagSafeLEDTransport()
        let service = MagSafeLEDService(transport: transport)

        try service.apply(.green)
        try service.apply(.amber)
        XCTAssertEqual(transport.writes, [2, 4])

        XCTAssertThrowsError(try service.apply(.system))
        XCTAssertEqual(transport.writes, [2, 4])
    }

    func testRestoreHandsControlBackToTheSystem() throws {
        let transport = FakeMagSafeLEDTransport()
        let service = MagSafeLEDService(transport: transport)

        try service.restore()

        XCTAssertEqual(transport.writes, [6])
    }

    func testUnavailableTransportNeverWrites() {
        let transport = FakeMagSafeLEDTransport()
        transport.available = false
        let service = MagSafeLEDService(transport: transport)

        XCTAssertFalse(service.isAvailable)
        XCTAssertThrowsError(try service.apply(.green))
        XCTAssertTrue(transport.writes.isEmpty)
    }
}

private final class FakeMagSafeLEDTransport: MagSafeLEDTransport, @unchecked Sendable {
    var available = true
    var value: Int?
    var writes: [Int] = []

    func isAvailable() -> Bool { available }
    func readValue() -> Int? { value }
    func writeValue(_ value: Int) -> Bool {
        writes.append(value)
        return true
    }
}
