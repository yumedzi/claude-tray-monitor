import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusView: StatusItemView?
    private var panel: NSPanel?
    private var panelHost: NSHostingView<PopoverView>?
    private var settingsWindow: NSWindow?
    private var lastInterval: Double = 5
    private var lastAutoRefresh = true

    private let store = UsageStore()
    private let accounts = AccountStore()
    private var poller: Poller?

    private var themeObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppSettings.registerDefaults()
        lastInterval = AppSettings.pollIntervalMinutes
        lastAutoRefresh = AppSettings.autoRefresh

        let poller = Poller(store: store)
        self.poller = poller

        setupStatusItem()
        setupPanel()
        installObservers()

        poller.start()

        store.onChange = { [weak self] in
            self?.storeDidChange()
        }

        Task {
            await poller.refresh(force: true)
        }
        accounts.reload(force: true)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 38)
        let view = StatusItemView(frame: NSRect(x: 0, y: 0, width: 38, height: 24))
        view.store = store
        view.onClick = { [weak self] in self?.handleLeftClick() }
        view.onRightClick = { [weak self] event in self?.handleRightClick(event) }
        view.autoresizingMask = [.width, .height]
        if let button = item.button {
            view.frame = button.bounds
            button.addSubview(view)
        }
        statusItem = item
        statusView = view
        updateStatusItemWidth()
        applyThemeOverride()
        storeDidChange()
    }

    private func updateStatusItemWidth() {
        guard let statusItem else { return }
        let show = AppSettings.showPercentages
        let horizontal = AppSettings.barOrientation == "horizontal"
        let width: CGFloat
        if StatusItemView.spendActive(snapshot: store.snapshot) {
            if horizontal {
                width = show ? 26 : 18
            } else if show, let spend = store.snapshot.spend {
                width = StatusItemView.spendVerticalWidth(
                    used: UsageParser.formatDollarsCompact(spend.used),
                    limit: UsageParser.formatDollarsCompact(spend.limit)
                )
            } else {
                width = 18
            }
        } else if show {
            width = horizontal ? 28 : 30
        } else {
            width = horizontal ? 20 : 14
        }
        statusItem.length = width
        if let button = statusItem.button, let view = statusView, view.frame.width != button.bounds.width {
            view.frame = button.bounds
        }
    }

    private func setupPanel() {
        let host = NSHostingView(rootView: PopoverView(
            store: store,
            onRefresh: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.poller?.refresh(force: true)
                }
            },
            onSettings: { [weak self] in self?.openSettings() },
            onQuit: { [weak self] in
                self?.closePanel()
                NSApp.terminate(nil)
            }
        ))
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        host.autoresizingMask = [.width, .height]
        host.frame = effect.bounds
        effect.addSubview(host)

        // the material of NSVisualEffectView is composited at window level, so its own
        // layer mask won't clip it — wrap it in a plain container whose mask clips both.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 358, height: 200))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        effect.frame = container.bounds
        container.addSubview(effect)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 358, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // non-activating panel: the app is usually inactive, which suppresses tooltips by default
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.contentView = container

        panelHost = host
        self.panel = panel
    }

    private func installObservers() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.defaultsDidChange()
            }
        }

        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusView?.needsDisplay = true
            }
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Task { @MainActor [weak self] in
                if event.keyCode == 53 {
                    self?.closePanel()
                }
            }
            return event
        }
    }

    private func defaultsDidChange() {
        let interval = AppSettings.pollIntervalMinutes
        let autoRefresh = AppSettings.autoRefresh
        if interval != lastInterval || autoRefresh != lastAutoRefresh {
            lastInterval = interval
            lastAutoRefresh = autoRefresh
            poller?.reschedule(intervalMinutes: interval)
        }
        updateStatusItemWidth()
        applyThemeOverride()
        storeDidChange()
    }

    private func applyThemeOverride() {
        statusView?.appearance = Theme.appearance(for: AppSettings.themeMode)
    }

    private func storeDidChange() {
        updateStatusItemWidth()
        statusView?.needsDisplay = true
        statusView?.toolTip = TooltipText.make(store.snapshot)
        if panel?.isVisible == true {
            schedulePanelResize()
        }
    }

    private func schedulePanelResize() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.resizePanelToFit()
        }
    }

    private func resizePanelToFit() {
        guard let panel, let host = panelHost, let button = statusItem?.button else { return }
        panel.setContentSize(host.fittingSize)
        placePanel(by: button)
    }

    private func handleLeftClick() {
        guard let panel, let button = statusItem?.button else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel(from: button)
            if AppSettings.refreshOnClick {
                Task { [weak self] in
                    await self?.poller?.refresh(force: true)
                }
            }
        }
    }

    private func showPanel(from button: NSButton) {
        guard let panel, let host = panelHost, let window = button.window else { return }
        panel.setContentSize(host.fittingSize)
        placePanel(by: button)
        panel.orderFront(nil)
    }

    private func placePanel(by button: NSButton) {
        guard let panel, let window = button.window else { return }
        let size = panel.frame.size
        let buttonScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard let visible = window.screen?.visibleFrame else { return }
        let x = min(max(buttonScreen.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = visible.maxY - size.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func closePanel() {
        panel?.orderOut(nil)
    }

    private func handleRightClick(_ event: NSEvent) {
        closePanel()
        guard let statusView else { return }
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: statusView)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let check = NSMenuItem(title: "Check Now", action: #selector(checkNow), keyEquivalent: "r")
        check.target = self
        if let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh") {
            image.isTemplate = true
            check.image = image
        }
        let settings = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let account = NSMenuItem(title: "Account", action: nil, keyEquivalent: "")
        account.submenu = buildAccountMenu()
        if let image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Account") {
            image.isTemplate = true
            account.image = image
        }
        menu.addItem(check)
        menu.addItem(account)
        menu.addItem(buildLaunchItem())
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func buildAccountMenu() -> NSMenu {
        accounts.reload()
        let menu = NSMenu()
        let selected = AccountSelection.current

        var autoTitle = "Auto (follow Claude Desktop)"
        if let active = accounts.activeProfileDir {
            autoTitle = "Auto (running: \((active as NSString).lastPathComponent))"
        }
        menu.addItem(accountItem(autoTitle, selection: .auto, selected: selected))
        menu.addItem(.separator())

        if accounts.visibleAccounts.isEmpty {
            let empty = NSMenuItem(title: accounts.isLoading ? "Loading accounts…" : "No Claude Desktop accounts found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for account in accounts.visibleAccounts {
            let item = accountItem(accounts.title(for: account), selection: AccountSelection(id: account.id), selected: selected)
            item.toolTip = account.profile.dir
            menu.addItem(item)
        }
        // A pinned account that is currently unavailable still shows, so the checkmark is never lost.
        if case .pinned = selected, !accounts.visibleAccounts.contains(where: { selected.matches($0.id) }) {
            let item = accountItem("\(accounts.label(for: selected)) (unavailable)", selection: selected, selected: selected)
            menu.addItem(item)
        }
        if !accounts.isHidden(AccountSelection.oauthId) || selected == .oauth {
            menu.addItem(accountItem(accounts.label(for: .oauth), selection: .oauth, selected: selected))
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Accounts…", action: #selector(openSettings), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        return menu
    }

    /// One Desktop instance per profile folder: a single item when there is one profile, a submenu otherwise.
    private func buildLaunchItem() -> NSMenuItem {
        let targets = launchTargets()
        let item = NSMenuItem(title: "Launch Desktop", action: nil, keyEquivalent: "")
        if let image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Launch Desktop") {
            image.isTemplate = true
            item.image = image
        }
        if targets.count <= 1 {
            item.action = #selector(launchDesktop(_:))
            item.target = self
            item.representedObject = targets.first?.dir ?? ProfileLocator.defaultProfileDir.path
            if let target = targets.first { item.toolTip = "\(target.title)\n\(target.dir)" }
            return item
        }
        let submenu = NSMenu()
        for target in targets {
            let entry = NSMenuItem(title: target.title, action: #selector(launchDesktop(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = target.dir
            entry.toolTip = target.dir
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    /// Visible profiles, labeled by the (renamed) accounts signed in there.
    private func launchTargets() -> [(dir: String, title: String)] {
        accounts.profiles.compactMap { profile in
            let all = accounts.accounts.filter { $0.profile.dir == profile.dir }
            if all.isEmpty {
                guard !accounts.isHidden("profile:\(profile.dir)") else { return nil }
                return (profile.dir, "\(profile.name) (signed out)")
            }
            let visible = all.filter { !accounts.isHidden($0.id) }
            guard !visible.isEmpty else { return nil }
            let names = visible.map { accounts.customName(for: $0.id) ?? $0.organization.name }
            return (profile.dir, "\(names.joined(separator: ", ")) (\(profile.name))")
        }
    }

    @objc private func launchDesktop(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        DesktopLauncher.launch(profileDir: dir)
    }

    private func accountItem(_ title: String, selection: AccountSelection, selected: AccountSelection) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectAccount(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = selection.id
        item.state = selection == selected || selected.matches(selection.id) ? .on : .off
        return item
    }

    @objc private func selectAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        applyAccountSelection(AccountSelection(id: id))
    }

    private func applyAccountSelection(_ selection: AccountSelection) {
        guard selection != AccountSelection.current else { return }
        accounts.select(selection)
        Task { @MainActor [weak self] in
            await self?.poller?.refreshForSelectionChange()
        }
    }

    /// Apply a rename to the data already shown, without a network round-trip.
    private func relabelSnapshot() {
        var snapshot = store.snapshot
        guard let id = snapshot.accountId else { return }
        if id == AccountSelection.oauthId {
            snapshot.accountLabel = AppSettings.accountNames[id] ?? "Claude Code login"
        } else if let account = accounts.accounts.first(where: { $0.id == id }) {
            snapshot.accountLabel = AppSettings.accountNames[id] ?? account.organization.name
        } else {
            return
        }
        store.setSnapshot(snapshot)
    }

    @objc private func checkNow() {
        Task {
            await poller?.refresh(force: true)
        }
    }

    @objc private func openSettings() {
        closePanel()
        showSettings()
    }

    private func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                store: store,
                accounts: accounts,
                onSelectAccount: { [weak self] selection in
                    self?.applyAccountSelection(selection)
                },
                onAccountsRenamed: { [weak self] in
                    self?.relabelSnapshot()
                }
            ))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Claude Tray Monitor Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        accounts.syncSelection()
        accounts.reload()
        guard let window = settingsWindow else { return }
        // An accessory (LSUIElement) app isn't frontmost, and macOS 14's cooperative
        // NSApp.activate() can be declined — force activation and raise the window.
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
