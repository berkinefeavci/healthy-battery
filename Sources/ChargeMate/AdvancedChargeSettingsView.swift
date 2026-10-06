import SwiftUI

/// Experimental settings for the advanced charge engine. Everything is disabled until a verified
/// charge-inhibit backend is injected; the existing placeholder views are left untouched.
struct AdvancedChargeSettingsView: View {
    @ObservedObject var runner: AdvancedChargeRunner

    private var supported: Bool { runner.capabilities.canInhibitCharging }
    private var canDischarge: Bool { supported && runner.capabilities.canForceDischarge }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Gelişmiş şarj (deneysel)", systemImage: "flask").font(.headline)
                Spacer()
                StatusBadge(text: statusText, color: supported ? .green : .secondary, icon: supported ? "checkmark.circle" : "lock.fill")
            }
            if !supported {
                Text(runner.capabilities.reason ?? String(localized: "Şarj durdurma yardımcısı kurulu ya da doğrulanmış değil. Bu ayarlar şimdilik etkisizdir ve donanıma hiçbir şey yazmaz."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !runner.reason.isEmpty {
                Text(runner.reason).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Group {
                Stepper(value: Binding(get: { runner.settings.targetLimit },
                                       set: { runner.settings.targetLimit = AdvancedChargeLimits.normalizedTarget($0) }),
                        in: AdvancedChargeLimits.minTarget...AdvancedChargeLimits.maxTarget, step: AdvancedChargeLimits.targetStep) {
                    Text("Hedef sınır: %\(runner.settings.targetLimit)")
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
        .chargeCard()
    }

    private var statusText: String {
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
        case .calibrating: return String(localized: "Kalibrasyon sürüyor")
        }
    }
}
