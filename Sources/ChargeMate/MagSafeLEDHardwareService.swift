import Foundation
import Darwin

/// Authorized settings and manual control; a root-owned service maintains the policy.
/// The installed executable is root-owned and accepts only four fixed ACLC values.
final class MagSafeLEDHardwareService {
    static let shared = MagSafeLEDHardwareService()
    static let installedPath = "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.led"
    /// Root helper/daemon identity installed by versions of this app published as "ChargeMate".
    static let legacyInstalledPath = "/Library/PrivilegedHelperTools/com.chargemate.ledctl"
    static let legacyLaunchDaemonLabel = "local.chargemate.led"
    private static let legacySocketPath = "/var/run/local.chargemate.led.sock"
    /// Matches LED_HELPER_VERSION in Tools/LEDControllers.h. Version 2 also backs off for Battery
    /// Toolkit, BatFi and batt, not just AlDente; older helpers show as not installed so the user reinstalls.
    private static let minimumHelperVersion = 2

    enum ServiceError: Error, LocalizedError {
        case helperMissing
        case helperNotTrusted
        case unsupportedValue
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing: return String(localized: "LED yardımcısı kurulmamış. Önce denetimi etkinleştirin.")
            case .helperNotTrusted: return String(localized: "LED yardımcısı yöneticiye ait değil; kullanılamaz.")
            case .unsupportedValue: return String(localized: "Bu ışık çıkışı desteklenmiyor.")
            case .commandFailed(let detail): return String(localized: "LED komutu tamamlanamadı: \(detail)")
            }
        }
    }

    private let journal: URL
    private lazy var coordinator = makeCoordinator()
    private func makeCoordinator() -> MagSafeLEDControlCoordinator {
        let backend = MagSafeLEDControlCoordinator.Backend(
            supportedOutputs: [.system, .green, .orange, .off],
            read: { try Self.readLED() },
            write: { try Self.writeLED($0) }
        )
        return MagSafeLEDControlCoordinator(journal: journal, backend: backend)
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        journal = support.appendingPathComponent("Cellkeep/magsafe-led-session.json")
    }

    static func installed() -> Bool {
        guard (helperVersion() ?? 0) >= minimumHelperVersion else { return false }
        return trusted(atPath: installedPath, socketPath: "/var/run/io.github.berkinefeavci.cellkeep.led.sock")
    }

    /// True when a helper installed by the previous "ChargeMate" identity is present, root-owned.
    static func legacyInstalled() -> Bool {
        trusted(atPath: legacyInstalledPath, socketPath: legacySocketPath)
    }

    private static func helperVersion() -> Int? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: installedPath)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func trusted(atPath path: String, socketPath: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let owner = (attributes?[.ownerAccountID] as? NSNumber)?.intValue
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        return HelperInstallState.isTrusted(ownerUID: owner, posixPermissions: mode,
                                             socketExists: FileManager.default.fileExists(atPath: socketPath))
    }

    /// True when the legacy helper is present but the current one is not yet — the one-time
    /// install/upgrade flow should replace it.
    static func updateRequired() -> Bool { legacyInstalled() && !installed() }

    static func install() throws {
        guard let executable = Bundle.main.executableURL else { throw ServiceError.helperMissing }
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/CellkeepLEDHelper")
        guard FileManager.default.fileExists(atPath: bundled.path) else { throw ServiceError.helperMissing }
        let legacyCleanup = legacyInstalled()
            ? "(/bin/launchctl bootout system/\(legacyLaunchDaemonLabel) 2>/dev/null || true) && " +
              "/bin/rm -f \(shellQuote(legacyInstalledPath)) /Library/LaunchDaemons/\(legacyLaunchDaemonLabel).plist && "
            : ""
        let command = legacyCleanup +
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools && " +
            "/usr/bin/install -o root -g wheel -m 755 \(shellQuote(bundled.path)) \(shellQuote(installedPath)) && " +
            HelperInstallState.signatureCheckCommand(installedPath: installedPath,
                                                     teamIdentifier: HelperInstallState.currentTeamIdentifier()) + " && " +
            HelperInstallState.writeLaunchDaemonPlistCommand(label: "io.github.berkinefeavci.cellkeep.led",
                                                             helperPath: installedPath) + " && " +
            "\(shellQuote(installedPath)) --authorize-uid \(getuid()) && " +
            "(/bin/launchctl bootout system/io.github.berkinefeavci.cellkeep.led 2>/dev/null || true) && " +
            "/bin/launchctl bootstrap system /Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.led.plist"
        try authorized(command)
        guard installed() else { throw ServiceError.helperNotTrusted }
    }

    func apply(_ output: MagSafeLEDOutput) -> MagSafeLEDControlCoordinator.Outcome {
        guard Self.installed() else { return .blocked(String(localized: "LED yardımcısı kurulmamış.")) }
        // "System" ends manual control and returns to the policy saved on the MagSafe page. It used to
        // save "System" as that policy, which silently erased a chosen night window.
        if output == .system { return resumeSavedPolicy() }
        // A half-finished or unreadable test is settled by the saved policy, not by forcing the
        // colour read before it (that colour may have been macOS's own choice).
        if coordinator.requiresRecovery && !coordinator.sessionActive {
            let resumed = resumeSavedPolicy()
            guard resumed == .restored else { return resumed }
        }
        return coordinator.apply(output)
    }

    /// Ends a manual test: the light goes back to the policy chosen on the MagSafe page.
    func restore() -> MagSafeLEDControlCoordinator.Outcome {
        guard Self.installed() else { return .blocked(String(localized: "LED yardımcısı kurulmamış.")) }
        return resumeSavedPolicy()
    }

    private func resumeSavedPolicy() -> MagSafeLEDControlCoordinator.Outcome {
        let defaults = UserDefaults.standard
        let saved = MagSafeLEDPolicy(rawValue: defaults.string(forKey: MagSafeLEDPreferences.policyKey) ?? "") ?? .system
        let start = defaults.object(forKey: MagSafeLEDTimeWindow.startKey) as? Int ?? MagSafeLEDTimeWindow.defaultStart
        let end = defaults.object(forKey: MagSafeLEDTimeWindow.endKey) as? Int ?? MagSafeLEDTimeWindow.defaultEnd
        do {
            try Self.configure(policy: saved == .status ? .system : saved, start: start, end: end)
            return .restored
        } catch {
            return .blocked(error.localizedDescription)
        }
    }

    var requiresRecovery: Bool { coordinator.requiresRecovery }

    /// A manual test pauses the root service until the policy is applied again. At launch nobody is
    /// mid-test any more, so a pause left behind (app quit, forgotten "Back to start") is ended here.
    static func resumeIfPausedByTest() {
        guard helperState() == .pausedByTest, installed() else { return }
        _ = shared.restore()
    }

    static func configure(policy: MagSafeLEDPolicy, start: Int, end: Int) throws {
        guard (0..<1440).contains(start), (0..<1440).contains(end) else { throw ServiceError.unsupportedValue }
        let mode: Int
        switch policy {
        case .system: mode = 0
        case .alwaysOff: mode = 1
        case .scheduled: mode = 2
        case .status: throw ServiceError.unsupportedValue
        }
        try request("P \(mode) \(start) \(end)")
        // An explicit policy selection transfers ownership from a manual test.
        // Its old baseline must not later overwrite the newly selected policy.
        if FileManager.default.fileExists(atPath: shared.journal.path) {
            try FileManager.default.removeItem(at: shared.journal)
        }
        shared.coordinator = shared.makeCoordinator()
    }

    static func helperState() -> MagSafeLEDHelperState? {
        (try? String(contentsOfFile: "/Library/Application Support/CellkeepLED/policy")).flatMap(MagSafeLEDHelperState.parse)
    }

    static func savedPolicy() -> (MagSafeLEDPolicy, Int, Int)? {
        guard case .policy(let policy, let start, let end) = helperState() else { return nil }
        return (policy, start, end)
    }

    private static func readLED() throws -> MagSafeLEDOutput {
        let value = try SMCReader.shared.read("ACLC")
        guard value.type == "ui8 ", value.bytes.count == 1,
              let output = MagSafeLEDRawCodec.decode(value.bytes[0]) else {
            throw ServiceError.unsupportedValue
        }
        return output
    }

    private static func writeLED(_ output: MagSafeLEDOutput) throws {
        guard installed() else { throw ServiceError.helperNotTrusted }
        guard let value = MagSafeLEDRawCodec.encode(output) else { throw ServiceError.unsupportedValue }
        // The helper only answers after eight settled 1 s samples (~8.5 s), though the light changes
        // at once. Send without waiting for that answer and confirm with our own read instead; a
        // press right after another waits for the helper to free up, hence the 12 s limit.
        try request("W \(value)", awaitReply: false)
        let deadline = Date().addingTimeInterval(12)
        repeat {
            if (try? readLED()) == output { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw ServiceError.commandFailed(String(localized: "Işık istenen renge geçmedi."))
    }

    static func verifyConnection() throws { try request("PING") }

    private static func request(_ command: String, awaitReply: Bool = true) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServiceError.helperMissing }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/io.github.berkinefeavci.cellkeep.led.sock"
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            path.utf8CString.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ServiceError.helperMissing }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw ServiceError.helperNotTrusted }
        let bytes = Array((command + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), bytes.count - sent) }
            guard count > 0 else { throw ServiceError.commandFailed(String(localized: "Yardımcıya ulaşılamadı.")) }
            sent += count
        }
        guard awaitReply else { return }
        var response = [UInt8]()
        while response.count < 16 {
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { throw ServiceError.commandFailed(String(localized: "Yardımcı yanıt vermedi.")) }
            if byte == 10 { break }
            response.append(byte)
        }
        guard String(bytes: response, encoding: .utf8) == "0" else {
            throw ServiceError.commandFailed(String(localized: "İşlem tamamlanamadı. Yardımcı güncellemesi veya ışığın yeniden denetlenmesi gerekiyor."))
        }
    }

    private static func authorized(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let detail = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? String(localized: "Bilinmeyen hata")
        guard process.terminationStatus == 0 else { throw ServiceError.commandFailed(detail) }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
