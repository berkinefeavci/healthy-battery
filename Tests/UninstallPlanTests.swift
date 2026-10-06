import Foundation

@main enum UninstallPlanTests {
    static func main() {
        let appData = "/Users/tester/Library/Application Support/Cellkeep"

        // Default options: reset ON, data removal OFF.
        let defaultSteps = UninstallPlan.build(options: .default, applicationSupportDirectory: appData)
        precondition(UninstallPlan.Options.default.resetNativeChargeLimit)
        precondition(!UninstallPlan.Options.default.removeApplicationSupportData)
        precondition(defaultSteps.contains(.resetNativeChargeLimitTo100), "default resets native limit")
        precondition(!defaultSteps.contains(.removeApplicationSupportData(path: appData)), "default keeps app data")
        precondition(defaultSteps.contains(.unregisterLoginItem))

        // Both current and legacy "ChargeMate" helpers are always in the plan, regardless of options.
        let helperSteps = defaultSteps.compactMap { step -> UninstallPlan.HelperTarget? in
            guard case .bootOutAndRemoveHelper(let target) = step else { return nil }
            return target
        }
        precondition(helperSteps.count == 5, "3 current + 2 legacy helper targets")
        precondition(helperSteps.contains { $0.daemonLabel == "io.github.berkinefeavci.cellkeep.led" })
        precondition(helperSteps.contains { $0.daemonLabel == "io.github.berkinefeavci.cellkeep.powermode" })
        precondition(helperSteps.contains { $0.daemonLabel == "io.github.berkinefeavci.cellkeep.chargeinhibit" })
        precondition(helperSteps.contains { $0.daemonLabel == "local.chargemate.led" })
        precondition(helperSteps.contains { $0.daemonLabel == "local.chargemate.powermode" })
        precondition(helperSteps.contains { $0.binaryPath == "/Library/PrivilegedHelperTools/com.chargemate.ledctl" })
        precondition(helperSteps.contains { $0.binaryPath == "/Library/PrivilegedHelperTools/com.chargemate.powermode" })

        // Both checkboxes off: neither optional step appears.
        let minimalSteps = UninstallPlan.build(
            options: .init(resetNativeChargeLimit: false, removeApplicationSupportData: false),
            applicationSupportDirectory: appData)
        precondition(!minimalSteps.contains(.resetNativeChargeLimitTo100))
        precondition(!minimalSteps.contains(.removeApplicationSupportData(path: appData)))

        // Both checkboxes on: both optional steps appear, with the right path.
        let fullSteps = UninstallPlan.build(
            options: .init(resetNativeChargeLimit: true, removeApplicationSupportData: true),
            applicationSupportDirectory: appData)
        precondition(fullSteps.contains(.resetNativeChargeLimitTo100))
        precondition(fullSteps.contains(.removeApplicationSupportData(path: appData)))

        // The admin shell command bundles every helper removal into one command, and is nil
        // when the plan has no helper-removal steps (nothing to execute with elevated rights).
        let command = UninstallPlan.adminShellCommand(for: defaultSteps)
        precondition(command != nil)
        precondition(command!.contains("launchctl bootout system/io.github.berkinefeavci.cellkeep.led"))
        precondition(command!.contains("launchctl bootout system/io.github.berkinefeavci.cellkeep.powermode"))
        precondition(command!.contains("launchctl bootout system/io.github.berkinefeavci.cellkeep.chargeinhibit"))
        precondition(command!.contains("launchctl bootout system/local.chargemate.led"))
        precondition(command!.contains("launchctl bootout system/local.chargemate.powermode"))
        precondition(command!.contains("rm -f '/Library/PrivilegedHelperTools/com.chargemate.ledctl'"))
        precondition(command!.contains(" && "), "steps are chained, not run independently")
        precondition(UninstallPlan.adminShellCommand(for: [.unregisterLoginItem]) == nil,
                     "no helper steps means no admin command is needed")

        print("Uninstall plan: default options, helper targets and admin command assertions passed; nothing executed.")
    }
}
