import SwiftUI

/// Receives files opened from Finder, the Dock icon or `open -a`, and brings the main window back.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handler: (([URL]) -> Void)?
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler { handler(urls) } else { pending += urls }
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func connect(_ handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        if !pending.isEmpty { handler(pending); pending = [] }
    }

    /// SwiftUI opens windows only from views, so run the Window menu's ⌘0 command.
    private func showMainWindow() {
        DispatchQueue.main.async {
            for item in NSApp.mainMenu?.items ?? [] {
                guard let menu = item.submenu,
                      let index = menu.items.firstIndex(where: { $0.keyEquivalent == "0" && $0.title == "Waifu2x-Mac" })
                else { continue }
                menu.performActionForItem(at: index)
                return
            }
        }
    }
}

private struct ShowMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Waifu2x-Mac") { openWindow(id: "workspace") }.keyboardShortcut("0")
    }
}

@main
struct Waifu2xMac: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var workspace = Workspace()

    var body: some Scene {
        Window("Waifu2x-Mac", id: "workspace") {
            WorkspaceView(workspace: workspace, delegate: delegate)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1300, height: 810)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…", action: workspace.chooseFiles)
                    .keyboardShortcut("o").disabled(workspace.isExporting)
                Button("Add Folder…", action: workspace.chooseInputFolder)
                    .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(workspace.isExporting)
                Button("Choose Output Folder…", action: workspace.chooseFolder)
                    .keyboardShortcut("o", modifiers: [.command, .option]).disabled(workspace.isExporting)
                Divider()
                Button("Export", action: workspace.requestExport)
                    .keyboardShortcut("e").disabled(!workspace.canRequestExport).help(workspace.exportHelp)
                Button("Stop", action: workspace.stop)
                    .keyboardShortcut(".").disabled(!workspace.isExporting || workspace.isStopping)
                Menu("Recent Exports") {
                    ForEach(workspace.recent, id: \.self) { url in
                        Button(url.lastPathComponent) { NSWorkspace.shared.open(url) }
                    }
                    Divider()
                    Button("Clear Menu", action: workspace.clearRecent).disabled(workspace.recent.isEmpty)
                }
                Divider()
                Button("Clear Batch", action: workspace.startOver)
                    .disabled(workspace.jobs.isEmpty || workspace.isExporting)
            }
            CommandGroup(after: .sidebar) {
                Button(workspace.inspectorPresented ? "Hide Inspector" : "Show Inspector", action: workspace.toggleInspector)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Fit") { workspace.showsDetail = false }
                    .keyboardShortcut("1").disabled(!workspace.detailAvailable || workspace.isGeneratingAI || workspace.isExporting)
                Button("Actual Pixels (1:1)") { workspace.showsDetail = true }
                    .keyboardShortcut("2").disabled(!workspace.detailAvailable || workspace.isGeneratingAI || workspace.isExporting)
                Button("Preview AI", action: workspace.generateAIPreview)
                    .keyboardShortcut("r").disabled(!workspace.canPreviewAI)
            }
            CommandGroup(before: .windowList) { ShowMainWindowButton() }
            CommandGroup(replacing: .help) {
                Button("Waifu2x-Mac Help") {
                    if let url = Bundle.main.url(forResource: "OptionalEngines", withExtension: "md") {
                        NSWorkspace.shared.open(url)
                    }
                }.disabled(Bundle.main.url(forResource: "OptionalEngines", withExtension: "md") == nil)
            }
        }
        Settings {
            SettingsView(workspace: workspace)
        }
    }
}
