import Darwin
import Foundation

enum SystemPowerMode: Int, CaseIterable, Hashable {
    case automatic = 0
    case lowPower = 1
    case turbo = 2

    var title: String {
        switch self {
        case .automatic: return String(localized: "Otomatik")
        case .lowPower: return String(localized: "Tasarruf")
        case .turbo: return String(localized: "Turbo")
        }
    }

    var command: String { "/usr/bin/pmset -a powermode \(rawValue)" }

    static func parse(pmset output: String, externalPower: Bool = true) -> Self? {
        let section = externalPower ? "AC Power:" : "Battery Power:"
        let selected = output.components(separatedBy: section).dropFirst().first ?? output
        guard let match = selected.range(of: #"(?m)^\s*powermode\s+(\d+)\s*$"#, options: .regularExpression),
              let value = Int(selected[match].split(whereSeparator: { $0.isWhitespace }).last ?? "") else { return nil }
        return Self(rawValue: value)
    }
}

enum SystemPowerSource: String, CaseIterable, Hashable {
    case battery
    case adapter
    case all

    var requestCode: String {
        switch self {
        case .battery: return "B"
        case .adapter: return "C"
        case .all: return "A"
        }
    }

    func arguments(for mode: SystemPowerMode) -> [String] {
        let flag: String
        switch self {
        case .battery: flag = "-b"
        case .adapter: flag = "-c"
        case .all: flag = "-a"
        }
        return [flag, "powermode", String(mode.rawValue)]
    }
}

struct SystemPowerModeProfiles: Equatable {
    let battery: SystemPowerMode
    let adapter: SystemPowerMode

    static func parse(pmset output: String) -> Self? {
        guard output.contains("Battery Power:"), output.contains("AC Power:"),
              let battery = SystemPowerMode.parse(pmset: output, externalPower: false),
              let adapter = SystemPowerMode.parse(pmset: output, externalPower: true) else { return nil }
        return .init(battery: battery, adapter: adapter)
    }

    func active(externalPower: Bool) -> SystemPowerMode {
        externalPower ? adapter : battery
    }

    func mode(for source: SystemPowerSource) -> SystemPowerMode? {
        switch source {
        case .battery: return battery
        case .adapter: return adapter
        case .all: return battery == adapter ? battery : nil
        }
    }
}

enum SystemPowerModeService {
    static let helperPath = "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.powermode"
    private static let socketPath = "/var/run/io.github.berkinefeavci.cellkeep.powermode.sock"
    /// Matches POWER_MODE_HELPER_VERSION in Tools/PowerModeHelper.c. 3: callers must be the signed app.
    private static let minimumHelperVersion = 3
    /// Root helper/daemon identity installed by versions of this app published as "ChargeMate".
    static let legacyHelperPath = "/Library/PrivilegedHelperTools/com.chargemate.powermode"
    static let legacyLaunchDaemonLabel = "local.chargemate.powermode"
    private static let legacySocketPath = "/var/run/local.chargemate.powermode.sock"

    static func read(externalPower: Bool) -> SystemPowerMode? {
        readProfiles()?.active(externalPower: externalPower)
    }

    static func readProfiles() -> SystemPowerModeProfiles? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        return SystemPowerModeProfiles.parse(pmset: output)
    }

