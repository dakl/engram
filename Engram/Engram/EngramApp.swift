//
//  EngramApp.swift
//  Engram
//
//  Created by Daniel Klevebring on 2026-06-01.
//

import Sparkle
import SwiftUI

@main
struct EngramApp: App {
    /// Owns the Sparkle updater for the app's lifetime. `startingUpdater: true`
    /// begins the scheduled background checks immediately (cadence + feed come
    /// from the SU* Info.plist keys; see ADR 0010).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// The app owns the model so the menu-bar `.commands` can drive the same
    /// instance the window renders (lens switching, refresh). The window publishes
    /// it as a `@FocusedValue` so commands reach whichever window is key.
    @State private var model = EngramModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .focusedSceneValue(\.engramModel, model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            EngramCommands()
        }

        Settings {
            SettingsView(updater: updaterController.updater, model: model)
        }
    }
}

/// Menu-bar commands that drive the focused window's model: a View menu with
/// ⌘1–4 lens switching + ⌘R refresh, and a Help menu linking to the project.
private struct EngramCommands: Commands {
    @FocusedValue(\.engramModel) private var model

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            ForEach(Array(EngramModel.Section.visibleCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { model?.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(model == nil)
            }
            Divider()
            Button("Refresh") { model?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model == nil)
        }
        CommandGroup(replacing: .help) {
            Link("Engram on GitHub", destination: URL(string: "https://github.com/dakl/engram")!)
        }
    }
}

/// Carries the key window's `EngramModel` to the menu-bar commands via the focus
/// system, so a `Commands` struct (which can't hold view state) can act on it.
private struct EngramModelFocusedKey: FocusedValueKey {
    typealias Value = EngramModel
}

extension FocusedValues {
    var engramModel: EngramModel? {
        get { self[EngramModelFocusedKey.self] }
        set { self[EngramModelFocusedKey.self] = newValue }
    }
}
