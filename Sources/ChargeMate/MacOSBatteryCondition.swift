import Foundation

/// macOS's own battery condition (System Settings → Battery → Battery Health: Normal or Service
/// Recommended). IOKit no longer publishes it on Apple Silicon; `system_profiler SPPowerDataType`
/// does, in about 0.2 s. Read in the background at launch and then at most every 6 hours.
enum MacOSBatteryCondition {
    /// `sppower_battery_health` from `system_profiler SPPowerDataType -json`; nil when absent.
    static func parse(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            if let info = item["sppower_battery_health_info"] as? [String: Any],
               let health = info["sppower_battery_health"] as? String, !health.isEmpty { return health }
        }
        return nil
    }

    /// "Good" is what System Settings shows as Normal; anything else means macOS recommends service.
    static func text(forHealth raw: String) -> String {
        raw.caseInsensitiveCompare("Good") == .orderedSame || raw.caseInsensitiveCompare("Normal") == .orderedSame
            ? String(localized: "Normal") : String(localized: "Servis önerilir")
    }
}

#if canImport(AppKit)
final class MacOSBatteryConditionReader {
    static let shared = MacOSBatteryConditionReader()
    static let refreshInterval: TimeInterval = 6 * 3600

    /// Display text; nil until the first read finished (or when macOS reports nothing).
    private(set) var text: String?
    private var lastRead = Date.distantPast
    private var reading = false

    /// Main thread. Starts a background read when due; `onChange` runs on main when the text changed.
    func refreshIfDue(now: Date = Date(), onChange: @escaping () -> Void) {
        guard !reading, now.timeIntervalSince(lastRead) >= Self.refreshInterval else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPPowerDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var health: String?
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                health = MacOSBatteryCondition.parse(data)
            }
            DispatchQueue.main.async {
                self.reading = false
                self.lastRead = Date()
                let text = health.map(MacOSBatteryCondition.text(forHealth:))
                if text != self.text { self.text = text; onChange() }
            }
        }
    }
}
#endif
