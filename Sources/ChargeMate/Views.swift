import SwiftUI

struct TrailingToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack { Text(title); Spacer(); Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch) }
    }
}

struct PopoverView: View {
    @EnvironmentObject var battery: BatteryMonitor
    @AppStorage("popoverLayout") private var savedLayout = Data()
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(PanelSizeMode.storageKey) private var panelSizeMode = PanelSizeMode.normal.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var limitEditor = false
    @ObservedObject private var advanced = AdvancedChargeRunner.shared
    @State private var editing = false
    @State private var draft: [PlacedWidget] = []
    @State private var dragging: PanelWidget?
    @State private var dragOffset: CGSize = .zero
    @State private var cardFrames: [PanelWidget: CGRect] = [:]
    private static let cardSpace = "panelCards"
    @State private var saveError: String?
    @State private var galleryOpen = false
    @State private var footerHovered = false
    @ObservedObject private var installer = UpdateInstaller.shared

    init(showLimitEditor: Bool = false) {
        _limitEditor = State(initialValue: showLimitEditor)
    }

    private var shownLimit: Int { battery.adapterModeActive ? Int(battery.chargeLimit) : ChargeLimitDisplay.shown(native: battery.nativeLimit, preference: battery.chargeLimit) }

    private var layout: (items: [PlacedWidget], notice: String?) {
        let preferences = UserDefaults.standard
        var legacy: [PanelWidget] = [.statusExplanation]
        if preferences.object(forKey: "showPowerFlow") as? Bool ?? true { legacy.append(.powerFlow) }
        legacy += [.significantEnergy, .powerMode]
        if preferences.object(forKey: "showBatteryChart") as? Bool ?? true { legacy.append(.chartLevel) }
        if preferences.object(forKey: "showQuickStats") as? Bool ?? true { legacy.append(.specifications) }
        if preferences.object(forKey: "showBatteryChart") as? Bool ?? true { legacy.append(.chartPower) }
        return PopoverLayout.decode(savedLayout, legacy: legacy)
    }

