import SwiftUI

let controlNotice = String(localized: "macOS limiti açıkça Uygula’ya bastığınızda kaydedilir. Başka bir şarj uygulaması açıkken değişiklik yapılamaz.")

enum HistoryCoverage {
    /// Saf, test edilebilir kapsam metni üretici. Uydurma veri yok: eksik ölçüm metinde açıkça belirtilir.
    static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let minutes = Int((seconds / 60).rounded(.down))
        if minutes < 60 { return String(localized: "\(max(1, minutes)) dk") }
        let hours = seconds / 3600
        if hours < 24 {
            let language = Bundle.main.preferredLocalizations.first ?? "tr"
            let text = String(format: "%.1f", min(hours, 23.9))
            return String(localized: "\(language == "en" ? text : text.replacingOccurrences(of: ".", with: ",")) sa")
        }
        return String(localized: "\(24) sa")
    }
    static func text(count: Int, oldestDate: Date?, now: Date, rangeHours: Int) -> String {
        guard count > 0, let oldest = oldestDate else { return String(localized: "Ölçüm toplanıyor…") }
        let span = min(max(0, now.timeIntervalSince(oldest)), Double(rangeHours) * 3600)
        guard count >= 5 else { return String(localized: "Ölçüm toplanıyor… (ölçüm: \(count))") }
        let base = String(localized: "Kapsam: son \(durationText(span)) · \(count) ölçüm")
        if span < Double(rangeHours) * 3600 - 60 {
            return String(localized: "\(base) · Veri toplama sürüyor — 24 saate kadar birikecek")
        }
        return base
    }
}

struct DraftBadge: View {
    var detail: String
    var body: some View {
        Label("Taslak", systemImage: "pencil.tip")
            .font(.system(size: 9, weight: .medium)).foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.orange.opacity(0.14), in: Capsule())
            .help(detail)
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color
    let icon: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct GlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("appReduceTransparency") private var appReduceTransparency = false
    var radius: CGFloat = 20
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || appReduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.42 : 0.18), lineWidth: contrast == .increased ? 1.5 : 1))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.20 : 0.55), lineWidth: 1))
                .shadow(color: .black.opacity(scheme == .dark ? 0.16 : 0.07), radius: 6, y: 3)
        }
    }
}

struct WindowSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("appReduceTransparency") private var appReduceTransparency = false
    func body(content: Content) -> some View {
        content.background(reduceTransparency || appReduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear)
    }
}

extension View {
    func chargeCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .modifier(GlassSurface())
    }
    func hoverSurface(enabled: Bool = true) -> some View { modifier(HoverSurface(enabled: enabled)) }
    func chargeMateButtonStyle() -> some View { modifier(AdaptiveButtonStyle()) }
    func popoverToolbarButtonStyle(active: Bool = false, iconOnly: Bool = false) -> some View {
        buttonStyle(PopoverToolbarButtonStyle(active: active, iconOnly: iconOnly))
    }
    /// Custom focusable visualizations keep keyboard input without macOS's
    /// rectangular blue focus effect. Native form controls retain their cues.
    @ViewBuilder
    func quietVisualizationFocus() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() }
        else { self }
    }
}

private struct AdaptiveButtonStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("appReduceTransparency") private var appReduceTransparency = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, !appReduceTransparency { content.buttonStyle(.glass).buttonBorderShape(.capsule) }
        else { content.buttonStyle(ChargeMateButtonStyle()) }
    }
}

struct ChargeMateGlassContainer<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: 12) { content } }
        else { content }
    }
}

private struct HoverSurface: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let enabled: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(.primary.opacity(enabled && hovering ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(enabled && hovering ? 0.16 : 0), lineWidth: 1))
            .onHover { inside in
                guard enabled else { return }
                if reduceMotion { hovering = inside }
                else { withAnimation(.easeOut(duration: 0.14)) { hovering = inside } }
            }
    }
}

/// Home Screen-style edit motion, kept cheap: on entering edit mode each card wobbles a few
/// times and settles. A never-ending wobble re-renders every glass card each frame (about 60% CPU
/// with nine cards), and a `repeatForever` animation is also hard to stop reliably. This one is a
/// finite `repeatCount`, so it ends on its own. The angle keeps edge travel to about a point
/// (smaller for wide cards); each card has its own tempo so neighbours move out of step.
/// Reduce Motion skips the wobble and keeps only the border.
private struct EditModeJiggle: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    let wide: Bool
    @State private var tilt = 0.0
    @State private var tempo = Double.random(in: 0.12...0.16)
    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(tilt))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(active ? 0.16 : 0), lineWidth: 1)
            )
            .onAppear { if active { wobble() } }
            .onChange(of: active) { on in
                if on { wobble() } else { withAnimation(.easeOut(duration: 0.15)) { tilt = 0 } }
            }
    }
    private func wobble() {
        guard !reduceMotion else { return }
        let angle = wide ? 0.35 : 0.8, swings = 5
        tilt = -angle
        withAnimation(.easeInOut(duration: tempo).repeatCount(swings, autoreverses: true)) { tilt = angle }
        DispatchQueue.main.asyncAfter(deadline: .now() + tempo * Double(swings)) {
            withAnimation(.easeOut(duration: 0.2)) { tilt = 0 }
        }
    }
}

extension View {
    /// Applies the edit-mode jiggle/highlight to a widget card.
    func editModeJiggle(active: Bool, wide: Bool) -> some View { modifier(EditModeJiggle(active: active, wide: wide)) }
}

