import Foundation
import IOKit
import PowerUIBridge

@main
struct ReadOnlyCheck {
    static func main() throws {
        print("READ-ONLY diagnostic; effective uid=\(geteuid()); only SMC commands 9 and 5")
        func value(_ type: String, _ bytes: [UInt8]) -> Double? {
            SMCReader.Value(key: "TEST", type: type, bytes: bytes).number
        }
        precondition(value("sp78", [0x23, 0x80]) == 35.5)
        precondition(value("sp78", [0xfe, 0x80]) == -1.5)
        precondition(value("flt ", [0, 0, 0x0e, 0x42]) == 35.5)
        precondition(value("flt ", [0, 0, 0xc0, 0x7f]) == nil)
        precondition(value("flt ", [0, 0]) == nil)
        precondition(value("ui8 ", [0]) == 0)
        precondition(SMCReader.Value(key: "#KEY", type: "ui32", bytes: [0, 0, 8, 0x28]).number == 2088)
        let cellVoltage = SMCReader.Value(key: "BC1V", type: "ui16", bytes: [0xc9, 0x0f])
        precondition(cellVoltage.number == nil)
        precondition(cellVoltage.unsignedInteger(littleEndian: true) == 4041)
        do { _ = try SMCReader.shared.read("TOO-LONG"); preconditionFailure("Invalid key accepted") }
        catch SMCReader.ReadError.invalidKey { }
        print("PASS: signed sp78, little-endian flt, zero ui8, malformed/NaN data, invalid key")

        let componentPowers = SMCReader.componentPowers { key in
            ["PSTR": 12.0, "PZC0": 3.5, "PDBR": 1.2][key]
        }
        precondition(componentPowers.system == .init(key: "PSTR", watts: 12))
        precondition(componentPowers.processor == .init(key: "PZC0", watts: 3.5))
        precondition(componentPowers.display == .init(key: "PDBR", watts: 1.2))
        let fallbacks = SMCReader.componentPowers { key in
            ["PCPR": 2.5, "PBwo": 0.8, "PSTR": .nan][key]
        }
        precondition(fallbacks.system == nil && fallbacks.processor?.key == "PCPR" && fallbacks.display?.key == "PBwo")
        print("PASS: bounded SMC system, processor and display power selection with fallbacks")

        var s = BatterySnapshot()
        BatteryMonitor.applyRegistry([
            "CurrentCapacity": 80,
            "Voltage": 12000,
            "InstantAmperage": NSNumber(value: UInt64.max - 999),
            "BatteryData": ["FullChargeCapacity": 4800, "RemainingCapacity": 3600, "DesignCapacity": 6000, "Temperature": 3550],
            "PowerTelemetryData": ["SystemPowerIn": 25000, "SystemLoad": 24000],
            "AdapterDetails": ["Watts": 60]
        ], to: &s)
        precondition(s.percentage == 80 && s.hardwarePercentage == 75)
        precondition(s.healthPercent == 80 && s.temperatureC == 35.5)
        precondition(s.amperage == -1000 && s.wattage == -12)
        precondition(s.systemWatts == 24 && s.adapterRatedWatts == 60)
        print("PASS: nested BatteryData, hardware SOC, capacity, temperature, signed current, telemetry, read-only gate")

        let monitorRoot = FileManager.default.temporaryDirectory.appendingPathComponent("chargemate-readonly-\(UUID())")
        try FileManager.default.createDirectory(at: monitorRoot, withIntermediateDirectories: true)
        let monitorSuite = "local.chargemate.readonly.\(UUID())"
        let monitorDefaults = UserDefaults(suiteName: monitorSuite)!
        defer {
            monitorDefaults.removePersistentDomain(forName: monitorSuite)
            try? FileManager.default.removeItem(at: monitorRoot)
        }
        var setterCalls = 0
        let stateJSON = Data(#"{"schemaVersion":1,"ok":true,"state":{"manualLimit":80,"availableLimits":[80,85,90,95,100],"enabledRaw":1,"currentLimit":80}}"#.utf8)
        let backend = NativeChargeBackend(version: "read-only-check", timeout: 0.1) { arguments, _ in
            if arguments.first == "set" { setterCalls += 1 }
            return NativeChargeProcessResult(status: 0, output: stateJSON)
        }
        let coordinator = ChargeControlCoordinator(journal: monitorRoot.appendingPathComponent("control.json"),
                                                    backend: backend, rival: { false })
        let policyController = ChargePolicyController(
            backend: backend, coordinator: coordinator,
            policyStore: ChargePolicyStore(url: monitorRoot.appendingPathComponent("charge-policy.json")),
            sessionStore: TopUpSessionStore(url: monitorRoot.appendingPathComponent("charge-session.json")),
            rival: { false })
        var startupSnapshot = BatterySnapshot()
        startupSnapshot.available = true
        startupSnapshot.externalConnected = true
        startupSnapshot.percentage = 70
        startupSnapshot.hardwarePercentage = 70
        startupSnapshot.sampledAt = Date()
        let monitor = BatteryMonitor(defaults: monitorDefaults, policyController: policyController,
                                     historyURL: monitorRoot.appendingPathComponent("history.json"),
                                     batteryReader: { startupSnapshot }, nativeReader: { try? backend.readState() },
                                     controllerRunning: { false }, energyReader: { .success([]) })
        monitor.start()
        let startupDeadline = Date().addingTimeInterval(2)
        while !monitor.snapshot.available, Date() < startupDeadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        monitor.stop()
        precondition(monitor.snapshot.available && setterCalls == 0)
        print("PASS: construction, startup reconciliation, refresh and shutdown issue zero native writes")

        func flow(external: Bool, charging: Bool, batteryWatts: Double,
                  adapterWatts: Double? = 25, systemWatts: Double? = 20,
                  processorWatts: Double? = 8, displayWatts: Double? = 2) -> PowerFlowPresentation {
            var snapshot = BatterySnapshot()
            snapshot.available = true
            snapshot.externalConnected = external
            snapshot.isCharging = charging
            snapshot.wattage = batteryWatts
            snapshot.batteryPowerAvailable = true
            snapshot.adapterWatts = adapterWatts
            snapshot.systemWatts = systemWatts
            snapshot.processorWatts = processorWatts
            snapshot.displayWatts = displayWatts
            return snapshot.powerFlow
        }
        precondition(BatterySnapshot().powerFlow.mode == .unavailable)
        let chargingFlow = flow(external: true, charging: true, batteryWatts: 5)
        precondition(chargingFlow.mode == .charging && chargingFlow.edges.map(\.id) == ["adapter-mac", "adapter-battery", "mac-processor", "mac-display", "mac-other"])
        precondition(chargingFlow.edges.map(\.watts) == [20, 5, 8, 2, 10])
        precondition(chargingFlow.edges.allSatisfy { !$0.id.contains("junction") })
        let derivedAdapterFlow = flow(external: true, charging: true, batteryWatts: 5, adapterWatts: nil)
        precondition(derivedAdapterFlow.edges.filter { $0.source == .adapter }.compactMap(\.watts).reduce(0, +) == 25)
        precondition(PowerFlowLayout.column(for: .mac, mode: .charging) == .device)
        precondition(PowerFlowLayout.column(for: .adapter, mode: .charging) == .source)
        precondition(PowerFlowLayout.column(for: .battery, mode: .charging) == .device)
        precondition(PowerFlowLayout.column(for: .battery, mode: .adapterOnly) == .destination)
        precondition(PowerFlowLayout.column(for: .battery, mode: .batteryOnly) == .source)
        precondition(PowerFlowLayout.column(for: .battery, mode: .batteryAssist) == .source)
        precondition(PowerFlowLayout.column(for: .display, mode: .charging) == .destination)
        precondition(PowerFlowLayout.column(for: .processor, mode: .charging) == .destination)
        precondition(PowerFlowLayout.column(for: .other, mode: .charging) == .destination)
        precondition(PowerFlowLayout.verticalRank(for: .battery, mode: .charging) == 0)
        precondition(PowerFlowLayout.verticalRank(for: .mac, mode: .charging) == 1)
        precondition(PowerFlowLayout.verticalRank(for: .processor, mode: .charging) == 1)
        precondition(PowerFlowLayout.verticalRank(for: .display, mode: .charging) == 2)
        precondition(PowerFlowLayout.verticalRank(for: .other, mode: .charging) == 3)
        precondition(PowerFlowLayout.batteryTone(for: 0) == .red)
        precondition(PowerFlowLayout.batteryTone(for: 20) == .red)
        precondition(PowerFlowLayout.batteryTone(for: 21) == .yellow)
        precondition(PowerFlowLayout.batteryTone(for: 50) == .yellow)
        precondition(PowerFlowLayout.batteryTone(for: 51) == .green)
        precondition(PowerFlowLayout.batteryTone(for: 100) == .green)
        precondition(PowerFlowLayout.batteryTone(for: nil) == .green)
        let adapterFlow = flow(external: true, charging: false, batteryWatts: 0.2)
        precondition(adapterFlow.mode == .adapterOnly && adapterFlow.edges.first?.id == "adapter-mac")
        precondition(!adapterFlow.edges.contains { $0.target == .battery })
        let batteryFlow = flow(external: false, charging: false, batteryWatts: -12)
        precondition(batteryFlow.mode == .batteryOnly && batteryFlow.edges.first?.id == "battery-mac" && batteryFlow.edges.first?.watts == 20)
        let assistFlow = flow(external: true, charging: false, batteryWatts: -3)
        precondition(assistFlow.mode == .batteryAssist && assistFlow.edges.prefix(2).map(\.id) == ["adapter-mac", "battery-mac"])
        precondition(assistFlow.edges.prefix(2).map(\.watts) == [17, 3])
        let missingBatteryFlow = flow(external: false, charging: false, batteryWatts: 0, systemWatts: 20)
        precondition(missingBatteryFlow.mode == .batteryOnly && missingBatteryFlow.edges.first?.active == true)
        precondition(PowerFlowPresentation.lineWidth(for: 0.49) == 1.5)
        precondition(PowerFlowPresentation.lineWidth(for: 0.50) == 1.5)
        precondition(PowerFlowPresentation.lineWidth(for: 0.51) > 1.5)
        precondition(flow(external: true, charging: false, batteryWatts: 5).mode == .unavailable)
        precondition(flow(external: true, charging: true, batteryWatts: -5).edges.isEmpty)
        var stale = BatterySnapshot(); stale.available = true; stale.sampledAt = Date().addingTimeInterval(-11)
        precondition(stale.powerFlow.mode == .unavailable && stale.powerFlow.edges.allSatisfy { $0.watts == nil })
        precondition(PowerFlowPresentation.lineWidth(for: 60) == 18)
        precondition(PowerFlowPresentation.lineWidth(for: 120) == 18)
        print("PASS: unavailable, charging, adapter, battery, assist, dead-zone and missing-measurement flow states")

        let energyOutput = """
        PID    COMMAND          %CPU POWER
        101    Video Editor     18.4 18.4
        202    backgroundd       2.1  2.1
        """
        let energyApps = BatteryMonitor.parseEnergyApps(energyOutput, applicationNames: [101: "Video Editor"], excludingPID: 202)
        precondition(energyApps == [EnergyApp(pid: 101, name: "Video Editor", power: 18.4, cpu: 18.4, isApplication: true)])
        precondition(energyApps.first?.iconPath == nil)

        // Regular apps get their own bundle path; helper rows get the resolved owner's bundle path.
        let iconOutput = """
        PID    COMMAND          %CPU POWER
        101    Video Editor     18.4 18.4
        303    Browser Helper    3.2  4.1
        """
        let appsWithIcons = BatteryMonitor.parseEnergyApps(iconOutput,
            applicationNames: [101: "Video Editor"],
            resolvedNames: [303: "Dia · bir web sayfası çalışıyor"],
            applicationIconPaths: [101: "/Applications/Video Editor.app"],
            resolvedIconPaths: [303: "/Applications/Dia.app"])
        precondition(appsWithIcons.first { $0.pid == 101 }?.iconPath == "/Applications/Video Editor.app")
        precondition(appsWithIcons.first { $0.pid == 303 }?.iconPath == "/Applications/Dia.app")
        print("PASS: macOS top power activity parsing and foreground-app classification")

        let historyFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: historyFile) }
        let now = Date()
        let points = [-90000.0, -60.0, 60.0].map { offset in
            BatteryHistoryPoint(date: now.addingTimeInterval(offset), percentage: 80, wattage: 0, temperatureC: nil, systemWatts: 12, healthPercent: 78, cycleCount: 349)
        }
        try JSONEncoder().encode(points).write(to: historyFile)
        let retained = BatteryMonitor.loadHistory(from: historyFile, now: now)
        precondition(retained.count == 1 && retained[0].date == now.addingTimeInterval(-60) && retained[0].temperatureC == nil)
        print("PASS: history survives serialization, absent sensors, old/future sample filtering")
        let migrated = HistoryArchive(schemaVersion: 2, measurements: retained, limitEvents: [LimitEvent(date: now.addingTimeInterval(-30), value: 80), LimitEvent(date: now, value: 90)])
        try migrated.write(historyFile)
        let restored = try HistoryArchive.read(historyFile, now: now)
        precondition(restored.measurements.count == 1 && restored.measurements[0].batteryCurrentMA == nil && restored.limitEvents == migrated.limitEvents)
        let backup = historyFile.appendingPathExtension("v1.backup")
        precondition(FileManager.default.fileExists(atPath: backup.path))
        defer {
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.removeItem(at: historyFile.appendingPathExtension("before-measurement-quality.backup"))
        }
        let broken = Data("invalid history".utf8)
        try broken.write(to: historyFile)
        do { try migrated.write(historyFile); preconditionFailure("Corrupt history overwritten") } catch { }
        let unchanged = try Data(contentsOf: historyFile)
        precondition(unchanged == broken)
        print("PASS: history v1 backup/migration, unknown old current, limit-event round-trip, corrupt-file preservation")
        if CommandLine.arguments.contains("--live") {
            let energy = BatteryMonitor.readEnergyAppsResult()
            guard case .success(let apps) = energy else { fatalError("Live energy sample failed: \(energy)") }
            print("PASS: live top POWER sample; \(apps.count) processes; no watt attribution")
            let native = CMPowerLimit.readState()
            print("LIVE PowerUI read: \(native)")
            let live = BatteryMonitor.readBattery()
            precondition(live.available && live.temperatureSource.hasPrefix("SMC") && live.temperatureC?.isFinite == true)
            precondition(live.nominalChargeCapacity.map { $0 > 0 } == true && live.designCapacity.map { $0 > 0 } == true)
            for field in BatteryField.allCases {
                let reading = live.reading(field)
                print("LIVE \(field.rawValue)=\(reading.text()) quality=\(reading.metadata.quality.rawValue) source=\(reading.metadata.source ?? "missing")")
            }
            let fallback = BatteryMonitor.readBattery(useSMC: false)
            guard let fallbackTemperature = fallback.temperatureC, let liveTemperature = live.temperatureC else {
                preconditionFailure("Live or fallback temperature missing")
            }
            precondition(fallbackTemperature.isFinite && fallback.temperatureSource.hasPrefix("IOKit"))
            precondition(abs(fallbackTemperature - liveTemperature) < 5)
            print("PASS: forced IOKit fallback=\(fallbackTemperature) source=\(fallback.temperatureSource)")
        }

