import Foundation

@main enum ChargePolicyPresentationTests {
    static func main() {
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); assertions += 1
        }
        check(ChargePolicyState.idle.title == "Şarj denetimi hazır", "idle title")
        check(ChargePolicyState.maintainingLimit(85).title == "Limit korunuyor: %85", "limit title")
        check(ChargePolicyState.topUpStarting.title == "Top Up başlatılıyor", "starting title")
        check(ChargePolicyState.topUpCharging(73).title == "Top Up: %73 → %100", "charging title")
        check(ChargePolicyState.topUpCharging(nil).title == "Top Up: %0 → %100", "missing percentage title")
        check(ChargePolicyState.topUpRestoring(80).title == "Önceki limite dönülüyor: %80", "restore title")
        let conflict = ChargePolicyState.pausedByConflict(expected: 80, observed: 90)
        check(conflict.title == "macOS limiti dışarıdan %90 yapıldı", "conflict title")
        let recovery = ChargePolicyState.recoveryRequired("ambiguous")
        check(recovery.title == "Kontrol gerekli; yeni işlem durduruldu", "recovery title")
        check(ChargePolicyState.topUpCharging(99).menubarText == "Top Up %99", "menu Top Up status")
        print("Charge policy presentation: \(assertions) assertions passed.")
    }
}