/// Small circular badge placed on a card corner in edit mode (remove/resize).
struct WidgetEditBadge: View {
    let systemImage: String
    var tint: Color = .primary
    /// Solid fill (e.g. red for remove); nil uses a neutral glass circle.
    var fill: Color? = nil
    let action: () -> Void
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background {
                if let fill { Circle().fill(fill) } else { Circle().fill(.ultraThinMaterial) }
            }
            .overlay(Circle().strokeBorder(.white.opacity(fill == nil ? 0.4 : 0.85), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { action() }
    }
}

/// Where each card sits while the panel is in edit mode. The remove badge and resize handle are
/// drawn from these anchors in an overlay above the glass container: inside it, the glass is
/// composited on top of them, and overlays hanging off a card's edge kept SwiftUI re-laying out
/// the panel every frame.
struct PanelEditAnchor: Identifiable {
    let widget: PanelWidget
    let size: WidgetSize
    let resizable: Bool
    let bounds: Anchor<CGRect>
    var id: PanelWidget { widget }
}

/// Card frames in the panel's card space while editing, for finding the drop target of a drag.
struct PanelCardFramesKey: PreferenceKey {
    static let defaultValue: [PanelWidget: CGRect] = [:]
    static func reduce(value: inout [PanelWidget: CGRect], nextValue: () -> [PanelWidget: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct PanelEditAnchorsKey: PreferenceKey {
    static let defaultValue: [PanelEditAnchor] = []
    static func reduce(value: inout [PanelEditAnchor], nextValue: () -> [PanelEditAnchor]) { value += nextValue() }
}

/// Home Screen widget-style resize grip on a card's bottom-right corner: an arc that follows the
/// card's corner. Drag left to make the card square, right to make it wide; a click toggles.
struct WidgetResizeHandle: View {
    let size: WidgetSize
    let onChange: (WidgetSize) -> Void
    static let extent: CGFloat = 38
    private static let cornerRadius: CGFloat = 20
    var body: some View {
        let e = Self.extent, r = Self.cornerRadius + 3
        // The arc's centre is the card corner's centre: `cornerRadius` in from the card's corner,
        // which sits 12 pt in from this view's bottom-right.
        let centre = CGPoint(x: e - 12 - Self.cornerRadius, y: e - 12 - Self.cornerRadius)
        ZStack {
            Path { path in
                path.addArc(center: centre, radius: r, startAngle: .degrees(8), endAngle: .degrees(82), clockwise: false)
            }
            .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        .frame(width: e, height: e)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { value in
            let dx = value.translation.width
            if abs(dx) < 6, abs(value.translation.height) < 6 { onChange(size == .square ? .wide : .square) }
            else if dx < -24 { onChange(.square) }
            else if dx > 24 { onChange(.wide) }
        })
        .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onChange(size == .square ? .wide : .square) }
    }
}

func watts(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.1f W", value)
}
func decimal(_ value: Double?, unit: String) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.2f %@", value, unit)
}

/// Pill/capsule silhouette shared by every chip/button in this file.
///
/// Important: draw a hairline "border" on this shape as a second, full-size `.fill()` underneath
/// an inset content fill — never as `.stroke()`/`.strokeBorder()`. On both `Capsule` and this
/// `RoundedRectangle`, stroking alongside a separate fill renders a faint bright seam exactly at
/// the pole of each rounded end (its vertical mid-height, left/right edges) — most likely a
/// stroke-offset artifact at the Bezier join where each rounded end's two quarter-arcs meet.
/// Confirmed by isolated rendering: fill-only and stroke-only are both clean; any fill+stroke
/// combination shows the seam regardless of shape type (`Capsule` vs `RoundedRectangle`),
/// strokeBorder vs centered stroke, single vs separate shape instances, `.compositingGroup()`,
/// or `.drawingGroup()`. Two nested fills (border-color capsule + `lineWidth`-inset content-color
/// capsule) render perfectly smooth instead, so that's the pattern used everywhere here.
private func pillShape() -> RoundedRectangle { RoundedRectangle(cornerRadius: 999, style: .continuous) }

struct ChargeMateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChargeMateButtonBody(configuration: configuration)
    }
}

struct PopoverToolbarButtonStyle: ButtonStyle {
    let active: Bool
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        PopoverToolbarButtonBody(configuration: configuration, active: active, iconOnly: iconOnly)
    }
}

private struct PopoverToolbarButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let active: Bool
    let iconOnly: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var highlighted: Bool { enabled && (active || hovering) }

    var body: some View {
        // One line always: when a translation is long the label shrinks a little instead of
        // wrapping mid-word inside the pill.
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: iconOnly ? 36 : nil, height: 36)
            .padding(.horizontal, iconOnly ? 0 : 11)
            .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
            .background {
                // A hairline border drawn as `Shape.stroke`/`strokeBorder` alongside a separate
                // fill renders a faint seam at the pole of each rounded end (see `pillShape()`'s
                // doc), so the border here is a second, full-size fill instead, with the material
                // and highlight fills inset by the border's own width on top of it.
                pillShape().fill(.white.opacity(highlighted ? 0.55 : 0.18))
                pillShape().inset(by: 0.8).fill(.ultraThinMaterial)
                pillShape().inset(by: 0.8).fill(highlighted
                    ? Color.white.opacity(scheme == .dark ? 0.96 : 0.88)
                    : Color.primary.opacity(scheme == .dark ? 0.11 : 0.06))
            }
            .contentShape(pillShape())
            .opacity(enabled ? 1 : 0.42)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.97)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { inside in
                if reduceMotion { hovering = inside }
                else { withAnimation(.easeOut(duration: 0.14)) { hovering = inside } }
            }
    }
}

private struct ChargeMateButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("appReduceTransparency") private var appReduceTransparency = false
    @State private var hovering = false
    @ViewBuilder var body: some View {
        let label = configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 7)
        if #available(macOS 26.0, *), !reduceTransparency, !appReduceTransparency {
            // Interactive glass alone reads as near-invisible at rest; every action button
            // needs a subtle resting fill so it doesn't only appear on hover.
            label
                .background(Capsule().fill(.primary.opacity(hovering ? 0.16 : 0.09)))
                .glassEffect(.regular.interactive(enabled), in: Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
                .onHover { inside in
                    guard enabled else { return }
                    if reduceMotion { hovering = inside }
                    else { withAnimation(.easeOut(duration: 0.14)) { hovering = inside } }
                }
        } else {
            label
                .modifier(GlassSurface(radius: 20))
                .overlay(Capsule().fill(.primary.opacity(enabled && hovering ? 0.08 : 0)))
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
                .onHover { inside in
                    guard enabled else { return }
                    if reduceMotion { hovering = inside }
                    else { withAnimation(.easeOut(duration: 0.14)) { hovering = inside } }
                }
        }
    }
}

/// Shared capsule chip for selection controls (limit percent, power mode, filters, catalog
/// picks). Selected chips get an accent-tinted glass fill; neutral chips stay glass-only.
/// Keeps the same glass language as `ChargeMateButtonBody` so no third button shape exists.
struct ChipButtonStyle: ButtonStyle {
    var selected: Bool
    var tint: Color = .accentColor
    /// Tighter font/padding for chips packed into narrow rows (e.g. three-across
    /// power-mode chips), so text never wraps inside a fixed-width chip.
    var compact: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        ChipButtonBody(configuration: configuration, selected: selected, tint: tint, compact: compact)
    }
}

private struct ChipButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let tint: Color
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("appReduceTransparency") private var appReduceTransparency = false
    @State private var hovering = false
    @ViewBuilder var body: some View {
        let label = configuration.label
            .font(.system(size: compact ? 10 : 11, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? (tint == .yellow ? Color.black : Color.white) : Color.primary)
            .padding(.horizontal, compact ? 6 : 10).padding(.vertical, compact ? 6 : 7)
        // Glass over a selected tint washes the color out (purple read as pale pink live), so a
        // selected chip is a solid pill; only unselected chips use glass.
        if #available(macOS 26.0, *), !reduceTransparency, !appReduceTransparency, !selected {
            label
                .glassEffect(.regular.interactive(enabled), in: pillShape())
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
        } else {
            label
                .background {
                    // See `pillShape()`: the border is a second full-size fill, not a stroke.
                    pillShape().fill(.white.opacity(selected ? 0.18 : 0.12))
                    pillShape().inset(by: 1).fill(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.primary.opacity(hovering ? 0.10 : 0.06)))
                }
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
                .onHover { inside in
                    guard enabled else { return }
                    if reduceMotion { hovering = inside }
                    else { withAnimation(.easeOut(duration: 0.14)) { hovering = inside } }
                }
        }
    }
}

/// Always-visible capsule for destructive/direct-action buttons that must read clearly at rest
/// (e.g. the energy list's "Çıkış"), unlike the glass button family which is interactive-only and
/// near-invisible until hovered. Solid `primary` fill + hairline stroke, stronger fill on hover.
struct QuitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuitButtonBody(configuration: configuration)
    }
}

private struct QuitButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                // See `pillShape()`: the border is a second full-size fill, not a stroke.
                pillShape().fill(.primary.opacity(0.18))
                pillShape().inset(by: 1).fill(.primary.opacity(hovering ? 0.18 : 0.12))
            }
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
            .onHover { inside in
                guard enabled else { return }
                if reduceMotion { hovering = inside }
                else { withAnimation(.easeOut(duration: 0.14)) { hovering = inside } }
            }
    }
}

