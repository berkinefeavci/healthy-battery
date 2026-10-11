import Foundation
import CoreGraphics

@main struct ChartDataCheck {
    static func main() {
        precondition(ChartRange.defaultHours == 1 && ChartRange.options == [1, 6, 24])
        // The picker's choice applies at rest, for every chart but health (always the full 24 h).
        for selected in ChartRange.options {
            precondition(ChartRange.idleHours(selectedHours: selected, isHealth: false) == selected)
            precondition(ChartRange.idleHours(selectedHours: selected, isHealth: true) == 24)
            let idle = ChartRange.idleHours(selectedHours: selected, isHealth: false)
            // Hovering reveals axes and labels but never moves the range.
            precondition(ChartRange.displayHours(selectedHours: selected, hovering: false, idleHours: idle) == selected)
            precondition(ChartRange.displayHours(selectedHours: selected, hovering: true, idleHours: idle) == selected)
            for progress in [0.0, 0.5, 1.0] {
                precondition(ChartRange.animatedHours(selectedHours: selected, progress: progress, idleHours: idle) == Double(selected))
            }
        }
        precondition(ChartRange.idleHours(selectedHours: 6, isHealth: true) == 24)
        precondition(ChartRange.animatedHours(selectedHours: 1, progress: 0, idleHours: 24) == 24)
        precondition(ChartRange.animatedHours(selectedHours: 6, progress: 1, idleHours: 24) == 24)
        // Stored values that are not an option (damaged or older preferences) never produce an empty window.
        for bad in [0, -3, 12, 48, Int.max] {
            precondition(ChartRange.normalized(bad) == 1)
            precondition(ChartRange.idleHours(selectedHours: bad, isHealth: false) == 1)
        }
        precondition(ChartPresentation.detailOpacity(-1) == 0)
        precondition(ChartPresentation.detailOpacity(0) == 0)
        precondition(ChartPresentation.detailOpacity(0.5) == 0.5)
        precondition(ChartPresentation.detailOpacity(2) == 1)
        precondition(ChartPresentation.axisLabel(99, domain: 98.9...100.1) == "99.0")
        precondition(ChartPresentation.axisLabel(100, domain: 0...100) == "100")
        let now = Date(timeIntervalSince1970: 1_789_387_200)
        let samples = [ChartSample(date: now.addingTimeInterval(-60), value: 70),
                       ChartSample(date: now.addingTimeInterval(-30), value: 71),
                       ChartSample(date: now, value: 72)]
        let data = ChartData(samples: samples, now: now, hours: 1, percentage: true)
        precondition(data.segments[0].first?.date == data.xDomain.lowerBound)
        precondition(data.segments[0].last?.date == data.xDomain.upperBound)
        precondition(data.nearest(to: now.addingTimeInterval(-46))?.value == 70)
        precondition(data.nearest(to: now.addingTimeInterval(-45))?.value == 70)
        precondition(data.nearest(to: now.addingTimeInterval(-44))?.value == 71)
        precondition(data.nearest(to: now.addingTimeInterval(-120)) == nil)
        let gap = ChartData(samples: [samples[0], ChartSample(date: samples[1].date, value: nil), samples[2]], now: now, hours: 1)
        precondition(gap.segments.count == 1 && gap.segments[0].count == 3)
        let longGap = ChartData(samples: [ChartSample(date: now.addingTimeInterval(-120), value: 1), samples[2]], now: now, hours: 1)
        precondition(longGap.segments.count == 1 && longGap.nearest(to: now.addingTimeInterval(-60))?.value == 1)
        let health = ChartData(samples: [ChartSample(date: now.addingTimeInterval(-60), value: 99),
                                         ChartSample(date: now, value: 100)], now: now, hours: 1, health: true)
        precondition(health.yDomain == 95...100)
        let noisyHealth = ChartData(samples: [
            ChartSample(date: now.addingTimeInterval(-7_100), value: 99),
            ChartSample(date: now.addingTimeInterval(-7_000), value: 101),
            ChartSample(date: now.addingTimeInterval(-6_900), value: 99.5),
            ChartSample(date: now.addingTimeInterval(-3_500), value: 100),
            ChartSample(date: now.addingTimeInterval(-3_400), value: 99.8),
            ChartSample(date: now.addingTimeInterval(-3_300), value: 99.9),
            ChartSample(date: now, value: 99.5)
        ], now: now, hours: 24, health: true)
        precondition(noisyHealth.samples.map(\.value) == [99.5, 99.9, 99.5])
        precondition(noisyHealth.yDomain == 95...100)
        let dip = ChartData(samples: [ChartSample(date: now.addingTimeInterval(-60), value: 97.4),
                                      ChartSample(date: now, value: 101.2)], now: now, hours: 1, health: true)
        precondition(dip.samples.compactMap(\.value).allSatisfy { $0 <= 100 } && dip.yDomain == 95...100)
        let worn = ChartData(samples: [ChartSample(date: now, value: 92.6)], now: now, hours: 1, health: true)
        precondition(worn.yDomain == 92...100)
        let healthGap = ChartData(samples: [ChartSample(date: now.addingTimeInterval(-600), value: 99),
                                            ChartSample(date: now, value: 100)], now: now, hours: 1, health: true)
        precondition(healthGap.samples.count == 2)
        precondition(healthGap.segments.count == 1 && healthGap.segments[0].count == 3)
        precondition(healthGap.segments[0][2].date == now && healthGap.segments[0][2].value == 100)
        let cold = ChartData(samples: [ChartSample(date: now, value: -3)], now: now, hours: 1)
        precondition(cold.yDomain.lowerBound < -3)
        let plot = ChartData.plot(in: CGSize(width: 340, height: 118))
        precondition(data.date(at: CGPoint(x: 5, y: 5), plot: plot) == nil)
        precondition(ChartData.labelX(-100, plot: plot) - 53 >= plot.minX)
        precondition(ChartData.labelX(1000, plot: plot) + 53 <= plot.maxX)
        let idlePlot = ChartData.plot(in: CGSize(width: 340, height: 118), detailProgress: 0)
        precondition(idlePlot == CGRect(x: 0, y: 0, width: 340, height: 118))
        let halfPlot = ChartData.plot(in: CGSize(width: 340, height: 118), detailProgress: 0.5)
        precondition(halfPlot == CGRect(x: 17, y: 4, width: 319, height: 103))
        precondition(ChartData.plot(in: CGSize(width: 340, height: 118), detailProgress: 1) == plot)
        let empty = ChartData(samples: [ChartSample(date: now, value: .nan)], now: now, hours: 1)
        precondition(empty.samples.isEmpty)
        // A render snapshot stays unchanged when the next measurement arrives.
        let extended = ChartData(samples: samples + [ChartSample(date: now.addingTimeInterval(30), value: 73)], now: now.addingTimeInterval(30), hours: 1)
        precondition(extended.nearest(to: samples[1].date) == samples[1] && data.samples.count == 3)
        print("PASS: chart selection ties/gaps/axes/empty/single/health/negative/immutable snapshots")
    }
}
