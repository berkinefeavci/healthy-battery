import SwiftUI

struct MenubarSettingsView: View {
    @EnvironmentObject var battery: BatteryMonitor
    @Environment(\.colorScheme) private var colorScheme
    @State private var preferences = MenubarPreferences.load()
    private let groups = ["Sağlık", "Batarya", "Adaptör", "Kontrol durumları"]

    private var presentation: MenubarPresentation {
        MenubarPresentation(preferences: preferences, snapshot: battery.snapshot, lowPower: battery.selectedPowerMode == .lowPower)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Seçili menü çubuğu öğeleri", systemImage: "menubar.rectangle").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if preferences.effectiveStyle != .hidden { Image(nsImage: icon(preferences.effectiveStyle).image).renderingMode(.original).id(colorScheme)
                            .frame(minWidth: 34, minHeight: 30).padding(5)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            .help(preferences.effectiveStyle.title)
                            .accessibilityLabel(preferences.effectiveStyle.title)
                        }
                        ForEach(preferences.metrics.filter { !(preferences.style == .iosBattery && $0 == .percentage) }) { metric in
                            selectedChip(metric)
                                .draggable(metric.rawValue)
                                .dropDestination(for: String.self) { items, _ in
                                    guard items.count == 1, let source = MenubarMetric(rawValue: items[0]), preferences.metrics.contains(source) else { return false }
                                    change { $0.move(source, before: metric) }; return true
                                }
                        }
                    }.padding(.vertical, 3)
                }
                let preview = MenubarRenderer.render(presentation, maxWidth: (NSScreen.main?.visibleFrame.width ?? 1440) * 0.35)
                HStack(spacing: 10) {
                    Text("Menüde görünüm").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Image(nsImage: preview.image).renderingMode(.original).id(colorScheme)
                            .frame(height: 24).accessibilityLabel(preview.description)
                    }
                }.help(preview.description)
                if preferences.accessFallback {
                    Text("Boş menüde erişim için durum simgesi gösterilir.").font(.caption).foregroundStyle(.secondary)
                }
                if let warning = preview.resourceWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                Text("Öğeleri sürükleyin; sıralama ve kaldırma seçenekleri için sağ tıklayın. Değişiklikler anında kaydedilir.")
                    .font(.caption).foregroundStyle(.secondary)
            }.chargeCard()

            Label("Menü çubuğu öğeleri kataloğu", systemImage: "book").font(.headline)
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Ana simge stili").font(.headline)
                        Text("Birini seçin").font(.caption).foregroundStyle(.secondary)
                    }
                    MenubarCatalogScroller(ids: MenubarStyle.allCases.map(\.rawValue)) { id in
                        if let style = MenubarStyle(rawValue: id) { styleButton(style) }
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("Ana simge seçenekleri").font(.headline)
                    MenubarCatalogScroller(ids: ["percentage", "tint"]) { id in
                        if id == "percentage" {
                            catalogButton(selected: preferences.style == .iosBattery || preferences.metrics.contains(.percentage),
                                          enabled: preferences.style != .iosBattery,
                                          help: preferences.style == .iosBattery ? String(localized: "iOS stilinde yüzde pilin içinde gösterilir.") : String(localized: "Menüde yüzde metnini göster veya gizle")) {
                                if preferences.style != .iosBattery { change { $0.toggle(.percentage) } }
                            } label: { Label("Yüzdeyi göster", systemImage: "percent") }
                        } else {
                            catalogButton(selected: preferences.lowPowerTint, help: String(localized: "Gerçek Düşük Güç Modunda simgeyi sarı göster")) {
                                change { $0.lowPowerTint.toggle() }
                            } label: { Label("Düşük Güç Modu rengi", systemImage: "paintpalette") }
                        }
                    }
                }
                ForEach(groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(groupTitle(group)).font(.headline)
                        MenubarCatalogScroller(ids: MenubarMetric.allCases.filter { $0.group == group && $0 != .percentage }.map(\.rawValue)) { id in
                            if let metric = MenubarMetric(rawValue: id) { metricButton(metric) }
                        }
                    }
                }
                Text("Kontrol göstergeleri ve macOS pil durumu, doğrulanmış kaynakları hazır olduğunda kullanılabilir olacak.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Spacer()
                    Button { change { $0 = MenubarPreferences() } } label: { Label("Sıfırla", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { change { $0.metrics = [] } } label: { Label("Tümünü temizle", systemImage: "trash") }
                }.chargeMateButtonStyle()
            }.chargeCard()

            VStack(alignment: .leading, spacing: 14) {
                Text("Yerleşim ve davranış").font(.headline)
                Stepper("Öğeler arası boşluk: \(preferences.spacing) pt", value: binding(\.spacing), in: 0...20)
                Stepper("Menüyü yenile: \(preferences.interval) saniye", value: binding(\.interval), in: 2...20)
                Picker("Sağ tık", selection: binding(\.rightClick)) {
                    ForEach(MenubarRightClick.allCases) { action in Text(action.title).tag(action).disabled(!action.supported) }
                }
                Text("Yenileme aralığı sensör örneklemesini değiştirmez. Geniş menülerde sağdaki öğeler +N altında toplanır; tüm değerler açıklamada bulunur.")
                    .font(.caption).foregroundStyle(.secondary)
            }.chargeCard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            let latest = MenubarPreferences.load()
            if latest != preferences { preferences = latest }
        }
    }

    private func groupTitle(_ group: String) -> String {
        switch group {
        case "Sağlık": return String(localized: "Batarya sağlığı")
        case "Batarya": return String(localized: "Batarya özellikleri")
        case "Adaptör": return String(localized: "Güç adaptörü özellikleri")
        default: return String(localized: "Healthy Battery durumları")
        }
    }
    private func change(_ update: (inout MenubarPreferences) -> Void) {
        update(&preferences); preferences = preferences.normalized(); preferences.save()
    }
    private func binding<Value>(_ keyPath: WritableKeyPath<MenubarPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: keyPath] }, set: { value in change { $0[keyPath: keyPath] = value } })
    }
    private func icon(_ style: MenubarStyle) -> MenubarRenderResult {
        var sample = preferences; sample.style = style; sample.metrics = []
        return MenubarRenderer.render(MenubarPresentation(preferences: sample, snapshot: battery.snapshot, lowPower: battery.selectedPowerMode == .lowPower), maxWidth: 120)
    }
    private func value(_ metric: MenubarMetric) -> String {
        var sample = preferences; sample.metrics = [metric]
        return MenubarPresentation(preferences: sample, snapshot: battery.snapshot, lowPower: battery.selectedPowerMode == .lowPower).values.first?.text ?? "—"
    }
    private func selectedChip(_ metric: MenubarMetric) -> some View {
        Button { change { $0.toggle(metric) } } label: {
            HStack(spacing: 5) {
                Image(systemName: metric.symbol)
                Text(value(metric)).monospacedDigit()
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
        }.buttonStyle(ChipButtonStyle(selected: false)).help("\(metric.title) · Tıklayarak kaldır; sürükleyerek sırala")
            .accessibilityLabel("\(metric.title): \(value(metric))")
            .contextMenu {
                Button("Sola taşı") { change { $0.move(metric, by: -1) } }.disabled(preferences.metrics.first == metric)
                Button("Sağa taşı") { change { $0.move(metric, by: 1) } }.disabled(preferences.metrics.last == metric)
                Button("Kaldır") { change { $0.toggle(metric) } }
            }
            .accessibilityAction(named: Text("Sola taşı")) { change { $0.move(metric, by: -1) } }
            .accessibilityAction(named: Text("Sağa taşı")) { change { $0.move(metric, by: 1) } }
    }
    private func styleButton(_ style: MenubarStyle) -> some View {
        catalogButton(selected: preferences.style == style, help: style.title) { change { $0.style = style } } label: {
            HStack(spacing: 7) {
                if style == .hidden { Image(systemName: "eye.slash") }
                else { Image(nsImage: icon(style).image).renderingMode(.original).id(colorScheme) }
                Text(style.title)
            }
        }
    }
    private func metricButton(_ metric: MenubarMetric) -> some View {
        catalogButton(selected: preferences.metrics.contains(metric), enabled: metric.unavailableReason == nil,
                      help: metric.unavailableReason ?? "\(metric.title): \(value(metric))") {
            change { $0.toggle(metric) }
        } label: { Label(metric.title, systemImage: metric.symbol) }
    }
    private func catalogButton<LabelContent: View>(selected: Bool, enabled: Bool = true, help: String,
                                                 action: @escaping () -> Void, @ViewBuilder label: () -> LabelContent) -> some View {
        Button(action: action) {
            label().fixedSize().padding(.horizontal, 12).frame(height: 30)
        }
        .buttonStyle(ChipButtonStyle(selected: selected))
        .disabled(!enabled).help(help)
            .accessibilityValue(selected ? String(localized: "Seçili") : String(localized: "Seçili değil"))
    }
}

