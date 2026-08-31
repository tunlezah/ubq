import SwiftUI
import UniFiBackupKit

extension Notification.Name {
    /// Posted by the ⌘F menu command; observed by the outline's search field.
    static let focusSearch = Notification.Name("focusSearch")
}

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

                Menu("Open Recent") {
                    if controller.recentFiles.isEmpty {
                        Button("No Recent Files") {}.disabled(true)
                    } else {
                        ForEach(controller.recentFiles, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                Task { await controller.open(url: url) }
                            }
                        }
                        Divider()
                        Button("Clear Menu") {
                            RecentFilesStore.clear()
                            controller.recentFiles = []
                        }
                    }
                }
            }

            CommandGroup(after: .textEditing) {
                Button("Find") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(controller.backup == nil)
            }

            CommandMenu("Backup") {
                Button("Export Selection…") {
                    controller.showExportSheet = true
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(controller.selectedNodes.isEmpty)

                Button("Toggle Select Mode") {
                    controller.selectionMode.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(controller.backup == nil)

                Divider()

                Button("Compare Backups…") {
                    controller.showDiff = true
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(controller.backup == nil)

                Button("Configuration Audit…") {
                    controller.showAudit = true
                }
                .disabled(controller.backup == nil)

                Button("Restore Advisor…") {
                    controller.showRestoreAdvisor = true
                }
                .disabled(controller.backup == nil)

                Divider()

                Button("Statistics…") {
                    controller.showStatistics = true
                }
                .disabled(controller.backup == nil)

                Button("Load Statistics…") {
                    Task { await controller.loadStatistics() }
                }
                .disabled(controller.backup == nil || controller.backup?.statsLoaded == true)

                Button("Archive Files…") {
                    controller.showFiles = true
                }
                .disabled(controller.backup == nil)

                Button("Secret Inventory…") {
                    controller.showSecretInventory = true
                }
                .disabled(controller.backup == nil)
            }
        }
    }
}
