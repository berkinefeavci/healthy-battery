import Foundation

@main
enum EnergyPresentationTests {
    static func main() {
        precondition(EnergyPresentation.displayName(for: "WindowServer") == "macOS ekran çizimi")
        precondition(EnergyPresentation.displayName(for: "kernel_task") == "macOS sistem koruması")
        precondition(EnergyPresentation.displayName(for: "mds_stores") == "Spotlight indeksleme")
        precondition(EnergyPresentation.displayName(for: "ego Helper") == "ego yardımcı işlemi")
        precondition(EnergyPresentation.displayName(for: "Safari") == "Safari")
        precondition(EnergyPresentation.impact(for: 45) == "Çok yüksek etki")
        precondition(EnergyPresentation.impact(for: 12) == "Yüksek etki")
        precondition(EnergyPresentation.impact(for: 6) == "Orta etki")

        // Owner app extraction from an executable path (left-most `*.app` component).
        let diaRendererPath = "/Applications/Dia.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper (Renderer).app/Contents/MacOS/Browser Helper (Renderer)"
        precondition(EnergyPresentation.ownerBundlePath(fromExecutablePath: diaRendererPath) == "/Applications/Dia.app")
        precondition(EnergyPresentation.ownerAppName(fromExecutablePath: diaRendererPath, bundleNameLookup: { _ in nil }) == "Dia")
        precondition(EnergyPresentation.ownerAppName(fromExecutablePath: diaRendererPath, bundleNameLookup: { _ in "Dia Browser" }) == "Dia Browser")
        precondition(EnergyPresentation.ownerBundlePath(fromExecutablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer") == nil)
        precondition(EnergyPresentation.ownerAppName(fromExecutablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer") == nil)

        // Role from launch arguments.
        precondition(EnergyPresentation.role(fromArguments: ["/path/Browser Helper (Renderer)", "--type=renderer", "--lang=en"]) == "bir web sayfası çalışıyor")
        precondition(EnergyPresentation.role(fromArguments: ["/path/Browser Helper (GPU)", "--type=gpu-process"]) == "sayfaları ekrana çiziyor")
        precondition(EnergyPresentation.role(fromArguments: ["/path/Browser Helper", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]) == "ağ bağlantıları")
        precondition(EnergyPresentation.role(fromArguments: ["/path/Browser Helper", "--type=utility", "--utility-sub-type=audio.mojom.AudioService"]) == "ses çalıyor")
        precondition(EnergyPresentation.role(fromArguments: ["/path/Browser Helper", "--type=utility", "--utility-sub-type=something.else"]) == "yardımcı işlem")
        precondition(EnergyPresentation.role(fromArguments: ["/path/Browser Helper", "--type=utility"]) == "yardımcı işlem")
        precondition(EnergyPresentation.role(fromArguments: ["/path/SomeHelper"]) == nil)
        precondition(EnergyPresentation.role(fromArguments: []) == nil)

        // Combined display name.

        // System-process SF Symbol mapping for rows with no real app icon.
        precondition(EnergyPresentation.symbolName(for: "WindowServer") == "display")
        precondition(EnergyPresentation.symbolName(for: "kernel_task") == "cpu")
        precondition(EnergyPresentation.symbolName(for: "mds") == "magnifyingglass")
        precondition(EnergyPresentation.symbolName(for: "mds_stores") == "magnifyingglass")
        precondition(EnergyPresentation.symbolName(for: "mdworker") == "magnifyingglass")
        precondition(EnergyPresentation.symbolName(for: "backupd") == "clock.arrow.circlepath")
        precondition(EnergyPresentation.symbolName(for: "photoanalysisd") == "photo")
        precondition(EnergyPresentation.symbolName(for: "softwareupdated") == "arrow.down.circle")
        precondition(EnergyPresentation.symbolName(for: "coreaudiod") == "speaker.wave.2")
        precondition(EnergyPresentation.symbolName(for: "some_unknown_daemon") == "gearshape")

        // Quit-button eligibility (pure decision logic; all lookups are injected fakes).
        let bundleIDs = ["/Applications/Dia.app": "company.dia.browser",
                         "/System/Library/CoreServices/Finder.app": "com.apple.finder",
                         "/Applications/Cellkeep.app": "local.chargemate"]
        let bundleIdentifier: (String) -> String? = { bundleIDs[$0] }
        let ownerPIDs = ["company.dia.browser": 4242]
        let ownerProcessIdentifier: (String, String) -> Int? = { bundleID, _ in ownerPIDs[bundleID] }
        let regularPIDs: Set<Int> = [111, 4242]
        let isRegularApp: (Int) -> Bool = { regularPIDs.contains($0) }

        // Regular app row: owner is the row's own PID.
        precondition(EnergyPresentation.quitTargetPID(
            rowPID: 111, isApplication: true, iconPath: "/Applications/Dia.app",
            ownBundleIdentifier: "local.chargemate",
            bundleIdentifier: bundleIdentifier, ownerProcessIdentifier: ownerProcessIdentifier,
            isRegularApp: isRegularApp) == 111)

        // Helper row: resolves to the owner app's running PID, not the (untouchable) helper PID.
        precondition(EnergyPresentation.quitTargetPID(
            rowPID: 9999, isApplication: false, iconPath: "/Applications/Dia.app",
            ownBundleIdentifier: "local.chargemate",
            bundleIdentifier: bundleIdentifier, ownerProcessIdentifier: ownerProcessIdentifier,
            isRegularApp: isRegularApp) == 4242)

        // System process: no owner `.app` at all.
        precondition(EnergyPresentation.quitTargetPID(
            rowPID: 1, isApplication: false, iconPath: nil,
            ownBundleIdentifier: "local.chargemate",
            bundleIdentifier: bundleIdentifier, ownerProcessIdentifier: ownerProcessIdentifier,
            isRegularApp: isRegularApp) == nil)

        // Cellkeep itself is never offered a Quit button.
        precondition(EnergyPresentation.quitTargetPID(
            rowPID: 222, isApplication: true, iconPath: "/Applications/Cellkeep.app",
            ownBundleIdentifier: "local.chargemate",
            bundleIdentifier: bundleIdentifier, ownerProcessIdentifier: ownerProcessIdentifier,
            isRegularApp: isRegularApp) == nil)

        // Finder is never offered a Quit button, even though it has a regular activation policy.
        precondition(EnergyPresentation.quitTargetPID(
            rowPID: 333, isApplication: true, iconPath: "/System/Library/CoreServices/Finder.app",
            ownBundleIdentifier: "local.chargemate",
            bundleIdentifier: bundleIdentifier, ownerProcessIdentifier: { _, _ in 333 },
            isRegularApp: { _ in true }) == nil)

        // A helper whose owner app is not currently running resolves to no target.
        precondition(EnergyPresentation.quitTargetPID(
            rowPID: 9999, isApplication: false, iconPath: "/Applications/Dia.app",
            ownBundleIdentifier: "local.chargemate",
            bundleIdentifier: bundleIdentifier, ownerProcessIdentifier: { _, _ in nil },
            isRegularApp: isRegularApp) == nil)

        // An owner without a regular activation policy (e.g. a background/accessory app) is excluded.
        precondition(EnergyPresentation.quitTargetPID(
            rowPID: 444, isApplication: true, iconPath: "/Applications/Dia.app",
            ownBundleIdentifier: "local.chargemate",
            bundleIdentifier: bundleIdentifier, ownerProcessIdentifier: ownerProcessIdentifier,
            isRegularApp: { _ in false }) == nil)

        // Merged "Yüksek Enerji Kullanımı" card grouping (pure; bundleIdentifier/displayName injected).
        let groupBundleIDs = ["/Applications/Dia.app": "company.dia.browser",
                              "/Applications/WhatsApp.app": "net.whatsapp.WhatsApp",
                              "/System/Library/CoreServices/Finder.app": "com.apple.finder",
                              "/Applications/Cellkeep.app": "local.chargemate"]
        let groupBundleIdentifier: (String) -> String? = { groupBundleIDs[$0] }
        let groupDisplayName: (String) -> String? = { path in
            path == "/Applications/Dia.app" ? "Dia" : path == "/Applications/WhatsApp.app" ? "WhatsApp" : nil
        }

        // Dia's main process and two helpers (same owner bundle) merge into one row with summed power;
        // WhatsApp stays its own row; the system process (no iconPath) is dropped entirely.
        let mergedRows: [(power: Double, iconPath: String?)] = [
            (power: 12, iconPath: "/Applications/Dia.app"),
            (power: 5, iconPath: "/Applications/Dia.app"),
            (power: 3, iconPath: "/Applications/Dia.app"),
            (power: 20, iconPath: "/Applications/WhatsApp.app"),
            (power: 9, iconPath: nil)
        ]
        let merged = EnergyPresentation.quittableAppGroups(
            from: mergedRows, ownBundleIdentifier: "local.chargemate",
            bundleIdentifier: groupBundleIdentifier, displayName: groupDisplayName)
        precondition(merged.count == 2)
        // Sorted by total power descending: WhatsApp (20) before Dia (12+5+3=20)... equal, so tie-break
        // by name: "Dia" < "WhatsApp".
        precondition(merged[0].name == "Dia" && merged[0].totalPower == 20)
        precondition(merged[1].name == "WhatsApp" && merged[1].totalPower == 20)

        // Cellkeep itself and Finder are excluded from the merged groups too.
        let excludedRows: [(power: Double, iconPath: String?)] = [
            (power: 50, iconPath: "/Applications/Cellkeep.app"),
            (power: 50, iconPath: "/System/Library/CoreServices/Finder.app")
        ]
        precondition(EnergyPresentation.quittableAppGroups(
            from: excludedRows, ownBundleIdentifier: "local.chargemate",
            bundleIdentifier: groupBundleIdentifier, displayName: groupDisplayName).isEmpty)

        // Capped to `limit`, keeping the highest-power groups.
        let manyBundleIDs: [String: String] = Dictionary(uniqueKeysWithValues: (0..<8).map { ("/Applications/App\($0).app", "id.app\($0)") })
        let manyRows: [(power: Double, iconPath: String?)] = (0..<8).map { (power: Double($0), iconPath: "/Applications/App\($0).app") }
        let capped = EnergyPresentation.quittableAppGroups(
            from: manyRows, ownBundleIdentifier: "local.chargemate",
            bundleIdentifier: { manyBundleIDs[$0] }, displayName: { _ in nil }, limit: 5)
        precondition(capped.count == 5)
        precondition(capped.map(\.totalPower) == [7, 6, 5, 4, 3])
        // No injected display name: falls back to the bundle's file name minus ".app".
        precondition(capped[0].name == "App7")

        print("PASS: technical process scores have understandable Turkish labels")

        // Empty-card visibility: the compact popover/panel/dashboard card hides entirely when
        // there's nothing to show; the full settings page always shows (it has its own explanatory
        // empty state instead).
        precondition(EnergyPresentation.shouldShowCard(itemCount: 0, compact: true) == false)
        precondition(EnergyPresentation.shouldShowCard(itemCount: 1, compact: true) == true)
        precondition(EnergyPresentation.shouldShowCard(itemCount: 0, compact: false) == true)
        precondition(EnergyPresentation.shouldShowCard(itemCount: 3, compact: false) == true)
        print("PASS: compact cards hide when empty, full settings page always shows")
    }
}
