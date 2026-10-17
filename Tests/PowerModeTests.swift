import Foundation

@main enum PowerModeTests {
    static func main() {
        precondition(SystemPowerMode.parse(pmset: "AC Power:\n powermode            0\n") == .automatic)
        precondition(SystemPowerMode.parse(pmset: "Battery Power:\n powermode 1\n") == .lowPower)
        precondition(SystemPowerMode.parse(pmset: "powermode 2\n") == .turbo)
        precondition(SystemPowerMode.parse(pmset: "powermode 9\n") == nil)
        precondition(SystemPowerMode.lowPower.command == "/usr/bin/pmset -a powermode 1")
        let profiles = SystemPowerModeProfiles.parse(pmset: """
        Battery Power:
         powermode 1
        AC Power:
         powermode 2
        """)
        precondition(profiles == .init(battery: .lowPower, adapter: .turbo))
        precondition(profiles?.active(externalPower: false) == .lowPower)
        precondition(profiles?.active(externalPower: true) == .turbo)
        precondition(SystemPowerModeProfiles.parse(pmset: "Battery Power:\n powermode 1\n") == nil)
        precondition(SystemPowerSource.battery.arguments(for: .lowPower) == ["-b", "powermode", "1"])
        precondition(SystemPowerSource.adapter.arguments(for: .turbo) == ["-c", "powermode", "2"])
        precondition(SystemPowerSource.all.arguments(for: .automatic) == ["-a", "powermode", "0"])
        precondition(SystemPowerSource.battery.requestCode == "B")
        precondition(SystemPowerSource.adapter.requestCode == "C")
        precondition(SystemPowerSource.all.requestCode == "A")
        precondition(!SystemPowerModeService.isCompatibleHelperVersion(nil))
        precondition(!SystemPowerModeService.isCompatibleHelperVersion(2)) // 2 still accepted any process of the user
        precondition(SystemPowerModeService.isCompatibleHelperVersion(3))
        precondition(SystemPowerModeService.parseCapabilities("") == [.automatic])
        precondition(SystemPowerModeService.parseCapabilities("lowpowermode 1\n") == [.automatic, .lowPower])
        precondition(SystemPowerModeService.parseCapabilities(" highpowermode 1\nlowpowermode 1\n") == [.automatic, .lowPower, .turbo])
        precondition(SystemPowerModeService.parseCapabilities("mysterymode 1\n") == [.automatic])
        print("Power mode: source profiles, parse and command assertions passed; no system write.")
    }
}
