import AppKit
import Foundation

/// Executes an `UninstallPlan` for real: one admin prompt for every helper/daemon removal (new
/// and legacy "ChargeMate" labels), then the non-privileged steps. This is the only side-effecting
/// half of uninstall — `UninstallPlan` itself stays pure and is what the unit tests cover.
/// Every step reports its own result: a step that did not finish is never counted as done.
enum UninstallExecutor {
    static func run(options: UninstallPlan.Options, battery: BatteryMonitor) async -> UninstallOutcome {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cellkeep").path
        let steps = UninstallPlan.build(options: options, applicationSupportDirectory: supportDirectory)

        if let command = UninstallPlan.adminShellCommand(for: steps) {
            do { try AdminAuthorization.run(command) }
            catch AdminAuthorization.Failure.cancelled { return .cancelled }
            catch AdminAuthorization.Failure.failed(let detail) {
                return .failed(detail.isEmpty ? String(localized: "macOS yönetici izni vermedi.") : detail)
            }
            catch { return .failed(error.localizedDescription) }
        }

        var problems: [String] = []

        // Unregistering something that was never registered throws; only act on a request that exists.
        if StartupPreferences.loginItemState().requested {
            do { _ = try StartupPreferences.setLoginItemEnabled(false) }
            catch { problems.append(String(localized: "Giriş öğesi kayıttan silinemedi: \(error.localizedDescription)")) }
        }

        if steps.contains(.resetNativeChargeLimitTo100) {
            let result = await battery.applyShortcutLimit(100)
            if result.status != .configurationVerified {
                problems.append(String(localized: "Şarj limiti %100'e sıfırlanamadı: \(result.message)"))
            }
        }

        for step in steps {
            guard case .removeApplicationSupportData(let path) = step,
                  FileManager.default.fileExists(atPath: path) else { continue }
            do { try FileManager.default.removeItem(atPath: path) }
            catch { problems.append(String(localized: "Uygulama verileri silinemedi: \(error.localizedDescription)")) }
        }

        return .finish(problems: problems)
    }
}
