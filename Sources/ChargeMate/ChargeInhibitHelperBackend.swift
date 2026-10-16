import Foundation

/// Wire format of `Tools/ChargeInhibitIPC.h`. Pure, so the protocol is unit-testable without a helper.
enum ChargeInhibitWire {
    enum Failure: Error, Equatable, LocalizedError {
        case badRequest, refused, failed, unsupported, gated, malformed, helperMissing, helperNotTrusted, locked
        var errorDescription: String? {
            switch self {
            case .badRequest: return "Şarj durdurma yardımcısı isteği anlamadı."
            case .refused: return "Şarj durdurma güvenlik kuralıyla reddedildi (pil düşük, adaptör yok veya uyku)."
            case .failed: return "Şarj durdurma yazılamadı ya da doğrulanamadı; her şey serbest bırakıldı."
            case .gated: return "macOS bu anahtarı özel yetkiye bağlamış (kIOReturnNotPrivileged); root olsa bile yazılamıyor."
            case .unsupported: return "Bu Mac'te doğrulanmış şarj durdurma anahtarı yok."
            case .malformed: return "Şarj durdurma yardımcısından geçersiz yanıt geldi."
            case .helperMissing: return "Şarj durdurma yardımcısı kurulu değil."
            case .helperNotTrusted: return "Şarj durdurma yardımcısı güvenli değil; işlem durduruldu."
            case .locked: return "Şarj durdurma henüz kilitli (deneysel, fiziksel test bekliyor)."
            }
        }
    }

    static let readRequest = "R\n"
    static let capabilitiesRequest = "C\n"
    static let heartbeatRequest = "H\n"

    static func setRequest(_ state: ChargeInhibitState) -> String {
        "S \(state.chargingInhibited ? 1 : 0) \(state.adapterInhibited ? 1 : 0)\n"
    }

    /// Splits "<status> <values…>"; throws the matching failure for a non-zero status.
    static func values(from response: String, allowed: ClosedRange<Int> = 0...1) throws -> [Int] {
        let fields = response.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = fields.first, let status = Int(first) else { throw Failure.malformed }
        switch status {
        case 0: break
        case 2: throw Failure.badRequest
        case 3: throw Failure.refused
        case 4: throw Failure.failed
        case 5: throw Failure.unsupported
        case 6: throw Failure.gated
        default: throw Failure.malformed
        }
        let numbers = fields.dropFirst().compactMap { Int($0) }
        guard numbers.count == fields.count - 1, numbers.allSatisfy({ allowed.contains($0) }) else { throw Failure.malformed }
        return numbers
    }

    static func state(from response: String) throws -> ChargeInhibitState {
        let numbers = try values(from: response)
        guard numbers.count == 2 else { throw Failure.malformed }
        return ChargeInhibitState(chargingInhibited: numbers[0] == 1, adapterInhibited: numbers[1] == 1)
    }

    /// "0 c a" (old) or "0 c a chargingReason adapterReason" with reasons 0 ok, 1 missing, 2 gated, 3 error.
    static func capabilities(from response: String) throws -> (charging: Bool, adapter: Bool, chargingReason: Int, adapterReason: Int) {
        let numbers = try values(from: response, allowed: 0...3)
        guard numbers.count == 2 || numbers.count == 4, numbers[0] <= 1, numbers[1] <= 1 else { throw Failure.malformed }
        let reasons = numbers.count == 4 ? (numbers[2], numbers[3]) : (numbers[0] == 1 ? 0 : 1, numbers[1] == 1 ? 0 : 1)
        return (numbers[0] == 1, numbers[1] == 1, reasons.0, reasons.1)
    }
}

/// Hidden/debug unlock. There is deliberately no settings UI for it: the feature stays locked
/// ("deneysel, fiziksel test bekliyor") until `docs/2026-10-06-Faz3-Fiziksel-Test.md` is signed off.
/// Enable for a test with: `defaults write io.github.berkinefeavci.cellkeep debug.chargeInhibitUnlocked -bool YES`
enum ChargeInhibitUnlock {
    static let defaultsKey = "debug.chargeInhibitUnlocked"
    static func isUnlocked(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }
}

