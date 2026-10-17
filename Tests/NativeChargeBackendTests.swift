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

        // The helper is a separate process without the app's language setting, so the app translates its
        // fixed (Turkish) failure messages. Every such literal in the helper sources must be listed.
        let literal = try NSRegularExpression(pattern: #""([^"\\]*\.)""#)
        var helperMessages = Set<String>()
        for path in ["Sources/PowerUIBridge/PowerUIBridge.m", "Sources/NativeChargeHelper/main.swift"] {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("failure(") {
                let line = String(line)
                for match in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    helperMessages.insert(String(line[Range(match.range(at: 1), in: line)!]))
                }
            }
        }
        check(helperMessages.count >= 11, "found the helper's fixed messages in its sources")
        check(helperMessages.isSubset(of: Set(NativeHelperText.messages.keys)),
              "every helper message is listed for translation: \(helperMessages.subtracting(NativeHelperText.messages.keys))")
        check(NativeChargeBackendError.rejected("bilinmeyen ileti").errorDescription == "bilinmeyen ileti",
              "unknown helper text passes through unchanged")

        print("Native charge backend: \(count) assertions passed; fake process only.")
    }
}
