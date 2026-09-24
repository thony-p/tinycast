import Foundation

/// Hermes' own number formatting, restated so the token gauge reads exactly like Hermes Desktop's.
///
/// Ported from `@hermes/shared`'s `compactNumber` and the statusbar's `usageContextLabel` /
/// `contextBarLabel`. The thresholds are the point: they sit just under the unit boundary so
/// rounding can never print "1000k" or "1000", and `M` is the top rung — a 1M context window in
/// Tonycast must read `1M`, not `1.0M`.
enum HermesUsageFormat {
    /// `999` → `999`, `1000` → `1k`, `1230` → `1.2k`, `211800` → `211.8k`, `1048576` → `1M`.
    static func compact(_ value: Int?) -> String {
        let number = Double(value ?? 0)
        guard number.isFinite, number > 0 else { return "0" }
        if number >= 999_950 { return scaled(number / 1_000_000, "M") }
        if number >= 999.5 { return scaled(number / 1_000, "k") }
        return String(Int(number.rounded()))
    }

    /// One decimal place, with a trailing `.0` dropped — `1.0M` is wrong, `1M` is right.
    private static func scaled(_ value: Double, _ suffix: String) -> String {
        let text = String(format: "%.1f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }

    /// `~211.8k/1M`, or empty when the agent has not reported a context window yet.
    ///
    /// The `~` marks an estimate. It is present for the ACP `usage_update` estimate and absent once
    /// the provider has measured the same turn, which is the distinction Hermes' own gauge makes.
    static func contextLabel(used: Int?, size: Int?, isEstimated: Bool) -> String {
        guard let size, size > 0 else { return "" }
        return "\(isEstimated ? "~" : "")\(compact(used))/\(compact(size))"
    }

    /// The ten-cell meter, `[██░░░░░░░░]`, matching the desktop statusbar cell for cell.
    ///
    /// Cells round on the raw percent, which is what the desktop does: at 94.9% both draw nine
    /// filled cells beside a "95%" label. Following the desktop exactly matters more here than
    /// making the two agree, because "same as Hermes" is the point of this whole type.
    static func bar(percent: Double?, width: Int = 10) -> String {
        // `String(repeating:count:)` traps on a negative count rather than returning empty, so both
        // counts are clamped before use. The width is clamped first: a negative width would drive
        // `filled` negative as well, and clamping only the tail still traps.
        let cells = max(0, width)
        // A non-finite percent is treated as none: NaN passes both clamps and would draw a full
        // bar, which reads as "context full" — a false alarm produced by a broken measurement.
        let raw = percent ?? 0
        let bounded = raw.isFinite ? max(0, min(100, raw)) : 0
        let filled = max(0, min(cells, Int((bounded / 100 * Double(cells)).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: cells - filled)
    }

    /// `[██░░░░░░░░] ~20%`, or empty when there is no context window to show a share of.
    static func barLabel(percent: Double?, isEstimated: Bool) -> String {
        guard let percent, percent.isFinite else { return "" }
        let bounded = Int(max(0, min(100, percent.rounded())))
        return "[\(bar(percent: percent))] \(isEstimated ? "~" : "")\(bounded)%"
    }

    /// The widest label `contextLabel` can return for a window, so an inline gauge can reserve a
    /// fixed slot instead of resizing as it ticks.
    ///
    /// `used` climbs from `9.9k` to `10.0k` mid-turn, and a self-sizing label would change the row's
    /// width and drag the caret. Within the realisable domain (`used <= size`, neither negative) this
    /// reservation is exact: `Tests/hermes-features-test.swift` sweeps every reading the formatter can
    /// produce and fails if one overflows it.
    ///
    /// The numerator cannot simply be `999.9k`. The `M` rung is unbounded, so a window past a billion
    /// tokens reports a form like `2000M` and a numerator of `1500.5M`, which is wider. The bound is
    /// therefore the wider of the `k` cap and the window's own `M` form, written at one decimal rather
    /// than compacted: the digit is what makes it an upper bound, since `compact` drops a trailing
    /// `.0` that this form keeps.
    static func widestContextLabel(size: Int?) -> String {
        guard let size, size > 0 else { return "" }
        let megabyteForm = String(format: "%.1f", Double(size) / 1_000_000) + "M"
        let numerator = megabyteForm.count > 6 ? megabyteForm : "999.9k"
        return "~\(numerator)/\(compact(size))"
    }

    /// The widest label `barLabel` can return: a full meter, a three-digit percent, and the tilde.
    static func widestBarLabel() -> String {
        "[\(bar(percent: 100))] ~100%"
    }
}