/// Shared circle affordance for icon-only buttons (quit, reorder, remove, scroll arrows).
/// Same hover/press language as the capsule styles, just a round hit area instead of a chip.
struct IconCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        IconCircleButtonBody(configuration: configuration, size: size)
    }
}

private struct IconCircleButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let size: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var body: some View {
        configuration.label
            .frame(width: size, height: size)
            .contentShape(Circle())
            .background(.primary.opacity(enabled && hovering ? 0.10 : 0), in: Circle())
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.42)
            .onHover { inside in
                guard enabled else { return }
                if reduceMotion { hovering = inside }
                else { withAnimation(.easeOut(duration: 0.14)) { hovering = inside } }
            }
    }
}

/// Calm, low-key status capsule (replaces an earlier "açık · İzleme" badge that drew too much
/// attention for a passive status indicator).
struct ReadOnlyBadge: View {
    @EnvironmentObject var battery: BatteryMonitor
    /// Short wording for the narrow settings sidebar; the full sentence stays in the tooltip.
    var compact = false
    private var verified: Bool { !battery.otherControllerRunning && battery.committedLimit != nil }
    private var text: String {
        if !verified { return String(localized: "İzleme modu") }
        return compact ? String(localized: "Doğrulandı") : String(localized: "macOS limiti · doğrulandı")
    }
    private var icon: String { battery.otherControllerRunning ? "eye" : verified ? "checkmark.seal" : "eye" }
    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .help(controlNotice)
    }
}

