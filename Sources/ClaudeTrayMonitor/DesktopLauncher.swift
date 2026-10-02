import AppKit

/// Starts Claude Desktop on a given profile folder, like
/// `open -n -a Claude --args --user-data-dir="…/Claude-Personal"`.
@MainActor
enum DesktopLauncher {
    static let bundleId = "com.anthropic.claudefordesktop"

    static func launch(profileDir: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            RequestLog.write("launch desktop: Claude.app not found")
            showError("Claude Desktop is not installed.")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // The default profile is the normal app: just open/activate it. Other profiles need their own instance.
        let isDefault = profileDir == ProfileLocator.defaultProfileDir.path
        if !isDefault {
            config.createsNewApplicationInstance = true
            config.arguments = ["--user-data-dir=\(profileDir)"]
        }
        RequestLog.write("launch desktop: \((profileDir as NSString).lastPathComponent)")
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            guard let error else { return }
            Task { @MainActor in
                RequestLog.write("launch desktop failed: \(error.localizedDescription)")
                showError(error.localizedDescription)
            }
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't launch Claude Desktop"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
