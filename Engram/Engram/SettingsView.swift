import Combine
import EngramCore
import Sparkle
import SwiftUI

/// Bridges Sparkle's `SPUUpdater` into SwiftUI. `canCheckForUpdates` is the one
/// property Sparkle documents as KVO-compliant; we mirror it so the "Check Now"
/// affordances disable themselves while a check is already running.
final class UpdaterViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

/// The menu item placed under the app menu ("Engram ▸ Check for Updates…"),
/// the standard macOS location users expect.
struct CheckForUpdatesView: View {
    private let updater: SPUUpdater
    @ObservedObject private var viewModel: UpdaterViewModel

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = ObservedObject(wrappedValue: UpdaterViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// The app's Settings window (⌘,): a General pane (embedding maintenance +
/// privacy) and the Sparkle-backed Updates pane. (The old General pane that
/// described removed lenses was deleted — ADR 0019; this one holds real actions.)
struct SettingsView: View {
    let updater: SPUUpdater
    let model: EngramModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            UpdatesSettingsView(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 480)
        .padding()
    }
}

/// General preferences: the on-device embedding model status + a manual re-index
/// (the in-session recovery from a degraded launch, ADR 0012), and the privacy
/// posture.
struct GeneralSettingsView: View {
    let model: EngramModel

    var body: some View {
        Form {
            Section("Embeddings") {
                LabeledContent("Recall model",
                               value: model.usingFallbackEmbedder ? "Fallback (reduced quality)" : "On-device contextual")
                Button { model.reindex() } label: {
                    if model.isReindexing {
                        Label("Re-indexing…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Text("Re-index all memories")
                    }
                }
                .disabled(model.isReindexing)
                Text("Rebuilds the on-device embedding index for every memory. Use this if recall looks off, or to pick up the contextual model once its assets have downloaded — no restart needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text(PrivacyCopy.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Updates preferences: current version, the automatic-check toggle, when we
/// last looked, and a manual check — mirroring the codez/papershelf pane.
struct UpdatesSettingsView: View {
    private let updater: SPUUpdater
    @ObservedObject private var viewModel: UpdaterViewModel
    @State private var automaticallyChecks: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = ObservedObject(wrappedValue: UpdaterViewModel(updater: updater))
        _automaticallyChecks = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Form {
            LabeledContent("Current version", value: appVersion)

            Toggle("Automatically check for updates", isOn: $automaticallyChecks)
                .onChange(of: automaticallyChecks) { _, newValue in
                    updater.automaticallyChecksForUpdates = newValue
                }

            if let lastCheck = updater.lastUpdateCheckDate {
                LabeledContent("Last checked",
                               value: lastCheck.formatted(date: .abbreviated, time: .shortened))
            }

            Button("Check Now") { updater.checkForUpdates() }
                .disabled(!viewModel.canCheckForUpdates)
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
