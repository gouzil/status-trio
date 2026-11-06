import Foundation
import PowerHelperProtocol

/// Accepts XPC connections from the app and exports the power-mode service.
///
/// The listener itself carries the code-signing requirement
/// (`setConnectionCodeSigningRequirement`), so a mismatched peer is rejected by
/// Foundation before this delegate runs. The delegate re-checks the caller as
/// defense in depth and logs any rejection.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: PowerModeService
    private let idleExit: IdleExitMonitor?
    private let onAllConnectionsClosed: @Sendable () -> Void
    private let connections = AcceptedConnectionCounter()

    init(
        service: PowerModeService,
        idleExit: IdleExitMonitor? = nil,
        onAllConnectionsClosed: @escaping @Sendable () -> Void = {}
    ) {
        self.service = service
        self.idleExit = idleExit
        self.onAllConnectionsClosed = onAllConnectionsClosed
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ClientAuthorization.isCallerAllowed(connection) else {
            NSLog(
                "StatusTrioPowerHelper rejected connection from pid %d",
                connection.processIdentifier
            )
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: PowerHelperXPCProtocol.self)
        connection.exportedObject = service

        // Every accepted connection is a reason for this root process to exist.
        // Counting them lets the daemon exit once the app is done with it,
        // including when the app quits without invalidating its connection.
        connections.opened()
        if let idleExit {
            idleExit.connectionOpened()
        }
        let idleExit = self.idleExit
        let connections = self.connections
        let onAllConnectionsClosed = self.onAllConnectionsClosed
        let lifetime = ConnectionLifetime {
            idleExit?.connectionClosed()
            // The two handlers can fire for the same connection; the lifetime
            // folds them into one decrement. The last client leaving is also
            // the last chance to undo a Sailing Mode charge limit before the
            // daemon idles out.
            if connections.closed() {
                onAllConnectionsClosed()
            }
        }
        connection.invalidationHandler = { lifetime.end() }
        connection.interruptionHandler = { lifetime.end() }
        connection.resume()
        return true
    }
}

/// Counts accepted connections separately from `IdleExitMonitor`'s own count,
/// so the delegate can act exactly once when the last client disconnects.
private final class AcceptedConnectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func opened() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    /// Returns true when this was the last open connection.
    func closed() -> Bool {
        lock.lock()
        count = max(0, count - 1)
        let wasLast = count == 0
        lock.unlock()
        return wasLast
    }
}
