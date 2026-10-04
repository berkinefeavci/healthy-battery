import AppKit
import Darwin

/// Other charge-limit tools that write the same SMC/native charge settings as Healthy Battery. Two writers
/// fight over the limit, so while any of them is present Healthy Battery locks its own hardware writes.
///
/// Identifiers come from each project's own source (bundle IDs, launchd labels, daemon executable
/// names); verify against the upstream project before adding or changing an entry.
enum ChargeControllerDetector {
    struct Known {
        let name: String
        /// Matched as a prefix against running GUI apps' bundle identifiers.
        let bundlePrefixes: [String]
        /// Matched as a prefix against running process names (proc_name, at most 32 characters).
        let processPrefixes: [String]
        /// Matched exactly against running process names, for short generic names.
        let processNames: [String]
        /// launchd plists that re-apply the tool's limit at boot/login even when nothing is running.
        let installedPaths: [String]
    }

    struct Signals {
        var bundleIdentifiers: [String] = []
        var processNames: [String] = []
        var existingPaths: Set<String> = []
    }

    static func known(home: String) -> [Known] {
        [
            Known(name: "AlDente", bundlePrefixes: ["com.apphousekitchen.aldente"],
                  processPrefixes: [], processNames: [], installedPaths: []),
            Known(name: "Battery Toolkit", bundlePrefixes: ["me.mhaeuser.BatteryToolkit"],
                  processPrefixes: ["me.mhaeuser.batterytoolkitd"], processNames: [], installedPaths: []),
            Known(name: "BatFi", bundlePrefixes: ["software.micropixels.BatFi"],
                  processPrefixes: ["software.micropixels.BatFi"], processNames: [], installedPaths: []),
            Known(name: "batt", bundlePrefixes: ["cc.chlc.batt"],
                  processPrefixes: [], processNames: ["batt"], installedPaths: []),
            Known(name: "battery", bundlePrefixes: ["co.palokaj.battery"],
                  processPrefixes: [], processNames: [], installedPaths: [home + "/Library/LaunchAgents/battery.plist"]),
            Known(name: "bclm", bundlePrefixes: [], processPrefixes: [], processNames: [],
                  installedPaths: ["/Library/LaunchDaemons/com.zackelia.bclm.plist"]),
        ]
    }

    /// Names of the detected tools, in `known` order, without duplicates.
    static func detect(_ signals: Signals, home: String) -> [String] {
        known(home: home).filter { tool in
            signals.bundleIdentifiers.contains { id in tool.bundlePrefixes.contains { id.hasPrefix($0) } }
                || signals.processNames.contains { name in
                    tool.processNames.contains(name) || tool.processPrefixes.contains { name.hasPrefix($0) }
                }
                || tool.installedPaths.contains { signals.existingPaths.contains($0) }
        }.map(\.name)
    }

    /// Bundle identifiers of running GUI apps that belong to a known tool, for a graceful quit.
    static func quittableBundlePrefixes(home: String) -> [String] {
        known(home: home).flatMap(\.bundlePrefixes)
    }

    static func current() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = known(home: home).flatMap(\.installedPaths).filter { FileManager.default.fileExists(atPath: $0) }
        let signals = Signals(bundleIdentifiers: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier),
                              processNames: runningProcessNames(),
                              existingPaths: Set(paths))
        return detect(signals, home: home)
    }

    private static func runningProcessNames() -> [String] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var names: [String] = []
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { names.append(String(cString: buffer)) }
        }
        return names
    }
}
