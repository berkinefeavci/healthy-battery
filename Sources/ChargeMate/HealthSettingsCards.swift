import SwiftUI

/// Şarj Kontrolü sayfasındaki Faz 2 kartları: sağlık özeti, sıcaklık koruması, bekleme uyarısı ve
/// Optimize Şarj ipucu.
struct HealthSettingsCards: View {
    @EnvironmentObject private var battery: BatteryMonitor
    @ObservedObject private var automation = HealthAutomation.shared
    @AppStorage(HealthAutomation.Keys.heatProtectionV1) private var heatProtection = false
    @AppStorage(HealthAutomation.Keys.fullChargeDwell) private var dwellWarning = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            healthCard
            automationCard
            if let note = automation.optimizedChargingNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .chargeCard()
            }
        }
    }

    var healthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Şarj sağlığı · son 7 gün", systemImage: "heart.text.square").font(.headline)
            if let summary = automation.habitsSummary, summary.observedHours > 0 {
                row(String(localized: "%95 üstünde, takılıyken"), hours(summary.hoursAtOrAbove95Plugged))
                row(String(localized: "35 °C üstünde şarj"), hours(summary.hoursChargingAbove35))
                row(String(localized: "Ortalama boşalma derinliği"),
                    summary.averageDischargeDepth.map { String(format: "%%%.0f", $0) } ?? "—")
            }
            Text(automation.advice.text)
                .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text("Yalnızca Healthy Battery açıkken ölçülen süreler sayılır.")
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).chargeCard()
    }

    var automationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Otomatik koruma", systemImage: "thermometer.snowflake").font(.headline)
            TrailingToggle(title: String(localized: "Sıcaklık koruması (sınırı %80'e çeker)"), isOn: $heatProtection)
            Text("Pil adaptörde şarj olurken 35 °C'yi geçerse sınır geçici olarak %80 olur, Turbo kapanır ve bildirim gelir. 32 °C'ye inince ya da adaptör çıkınca eski ayar döner. Pil zaten %80'in altındaysa şarjı durduramaz.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if automation.heatOverrideActive {
                StatusBadge(text: String(localized: "Sıcaklık koruması etkin"), color: .orange, icon: "thermometer.high")
            }
            Divider()
            TrailingToggle(title: String(localized: "Uzun süre dolu kalırsa uyar"), isOn: $dwellWarning)
            Text("Adaptör takılıyken pil 3 saatten uzun süre %95 üstünde kalırsa bildirim gelir.")
                .font(.caption).foregroundStyle(.secondary)
        }.toggleStyle(.switch).frame(maxWidth: .infinity, alignment: .leading).chargeCard()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium) }
            .font(.system(size: 12))
    }

    private func hours(_ value: Double) -> String { String(format: "%.1f", value) + " " + String(localized: "sa") }
}

/// "Şu saatte %100 hazır olsun": saati sorar, Top Up başlangıcını hesaplar ve kapalı bir görev olarak
/// Takvim düzenleyicisine verir.
struct ReadyBySheet: View {
    let rateSamples: [ChargeRateSample]
    let onCreate: (ScheduleTask) -> Void
    let onCancel: () -> Void
    @State private var readyAt = ReadyByPlanner.nextOccurrence(hour: 8, minute: 0, after: Date())

    private var lead: TimeInterval {
        ReadyByPlanner.leadTime(ratePercentPerHour: ReadyByPlanner.chargeRatePercentPerHour(rateSamples))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Şu saatte %100 hazır olsun").font(.headline)
            DatePicker(String(localized: "Hazır olacağı zaman"), selection: $readyAt, in: Date()...,
                       displayedComponents: [.date, .hourAndMinute])
            Text("Doldur şu zamanda başlar: \(ReadyByPlanner.startDate(readyAt: readyAt, lead: lead).formatted(date: .abbreviated, time: .shortened)) (yaklaşık \(Int((lead / 60).rounded())) dk önce). Süre son şarj hızınızdan tahmin edilir; veri yoksa 2 saat öncesidir. Görev kapalı başlar; kaydederken etkinleştirin.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("İptal", action: onCancel)
                Button("Görev oluştur") {
                    onCreate(ReadyByPlanner.task(readyAt: readyAt, lead: lead, now: Date()))
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 420)
    }
}
