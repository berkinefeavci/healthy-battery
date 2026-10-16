import Foundation

/// Pure plan for the "Healthy Battery'i kaldır" action: which root-owned helpers/daemons get removed
/// (both current and any leftover legacy "ChargeMate" ones), and which optional steps run based
/// on the user's checkbox choices. Building the plan never touches the file system, launchctl,
/// or an admin prompt — only `UninstallExecutor` (not covered by unit tests) actually runs it.
enum UninstallPlan {
    struct HelperTarget: Equatable {
        let daemonLabel: String
        let binaryPath: String
        let launchDaemonPlistPath: String
    }

    struct Options: Equatable {
        var resetNativeChargeLimit: Bool
        var removeApplicationSupportData: Bool

        /// The alert's own defaults: reset ON, data removal OFF.
        static let `default` = Options(resetNativeChargeLimit: true, removeApplicationSupportData: false)
    }

    enum Step: Equatable {
        case bootOutAndRemoveHelper(HelperTarget)
        case unregisterLoginItem
        case resetNativeChargeLimitTo100
        case removeApplicationSupportData(path: String)
    }

    /// Every helper/daemon this app (or its previous "ChargeMate" identity) may have installed.
    static let currentHelpers: [HelperTarget] = [
        HelperTarget(daemonLabel: "io.github.berkinefeavci.cellkeep.led",
                     binaryPath: "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.led",
                     launchDaemonPlistPath: "/Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.led.plist"),
        HelperTarget(daemonLabel: "io.github.berkinefeavci.cellkeep.powermode",
                     binaryPath: "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.powermode",
                     launchDaemonPlistPath: "/Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.powermode.plist"),
        // Faz 3 charge-inhibit helper; booting it out sends SIGTERM, which releases charging and the adapter.
        HelperTarget(daemonLabel: "io.github.berkinefeavci.cellkeep.chargeinhibit",
                     binaryPath: "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.chargeinhibit",
                     launchDaemonPlistPath: "/Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.chargeinhibit.plist")
    ]
    static let legacyHelpers: [HelperTarget] = [
        HelperTarget(daemonLabel: "local.chargemate.led",
                     binaryPath: "/Library/PrivilegedHelperTools/com.chargemate.ledctl",
                     launchDaemonPlistPath: "/Library/LaunchDaemons/local.chargemate.led.plist"),
        HelperTarget(daemonLabel: "local.chargemate.powermode",
                     binaryPath: "/Library/PrivilegedHelperTools/com.chargemate.powermode",
                     launchDaemonPlistPath: "/Library/LaunchDaemons/local.chargemate.powermode.plist")
    ]

    static func build(options: Options, applicationSupportDirectory: String) -> [Step] {
        var steps: [Step] = (currentHelpers + legacyHelpers).map { .bootOutAndRemoveHelper($0) }
        steps.append(.unregisterLoginItem)
        if options.resetNativeChargeLimit { steps.append(.resetNativeChargeLimitTo100) }
        if options.removeApplicationSupportData { steps.append(.removeApplicationSupportData(path: applicationSupportDirectory)) }
        return steps
    }

    /// The single `do shell script … with administrator privileges` command that removes every
    /// helper binary and daemon in one admin prompt. `nil` if the plan has no such steps.
    static func adminShellCommand(for steps: [Step]) -> String? {
        let helperCommands: [String] = steps.compactMap { step in
            guard case .bootOutAndRemoveHelper(let target) = step else { return nil }
            return "(/bin/launchctl bootout system/\(target.daemonLabel) 2>/dev/null || true) && " +
                "/bin/rm -f \(shellQuote(target.binaryPath)) \(shellQuote(target.launchDaemonPlistPath))"
        }
        guard !helperCommands.isEmpty else { return nil }
        return helperCommands.joined(separator: " && ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
