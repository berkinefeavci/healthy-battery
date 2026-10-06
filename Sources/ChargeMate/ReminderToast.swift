import AppKit
import Combine
import SwiftUI

/// Sabit boyutlu (300×44) toast. İçerik boyutu belirlemez; uzun metin 2 satırda kısalır.
private struct ReminderToastView: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "battery.75percent").font(.system(size: 14)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(width: ToastGeometry.size.width, height: ToastGeometry.size.height)
        .modifier(GlassSurface(radius: ToastGeometry.size.height / 2))
    }
}

/// Tıklama (erken kapatma) için hit-test'i kendine alır; odak almaz.
private final class ToastContentView: NSView {
    var onClick: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Durum öğesinin altında 5 sn görünen, bildirim merkezine gitmeyen küçük ipucu.
@MainActor
final class ReminderToastPresenter {
    static let displayDuration: TimeInterval = 5
    /// Durum öğesinin ekran çerçevesi (yoksa sağ üst köşe).
    var anchor: () -> CGRect? = { nil }
    /// Uygulamanın kendi paneli açıkken toast gösterilmez.
    var appPanelOpen: () -> Bool = { false }

    private var queue = ToastQueue()
    private var panel: ToastPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String) {
        if appPanelOpen() { return }
        switch queue.enqueue(text) {
        case .show(let text): present(text)
        case .queued, .dropped: break
        }
    }

    private func present(_ text: String) {
        let screen = (NSScreen.screens.first { anchor().map($0.frame.intersects) ?? false } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let target = ToastGeometry.frame(anchor: anchor(), screen: screen)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let panel = self.panel ?? ToastPanel(contentRect: target, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false)
        self.panel = panel
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false

        let content = ToastContentView(frame: CGRect(origin: .zero, size: ToastGeometry.size))
        content.onClick = { [weak self] in self?.dismiss() }
        let hosting = NSHostingView(rootView: ReminderToastView(text: text))
        hosting.frame = content.bounds
        hosting.autoresizingMask = [.width, .height]
        content.addSubview(hosting)
        panel.contentView = content
        content.setAccessibilityLabel(text)

        var start = target
        if !reduceMotion { start.origin.y += 6 }
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(target, display: true) }
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue])

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: work)
    }

    private func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        guard let panel, panel.isVisible else {
            if let next = queue.finished() { present(next) }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                guard let self else { return }
                if let next = self.queue.finished() { self.present(next) }
            }
        })
    }
}

/// BatteryMonitor anlık görüntülerini ReminderEngine'e besleyen ince bağlantı katmanı.
@MainActor
final class ReminderCenter {
    static let shared = ReminderCenter()
    static let stateKey = "remindersStateV1"

    let presenter = ReminderToastPresenter()
    private let battery: BatteryMonitor
    private let defaults: UserDefaults
    private var state: ReminderState
    private var cancellable: AnyCancellable?

    init(battery: BatteryMonitor = .shared, defaults: UserDefaults = .standard) {
        self.battery = battery
        self.defaults = defaults
        state = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(ReminderState.self, from: $0) }
            ?? ReminderState()
    }

    func start() {
        guard cancellable == nil else { return }
        cancellable = battery.$snapshot.sink { [weak self] snapshot in
            MainActor.assumeIsolated { self?.observe(snapshot) }
        }
    }

    func systemWillSleep() { state = ReminderEngine.willSleep(state) }
    func systemDidWake() { state = ReminderEngine.didWake(state, now: Date()) }
    func showSample() { presenter.show(String(localized: "Örnek hatırlatma — bu ipucu 5 saniye sonra kaybolur.")) }

    private func observe(_ snapshot: BatterySnapshot) {
        guard snapshot.available else { return }
        let sample = ReminderSample(percentage: snapshot.percentage ?? snapshot.hardwarePercentage,
                                    externalConnected: snapshot.externalConnected, isCharging: snapshot.isCharging,
                                    temperatureC: snapshot.temperatureC, limit: battery.nativeLimit)
        let result = ReminderEngine.step(state, sample: sample, settings: .load(defaults), now: Date())
        let changed = result.state != state
        state = result.state
        if changed, let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
        if let kind = result.fire.first { presenter.show(kind.message) }
    }
}