    var body: some View {
        VStack(spacing: 0) {
            ChargeMateGlassContainer {
                VStack(spacing: 12) {
                    PolicyConflictBanner()
                    HStack(spacing: 7) {
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) { limitEditor.toggle() }
                        } label: {
                            Text("Sınır: %\(shownLimit)")
                        }
                        .popoverToolbarButtonStyle(active: limitEditor)
                        .help(limitEditor ? String(localized: "Şarj hedefi düzenleyicisini kapat") : String(localized: "Şarj hedefini düzenle"))
                        .accessibilityLabel("Şarj hedefi yüzde \(shownLimit); düzenleyiciyi \(limitEditor ? String(localized: "kapat") : String(localized: "aç"))")
                        Spacer(minLength: 0)
                        // Locked feature: icon only, so the usable actions keep their full labels in
                        // every language within the 360 pt panel.
                        Button {} label: { Image(systemName: "minus.circle") }
                            .popoverToolbarButtonStyle(iconOnly: true).disabled(true)
                            .accessibilityLabel("Deşarj yakında; henüz kullanılamıyor")
                            .help("Yakında · güvenli bataryadan çalışma kontrolü henüz doğrulanmadı")
                        Button {
                            battery.topUpActive ? battery.stopTopUp() : battery.startTopUp()
                        } label: {
                            HStack(spacing: 6) {
                                Text("Doldur")
                                Image(systemName: battery.topUpActive ? "xmark.circle" : "plus.circle")
                            }
                        }
                            .popoverToolbarButtonStyle(active: battery.topUpActive)
                            .disabled(!battery.topUpControlAvailable)
                            .accessibilityLabel(battery.topUpActive ? String(localized: "Doldurmayı iptal et") : String(localized: "Doldurmayı başlat"))
                            .help(battery.topUpActive ? String(localized: "Önceki limite dön") : battery.topUpBlockReason ?? String(localized: "Yüzde 100'e şarj et ve önceki limiti geri yükle"))
                        Button {
                            AppDelegate.shared?.showSettings(page: .dashboard)
                        } label: {
                            Image(systemName: "square.grid.2x2")
                        }
                        .popoverToolbarButtonStyle(iconOnly: true)
                        .accessibilityLabel("Healthy Battery menüsünü aç")
                        .help("Healthy Battery menüsünü aç")
                    }
                    ChargeLimitBar()
                    if let status = advanced.adapterStatusText {
                        Text(status)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if battery.topUpActive, let restore = battery.topUpRestoreLimit {
                        Text(ChargeLimitDisplay.topUpReturnText(limit: restore))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if limitEditor {
                        NativeLimitControls().chargeCard()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }.padding(16)
            }.fixedSize(horizontal: false, vertical: true).zIndex(1)
            Divider().padding(.horizontal, 16)
            ScrollView {
                ChargeMateGlassContainer {
                    VStack(spacing: 12) {
                        if let notice = saveError ?? layout.notice {
                            Text(notice).font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(Array(PopoverLayout.rows(for: visibleItems).enumerated()), id: \.offset) { _, row in
                            // The row holding the card being dragged draws above the others.
                            rowView(row).zIndex(Self.widgets(in: row).contains { $0 == dragging } ? 1 : 0)
                        }
                        if (editing ? draft : layout.items).isEmpty {
                            Text("Kart yok. Düzenleme modunda alttan kart ekleyebilirsiniz.").font(.callout).foregroundStyle(.secondary).chargeCard()
                        }
                        if editing {
                            Text("Kartları sürükleyerek sıralayın; kaldırmak için eksiye basın, boyutunu sağ alt köşeden değiştirin.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            VStack(spacing: 12) {
                                HStack { ReadOnlyBadge(); Spacer(); HistoryRangePicker() }
                                Text("Healthy Battery \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Bu Mac’te saklanır")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                if let update = UpdateCheck.rememberedUpdate() { updateRow(update) }
                                Text("Düzenleme moduna girmek için bir karta uzun basın.")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .opacity(footerHovered ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { footerHovered = inside } }
                        }
                    }.padding(16)
                    .coordinateSpace(name: Self.cardSpace)
                    .onPreferenceChange(PanelCardFramesKey.self) { cardFrames = $0 }
                }
                .overlayPreferenceValue(PanelEditAnchorsKey.self) { anchors in editOverlay(anchors) }
            }.scrollIndicators(.never, axes: .vertical).clipped().zIndex(0)
            if editing {
                editBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: (PanelSizeMode(rawValue: panelSizeMode) ?? .normal).width)
        .modifier(WindowSurface())
        .onReceive(NotificationCenter.default.publisher(for: .chargeMatePanelClosed)) { _ in
            editing = false; draft = []; dragging = nil; limitEditor = false; galleryOpen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .chargeMatePanelLongPress)) { _ in startEditing() }
        .onExitCommand { AppDelegate.shared?.closePanel() }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }

    private func move(_ widget: PanelWidget, by step: Int) {
        guard let from = draft.firstIndex(where: { $0.widget == widget }), draft.indices.contains(from + step) else { return }
        draft.swapAt(from, from + step)
    }

    private func toggleSize(_ widget: PanelWidget) {
        guard let index = draft.firstIndex(where: { $0.widget == widget }) else { return }
        setSize(widget, draft[index].size == .square ? .wide : .square)
    }

    private func setSize(_ widget: PanelWidget, _ size: WidgetSize) {
        guard let index = draft.firstIndex(where: { $0.widget == widget }), draft[index].size != size,
              widget.supportedSizes.contains(size) else { return }
        withAnimation(.easeOut(duration: 0.2)) { draft[index].size = size }
    }

    private var visibleItems: [PlacedWidget] {
        let items = editing ? draft : layout.items
        // Güç modu artık durum açıklamasının içinde. Ayrı kart, yalnız durum kartını
        // kaldırmayı seçen eski/özel düzenlerde erişilebilir kalır.
        return !editing && items.contains(where: { $0.widget == .statusExplanation })
            ? items.filter { $0.widget != .powerMode } : items
    }

    /// Bir düzen satırını render eder: tam genişlik tek kart, ya da yarım genişlikte
    /// iki kare kart (ya da tek kalan kare, sol yarıda). Sütun genişlikleri her zaman
    /// üst kapsayıcının (panelin) genişliğinden gelir, hiçbir zaman içerikten.
    @ViewBuilder private func rowView(_ row: WidgetRow) -> some View {
        switch row {
        case .wide(let item):
            cardRow(item)
        case .squarePair(let a, let b):
            HStack(alignment: .top, spacing: 12) {
                cardRow(a).frame(maxWidth: .infinity)
                cardRow(b).frame(maxWidth: .infinity)
            }
        case .squareSingle(let a):
            HStack(alignment: .top, spacing: 12) {
                cardRow(a).frame(maxWidth: .infinity)
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }

    private func cardRow(_ item: PlacedWidget) -> some View {
        widgetContent(item)
            .environment(\.panelEditing, editing)
            // Unrotated bounds for the remove badge and resize handle (drawn in editOverlay).
            .anchorPreference(key: PanelEditAnchorsKey.self, value: .bounds) { bounds in
                editing ? [PanelEditAnchor(widget: item.widget, size: item.size,
                                           resizable: item.widget.supportedSizes.count > 1, bounds: bounds)] : []
            }
            .editModeJiggle(active: editing && !reduceMotion, wide: item.size == .wide)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PanelCardFramesKey.self,
                                           value: editing ? [item.widget: proxy.frame(in: .named(Self.cardSpace))] : [:])
                }
            }
            // The whole card, not just its text, takes the long press and the drag.
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .offset(dragging == item.widget ? dragOffset : .zero)
            .scaleEffect(dragging == item.widget ? 1.03 : 1)
            .shadow(color: .black.opacity(dragging == item.widget ? 0.25 : 0), radius: 10, y: 4)
            .zIndex(dragging == item.widget ? 1 : 0)
            // A SwiftUI drag, not AppKit drag-and-drop: `onDrag` on these cards kept the panel
            // re-laying out every frame (100% CPU) for as long as edit mode had been entered.
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.cardSpace))
                .onChanged { value in dragging = item.widget; dragOffset = value.translation }
                .onEnded { value in drop(item.widget, at: value.location) },
                     including: editing ? .all : .subviews)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in startEditing() })
            .contextMenu {
                if !editing { Button("Kartları düzenle") { startEditing() } }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("Kartları düzenle")) { startEditing() }
            .accessibilityAction(named: Text("Kaldır")) { if editing { draft.removeAll { $0.widget == item.widget } } }
            .accessibilityAction(named: Text("Yukarı taşı")) { if editing { move(item.widget, by: -1) } }
            .accessibilityAction(named: Text("Aşağı taşı")) { if editing { move(item.widget, by: 1) } }
            .accessibilityAction(named: Text("Boyutu değiştir")) {
                guard editing, item.widget.supportedSizes.count > 1 else { return }
                toggleSize(item.widget)
            }
    }

    /// Drops `source` on the card under `location`: moving down places it after that card,
    /// moving up places it before, so a one-step move works in both directions.
    private func drop(_ source: PanelWidget, at location: CGPoint) {
        defer { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragging = nil; dragOffset = .zero } }
        guard let target = cardFrames.first(where: { $0.key != source && $0.value.contains(location) })?.key,
              let from = draft.firstIndex(where: { $0.widget == source }),
              let to = draft.firstIndex(where: { $0.widget == target }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            // After removing the source, index `to` is just past the target when moving down
            // and the target itself when moving up.
            draft.insert(draft.remove(at: from), at: to)
        }
    }

    private static func widgets(in row: WidgetRow) -> [PanelWidget] {
        switch row {
        case .wide(let a), .squareSingle(let a): return [a.widget]
        case .squarePair(let a, let b): return [a.widget, b.widget]
        }
    }

    private func startEditing() {
        guard !editing else { return }
        draft = layout.items; saveError = nil
        withAnimation(.easeOut(duration: 0.18)) { editing = true }
    }

    private func finishEditing(save: Bool) {
        guard editing else { return }
        if save {
            do { savedLayout = try PopoverLayout.encode(draft) }
            catch { saveError = String(localized: "Düzen kaydedilemedi: \(error.localizedDescription)"); return }
        }
        withAnimation(.easeOut(duration: 0.18)) { editing = false }
        draft = []; dragging = nil; galleryOpen = false
    }

    /// Remove badges and resize handles, drawn above the glass so the cards never cover them.
    private func editOverlay(_ anchors: [PanelEditAnchor]) -> some View {
        GeometryReader { proxy in
            ForEach(anchors.filter { $0.widget != dragging }) { anchor in
                let frame = proxy[anchor.bounds]
                WidgetEditBadge(systemImage: "minus", tint: .white, fill: .red) {
                    withAnimation(.easeOut(duration: 0.15)) { draft.removeAll { $0.widget == anchor.widget } }
                }
                // Centred on the corner, like Home Screen widgets, so it never covers the title.
                .position(x: frame.minX + 1, y: frame.minY + 1)
                .accessibilityLabel("\(anchor.widget.title) kaldır")
                if anchor.resizable {
                    WidgetResizeHandle(size: anchor.size) { setSize(anchor.widget, $0) }
                        .position(x: frame.maxX + 12 - WidgetResizeHandle.extent / 2,
                                  y: frame.maxY + 12 - WidgetResizeHandle.extent / 2)
                        .accessibilityLabel("\(anchor.widget.title) boyutunu \(anchor.size == .square ? String(localized: "geniş") : String(localized: "kare")) yap")
                }
            }
        }
    }

    /// Edit-mode bar pinned under the cards, so Add, Cancel and Done are reachable without scrolling.
    private var editBar: some View {
        let missing = PanelWidget.allCases.filter { widget in !draft.contains { $0.widget == widget } }
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Menu {
                    let cards = missing.filter { !$0.isChart }, charts = missing.filter(\.isChart)
                    if !cards.isEmpty { Section("Kartlar") { ForEach(cards) { addButton($0) } } }
                    if !charts.isEmpty { Section("Grafikler") { ForEach(charts) { addButton($0) } } }
                } label: {
                    Label(missing.isEmpty ? String(localized: "Tümü panelde") : String(localized: "Kart ekle"), systemImage: "plus")
                }
                .menuStyle(.button).menuIndicator(.hidden)
                .popoverToolbarButtonStyle()
                .fixedSize()
                .disabled(missing.isEmpty)
                .help(missing.isEmpty ? String(localized: "Bütün kartlar ve grafikler zaten panelde.")
                                      : String(localized: "Panelde olmayan bir kart ya da grafik ekle"))
                Spacer(minLength: 0)
                Button("İptal") { finishEditing(save: false) }
                    .popoverToolbarButtonStyle()
                Button("Bitti") { finishEditing(save: true) }
                    .popoverToolbarButtonStyle(active: true)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private func addButton(_ widget: PanelWidget) -> some View {
        Button(widget.title) {
            withAnimation(.easeOut(duration: 0.15)) {
                draft.append(PlacedWidget(widget, size: widget.supportedSizes.contains(.wide) ? .wide : .square))
            }
        }
        .help(widget.detail)
    }

    @ViewBuilder private func updateRow(_ update: UpdateCheck.Release) -> some View {
        switch installer.phase {
        case .working(let message):
            ProgressView(message).controlSize(.small).font(.system(size: 10))
        case .failed(let message):
            Text(message).font(.system(size: 10)).foregroundStyle(.orange).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sürüm \(update.version) sayfasını aç") { NSWorkspace.shared.open(update.pageURL) }
                .buttonStyle(.link).font(.system(size: 10))
        case .idle:
            Button("Yeni sürüm var: \(update.version) · Güncelle") { installer.install(update) }
                .buttonStyle(.link).font(.system(size: 10))
        }
    }

    @ViewBuilder private func widgetContent(_ item: PlacedWidget) -> some View {
        let square = item.size == .square
        switch item.widget {
        case .statusExplanation:
            VStack(alignment: .leading, spacing: 8) {
                Text("Şu anda ne oluyor?").font(.system(size: 12, weight: .semibold))
                Text(battery.policyState.title).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text(battery.statusSentence).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                PowerModeQuickControl(compact: true)
            }.frame(maxWidth: .infinity, alignment: .leading).chargeCard()
        case .powerFlow: PowerFlowView(snapshot: battery.snapshot, connectedDevices: battery.connectedDevices)
        case .significantEnergy: EnergyUsageView(compact: true, maximumApps: 2, square: square)
        case .powerMode:
            PowerModeQuickControl().chargeCard()
        case .specifications: square ? AnyView(QuickStatsView(square: true)) : AnyView(QuickStatsView().chargeCard())
        case .chartLevel: MetricChartView(metric: .level, square: square)
        case .chartTemperature: MetricChartView(metric: .temperature, square: square)
        case .chartPower: MetricChartView(metric: .power, square: square)
        case .chartHealth: MetricChartView(metric: .health, square: square)
        case .chartCycles: MetricChartView(metric: .cycles, square: square)
        }
    }
}

