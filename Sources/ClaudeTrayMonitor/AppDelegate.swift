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

    private let store = UsageStore()
    private var poller: Poller?

    private var themeObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppSettings.registerDefaults()
        lastInterval = AppSettings.pollIntervalMinutes

        let poller = Poller(store: store)
        self.poller = poller

        setupStatusItem()
        setupPanel()
        installObservers()

        store.onChange = { [weak self] in
            self?.storeDidChange()
        }

        Task {
            await poller.refresh(force: true)
        }
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
        if show {
            width = horizontal ? 28 : 30
        } else {
            width = horizontal ? 20 : 14
        }
        statusItem.length = width
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 328, height: 200))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        effect.frame = container.bounds
        container.addSubview(effect)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 328, height: 200),
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
        if interval != lastInterval {
            lastInterval = interval
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
        statusView?.needsDisplay = true
        statusView?.toolTip = TooltipText.make(store.snapshot)
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
        let size = host.fittingSize
        panel.setContentSize(size)
        let buttonScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard let visible = window.screen?.visibleFrame else { return }
        let x = min(max(buttonScreen.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = visible.maxY - size.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFront(nil)
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
        menu.addItem(check)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
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
                onDataDirChange: { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.poller?.refresh(force: true)
                    }
                }
            ))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Claude Tray Monitor Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