struct NativeLimitControls: View {
    @EnvironmentObject var battery: BatteryMonitor
    @State private var confirmingRecovery = false
    @State private var recoveryLimit: Int?
    private var caption: Font { .system(size: 11) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Şarj sınırı", systemImage: "battery.100percent").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(battery.nativeLimit.map { "%\($0)" } ?? "—").monospacedDigit().font(.system(size: 15, weight: .bold))
            }
            if !battery.nativeLimits.isEmpty {
                HStack(spacing: 6) {
                    ForEach(battery.nativeLimits, id: \.self) { limit in
                        Button { battery.chargeLimit = Double(limit) } label: {
                            Text("%\(limit)").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ChipButtonStyle(selected: Int(battery.chargeLimit) == limit, tint: .green, compact: true))
                        .accessibilityLabel("Hedef yüzde \(limit)")
                    }
                }
            }
            if battery.otherControllerRunning {
                HStack(spacing: 8) {
                    Label("İzleme modu · başka şarj uygulaması açık", systemImage: "eye")
                        .font(caption).foregroundStyle(.secondary).lineLimit(1)
                        .help("İki uygulama aynı şarj sınırını yazarsa birbirini bozar; bu yüzden düğmeler kilitli.")
                    Spacer(minLength: 4)
                    Button("Diğerini kapat") { battery.quitOtherChargeController() }
                        .chargeMateButtonStyle()
                        .help("Diğer şarj uygulamasını normal şekilde kapatır; ardından Healthy Battery denetimi devralır.")
                }
            } else if !battery.nativeLimits.contains(Int(battery.chargeLimit)) {
                Text("Bu Mac %80–100 arasında beşer puan sunuyor.").font(caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(battery.nativeLimit == Int(battery.chargeLimit) ? String(localized: "macOS ile eşleşiyor") : String(localized: "Seçilen %\(Int(battery.chargeLimit))"))
                    .font(caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if battery.applyingLimit {
                    Button(battery.cancellationRequested ? String(localized: "Bekleniyor…") : String(localized: "Durdur")) { battery.cancelLimitRequest() }
                        .chargeMateButtonStyle()
                        .disabled(battery.cancellationRequested || battery.controlRecoveryRequired)
                } else {
                    Button("İptal") { battery.cancelDraftLimit() }
                        .chargeMateButtonStyle()
                        .disabled((battery.nativeLimit ?? battery.committedLimit) == nil || battery.nativeLimit == Int(battery.chargeLimit))
                }
                Button(battery.applyingLimit ? String(localized: "Kaydediliyor…") : String(localized: "Uygula")) { battery.applyNativeLimit() }
                    .chargeMateButtonStyle().disabled(!battery.hardwareControlAvailable || battery.nativeLimit == Int(battery.chargeLimit))
                    .help("Seçilen sınırı macOS'a kaydeder")
            }
            if let message = battery.limitMessage {
                Text(message).font(caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if battery.policyConflict != nil {
                HStack(spacing: 8) {
                    Button("Hedefi yeniden uygula") { battery.reapplyChargeMateTarget() }
                        .chargeMateButtonStyle()
                    Button("macOS değerini kullan") { battery.adoptMacOSLimit() }
                        .chargeMateButtonStyle()
                }.disabled(battery.applyingLimit || battery.otherControllerRunning)
            }
            if battery.controlRecoveryRequired {
                HStack(spacing: 8) {
                    Label("Önceki işlem kontrol edilmeli", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("İncele") {
                        recoveryLimit = battery.nativeLimit
                        confirmingRecovery = true
                    }
                    .chargeMateButtonStyle()
                    .disabled(battery.nativeLimit == nil || battery.applyingLimit || battery.otherControllerRunning)
                    .help("Mevcut macOS ayarını incele")
                }
            }
            if let current = battery.currentSystemLimit, current != battery.nativeLimit {
                Label("Sistem limiti %\(current)", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .help("Kayıtlı hedef ile sistemin bildirdiği limit farklı. Kaydetme doğrulaması, şarjın fiziksel olarak durduğunu göstermez.")
            }
        }.alert("Belirsiz işlemi kapat", isPresented: $confirmingRecovery) {
            Button("Vazgeç", role: .cancel) { }
            Button("Mevcut ayarı kabul et") {
                if let expected = recoveryLimit { battery.reconcileNativeLimit(expectedLimit: expected) }
            }
        } message: {
            Text("macOS kayıtlı limiti: %\(recoveryLimit ?? 0). Bu işlem ayarı değiştirmez. Değer yeniden okunur, önceki işlem kaydı korunur ve uygunsa kilit kaldırılır. Yeni hedef için ayrıca Uygula gerekir.")
        }
    }
}

struct PowerFlowView: View {
    let snapshot: BatterySnapshot
    var connectedDevices: [ConnectedDevice] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var flow: PowerFlowPresentation { snapshot.powerFlow }
    var body: some View {
        let presentation = flow
        let nodes = visibleNodes(presentation)
        let panelHeight = flowHeight(presentation)
        VStack(alignment: .leading, spacing: 8) {
            Text(flowTitle).font(.system(size: 11, weight: .semibold))
            GeometryReader { proxy in
                let positions = positions(in: proxy.size, presentation: presentation)
                ZStack {
                    ForEach(presentation.edges) { edge in
                        if let start = positions[edge.source], let end = positions[edge.target] {
                            FlowRouteView(curve: FlowCurve(from: start, to: end),
                                      watts: edge.watts, color: color(for: edge), help: description(edge))
                        }
                    }
                    if let other = positions[.other] {
                        if !presentation.edges.contains(where: { $0.target == .other }), let mac = positions[.mac] {
                            FlowRouteView(curve: FlowCurve(from: mac, to: other), watts: nil,
                                          color: .secondary, help: String(localized: "Diğer yükün gücü ölçülemiyor"))
                        }
                        ForEach(Array(connectedDevices.enumerated()), id: \.element.id) { index, device in
                            let position = accessoryPosition(index: index, in: proxy.size)
                            let deviceHelp = device.powerWatts != nil
                                ? "\(device.name) · \(watts(device.powerWatts))" : String(localized: "\(device.name) · anlık güç ölçülemiyor")
                            FlowRouteView(curve: FlowCurve(from: other, to: position), watts: device.powerWatts,
                                          color: .cyan, help: deviceHelp)
                        }
                    }
                    ForEach(nodes, id: \.self) { node in
                        if let position = positions[node] {
                            flowNode(node, icon: icon(for: node), value: value(for: node, presentation: presentation),
                                     color: color(for: node)).position(position)
                        }
                    }
                    ForEach(Array(connectedDevices.enumerated()), id: \.element.id) { index, device in
                        accessoryNode(device).position(accessoryPosition(index: index, in: proxy.size))
                    }
                }
            }.frame(height: panelHeight)
            Text(details(presentation)).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .topLeading).lineLimit(3)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: presentation.mode)
        .accessibilityElement(children: .contain)
    }
    private var flowTitle: String {
        switch flow.mode {
        case .charging: return String(localized: "Adaptör MacBook’u ve bataryayı besliyor")
        case .adapterOnly: return String(localized: "MacBook adaptörden çalışıyor")
        case .batteryOnly: return String(localized: "Batarya MacBook’u besliyor")
        case .batteryAssist: return String(localized: "Adaptör ve batarya birlikte çalışıyor")
        case .unavailable: return String(localized: "Güç akışı doğrulanamıyor")
        }
    }
    private func description(_ edge: PowerFlowEdge) -> String {
        "\(edge.source.title) → \(edge.target.title) · \(watts(edge.watts))"
    }
    private var batteryColor: Color {
        switch PowerFlowLayout.batteryTone(for: snapshot.percentage) {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        }
    }
    private func color(for edge: PowerFlowEdge) -> Color {
        if edge.source == .battery || edge.target == .battery { return batteryColor }
        if edge.source == .adapter { return .yellow }
        return color(for: edge.target)
    }
    private func details(_ presentation: PowerFlowPresentation) -> String {
        presentation.notice ?? (connectedDevices.isEmpty
            ? String(localized: "Toplam, işlemci ve ekran gerçek sensörlerden; Diğer GPU, bellek, depolama, fan ve ayrılamayan yüktür.")
            : connectedDevices.contains(where: { $0.powerWatts != nil })
                ? String(localized: "Dolu kollar ölçülen cihaz gücünü gösterir; kesikli kollarda anlık güç ölçülemiyor.")
                : String(localized: "Kesikli kollar bağlı cihazları gösterir; cihaz başına anlık güç ölçülemiyor."))
    }

    private func visibleNodes(_ presentation: PowerFlowPresentation) -> [PowerFlowNode] {
        var result = Set<PowerFlowNode>([.mac])
        for edge in presentation.edges { result.insert(edge.source); result.insert(edge.target) }
        if !connectedDevices.isEmpty { result.insert(.other) }
        return result.sorted { rank($0) < rank($1) }
    }

    private func rank(_ node: PowerFlowNode) -> Int {
        PowerFlowLayout.verticalRank(for: node, mode: flow.mode)
    }

    private func columnNodes(_ column: PowerFlowColumn, presentation: PowerFlowPresentation) -> [PowerFlowNode] {
        visibleNodes(presentation).filter { PowerFlowLayout.column(for: $0, mode: presentation.mode) == column }
    }

    private func flowHeight(_ presentation: PowerFlowPresentation) -> CGFloat {
        let count = max(columnNodes(.source, presentation: presentation).count,
                        columnNodes(.device, presentation: presentation).count,
                        columnNodes(.destination, presentation: presentation).count)
        return max(130, CGFloat(max(count, connectedDevices.count)) * 62)
    }

    private func positions(in size: CGSize, presentation: PowerFlowPresentation) -> [PowerFlowNode: CGPoint] {
        var result: [PowerFlowNode: CGPoint] = [:]
        func place(_ nodes: [PowerFlowNode], x: CGFloat) {
            guard !nodes.isEmpty else { return }
            let step = size.height / CGFloat(nodes.count)
            for (index, node) in nodes.enumerated() {
                result[node] = CGPoint(x: x, y: step * (CGFloat(index) + 0.5))
            }
        }
        let hasAccessories = !connectedDevices.isEmpty
        place(columnNodes(.source, presentation: presentation), x: 31)
        place(columnNodes(.device, presentation: presentation), x: size.width * (hasAccessories ? 0.34 : 0.5))
        place(columnNodes(.destination, presentation: presentation), x: hasAccessories ? size.width * 0.64 : size.width - 31)
        return result
    }

    private func accessoryPosition(index: Int, in size: CGSize) -> CGPoint {
        let step = size.height / CGFloat(connectedDevices.count)
        return CGPoint(x: size.width - 39, y: step * (CGFloat(index) + 0.5))
    }

    private func accessoryNode(_ device: ConnectedDevice) -> some View {
        VStack(spacing: 3) {
            Image(systemName: device.kind.icon).font(.system(size: 16)).foregroundStyle(.cyan)
            Text(device.name).font(.system(size: 9, weight: .medium))
                .lineLimit(1).truncationMode(.middle).frame(width: 70)
            Text(watts(device.powerWatts)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(width: 76, height: 58).modifier(GlassSurface(radius: 13))
        .help(device.powerWatts != nil ? "\(device.name) · \(watts(device.powerWatts))" : String(localized: "\(device.name) · anlık güç ölçülemiyor"))
        .accessibilityElement(children: .combine)
    }

    private func value(for node: PowerFlowNode, presentation: PowerFlowPresentation) -> Double? {
        switch node {
        case .adapter:
            return snapshot.adapterWatts ?? presentation.edges
                .filter { $0.source == .adapter }.compactMap(\.watts).reduce(0, +)
        case .mac: return snapshot.systemWatts
        case .processor: return snapshot.processorWatts
        case .display: return snapshot.displayWatts
        case .other: return presentation.edges.first { $0.target == .other }?.watts
        case .battery: return presentation.edges.first { $0.source == .battery || $0.target == .battery }?.watts
        }
    }

    private func icon(for node: PowerFlowNode) -> String {
        switch node {
        case .adapter: return "powerplug.portrait.fill"
        case .mac: return "laptopcomputer"
        case .battery: return "battery.100percent"
        case .display: return "display"
        case .processor: return "cpu"
        case .other: return "ellipsis"
        }
    }

    private func color(for node: PowerFlowNode) -> Color {
        switch node {
        case .adapter: return .yellow
        case .battery: return batteryColor
        case .mac: return .primary
        case .display: return .cyan
        case .processor: return .purple
        case .other: return .secondary
        }
    }
    private func flowNode(_ node: PowerFlowNode, icon: String, value: Double?, color: Color) -> some View {
        return VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(value == nil ? .secondary : color)
            Text(node.title).font(.system(size: 9, weight: .medium))
            Text(watts(value)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(width: 62, height: 58).modifier(GlassSurface(radius: 13))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help("\(node.title) · \(watts(value))")
        .accessibilityElement(children: .combine)
    }
}

private struct FlowCurve: Shape {
    var from: CGPoint
    var to: CGPoint
    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(from.animatableData, to.animatableData) }
        set { from.animatableData = newValue.first; to.animatableData = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        let middle = (from.x + to.x) / 2
        path.addCurve(to: to, control1: CGPoint(x: middle, y: from.y), control2: CGPoint(x: middle, y: to.y))
        return path
    }
}

private struct FlowRouteView: View {
    let curve: FlowCurve
    let watts: Double?
    let color: Color
    let help: String
    private var active: Bool { (watts ?? 0) > PowerFlowPresentation.deadZone }
    var body: some View {
        let width = PowerFlowPresentation.lineWidth(for: watts)
        let midpoint = CGPoint(x: (curve.from.x + curve.to.x) / 2, y: (curve.from.y + curve.to.y) / 2)
        let direction = Angle(radians: atan2(curve.to.y - curve.from.y, curve.to.x - curve.from.x))
        ZStack {
            curve.stroke(active ? color.opacity(0.82) : .secondary.opacity(0.18),
                         style: StrokeStyle(lineWidth: width, lineCap: .round, dash: active ? [] : [4, 5]))
            if active {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.white.opacity(0.92))
                    .rotationEffect(direction)
                    .position(midpoint)
                    .allowsHitTesting(false)
            }
            curve.stroke(Color.clear, style: StrokeStyle(lineWidth: max(20, width + 10), lineCap: .round))
                .contentShape(curve.stroke(style: StrokeStyle(lineWidth: max(20, width + 10))))
                .help(help)
        }
    }
}

/// Rows the wide "Battery info" card can show, grouped like the dashboard. Which rows are visible
/// is a per-user choice made in panel edit mode; the defaults match the earlier fixed card.
enum QuickStat: String, CaseIterable, Identifiable {
    case designCapacity, fullCapacity, hardwarePercentage, cycles
    case temperature, timeRemaining
    case current, voltage, batteryPower, systemPower
    case adapterPower, adapterVoltage, adapterCurrent

    enum Group: CaseIterable {
        case health, battery, electrical, adapter
        var title: String {
            switch self {
            case .health: return String(localized: "Batarya sağlığı")
            case .battery: return String(localized: "Batarya")
            case .electrical: return String(localized: "Elektrik")
            case .adapter: return String(localized: "Güç adaptörü")
            }
        }
        var members: [QuickStat] { QuickStat.allCases.filter { $0.group == self } }
    }

    static let storageKey = "quickStatsVisible"
    static let defaultVisible: [QuickStat] = [.fullCapacity, .cycles, .temperature, .timeRemaining,
                                              .batteryPower, .systemPower, .adapterPower]
    static var defaultStorage: String { defaultVisible.map(\.rawValue).joined(separator: ",") }

    static func visible(from storage: String) -> Set<QuickStat> {
        Set(storage.split(separator: ",").compactMap { QuickStat(rawValue: String($0)) })
    }
    static func storage(for visible: Set<QuickStat>) -> String {
        allCases.filter(visible.contains).map(\.rawValue).joined(separator: ",")
    }

    var id: String { rawValue }
    var group: Group {
        switch self {
        case .designCapacity, .fullCapacity, .hardwarePercentage, .cycles: return .health
        case .temperature, .timeRemaining: return .battery
        case .current, .voltage, .batteryPower, .systemPower: return .electrical
        case .adapterPower, .adapterVoltage, .adapterCurrent: return .adapter
        }
    }
    var icon: String {
        switch self {
        case .designCapacity: return "battery.100percent"
        case .fullCapacity: return "heart"
        case .hardwarePercentage: return "cpu"
        case .cycles: return "clock.arrow.circlepath"
        case .temperature: return "thermometer.medium"
        case .timeRemaining: return "clock"
        case .current: return "bolt.horizontal"
        case .voltage: return "bolt"
        case .batteryPower: return "battery.75percent"
        case .systemPower: return "laptopcomputer"
        case .adapterPower: return "powerplug.portrait.fill"
        case .adapterVoltage: return "bolt.circle"
        case .adapterCurrent: return "arrow.left.and.right.circle"
        }
    }
}

struct QuickStatsView: View {
    @EnvironmentObject var battery: BatteryMonitor
    @Environment(\.panelEditing) private var editing
    @AppStorage(QuickStat.storageKey) private var visibleStorage = QuickStat.defaultStorage
    /// Kare (yarım genişlik) varyant: yalnızca en önemli iki istatistik, büyük punto.
    var square: Bool = false

    private var visible: Set<QuickStat> { QuickStat.visible(from: visibleStorage) }

    var body: some View {
        if square {
            VStack(alignment: .leading, spacing: 10) {
                Text("Batarya bilgileri").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                squareStat(String(localized: "Sağlık"), icon: "heart", value: battery.snapshot.reading(.health).text())
                Divider()
                squareStat(String(localized: "Sıcaklık"), icon: "thermometer.medium", value: battery.temperatureText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
            .modifier(GlassSurface())
        } else {
            let groups = QuickStat.Group.allCases.filter { group in editing || group.members.contains(where: visible.contains) }
            VStack(spacing: 10) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    if editing { groupHeader(group) }
                    ForEach(group.members.filter { editing || visible.contains($0) }) { item in
                        row(item)
                    }
                }
                if groups.isEmpty {
                    Text("Satır seçmek için bir karta uzun basıp düzenleme moduna girin.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func groupHeader(_ group: QuickStat.Group) -> some View {
        let members = Set(group.members)
        let all = members.isSubset(of: visible)
        return Button {
            var next = visible
            if all { next.subtract(members) } else { next.formUnion(members) }
            visibleStorage = QuickStat.storage(for: next)
        } label: {
            HStack(spacing: 8) {
                checkmark(all)
                Text(group.title).font(.system(size: 11, weight: .semibold))
                Text("(tümü)").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title): \(all ? String(localized: "tümünü gizle") : String(localized: "tümünü göster"))")
    }

    @ViewBuilder private func row(_ item: QuickStat) -> some View {
        let shown = visible.contains(item)
        if editing {
            Button {
                var next = visible
                if shown { next.remove(item) } else { next.insert(item) }
                visibleStorage = QuickStat.storage(for: next)
            } label: {
                HStack(spacing: 8) {
                    checkmark(shown)
                    stat(item).opacity(shown ? 1 : 0.55)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title(item)): \(shown ? String(localized: "gizle") : String(localized: "göster"))")
        } else {
            stat(item)
        }
    }

    private func checkmark(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 13))
            .foregroundStyle(on ? Color.green : Color.secondary)
            .frame(width: 16)
    }

    private func title(_ item: QuickStat) -> String {
        switch item {
        case .designCapacity: return String(localized: "Tasarım kapasitesi")
        case .fullCapacity: return String(localized: "Kullanılabilir kapasite")
        case .hardwarePercentage: return String(localized: "Donanım yüzdesi")
        case .cycles: return String(localized: "Döngü sayısı")
        case .temperature: return String(localized: "Batarya sıcaklığı")
        case .timeRemaining: return battery.snapshot.isCharging ? String(localized: "Tam doluma kalan") : String(localized: "Kalan süre")
        case .current: return String(localized: "Akım")
        case .voltage: return String(localized: "Gerilim")
        case .batteryPower: return String(localized: "Batarya gücü")
        case .systemPower: return String(localized: "Sistem yükü")
        case .adapterPower: return String(localized: "Adaptör gücü")
        case .adapterVoltage: return String(localized: "Adaptör voltajı")
        case .adapterCurrent: return String(localized: "Adaptör akımı")
        }
    }

    private func value(_ item: QuickStat) -> String {
        let s = battery.snapshot
        switch item {
        case .designCapacity: return s.reading(.designCapacity).text(digits: 0)
        case .fullCapacity: return String(localized: "\(s.reading(.fullCapacity).text(digits: 0)) · \(s.usableCapacityText)")
        case .hardwarePercentage: return s.reading(.hardwarePercentage).text(digits: 0)
        case .cycles: return s.reading(.cycles).text(digits: 0)
        case .temperature: return battery.temperatureText
        case .timeRemaining: return s.reading(.timeRemaining).text(digits: 0)
        case .current: return s.reading(.current).text(digits: 0)
        case .voltage: return s.reading(.voltage).text(digits: 2)
        case .batteryPower: return s.reading(.batteryPower).text()
        case .systemPower: return s.reading(.systemPower).text()
        case .adapterPower: return "\(s.reading(.adapterPower).text()) / \(s.reading(.adapterRatedPower).text())"
        case .adapterVoltage: return s.reading(.adapterVoltage).text()
        case .adapterCurrent: return s.reading(.adapterCurrent).text(digits: 2)
        }
    }

    private func squareStat(_ title: String, icon: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Color.primary.opacity(0.72)).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(battery.snapshot.available ? value : "—").font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
    }
    private func stat(_ item: QuickStat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon).frame(width: 15)
            Text(title(item))
            Spacer(minLength: 8)
            Text(battery.snapshot.available ? value(item) : "—").foregroundStyle(.primary).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.72))
        .help(item == .temperature ? battery.snapshot.temperatureSource : "")
    }
}

/// Real app icons don't change between 60s energy samples, so cache them by bundle path instead
/// of asking `NSWorkspace` again on every row redraw. Read/written only from view rendering (main thread).
@MainActor
enum EnergyIconCache {
    private static var images: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        if let cached = images[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        images[path] = icon
        return icon
    }
}

struct EnergyUsageView: View {
    @EnvironmentObject var battery: BatteryMonitor
    @AppStorage("energyThreshold") private var threshold = "medium"
    @AppStorage("includeBackgroundEnergyProcesses") private var includeBackground = false
    var compact = false
    var maximumApps = 2
    /// Kare (yarım genişlik) panel varyantı: yalnızca en yüksek enerjili uygulamalar,
    /// bağlı cihaz listesi olmadan.
    var square = false
    private var stale: Bool { battery.energySampleDate.map { Date().timeIntervalSince($0) > 60 } ?? false }

    private var minimumPower: Double {
        switch threshold { case "low": return 5; case "high": return 25; default: return 10 }
    }
    private var apps: [EnergyApp] {
        battery.energyApps.filter { (includeBackground || $0.isApplication) && $0.power >= minimumPower }
    }
    var body: some View {
        if square {
            HighEnergyUsageCard(minimumPower: minimumPower, maximumApps: maximumApps)
        } else {
            VStack(spacing: compact ? 12 : 16) {
                // The compact popover/panel/dashboard widget is the compact high-energy card, merging
                // into a single "Yüksek Enerji Kullanımı" card; the full settings Energy page keeps
                // the detailed per-process list.
                if compact {
                    HighEnergyUsageCard(minimumPower: minimumPower)
                } else {
                    applicationCard
                }
                ConnectedDevicesView(compact: compact)
            }
        }
    }

    private var applicationCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Düşük Güç Modu", systemImage: "battery.25")
                Spacer()
                Text(battery.lowPowerModeEnabled ? String(localized: "Açık") : String(localized: "Kapalı"))
                    .fontWeight(.semibold)
                    .foregroundStyle(battery.lowPowerModeEnabled ? .green : .secondary)
            }.font(.system(size: 12))
            Text("Sistem ayarı salt-okunur izlenir.").font(.system(size: 10)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Label("Enerji kullanan uygulamalar ve sistem", systemImage: "bolt.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            if let date = battery.energySampleDate {
                Text("Son ölçüm: \(date.formatted(date: .omitted, time: .standard))\(stale ? String(localized: " · Güncel değil") : "")")
                    .font(.system(size: 10)).foregroundStyle(stale ? .orange : .secondary).monospacedDigit()
            }
            if case .failed(let message) = battery.energySampleState, !apps.isEmpty {
                Text("Güncel değil · \(message)").font(.system(size: 10)).foregroundStyle(.orange)
            }
            if apps.isEmpty {
                energyStateText.font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(apps) { app in
                    EnergyAppRow(app: app)
                }
            }
            Text("Etki seviyesi macOS ölçümünden gelir; watt değeri değildir.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Picker("Gösterilecek etki", selection: $threshold) {
                Text("Daha çok sonuç").tag("low")
                Text("Dengeli").tag("medium")
                Text("Yalnız çok yüksek").tag("high")
            }.pickerStyle(.menu)
            HStack {
                Text("Arka plan süreçlerini dahil et")
                Spacer()
                Toggle("Arka plan süreçlerini dahil et", isOn: $includeBackground).labelsHidden().toggleStyle(.switch)
            }.font(.system(size: 12))
            Text("Uygulama listesi dakikada bir, bağlı cihazlar birkaç saniyede bir yenilenir. Kapalı pencerelerde uygulama ölçümü tercihe bağlıdır.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .modifier(GlassSurface())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var energyStateText: some View {
        switch battery.energySampleState {
        case .idle, .loading:
            Text("macOS etkinlik örneklemesi hazırlanıyor…")
        case .ready, .empty:
            Text("Eşik üzerinde uygulama yok")
        case .failed(let message):
            Text("Etkinlik örneklenemedi: \(message)")
        }
    }
}

typealias EnergyAppGroup = EnergyPresentation.EnergyAppGroup

/// The popover/panel/dashboard "Apps Using Significant Energy" widget: only quittable user apps,
/// helper processes merged into their owner app, capped to 5 rows, each with an always-visible
/// quit capsule ("Çıkış", no hover reveal, no confirm step).
struct HighEnergyUsageCard: View {
    @EnvironmentObject var battery: BatteryMonitor
    var minimumPower: Double
    /// Kare (yarım genişlik) varyantta yalnızca en üstteki N uygulama gösterilir.
    var maximumApps: Int?

    private var groups: [EnergyAppGroup] {
        EnergyPresentation.quittableAppGroups(
            from: battery.energyApps.filter { $0.power >= minimumPower }.map { (power: $0.power, iconPath: $0.iconPath) },
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            bundleIdentifier: { Bundle(path: $0)?.bundleIdentifier },
            displayName: { EnergyPresentation.ownerAppName(fromExecutablePath: $0) },
            limit: maximumApps ?? 5)
    }

    var body: some View {
        // This compact card is only ever shown in the popover/panel/dashboard, where an empty
        // card wastes space next to real content, so it disappears entirely when there is
        // nothing to show (the full settings Energy page has its own detailed list with an
        // explanatory empty state instead).
        if EnergyPresentation.shouldShowCard(itemCount: groups.count, compact: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Yüksek Enerji Kullanımı:")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(groups) { group in
                    HighEnergyUsageRow(group: group)
                }
            }
            .padding(13)
            .frame(minHeight: maximumApps != nil ? 150 : nil, maxHeight: maximumApps != nil ? 150 : nil, alignment: .top)
            .modifier(GlassSurface())
            .accessibilityElement(children: .contain)
        }
    }
}

private struct HighEnergyUsageRow: View {
    let group: EnergyAppGroup
    @State private var hovering = false
    private var target: NSRunningApplication? { EnergyQuitAction.target(forOwnerBundlePath: group.bundlePath) }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: EnergyIconCache.icon(forPath: group.bundlePath))
                .resizable().interpolation(.high).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
                Text(EnergyPresentation.impact(for: group.totalPower))
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            EnergyQuitControl(target: target, ownerName: group.name, revealed: hovering)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(group.name)
        .accessibilityElement(children: .contain)
    }
}