    static func parseCapabilities(_ output: String) -> Set<SystemPowerMode> {
        var modes: Set<SystemPowerMode> = [.automatic]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields.last == "1" else { continue }
            if fields.first == "lowpowermode" { modes.insert(.lowPower) }
            if fields.first == "highpowermode" { modes.insert(.turbo) }
        }
        return modes
    }

    /// Hardware capability; it does not change while the app runs. SwiftUI views read this
    /// during rendering, so it must never spin the run loop (waitUntilExit does, and the
    /// re-entrant layout crashed the app with an AttributeGraph precondition failure).
    static func availableModes() -> Set<SystemPowerMode> { cachedModes }

    /// Call once at launch off the main thread so the first view render finds it ready.
    static func warmUpCapabilities() { _ = cachedModes }

    private static let cachedModes: Set<SystemPowerMode> = readAvailableModes()

    private static func readAvailableModes() -> Set<SystemPowerMode> {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "cap"]
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return [.automatic] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning { usleep(2_000) }
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
            return [.automatic]
        }
        return parseCapabilities(output)
    }

    enum WriteError: LocalizedError {
        case helperMissing
        case helperNotTrusted
        case commandFailed
        /// The user dismissed the administrator prompt; nothing was installed or changed.
        case cancelled
        case message(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return String(localized: "Yönetici onayı iptal edildi; yardımcı kurulmadı.")
            case .helperMissing: return String(localized: "Güç modu yardımcısı kurulamadı.")
            case .helperNotTrusted: return String(localized: "Güç modu yardımcısı güvenli değil; işlem durduruldu.")
            case .commandFailed: return String(localized: "macOS güç modu değiştirilemedi.")
            case .message(let value): return value
            }
        }
    }

    static func installed() -> Bool {
        guard isCompatibleHelperVersion(helperVersion()) else { return false }
        return trusted(atPath: helperPath, socketPath: socketPath)
    }

    static func isCompatibleHelperVersion(_ version: Int?) -> Bool {
        (version ?? 0) >= minimumHelperVersion
    }

    /// True when a helper installed by the previous "ChargeMate" identity is present, root-owned.
    /// The legacy helper predates versioning, so no version gate applies here.
    static func legacyInstalled() -> Bool {
        trusted(atPath: legacyHelperPath, socketPath: legacySocketPath)
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
        guard let executable = Bundle.main.executableURL else { throw WriteError.helperMissing }
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let bundled = resources.appendingPathComponent("CellkeepPowerModeHelper")
        guard FileManager.default.fileExists(atPath: bundled.path) else { throw WriteError.helperMissing }
        let command = HelperInstallState.installCommand(
            label: "io.github.berkinefeavci.cellkeep.powermode", helperPath: helperPath,
            bundledHelperPath: bundled.path, teamIdentifier: HelperInstallState.currentTeamIdentifier(), uid: getuid(),
            legacyCleanup: legacyInstalled()
                ? HelperInstallState.legacyCleanupCommand(daemonLabel: legacyLaunchDaemonLabel, binaryPath: legacyHelperPath)
                : "")
        try authorized(command)
        guard installed() else { throw WriteError.helperNotTrusted }
    }

    static func apply(_ mode: SystemPowerMode) -> Result<SystemPowerMode, WriteError> {
        apply(mode, source: .all)
    }

    static func apply(_ mode: SystemPowerMode, source: SystemPowerSource) -> Result<SystemPowerMode, WriteError> {
        do {
            if !installed() { try install() }
            try request(mode, source: source)
            guard readProfiles()?.mode(for: source) == mode else {
                return .failure(.message(String(localized: "macOS güç modu değişikliği doğrulanamadı.")))
            }
            return .success(mode)
        } catch let error as WriteError {
            return .failure(error)
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }

    /// Background callers never install or prompt. They may use only an already trusted helper.
    static func applyInstalled(_ mode: SystemPowerMode) -> Result<SystemPowerMode, WriteError> {
        applyInstalled(mode, source: .all)
    }

    static func applyInstalled(_ mode: SystemPowerMode, source: SystemPowerSource) -> Result<SystemPowerMode, WriteError> {
        guard installed() else { return .failure(.helperMissing) }
        do {
            try request(mode, source: source)
            guard readProfiles()?.mode(for: source) == mode else {
                return .failure(.message(String(localized: "macOS güç modu değişikliği doğrulanamadı.")))
            }
            return .success(mode)
        } catch let error as WriteError { return .failure(error) }
        catch { return .failure(.message(error.localizedDescription)) }
    }

    private static func request(_ mode: SystemPowerMode, source: SystemPowerSource) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WriteError.helperMissing }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            socketPath.utf8CString.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw WriteError.helperMissing }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw WriteError.helperNotTrusted }
        let request = Array("M \(source.requestCode) \(mode.rawValue)\n".utf8)
        guard request.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress!, request.count) }) == request.count else {
            throw WriteError.commandFailed
        }
        var response = [UInt8]()
        while response.count < 8 {
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { throw WriteError.commandFailed }
            if byte == 10 { break }
            response.append(byte)
        }
        guard String(bytes: response, encoding: .utf8) == "0" else { throw WriteError.commandFailed }
    }

    private static func authorized(_ command: String) throws {
        do { try AdminAuthorization.run(command) }
        catch AdminAuthorization.Failure.cancelled { throw WriteError.cancelled }
        catch AdminAuthorization.Failure.failed(let detail) {
            throw WriteError.message(detail.isEmpty ? String(localized: "macOS yönetici izni vermedi.") : detail)
        }
    }

    private static func helperVersion() -> Int? {
        HelperInstallState.cachedVersion(atPath: helperPath) { HelperInstallState.readVersion(ofHelperAt: helperPath) }
    }
}
