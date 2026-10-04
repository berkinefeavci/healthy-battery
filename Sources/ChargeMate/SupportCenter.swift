import AppKit
import SwiftUI

struct SupportCenterView: View {
    @EnvironmentObject private var battery: BatteryMonitor
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var message: String?
    @State private var showResetConfirmation = false
    @State private var showClearHistoryConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            introCard
            helpCard
            diagnosticsCard
            dataCard
            aboutCard
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Başlangıç rehberi", systemImage: "sparkles").font(.headline)
                Spacer()
                if onboardingCompleted { Label("Tamamlandı", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
            }
            HStack(alignment: .top, spacing: 10) {
                guideStep(1, String(localized: "Ölçümleri oku"), String(localized: "Kaynak ve tazelik doğrulanmıyorsa değer yerine — gösterilir."), "waveform.path.ecg")
                guideStep(2, String(localized: "Limitin sınırı"), String(localized: "Yerel limit yalnız macOS’un sunduğu değerlerde ve açık Uygula eylemiyle değişir."), "battery.100percent")
                guideStep(3, String(localized: "Kontrol yetenekleri"), String(localized: "Pause, discharge ve kalibrasyon doğrulanana kadar kapalı kalır; başka denetleyici varsa işlem yapılmaz."), "shield.lefthalf.filled")
            }
            HStack {
                Text("Başla yalnız izlemeyi sürdürür; şarj kontrolünü veya otomasyonu etkinleştirmez.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(onboardingCompleted ? String(localized: "Rehberi yeniden tamamla") : String(localized: "Başla")) {
                    battery.start()
                    onboardingCompleted = true
                    message = String(localized: "İzleme etkin. Hiçbir şarj kontrolü açılmadı.")
                }.chargeMateButtonStyle()
            }
        }.chargeCard()
    }

    private func guideStep(_ number: Int, _ title: String, _ detail: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: icon).foregroundStyle(.blue); Text("\(number). \(title)").font(.subheadline.weight(.semibold)) }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Yerel yardım", systemImage: "questionmark.circle").font(.headline)
            HStack(spacing: 16) {
                Link("Hata bildir", destination: URL(string: "https://github.com/berkinefeavci/healthy-battery/issues/new?title=Hata%3A%20")!)
                Link("Öneri gönder", destination: URL(string: "https://github.com/berkinefeavci/healthy-battery/issues/new?title=%C3%96neri%3A%20")!)
            }
            Text("Tanı dosyası yalnızca siz eklemeyi seçerseniz paylaşılır.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Neden bazı değerler — görünüyor?") {
                Text("Sensör yoksa, veri geçersizse veya ölçüm 10 saniyeden eskiyse Healthy Battery tahmin üretmez.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
            DisclosureGroup("Neden bazı kontroller kapalı?") {
                Text("Bu Mac’te fiziksel etkisi ayrı olarak doğrulanmayan şarj durdurma, boşaltma ve kalibrasyon eylemleri güvenlik nedeniyle etkinleştirilmez.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
            DisclosureGroup("Başka bir şarj uygulaması açıksa ne olur?") {
                Text("Healthy Battery başka bir pil denetleyicisi algıladığında donanım değişikliğini kilitler; izleme ve geçmiş çalışmaya devam eder.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }.chargeCard()
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tanılama", systemImage: "stethoscope").font(.headline)
            Text("Rapor yalnız uygulama/OS/model, ölçüm kalitesi, yetenek özeti ve hata var/yok bilgisini içerir. Seri numarası, kullanıcı adı, dosya yolu ve süreç listesi eklenmez.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { exportDiagnostics() } label: { Label("Tanılama raporunu kaydet", systemImage: "square.and.arrow.down") }
                    .chargeMateButtonStyle()
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }.chargeCard()
    }

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Veriler ve sıfırlama", systemImage: "externaldrive").font(.headline)
            Text("Arayüz sıfırlama; geçmişi, macOS’un şarj hedefini ve kontrol işlem kayıtlarını değiştirmez. Geçmiş temizleme ayrı ve geri alınabilir bir işlemdir.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Arayüz ayarlarını sıfırla") { showResetConfirmation = true }
                Button("Geçmişi CSV olarak dışa aktar") { exportHistoryCSV() }
                    .disabled(battery.history.isEmpty)
                Button("Günlük özetleri CSV olarak dışa aktar") { exportDailyCSV() }
                    .disabled(battery.dailySummaries.isEmpty)
                Button("Geçmişi temizle", role: .destructive) { showClearHistoryConfirmation = true }
                if battery.historyBackupAvailable {
                    Button("Son geçmiş yedeğini geri al") { battery.restoreHistoryBackup { message = $0 } }
                }
            }.chargeMateButtonStyle()
            .confirmationDialog("Yalnız Healthy Battery arayüz ayarları sıfırlansın mı?", isPresented: $showResetConfirmation) {
                Button("Arayüz ayarlarını sıfırla", role: .destructive) {
                    ChargeMatePreferences.resetUI(in: .standard)
                    message = String(localized: "Arayüz ayarları sıfırlandı; geçmiş ve sistem limiti korundu.")
                }
            }
            .confirmationDialog("Geçmiş temizlensin mi? Önce yerel yedek oluşturulur.", isPresented: $showClearHistoryConfirmation) {
                Button("Yedekle ve geçmişi temizle", role: .destructive) { battery.clearHistoryWithBackup { message = $0 } }
            }
        }.chargeCard()
    }

    private var aboutCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.shield.fill").font(.system(size: 46)).foregroundStyle(.blue.gradient)
            Text("Healthy Battery").font(.title.bold())
            Text("Sürüm \(version) (\(build)) · bağımsız macOS uygulaması.")
                .font(.caption).foregroundStyle(.secondary)
            UpdateCheckSection()
            DisclosureGroup("Uygulamayı kaldırma") {
                Text("Ayarlar → Genel’deki “Healthy Battery’i kaldır” düğmesi yardımcıları ve arka plan servislerini kaldırır. Ardından Applications içindeki Healthy Battery’i Çöp Sepeti’ne taşıyın.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.frame(maxWidth: 520)
        }.frame(maxWidth: .infinity).padding(.vertical, 12).chargeCard()
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

    private func exportHistoryCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Healthy Battery-History.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = battery.history.map { point in
            HistoryCSV.Row(date: point.date, percentage: point.percentage, hardwarePercentage: point.hardwarePercentage,
                           batteryWatts: point.wattage, systemWatts: point.systemWatts, temperatureC: point.temperatureC,
                           healthPercent: point.healthPercent, cycleCount: point.cycleCount,
                           batteryCurrentMA: point.batteryCurrentMA, batteryVoltageV: point.batteryVoltageV,
                           remainingCapacityMAh: point.remainingCapacityMAh, fullCapacityMAh: point.fullCapacityMAh)
        }
        do {
            try Data(HistoryCSV.make(rows).utf8).write(to: url, options: .atomic)
            message = String(localized: "Geçmiş dışa aktarıldı: \(rows.count) ölçüm.")
        } catch { message = String(localized: "Geçmiş dışa aktarılamadı: \(error.localizedDescription)") }
    }

    private func exportDailyCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Healthy Battery-Daily.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let days = battery.dailySummaries
        do {
            try Data(HistoryCSV.makeDaily(days).utf8).write(to: url, options: .atomic)
            message = String(localized: "Günlük özetler dışa aktarıldı: \(days.count) gün.")
        } catch { message = String(localized: "Geçmiş dışa aktarılamadı: \(error.localizedDescription)") }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Healthy Battery-Tanilama.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = ChargeMateDiagnostics.report(snapshot: battery.snapshot, nativeLimit: battery.nativeLimit,
            currentSystemLimit: battery.currentSystemLimit, nativeLimits: battery.nativeLimits,
            otherControllerRunning: battery.otherControllerRunning, applyingLimit: battery.applyingLimit,
            recoveryRequired: battery.controlRecoveryRequired, historyCount: battery.history.count,
            historyError: battery.historyError != nil, energyState: battery.energySampleState)
        do {
            try report.data(using: .utf8)!.write(to: url, options: .atomic)
            message = String(localized: "Tanılama raporu kaydedildi.")
        } catch { message = String(localized: "Rapor kaydedilemedi: \(error.localizedDescription)") }
    }
}