/// Modern "add card" gallery: a grid of preview tiles (name, one-line description, size chips)
/// replacing the old plain catalog list. Tapping a size chip adds the card at that size.
/// Not `private`: also rendered directly by the offscreen `WidgetGridPreview` verification tool
/// (Tests/WidgetGridPreview.swift), which needs to open it without simulating a pointer click.
struct WidgetGallerySheet: View {
    @Binding var draft: [PlacedWidget]
    let dismiss: () -> Void

    private var columns: [GridItem] { [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kart kataloğu").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Kapat") { dismiss() }.popoverToolbarButtonStyle()
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(PanelWidget.allCases) { item in
                        galleryTile(item)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360, height: 420)
    }

    private func galleryTile(_ item: PanelWidget) -> some View {
        let placed = draft.contains { $0.widget == item }
        return VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                sizeChip(String(localized: "Geniş"), size: .wide, item: item, disabled: placed)
                if item.supportedSizes.contains(.square) {
                    sizeChip(String(localized: "Kare"), size: .square, item: item, disabled: placed)
                }
                Spacer(minLength: 0)
                if placed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .modifier(GlassSurface(radius: 14))
        .accessibilityElement(children: .combine)
    }

    private func sizeChip(_ title: String, size: WidgetSize, item: PanelWidget, disabled: Bool) -> some View {
        Button {
            guard !draft.contains(where: { $0.widget == item }) else { return }
            draft.append(PlacedWidget(item, size: size))
        } label: {
            Text(title)
        }
        .buttonStyle(ChipButtonStyle(selected: false, compact: true))
        .disabled(disabled)
        .accessibilityLabel("\(item.title) · \(title) ekle")
    }
}

