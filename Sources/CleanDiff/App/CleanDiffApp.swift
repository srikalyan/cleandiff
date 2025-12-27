import SwiftUI
import AppKit

/// Shared app state that's accessible to both AppDelegate and SwiftUI views
@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var showNewComparisonSheet = false
    @Published var comparisons: [Comparison] = []
    @Published var selectedComparisonId: UUID?

    private init() {}

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true

        if panel.runModal() == .OK {
            let urls = panel.urls
            if urls.count == 2 {
                addComparison(left: urls[0], right: urls[1])
            }
        }
    }

    func addComparison(left: URL, right: URL, base: URL? = nil, merged: URL? = nil) {
        let comparison = Comparison(
            leftURL: left,
            rightURL: right,
            baseURL: base,
            mergedURL: merged
        )
        comparisons.append(comparison)
        selectedComparisonId = comparison.id
        print("[AppState] Added comparison: \(comparison.title), total: \(comparisons.count)")
    }

    func closeComparison(_ id: UUID) {
        comparisons.removeAll { $0.id == id }
        if selectedComparisonId == id {
            selectedComparisonId = comparisons.first?.id
        }
    }
}

/// AppDelegate that manually creates the window for command-line launches
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    /// Track view models for unsaved changes check
    var viewModels: [UUID: ComparisonViewModel] = [:]

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set activation policy BEFORE app finishes launching
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] applicationDidFinishLaunching")

        // Parse command-line arguments
        let args = Array(CommandLine.arguments.dropFirst())
        print("[AppDelegate] Arguments: \(args)")

        if args.count >= 2 {
            handleCommandLineArgs(args)
        }

        // Create the window manually
        createMainWindow()

        // Activate the app
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func createMainWindow() {
        print("[AppDelegate] Creating main window...")

        let contentView = ContentView()
            .environmentObject(AppState.shared)

        let hostingController = NSHostingController(rootView: contentView)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window?.title = "CleanDiff"
        window?.contentViewController = hostingController
        window?.center()
        window?.setFrameAutosaveName("CleanDiff Main Window")
        window?.delegate = self  // Set window delegate for close confirmation
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()

        print("[AppDelegate] Window created and displayed")
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Check for unsaved changes
        let hasUnsaved = viewModels.values.contains { $0.hasUnsavedChanges }

        if hasUnsaved {
            let alert = NSAlert()
            alert.messageText = "You have unsaved changes"
            alert.informativeText = "Do you want to save your changes before closing?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save All")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:  // Save All
                Task {
                    for viewModel in self.viewModels.values where viewModel.hasUnsavedChanges {
                        try? await viewModel.saveAll()
                    }
                    await MainActor.run {
                        sender.close()
                        NSApplication.shared.terminate(nil)
                    }
                }
                return false  // Don't close yet, we'll close after saving

            case .alertSecondButtonReturn:  // Don't Save
                return true  // Allow close without saving

            default:  // Cancel
                return false  // Don't close
            }
        }

        return true  // No unsaved changes, allow close
    }

    /// Handle command-line arguments for git difftool/mergetool
    private func handleCommandLineArgs(_ args: [String]) {
        switch args.count {
        case 2:
            // Two-way diff: cleandiff <left> <right>
            let leftURL = URL(fileURLWithPath: args[0])
            let rightURL = URL(fileURLWithPath: args[1])
            AppState.shared.addComparison(left: leftURL, right: rightURL)

        case 3:
            // Three-way merge without output: cleandiff <base> <left> <right>
            let baseURL = URL(fileURLWithPath: args[0])
            let leftURL = URL(fileURLWithPath: args[1])
            let rightURL = URL(fileURLWithPath: args[2])
            AppState.shared.addComparison(left: leftURL, right: rightURL, base: baseURL)

        case 4:
            // Git mergetool format: cleandiff <base> <left> <right> <merged>
            let baseURL = URL(fileURLWithPath: args[0])
            let leftURL = URL(fileURLWithPath: args[1])
            let rightURL = URL(fileURLWithPath: args[2])
            let mergedURL = URL(fileURLWithPath: args[3])
            AppState.shared.addComparison(left: leftURL, right: rightURL, base: baseURL, merged: mergedURL)

        default:
            if args.count > 0 {
                print("""
                Usage: cleandiff <left> <right>              # Two-way diff
                       cleandiff <base> <left> <right>       # Three-way merge
                       cleandiff <base> <left> <right> <out> # Git mergetool

                Git configuration:
                  git config --global diff.tool cleandiff
                  git config --global difftool.cleandiff.cmd 'cleandiff "$LOCAL" "$REMOTE"'

                  git config --global merge.tool cleandiff
                  git config --global mergetool.cleandiff.cmd 'cleandiff "$BASE" "$LOCAL" "$REMOTE" "$MERGED"'
                  git config --global mergetool.cleandiff.trustExitCode true
                """)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            createMainWindow()
        }
        return true
    }
}

// Use NSApplicationMain-style entry point for reliable window creation
@main
struct CleanDiffAppMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // Set up the main menu
        setupMainMenu()

        app.run()
    }

    @MainActor
    static func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About CleanDiff", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Preferences...", action: nil, keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit CleanDiff", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        let newComparisonItem = NSMenuItem(title: "New Comparison", action: #selector(AppDelegate.newComparison), keyEquivalent: "n")
        fileMenu.addItem(newComparisonItem)

        fileMenu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Files...", action: #selector(AppDelegate.openFiles), keyEquivalent: "o")
        fileMenu.addItem(openItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }
}

// Menu action extensions
extension AppDelegate {
    @objc func newComparison() {
        AppState.shared.showNewComparisonSheet = true
    }

    @objc func openFiles() {
        AppState.shared.openFilePicker()
    }
}
