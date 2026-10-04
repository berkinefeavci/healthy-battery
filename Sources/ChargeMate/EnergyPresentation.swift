import Foundation

enum EnergyPresentation {
    private static let processNames = [
        "WindowServer": String(localized: "macOS ekran çizimi"),
        "kernel_task": String(localized: "macOS sistem koruması"),
        "mds": String(localized: "Spotlight indeksleme"),
        "mds_stores": String(localized: "Spotlight indeksleme"),
        "mdworker": String(localized: "Spotlight indeksleme"),
        "photoanalysisd": String(localized: "Fotoğraflar analizi"),
        "backupd": String(localized: "Time Machine yedekleme"),
        "softwareupdated": String(localized: "macOS güncellemesi")
    ]

    static func displayName(for processName: String) -> String {
        if let mapped = processNames[processName] { return mapped }
        if processName.hasSuffix(" Helper") {
            return String(processName.dropLast(" Helper".count)) + String(localized: " yardımcı işlemi")
        }
        return processName
    }

    private static let symbolNames = [
        "WindowServer": "display",
        "kernel_task": "cpu",
        "mds": "magnifyingglass",
        "mds_stores": "magnifyingglass",
        "mdworker": "magnifyingglass",
        "backupd": "clock.arrow.circlepath",
        "photoanalysisd": "photo",
        "softwareupdated": "arrow.down.circle",
        "coreaudiod": "speaker.wave.2"
    ]

    /// SF Symbol for a row with no real app icon (no owning `.app` bundle), keyed on the raw
    /// process name `top` reports (before any display-name substitution).
    static func symbolName(for processName: String) -> String {
        symbolNames[processName] ?? "gearshape"
    }

    static func impact(for score: Double) -> String {
        if score >= 25 { return String(localized: "Çok yüksek etki") }
        if score >= 10 { return String(localized: "Yüksek etki") }
        if score >= 5 { return String(localized: "Orta etki") }
        return String(localized: "Düşük etki")
    }

    // MARK: - Owner app + role naming for helper processes `top` truncates to 16 characters.

