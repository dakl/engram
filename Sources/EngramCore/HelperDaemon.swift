import Foundation
import Security

/// The privileged helper daemon (ADR 0022). Runs as root, launched by
/// `SMAppService` as the hidden `engram _helper-daemon` subcommand. It vends a
/// single XPC method that installs the CLI symlink, and only after validating
/// that the connecting client is our signed app.
public final class HelperDaemon: NSObject, NSXPCListenerDelegate, EngramHelperProtocol {
    private let listener: NSXPCListener

    public override init() {
        listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
        super.init()
        listener.delegate = self
    }

    /// Services XPC connections forever. Call from the daemon process; never returns.
    public func run() -> Never {
        listener.resume()
        dispatchMain()
    }

    // MARK: - NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener,
                         shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard HelperDaemon.isClientTrusted(newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: EngramHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    // MARK: - EngramHelperProtocol

    /// Installs `/usr/local/bin/engram` → the daemon's own bundled binary. Both
    /// paths are fixed/derived here, never taken from the client (ADR 0022), so
    /// the helper can only ever install itself.
    public func installCLI(withReply reply: @escaping (Bool, String) -> Void) {
        guard let source = Bundle.main.executablePath else {
            reply(false, "could not locate the bundled engram binary")
            return
        }
        let dest = HelperConstants.installDestination
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dest) || HelperDaemon.isSymlink(atPath: dest) {
                try fileManager.removeItem(atPath: dest)
            }
            try fileManager.createSymbolicLink(atPath: dest, withDestinationPath: source)
            reply(true, "installed engram → \(dest)")
        } catch {
            reply(false, "\(error)")
        }
    }

    // MARK: - Validation

    /// `fileExists` follows symlinks, so a dangling link reports false; check the
    /// symbolic-link attribute directly to catch that case too.
    private static func isSymlink(atPath path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Validates the connecting client's code signature against our app's
    /// requirement (ADR 0022) via the connection's audit token. Reject anything
    /// that isn't our notarized app, so the root helper can't be driven by other
    /// processes.
    static func isClientTrusted(_ connection: NSXPCConnection) -> Bool {
        guard let token = auditToken(of: connection) else { return false }
        let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let guestCode = code else { return false }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(HelperConstants.clientCodeRequirement as CFString,
                                             [], &requirement) == errSecSuccess,
              let clientRequirement = requirement else { return false }

        return SecCodeCheckValidity(guestCode, [], clientRequirement) == errSecSuccess
    }

    /// NSXPCConnection doesn't expose its audit token publicly; read it via KVC.
    /// This is the established pattern for secure XPC peer validation.
    private static func auditToken(of connection: NSXPCConnection) -> audit_token_t? {
        guard let value = connection.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        return token
    }
}