private extension MenubarMetric {
    var symbol: String {
        switch self {
        case .percentage: return "percent"
        case .healthPercent: return "stethoscope"
        case .macOSCondition: return "cross.case"
        case .cycleCount: return "clock.arrow.circlepath"
        case .hardwarePercentage: return "gauge.medium"
        case .temperatureC: return "thermometer.medium"
        case .timeRemaining: return "clock"
        case .batteryCurrentMA, .batteryVoltageV, .batteryWatts: return "battery.100percent"
        case .systemWatts: return "laptopcomputer"
        case .adapterCurrentA, .adapterVoltageV, .adapterWatts: return "powerplug.fill"
        case .calibration: return "slider.vertical.3"
        case .heatProtection: return "flame"
        case .sailing: return "paperplane.fill"
        case .topUp: return "plus.circle"
        }
    }
}

private struct CatalogItemFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Arrows only scroll; choice state belongs to catalog buttons.
private struct MenubarCatalogScroller<Content: View>: View {
    let ids: [String]
    @ViewBuilder var content: (String) -> Content
    @State private var frames: [String: CGRect] = [:]
    @State private var space = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                let viewport = max(1, geometry.size.width - 52)
                let canLeft = (ids.first.flatMap { frames[$0]?.minX } ?? 0) < -1
                let canRight = (ids.last.flatMap { frames[$0]?.maxX } ?? 0) > viewport + 1
                HStack(spacing: 4) {
                    arrow("chevron.left", enabled: canLeft) {
                        guard let id = ids.last(where: { (frames[$0]?.minX ?? 0) < -1 }) else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .leading) }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ids, id: \.self) { id in
                                content(id).id(id).background(GeometryReader { item in
                                    Color.clear.preference(key: CatalogItemFrames.self, value: [id: item.frame(in: .named(space))])
                                })
                            }
                        }.padding(.vertical, 3)
                    }.coordinateSpace(name: space)
                        .onPreferenceChange(CatalogItemFrames.self) { frames = $0 }
                    arrow("chevron.right", enabled: canRight) {
                        guard let id = ids.first(where: { (frames[$0]?.minX ?? 0) > 1 }) else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .leading) }
                    }
                }
            }
        }.frame(height: 36)
    }
    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)) }
            .buttonStyle(IconCircleButtonStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.2)
            .accessibilityLabel(symbol == "chevron.left" ? String(localized: "Kataloğu sola kaydır") : String(localized: "Kataloğu sağa kaydır"))
    }
}