/// Shared trailing quit control: a "Çıkış" capsule revealed on row hover (no confirm step) that calls `terminate()` directly, then shows "Kapatılıyor…" until the row
/// disappears on the next sample, or "Reddetti" if `terminate()` returned false.
private struct EnergyQuitControl: View {
    let target: NSRunningApplication?
    let ownerName: String
    /// Shown only while the row is hovered; kept in the layout and to VoiceOver via opacity.
    var revealed = true
    private enum QuitState { case idle, quitting, rejected }
    @State private var state = QuitState.idle

    var body: some View {
        switch state {
        case .rejected:
            Text("Reddetti").font(.system(size: 10)).foregroundStyle(.orange)
        case .quitting:
            Text("Kapatılıyor…").font(.system(size: 10)).foregroundStyle(.secondary)
        case .idle:
            if let target {
                Button("Çıkış") { performQuit(target) }
                    .buttonStyle(QuitButtonStyle())
                    .opacity(revealed ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: revealed)
                    .accessibilityLabel("\(ownerName) uygulamasını kapat")
                    .help("\(ownerName) uygulamasını kapat")
            }
        }
    }

    /// `terminate()` only *asks* the app to quit (it may prompt to save); Healthy Battery never force-quits.
    /// A fresh energy sample has no public trigger on `BatteryMonitor`, so a successful request just
    /// waits in "Kapatılıyor…" until the row drops off the next 60 s sample.
    private func performQuit(_ target: NSRunningApplication) {
        state = .quitting
        if !target.terminate() { state = .rejected }
    }
}

