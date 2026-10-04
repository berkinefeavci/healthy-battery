import Charts
import SwiftUI

/// Dashboard card for the daily summaries: a battery-health trend and charging habits over the last
/// 7 and 30 days. Every value comes from recorded readings; a window without data shows "—".
struct LongTermHealthCard: View {
    @EnvironmentObject var battery: BatteryMonitor

    private struct HealthPoint: Identifiable {
        let date: Date
        let health: Double
        var id: Date { date }
    }

    private var healthPoints: [HealthPoint] {
        battery.dailySummaries.compactMap { summary in
            guard let health = summary.healthPercent,
                  let date = LongTermHistory.date(of: summary.day, calendar: .current) else { return nil }
            return HealthPoint(date: date, health: min(100, health))
        }
    }

    private var today: String { LongTermHistory.dayKey(Date(), calendar: .current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Uzun vadeli sağlık", systemImage: "calendar").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(battery.dailySummaries.count) günlük kayıt").font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.6))
            }
            let points = healthPoints
            if points.count >= 2 {
                let values = points.map(\.health)
                let upper = 100.0
                let lower = max(0, min(values.min()!.rounded(.down), upper - ChartData.minimumHealthSpan))
                Chart(points) { point in
                    LineMark(x: .value("Gün", point.date, unit: .day), y: .value("Sağlık", point.health))
                        .foregroundStyle(.orange)
                    PointMark(x: .value("Gün", point.date, unit: .day), y: .value("Sağlık", point.health))
                        .foregroundStyle(.orange).symbolSize(12)
                }
                .chartYScale(domain: lower...upper)
                .frame(height: 130)
                .accessibilityLabel("Günlük batarya sağlığı grafiği")
            } else {
                Text("Sağlık eğilimi için en az iki günlük ölçüm gerekiyor. Healthy Battery açık kaldıkça her gün bir özet kaydedilir.")
                    .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                statsColumn(title: String(localized: "Son 7 gün"), stats: stats(days: 7))
                statsColumn(title: String(localized: "Son 30 gün"), stats: stats(days: 30))
            }
            Text("Günlük özetler bu Mac’te 400 güne kadar saklanır; yalnızca Healthy Battery açıkken kaydedilen ölçümlerden hesaplanır.")
                .font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).chargeCard()
    }

    private func stats(days: Int) -> LongTermHistory.Stats? {
        LongTermHistory.stats(battery.dailySummaries, lastDays: days, endingOn: today, calendar: .current)
    }

    private func statsColumn(title: String, stats: LongTermHistory.Stats?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            row(String(localized: "Ortalama doluluk"), stats?.averagePercent.map { Self.percent($0) })
            row(String(localized: "%90 ve üstünde geçen süre"), stats?.shareAtOrAbove90.map { Self.percent($0 * 100) })
            row(String(localized: "Eklenen döngü"), stats?.cyclesAdded.map { String($0) })
            row(String(localized: "Sağlık değişimi"), stats?.healthChange.map { String(localized: "\(String(format: "%+.1f", $0)) puan") })
            row(String(localized: "En yüksek sıcaklık"), stats?.peakTemperatureC.map { String(format: "%.1f °C", $0) })
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Color.primary.opacity(0.72))
            Spacer(minLength: 4)
            Text(value ?? "—").monospacedDigit()
        }.font(.system(size: 10))
    }

    private static func percent(_ value: Double) -> String {
        String(localized: "%\(Int(value.rounded()))")
    }
}
