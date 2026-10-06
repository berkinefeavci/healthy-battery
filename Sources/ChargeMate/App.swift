import SwiftUI
import AppKit
import Combine

@main
enum ChargeMateApp {
    static func main() {
        if CommandLine.arguments.contains("--verify-led-connection") {
            do { try MagSafeLEDHardwareService.verifyConnection(); print("LED IPC authenticated: OK"); exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        if CommandLine.arguments.contains("--verify-led-policy-roundtrip") {
            do {
                guard let saved = MagSafeLEDHardwareService.savedPolicy() else { exit(2) }
                try MagSafeLEDHardwareService.configure(policy: saved.0, start: saved.1, end: saved.2)
                print("LED same-policy IPC round-trip: OK"); exit(0)
            } catch { print(error.localizedDescription); exit(1) }
        }
        // Runs once, before anything (BatteryMonitor.shared included) can touch the new
        // Application Support folder or UserDefaults domain — otherwise an empty new folder
        // would already exist by the time migration checks it, and it would look "already there"
        // instead of missing.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        IdentityMigration.runIfNeeded(oldSupportDirectory: support.appendingPathComponent("ChargeMate"),
                                       newSupportDirectory: support.appendingPathComponent("Cellkeep"))
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { AppDelegate.shared?.closePanel() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
            AppDelegate.shared?.closePanel()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem?

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
    private var panel: MenuPanel!
    private var panelHosting: NSHostingController<AnyView>!
    private var settingsWindow: NSWindow?
    private var observation: AnyCancellable?
    private var sleepObservation: AnyCancellable?
    private var menuTimer: Timer?
    private var menuInterval = 0
    private var menuPreferences = MenubarPreferences.load()
    private var scheduleRuntime: ScheduleRuntime?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private let battery = BatteryMonitor.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        ChargeMateAppShortcuts.updateAppShortcutParameters()
        if UserDefaults.standard.object(forKey: MenubarPreferences.storageKey) == nil { menuPreferences.save() }
        if !UserDefaults.standard.bool(forKey: "chartHoverOverviewMigrationV1") {
            UserDefaults.standard.set(ChartRange.defaultHours, forKey: "historyHours")
            UserDefaults.standard.set(true, forKey: "chartHoverOverviewMigrationV1")
        }
        battery.start()
        DispatchQueue.global(qos: .utility).async { MagSafeLEDHardwareService.resumeIfPausedByTest() }
        sleepObservation = battery.$snapshot
            .combineLatest(battery.$nativeLimit, battery.$committedLimit)
            .sink { [weak self] _ in self?.updateSleepBehavior() }
        updateSleepBehavior()
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cellkeep")
        scheduleRuntime = ScheduleRuntime(
            directory: supportDirectory,
            manualOperationActive: { [weak battery] in battery?.scheduleOperationActive ?? true },
            capabilities: { [weak battery] in battery?.scheduleCapabilities ?? .unavailable },
            chargeLimit: { [weak battery] limit in
                battery?.applyScheduledLimit(limit)
                    ?? .init(operationID: UUID(), status: .rejected, state: nil, message: String(localized: "Healthy Battery kullanılamıyor."))
            },
            topUp: { [weak battery] executionID in
                battery?.startScheduledTopUp(executionID: executionID)
                    ?? .init(operationID: UUID(), status: .rejected, state: nil, message: String(localized: "Healthy Battery kullanılamıyor."))
            })
        scheduleRuntime?.start()
        // A no-op when the user turned the daily release check off.
        UpdateNotifications.shared.start()
        HealthAutomation.shared.start()
        DispatchQueue.global(qos: .utility).async { SystemPowerModeService.warmUpCapabilities() }
        GlobalHotKey.shared.action = { [weak self] in self?.togglePanel(nil) }
        GlobalHotKey.shared.apply(.current)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Cellkeep"
        statusItem = item
        let bootMode = PanelSizeMode.current
        let bootScreen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let bootFrame = PanelSizing.panelFrame(anchor: .zero, mode: bootMode,
                                               content: CGSize(width: bootMode.width, height: 480),
                                               screen: bootScreen)
        panel = MenuPanel(contentRect: bootFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Healthy Battery Panel"
        let hosting = NSHostingController(rootView: AnyView(PopoverView().environmentObject(battery).clipShape(RoundedRectangle(cornerRadius: 22))))
        // NOT: `.preferredContentSize` KASITLIYLA kapalı — bu seçenek pencere içeriğinin
        // hosting'in ideal boyutuna kilitlenmesine yol açıyor ve PanelSizing.panelFrame
        // kenetlemesi runtime'da eziliyordu (canlı ölçüm: panel 1320pt = ekran üstü).
        // Boyut tamamen AppDelegate'in manuel setFrame akışıyla belirlenir.
        hosting.sizingOptions = []
        panelHosting = hosting
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        // A behind-window blur ignores the layer's corner radius and paints a square backdrop;
        // only a stretchable mask image rounds the blur itself.
        effect.maskImage = Self.roundedMask(radius: 22)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        let container = NSViewController()
        container.view = effect
        container.addChild(hosting)
        panel.contentViewController = container
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        if let button = item.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Healthy Battery")
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanelIfOutside(at: NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 && self.panel.isVisible {
                if let chart = self.panel.firstResponder as? ChartTrackingView, chart.onCommand(53) { return nil }
                self.closePanel()
                return nil
            }
            if event.type != .keyDown { self.closePanelIfOutside(at: NSEvent.mouseLocation) }
            return event
        }
        preferencesChanged()
        observation = battery.$selectedPowerMode.removeDuplicates()
            .combineLatest(battery.$actionMessage.removeDuplicates()).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenuBar() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshMenuAppearance), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshMenuAppearance), name: NSColor.systemColorsDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceDidWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceWillSleep),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        // Inert until a supported ChargeInhibitBackend is injected into AdvancedChargeRunner.shared.
        AdvancedChargeRunner.shared.start()
        AdapterModeController.shared.start()
        battery.snapshotObserver = { [weak battery] snapshot in
            guard let percentage = snapshot.percentage ?? snapshot.hardwarePercentage else { return }
            AdvancedChargeRunner.shared.update(percentage: percentage, temperatureC: snapshot.temperatureC,
                                               externalConnected: snapshot.externalConnected, isCharging: snapshot.isCharging,
                                               topUpActive: battery?.topUpActive ?? false)
        }
        installApplicationMenu()
        ChartTrackingView.isPanelWindow = { $0 is MenuPanel }
        if UserDefaults.standard.bool(forKey: "showPanelAtLaunch") {
            DispatchQueue.main.async { [weak self] in self?.togglePanel(nil) }
        }
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu(title: "Healthy Battery")
        appMenu.addItem(withTitle: String(localized: "Gösterge Tablosu’nu aç"), action: #selector(openDashboard), keyEquivalent: "d").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Healthy Battery’ten çık"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
    }

    @objc private func openDashboard() { showSettings(page: .dashboard) }
    @objc private func openChargeSettings() { showSettings(page: .charge) }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard NSApp.currentEvent?.type == .rightMouseUp else { togglePanel(sender); return }
        switch menuPreferences.rightClick {
        case .none: break
        case .likeLeftClick: togglePanel(sender)
        case .openDashboard: showSettings(page: .dashboard)
        case .toggleCharging, .toggleLowPower:
            // Preferences may come from a newer build: never dispatch an unverified writer.
            statusItem?.button?.toolTip = String(localized: "Bu sağ tık eylemi henüz kullanılamıyor. Menü ayarlarından başka bir eylem seçin.")
        }
    }

