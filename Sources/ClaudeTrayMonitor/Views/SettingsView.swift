import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var accounts: AccountStore
    let onSelectAccount: (AccountSelection) -> Void
    var onAccountsRenamed: () -> Void = {}

    @AppStorage("autoRefresh") private var autoRefresh: Bool = true
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
    @AppStorage("showMonthlySpend") private var showMonthlySpend: Bool = true
    @AppStorage("showPaceMarkers") private var showPaceMarkers: Bool = true
    @State private var addFolderError: String?
    @State private var renamingId: String?
    @State private var renameText = ""
    @State private var showHidden = false
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    var body: some View {
        Form {
            Section("Polling") {
                Toggle("Auto refresh", isOn: $autoRefresh)
                if autoRefresh {
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
                } else {
                    Text("No background requests. Usage refreshes on launch, when the tray icon is clicked (if enabled below), or via right-click ▸ Check Now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Refresh when tray icon is clicked", isOn: $refreshOnClick)
            }

            Section("Tray bars") {
                Toggle("Show monthly spend instead of usage bars", isOn: $showMonthlySpend)
                if spendAvailable {
                    Text("Enterprise detected — Claude reports monthly spend instead of usage windows. The tray shows current spend over the monthly limit in a single column. Settings marked (subscription) apply to usage bars only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker(subscriptionLabel("Left bar"), selection: $bar1Field) {
                    ForEach(fields, id: \.self) { field in
                        Text(AppSettings.displayName(for: field)).tag(field)
                    }
                }
                Picker(subscriptionLabel("Right bar"), selection: $bar2Field) {
                    ForEach(fields, id: \.self) { field in
                        Text(AppSettings.displayName(for: field)).tag(field)
                    }
                }
                Picker("Bar orientation", selection: $barOrientation) {
                    Text("Vertical").tag("vertical")
                    Text("Horizontal").tag("horizontal")
                }
                .pickerStyle(.segmented)
                Toggle("Show percentages on bars", isOn: $showPercentages)
                Toggle("Show pace markers (ideal even usage)", isOn: $showPaceMarkers)
                Text("Weekly bars get a faint tick per day (1/7 of the limit each); monthly spend gets one tick at today's ideal spend. Fill past the tick = ahead of pace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showPercentages {
                    Toggle(subscriptionLabel("Show labels (s/w) on bars"), isOn: $showLabels)
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

            Section {
                accountRow(
                    title: "Auto",
                    detail: autoDetail,
                    selection: .auto
                )
                ForEach(accounts.visibleAccounts) { account in
                    accountRow(
                        title: accounts.title(for: account),
                        detail: accountDetail(account),
                        selection: AccountSelection(id: account.id),
                        manageId: account.id,
                        defaultName: account.organization.name
                    )
                }
                ForEach(issueProfiles.filter { !accounts.isHidden(issueId($0)) }, id: \.dir) { profile in
                    HStack {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name)
                            Text("\(tildize(profile.dir)) · \(accounts.profileIssues[profile.dir] ?? "unavailable")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        hideButton(issueId(profile))
                    }
                }
                if !accounts.isHidden(AccountSelection.oauthId) {
                    accountRow(
                        title: accounts.label(for: .oauth),
                        detail: "Keychain credentials used by the claude CLI",
                        selection: .oauth,
                        manageId: AccountSelection.oauthId,
                        defaultName: "Claude Code login (OAuth)"
                    )
                }
                if !hiddenRows.isEmpty {
                    DisclosureGroup("Hidden (\(hiddenRows.count))", isExpanded: $showHidden) {
                        ForEach(hiddenRows, id: \.id) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title).foregroundStyle(.secondary)
                                    Text(row.detail)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button("Show") { accounts.setHidden(row.id, false) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Account")
                    Spacer()
                    if accounts.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            accounts.reload(force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Rescan accounts")
                    }
                }
            }

            Section("Manual Desktop profiles") {
                ForEach(accounts.profiles.filter(\.isManual).map(\.dir), id: \.self) { dir in
                    HStack {
                        Text(tildize(dir))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            removeManual(dir)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this profile")
                    }
                }
                HStack {
                    Button("Add Desktop profile folder…") { chooseDirectory() }
                    Spacer()
                    if let addFolderError {
                        Text(addFolderError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Text("Folders found automatically: ~/Library/Application Support/Claude and Claude-*. Add a folder here for profiles kept elsewhere (it must contain a Cookies file).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("Claude Tray Monitor 0.10.0 — © Viktor Moyseyenko, 2026")
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
        var available = store.orderedFields
        if !available.contains("monthly_spend") {
            available.append("monthly_spend")
        }
        return available.isEmpty ? ["five_hour", "seven_day"] : available
    }

    private var spendAvailable: Bool {
        store.snapshot.spend != nil
    }

    private func subscriptionLabel(_ base: String) -> String {
        spendAvailable ? "\(base) (subscription)" : base
    }

    private var autoDetail: String {
        if let active = accounts.activeProfileDir {
            return "Follows the running Claude Desktop — now \(tildize(active))"
        }
        return "Follows the running Claude Desktop, else the first signed-in profile"
    }

    private var issueProfiles: [DesktopSession.Profile] {
        accounts.profiles.filter { accounts.profileIssues[$0.dir] != nil }
    }

    private func accountDetail(_ account: Account) -> String {
        var parts: [String] = []
        if accounts.customName(for: account.id) != nil { parts.append(account.organization.name) }
        parts.append(tildize(account.profile.dir))
        if account.profile.isManual { parts.append("added manually") }
        return parts.joined(separator: " · ")
    }

    private func issueId(_ profile: DesktopSession.Profile) -> String { "profile:\(profile.dir)" }

    private struct HiddenRow { let id: String; let title: String; let detail: String }

    private var hiddenRows: [HiddenRow] {
        var rows = accounts.hiddenAccounts.map {
            HiddenRow(id: $0.id, title: accounts.title(for: $0), detail: tildize($0.profile.dir))
        }
        rows += issueProfiles.filter { accounts.isHidden(issueId($0)) }.map {
            HiddenRow(id: issueId($0), title: $0.name, detail: "\(tildize($0.dir)) · \(accounts.profileIssues[$0.dir] ?? "unavailable")")
        }
        if accounts.isHidden(AccountSelection.oauthId) {
            rows.append(HiddenRow(id: AccountSelection.oauthId, title: accounts.label(for: .oauth), detail: "Keychain credentials used by the claude CLI"))
        }
        return rows
    }

    private func hideButton(_ id: String) -> some View {
        Button {
            if AccountSelection(id: accounts.selectionId).matches(id) {
                onSelectAccount(.auto)
            }
            accounts.setHidden(id, true)
        } label: {
            Image(systemName: "eye.slash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Hide from the tray menu and this list")
    }

    private func accountRow(
        title: String,
        detail: String,
        selection: AccountSelection,
        manageId: String? = nil,
        defaultName: String = ""
    ) -> some View {
        let isSelected = AccountSelection(id: accounts.selectionId).matches(selection.id)
        return HStack(spacing: 6) {
            selectableRow(title: title, detail: detail, selection: selection, isSelected: isSelected)
            if let manageId {
                Button {
                    renameText = accounts.customName(for: manageId) ?? defaultName
                    renamingId = manageId
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Rename")
                .popover(isPresented: Binding(
                    get: { renamingId == manageId },
                    set: { if !$0 { renamingId = nil } }
                )) {
                    renameEditor(id: manageId, defaultName: defaultName)
                }
                hideButton(manageId)
            }
        }
    }

    private func renameEditor(id: String, defaultName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display name").font(.headline)
            TextField(defaultName, text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { commitRename(id) }
            HStack {
                Button("Reset") {
                    accounts.rename(id, to: "")
                    renamingId = nil
                }
                .disabled(accounts.customName(for: id) == nil)
                Spacer()
                Button("Cancel") { renamingId = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitRename(id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func commitRename(_ id: String) {
        accounts.rename(id, to: renameText)
        renamingId = nil
        onAccountsRenamed()
    }

    private func selectableRow(title: String, detail: String, selection: AccountSelection, isSelected: Bool) -> some View {
        Button {
            onSelectAccount(selection)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func removeManual(_ dir: String) {
        if case let .pinned(pinnedDir, _) = AccountSelection(id: accounts.selectionId), pinnedDir == dir {
            onSelectAccount(.auto)
        }
        accounts.removeManualProfile(dir)
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
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard DesktopSession.hasCookies(dir: url.path) else {
            addFolderError = "No Cookies file in that folder"
            return
        }
        addFolderError = nil
        accounts.addManualProfile(url.path)
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