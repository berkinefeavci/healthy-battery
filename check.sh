#!/bin/bash
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  else
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
cd "$(dirname "$0")"
mkdir -p .build/checks
xcrun swiftc -parse-as-library Sources/ChargeMate/ChargeMateShortcuts.swift Tests/ShortcutsTests.swift \
  -o .build/checks/shortcuts-tests
.build/checks/shortcuts-tests
# App Intents may read through the native backend, but every write stays on existing owners.
! grep -Eq 'CMPowerLimit\.apply|NativeChargeBackend.*apply|SystemPowerModeService\.apply\(' \
  Sources/ChargeMate/ChargeMateIntents.swift
! grep -Eq 'SystemPowerModeService\.install|MagSafeLEDHardwareService\.install' \
  Sources/ChargeMate/ChargeMateIntents.swift
grep -Fq 'SystemPowerModeService.applyInstalled' Sources/ChargeMate/ChargeMateIntents.swift
grep -Fq 'BatteryMonitor.shared.applyShortcutLimit' Sources/ChargeMate/ChargeMateIntents.swift
xcrun clang -Wall -Wextra -Werror Tests/MagSafeTimeWindowTests.c -o .build/checks/magsafe-time-tests
xcrun clang -Wall -Wextra -Werror Tests/LEDControllersTests.c -o .build/checks/led-controllers-tests
.build/checks/led-controllers-tests
.build/checks/magsafe-time-tests

# PowerUI writes belong only to the timeout-bounded helper process.
! grep -q 'CMPowerLimit\.apply' Sources/ChargeMate/BatteryMonitor.swift
! grep -q 'CMPowerLimit\.apply' Sources/ChargeMate/ChargeControlCoordinator.swift
test "$(grep -rl 'CMPowerLimit\.apply' Sources | wc -l | tr -d ' ')" = "1"
! grep -Eq 'evaluateActions|performActionWrite|#if SWIFT_PACKAGE' Sources/ChargeMate/BatteryMonitor.swift
# Source-level UI regression guard, not a substitute for a real pointer/keyboard visual test.
# These custom focusable visualizations must not recreate the reported blue frame.
! grep -Eq 'strokeBorder\((focused|keyboardFocused) \? Color\.accentColor' \
  Sources/ChargeMate/Views.swift Sources/ChargeMate/HistoryPlot.swift
grep -Fq '.focusable().focused($focused).quietVisualizationFocus()' Sources/ChargeMate/Views.swift
! grep -Fq 'RoundedRectangle(cornerRadius: 5).strokeBorder(keyboardFocused' Sources/ChargeMate/HistoryPlot.swift
# Power-flow hover must never mutate opacity/state; overlapping route and node
# hit regions previously caused rapid dim/restore flicker.
! grep -Fq '@State private var hovered: FlowFocus?' Sources/ChargeMate/Components.swift
! grep -Fq '.opacity(related ? 1 : 0.45)' Sources/ChargeMate/Components.swift
# Applying a power profile blocks repeated input without entering SwiftUI's
# disabled visual state. Show only actionable errors below the controls.
! grep -Fq '.disabled(battery.applyingPowerMode)' Sources/ChargeMate/PowerModeView.swift
grep -Fq '.allowsHitTesting(!battery.applyingPowerMode)' Sources/ChargeMate/PowerModeView.swift
grep -Fq 'if let message = battery.powerModeMessage' Sources/ChargeMate/PowerModeView.swift
! grep -Eq 'Top Up.*disabled\(true\)|disabled\(true\).*Top Up' Sources/ChargeMate/Views.swift
# Popover quick actions stay explicit: Top Up is shown as Doldur; unsupported
# force-battery control is visible but cannot pretend to work.
grep -Fq '.accessibilityLabel("Deşarj yakında; henüz kullanılamıyor")' Sources/ChargeMate/Views.swift
grep -Fq 'Text("Doldur")' Sources/ChargeMate/Views.swift
grep -Fq '.popoverToolbarButtonStyle(iconOnly: true).disabled(true)' Sources/ChargeMate/Views.swift
grep -Fq 'Text("Sınır: %\(Int(battery.chargeLimit))")' Sources/ChargeMate/Views.swift
! grep -Fq 'slider.horizontal.3' Sources/ChargeMate/Views.swift
! grep -Fq 'Image(systemName: limitEditor ? "chevron.up" : "chevron.down")' Sources/ChargeMate/Views.swift
grep -Fq '.popoverToolbarButtonStyle(active: battery.topUpActive)' Sources/ChargeMate/Views.swift
! grep -Fq 'isOn: .constant(false)' Sources/ChargeMate/ScheduleView.swift
xcrun clang -fobjc-arc -c Sources/PowerUIBridge/PowerUIBridge.m -I Sources/PowerUIBridge/include -o .build/checks/PowerUIBridge.o
printf 'module PowerUIBridge { header "../../Sources/PowerUIBridge/include/PowerUIBridge.h" export * }\n' > .build/checks/module.modulemap

