import Foundation

@main enum ChargeInhibitHelperBackendTests {
    final class FakeHelper {
        var requests: [String] = []
        var responses: [String: String] = ["C\n": "0 1 1", "R\n": "0 0 0", "H\n": "0"]
        var failHeartbeat = false
        func send(_ line: String) throws -> String {
            requests.append(line)
            if line == "H\n" && failHeartbeat { throw ChargeInhibitWire.Failure.failed }
            if line.hasPrefix("S "), responses[line] == nil {
                return "0 " + line.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return responses[line] ?? "2"
        }
    }

    static func backend(_ helper: FakeHelper, unlocked: Bool = true, installed: Bool = true) -> ChargeInhibitHelperBackend {
        ChargeInhibitHelperBackend(isUnlocked: { unlocked }, isInstalled: { installed }, transport: helper.send)
    }

    static func main() throws {
        // Wire format.
        precondition(ChargeInhibitWire.setRequest(.init(chargingInhibited: true, adapterInhibited: false)) == "S 1 0\n")
        precondition(ChargeInhibitWire.setRequest(.released) == "S 0 0\n")
        let parsed = try ChargeInhibitWire.state(from: "0 1 0")
        precondition(parsed == .init(chargingInhibited: true, adapterInhibited: false))
        for (text, expected) in [("2", ChargeInhibitWire.Failure.badRequest), ("3", .refused), ("4", .failed), ("5", .unsupported),
                                 ("", .malformed), ("x", .malformed), ("9", .malformed), ("0 1", .malformed), ("0 2 0", .malformed)] {
            do { _ = try ChargeInhibitWire.state(from: text); preconditionFailure("\(text) must throw") }
            catch let failure as ChargeInhibitWire.Failure { precondition(failure == expected, "\(text)") }
        }

        // Locked by default: unsupported with a reason, and no helper traffic at all.
        let locked = FakeHelper()
        let lockedCaps = backend(locked, unlocked: false).capabilities()
        precondition(!lockedCaps.canInhibitCharging && !lockedCaps.canForceDischarge && lockedCaps.reason != nil)
        precondition(locked.requests.isEmpty)
        precondition(!ChargeInhibitUnlock.isUnlocked(UserDefaults(suiteName: "faz3-test-\(UUID().uuidString)")!))
        do { _ = try backend(locked, unlocked: false).apply(.init(chargingInhibited: true, adapterInhibited: false)); preconditionFailure() }
        catch { precondition(locked.requests.isEmpty) }

        // Not installed: unsupported, release is a harmless no-op.
        let missing = FakeHelper()
        precondition(backend(missing, installed: false).capabilities() == ChargeInhibitCapabilities(
            canInhibitCharging: false, canForceDischarge: false, reason: ChargeInhibitWire.Failure.helperMissing.errorDescription))
        let noop = try backend(missing, installed: false).apply(.released)
        precondition(noop == .released && missing.requests.isEmpty)

        // Keys verified: mapped capabilities. This Mac's reality (adapter key only) must work too.
        let both = FakeHelper()
        let bothCaps = backend(both).capabilities()
        precondition(bothCaps.canInhibitCharging && bothCaps.canForceDischarge && bothCaps.reason == nil)
        let adapterOnly = FakeHelper(); adapterOnly.responses["C\n"] = "0 0 1"
        let adapterCaps = backend(adapterOnly).capabilities()
        precondition(!adapterCaps.canInhibitCharging && adapterCaps.canForceDischarge)
        do { _ = try backend(adapterOnly).apply(.init(chargingInhibited: true, adapterInhibited: false)); preconditionFailure() }
        catch let failure as ChargeInhibitWire.Failure { precondition(failure == .unsupported) }
        precondition(!adapterOnly.requests.contains { $0.hasPrefix("S ") }, "unsupported inhibit must not reach the helper")
        let none = FakeHelper(); none.responses["C\n"] = "0 0 0"
        let noneCaps = backend(none).capabilities()
        precondition(!noneCaps.canInhibitCharging && !noneCaps.canForceDischarge && noneCaps.reason != nil)

        // Apply is verified against the request; a mismatching reply is an error.
        let appliedState = try backend(both).apply(.init(chargingInhibited: true, adapterInhibited: false))
        precondition(appliedState.chargingInhibited)
        let lying = FakeHelper(); lying.responses["S 1 0\n"] = "0 0 0"
        do { _ = try backend(lying).apply(.init(chargingInhibited: true, adapterInhibited: false)); preconditionFailure() }
        catch let failure as ChargeInhibitWire.Failure { precondition(failure == .failed) }

        // Heartbeat owner: never starts for an unsupported backend, runs while inhibited, stops on release.
        let idle = ChargeInhibitHeartbeat(backend: backend(none), interval: 0.05)
        do { _ = try idle.hold(.init(chargingInhibited: true, adapterInhibited: false)); preconditionFailure() }
        catch { precondition(!idle.isRunning) }
        let owner = ChargeInhibitHeartbeat(backend: backend(both), interval: 0.05)
        precondition(!owner.isRunning, "not started until a feature asks")
        _ = try owner.hold(.init(chargingInhibited: true, adapterInhibited: false))
        precondition(owner.isRunning)
        Thread.sleep(forTimeInterval: 0.3)
        precondition(both.requests.filter { $0 == "H\n" }.count >= 3, "heartbeats flow while inhibited")
        _ = try owner.hold(.released)
        precondition(!owner.isRunning)
        let beats = both.requests.filter { $0 == "H\n" }.count
        Thread.sleep(forTimeInterval: 0.2)
        precondition(both.requests.filter { $0 == "H\n" }.count == beats, "no heartbeat after release")

        // A failing heartbeat stops the timer and reports (the helper's watchdog then releases).
        let flaky = FakeHelper()
        let failing = ChargeInhibitHeartbeat(backend: backend(flaky), interval: 0.05)
        var reported = false
        failing.onFailure = { _ in reported = true }
        _ = try failing.hold(.init(chargingInhibited: false, adapterInhibited: true))
        flaky.failHeartbeat = true
        Thread.sleep(forTimeInterval: 0.3)
        precondition(reported && !failing.isRunning)

        // Install command: one chained admin command, root-owned copy checked before launch.
        let command = ChargeInhibitHelperService.installCommand(bundledHelperPath: "/Apps/x y/Helper", teamIdentifier: "ABCDE12345", uid: 501)
        precondition(command.contains("--authorize-uid 501"))
        precondition(command.contains("launchctl bootstrap system /Library/LaunchDaemons/io.github.berkinefeavci.cellkeep.chargeinhibit.plist"))
        precondition(command.contains("'/Apps/x y/Helper'"))
        precondition(command.range(of: "codesign --verify")!.lowerBound < command.range(of: "--authorize-uid")!.lowerBound)
        precondition(ChargeInhibitHelperService.minimumHelperVersion == 1)
        precondition(ChargeInhibitSafety.watchdogTimeout == 60 && ChargeInhibitSafety.criticalPercent == 10)
        print("Charge inhibit backend: wire format, lock, capabilities, heartbeat owner and install command assertions passed; no helper contacted.")
    }
}
