import AppKit
import Foundation

/// Detects launches from a mounted disk image (which silently break Sparkle
/// updates) and offers to move the app to /Applications and relaunch.
enum InstallLocation {
    @MainActor
    static func offerMoveIfLaunchedFromDMG() {
        #if DEBUG
        return
        #else
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasPrefix("/Volumes/"), bundlePath.hasSuffix(".app") else { return }

        let alert = NSAlert()
        alert.messageText = "Move Kawenreel to Applications"
        alert.informativeText = "Kawenreel is running from the disk image. Move it to Applications to enable automatic updates."
        alert.addButton(withTitle: "Move & Relaunch")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let dest = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent((bundlePath as NSString).lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: bundlePath), to: dest)
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not move the app"
            failure.informativeText = "Drag Kawenreel to Applications in Finder instead. (\(error.localizedDescription))"
            failure.runModal()
        }
        #endif
    }
}