        guard CommandLine.arguments.contains("--live") else { return }
        let reader = SMCReader.shared
        let ledSnapshot = BatteryMonitor.readBattery(useSMC: false)
        let led = MagSafeLEDCapability.liveProbe(externalConnected: ledSnapshot.externalConnected, reader: reader)
        print("MagSafe LED read-only probe: \(led.probeState)")
        if let baseline = try? reader.read("ACLC") {
            print("ACLC read-only baseline: type=\(baseline.type) bytes=\(hex(baseline.bytes))")
        }
        guard let temperature = reader.batteryTemperature(), let celsius = temperature.number else {
            fatalError("TB1T read did not yield a valid temperature")
        }
        print("TB1T type=\(temperature.type) bytes=\(hex(temperature.bytes)) celsius=\(celsius)")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let property = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0),
               let number = property.takeRetainedValue() as? NSNumber {
                let registryCelsius = number.doubleValue / 100
                print("IOKit temperature=\(registryCelsius) delta=\(abs(celsius - registryCelsius))")
                precondition(abs(celsius - registryCelsius) < 5, "SMC and IOKit temperatures unexpectedly disagree")
            }
        }
        for key in ["CH0B", "BCLM", "CH0C", "CH0I", "CHTE", "CHWA", "CHLS", "CHLT", "CHIE", "CHNC", "CHSC", "BRSC", "#KEY"] {
            do {
                let result = try reader.read(key)
                print("\(key) type=\(result.type) bytes=\(hex(result.bytes)) number=\(result.number.map(String.init(describing:)) ?? "unparsed")")
            } catch SMCReader.ReadError.keyNotFound(let name) {
                print("\(name) unavailable for this user: SMC 0x84 (not a zero reading)")
            } catch {
                print("\(key) not readable: \(error)")
            }
        }
        print("PASS: live read-only ABI and temperature validation; no supported write requested")
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