    @objc private func refreshMenuAppearance() { updateMenuBar() }
    @objc private func workspaceDidWake() {
        AdvancedChargeRunner.shared.setSleepState(.awake)
        battery.handleWake()
    }
    @objc private func workspaceWillSleep() { AdvancedChargeRunner.shared.setSleepState(.asleep) }

    private func updateMenuBar() {
        guard let button = statusItem?.button else { return }
        let budget = (button.window?.screen ?? NSScreen.main)?.visibleFrame.width ?? 1440
        let model = MenubarPresentation(preferences: menuPreferences, snapshot: battery.snapshot,
                                       lowPower: battery.selectedPowerMode == .lowPower,
                                       policyState: battery.policyState)
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            let output = MenubarRenderer.render(model, maxWidth: budget * 0.35)
            button.title = ""
            button.image = output.image
            button.imagePosition = .imageOnly
            button.toolTip = output.description
            button.setAccessibilityLabel(output.description)
        }
    }

    @objc private func preferencesChanged() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.preferencesChanged() }
            return
        }
        let style = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        NSApp.appearance = style == "dark" ? NSAppearance(named: .darkAqua) : style == "light" ? NSAppearance(named: .aqua) : nil
        let desiredPolicy: NSApplication.ActivationPolicy = UserDefaults.standard.bool(forKey: "showDockIcon") ? .regular : .accessory
        if NSApp.activationPolicy() != desiredPolicy { NSApp.setActivationPolicy(desiredPolicy) }
        updateSleepBehavior()
        menuPreferences = MenubarPreferences.load()
        if menuInterval != menuPreferences.interval {
            menuInterval = menuPreferences.interval
            menuTimer?.invalidate()
            menuTimer = Timer.scheduledTimer(withTimeInterval: Double(menuInterval), repeats: true) { [weak self] _ in
                self?.updateMenuBar()
            }
        }
        updateMenuBar()
        refitPanelIfVisible()
    }

    private func panelContentSize(for mode: PanelSizeMode) -> CGSize {
        CGSize(width: mode.width, height: mode.preferredHeight)
    }

    /// Panel görünürken mod/kart tercihi değişirse çerçeveyi bir kez, animasyonsuz günceller.
    private func refitPanelIfVisible() {
        guard panel.isVisible, let anchor = statusButtonFrame,
              let screen = (statusItem?.button?.window?.screen ?? NSScreen.main)?.visibleFrame else { return }
        let mode = PanelSizeMode.current
        let frame = PanelSizing.panelFrame(anchor: anchor, mode: mode,
                                           content: panelContentSize(for: mode), screen: screen)
        if !frame.equalTo(panel.frame) { panel.setFrame(frame, display: true) }
    }

    @objc func togglePanel(_ sender: Any?) {
        if panel.isVisible { closePanel(); return }
        guard let button = statusItem?.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let mode = PanelSizeMode.current
        let content = panelContentSize(for: mode)
        let frame = PanelSizing.panelFrame(anchor: anchor, mode: mode, content: content, screen: screen)
        FileHandle.standardError.write((PanelSizing.debugDescription(mode: mode, content: content, screen: screen, result: frame) + "\n").data(using: .utf8)!)
        panel.setFrame(frame, display: false)
        // Take keyboard focus without activating the app and raising its settings window.
        panel.makeKeyAndOrderFront(sender)
        battery.panelVisible = true
        battery.refresh()
        statusItem?.button?.highlight(true)
    }

    func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        battery.panelVisible = false
        statusItem?.button?.highlight(false)
        NotificationCenter.default.post(name: .chargeMatePanelClosed, object: nil)
    }

    private var statusButtonFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func closePanelIfOutside(at point: NSPoint) {
        guard panel.isVisible, !panel.frame.contains(point), statusButtonFrame?.contains(point) != true else { return }
        closePanel()
    }

    func showSettings(page: SettingsPage = .dashboard) {
        closePanel()
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(selection: page).environmentObject(battery))
            hosting.sizingOptions = []
            let effect = NSVisualEffectView()
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            let controller = NSViewController()
            controller.view = effect
            controller.addChild(hosting)
            let window = NSWindow(contentViewController: controller)
            window.title = "Healthy Battery"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: SettingsLayout.windowIdealWidth,
                                         height: SettingsLayout.windowIdealHeight))
            window.minSize = NSSize(width: SettingsLayout.windowMinWidth,
                                    height: SettingsLayout.windowMinHeight)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.center()
            settingsWindow = window
            window.delegate = self
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        battery.settingsVisible = true
        battery.refresh()
        NotificationCenter.default.post(name: .chargeMateSettingsPage, object: page)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { battery.settingsVisible = false }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(page: .dashboard)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuTimer?.invalidate()
        sleepObservation?.cancel()
        SleepInhibitionController.shared.stop()
        AdvancedChargeRunner.shared.stop()
        scheduleRuntime?.stop()
        battery.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func updateSleepBehavior() {
        precondition(Thread.isMainThread)
        let snapshot = battery.snapshot
        SleepInhibitionController.shared.update(.init(
            enabled: UserDefaults.standard.bool(forKey: SleepBehaviorPreferences.preventIdleSleepUntilTarget),
            batteryAvailable: snapshot.available,
            externalConnected: snapshot.externalConnected,
            percentage: snapshot.percentage.map(Double.init) ?? snapshot.hardwarePercentage.map(Double.init),
            target: battery.nativeLimit ?? battery.committedLimit,
            startedAt: nil,
            now: Date()
        ))
    }
}
