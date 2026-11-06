import Foundation
import PowerHelperProtocol

/// The app's view of the helper's Sailing Mode charge-limit surface.
///
/// Unlike the Low Power Mode/HIGH Power Mode one-shot surface, these calls run
/// inside a *session*: the helper restores the user's original Charge Limit
/// when the last client connection closes, so every sailing call has to reuse
/// one persistent `NSXPCConnection`. `startSession()` opens it and
/// `endSession()` closes it after `restore()` has been requested.
protocol SailingChargeLimitClienting: Sendable {
    /// Opens (or keeps) the persistent helper connection used by the session.
    func startSession() async throws
    /// Invalidates the persistent helper connection. Safe to call repeatedly.
    func endSession()
    /// Whether this Mac can enforce a manual charge limit through the helper.
    func readCapability() async throws -> Bool
    /// The charge limit currently applied by the helper, or `nil` when none is.
    func readAppliedLimit() async throws -> Int?
    /// Applies `percent` as the system's manual charge limit.
    func applyLimit(_ percent: Int) async throws
    /// Restores the Charge Limit setting that was active before the session.
    func restore() async throws
}

enum SailingChargeLimitClientError: LocalizedError, Equatable {
    case helperUnavailable
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "The power helper is not available."
        case let .rejected(reason):
            reason
        }
    }
}

/// Maps the Objective-C reply shapes of the v3 helper methods to Swift results.
///
/// A capability answer of `false` without an error is a normal "this Mac does
/// not support it" result, while a `false` write result is a failure. Keeping
/// the mapping separate from the XPC plumbing lets the controller tests pin the
/// contract without a registered daemon.
enum SailingChargeLimitReply {
    static func capability(
        supported: Bool,
        error: String?
    ) -> Result<Bool, any Error> {
        if let error {
            return .failure(SailingChargeLimitClientError.rejected(error))
        }
        return .success(supported)
    }

    static func appliedLimit(
        _ percent: Int,
        error: String?
    ) -> Result<Int?, any Error> {
        if let error {
            return .failure(SailingChargeLimitClientError.rejected(error))
        }
        return .success(percent == -1 ? nil : percent)
    }

    static func writeSucceeded(
        _ succeeded: Bool,
        error: String?,
        failureDescription: String
    ) -> Result<Void, any Error> {
        if let error {
            return .failure(SailingChargeLimitClientError.rejected(error))
        }
        guard succeeded else {
            return .failure(SailingChargeLimitClientError.rejected(failureDescription))
        }
        return .success(())
    }
}

/// A standalone XPC client for the Sailing Mode methods.
///
/// The connection is created on the first request and kept alive until
/// `endSession()`. Individual replies use a timeout but never invalidate the
/// connection: the helper treats a disconnect as "the app is gone" and restores
/// the user's original charge limit, which would defeat an active sailing
/// session between interval switches.
final class XPCPrivilegedSailingChargeLimitClient: SailingChargeLimitClienting, @unchecked Sendable {
    private let connection: SailingChargeLimitXPCConnection

    init(requestTimeout: TimeInterval = 3) {
        connection = SailingChargeLimitXPCConnection(requestTimeout: requestTimeout)
    }

    func startSession() async throws {
        try await connection.start()
    }

    func endSession() {
        connection.end()
    }

    func readCapability() async throws -> Bool {
        try await request { proxy, finish in
            proxy.readSailingChargeLimitCapability { supported, error in
                finish(
                    SailingChargeLimitReply.capability(
                        supported: supported,
                        error: error
                    )
                )
            }
        }
    }

    func readAppliedLimit() async throws -> Int? {
        try await request { proxy, finish in
            proxy.readSailingChargeLimit { percent, error in
                finish(
                    SailingChargeLimitReply.appliedLimit(percent, error: error)
                )
            }
        }
    }

    func applyLimit(_ percent: Int) async throws {
        try await request { proxy, finish -> Void in
            proxy.applySailingChargeLimit(percent) { succeeded, error in
                finish(
                    SailingChargeLimitReply.writeSucceeded(
                        succeeded,
                        error: error,
                        failureDescription: "The helper did not apply the sailing charge limit."
                    )
                )
            }
        }
    }

