import SwiftUI
import UniFiBackupKit

@main
struct UnifiBackupInspectorApp: App {
    @State private var controller = InspectorController()

    var body: some Scene {
        WindowGroup {
            InspectorWindow(controller: controller)
                .onOpenURL { url in
                    Task { await controller.open(url: url) }
                }
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    Task { await controller.openWithPanel() }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Backup") {
                Button("Export Selection…") {
                    controller.showExportSheet = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(controller.selectedNodes.isEmpty)

                Divider()

                Button("Toggle Select Mode") {
                    controller.selectionMode.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Button("Load Statistics…") {
                    Task { await controller.loadStatistics() }
                }
                .disabled(controller.backup == nil || controller.backup?.statsLoaded == true)
            }
        }
    }
}
