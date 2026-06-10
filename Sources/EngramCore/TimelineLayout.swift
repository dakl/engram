import Foundation

/// Deterministic time-axis layout for the timeline lens (ADR 0011): dated items
/// flow left→right by month, and items sharing a month stack vertically, balanced
/// around the lane centre. Pure and unit-testable; positions are arbitrary world
/// coordinates the renderer fits to the canvas like any other layout.
public enum TimelineLayout {
    public static func positions(
        for items: [(id: UUID, date: Date)],
        laneSpacing: Double = 90,
        rowSpacing: Double = 26
    ) -> [UUID: SIMD2<Double>] {
        guard !items.isEmpty else { return [:] }

        let calendar = Calendar(identifier: .gregorian)
        func monthIndex(_ date: Date) -> Int {
            let components = calendar.dateComponents([.year, .month], from: date)
            return (components.year ?? 0) * 12 + (components.month ?? 0)
        }

        // Stable order: by date, then id, so ties never reshuffle between runs.
        let sorted = items.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }

        // Map each occupied month to a contiguous lane index (0, 1, 2 …).
        let orderedMonths = Array(Set(sorted.map { monthIndex($0.date) })).sorted()
        let laneByMonth = Dictionary(uniqueKeysWithValues: orderedMonths.enumerated().map { ($1, $0) })

        var rowInMonth: [Int: Int] = [:]
        var countByMonth: [Int: Int] = [:]
        for item in sorted { countByMonth[monthIndex(item.date), default: 0] += 1 }

        var positions: [UUID: SIMD2<Double>] = [:]
        for item in sorted {
            let month = monthIndex(item.date)
            let lane = laneByMonth[month] ?? 0
            let row = rowInMonth[month, default: 0]
            rowInMonth[month] = row + 1
            // Stack upward from the baseline (y = 0) so a horizontal time axis can
            // sit below the dots and months read left→right along it.
            positions[item.id] = SIMD2(Double(lane) * laneSpacing, -Double(row) * rowSpacing)
        }
        return positions
    }
}