/// Measures the percentage text's rendered width so `ChargeLimitBar` can place the status glyph
/// just to its right when the fill is too narrow to center the glyph within it.
private struct PercentageTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChargeLimitBar: View {
    @EnvironmentObject var battery: BatteryMonitor
    @State private var draggingTarget: Double?
    @State private var isDragging = false
    @State private var isHovering = false
    @State private var percentageTextWidth: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("appReduceTransparency") private var appReduceTransparency = false

    private static let barHeight: CGFloat = 30
    private static let labelHeight: CGFloat = 24
    private static let pendingLineHeight: CGFloat = 14

    /// Marker shows the limit macOS really enforces; the draft only exists while dragging.
    private var target: Double {
        draggingTarget ?? Double(battery.adapterModeActive ? Int(battery.chargeLimit)
            : ChargeLimitDisplay.shown(native: battery.nativeLimit, preference: battery.chargeLimit))
    }
    private var draft: Double { draggingTarget ?? battery.chargeLimit }
    private var saved: Int? { battery.adapterModeActive ? Int(battery.chargeLimit) : battery.nativeLimit ?? battery.committedLimit }
    private func step(_ forward: Bool) {
        let limits = battery.barLimits.sorted()
        if let next = forward ? limits.first(where: { Double($0) > draft }) : limits.last(where: { Double($0) < draft }) {
            battery.chargeLimit = Double(next)
        }
    }
    private var stateSymbol: String {
        switch battery.snapshot.powerFlow.mode {
        case .charging: return "bolt.fill"
        case .adapterOnly: return "pause.fill"
        case .batteryOnly: return "battery.100percent"
        case .batteryAssist: return "arrow.triangle.branch"
        case .unavailable: return "ellipsis"
        }
    }
    private var currentPercentage: Double? { battery.snapshot.reading(.percentage).validValue }
    private var isDataUnavailable: Bool {
        battery.snapshot.powerFlow.mode == .unavailable || currentPercentage == nil
    }
    private var glassTint: Color { isDataUnavailable ? .secondary : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let clampedCurrent = min(100, max(0, currentPercentage ?? 0))
                let currentWidth: CGFloat = isDataUnavailable ? 0 : width * clampedCurrent / 100
                let targetWidth = width * min(100, max(0, target)) / 100
                let markerX = min(width - 1, max(1, targetWidth))

                ZStack(alignment: .leading) {
                    trackBackground
                    if currentWidth > 0 {
                        currentFill
                            .frame(width: currentWidth, alignment: .leading)
                            .overlay(
                                LinearGradient(colors: [.white.opacity(0.38), .clear],
                                               startPoint: .top, endPoint: .center)
                            )
                            // The fill must always end in a proper capsule cap, never a hard flat
                            // rectangle edge, whether or not it reaches the track's own rounded end.
                            .clipShape(Capsule())
                    }
                    Text(battery.percentageText)
                        .background(
                            GeometryReader { textProxy in
                                Color.clear.preference(key: PercentageTextWidthKey.self, value: textProxy.size.width)
                            }
                        )
                        .padding(.leading, 12)
                        .frame(width: width, height: Self.barHeight, alignment: .leading)
                    // Centered within the fill once it's wide enough; otherwise just right of the
                    // percentage text (still inside the fill); hidden if neither fits, so it never
                    // straddles the fill/track boundary the way a whole-bar center can.
                    if let glyphX = ChargeBarLayout.glyphCenterX(barWidth: width, fillWidth: currentWidth,
                                                                  textWidth: percentageTextWidth) {
                        Image(systemName: stateSymbol)
                            .position(x: glyphX, y: Self.barHeight / 2)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: width, height: Self.barHeight)
                .onPreferenceChange(PercentageTextWidthKey.self) { percentageTextWidth = $0 }
                .clipShape(Capsule())
                .overlay(alignment: .leading) {
                    // At limit 100 the marker would sit exactly on the bar's rounded right cap,
                    // where it either gets clipped or reads as a rendering glitch; there is also
                    // nothing left to mark once the target is the maximum, so it's hidden instead.
                    if Int(target.rounded()) < 100 {
                        DashedLine()
                            .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [3, 3]))
                            .frame(width: 2, height: Self.barHeight)
                            .offset(x: markerX - 1)
                    }
                }
                .overlay(Capsule().strokeBorder(.white.opacity(rimOpacity), lineWidth: 1))
                .overlay(Capsule().strokeBorder(.primary.opacity(focused ? 0.42 : 0), lineWidth: 1))
                .background(
                    ChargeBarDragArea(
                        onBegin: { isDragging = true },
                        onChange: { fraction in
                            let proposed = min(100, max(0, fraction * 100))
                            draggingTarget = battery.barLimits
                                .min(by: { abs(Double($0) - proposed) < abs(Double($1) - proposed) })
                                .map(Double.init)
                        },
                        onEnd: endDrag,
                        onHoverChanged: { hovering in isHovering = hovering }
                    )
                )
                .overlay(alignment: .topLeading) {
                    if isDragging {
                        dragLabel(Int(target))
                            .fixedSize()
                            .offset(x: clampedLabelX(markerX: markerX, width: width), y: -(Self.labelHeight + 6))
                    }
                }
                .help("Sürükleyerek hedefi belirleyin · Seçili hedef %\(Int(target))")
            }.frame(height: Self.barHeight)
            // Only takes space while a draft is pending, so the idle bar sits centered between the
            // toolbar and the next section instead of reading as glued to the top.
            if saved != Int(draft) {
                Text("Seçilen %\(Int(draft)) · uygulanmadı")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(height: Self.pendingLineHeight, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Şarj hedefi; bar üzerinde sürükleyip bırakınca uygulanır, yön tuşlarıyla taslak değişir")
        .accessibilityValue("Doluluk \(battery.percentageText), kayıtlı \(saved.map(String.init) ?? String(localized: "bilinmiyor")), taslak %\(Int(target))")
        .accessibilityAdjustableAction { direction in
            step(direction == .increment)
        }
        .focusable().focused($focused).quietVisualizationFocus()
        .onMoveCommand { direction in
            if direction == .right || direction == .up { step(true) }
            if direction == .left || direction == .down { step(false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chargeMatePanelClosed)) { _ in
            draggingTarget = nil; isDragging = false; isHovering = false
        }
    }

    private var rimOpacity: Double {
        let base = scheme == .dark ? 0.20 : 0.55
        let hoverBoost = scheme == .dark ? 0.14 : 0.18
        return isHovering ? base + hoverBoost : base
    }

    // `glassEffect` renders in its own layer that `clipShape` does not clip: live, the fill escaped
    // as a flat rectangle over the text. Plain shapes keep the bar exactly as previewed.
    @ViewBuilder private var trackBackground: some View {
        if reduceTransparency || appReduceTransparency {
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
        } else {
            Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.07))
        }
    }

    @ViewBuilder private var currentFill: some View {
        if reduceTransparency || appReduceTransparency {
            Rectangle().fill(glassTint.opacity(scheme == .dark ? 0.94 : 0.9))
        } else {
            Rectangle().fill(LinearGradient(colors: [glassTint.opacity(0.95), glassTint.opacity(0.80)],
                                            startPoint: .top, endPoint: .bottom))
        }
    }

    private func dragLabel(_ value: Int) -> some View {
        Text("Sınır %\(value)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .modifier(GlassSurface(radius: 11))
    }

    private func clampedLabelX(markerX: CGFloat, width: CGFloat) -> CGFloat {
        let approxHalf: CGFloat = 32
        return min(max(0, width - approxHalf * 2), max(0, markerX - approxHalf))
    }

    private func endDrag() {
        defer { draggingTarget = nil; isDragging = false }
        guard let draggingTarget else { return }
        let newValue = Int(draggingTarget)
        battery.chargeLimit = draggingTarget
        if battery.adapterModeActive || newValue != saved { battery.applyNativeLimit() }
    }
}