/// `ChargeInhibitBackend` that talks to the root helper. Supported only when the feature is unlocked,
/// the helper is installed and trusted, and it reports the SMC keys as verified on this Mac.
struct ChargeInhibitHelperBackend: ChargeInhibitBackend {
    var isUnlocked: () -> Bool = { ChargeInhibitUnlock.isUnlocked() }
    var isInstalled: () -> Bool = { ChargeInhibitHelperService.installed() }
    var transport: (String) throws -> String = { try ChargeInhibitHelperService.request($0) }

    func capabilities() -> ChargeInhibitCapabilities {
        guard isUnlocked() else {
            return ChargeInhibitCapabilities(canInhibitCharging: false, canForceDischarge: false,
                                             reason: ChargeInhibitWire.Failure.locked.errorDescription)
        }
        guard isInstalled() else {
            return ChargeInhibitCapabilities(canInhibitCharging: false, canForceDischarge: false,
                                             reason: ChargeInhibitWire.Failure.helperMissing.errorDescription)
        }
        do {
            let verified = try ChargeInhibitWire.capabilities(from: transport(ChargeInhibitWire.capabilitiesRequest))
            guard verified.charging || verified.adapter else {
                // Gated (macOS refuses the key) is reported distinctly from missing (no such key).
                let gated = verified.chargingReason == 2 || verified.adapterReason == 2
                return ChargeInhibitCapabilities(canInhibitCharging: false, canForceDischarge: false,
                                                 reason: (gated ? ChargeInhibitWire.Failure.gated : .unsupported).errorDescription)
            }
            // The adapter channel (CHIE) alone is enough; CHTE is not required.
            return ChargeInhibitCapabilities(canInhibitCharging: verified.charging, canForceDischarge: verified.adapter,
                                             reason: nil)
        } catch {
            return ChargeInhibitCapabilities(canInhibitCharging: false, canForceDischarge: false,
                                             reason: error.localizedDescription)
        }
    }

    func readState() throws -> ChargeInhibitState {
        try requireSupported(forInhibit: false)
        return try ChargeInhibitWire.state(from: transport(ChargeInhibitWire.readRequest))
    }

    func apply(_ state: ChargeInhibitState) throws -> ChargeInhibitState {
        // Releasing is always allowed once the helper exists; inhibiting needs a verified capability.
        let releasing = !state.chargingInhibited && !state.adapterInhibited
        if !releasing {
            let current = capabilities()
            guard current.canInhibitCharging || current.canForceDischarge else {
                throw ChargeInhibitWire.Failure.unsupported
            }
            if state.chargingInhibited && !current.canInhibitCharging { throw ChargeInhibitWire.Failure.unsupported }
            if state.adapterInhibited && !current.canForceDischarge { throw ChargeInhibitWire.Failure.unsupported }
        } else {
            guard isInstalled() else { return .released }
        }
        let applied = try ChargeInhibitWire.state(from: transport(ChargeInhibitWire.setRequest(state)))
        guard applied == state else { throw ChargeInhibitWire.Failure.failed } // the helper already read it back
        return applied
    }

    func heartbeat() throws {
        try requireSupported(forInhibit: false)
        _ = try ChargeInhibitWire.values(from: transport(ChargeInhibitWire.heartbeatRequest))
    }

    private func requireSupported(forInhibit: Bool) throws {
        guard isUnlocked() else { throw ChargeInhibitWire.Failure.locked }
        guard isInstalled() else { throw ChargeInhibitWire.Failure.helperMissing }
    }
}

/// Owns the 20 s heartbeat while something is inhibited. It never starts on its own: `hold` is
/// called only by a feature that wants to inhibit, and only while the backend reports a capability.
/// If the heartbeat cannot be delivered, the helper's 60 s watchdog releases everything.
final class ChargeInhibitHeartbeat {
    private let backend: ChargeInhibitBackend
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "io.github.berkinefeavci.cellkeep.chargeinhibit.heartbeat")
    private let lock = NSLock() // guards `timer`; never queue.sync, the failure path stops from the queue itself
    /// Called (on the heartbeat queue) when a heartbeat fails; the timer is stopped first.
    var onFailure: ((Error) -> Void)?

    init(backend: ChargeInhibitBackend, interval: TimeInterval = ChargeInhibitSafety.heartbeatInterval) {
        self.backend = backend
        self.interval = interval
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return timer != nil }

    /// Applies `state`; keeps a heartbeat running while it is not the released state.
    @discardableResult
    func hold(_ state: ChargeInhibitState) throws -> ChargeInhibitState {
        let wantsInhibit = state.chargingInhibited || state.adapterInhibited
        if wantsInhibit {
            let capabilities = backend.capabilities()
            guard capabilities.canInhibitCharging || capabilities.canForceDischarge else {
                throw ChargeInhibitWire.Failure.unsupported
            }
        }
        let applied = try backend.apply(state)
        if applied.chargingInhibited || applied.adapterInhibited { start() } else { stop() }
        return applied
    }

    func release() { _ = try? hold(.released); stop() }

    /// One heartbeat; returns false (and stops the timer) when it could not be delivered.
    @discardableResult
    func beat() -> Bool {
        do { try backend.heartbeat(); return true }
        catch { stop(); onFailure?(error); return false }
    }

    private func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.beat() }
        source.resume()
        timer = source
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }
}

