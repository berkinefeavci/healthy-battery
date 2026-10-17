import Foundation

@main enum NativeChargeBackendTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError(label) }
            count += 1
        }

        let valid = Data(#"{"schemaVersion":1,"ok":true,"state":{"manualLimit":80,"availableLimits":[80,85,90,95,100],"enabledRaw":1,"currentLimit":80}}"#.utf8)
        var calls: [[String]] = []
        let backend = NativeChargeBackend(timeout: 0.1) { arguments, _ in
            calls.append(arguments)
            return NativeChargeProcessResult(status: 0, output: valid)
        }

        let read = try backend.readState()
        check(read == NativeChargeState(manualLimit: 80, availableLimits: [80, 85, 90, 95, 100], enabledRaw: 1, currentLimit: 80),
              "valid read decodes complete state")
        check(calls == [["read"]], "read uses exact command")

        _ = try backend.setLimit(85)
        check(calls == [["read"], ["set", "85"]], "set uses exact allowlisted decimal command")

        let beforeRejected = calls.count
        do {
            _ = try backend.setLimit(79)
            fatalError("unsupported limit accepted")
        } catch {
            check(error as? NativeChargeBackendError == .rejected("Bu şarj limiti desteklenmiyor."),
                  "unsupported limit rejected")
        }
        check(calls.count == beforeRejected, "unsupported limit launches no process")

        let missing = NativeChargeBackend.production(helperURL: URL(fileURLWithPath: "/definitely/missing/ChargeMateNativeChargeHelper"), timeout: 0.1)
        do {
            _ = try missing.readState()
            fatalError("missing helper accepted")
        } catch {
            check(error as? NativeChargeBackendError == .helperMissing, "missing helper reported")
        }

        let failed = NativeChargeBackend(timeout: 0.1) { _, _ in
            NativeChargeProcessResult(status: 7, output: Data(#"{"schemaVersion":1,"ok":false,"error":"reddedildi"}"#.utf8))
        }
        do {
            _ = try failed.readState()
            fatalError("nonzero exit accepted")
        } catch {
            check(error as? NativeChargeBackendError == .rejected("reddedildi"), "helper error preserved")
        }

        let timeout = NativeChargeBackend(timeout: 0.1) { _, _ in throw NativeChargeBackendError.timedOut }
        do {
            _ = try timeout.readState()
            fatalError("timeout accepted")
        } catch {
            check(error as? NativeChargeBackendError == .timedOut, "timeout preserved")
        }

        for (label, data) in [
            ("malformed", Data("not-json".utf8)),
            ("schema", Data(#"{"schemaVersion":2,"ok":true,"state":{"manualLimit":80,"availableLimits":[80],"enabledRaw":1,"currentLimit":80}}"#.utf8)),
            ("duplicate", Data(#"{"schemaVersion":1,"ok":true,"state":{"manualLimit":80,"availableLimits":[80,80],"enabledRaw":1,"currentLimit":80}}"#.utf8)),
            ("manual range", Data(#"{"schemaVersion":1,"ok":true,"state":{"manualLimit":101,"availableLimits":[80,90],"enabledRaw":1,"currentLimit":85}}"#.utf8)),
            ("range", Data(#"{"schemaVersion":1,"ok":true,"state":{"manualLimit":80,"availableLimits":[75,80],"enabledRaw":1,"currentLimit":80}}"#.utf8))
        ] {
            let invalid = NativeChargeBackend(timeout: 0.1) { _, _ in NativeChargeProcessResult(status: 0, output: data) }
            do {
                _ = try invalid.readState()
                fatalError("\(label) response accepted")
            } catch {
                check(error as? NativeChargeBackendError == .malformedResponse, "\(label) response rejected")
            }
        }

        let oversized = NativeChargeBackend(timeout: 0.1) { _, _ in
            NativeChargeProcessResult(status: 0, output: Data(repeating: 65, count: 65_537))
        }
        do {
            _ = try oversized.readState()
            fatalError("oversized response accepted")
        } catch {
            check(error as? NativeChargeBackendError == .oversizedResponse, "oversized response rejected")
        }

        let unordered = Data(#"{"schemaVersion":1,"ok":true,"state":{"manualLimit":85,"availableLimits":[100,80,85],"enabledRaw":1,"currentLimit":85}}"#.utf8)
        let normalized = NativeChargeBackend(timeout: 0.1) { _, _ in NativeChargeProcessResult(status: 0, output: unordered) }
        let normalizedState = try normalized.readState()
        check(normalizedState.availableLimits == [80, 85, 100], "valid limits sort for presentation")
        let observedStep = Data(#"{"schemaVersion":1,"ok":true,"state":{"manualLimit":81,"availableLimits":[80,85,90,95,100],"enabledRaw":1,"currentLimit":100}}"#.utf8)
        let observed = NativeChargeBackend(timeout: 0.1) { _, _ in NativeChargeProcessResult(status: 0, output: observedStep) }
        let observedState = try observed.readState()
        check(observedState.manualLimit == 81, "read accepts a real observed non-writable limit")

        // Every error the PowerUI bridge or the helper can print has a translation entry, so none reaches the
        // UI as untranslated Turkish. (Reads the sources, so a new message cannot be added unnoticed.)
        func messages(in path: String, pattern: String) throws -> [String] {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let regex = try NSRegularExpression(pattern: pattern)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        let bridge = try messages(in: "Sources/PowerUIBridge/PowerUIBridge.m", pattern: #"failure\(@"([^"]+)"\)"#)
            + (try messages(in: "Sources/PowerUIBridge/PowerUIBridge.m", pattern: #"\?: @"([^"]+)""#))
        let helper = try messages(in: "Sources/NativeChargeHelper/main.swift", pattern: #"failure\("([^"]+)"\)"#)
            .filter { $0 != "test" }
        check(bridge.count >= 9 && helper.count == 2, "found the bridge and helper messages in the sources")
        for message in bridge + helper {
            check(NativeChargeBackend.isTranslated(helperMessage: message), "helper message has a translation: \(message)")
        }
        check(NativeChargeBackend.localized(helperMessage: "text from macOS itself") == "text from macOS itself",
              "unknown helper text passes through")

        print("Native charge backend: \(count) assertions passed; fake process only.")
    }
}
