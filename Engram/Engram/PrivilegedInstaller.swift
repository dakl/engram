import Foundation

/// Installs the `/usr/local/bin/engram` symlink with one authenticated prompt
/// (ADR 0022). `/usr/local/bin` is root-owned on Apple Silicon and fresh macOS,
/// so the write needs privilege — we get it by running the symlink through
/// `/usr/bin/osascript`'s `do shell script … with administrator privileges`,
/// which shows the standard admin **password** dialog. (It does not offer Touch
/// ID — `do shell script` doesn't route through the biometric authorization
/// path, confirmed on-device; Touch ID would require a privileged helper, ADR
/// 0022.) No persistent helper, no Login Items, nothing left registered after.
enum PrivilegedInstaller {
    enum Outcome {
        case installed(String)
        /// The user dismissed the authentication dialog.
        case cancelled
        case failed(String)
    }

    /// Watchdog ceiling so a wedged auth dialog can't hang the install sheet on
    /// its spinner forever. Generous — the user may take a while to authenticate.
    private static let timeout: TimeInterval = 120

    static func install(source: String = EngramModel.bundledEngramPath) async -> Outcome {
        await Task.detached(priority: .userInitiated) { runOSAScript(source: source) }.value
    }

    private static func runOSAScript(source: String) -> Outcome {
        let dest = "/usr/local/bin/engram"
        // -sfn: replace any existing file/symlink atomically; -n so an existing
        // symlink-to-dir is treated as a file, not followed into.
        let shellCommand = "/bin/mkdir -p /usr/local/bin && /bin/ln -sfn "
            + shellQuoted(source) + " " + shellQuoted(dest)
        let appleScript = "do shell script \"" + appleScriptEscaped(shellCommand)
            + "\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return .failed("Couldn't run the installer: \(error.localizedDescription)")
        }
        // Watchdog: terminate a wedged auth dialog so waitUntilExit() can't block
        // the sheet's spinner indefinitely.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        if process.terminationReason == .uncaughtSignal {
            return .failed(
                "The installer timed out waiting for authorization. Try again, or install from Terminal with sudo.")
        }
        if process.terminationStatus == 0 {
            return .installed("installed engram → \(dest)")
        }
        let message = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // osascript reports a user-cancelled auth dialog as error -128 (userCancelledErr).
        if message.contains("-128") {
            return .cancelled
        }
        return .failed(message.isEmpty ? "Install failed." : message)
    }

    /// Single-quotes a string for /bin/sh, escaping embedded single quotes. Both
    /// paths here are app-derived, not user text, but quote anyway so an unusual
    /// install location can't break (or inject into) the command. `internal` for
    /// unit testing (this is the one security-relevant, testable piece).
    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string to sit inside an AppleScript double-quoted literal.
    static func appleScriptEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