xcrun swiftc Sources/NativeChargeHelper/NativeChargeHelperProtocol.swift Tests/NativeChargeHelperTests.swift \
  -o .build/checks/native-charge-helper-tests
.build/checks/native-charge-helper-tests
xcrun swiftc -I .build/checks Sources/NativeChargeHelper/*.swift .build/checks/PowerUIBridge.o \
  -o .build/checks/native-charge-helper
.build/checks/native-charge-helper --self-test
test "$(grep -rl 'CMPowerLimit\.apply' Sources/NativeChargeHelper | wc -l | tr -d ' ')" = "1"
xcrun swiftc Sources/ChargeMate/NativeChargeBackend.swift Tests/NativeChargeBackendTests.swift \
  -o .build/checks/native-charge-backend-tests
.build/checks/native-charge-backend-tests

# Salt-okunur teşhis paketi (SMC/PowerUI/geçmiş/güç akışı).
xcrun swiftc -I .build/checks \
  Sources/ChargeMate/SMCReader.swift \
  Sources/ChargeMate/MagSafeLED.swift \
  Sources/ChargeMate/NativeChargeBackend.swift \
  Sources/ChargeMate/ChargePolicy.swift \
  Sources/ChargeMate/ChargePolicyController.swift \
  Sources/ChargeMate/ChargeControlCoordinator.swift \
  Sources/ChargeMate/PowerMode.swift Sources/ChargeMate/HelperInstallState.swift \
  Sources/ChargeMate/Schedule.swift \
  Sources/ChargeMate/ConnectedDevice.swift \
  Sources/ChargeMate/EnergyPresentation.swift Sources/ChargeMate/ChargeControllerDetector.swift Sources/ChargeMate/LongTermHistory.swift Sources/ChargeMate/BatteryMonitor.swift \
  Tests/ReadOnlyCheck.swift \
  .build/checks/PowerUIBridge.o -o .build/checks/read-only-check
.build/checks/read-only-check "$@"

# MagSafe policy/storage tests use fake capability only. There is no SMC write command.
xcrun swiftc Sources/ChargeMate/SMCReader.swift Sources/ChargeMate/MagSafeLED.swift \
  Tests/MagSafeLEDTests.swift -o .build/checks/magsafe-led-tests
.build/checks/magsafe-led-tests

xcrun swiftc Sources/ChargeMate/SMCReader.swift Sources/ChargeMate/MagSafeLED.swift Sources/ChargeMate/MagSafeLEDControlCoordinator.swift \
  Tests/MagSafeLEDCoordinatorTests.swift -o .build/checks/magsafe-led-coordinator-tests
.build/checks/magsafe-led-coordinator-tests

# Şarj politikası saf mantık ve geçici dosya testleri; donanım erişimi yok.
xcrun swiftc Sources/ChargeMate/NativeChargeBackend.swift Sources/ChargeMate/ChargeControlCoordinator.swift \
  Sources/ChargeMate/ChargePolicy.swift Tests/ChargePolicyTests.swift -o .build/checks/charge-policy-tests
.build/checks/charge-policy-tests

xcrun swiftc Sources/ChargeMate/NativeChargeBackend.swift Sources/ChargeMate/ChargeControlCoordinator.swift \
  Sources/ChargeMate/ChargePolicy.swift Tests/ChargePolicyPresentationTests.swift \
  -o .build/checks/charge-policy-presentation-tests
.build/checks/charge-policy-presentation-tests

xcrun swiftc Sources/ChargeMate/NativeChargeBackend.swift Sources/ChargeMate/ChargeControlCoordinator.swift \
  Sources/ChargeMate/ChargePolicy.swift Sources/ChargeMate/ChargePolicyController.swift \
  Tests/ChargePolicyControllerTests.swift -o .build/checks/charge-policy-controller-tests
.build/checks/charge-policy-controller-tests

xcrun swiftc -parse-as-library Sources/ChargeMate/ChargeInhibit.swift Sources/ChargeMate/AdvancedChargeEngine.swift \
  Sources/ChargeMate/AdvancedChargeRunner.swift Tests/AdvancedChargeEngineTests.swift -o .build/checks/advanced-charge-engine-tests
.build/checks/advanced-charge-engine-tests

xcrun swiftc Sources/ChargeMate/PowerMode.swift Sources/ChargeMate/HelperInstallState.swift Tests/PowerModeTests.swift -o .build/checks/power-mode-tests
.build/checks/power-mode-tests

xcrun swiftc Sources/ChargeMate/HelperInstallState.swift Tests/HelperInstallStateTests.swift -o .build/checks/helper-install-state-tests
.build/checks/helper-install-state-tests
xcrun swiftc Sources/ChargeMate/UpdateCheck.swift Tests/UpdateCheckTests.swift -o .build/checks/update-check-tests
.build/checks/update-check-tests
xcrun swiftc Sources/ChargeMate/UpdateCheck.swift Sources/ChargeMate/HelperInstallState.swift Sources/ChargeMate/UpdateInstaller.swift Tests/UpdateInstallerTests.swift -o .build/checks/update-installer-tests
.build/checks/update-installer-tests
xcrun swiftc Sources/ChargeMate/ChargeControllerDetector.swift Tests/ChargeControllerDetectorTests.swift -o .build/checks/charge-controller-detector-tests
.build/checks/charge-controller-detector-tests
xcrun swiftc Sources/ChargeMate/LongTermHistory.swift Sources/ChargeMate/HistoryCSV.swift Tests/HistoryCSVTests.swift -o .build/checks/history-csv-tests
.build/checks/history-csv-tests
xcrun swiftc Sources/ChargeMate/LongTermHistory.swift Tests/LongTermHistoryTests.swift -o .build/checks/long-term-history-tests
.build/checks/long-term-history-tests
xcrun swiftc Sources/ChargeMate/GlobalHotKey.swift Tests/GlobalHotKeyTests.swift -o .build/checks/global-hot-key-tests
.build/checks/global-hot-key-tests

xcrun swiftc Sources/ChargeMate/IdentityMigration.swift Tests/IdentityMigrationTests.swift -o .build/checks/identity-migration-tests
.build/checks/identity-migration-tests

xcrun swiftc Sources/ChargeMate/UninstallPlan.swift Tests/UninstallPlanTests.swift -o .build/checks/uninstall-plan-tests
.build/checks/uninstall-plan-tests
xcrun clang -Wall -Wextra -Werror Tools/PowerModeHelper.c -o .build/checks/power-mode-helper-tests
.build/checks/power-mode-helper-tests --self-test
test "$(.build/checks/power-mode-helper-tests --version)" = "2"

xcrun swiftc Sources/ChargeMate/SleepBehavior.swift Tests/SleepBehaviorTests.swift \
  -framework IOKit -o .build/checks/sleep-behavior-tests
.build/checks/sleep-behavior-tests

xcrun swiftc Sources/ChargeMate/NativeChargeBackend.swift Sources/ChargeMate/ChargeControlCoordinator.swift \
  Tests/ChargeControlCoordinatorTests.swift -o .build/checks/coordinator-tests
.build/checks/coordinator-tests

xcrun swiftc -I .build/checks Sources/ChargeMate/SMCReader.swift Sources/ChargeMate/NativeChargeBackend.swift Sources/ChargeMate/ChargePolicy.swift Sources/ChargeMate/ChargePolicyController.swift Sources/ChargeMate/Schedule.swift \
  Sources/ChargeMate/ChargeControlCoordinator.swift Sources/ChargeMate/PowerMode.swift Sources/ChargeMate/HelperInstallState.swift Sources/ChargeMate/ConnectedDevice.swift Sources/ChargeMate/EnergyPresentation.swift Sources/ChargeMate/ChargeControllerDetector.swift Sources/ChargeMate/LongTermHistory.swift Sources/ChargeMate/BatteryMonitor.swift \
  Tests/BatteryMonitorControlTests.swift .build/checks/PowerUIBridge.o -o .build/checks/monitor-control-tests
.build/checks/monitor-control-tests

xcrun swiftc -I .build/checks Sources/ChargeMate/SMCReader.swift Sources/ChargeMate/NativeChargeBackend.swift Sources/ChargeMate/ChargePolicy.swift Sources/ChargeMate/ChargePolicyController.swift Sources/ChargeMate/Schedule.swift \
  Sources/ChargeMate/ChargeControlCoordinator.swift Sources/ChargeMate/PowerMode.swift Sources/ChargeMate/HelperInstallState.swift Sources/ChargeMate/ConnectedDevice.swift Sources/ChargeMate/EnergyPresentation.swift Sources/ChargeMate/ChargeControllerDetector.swift Sources/ChargeMate/LongTermHistory.swift Sources/ChargeMate/BatteryMonitor.swift \
  Tests/MeasurementQualityTests.swift .build/checks/PowerUIBridge.o -o .build/checks/measurement-quality-tests
.build/checks/measurement-quality-tests

xcrun swiftc Sources/ChargeMate/ChartData.swift Tests/ChartDataCheck.swift -o .build/checks/chart-data-check
.build/checks/chart-data-check
xcrun swiftc Sources/ChargeMate/ChargeBarLayout.swift Tests/ChargeBarLayoutCheck.swift -o .build/checks/charge-bar-layout-check
.build/checks/charge-bar-layout-check
xcrun swiftc Sources/ChargeMate/ChartData.swift Sources/ChargeMate/HistoryPlot.swift Tests/ChartHoverCheck.swift \
  -o .build/checks/chart-hover-check
.build/checks/chart-hover-check
xcrun swiftc -parse-as-library Sources/ChargeMate/ConnectedDevice.swift Tests/ConnectedDeviceTests.swift \
  -o .build/checks/connected-device-tests
.build/checks/connected-device-tests
xcrun swiftc -parse-as-library Sources/ChargeMate/EnergyPresentation.swift Tests/EnergyPresentationTests.swift \
  -o .build/checks/energy-presentation-tests
.build/checks/energy-presentation-tests
xcrun swiftc Sources/ChargeMate/PopoverLayout.swift Tests/PopoverLayoutCheck.swift -o .build/checks/popover-layout-check
.build/checks/popover-layout-check

# Giriş öğesi status eşlemesi saf testtir; register/unregister çağrısı yapılmaz.
xcrun swiftc Sources/ChargeMate/StartupPreferences.swift Tests/StartupPreferencesTests.swift \
  -o .build/checks/startup-preferences-tests
.build/checks/startup-preferences-tests

xcrun swiftc Sources/ChargeMate/SettingsPage.swift Tests/SettingsPageTests.swift \
  -o .build/checks/settings-page-tests
.build/checks/settings-page-tests

xcrun swiftc Sources/ChargeMate/SettingsLayout.swift Tests/SettingsLayoutTests.swift \
  -o .build/checks/settings-layout-tests
.build/checks/settings-layout-tests

xcrun swiftc -I .build/checks Sources/ChargeMate/SMCReader.swift Sources/ChargeMate/NativeChargeBackend.swift Sources/ChargeMate/ChargePolicy.swift Sources/ChargeMate/ChargePolicyController.swift Sources/ChargeMate/Schedule.swift \
  Sources/ChargeMate/ChargeControlCoordinator.swift Sources/ChargeMate/PowerMode.swift Sources/ChargeMate/HelperInstallState.swift Sources/ChargeMate/ConnectedDevice.swift Sources/ChargeMate/EnergyPresentation.swift Sources/ChargeMate/ChargeControllerDetector.swift Sources/ChargeMate/LongTermHistory.swift Sources/ChargeMate/BatteryMonitor.swift \
  Sources/ChargeMate/MenubarPreferences.swift Sources/ChargeMate/MenubarPresentation.swift \
  Tests/MenubarTests.swift .build/checks/PowerUIBridge.o -o .build/checks/menubar-tests
.build/checks/menubar-tests "$PWD/.build/ChargeMate.app" "$PWD/.build/checks/menubar-preview.png"

# Yardım/tanılama: geçici defaults ve dosyalar, sahte donanım; NSSavePanel açılmaz.
xcrun swiftc -I .build/checks Sources/ChargeMate/SMCReader.swift Sources/ChargeMate/NativeChargeBackend.swift Sources/ChargeMate/ChargePolicy.swift Sources/ChargeMate/ChargePolicyController.swift Sources/ChargeMate/Schedule.swift \
  Sources/ChargeMate/ChargeControlCoordinator.swift Sources/ChargeMate/PowerMode.swift Sources/ChargeMate/HelperInstallState.swift Sources/ChargeMate/ConnectedDevice.swift Sources/ChargeMate/EnergyPresentation.swift Sources/ChargeMate/ChargeControllerDetector.swift Sources/ChargeMate/LongTermHistory.swift Sources/ChargeMate/BatteryMonitor.swift \
  Sources/ChargeMate/MenubarPreferences.swift Sources/ChargeMate/SupportModels.swift Tests/SupportCenterTests.swift \
  .build/checks/PowerUIBridge.o -o .build/checks/support-center-tests
.build/checks/support-center-tests

xcrun swiftc Sources/ChargeMate/PowerMode.swift Sources/ChargeMate/HelperInstallState.swift Sources/ChargeMate/Schedule.swift Tests/ScheduleTests.swift -o .build/checks/schedule-tests
.build/checks/schedule-tests

xcrun swiftc Sources/ChargeMate/NativeChargeBackend.swift Sources/ChargeMate/ChargeControlCoordinator.swift \
  Sources/ChargeMate/ChargePolicy.swift Sources/ChargeMate/ChargePolicyController.swift Sources/ChargeMate/PowerMode.swift Sources/ChargeMate/HelperInstallState.swift \
  Sources/ChargeMate/Schedule.swift Sources/ChargeMate/ScheduleScheduler.swift \
  Tests/ScheduleSchedulerTests.swift -o .build/checks/schedule-scheduler-tests
.build/checks/schedule-scheduler-tests
