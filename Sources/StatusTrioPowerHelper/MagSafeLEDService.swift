import Foundation
import IOKit

/// The fixed MagSafe LED colors exposed by the helper.
///
/// The values follow AlDente's MagSafe 3 adapter: 6 hands control back to
/// macOS, 1 turns the LED off, 2 is green and 4 is amber. No arbitrary SMC key
/// or byte is exposed.
enum MagSafeLEDColor: Int, CaseIterable, Sendable {
    case system = 6
    case off = 1
    case green = 2
    case amber = 4
}

protocol MagSafeLEDTransport: Sendable {
    func isAvailable() -> Bool
    func readValue() -> Int?
    func writeValue(_ value: Int) -> Bool
}

/// Minimal AppleSMC access for the single fixed `ACLC` byte key.
///
/// This uses the same explicit 80-byte ABI as `SystemPowerReader` in the app:
/// key at 0, key-info size at 28, result at 40, command at 42, payload at 48.
/// It deliberately avoids a Swift struct for the wire format so compiler
/// padding cannot move the payload byte.
private enum MagSafeSMCAccess {
    private static let handleYPCEvent: UInt32 = 2
    private static let readKey: UInt8 = 5
    private static let writeKey: UInt8 = 6
    private static let getKeyInfo: UInt8 = 9

    static func fourCC(_ string: String) -> UInt32? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func keyInfo(_ key: String) -> (size: UInt32, type: String)? {
        guard let keyCode = fourCC(key) else { return nil }
        var request = [UInt8](repeating: 0, count: 80)
        writeLittleEndian(keyCode, to: &request, at: 0)
        request[42] = getKeyInfo
        guard let response = exchange(request), response.count == 80, response[40] == 0 else {
            return nil
        }
        let typeWord = readLittleEndian(response, at: 32)
        let type = String(
            bytes: [
                UInt8((typeWord >> 24) & 0xff),
                UInt8((typeWord >> 16) & 0xff),
                UInt8((typeWord >> 8) & 0xff),
                UInt8(typeWord & 0xff),
            ],
            encoding: .ascii
        ) ?? "????"
        return (readLittleEndian(response, at: 28), type)
    }

    static func readByte(_ key: String) -> UInt8? {
        guard let keyCode = fourCC(key),
              let info = keyInfo(key) else { return nil }
        var request = [UInt8](repeating: 0, count: 80)
        writeLittleEndian(keyCode, to: &request, at: 0)
        writeLittleEndian(info.size, to: &request, at: 28)
        request[42] = readKey
        guard let response = exchange(request), response.count == 80, response[40] == 0 else {
            return nil
        }
        return response[48]
    }

    static func writeByte(_ key: String, value: UInt8) -> Bool {
        guard let keyCode = fourCC(key),
              let info = keyInfo(key) else { return false }
        var request = [UInt8](repeating: 0, count: 80)
        writeLittleEndian(keyCode, to: &request, at: 0)
        writeLittleEndian(info.size, to: &request, at: 28)
        request[42] = writeKey
        request[48] = value
        guard let response = exchange(request), response.count == 80, response[40] == 0 else {
            return false
        }
        return true
    }

    private static func exchange(_ request: [UInt8]) -> [UInt8]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            return nil
        }
        defer { IOServiceClose(connection) }

        var request = request
        var response = [UInt8](repeating: 0, count: 80)
        var responseSize = 80
        let result = IOConnectCallStructMethod(
            connection,
            handleYPCEvent,
            &request,
            request.count,
            &response,
            &responseSize
        )
        guard result == kIOReturnSuccess, responseSize == 80 else { return nil }
        return response
    }

    private static func writeLittleEndian(_ value: UInt32, to buffer: inout [UInt8], at offset: Int) {
        for index in 0..<4 {
            buffer[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    private static func readLittleEndian(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { result, index in
            result | UInt32(buffer[offset + index]) << (index * 8)
        }
    }
}

struct SystemMagSafeLEDTransport: MagSafeLEDTransport {
    private static let key = "ACLC"

    func isAvailable() -> Bool {
        guard let info = MagSafeSMCAccess.keyInfo(Self.key) else { return false }
        return info.size == 1
            && info.type.trimmingCharacters(in: .whitespaces) == "ui8"
    }

    func readValue() -> Int? {
        MagSafeSMCAccess.readByte(Self.key).map(Int.init)
    }

    func writeValue(_ value: Int) -> Bool {
        guard let byte = UInt8(exactly: value) else { return false }
        return MagSafeSMCAccess.writeByte(Self.key, value: byte)
    }
}

/// Serialized access to the single `ACLC` key. Values are deliberately
/// restricted to the documented system/off/green/amber set; this service is
/// not a generic SMC key writer.
final class MagSafeLEDService: @unchecked Sendable {
    private let transport: any MagSafeLEDTransport
    private let lock = NSLock()

    init(transport: any MagSafeLEDTransport = SystemMagSafeLEDTransport()) {
        self.transport = transport
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return transport.isAvailable()
    }

    func read() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return transport.readValue()
    }

    func apply(_ color: MagSafeLEDColor) throws {
        guard color == .green || color == .amber else {
            throw MagSafeLEDServiceError.invalidColor
        }
        lock.lock()
        defer { lock.unlock() }
        guard transport.isAvailable(), transport.writeValue(color.rawValue) else {
            throw MagSafeLEDServiceError.writeFailed
        }
    }

    func restore() throws {
        lock.lock()
        defer { lock.unlock() }
        guard transport.isAvailable(), transport.writeValue(MagSafeLEDColor.system.rawValue) else {
            throw MagSafeLEDServiceError.writeFailed
        }
    }
}

enum MagSafeLEDServiceError: LocalizedError {
    case invalidColor
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidColor: "The MagSafe LED color is not supported."
        case .writeFailed: "The MagSafe LED could not be changed."
        }
    }
}