    func restore() async throws {
        try await request { proxy, finish -> Void in
            proxy.restoreSailingChargeLimit { succeeded, error in
                finish(
                    SailingChargeLimitReply.writeSucceeded(
                        succeeded,
                        error: error,
                        failureDescription: "The helper did not restore the original charge limit."
                    )
                )
            }
        }
    }

    private func request<Value: Sendable>(
        _ body: @escaping @Sendable (
            any PowerHelperXPCProtocol,
            @escaping (Result<Value, any Error>) -> Void
        ) -> Void
    ) async throws -> Value {
        try await connection.perform(body)
    }
}

/// Lets the shared helper client answer the Sailing Mode surface without
/// changing its existing Low Power Mode implementation. All instances delegate
/// to one app-wide sailing session so the helper sees a single connection.
extension XPCPrivilegedHelperClient: SailingChargeLimitClienting {
    func startSession() async throws {
        try await sharedSailingChargeLimitClient.startSession()
    }

    func endSession() {
        sharedSailingChargeLimitClient.endSession()
    }

    func readCapability() async throws -> Bool {
        try await sharedSailingChargeLimitClient.readCapability()
    }

    func readAppliedLimit() async throws -> Int? {
        try await sharedSailingChargeLimitClient.readAppliedLimit()
    }

    func applyLimit(_ percent: Int) async throws {
        try await sharedSailingChargeLimitClient.applyLimit(percent)
    }

    func restore() async throws {
        try await sharedSailingChargeLimitClient.restore()
    }
}

/// The app-wide sailing session used by `XPCPrivilegedHelperClient`.
private let sharedSailingChargeLimitClient = XPCPrivilegedSailingChargeLimitClient()

/// Owns the persistent `NSXPCConnection` and serializes requests on one queue.
///
/// Replies are resolved exactly once with a timeout. A reply never invalidates
/// the connection; only `end()` (or a connection-level failure) tears it down.
private final class SailingChargeLimitXPCConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StatusTrio.PowerHelper.SailingChargeLimit.XPC")
    private let requestTimeout: TimeInterval
    private var connection: NSXPCConnection?
    private var proxy: (any PowerHelperXPCProtocol)?

    init(requestTimeout: TimeInterval) {
        self.requestTimeout = requestTimeout
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    _ = try makeProxyIfNeeded()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func end() {
        queue.async { [self] in
            dropConnection()
        }
    }

    func perform<Value: Sendable>(
        _ body: @escaping @Sendable (
            any PowerHelperXPCProtocol,
            @escaping (Result<Value, any Error>) -> Void
        ) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let proxy: any PowerHelperXPCProtocol
                do {
                    proxy = try makeProxyIfNeeded()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let finish = SailingOneShotReply(
                    continuation: continuation,
                    timeout: requestTimeout,
                    queue: queue,
                    timeoutError: SailingChargeLimitClientError.helperUnavailable
                )
                body(proxy, finish.resolve)
            }
        }
    }

    private func makeProxyIfNeeded() throws -> any PowerHelperXPCProtocol {
        if let proxy {
            return proxy
        }
        dropConnection()
        let connection = NSXPCConnection(
            machServiceName: PowerHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperXPCProtocol.self)
        connection.interruptionHandler = { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in self?.dropConnection() }
        }
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in self?.dropConnection() }
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.dropConnection() }
        }) as? any PowerHelperXPCProtocol else {
            connection.invalidate()
            throw SailingChargeLimitClientError.helperUnavailable
        }
        self.connection = connection
        self.proxy = proxy
        return proxy
    }

    private func dropConnection() {
        connection?.invalidate()
        connection = nil
        proxy = nil
    }
}

/// Resumes the continuation exactly once; unlike `OneShotReply` it leaves the
/// shared connection alive for the next sailing command.
private final class SailingOneShotReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<Value, any Error>

    init(
        continuation: CheckedContinuation<Value, any Error>,
        timeout: TimeInterval,
        queue: DispatchQueue,
        timeoutError: any Error
    ) {
        self.continuation = continuation
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            resolve(.failure(timeoutError))
        }
    }

    func resolve(_ result: Result<Value, any Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.resume(with: result)
    }
}
