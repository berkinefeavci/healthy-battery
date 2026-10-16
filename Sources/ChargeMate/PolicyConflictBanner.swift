import SwiftUI

/// Prominent strip at the top of the popover while macOS's native limit differs from Healthy Battery's target.
struct PolicyConflictBanner: View {
    @EnvironmentObject var battery: BatteryMonitor

    var body: some View {
        if let conflict = battery.policyConflict {
            VStack(alignment: .leading, spacing: 8) {
                Label(ChargeLimitDisplay.conflictTitle(observed: conflict.observed, expected: conflict.expected),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Hedefimi uygula") { battery.reapplyChargeMateTarget() }
                        .chargeMateButtonStyle()
                    Button("macOS değerini kullan") { battery.adoptMacOSLimit() }
                        .chargeMateButtonStyle()
                }.disabled(battery.applyingLimit || battery.otherControllerRunning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }
}

/// Settings card: what to do when macOS's limit changes outside the app.
struct ExternalChangeSettingsCard: View {
    @EnvironmentObject var battery: BatteryMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("macOS sınırı dışarıdan değişirse", systemImage: "arrow.triangle.2.circlepath").font(.headline)
            Picker("macOS sınırı dışarıdan değişirse", selection: $battery.externalChangeResponse) {
                ForEach(ExternalChangeResponse.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.chargeCard()
    }

    private var hint: String {
        switch battery.externalChangeResponse {
        case .ask: return String(localized: "Panelde bir uyarı gösterilir; hedefi geri yazmak ya da macOS değerini kullanmak size kalır.")
        case .reapply: return String(localized: "Hedefiniz bir kez otomatik geri yazılır. Başarısız olursa ya da 10 dakika içinde yine değişirse size sorulur.")
        case .adopt: return String(localized: "macOS'taki yeni değer otomatik olarak Healthy Battery hedefi olur.")
        }
    }
}
