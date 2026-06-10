import Foundation

/// Install logic for the CLI itself, the Claude Code hooks (recall +
/// verify-context), and the skills. This is the single source of truth: the
/// macOS app's toolbar buttons just shell out to `engram install` / `engram setup`.
enum Setup {
    static let installPrefix = "/usr/local/bin"
    static var installedCLIPath: String { "\(installPrefix)/engram" }

    /// The Claude Code hooks `engram setup` installs (idempotent): per-prompt
    /// recall (ADR 0005) and a session-start code-grounded sanity check (ADR 0008
    /// Phase 2). Both are read-only and always exit 0, so they can't block a session.
    static let managedHooks: [(event: String, command: String)] = [
        ("UserPromptSubmit", "\(installPrefix)/engram hook recall"),
        ("SessionStart", "\(installPrefix)/engram hook verify-context"),
    ]

    private static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    // MARK: - engram install

    /// Copies the running binary to `/usr/local/bin/engram`.
    static func installCLI() throws -> String {
        guard let source = Bundle.main.executablePath else {
            throw SetupError("could not locate the running engram binary")
        }
        let dest = installedCLIPath
        if source == dest {
            return "engram is already running from \(dest)"
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: installPrefix, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.copyItem(atPath: source, toPath: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
        return "installed engram → \(dest)"
    }

    // MARK: - engram setup

    static func runSetup(hooks: Bool, skills: Bool) throws -> String {
        var lines: [String] = []
        if hooks { lines.append(try installHook()) }
        if skills { lines.append(contentsOf: try installSkills()) }
        return lines.joined(separator: "\n")
    }

    /// Merges the SessionStart recall hook into ~/.claude/settings.json
    /// (idempotent; backs up the file first).
    private static func installHook() throws -> String {
        let fm = FileManager.default
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
            // back up before modifying
            let backup = settingsURL.appendingPathExtension("engram-bak")
            try? data.write(to: backup)
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Migrate: strip any previous engram hook from every event (e.g. the old
        // SessionStart session-digest), so re-running converges on one hook.
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                guard var inner = group["hooks"] as? [[String: Any]] else { return group }
                inner.removeAll { ($0["command"] as? String)?.contains("engram hook") ?? false }
                if inner.isEmpty { return nil }
                var g = group; g["hooks"] = inner; return g
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }

        for managed in managedHooks {
            var event = hooks[managed.event] as? [[String: Any]] ?? []
            event.append(["hooks": [["type": "command", "command": managed.command, "timeout": 10]]])
            hooks[managed.event] = event
        }
        root["hooks"] = hooks

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL)
        let events = managedHooks.map(\.event).joined(separator: " + ")
        return "installed \(events) hooks → \(settingsURL.path)"
    }

    /// Writes the /remember skill from its embedded template.
    private static func installSkills() throws -> [String] {
        let fm = FileManager.default
        let skillsDir = claudeDir.appendingPathComponent("skills", isDirectory: true)
        var lines: [String] = []
        for (name, body) in [("remember", rememberSkill)] {
            let dir = skillsDir.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
            lines.append("installed /\(name) skill → \(dir.path)/SKILL.md")
        }
        return lines
    }
}

struct SetupError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