/// A single vertical dashed line spanning its own frame — used for the charge-limit marker.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 1))
        return path
    }
}

private struct ChargeBarDragArea: NSViewRepresentable {
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onHoverChanged: (Bool) -> Void
    func makeNSView(context: Context) -> ChargeBarTrackingView {
        let view = ChargeBarTrackingView()
        view.onBegin = onBegin; view.onChange = onChange; view.onEnd = onEnd; view.onHoverChanged = onHoverChanged
        return view
    }
    func updateNSView(_ nsView: ChargeBarTrackingView, context: Context) {
        nsView.onBegin = onBegin; nsView.onChange = onChange; nsView.onEnd = onEnd; nsView.onHoverChanged = onHoverChanged
    }
}

/// Plain NSView instead of a SwiftUI `DragGesture`: inside the non-activating menu-bar
/// panel (`MenuPanel`, `.nonactivatingPanel`), AppKit still treats the very first
/// mouseDown after the panel gains key status as an activation click and swallows it
/// before it reaches a gesture recognizer unless the responder opts in via
/// `acceptsFirstMouse(for:)`. SwiftUI views with only a `DragGesture` never opt in,
/// so the reported "limit not draggable" bug was the bar's first click being eaten;
/// dragging only appeared to work once a prior click elsewhere had already made the
/// panel key. Overriding `acceptsFirstMouse` here (same fix already used by
/// `ChartTrackingView` in HistoryPlot.swift) makes every click land immediately.
final class ChargeBarTrackingView: NSView {
    var onBegin: () -> Void = {}
    var onChange: (Double) -> Void = { _ in }
    var onEnd: () -> Void = {}
    var onHoverChanged: (Bool) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHoverChanged(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged(false) }
    override func mouseDown(with event: NSEvent) { onBegin(); report(event) }
    override func mouseDragged(with event: NSEvent) { report(event) }
    override func mouseUp(with event: NSEvent) { onEnd() }
    private func report(_ event: NSEvent) {
        guard bounds.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onChange(Double(min(1, max(0, point.x / bounds.width))))
    }
}

