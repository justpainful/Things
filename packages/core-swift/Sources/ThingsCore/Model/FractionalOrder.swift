import Foundation

/// `sort_order REAL` with fractional insertion.
///
/// Dropping an item between 2.0 and 3.0 writes 2.5. No renumbering cascade, so a reorder
/// is a single-row change — which matters enormously for sync, where renumbering 40 rows
/// would manufacture 40 phantom conflicts.
public enum FractionalOrder {

    public static let step: Double = 1.0
    public static let first: Double = 1.0

    /// Doubles have ~52 bits of mantissa; repeated halving between two neighbours runs out
    /// after about 50 insertions in the same gap. Below this we rebalance.
    public static let minimumGap: Double = 1e-9

    public static func between(_ lower: Double?, _ upper: Double?) -> Double {
        switch (lower, upper) {
        case (nil, nil):
            return first
        case (nil, .some(let upper)):
            return upper - step
        case (.some(let lower), nil):
            return lower + step
        case (.some(let lower), .some(let upper)):
            return (lower + upper) / 2
        }
    }

    public static func needsRebalance(_ orders: [Double]) -> Bool {
        guard orders.count > 1 else { return false }
        let sorted = orders.sorted()
        for index in 1..<sorted.count where sorted[index] - sorted[index - 1] < minimumGap {
            return true
        }
        return false
    }

    /// Evenly spaced 1, 2, 3… preserving the current order.
    public static func rebalanced(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { first + Double($0) * step }
    }

    /// Order for appending after everything currently present.
    public static func appending(after orders: [Double]) -> Double {
        guard let maximum = orders.max() else { return first }
        return maximum + step
    }
}
