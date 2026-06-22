import SwiftUI

/// The two install actions the app can perform, with the copy + CLI arguments
/// each one needs.
enum InstallKind: Identifiable, Equatable {
    case cli
    case integration

    var id: String { self == .cli ? "cli" : "integration" }

    var title: String {
        switch self {
        case .cli: return "Install the engram CLI"
        case .integration: return "Install Hooks & Skills"
        }
    }

    var systemImage: String {
        switch self {
        case .cli: return "terminal"
        case .integration: return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .cli: return .blue
        case .integration: return .purple
        }
    }

    var summary: String {
        switch self {
        case .cli:
            return "Symlinks the bundled engram command-line tool into your PATH."
        case .integration:
            return "Sets up Engram's Claude Code integration."
        }
    }

    var bullets: [String] {
        switch self {
        case .cli:
            return [
                "Symlinks /usr/local/bin/engram to the bundled CLI",
                "Lets Claude Code and your terminal run engram",
                "Asks for your password to write there",
            ]
        case .integration:
            return [
                "Adds a UserPromptSubmit recall hook to ~/.claude/settings.json (backed up first)",
                "Installs the /remember skill",
                "Idempotent — safe to run again",
                "Tip: install the CLI first so the hook can find engram",
            ]
        }
    }

    /// CLI install writes to root-owned /usr/local/bin, so it goes through the
    /// privileged helper (ADR 0022); integration install only edits files under
    /// the user's home and shells out to the bundled CLI.
    var usesPrivilegedHelper: Bool {
        switch self {
        case .cli: return true
        case .integration: return false
        }
    }

    var arguments: [String] {
        switch self {
        case .cli: return ["install"]
        case .integration: return ["setup"]
        }
    }
}

/// Confirmation + progress + result sheet for an install action.
struct InstallSheet: View {
    let kind: InstallKind
    let model: EngramModel
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .confirm

    enum Phase: Equatable {
        case confirm
        case running
        case done(output: String, success: Bool)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.systemImage)
                .font(.title)
                .foregroundStyle(kind.tint)
                .frame(width: 52, height: 52)
                .background(kind.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.headline)
                Text(kind.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .confirm:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(kind.bullets, id: \.self) { bullet in
                    Label {
                        Text(bullet)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(kind.tint)
                    }
                    .font(.callout)
                }
            }
        case .running:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        case let .done(output, success):
            VStack(alignment: .leading, spacing: 12) {
                Label(success ? "Done" : "Something went wrong",
                      systemImage: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(success ? .green : .orange)
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            switch phase {
            case .confirm:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") { run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(kind.tint)
            case .running:
                Button("Install") {}.disabled(true).buttonStyle(.borderedProminent)
            case .done:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private func run() {
        phase = .running
        Task {
            if kind.usesPrivilegedHelper {
                switch await PrivilegedInstaller.install() {
                case let .installed(message):
                    phase = .done(output: message, success: true)
                    model.refresh()
                case .cancelled:
                    phase = .confirm
                case let .failed(message):
                    phase = .done(output: message + "\n\nOr install it from Terminal:\n    sudo "
                        + EngramModel.bundledEngramPath + " install", success: false)
                }
            } else {
                let result = await Task.detached(priority: .userInitiated) {
                    EngramModel.runBundledEngram(kind.arguments)
                }.value
                phase = .done(output: result.output, success: result.success)
            }
        }
    }
}

#Preview("Confirm — CLI") {
    InstallSheet(kind: .cli, model: .preview())
}

#Preview("Confirm — Hooks & Skills") {
    InstallSheet(kind: .integration, model: .preview())
}