/// Installs/queries the root helper. Mirrors `SystemPowerModeService` (one admin prompt, root-owned
/// copy checked before it runs). Nothing calls `install()` automatically: it is exposed for the
/// future, explicit "Şarj durdurmayı etkinleştir" action only. Removal is part of `UninstallPlan`.
enum ChargeInhibitHelperService {
    static let label = "io.github.berkinefeavci.cellkeep.chargeinhibit"
    static let helperPath = "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.chargeinhibit"
    static let socketPath = "/var/run/io.github.berkinefeavci.cellkeep.chargeinhibit.sock"
    static let minimumHelperVersion = 1
    static let bundledHelperName = "CellkeepChargeInhibitHelper"

    static func installed() -> Bool {
        guard (helperVersion() ?? 0) >= minimumHelperVersion else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: helperPath)
        let owner = (attributes?[.ownerAccountID] as? NSNumber)?.intValue
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        return HelperInstallState.isTrusted(ownerUID: owner, posixPermissions: mode,
                                             socketExists: FileManager.default.fileExists(atPath: socketPath))
    }

    /// The one admin shell command: copy → verify signature → write plist → authorize this user → (re)load.
    /// Pure and public so tests can inspect it; `install()` is the only caller that runs it.
    static func installCommand(bundledHelperPath: String, teamIdentifier: String?, uid: uid_t) -> String {
        let quote = HelperInstallState.shellQuoted
        return "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools && " +
            "/usr/bin/install -o root -g wheel -m 755 \(quote(bundledHelperPath)) \(quote(helperPath)) && " +
            HelperInstallState.signatureCheckCommand(installedPath: helperPath, teamIdentifier: teamIdentifier) + " && " +
            HelperInstallState.writeLaunchDaemonPlistCommand(label: label, helperPath: helperPath) + " && " +
            "\(quote(helperPath)) --authorize-uid \(uid) && " +
            "(/bin/launchctl bootout system/\(label) 2>/dev/null || true) && " +
            "/bin/launchctl bootstrap system /Library/LaunchDaemons/\(label).plist"
    }

    static func install() throws {
        guard let executable = Bundle.main.executableURL else { throw ChargeInhibitWire.Failure.helperMissing }
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent(bundledHelperName)
        guard FileManager.default.fileExists(atPath: bundled.path) else { throw ChargeInhibitWire.Failure.helperMissing }
        try authorized(installCommand(bundledHelperPath: bundled.path,
                                      teamIdentifier: HelperInstallState.currentTeamIdentifier(), uid: getuid()))
        guard installed() else { throw ChargeInhibitWire.Failure.helperNotTrusted }
    }

    static func request(_ line: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChargeInhibitWire.Failure.helperMissing }
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
        guard connected == 0 else { throw ChargeInhibitWire.Failure.helperMissing }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw ChargeInhibitWire.Failure.helperNotTrusted }
        let bytes = Array(line.utf8)
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress!, bytes.count) }) == bytes.count else {
            throw ChargeInhibitWire.Failure.failed
        }
        var response = [UInt8]()
        while response.count < 32 {
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { throw ChargeInhibitWire.Failure.malformed }
            if byte == 10 { break }
            response.append(byte)
        }
        guard let text = String(bytes: response, encoding: .utf8) else { throw ChargeInhibitWire.Failure.malformed }
        return text
    }

    private static func authorized(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ChargeInhibitWire.Failure.failed }
    }

    private static func helperVersion() -> Int? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
