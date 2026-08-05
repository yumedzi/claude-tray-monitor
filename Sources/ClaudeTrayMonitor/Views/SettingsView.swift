import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    let onDataDirChange: () -> Void

    @AppStorage("pollIntervalMinutes") private var pollIntervalMinutes: Double = 5
    @AppStorage("refreshOnClick") private var refreshOnClick: Bool = true
    @AppStorage("themeMode") private var themeMode: String = "system"
    @AppStorage("showPercentages") private var showPercentages: Bool = true
    @AppStorage("showLabels") private var showLabels: Bool = true
    @AppStorage("warnThreshold") private var warnThreshold: Double = 80
    @AppStorage("errorThreshold") private var errorThreshold: Double = 90
    @AppStorage("bar1Field") private var bar1Field: String = "five_hour"
    @AppStorage("bar2Field") private var bar2Field: String = "seven_day"
    @AppStorage("barOrientation") private var barOrientation: String = "vertical"
    @AppStorage("desktopDataDir") private var desktopDataDir: String = ""
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    init(store: UsageStore, onDataDirChange: @escaping () -> Void = {}) {
        self.store = store
        self.onDataDirChange = onDataDirChange
    }

    var body: some View {
        Form {
            Section("Polling") {
                LabeledContent("Interval") {
                    HStack(spacing: 10) {
                        Slider(value: $pollIntervalMinutes, in: 1...60, step: 1)
                        Text("\(Int(pollIntervalMinutes)) min")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Text("The app makes one network request per interval. Be kind to the API — 5–15 minutes is usually enough.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Refresh when tray icon is clicked", isOn: $refreshOnClick)
            }

            Section("Tray bars") {
                Picker("Left bar", selection: $bar1Field) {
                    ForEach(fields, id: \.self) { field in
                        Text(AppSettings.displayName(for: field)).tag(field)
                    }
                }
                Picker("Right bar", selection: $bar2Field) {
                    ForEach(fields, id: \.self) { field in
                        Text(AppSettings.displayName(for: field)).tag(field)
                    }
                }
                Picker("Bar orientation", selection: $barOrientation) {
                    Text("Vertical").tag("vertical")
                    Text("Horizontal").tag("horizontal")
                }
                Toggle("Show percentages on bars", isOn: $showPercentages)
                if showPercentages {
                    Toggle("Show labels (s/w) on bars", isOn: $showLabels)
                }
            }

            Section("Colors") {
                LabeledContent("Warning at") {
                    HStack(spacing: 10) {
                        Slider(value: $warnThreshold, in: 1...100, step: 1)
                        Text("\(Int(warnThreshold))%")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                LabeledContent("Error at") {
                    HStack(spacing: 10) {
                        Slider(value: $errorThreshold, in: 1...100, step: 1)
                        Text("\(Int(errorThreshold))%")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Text("Bars turn orange past the warning threshold and red past the error threshold.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Theme", selection: $themeMode) {
                    Text("Follow system").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Claude Desktop") {
                TextField("~/Library/Application Support/Claude-Personal", text: $desktopDataDir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                HStack {
                    Text(desktopDirCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Browse…") { chooseDirectory() }
                }
            }
            .onChange(of: desktopDataDir) { _, _ in
                onDataDirChange()
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        applyLaunchAtLogin(enabled)
                    }
            }

            Section {
                HStack {
                    Spacer()
                    Text("Claude Tray Monitor 0.4.0 — (c) Viktor Moyseyenko, 2026")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
        .padding(.bottom, 4)
    }

    private var fields: [String] {
        let available = store.orderedFields
        return available.isEmpty ? ["five_hour", "seven_day"] : available
    }

    private var desktopDirCaption: String {
        guard !desktopDataDir.isEmpty else {
            if let resolved = DesktopSession.resolvedDirectory()?.path {
                return "Auto-detected: \(tildize(resolved)). The desktop session cookie is read from there."
            }
            return "Where Claude Desktop stores its profile. Leave empty to auto-detect."
        }
        if let resolved = DesktopSession.resolvedDirectory()?.path, isConfiguredDir(resolved) {
            return "Using \(tildize(resolved)). Refresh to apply."
        }
        return "Custom directory not found — falling back to auto-detection."
    }

    private func isConfiguredDir(_ resolved: String) -> Bool {
        let expanded = expand(desktopDataDir)
        return resolved == expanded
            || resolved == (expanded as NSString).appendingPathComponent("Default")
    }

    private func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func tildize(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select the Claude Desktop profile directory (contains the Cookies file)"
        if panel.runModal() == .OK, let url = panel.url {
            desktopDataDir = url.path
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("launch at login failed: \(error)")
        }
    }
}