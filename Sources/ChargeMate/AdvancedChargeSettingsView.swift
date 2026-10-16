import SwiftUI

/// Experimental settings for the advanced charge engine. Everything is disabled until a verified
/// charge-inhibit backend is injected; the existing placeholder views are left untouched.
struct AdvancedChargeSettingsView: View {
    @ObservedObject var runner: AdvancedChargeRunner
    @ObservedObject private var adapter = AdapterModeController.shared

    private var supported: Bool { runner.capabilities.canInhibitCharging }
    private var canDischarge: Bool { supported && runner.capabilities.canForceDischarge }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Gelişmiş şarj (deneysel)", systemImage: "flask").font(.headline)
                Spacer()
                StatusBadge(text: statusText, color: (supported || adapter.active) ? .green : .secondary, icon: (supported || adapter.active) ? "checkmark.circle" : "lock.fill")
            }
            adapterModeSection
            Divider()
            if adapter.active {
                // Adapter mode status replaces the generic "locked" text.
            } else if !supported && adapter.helperInstalled {
                Text("Bu Mac şarjı takılıyken durdurmaya izin vermediği için yelken, ısı ile duraklatma, uyku davranışı, deşarj ve kalibrasyon burada gösterilmez. Adaptör modu açılınca hedef sınır onun üzerinden uygulanır.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !supported {
                Text(runner.capabilities.reason ?? String(localized: "Şarj durdurma yardımcısı kurulu ya da doğrulanmış değil. Bu ayarlar şimdilik etkisizdir ve donanıma hiçbir şey yazmaz."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !runner.reason.isEmpty {
                Text(runner.reason).font(.caption).foregroundStyle(.secondary)
            }
            // Without a verified charge-inhibit key these controls cannot do anything: hidden, not greyed out.
            if supported || adapter.active {
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
                                in: AdvancedChargeLimits.minSailingDelta...AdvancedChargeLimits.maxSailingDelta) {
                            Text("Yelken aralığı: %\(runner.settings.sailingDelta) (şarj %\(runner.settings.targetLimit - runner.settings.sailingDelta) altında yeniden başlar)")
                        }
                    }
                    Toggle("Isı koruması: 35 °C üstünde şarjı duraklat, 32 °C altında sürdür", isOn: $runner.settings.heatProtectionEnabled)
                    Toggle("Uyku davranışı: hedefin üstünde uykuya dalmadan önce şarjı durdur", isOn: $runner.settings.sleepBehaviorEnabled)
                    Text("Uyku sırasında yardımcı güvenlik için her şeyi serbest bırakır; Mac uyurken pil hedefin üstüne çıkabilir.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if runner.sleepMayOvershoot {
                        Text("Uyku sırasında hedefin üstüne çıkabilir.").font(.caption2).foregroundStyle(.orange)
                    }
                }
                .disabled(!supported)
                Divider()
                HStack {
                    if runner.memory.discharge != nil {
                        Button("Deşarjı iptal et") { runner.cancelDischarge() }
                    } else {
                        Button("Hedefe kadar deşarj et") { runner.requestDischarge() }.disabled(!canDischarge)
                    }
                    if runner.memory.calibration != nil {
                        Button("Kalibrasyonu iptal et") { runner.cancelCalibration() }
                    } else {
                        Button("Kalibrasyonu başlat") { runner.startCalibration() }.disabled(!canDischarge)
                    }
                    Spacer()
                }
                if let error = runner.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Kalibrasyon: tam şarj, 1 saat bekleme, 15 seviyesine deşarj, tekrar tam şarj, ardından sınır geri yüklenir (en fazla 24 saat).")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        if adapter.active {
            return runner.display == .adapterCut ? String(localized: "Adaptör kesildi") : String(localized: "Adaptör modu")
        }
        guard supported else { return String(localized: "Kullanılamıyor") }
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
