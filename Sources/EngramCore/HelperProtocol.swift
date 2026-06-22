import Foundation

/// Shared constants for the privileged helper (ADR 0022). Both the daemon (the
/// bundled `engram` binary run as `engram _helper-daemon`) and the app's XPC
/// client refer to these, so they live in EngramCore — the one target both link.
public enum HelperConstants {
    /// The Mach service the daemon vends and the app connects to. Must match the
    /// `MachServices` key and `Label` in the bundled LaunchDaemon plist.
    public static let machServiceName = "org.klevan.Engram.helper"

    /// The LaunchDaemon plist `SMAppService.daemon(plistName:)` registers. Must
    /// match the file bundled at `Contents/Library/LaunchDaemons/`.
    public static let daemonPlistName = "org.klevan.Engram.helper.plist"

    /// Where the CLI symlink is installed. Hard-coded — the helper never takes a
    /// destination from the client (ADR 0022).
    public static let installDestination = "/usr/local/bin/engram"

    /// Code-signing requirement every connecting client must satisfy: our app,
    /// signed by our team (ADR 0022). Team ID from `.github/ExportOptions.plist`.
    public static let clientCodeRequirement =
        "anchor apple generic and identifier \"org.klevan.Engram\" "
        + "and certificate leaf[subject.OU] = \"M2RXQJGK5A\""
}

/// The XPC contract between the app and the privileged helper. One method: the
/// daemon installs the CLI symlink as root and reports back. Reply types are
/// Objective-C bridgeable so the interface is `@objc`-compatible.
@objc public protocol EngramHelperProtocol {
    /// Creates the `/usr/local/bin/engram` symlink pointing at the daemon's own
    /// (bundled) binary. `success` reports the outcome; `message` is a
    /// human-readable result or error suitable for showing in the app.
    func installCLI(withReply reply: @escaping (_ success: Bool, _ message: String) -> Void)
}
