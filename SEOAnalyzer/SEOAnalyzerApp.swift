import SwiftUI

@main
struct SEOAnalyzerApp: App {
    var body: some Scene {
        WindowGroup("SEO-Анализатор") {
            ContentView()
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") {
                    Task { await UpdateService.shared.check(silent: false) }
                }
                .keyboardShortcut("u", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
