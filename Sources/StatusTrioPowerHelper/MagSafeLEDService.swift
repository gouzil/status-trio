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

/// The minimal AppleSMC ABI needed for `ACLC`. This is intentionally limited
/// to one fixed key and one byte; it is not a general-purpose SMC writer.
private enum MagSafeSMCAccess {
    private static let handleYPCEvent: UInt32 = 2
    private static let readKey: UInt8 = 5
    private static let writeKey: UInt8 = 6
    private static let getKeyInfo: UInt8 = 9

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Param {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    static func fourCC(_ string: String) -> UInt32? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func keyInfo(_ key: String) -> (size: UInt32, type: String)? {
        try? withConnection { connection in
            var request = Param()
            request.key = fourCC(key) ?? 0
            request.data8 = getKeyInfo
            let reply = try call(connection, request)
            let type = String(
                bytes: [
                    UInt8((reply.keyInfo.dataType >> 24) & 0xff),
                    UInt8((reply.keyInfo.dataType >> 16) & 0xff),
                    UInt8((reply.keyInfo.dataType >> 8) & 0xff),
                    UInt8(reply.keyInfo.dataType & 0xff),
                ],
                encoding: .ascii
            ) ?? "????"
            return (reply.keyInfo.dataSize, type)
        }
    }

    static func readByte(_ key: String) -> UInt8? {
        try? withConnection { connection in
            var info = Param()
            info.key = fourCC(key) ?? 0
            info.data8 = getKeyInfo
            let infoReply = try call(connection, info)
            var request = Param()
            request.key = fourCC(key) ?? 0
            request.data8 = readKey
            request.keyInfo.dataSize = infoReply.keyInfo.dataSize
            let reply = try call(connection, request)
            return reply.bytes.0
        }
    }

    static func writeByte(_ key: String, value: UInt8) -> Bool {
        (try? withConnection { connection in
            var info = Param()
            info.key = fourCC(key) ?? 0
            info.data8 = getKeyInfo
            let infoReply = try call(connection, info)
            var request = Param()
            request.key = fourCC(key) ?? 0
            request.data8 = writeKey
            request.keyInfo.dataSize = infoReply.keyInfo.dataSize
            request.bytes.0 = value
            _ = try call(connection, request)
            return true
        }) ?? false
    }

    private static func call(
        _ connection: io_connect_t,
        _ input: Param
    ) throws -> Param {
        var input = input
        var output = Param()
        var outputSize = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(
            connection,
            handleYPCEvent,
            &input,
            MemoryLayout<Param>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else {
            throw MagSafeSMCAccessError.callFailed(result)
        }
        guard output.result == 0 else {
            throw MagSafeSMCAccessError.smcResult(output.result)
        }
        return output
    }

    private static func withConnection<T>(
        _ body: (io_connect_t) throws -> T
    ) throws -> T {
        guard MemoryLayout<Param>.stride == 80 else {
            throw MagSafeSMCAccessError.unexpectedLayout
        }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw MagSafeSMCAccessError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            throw MagSafeSMCAccessError.openFailed
        }
        defer { IOServiceClose(connection) }
        return try body(connection)
    }
}

private enum MagSafeSMCAccessError: Error {
    case serviceNotFound
    case openFailed
    case callFailed(kern_return_t)
    case smcResult(UInt8)
    case unexpectedLayout
}

struct SystemMagSafeLEDTransport: MagSafeLEDTransport {
    private static let key = "ACLC"

    func isAvailable() -> Bool {
        guard let info = MagSafeSMCAccess.keyInfo(Self.key) else { return false }
        return info.size == 1 && info.type.trimmingCharacters(in: .whitespaces) == "ui8"
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
