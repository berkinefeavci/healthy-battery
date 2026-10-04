import SwiftUI

struct MagSafeLEDSettingsView: View {
    @EnvironmentObject private var battery: BatteryMonitor
    @AppStorage(MagSafeLEDPreferences.policyKey) private var policyRaw = MagSafeLEDPolicy.system.rawValue
    @AppStorage(MagSafeLEDPreferences.completionKey) private var completionRaw = MagSafeLEDCompletionBehavior.green.rawValue
    @AppStorage(MagSafeLEDPreferences.blinkKey) private var blinkWhileDischarging = false
    @State private var capability = MagSafeLEDCapability(
        connection: .none, probeState: .checking, writerReady: false, supportedOutputs: []
    )
    @State private var helperInstalled = false
    @State private var isWorking = false
    @State private var testMessage = ""
    @State private var testFailed = false
    @State private var policyMessage = ""
    @State private var pausedByTest = false
    @State private var loadedSelection = false
    @AppStorage(MagSafeLEDTimeWindow.startKey) private var startMinute = MagSafeLEDTimeWindow.defaultStart
    @AppStorage(MagSafeLEDTimeWindow.endKey) private var endMinute = MagSafeLEDTimeWindow.defaultEnd

    private var policy: Binding<MagSafeLEDPolicy> {
        Binding(get: { MagSafeLEDPolicy(rawValue: policyRaw) ?? .system },
                set: { policyRaw = $0.rawValue; policyMessage = "" })
    }

    private var completion: Binding<MagSafeLEDCompletionBehavior> {
        Binding(get: { MagSafeLEDCompletionBehavior(rawValue: completionRaw) ?? .green },
                set: { completionRaw = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerCard
            policyCard
            if policy.wrappedValue == .status { mappingCard }
            diagnosticCard
        }
        .onAppear {
            refreshCapability()
            if !loadedSelection {
                switch MagSafeLEDHardwareService.helperState() {
                case .policy(let saved, let start, let end):
                    policyRaw = saved.rawValue
                    if saved == .scheduled { startMinute = start; endMinute = end }
                case .pausedByTest: pausedByTest = true
                case nil: break
                }
                let times = MagSafeLEDTimeWindow.repaired(policy: policy.wrappedValue, start: startMinute, end: endMinute)
                startMinute = times.start; endMinute = times.end
                loadedSelection = true
            }
        }
        .onChange(of: battery.snapshot.externalConnected) { _ in refreshCapability() }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "light.beacon.max.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                    .frame(width: 48, height: 48)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text("MagSafe ışığı").font(.headline)
                    Text("Şarj kablosundaki durum ışığının Healthy Battery durumlarını nasıl göstereceğini seçin.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(text: helperInstalled ? String(localized: "Işık denetimi hazır") : String(localized: "Kurulum gerekli"),
                            color: helperInstalled ? .green : .orange,
                            icon: helperInstalled ? "checkmark.circle" : "shield.lefthalf.filled")
            }
            Divider()
            Label(capabilityExplanation, systemImage: capabilityIcon)
                .font(.caption)
                .foregroundStyle(helperInstalled ? Color.green : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Her zaman kapalı ve saat aralığı uygulama kapalıyken de çalışır. Saatler bu Mac’in yerel saatidir.")
                .font(.caption).foregroundStyle(.secondary)
        }.chargeCard()
    }

