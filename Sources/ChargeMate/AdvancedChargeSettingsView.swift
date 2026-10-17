import SwiftUI

/// Experimental settings for the advanced charge engine and adapter mode. Controls that need a verified
/// charge-inhibit key appear only when this Mac has one (or while adapter mode runs); nothing here writes to
/// the hardware without the helper.
struct AdvancedChargeSettingsView: View {
    @ObservedObject var runner: AdvancedChargeRunner
    @ObservedObject private var adapter = AdapterModeController.shared

    private var supported: Bool { runner.capabilities.canInhibitCharging }
    /// Verified adapter cut (helper + passed self-test): Discharge and Calibration work through it.
    private var adapterCut: Bool { !supported && adapter.adapterCutAvailable }
    private var canDischarge: Bool { (supported && runner.capabilities.canForceDischarge) || adapterCut }
    private var limitControls: Bool { supported || adapter.active }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Gelişmiş şarj (deneysel)", systemImage: "flask").font(.headline)
                Spacer()
                StatusBadge(text: statusText, color: (supported || adapterCut) ? .green : .secondary, icon: (supported || adapterCut) ? "checkmark.circle" : "lock.fill")
            }
            adapterModeSection
            Divider()
            if adapter.active {
                // Adapter mode status replaces the generic "locked" text.
            } else if adapterCut {
                Text("Adaptör modu kapalı: sınırı macOS tutar. Deşarj ve kalibrasyon yine de aşağıdan adaptör kesilerek çalışır.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !supported && adapter.helperInstalled {
                Text("Bu Mac şarjı takılıyken durdurmaya izin vermiyor; Healthy Battery bunun yerine adaptörü keser. Deşarj, kalibrasyon ve adaptör modu, otomatik adaptör testi geçince açılır.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !supported {
                Text(runner.capabilities.reason ?? String(localized: "Şarj durdurma yardımcısı kurulu ya da doğrulanmış değil. Bu ayarlar şimdilik etkisizdir ve donanıma hiçbir şey yazmaz."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !runner.reason.isEmpty {
                Text(runner.reason).font(.caption).foregroundStyle(.secondary)
            }
            // Without a verified lever these controls cannot do anything: hidden, not greyed out.
            if limitControls {
                Divider()
                Group {
                    if adapter.active {
                        Text("Hedef sınır ana sınır çubuğundan ayarlanır (%\(runner.settings.targetLimit)).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                    Stepper(value: Binding(get: { runner.settings.targetLimit },
                                           set: { runner.settings.targetLimit = AdvancedChargeLimits.normalizedTarget($0) }),
                            in: AdvancedChargeLimits.minTarget...AdvancedChargeLimits.maxTarget, step: AdvancedChargeLimits.targetStep) {
                        Text("Hedef sınır: %\(runner.settings.targetLimit)")
                    }
                    }
                    Toggle("Yelken modu", isOn: $runner.settings.sailingEnabled)
                    if runner.settings.sailingEnabled {
                        Stepper(value: $runner.settings.sailingDelta,
                                in: (adapter.active ? AdvancedChargeLimits.adapterMinBand : AdvancedChargeLimits.minSailingDelta)...AdvancedChargeLimits.maxSailingDelta) {
                            Text("Yelken aralığı: %\(runner.settings.sailingDelta) (şarj %\(runner.settings.targetLimit - runner.settings.sailingDelta) altında yeniden başlar)")
                        }
                    }
                    if adapter.active {
                        Text(runner.settings.sailingEnabled
                             ? String(localized: "Yelken açık: adaptör hedefte kesilir, pil yelken aralığı kadar inince geri açılır. Pil daha seyrek şarj olur.")
                             : String(localized: "Yelken kapalı: adaptör hedefte kesilir, pil 5 puan inince geri açılır."))
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Uyku sırasında yardımcı güvenlik için her şeyi serbest bırakır; Mac uyurken pil hedefin üstüne çıkabilir.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if runner.sleepMayOvershoot {
                        Text("Uyku sırasında hedefin üstüne çıkabilir.").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            if canDischarge {
                Divider()
                HStack {
                    if runner.memory.discharge != nil {
                        Button("Deşarjı iptal et") { runner.cancelDischarge() }
                    } else if adapterCut {
                        Button("%\(adapter.dischargeLimit) seviyesine deşarj et") { adapter.toggleDischarge() }
                            .disabled(adapter.dischargeBlockReason != nil)
                            .help(adapter.dischargeBlockReason ?? "")
                    } else {
                        Button("Hedefe kadar deşarj et") { runner.requestDischarge() }
                    }
                    if runner.memory.calibration != nil {
                        Button("Kalibrasyonu iptal et") { runner.cancelCalibration() }
                    } else {
                        Button("Kalibrasyonu başlat") { adapterCut ? adapter.startCalibration() : runner.startCalibration() }
                    }
                    Spacer()
                }
                if let calibration = runner.memory.calibration {
                    Text(AdvancedChargeRunner.calibrationTitle(calibration.phase)).font(.caption.weight(.medium))
                }
                if let error = runner.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Kalibrasyon: %100'e şarj, 1 saat bekleme, %15 seviyesine deşarj, yeniden %100, ardından sınır geri yüklenir (en fazla 24 saat).")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if adapterCut {
                    Text("Deşarj ve kalibrasyon sürerken Mac boşta uyumaz. Kapak kapanır ya da Mac uyursa adaptör geri açılır; işlem Mac uyanınca kaldığı yerden sürer.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .chargeCard()
    }

    private var adapterModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Adaptör modu (deneysel)", isOn: Binding(get: { adapter.enabled }, set: { adapter.setEnabled($0) }))
                .disabled(adapter.installing || (!adapter.helperInstalled && !adapter.enabled))
            Text("Bu Mac'te macOS şarjı durdurmaya izin vermiyor. Adaptör modu, pil hedefe ulaşınca adaptörü yazılımla keser (Mac pilden çalışır) ve pil birkaç puan düşünce geri açar. Yalnızca Mac uyanıkken çalışır; uykudan önce adaptör geri açılır, bu yüzden uyku sırasında pil hedefin üstüne, macOS sınırına kadar çıkabilir. Pil günde yaklaşık 1 döngüyü sığ biçimde kullanır. Yardımcı kurulunca adaptör kesme bu Mac'te otomatik olarak test edilir.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            selfTestRow
            if adapter.active, runner.settings.heatProtectionEnabled {
                Text("Isı koruması açık: şarj sırasında pil 35 °C'yi geçerse adaptör kesilir, 32 °C'nin altına inince şarj sürer.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !adapter.helperInstalled {
                HStack {
                    Button(adapter.installing ? String(localized: "Kuruluyor…") : String(localized: "Yardımcıyı kur")) {
                        adapter.installHelperFromUserAction()
                    }.disabled(adapter.installing)
                    Text("Tek seferlik yönetici onayı ister.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let text = runner.adapterStatusText ?? (adapter.active ? runner.reason : nil) {
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            if let message = adapter.message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var selfTestRow: some View {
        if adapter.helperInstalled {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if adapter.selfTestRunning {
                    ProgressView().controlSize(.small)
                    Text("Adaptör testi sürüyor (birkaç dakika). Mac bu sırada birkaç kez kısa süre pilden çalışır.")
                } else if let report = adapter.selfTestReport {
                    Image(systemName: report.outcome == .passed ? "checkmark.circle.fill"
                          : report.outcome == .failed ? "xmark.octagon.fill" : "clock")
                        .foregroundStyle(report.outcome == .passed ? Color.green : report.outcome == .failed ? Color.red : Color.secondary)
                    Text(report.summary)
                } else {
                    Text("Adaptör testi henüz yapılmadı.")
                }
                Spacer(minLength: 8)
                if !adapter.selfTestRunning {
                    Button(adapter.selfTestReport == nil ? String(localized: "Testi çalıştır") : String(localized: "Testi yeniden çalıştır")) {
                        adapter.runSelfTest()
                    }
                    .disabled(adapter.active)
                }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        if adapter.active, runner.display == .idle || runner.display == .adapterCut {
            return runner.display == .adapterCut ? String(localized: "Adaptör kesildi") : String(localized: "Adaptör modu")
        }
        guard supported || adapterCut else { return String(localized: "Kullanılamıyor") }
        switch runner.display {
        case .unavailable: return String(localized: "Kullanılamıyor")
        case .idle: return String(localized: "Hazır")
        case .criticalLow: return String(localized: "Kritik seviye")
        case .onBattery: return String(localized: "Pilden çalışıyor")
        case .topUp: return String(localized: "Doldur etkin")
        case .holdingAtLimit: return String(localized: "Sınırda tutuluyor")
        case .sailing: return String(localized: "Yelken")
        case .heatPaused: return String(localized: "Isı nedeniyle duraklatıldı")
        case .discharging: return String(localized: "Deşarj oluyor")
        case .adapterCut: return String(localized: "Adaptör kesildi")
        case .calibrating: return String(localized: "Kalibrasyon sürüyor")
        }
    }
}
