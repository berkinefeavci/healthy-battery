import SwiftUI

/// Genel sayfadaki "Hatırlatmalar" kartı: ana anahtar, tür başına anahtar ve örnek toast.
struct ReminderSettingsCard: View {
    @AppStorage(ReminderSettings.masterKey) private var master = true
    @AppStorage(ReminderKind.cableRemoved.defaultsKey) private var cable = true
    @AppStorage(ReminderKind.reached40.defaultsKey) private var at40 = true
    @AppStorage(ReminderKind.reached20.defaultsKey) private var at20 = true
    @AppStorage(ReminderKind.chargingWarm.defaultsKey) private var warm = true
    @AppStorage(ReminderKind.pluggedFull.defaultsKey) private var full = true
    @AppStorage(ReminderKind.calibration.defaultsKey) private var calibration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Hatırlatmalar", systemImage: "bell.badge").font(.headline)
            TrailingToggle(title: String(localized: "Küçük ipuçlarını göster"), isOn: $master)
            Text("Menü çubuğu simgesinin altında 5 saniye görünür ve kendiliğinden kaybolur. Bildirim merkezine gitmez, konum izlemez.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Group {
                TrailingToggle(title: ReminderKind.cableRemoved.title, isOn: $cable)
                TrailingToggle(title: ReminderKind.reached40.title, isOn: $at40)
                TrailingToggle(title: ReminderKind.reached20.title, isOn: $at20)
                TrailingToggle(title: ReminderKind.chargingWarm.title, isOn: $warm)
                TrailingToggle(title: ReminderKind.pluggedFull.title, isOn: $full)
                TrailingToggle(title: ReminderKind.calibration.title, isOn: $calibration)
            }.disabled(!master)
            Button("Örnek göster") { ReminderCenter.shared.showSample() }
        }
        .toggleStyle(.switch)
        .chargeCard()
    }
}
