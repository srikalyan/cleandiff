import AppKit
import SwiftUI

// Entry point for SPM executable
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Create the SwiftUI app
let cleanDiffApp = CleanDiffApp()
cleanDiffApp.body.windowGroup

// This is needed to properly initialize AppKit when launched as an executable
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

// Run the application
app.run()