    private var policyCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Işık politikası", systemImage: "switch.2").font(.headline)
            HStack(spacing: 4) {
                ForEach([MagSafeLEDPolicy.system, .alwaysOff, .scheduled]) { item in
                    Button { policy.wrappedValue = item } label: {
                        Text(item.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChipButtonStyle(selected: policy.wrappedValue == item))
                    .accessibilityAddTraits(policy.wrappedValue == item ? .isSelected : [])
                }
            }
            .disabled(isWorking || battery.otherControllerRunning)
            if policy.wrappedValue == .scheduled {
                HStack(spacing: 24) {
                    timeControl(String(localized: "Kapanış"), minutes: $startMinute)
                    timeControl(String(localized: "Açılış"), minutes: $endMinute)
                }.disabled(isWorking)
                Text(startMinute == endMinute ? String(localized: "Aynı başlangıç ve bitiş saati: bütün gün kapalı.") : String(localized: "Her gün bu aralıkta kapalı; aralık dışında macOS yönetir. Gece yarısını aşan aralıklar desteklenir."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Uygula") { applyPolicy(policy.wrappedValue) }
                .chargeMateButtonStyle()
                .disabled(isWorking || battery.otherControllerRunning || !helperInstalled)
            if battery.otherControllerRunning { Text("Başka bir şarj uygulaması açıkken ışık denetimi bekler.").font(.caption) }
            if !helperInstalled && !isWorking {
                // An older helper (from Healthy Battery 1.0) still answers on the socket but is not trusted
                // any more; sending it the policy only produced an unclear wait.
                Text("Önce aşağıdaki 'Işık denetimini etkinleştir' ile ışık yardımcısını kurun veya güncelleyin; yönetici şifresi bir kez istenir.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pausedByTest && !isWorking {
                HStack(spacing: 10) {
                    Label("Manuel test otomatik ışık ayarını duraklattı.", systemImage: "pause.circle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Devam ettir") { restoreLED() }.chargeMateButtonStyle()
                }
            }
            if isWorking { ProgressView(String(localized: "Ayar uygulanıyor…")) }
            if !policyMessage.isEmpty { Text(policyMessage).font(.caption).foregroundStyle(.secondary) }

            if policy.wrappedValue == .status {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Şarj tamamlandığında").font(.system(size: 12, weight: .semibold))
                        Text("Hedefe veya %100’e ulaşıldığı doğrulandığında.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Şarj tamamlandığında", selection: completion) {
                        ForEach(MagSafeLEDCompletionBehavior.allCases) { item in Text(item.title).tag(item) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 190)
                }
                Toggle("Boşalırken turuncu yanıp sönsün", isOn: $blinkWhileDischarging)
                    .toggleStyle(.switch)
                Text("Yanıp sönme yalnız MagSafe 3 ve doğrulanmış bir backend destekliyorsa uygulanır; desteklenmeyen durumda sabit turuncuya sessizce çevrilmez.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.chargeCard()
    }

    private var mappingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Duruma göre renkler", systemImage: "circle.hexagongrid.fill").font(.headline)
            mappingRow(String(localized: "Şarj oluyor"), color: .orange, result: String(localized: "Turuncu"))
            mappingRow(String(localized: "Şarj hedefi tamamlandı"), color: completion.wrappedValue == .green ? .green : .secondary,
                       result: completion.wrappedValue.title)
            mappingRow(String(localized: "Isı koruması bekletiyor"), color: .orange, result: String(localized: "Turuncu"))
            mappingRow(String(localized: "Boşalıyor"), color: .orange,
                       result: blinkWhileDischarging ? String(localized: "Turuncu yanıp sönme") : String(localized: "Turuncu"))
            Text("Bilinmeyen, çelişkili veya eski ölçümde Healthy Battery ışığı değiştirmez.")
                .font(.caption).foregroundStyle(.secondary)
        }.chargeCard()
    }

    private var diagnosticCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Fiziksel ışık testi", systemImage: "wrench.and.screwdriver.fill").font(.headline)
                Spacer()
                Button { refreshCapability() } label: { Label("Yeniden denetle", systemImage: "arrow.clockwise") }
                    .chargeMateButtonStyle()
            }
            Text("Manuel deneme otomatik ışık ayarını duraklatır. 'Testi bitir' kayıtlı ayara döner; Healthy Battery yeniden açıldığında da kendiliğinden devam eder.")
                .font(.callout).foregroundStyle(.secondary)
            if !helperInstalled {
                Button { installHelper() } label: {
                    Label("Işık denetimini etkinleştir", systemImage: "lock.shield")
                }
                .chargeMateButtonStyle()
                .disabled(isWorking)
            }
            HStack {
                testButton(String(localized: "Yeşil"), icon: "circle.fill", output: .green, tint: .green)
                testButton(String(localized: "Turuncu"), icon: "circle.fill", output: .orange, tint: .orange)
                testButton(String(localized: "Kapalı"), icon: "lightbulb.slash", output: .off)
                Button("Testi bitir") { restoreLED() }
                    .chargeMateButtonStyle()
                    .disabled(!helperInstalled || isWorking)
            }
            if isWorking { ProgressView(String(localized: "Işık doğrulanıyor…")) }
            if !testMessage.isEmpty {
                Text(testMessage).font(.caption).foregroundStyle(testFailed ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
        }.chargeCard()
    }

    private func mappingRow(_ title: String, color: Color, result: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(result).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private func testButton(_ title: String, icon: String, output: MagSafeLEDOutput, tint: Color? = nil) -> some View {
        Button { runTest(output) } label: {
            Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(tint ?? .primary) }
        }
            .chargeMateButtonStyle()
            .disabled(!helperInstalled || isWorking || !battery.snapshot.externalConnected)
            .help("MagSafe ışığını seçili duruma getirir.")
    }

    private var capabilityExplanation: String {
        switch capability.probeState {
        case .checking: return String(localized: "MagSafe LED yeteneği salt okunur olarak denetleniyor.")
        case .noAdapter: return String(localized: "Adaptör bağlı değil. MagSafe bağlantı türü doğrulanamadı.")
        case .candidateKeyFound: return helperInstalled
            ? String(localized: "LED denetimi bağlı. Kalıcı ayarı veya aşağıdaki manuel düğmeleri kullanabilirsiniz.")
            : String(localized: "LED anahtarı okunuyor. Manuel deneme için aşağıdaki yardımcının kurulması gerekiyor.")
        case .candidateKeyUnavailable: return String(localized: "Adaptör bağlı, fakat aday LED denetleyici anahtarı bu kullanıcı oturumunda okunamadı.")
        case .malformedCandidate: return String(localized: "Aday LED verisi beklenen güvenli biçimle uyuşmuyor; kontrol devre dışı tutuldu.")
        }
    }

    private var capabilityIcon: String {
        switch capability.probeState {
        case .candidateKeyFound: return "eye.fill"
        case .noAdapter: return "powerplug.fill"
        case .checking: return "hourglass"
        case .candidateKeyUnavailable, .malformedCandidate: return "exclamationmark.triangle.fill"
        }
    }

    private func refreshCapability() {
        capability = .liveProbe(externalConnected: battery.snapshot.externalConnected)
        helperInstalled = MagSafeLEDHardwareService.installed()
    }

    private func timeControl(_ title: String, minutes: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.callout)
            Spacer()
            Picker("\(title) saati", selection: Binding(get: { minutes.wrappedValue / 60 },
                set: { minutes.wrappedValue = $0 * 60 + minutes.wrappedValue % 60 })) {
                ForEach(0..<24) { Text(String(format: "%02d", $0)).tag($0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 66)
            Text(":")
            Picker("\(title) dakikası", selection: Binding(get: { minutes.wrappedValue % 60 },
                set: { minutes.wrappedValue = minutes.wrappedValue / 60 * 60 + $0 })) {
                ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 66)
        }.frame(maxWidth: .infinity)
    }

    private func applyPolicy(_ selected: MagSafeLEDPolicy) {
        guard !isWorking else { return }
        guard MagSafeLEDHardwareService.installed() else {
            helperInstalled = false
            testMessage = String(localized: "LED yardımcısı kurulmamış. Önce denetimi etkinleştirin.")
            return
        }
        let start = startMinute, end = endMinute
        isWorking = true
        policyMessage = String(localized: "Ayar kaydediliyor…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try MagSafeLEDHardwareService.configure(policy: selected, start: start, end: end)
                DispatchQueue.main.async {
                    policyRaw = selected.rawValue
                    helperInstalled = MagSafeLEDHardwareService.installed()
                    policyMessage = String(localized: "Uygulandı: \(selected.title). Işık birkaç saniye içinde güncellenir.")
                    pausedByTest = false; testMessage = ""
                    isWorking = false
                }
            } catch {
                DispatchQueue.main.async { policyMessage = error.localizedDescription; isWorking = false }
            }
        }
    }

    private func installHelper() {
        isWorking = true
        testMessage = String(localized: "Yönetici izni bekleniyor…")
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do {
                try MagSafeLEDHardwareService.install()
                message = String(localized: "Işık yardımcısı kuruldu. Manuel renk düğmeleri hazır.")
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                helperInstalled = MagSafeLEDHardwareService.installed()
                testMessage = message
                isWorking = false
            }
        }
    }

    private func runTest(_ output: MagSafeLEDOutput) {
        isWorking = true
        testFailed = false
        testMessage = String(localized: "Işık değiştiriliyor…")
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = MagSafeLEDHardwareService.shared.apply(output)
            let paused = MagSafeLEDHardwareService.helperState() == .pausedByTest
            DispatchQueue.main.async {
                testMessage = outcomeMessage(outcome)
                if case .blocked = outcome { testFailed = true }
                pausedByTest = paused
                isWorking = false
            }
        }
    }

    private func restoreLED() {
        isWorking = true
        testFailed = false
        testMessage = String(localized: "Kayıtlı ışık politikası yeniden uygulanıyor…")
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = MagSafeLEDHardwareService.shared.restore()
            let paused = MagSafeLEDHardwareService.helperState() == .pausedByTest
            DispatchQueue.main.async {
                testMessage = outcomeMessage(outcome)
                if case .blocked = outcome { testFailed = true }
                pausedByTest = paused
                isWorking = false
            }
        }
    }

    private func outcomeMessage(_ outcome: MagSafeLEDControlCoordinator.Outcome) -> String {
        switch outcome {
        case .applied: return String(localized: "Işık değişti.")
        case .unchanged: return String(localized: "LED durumu değişmedi.")
        case .restored: return String(localized: "Test bitti; kayıtlı ışık politikası yeniden uygulandı.")
        case .blocked(let reason): return String(localized: "İşlem durduruldu: \(reason)")
        }
    }
}
