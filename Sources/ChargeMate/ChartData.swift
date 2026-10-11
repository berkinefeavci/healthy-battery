import Foundation
import CoreGraphics

enum ChartRange {
    static let defaultHours = 1
    /// The ranges the picker offers (hours of history shown).
    static let options = [1, 6, 24]

    /// A stored value that is not one of the options (older or damaged preferences) falls back to the default.
    static func normalized(_ hours: Int) -> Int { options.contains(hours) ? hours : defaultHours }

    /// The range a chart shows at rest: the one chosen in the picker. The health chart always shows the whole
    /// 24 hours, because its points are hourly medians and a shorter window would leave one dot.
    static func idleHours(selectedHours: Int, isHealth: Bool) -> Int {
        isHealth ? options.last! : normalized(selectedHours)
    }

    /// Hovering adds the detail layer (axes and labels); it never changes the range, so the range at rest and
    /// under the pointer are the same. `idleHours` already carries the picker's choice.
    static func displayHours(selectedHours: Int, hovering: Bool, idleHours: Int) -> Int {
        hovering ? max(idleHours, normalized(selectedHours)) : idleHours
    }

    static func animatedHours(selectedHours: Int, progress: Double, idleHours: Int) -> Double {
        let target = Double(max(idleHours, normalized(selectedHours)))
        let value = min(1, max(0, progress))
        return Double(idleHours) + (target - Double(idleHours)) * value
    }
}

enum ChartPresentation {
    static func detailOpacity(_ progress: Double) -> Double {
        min(1, max(0, progress))
    }

    static func axisLabel(_ value: Double, domain: ClosedRange<Double>) -> String {
        String(format: domain.upperBound - domain.lowerBound < 10 ? "%.1f" : "%.0f", value)
    }
}

/// Immutable plot input. Rendering never reads BatteryMonitor or preferences.
struct ChartSample: Equatable {
    let date: Date
    let value: Double?
}

struct ChartData: Equatable {
    let samples: [ChartSample]
    let segments: [[ChartSample]]
    let xDomain: ClosedRange<Date>
    let yDomain: ClosedRange<Double>

    init(samples input: [ChartSample], now: Date, hours: Int, percentage: Bool = false, health: Bool = false) {
        self.init(samples: input, now: now, hours: Double(hours), percentage: percentage, health: health)
    }

    init(samples input: [ChartSample], now: Date, hours: Double, percentage: Bool = false, health: Bool = false) {
        let start = now.addingTimeInterval(-hours * 3600)
        let ordered = input.filter { $0.date >= start && $0.date <= now }.sorted { $0.date < $1.date }
        // Missing polls must not punch visual holes into an otherwise valid trend.
        // Connecting the surrounding real measurements is linear interpolation;
        // no synthetic value is persisted or presented as a sensor sample.
        let valid = ordered.filter { $0.value?.isFinite == true }
        // Health is capped at 100 like macOS; this also tames older history saved before the cap.
        samples = health ? Self.hourlyHealthSamples(valid.map { ChartSample(date: $0.date, value: min(100, $0.value!)) }) : valid
        // Use one shared time window for every metric. Missing periods stay empty.
        xDomain = start...now
        segments = samples.isEmpty ? [] : [Self.extendToBounds(samples, start: start, end: now)]
        let values = samples.compactMap(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        if percentage { yDomain = 0...100 }
        else if health {
            // At least five points tall: a one-point gauge re-estimate must not look like a cliff.
            let upper = max(100, ceil(high))
            let lower = max(0, min(floor(low), upper - Self.minimumHealthSpan))
            yDomain = lower...upper
        }
        else {
            let margin = max(0.5, (high - low) * 0.15)
            yDomain = (low - margin)...(high + margin)
        }
    }

    func nearest(to date: Date, maximumDistance: TimeInterval = 45) -> ChartSample? {
        guard !samples.isEmpty else { return nil }
        var lower = 0, upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        let before = lower > 0 ? samples[lower - 1] : nil
        let after = lower < samples.count ? samples[lower] : nil
        let closest: ChartSample
        if let before, let after {
            closest = date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
        } else { closest = before ?? after! }
        if abs(closest.date.timeIntervalSince(date)) <= maximumDistance { return closest }
        // Inside two real endpoints the plotted line is an interpolation, so keep
        // hover inspection available instead of reporting a false missing region.
        guard let first = samples.first, let last = samples.last,
              date >= first.date, date <= last.date else { return nil }
        return closest
    }

    static func plot(in size: CGSize, detailProgress: Double = 1) -> CGRect {
        let progress = CGFloat(ChartPresentation.detailOpacity(detailProgress))
        let left = 34 * progress, top = 8 * progress
        let right = 8 * progress, bottom = 22 * progress
        return CGRect(x: left, y: top,
                      width: max(1, size.width - left - right),
                      height: max(1, size.height - top - bottom))
    }

    static let minimumHealthSpan = 5.0

    private static func hourlyHealthSamples(_ samples: [ChartSample]) -> [ChartSample] {
        func aggregate(_ bucket: [ChartSample]) -> ChartSample {
            let values = bucket.compactMap(\.value).sorted()
            let middle = values.count / 2
            let median = values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2
                : values[middle]
            return ChartSample(date: bucket.last!.date, value: median)
        }

        var result: [ChartSample] = []
        var bucket: [ChartSample] = []
        var bucketHour: Int?
        for sample in samples {
            let hour = Int(floor(sample.date.timeIntervalSinceReferenceDate / 3600))
            if bucketHour != hour {
                if !bucket.isEmpty { result.append(aggregate(bucket)) }
                bucket = []
                bucketHour = hour
            }
            bucket.append(sample)
        }
        if !bucket.isEmpty { result.append(aggregate(bucket)) }
        return result
    }

    private static func extendToBounds(_ samples: [ChartSample], start: Date, end: Date) -> [ChartSample] {
        guard let first = samples.first, let last = samples.last else { return [] }
        var result = samples
        if first.date > start { result.insert(ChartSample(date: start, value: first.value), at: 0) }
        if last.date < end { result.append(ChartSample(date: end, value: last.value)) }
        return result
    }

    func date(at position: CGPoint, plot: CGRect) -> Date? {
        guard plot.contains(position), plot.width > 0 else { return nil }
        return xDomain.lowerBound.addingTimeInterval((position.x - plot.minX) / plot.width * xDomain.upperBound.timeIntervalSince(xDomain.lowerBound))
    }

    func position(_ sample: ChartSample, plot: CGRect) -> CGPoint {
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        let x = sample.date.timeIntervalSince(xDomain.lowerBound) / span
        let y = ((sample.value ?? yDomain.lowerBound) - yDomain.lowerBound) / (yDomain.upperBound - yDomain.lowerBound)
        return CGPoint(x: plot.minX + x * plot.width, y: plot.maxY - y * plot.height)
    }

    static func labelX(_ x: CGFloat, plot: CGRect, width: CGFloat = 106) -> CGFloat {
        min(max(x, plot.minX + width / 2), max(plot.minX + width / 2, plot.maxX - width / 2))
    }
}