/// Resolves which running application (if any) an energy-list row's Quit button should target.
/// Wraps `EnergyPresentation.quitTargetPID`'s pure logic with the real `Bundle`/`NSRunningApplication`
/// lookups; kept separate from the view so the view body stays a thin, previewable layout.
enum EnergyQuitAction {
    static func target(for app: EnergyApp) -> NSRunningApplication? {
        guard let pid = EnergyPresentation.quitTargetPID(
            rowPID: app.pid, isApplication: app.isApplication, iconPath: app.iconPath,
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            bundleIdentifier: { Bundle(path: $0)?.bundleIdentifier },
            ownerProcessIdentifier: { bundleIdentifier, bundlePath in
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .first { $0.bundleURL?.path == bundlePath }
                    .map { Int($0.processIdentifier) }
            },
            isRegularApp: { pid in
                NSRunningApplication(processIdentifier: pid_t(pid))?.activationPolicy == .regular
            }
        ) else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))
    }

    /// The owner app's display name, for the Quit button's tooltip/accessibility label
    /// (e.g. "Dia", not the full "Dia · bir web sayfası çalışıyor" row label).
    static func ownerDisplayName(for app: EnergyApp) -> String {
        guard let iconPath = app.iconPath,
              let name = EnergyPresentation.ownerAppName(fromExecutablePath: iconPath) else {
            return EnergyPresentation.displayName(for: app.name)
        }
        return name
    }

    /// As `target(for:)`, but for the merged popover card, which already knows the owner bundle path
    /// from `EnergyPresentation.quittableAppGroups` and doesn't need a row PID to start from.
    static func target(forOwnerBundlePath bundlePath: String) -> NSRunningApplication? {
        guard let bundleID = Bundle(path: bundlePath)?.bundleIdentifier,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.bundleURL?.path == bundlePath }),
              running.activationPolicy == .regular else { return nil }
        return running
    }
}

