import EngramCore
import Foundation
import ServiceManagement

/// Drives the privileged helper (ADR 0022): registers the bundled LaunchDaemon
/// with `SMAppService`, then calls it over XPC to create the
/// `/usr/local/bin/engram` symlink as root. Replaces the user-writable-only
/// `engram install` path for the app's "Install CLI" button.
enum PrivilegedInstaller {
    enum Outcome {
        case installed(String)
        /// The daemon needs the user to enable Engram in System Settings → Login
        /// Items before it can run. System Settings has been opened.
        case needsApproval
        case failed(String)
    }

    private static var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    }

    /// Registers + (if needed) prompts approval for the daemon, then asks it to
    /// install the symlink.
    static func install() async -> Outcome {
        switch ensureRegistered() {
        case .ready:
            break
        case .needsApproval:
            return .needsApproval
        case let .failed(message):
            return .failed(message)
        }
        return await callHelper()
    }

    private enum Registration {
        case ready
        case needsApproval
        case failed(String)
    }

    private static func ensureRegistered() -> Registration {
        let service = self.service
        switch service.status {
        case .enabled:
            return .ready
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return .needsApproval
        case .notRegistered, .notFound:
            do {
                try service.register()
            } catch {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    return .needsApproval
                }
                return .failed("Couldn't register the privileged helper: \(error.localizedDescription)")
            }
            // Registration on a fresh machine lands in requiresApproval until the
            // user toggles Engram on in Login Items.
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return .needsApproval
            }
            return service.status == .enabled
                ? .ready
                : .failed("Helper didn't enable (status \(service.status.rawValue)).")
        @unknown default:
            return .failed("Unexpected helper status (\(service.status.rawValue)).")
        }
    }

    private static func callHelper() async -> Outcome {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                             options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EngramHelperProtocol.self)
            connection.resume()

            // The error handler and the reply both run on XPC's queue and are
            // mutually exclusive in practice, but guard against a double resume.
            let once = Once()
            let finish: (Outcome) -> Void = { outcome in
                once.run {
                    connection.invalidate()
                    continuation.resume(returning: outcome)
                }
            }

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(.failed("Couldn't reach the helper: \(error.localizedDescription)"))
            }
            guard let helper = proxy as? EngramHelperProtocol else {
                finish(.failed("Couldn't create the helper proxy."))
                return
            }
            helper.installCLI { success, message in
                finish(success ? .installed(message) : .failed(message))
            }
        }
    }
}

/// One-shot guard so a continuation is resumed exactly once across the XPC
/// reply and error-handler callbacks.
private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}
