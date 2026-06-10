import SwiftUI

/// First-run onboarding (P1 #10): the welcome sheet a brand-new user sees once.
/// Explains Engram in a line, offers the two install actions, points at
/// `/remember`, and states the privacy posture (#13). "Done"/"Skip" both set
/// `engram.hasOnboarded` so it never reappears.
struct WelcomeSheet: View {
    let model: EngramModel
    @Binding var hasOnboarded: Bool
    @Environment(\.dismiss) private var dismiss

    /// Onboarding presents its own install sheet (nested) rather than reusing
    /// `model.pendingInstall`, so the welcome sheet stays up underneath and the
    /// two bindings can't fight over the same presentation slot.
    @State private var pendingInstall: InstallKind?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    installSteps
                    Divider()
                    usageStep
                    Divider()
                    privacyNote
                }
                .padding(Space.xl)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
        .sheet(item: $pendingInstall) { kind in
            InstallSheet(kind: kind, model: model)
        }
    }

    private var header: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Welcome to Engram")
                .font(.title2.weight(.semibold))
            Text("A local-first memory for Claude Code — store what matters, recall it later.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(Space.xl)
    }

    private var installSteps: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("GET SET UP").font(Typo.eyebrow).foregroundStyle(.secondary)
            Button {
                pendingInstall = .cli
            } label: {
                Label("Install CLI", systemImage: "terminal")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Button {
                pendingInstall = .integration
            } label: {
                Label("Install Hooks & Skills", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Text("Install the CLI first, then Hooks & Skills so the recall hook can find it.")
                .font(Typo.meta)
                .foregroundStyle(.secondary)
        }
    }

    private var usageStep: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("THEN, IN CLAUDE CODE").font(Typo.eyebrow).foregroundStyle(.secondary)
            (Text("Type ") + Text("/remember").font(.body.monospaced().weight(.semibold)) + Text(" to save something worth keeping. Engram recalls relevant memories automatically on each prompt."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label("Privacy", systemImage: "lock.shield")
                .font(Typo.eyebrow)
                .foregroundStyle(.secondary)
            Text(PrivacyCopy.summary)
                .font(Typo.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip") { finish() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Done") { finish() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(Space.l)
    }

    private func finish() {
        hasOnboarded = true
        dismiss()
    }
}

#if DEBUG
#Preview {
    WelcomeSheet(model: .preview(), hasOnboarded: .constant(false))
}
#endif