/// A row in the full settings Energy page's detailed, per-process list (system processes included).
/// Quittable rows reveal the same "Çıkış" capsule as the compact card on hover; direct `terminate()`.
struct EnergyAppRow: View {
    let app: EnergyApp
    @State private var hovering = false

    private var quitTarget: NSRunningApplication? { EnergyQuitAction.target(for: app) }
    private var ownerName: String { EnergyQuitAction.ownerDisplayName(for: app) }

    var body: some View {
        HStack(spacing: 9) {
            if let iconPath = app.iconPath {
                Image(nsImage: EnergyIconCache.icon(forPath: iconPath))
                    .resizable().interpolation(.high).frame(width: 16, height: 16)
            } else {
                Image(systemName: EnergyPresentation.symbolName(for: app.name))
                    .foregroundStyle(.secondary).frame(width: 16)
            }
            // The name gets layout priority so it's the last thing to truncate: the trailing metrics
            // are already as compact as they can be ("%11 CPU", not "İşlemci yükü 11.0%").
            Text(EnergyPresentation.displayName(for: app.name)).lineLimit(1).layoutPriority(1).help(app.name)
            Spacer(minLength: 8)
            Text(EnergyPresentation.impact(for: app.power))
                .fontWeight(.semibold)
                .help(String(format: String(localized: "macOS POWER puanı: %.1f"), app.power))
            Text(String(localized: "%\(Int(app.cpu.rounded())) CPU"))
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                .help("Birden çok çekirdek kullanıldığında yüzde 100'ü aşabilir.")
            EnergyQuitControl(target: quitTarget, ownerName: ownerName, revealed: hovering)
        }
        .font(.system(size: 12))
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}

struct ConnectedDevicesView: View {
    @EnvironmentObject var battery: BatteryMonitor
    @State private var ejectingDisk: String?
    @State private var ejectError: String?
    @State private var ejectSuccess = false
    var compact = false