struct SettingsView: View {
    @EnvironmentObject var battery: BatteryMonitor
    @State var selection: SettingsPage = .dashboard
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirmingRecovery = false
    @State private var recoveryLimit: Int?
    private let scheduleStorageDirectory: URL?

    init(selection: SettingsPage = .dashboard, scheduleStorageDirectory: URL? = nil) {
        _selection = State(initialValue: selection)
        self.scheduleStorageDirectory = scheduleStorageDirectory
    }

    var body: some View {
            HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Image(systemName: "bolt.shield.fill").font(.system(size: 15)).foregroundStyle(Color.primary.opacity(0.72))
                    Text("Healthy Battery").font(.system(size: 13, weight: .semibold))
                }.padding(.horizontal, 12).padding(.top, 43).padding(.bottom, 13)
                sidebarButton(.dashboard)
                sidebarGroup(String(localized: "PİL BAKIMI"), pages: [.charge, .sleep, .energy])
                sidebarGroup(String(localized: "OTOMASYONLAR"), pages: [.schedule, .shortcuts])
                sidebarGroup(String(localized: "GÖRÜNÜM"), pages: [.popover, .menubar])
                sidebarGroup(String(localized: "DİĞER"), pages: [.general, .magsafeLED, .about])
                Spacer()
                Divider().padding(.horizontal, 10)
                HStack {
                    ReadOnlyBadge(compact: true)
                    Spacer()
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                        .buttonStyle(IconCircleButtonStyle()).help("Healthy Battery’ten çık")
                }.padding(10)
            }.padding(.horizontal, 10).frame(width: SettingsLayout.sidebarWidth).background(.ultraThinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if selection != .dashboard { HStack {
                    Text(selection.title).font(.system(size: 25, weight: .bold, design: .rounded))
                    Spacer()
                    Text(battery.percentageText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Color.primary.opacity(0.72))
                    Image(systemName: battery.snapshot.isCharging ? "battery.100percent.bolt" : "battery.100percent")
                        .foregroundStyle(battery.snapshot.isCharging ? .green : .secondary)
                }
                .frame(maxWidth: SettingsLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, SettingsLayout.pageHorizontalPadding)
                .padding(.top, 30).padding(.bottom, 16)
                }
                ScrollView {
                    ChargeMateGlassContainer {
                    VStack(alignment: .leading, spacing: SettingsLayout.cardSpacing) { pageContent }
                        .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
                        .padding(.horizontal, SettingsLayout.pageHorizontalPadding)
                        .padding(.top, selection == .dashboard ? 16 : 0)
                        .padding(.bottom, 20)
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never, axes: .vertical)
                .clipped()
            }.background(.clear)
            }
        .frame(minWidth: SettingsLayout.windowMinWidth, idealWidth: SettingsLayout.windowIdealWidth,
               maxWidth: .infinity, minHeight: SettingsLayout.windowMinHeight,
               idealHeight: SettingsLayout.windowIdealHeight, maxHeight: .infinity)
        .background(Color.clear)
        .modifier(WindowSurface())
        .onReceive(NotificationCenter.default.publisher(for: .chargeMateSettingsPage)) { notification in
            if let page = notification.object as? SettingsPage { selection = page }
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }

    private func sidebarGroup(_ title: String, pages: [SettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.5))
                .padding(.leading, 12).padding(.top, 15).padding(.bottom, 4)
            ForEach(pages) { sidebarButton($0) }
        }
    }
    private func sidebarButton(_ page: SettingsPage) -> some View {
        Button { selection = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page.icon).frame(width: 18)
                Text(page.title)
                Spacer(minLength: 0)
            }.font(.system(size: 12, weight: selection == page ? .medium : .regular))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(selection == page ? Color.accentColor : Color.primary)
                .background(selection == page ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).hoverSurface()
    }
    @ViewBuilder private var pageContent: some View {
        switch selection {
        case .dashboard:
            DashboardView()
        case .charge:
            chargeLimitCard
            ExternalChangeSettingsCard()
            topUpCard
            HealthSettingsCards()
            advancedLockedCard
            AdvancedChargeSettingsView(runner: AdvancedChargeRunner.shared)
        case .energy:
            EnergyUsageView()
            PowerFlowView(snapshot: battery.snapshot, connectedDevices: battery.connectedDevices).chargeCard()
            QuickStatsView().chargeCard()
            VStack(spacing: 12) {
                energyDetailRow(String(localized: "Gerilim"), value: battery.snapshot.reading(.voltage).text(digits: 2))
                energyDetailRow(String(localized: "Batarya akımı"), value: battery.snapshot.reading(.current).text(digits: 0))
                energyDetailRow(String(localized: "Batarya gücü (+ şarj / − tüketim)"), value: battery.snapshot.reading(.batteryPower).text())
                energyDetailRow(String(localized: "Tam şarj kapasitesi"), value: battery.snapshot.reading(.fullCapacity).text(digits: 0))
                energyDetailRow(String(localized: "Tasarım kapasitesi"), value: battery.snapshot.reading(.designCapacity).text(digits: 0))
                energyDetailRow(String(localized: "Adaptörün nominal gücü"), value: watts(battery.snapshot.adapterRatedWatts))
                energyDetailRow(String(localized: "Sıcaklık kaynağı"), value: battery.snapshot.temperatureSource)
            }.font(.system(size: 12)).chargeCard()
        case .sleep:
            SleepBehaviorView()
        case .schedule:
            ScheduleView(storageDirectory: scheduleStorageDirectory)
        case .shortcuts:
            ShortcutsSettingsView()
        case .popover: AppearanceView()
        case .menubar: MenubarSettingsView()
        case .general: GeneralSettingsView()
        case .magsafeLED: MagSafeLEDSettingsView()
        case .about:
            SupportCenterView()
        }
    }

    private func energyDetailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity)
    }

    /// Şarj sınırı kartı: bu ayfanın kendi taslak/uygula kontrolleri. Kasıtlı olarak
    /// `NativeLimitControls` yerine ayrı tutulur — o bileşen açılır panelde de kullanılıyor ve
    /// oradaki düzen bu sayfadan bağımsız değişebilir.
    private var chargeLimitCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Şarj sınırı", systemImage: "battery.100percent").font(.headline)
                Spacer()
                Text(battery.policyState.title).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    Text("Kayıtlı macOS limiti").font(.system(size: 12, weight: .semibold))
                    Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .help(controlNotice)
                Spacer()
                Text(battery.nativeLimit.map { "%\($0)" } ?? "—")
                    .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
            }
            Text(limitCaption).font(.caption).foregroundStyle(.secondary)
            if !battery.nativeLimits.isEmpty {
                HStack(spacing: 6) {
                    ForEach(battery.nativeLimits, id: \.self) { limit in
                        Button { battery.chargeLimit = Double(limit) } label: {
                            Text("\(limit)%").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ChipButtonStyle(selected: Int(battery.chargeLimit) == limit, tint: .green))
                        .accessibilityLabel("Hedef yüzde \(limit)")
                    }
                }
            }
            if battery.otherControllerRunning {
                Label("Başka bir şarj uygulaması açık; önce ondan çıkın.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if battery.applyingLimit {
                    Button(battery.cancellationRequested ? String(localized: "İptal bekleniyor…") : String(localized: "İsteği iptal et")) { battery.cancelLimitRequest() }
                        .chargeMateButtonStyle()
                        .disabled(battery.cancellationRequested || battery.controlRecoveryRequired)
                } else {
                    Button("İptal") { battery.cancelDraftLimit() }
                        .chargeMateButtonStyle()
                        .disabled((battery.nativeLimit ?? battery.committedLimit) == nil)
                }
                Spacer()
                Button(battery.applyingLimit ? String(localized: "Kaydediliyor…") : String(localized: "macOS’a uygula")) { battery.applyNativeLimit() }
                    .chargeMateButtonStyle()
                    .disabled(!battery.hardwareControlAvailable || battery.nativeLimit == Int(battery.chargeLimit))
            }
            if let message = battery.limitMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if battery.policyConflict != nil {
                HStack {
                    Button("Healthy Battery hedefini yeniden uygula") { battery.reapplyChargeMateTarget() }.chargeMateButtonStyle()
                    Button("macOS değerini benimse") { battery.adoptMacOSLimit() }.chargeMateButtonStyle()
                }.disabled(battery.applyingLimit || battery.otherControllerRunning)
            }
            if battery.controlRecoveryRequired {
                HStack(spacing: 6) {
                    Label("Önceki işlem kontrol edilmeli", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Spacer()
                    Button("İncele…") { recoveryLimit = battery.nativeLimit; confirmingRecovery = true }
                        .chargeMateButtonStyle()
                        .disabled(battery.nativeLimit == nil || battery.applyingLimit || battery.otherControllerRunning)
                }
            }
            if let current = battery.currentSystemLimit, current != battery.nativeLimit {
                Text("Kayıt ile sistemin bildirdiği limit (%\(current)) farklı.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Kaydetme doğrulaması, şarjın fiziksel olarak durduğunu göstermez.")
            }
        }
        .chargeCard()
        .alert("Belirsiz işlemi kapat", isPresented: $confirmingRecovery) {
            Button("Vazgeç", role: .cancel) { }
            Button("Mevcut ayarı kabul et") {
                if let expected = recoveryLimit { battery.reconcileNativeLimit(expectedLimit: expected) }
            }
        } message: {
            Text("macOS kayıtlı limiti: %\(recoveryLimit ?? 0). Bu işlem ayarı değiştirmez. Değer yeniden okunur, önceki işlem kaydı korunur ve uygunsa kilit kaldırılır. Yeni hedef için ayrıca Uygula gerekir.")
        }
    }

    private var limitCaption: String {
        if !battery.nativeLimits.contains(Int(battery.chargeLimit)) {
            return String(localized: "Bu Mac’in yerel arayüzü %80–100 arasında, beşer puanlık limitler sunuyor.")
        }
        return battery.nativeLimit == Int(battery.chargeLimit)
            ? String(localized: "macOS kaydıyla eşleşiyor") : String(localized: "Taslak hedef: %\(Int(battery.chargeLimit)) · henüz uygulanmadı")
    }

    private var topUpCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Doldur (Top Up)", systemImage: "plus.circle").font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(battery.topUpActive ? String(localized: "Doldurma sürüyor") : String(localized: "Hazır")).font(.system(size: 12, weight: .semibold))
                    Text("Yüzde 100’e şarj eder, sonra önceki limite döner.")
                        .font(.caption).foregroundStyle(.secondary)
                    if battery.topUpActive, let restore = battery.topUpRestoreLimit {
                        Text(ChargeLimitDisplay.topUpReturnText(limit: restore))
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(battery.topUpActive ? String(localized: "İptal et") : String(localized: "Başlat")) {
                    battery.topUpActive ? battery.stopTopUp() : battery.startTopUp()
                }
                .chargeMateButtonStyle()
                .disabled(!battery.topUpControlAvailable)
                .accessibilityLabel(battery.topUpActive ? String(localized: "Doldurmayı iptal et") : String(localized: "Doldurmayı başlat"))
                .help(battery.topUpActive ? String(localized: "Önceki limite dön") : String(localized: "Yüzde 100'e şarj et ve önceki limiti geri yükle"))
            }
        }.chargeCard()
    }

    private var advancedLockedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Gelişmiş", systemImage: "lock.fill").font(.headline)
            lockedRow(String(localized: "Deşarj"), icon: "minus.circle", detail: String(localized: "Bataryadan çalışmayı zorlar; güvenli bataryadan çalışma kontrolü henüz doğrulanmadı."))
            Divider()
            lockedRow(String(localized: "Yelken modu"), icon: "sailboat", detail: String(localized: "Şarj ve boşalmayı hedef bandında dengeler."))
            Divider()
            lockedRow(String(localized: "Isı koruması"), icon: "thermometer.snowflake", detail: String(localized: "Yüksek sıcaklıkta şarjı geçici olarak durdurur."))
            Divider()
            lockedRow(String(localized: "Kalibrasyon"), icon: "arrow.triangle.2.circlepath", detail: String(localized: "Beş aşamalı tam şarj/deşarj döngüsünü otomatik yönetir."))
            Text("Fiziksel durdurma desteği doğrulanınca eklenecek. Etkisiz anahtar gösterilmez.")
                .font(.caption).foregroundStyle(.secondary)
        }.chargeCard()
    }

    private func lockedRow(_ title: String, icon: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            StatusBadge(text: String(localized: "Yakında · donanım doğrulaması bekliyor"), color: .secondary, icon: "clock")
        }
        .help(detail)
        .opacity(0.72)
    }
}