    /// The left-most `*.app` bundle path contained in an executable path, e.g.
    /// `/Applications/Dia.app/Contents/Frameworks/.../Browser Helper (Renderer)` → `/Applications/Dia.app`.
    /// Returns nil for paths with no `.app` component (e.g. system daemons like `WindowServer`).
    static func ownerBundlePath(fromExecutablePath path: String) -> String? {
        var accumulated = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            accumulated += "/\(component)"
            if component.hasSuffix(".app") { return accumulated }
        }
        return nil
    }

    /// `bundleNameLookup` is injectable (CFBundleDisplayName → CFBundleName → file name by default)
    /// so tests can resolve a name without a real bundle on disk.
    static func ownerAppName(fromExecutablePath path: String,
                             bundleNameLookup: (String) -> String? = defaultBundleDisplayName) -> String? {
        guard let bundlePath = ownerBundlePath(fromExecutablePath: path) else { return nil }
        if let name = bundleNameLookup(bundlePath), !name.isEmpty { return name }
        let fileName = (bundlePath as NSString).lastPathComponent
        return fileName.hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
    }

    static func defaultBundleDisplayName(_ bundlePath: String) -> String? {
        guard let bundle = Bundle(path: bundlePath) else { return nil }
        return (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
    }

    /// Turkish description of what a Chromium-style helper process is doing, derived from its launch
    /// arguments (`--type=` and, for utility processes, `--utility-sub-type=`). Returns nil when the
    /// arguments carry no recognizable `--type=`, e.g. when they could not be read.
    static func role(fromArguments args: [String]) -> String? {
        guard let type = value(forArgumentPrefix: "--type=", in: args) else { return nil }
        switch type {
        case "renderer": return String(localized: "bir web sayfası çalışıyor")
        case "gpu-process": return String(localized: "sayfaları ekrana çiziyor")
        case "utility":
            switch value(forArgumentPrefix: "--utility-sub-type=", in: args) {
            case "network.mojom.NetworkService": return String(localized: "ağ bağlantıları")
            case "audio.mojom.AudioService": return String(localized: "ses çalıyor")
            default: return String(localized: "yardımcı işlem")
            }
        default: return String(localized: "yardımcı işlem")
        }
    }

    private static func value(forArgumentPrefix prefix: String, in args: [String]) -> String? {
        guard let arg = args.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(arg.dropFirst(prefix.count))
    }

    /// The row label for a process `top` may have truncated: an owner app name plus what it is doing,
    /// e.g. `Dia · bir web sayfası çalışıyor`. Falls back to the existing system-process mapping/raw
    /// name when no owner `.app` could be determined, and to just the owner name when the role
    /// (launch arguments) could not be read.
    static func helperDisplayName(ownerAppName: String?, role: String?, rawProcessName: String) -> String {
        guard let owner = ownerAppName, !owner.isEmpty else { return displayName(for: rawProcessName) }
        guard let role else { return owner }
        return "\(owner) · \(role)"
    }

    // MARK: - Quit-button eligibility

    /// Bundle identifier Finder always reports; never offered a Quit button even though it has a
    /// regular activation policy.
    static let finderBundleIdentifier = "com.apple.finder"

    /// Pure decision logic for "Apps Using Significant Energy" Quit buttons: is a row quittable, and
    /// if so, which running application's PID should `terminate()` target?
    ///
    /// - `rowPID`/`isApplication`/`iconPath` mirror the matching `EnergyApp` fields. `iconPath` is the
    ///   owning `.app` bundle path (the row's own bundle for a regular app, the owner's bundle for a
    ///   helper process); nil means no owner `.app` was found (a system process).
    /// - `ownBundleIdentifier` is Healthy Battery's own bundle identifier, so Healthy Battery never offers to
    ///   quit itself.
    /// - `bundleIdentifier` resolves a bundle path to its `CFBundleIdentifier` (injected so tests never
    ///   touch disk; production passes `Bundle(path:)?.bundleIdentifier`).
    /// - `ownerProcessIdentifier` resolves the *running* owner app's PID for a helper row, given the
    ///   owner's bundle identifier and bundle path (injected; production matches
    ///   `NSRunningApplication.runningApplications(withBundleIdentifier:)` by `bundleURL.path`). Not
    ///   consulted for a regular app row, which is its own owner.
    /// - `isRegularApp` reports whether a PID's activation policy is `.regular` (injected; production
    ///   passes `NSRunningApplication(processIdentifier:)?.activationPolicy == .regular`).
    ///
    /// Returns nil for a system process (no owner `.app`), Healthy Battery itself, Finder, a helper whose
    /// owner app is not currently running, or any owner without a regular activation policy.
    static func quitTargetPID(rowPID: Int, isApplication: Bool, iconPath: String?,
                              ownBundleIdentifier: String?,
                              bundleIdentifier: (String) -> String?,
                              ownerProcessIdentifier: (_ bundleIdentifier: String, _ bundlePath: String) -> Int?,
                              isRegularApp: (Int) -> Bool) -> Int? {
        guard let bundlePath = iconPath, let bundleID = bundleIdentifier(bundlePath) else { return nil }
        if bundleID == finderBundleIdentifier { return nil }
        if let ownBundleIdentifier, bundleID == ownBundleIdentifier { return nil }
        let ownerPID: Int?
        if isApplication {
            ownerPID = rowPID
        } else {
            ownerPID = ownerProcessIdentifier(bundleID, bundlePath)
        }
        guard let ownerPID, isRegularApp(ownerPID) else { return nil }
        return ownerPID
    }

    // MARK: - Merged "Yüksek Enerji Kullanımı" popover card grouping

    /// One merged row for the popover/panel card: every energy-list row (the app itself and any of its
    /// helper processes) that shares an owner `.app` bundle, combined into a single quittable entry
    /// with summed POWER.
    struct EnergyAppGroup: Identifiable, Equatable {
        let bundlePath: String
        let name: String
        let totalPower: Double
        var id: String { bundlePath }
    }

    /// Groups energy-list rows by owner `.app` bundle path, sums each group's POWER, sorts by that
    /// total (descending, ties broken by name) and caps the result to `limit`. A row with no owner
    /// `.app` (a system process), Healthy Battery itself, or Finder is never included — matching
    /// `quitTargetPID`'s exclusions, minus the activation-policy check (that needs a live running app,
    /// resolved later at render/tap time, not while merely grouping a sample).
    ///
    /// - `rows` is `(power, iconPath)` for each energy-list row — deliberately not the concrete
    ///   `EnergyApp` (defined in `BatteryMonitor.swift`, outside this file's own compiled-test unit),
    ///   the same way `quitTargetPID` above takes decomposed fields instead of a whole `EnergyApp`.
    /// - `bundleIdentifier` resolves a bundle path to its `CFBundleIdentifier` (injected; production
    ///   passes `Bundle(path:)?.bundleIdentifier`).
    /// - `displayName` resolves a bundle path to a human name (injected; production passes
    ///   `ownerAppName(fromExecutablePath:)`); falls back to the bundle's file name minus `.app`.
    static func quittableAppGroups(from rows: [(power: Double, iconPath: String?)], ownBundleIdentifier: String?,
                                   bundleIdentifier: (String) -> String?,
                                   displayName: (String) -> String?,
                                   limit: Int = 5) -> [EnergyAppGroup] {
        var totals: [String: Double] = [:]
        var order: [String] = []
        for row in rows {
            guard let bundlePath = row.iconPath, let bundleID = bundleIdentifier(bundlePath) else { continue }
            if bundleID == finderBundleIdentifier { continue }
            if let ownBundleIdentifier, bundleID == ownBundleIdentifier { continue }
            if totals[bundlePath] == nil { order.append(bundlePath) }
            totals[bundlePath, default: 0] += row.power
        }
        let groups = order.map { path -> EnergyAppGroup in
            let fileName = (path as NSString).lastPathComponent
            let fallback = fileName.hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
            let name = displayName(path) ?? fallback
            return EnergyAppGroup(bundlePath: path, name: name, totalPower: totals[path] ?? 0)
        }
        return Array(groups.sorted { $0.totalPower == $1.totalPower ? $0.name < $1.name : $0.totalPower > $1.totalPower }
            .prefix(limit))
    }

    // MARK: - Empty-card visibility

    /// Whether a summary card with nothing to show should render at all. The compact
    /// popover/panel/dashboard widgets disappear entirely when empty, so a blank card never sits
    /// next to real content; the full settings page keeps its explanatory empty state instead, so
    /// it always shows regardless of item count.
    static func shouldShowCard(itemCount: Int, compact: Bool) -> Bool {
        compact ? itemCount > 0 : true
    }
}
