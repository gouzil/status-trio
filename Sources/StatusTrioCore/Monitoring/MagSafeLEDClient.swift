import Foundation

/// App-side abstraction over the fixed MagSafe LED operations.
protocol MagSafeLEDClienting: Sendable {
    func magSafeCapability() async throws -> Bool
    func magSafeState() async throws -> Int
    func setMagSafeColor(_ color: MagSafeLEDColor) async throws -> Bool
    func restoreMagSafeColor() async throws -> Bool
}

extension XPCPrivilegedHelperClient: MagSafeLEDClienting {
    func magSafeCapability() async throws -> Bool {
        try await readMagSafeLEDCapability()
    }

    func magSafeState() async throws -> Int {
        try await readMagSafeLEDState()
    }

    func setMagSafeColor(_ color: MagSafeLEDColor) async throws -> Bool {
        try await setMagSafeLED(color)
    }

    func restoreMagSafeColor() async throws -> Bool {
        try await restoreMagSafeLED()
    }
}