    var body: some View {
        // The compact popover/panel/dashboard card disappears entirely when nothing is
        // connected; the full settings Energy page keeps the explanatory empty state below.
        if EnergyPresentation.shouldShowCard(itemCount: battery.connectedDevices.count, compact: compact) {
        VStack(alignment: .leading, spacing: compact ? 9 : 13) {
            HStack {
                Label("Bağlı cihazlar", systemImage: "cable.connector")
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
                Spacer()
                if !battery.connectedDevices.isEmpty {
                    Text("\(battery.connectedDevices.count) cihaz")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if battery.connectedDevices.isEmpty {
                Text("Şu anda USB üzerinden tanınan cihaz yok.")
                    .font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary)
                Text("Telefon, SSD veya USB bellek algılandığında burada görünür. Yalnız şarj bağlantıları cihaz adı bildirmeyebilir.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(battery.connectedDevices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.kind.icon)
                            .font(.system(size: 20)).frame(width: 28).foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).fontWeight(.medium)
                            Text(device.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(watts(device.powerWatts)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        if device.canEject {
                            Button(ejectingDisk == device.diskIdentifier ? String(localized: "Çıkarılıyor…") : String(localized: "Çıkar")) {
                                guard ejectingDisk == nil else { return }
                                ejectingDisk = device.diskIdentifier
                                ejectError = nil
                                ejectSuccess = false
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let error = ConnectedDeviceReader.eject(device)
                                    DispatchQueue.main.async {
                                        ejectingDisk = nil
                                        ejectError = error
                                        ejectSuccess = error == nil
                                        battery.refresh()
                                    }
                                }
                            }
                            .chargeMateButtonStyle()
                            .disabled(ejectingDisk != nil)
                        } else {
                            Text("Bağlı").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                        }
                    }.font(.system(size: compact ? 11 : 12))
                }
                if let ejectError { Text(ejectError).foregroundStyle(.red).font(.system(size: 10)) }
                if ejectSuccess { Text("Disk çıkarıldı; güvenle ayırabilirsiniz.").foregroundStyle(.green).font(.system(size: 10)) }
                if battery.connectedDevices.contains(where: { $0.powerWatts == nil }) {
                    Text("Birden fazla cihaz bağlıyken cihaz başına güç ayrılamaz.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(compact ? 13 : 14)
        .modifier(GlassSurface())
        .accessibilityElement(children: .contain)
        }
    }
}

enum BatteryMetric: String, CaseIterable {
    case level = "Batarya seviyesi", temperature = "Batarya sıcaklığı", power = "Sistem gücü", health = "Maksimum kapasite", cycles = "Döngü sayısı"
    /// Display name. The Turkish raw values stay as they are because they identify the metric.
    var title: String {
        switch self {
        case .level: return String(localized: "Batarya seviyesi")
        case .temperature: return String(localized: "Batarya sıcaklığı")
        case .power: return String(localized: "Sistem gücü")
        case .health: return String(localized: "Maksimum kapasite")
        case .cycles: return String(localized: "Döngü sayısı")
        }
    }
    var color: Color { switch self { case .level: return .green; case .temperature: return .blue; case .power: return .purple; case .health: return .orange; case .cycles: return .teal } }
    var icon: String { switch self { case .level: return "battery.100percent"; case .temperature: return "thermometer.medium"; case .power: return "bolt.fill"; case .health: return "heart.fill"; case .cycles: return "clock.arrow.circlepath" } }
    func value(_ point: BatteryHistoryPoint) -> Double? {
        switch self { case .level: return point.percentage.map(Double.init); case .temperature: return point.temperatureC; case .power: return point.systemWatts; case .health: return point.healthPercent; case .cycles: return point.cycleCount.map(Double.init) }
    }
    func text(_ snapshot: BatterySnapshot) -> String {
        guard snapshot.available else { return "—" }
        switch self {
        case .level: return snapshot.reading(.percentage).text(digits: 0)
        case .temperature: return snapshot.reading(.temperature).text()
        case .power: return snapshot.reading(.systemPower).text()
        case .health: return snapshot.reading(.health).text()
        case .cycles: return snapshot.reading(.cycles).text(digits: 0)
        }
    }
    func hoverText(_ value: Double) -> String {
        switch self {
        case .level, .health: return String(format: "%.1f %%", value)
        case .temperature: return String(format: "%.1f °C", value)
        case .power: return String(format: "%.1f W", value)
        case .cycles: return String(format: "%.0f", value)
        }
    }
}

struct MetricChartView: View {
    @EnvironmentObject var battery: BatteryMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("historyHours") private var hours = ChartRange.defaultHours
    @State private var zoomProgress = 0.0
    @State private var samples: [ChartSample] = []
    let metric: BatteryMetric
    var height: CGFloat = 118
    /// Kare (yarım genişlik) varyant: başlık, büyük güncel değer ve mini bir sparkline.
    /// Tam genişlik varyantın aksine yakınlaştırma/aralık detayına yer yoktur.
    var square: Bool = false
    var body: some View {
        let now = battery.history.last?.date ?? Date()
        VStack(alignment: .leading, spacing: square ? 4 : 0) {
            if square {
                // Only the header is inset; the plot runs edge to edge like the wide card's.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: metric.icon).font(.system(size: 11)).foregroundStyle(metric.color)
                        Text(metric.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(metric.text(battery.snapshot)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .padding(.horizontal, 12).padding(.top, 12)
                Spacer(minLength: 0)
            } else {
                HStack {
                    Text(metric.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.primary.opacity(0.72))
                    Spacer()
                    Image(systemName: metric.icon).foregroundStyle(metric.color)
                    Text(metric.text(battery.snapshot)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 9)
            }
            AnimatedHistoryPlot(samples: samples, now: now, selectedHours: hours, progress: zoomProgress,
                                metric: metric, height: square ? 78 : height, limitEvents: battery.limitEvents,
                                onHoverChanged: square ? { _ in } : updateOverview)
                .allowsHitTesting(!square)
            if !square, let error = battery.historyError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
            .frame(maxWidth: .infinity, minHeight: square ? 150 : nil, maxHeight: square ? 150 : nil, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .modifier(GlassSurface())
            .onAppear(perform: rebuildSamples)
            .onChange(of: battery.history.last?.date) { _ in rebuildSamples() }
    }

    private func updateOverview(_ hovering: Bool) {
        let target = hovering ? 1.0 : 0.0
        guard zoomProgress != target else { return }
        if reduceMotion { zoomProgress = target }
        else { withAnimation(.easeInOut(duration: 0.26)) { zoomProgress = target } }
    }

    private func rebuildSamples() {
        samples = battery.history.map { ChartSample(date: $0.date, value: metric.value($0)) }
    }
}

private struct AnimatedHistoryPlot: View, Animatable {
    let samples: [ChartSample]
    let now: Date
    let selectedHours: Int
    var progress: Double
    let metric: BatteryMetric
    let height: CGFloat
    let limitEvents: [LimitEvent]
    let onHoverChanged: (Bool) -> Void

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let idleHours = ChartRange.idleHours(isHealth: metric == .health)
        let animatedHours = ChartRange.animatedHours(selectedHours: selectedHours, progress: progress, idleHours: idleHours)
        let labelHours = ChartRange.displayHours(selectedHours: selectedHours, hovering: progress > 0.5, idleHours: idleHours)
        let data = ChartData(samples: samples, now: now, hours: animatedHours,
                             percentage: metric == .level, health: metric == .health)
        HistoryPlot(data: data, metric: metric, hours: labelHours, height: height,
                    detailProgress: progress,
                    limitEvents: limitEvents, onHoverChanged: onHoverChanged)
            .equatable()
    }
}

struct HistoryRangePicker: View {
    @AppStorage("historyHours") private var hours = ChartRange.defaultHours
    @Environment(\.colorScheme) private var scheme
    private let ranges = [1, 6, 24].map { ($0, String(localized: "\($0) sa")) }

    // One plain segmented capsule: glass chips inside a stroked capsule read as clutter.
    var body: some View {
        HStack(spacing: 0) {
            ForEach(ranges, id: \.0) { range in
                let selected = hours == range.0
                Button {
                    hours = range.0
                } label: {
                    Text(range.1)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selected {
                                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.22 : 0.12))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.1)
                .accessibilityValue(selected ? String(localized: "Seçili") : String(localized: "Seçili değil"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(width: 150, height: 26)
        .background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Grafik aralığı")
        .help("Geçmiş yerel olarak tutulur, en fazla 24 saat; veri uygulama açıkken birikir. 24 saatten uzun aralık sunulmaz.")
    }
}
