import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var battery: BatteryMonitor
    private var s: BatterySnapshot { battery.snapshot }
    var body: some View {
        VStack(spacing: 19) {
            HStack(spacing: 12) {
                powerItem("powerplug.portrait.fill", String(localized: "Adaptör"), s.reading(.adapterPower).text(), .yellow)
                Divider().frame(height: 15)
                powerItem("laptopcomputer", "MacBook", s.reading(.systemPower).text(), .blue)
                Divider().frame(height: 15)
                powerItem("battery.100percent", String(localized: "Batarya"), s.reading(.batteryPower).text(), .green)
                Spacer(minLength: 0)
                Image(systemName: "waveform.path").foregroundStyle(Color.primary.opacity(0.72))
            }.font(.system(size: 10)).padding(.horizontal, 14).padding(.vertical, 11).modifier(GlassSurface(radius: 22))
            HStack(alignment: .top, spacing: 15) {
                specCard(String(localized: "Batarya"), icon: "bolt.fill", rows: [
                    (String(localized: "Akım"), s.reading(.current).text(digits: 0)),
                    (String(localized: "Gerilim"), s.reading(.voltage).text(digits: 2)),
                    (String(localized: "Güç"), s.reading(.batteryPower).text()),
                    (String(localized: "Sistem yükü"), s.reading(.systemPower).text()),
                    (String(localized: "Kalan kapasite"), s.reading(.remainingCapacity).text(digits: 0))])
                specCard(String(localized: "Batarya sağlığı"), icon: "heart.fill", rows: [
                    (String(localized: "Tasarım"), s.reading(.designCapacity).text(digits: 0)),
                    (String(localized: "Tam şarj kapasitesi"), s.reading(.fullCapacity).text(digits: 0)),
                    (String(localized: "Kullanılabilir kapasite"), s.usableCapacityText),
                    (String(localized: "Sağlık"), s.reading(.health).text()),
                    (String(localized: "Döngü sayısı"), s.reading(.cycles).text(digits: 0)),
                    (String(localized: "Donanım yüzdesi"), s.reading(.hardwarePercentage).text(digits: 0))])
                specCard(String(localized: "Güç adaptörü"), icon: "powerplug.portrait.fill", rows: [
                    (String(localized: "Bağlantı"), s.externalConnected ? String(localized: "Bağlı") : String(localized: "Bağlı değil")),
                    (String(localized: "Anlık güç"), s.reading(.adapterPower).text()),
                    (String(localized: "Nominal güç"), s.reading(.adapterRatedPower).text()),
                    (String(localized: "Nominal gerilim"), s.reading(.adapterVoltage).text(digits: 2)),
                    (String(localized: "Nominal akım"), s.reading(.adapterCurrent).text(digits: 2))])
            }
            HStack {
                Label("Batarya geçmişi", systemImage: "chart.xyaxis.line").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.primary.opacity(0.72))
                Spacer()
                HistoryRangePicker()
            }
            HStack(alignment: .top, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                    MetricChartView(metric: .level, height: 142)
                    MetricChartView(metric: .temperature, height: 142)
                    MetricChartView(metric: .power, height: 142)
                    MetricChartView(metric: .health, height: 142)
                    MetricChartView(metric: .cycles, height: 142)
                }.frame(maxWidth: .infinity)
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack { Text("Şarj durumu").font(.system(size: 12, weight: .semibold)); Spacer(); Circle().fill(.green).frame(width: 5, height: 5) }
                        Text(battery.statusSentence).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        ReadOnlyBadge()
                    }.chargeCard()
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Kayıtlı macOS limiti", systemImage: "battery.100percent").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.72))
                        Text(battery.nativeLimit.map { "%\($0)" } ?? "—").font(.system(size: 27, weight: .light)).monospacedDigit()
                        Text("Charge Control bölümünden düzenleyin.").font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.72))
                    }.frame(maxWidth: .infinity, alignment: .leading).chargeCard()
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Döngü sayısı", systemImage: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.72))
                        Text(s.reading(.cycles).text(digits: 0)).font(.system(size: 27, weight: .light)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading).chargeCard()
                    .help(String(localized: "Sıcaklık: \(s.temperatureSource)"))
                    EnergyUsageView(compact: true, maximumApps: 5)
                }.frame(width: 190)
            }.frame(maxWidth: .infinity)
            HStack {
                Image(systemName: "internaldrive")
                Text("Gerçek ölçümler, bu Mac’te 24 saat saklanır. Grafiğin üzerine gelerek ölçüm inceleyebilirsiniz.")
                Spacer()
            }.font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.5))
            ProGate(feature: String(localized: "Uzun süreli sağlık geçmişi")) { LongTermHealthCard() }
        }
    }
    private func powerItem(_ icon: String, _ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) { Image(systemName: icon).foregroundStyle(color); Text(title).foregroundStyle(Color.primary.opacity(0.72)); Text(value).fontWeight(.semibold).monospacedDigit() }
    }
    private func specCard(_ title: String, icon: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
            VStack(spacing: 6) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline) {
                        Text(rows[index].0).foregroundStyle(Color.primary.opacity(0.72))
                        Spacer(minLength: 4)
                        Text(s.available ? rows[index].1 : "—").monospacedDigit().multilineTextAlignment(.trailing)
                    }.font(.system(size: 10))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading).frame(minHeight: 132, alignment: .top).chargeCard()
    }
}