private struct AppearanceView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("appReduceTransparency") private var reduceTransparency = false
    @AppStorage(PanelSizeMode.storageKey) private var panelSizeMode = PanelSizeMode.normal.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Açılır paneli kişiselleştirin").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Panel boyutu").font(.system(size: 12, weight: .semibold))
                    Picker("Panel boyutu", selection: $panelSizeMode) {
                        ForEach(PanelSizeMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(panelSizeHint)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Panel yüksekliği seçilen moda ve ekrana göre sınırlanır; kartlar içeride kaydırılır.")
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                Divider()
                Picker("Görünüm", selection: $appearance) {
                    Text("Sistem").tag("system")
                    Text("Açık").tag("light")
                    Text("Koyu").tag("dark")
                }.pickerStyle(.segmented)
                Divider()
                TrailingToggle(title: String(localized: "Saydamlığı azalt"), isOn: $reduceTransparency)
                Text("Kart eklemek, kaldırmak ve sıralamak için paneldeki bir karta uzun basın veya sağ tıklayıp “Kartları düzenle”yi seçin. Kompakt boyutta da seçtiğiniz kartlar korunur.")
                    .font(.caption).foregroundStyle(.secondary)
        }.toggleStyle(.switch).chargeCard()
    }

    /// Panel boyut modu seçiminin ne yaptığını açıklayan kısa metin.
    var panelSizeHint: String {
        switch PanelSizeMode(rawValue: panelSizeMode) ?? .normal {
        case .compact: return String(localized: "Kompakt: 340 pt genişlik — dar ekranlar ve sade görünüm için.")
        case .normal: return String(localized: "Normal: 400 pt genişlik — varsayılan düzen.")
        case .detailed: return String(localized: "Detaylı: 520 pt genişlik — grafikler ve istatistikler için daha fazla yer.")
        }
    }

}
