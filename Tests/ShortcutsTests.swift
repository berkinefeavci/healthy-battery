import Foundation

@main enum ShortcutsTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            assertions += 1
        }
        func expects(_ expected: ChargeMateShortcutError, _ label: String,
                     _ operation: () throws -> Void) {
            do {
                try operation()
                preconditionFailure(label)
            } catch let error as ChargeMateShortcutError {
                check(error == expected, label)
            } catch {
                preconditionFailure("\(label): unexpected \(error)")
            }
        }

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let fresh = ChargeMateShortcutSnapshot(
            sampledAt: now.addingTimeInterval(-2),
            macOSPercentage: 83,
            hardwarePercentage: 81,
            temperatureC: 35.5,
            committedLimit: 85,
            nativeManualLimit: 90,
            nativeCurrentLimit: 95,
            state: .charging
        )
        let reader = ChargeMateShortcutReader(snapshot: fresh, now: now)
        check(try reader.percentage(.macOS) == 83, "macOS percentage stays numeric")
        check(try reader.percentage(.hardware) == 81, "hardware percentage is independent")
        check(try reader.temperatureCelsius() == 35.5, "temperature stays numeric Celsius")
        check(try reader.limit(.committed) == 85, "committed limit is explicit")
        check(try reader.limit(.nativeManual) == 90, "native manual limit is explicit")
        check(try reader.limit(.nativeCurrent) == 95, "native current limit is explicit")
        check(try reader.state() == .charging, "state uses stable external enum")

        var missingHardware = fresh
        missingHardware.hardwarePercentage = nil
        expects(.measurementUnavailable("Donanım pil yüzdesi"), "missing hardware is an error, not zero") {
            _ = try ChargeMateShortcutReader(snapshot: missingHardware, now: now).percentage(.hardware)
        }
        var missingTemperature = fresh
        missingTemperature.temperatureC = nil
        expects(.measurementUnavailable("Batarya sıcaklığı"), "missing temperature is an error") {
            _ = try ChargeMateShortcutReader(snapshot: missingTemperature, now: now).temperatureCelsius()
        }
        var stale = fresh
        stale.sampledAt = now.addingTimeInterval(-5.1)
        expects(.staleMeasurement, "older than five seconds is rejected") {
            _ = try ChargeMateShortcutReader(snapshot: stale, now: now).percentage(.macOS)
        }
        var future = fresh
        future.sampledAt = now.addingTimeInterval(0.1)
        expects(.staleMeasurement, "future timestamp is rejected") {
            _ = try ChargeMateShortcutReader(snapshot: future, now: now).percentage(.macOS)
        }

        check(ChargeMateShortcutState.resolve(available: false, controlState: "charging",
                                              policyState: "idle", isCharging: true,
                                              externalConnected: true) == .unavailable,
              "unavailable telemetry wins")
        check(ChargeMateShortcutState.resolve(available: true, controlState: "topUp",
                                              policyState: "topUpCharging", isCharging: true,
                                              externalConnected: true) == .topUp,
              "Top Up state stays stable")
        check(ChargeMateShortcutState.resolve(available: true, controlState: "heatProtect",
                                              policyState: "idle", isCharging: false,
                                              externalConnected: true) == .heatProtect,
              "heat state stays stable")
        check(ChargeMateShortcutState.resolve(available: true, controlState: "sailing",
                                              policyState: "idle", isCharging: false,
                                              externalConnected: true) == .sailing,
              "sailing state stays stable")
        for (key, expected) in [("calibrating", ChargeMateShortcutState.calibration), ("discharging", .discharging),
                                ("adapterCut", .discharging), ("heatPaused", .heatProtect), ("sailing", .sailing)] {
            check(ChargeMateShortcutState.resolve(available: true, controlState: "pausedAtLimit", advancedState: key,
                                                  policyState: "idle", isCharging: false,
                                                  externalConnected: false) == expected,
                  "adapter-cut engine state \(key) wins over the native state")
        }
        check(ChargeMateShortcutState.resolve(available: true, controlState: "idle", advancedState: "calibrating",
                                              policyState: "recoveryRequired", isCharging: false,
                                              externalConnected: true) == .error,
              "recovery still wins over the engine state")
        check(ChargeMateShortcutState.resolve(available: true, controlState: "idle",
                                              policyState: "recoveryRequired", isCharging: false,
                                              externalConnected: true) == .error,
              "recovery is an explicit error state")
        check(ChargeMateShortcutState.resolve(available: true, controlState: "idle",
                                              policyState: "idle", isCharging: false,
                                              externalConnected: false) == .discharging,
              "battery operation resolves to discharging")

        // The "actions ready" count follows what can really run: reads always, controls only with their prerequisite.
        check(ChargeMateShortcutReadiness.total == 10, "ten shortcut actions in total")
        check(ChargeMateShortcutReadiness.ready(nativeLimitsAvailable: true, adapterCutVerified: true, powerModeHelperInstalled: true,
                                                magSafeHelperInstalled: true) == 10, "everything ready")
        check(ChargeMateShortcutReadiness.ready(nativeLimitsAvailable: true, powerModeHelperInstalled: true,
                                                magSafeHelperInstalled: true) == 8, "no verified adapter cut costs discharge and calibration")
        check(ChargeMateShortcutReadiness.ready(nativeLimitsAvailable: false, powerModeHelperInstalled: false,
                                                magSafeHelperInstalled: false) == 4, "only reads without prerequisites")
        check(ChargeMateShortcutReadiness.ready(nativeLimitsAvailable: true, powerModeHelperInstalled: false,
                                                magSafeHelperInstalled: true) == 7, "missing power-mode helper costs one action")

        print("Shortcuts contract: \(assertions) assertions passed; writer fake only.")
    }
}
