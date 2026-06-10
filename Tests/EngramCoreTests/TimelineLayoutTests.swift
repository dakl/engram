import Foundation
import Testing
@testable import EngramCore

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    let calendar = Calendar(identifier: .gregorian)
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@Test func timelineOrdersMonthsLeftToRightAndSharesLaneWithinMonth() {
    let jan1 = UUID(), jan2 = UUID(), mar = UUID()
    let items = [
        (id: mar, date: date(2026, 3, 5)),
        (id: jan1, date: date(2026, 1, 2)),
        (id: jan2, date: date(2026, 1, 20)),
    ]

    let positions = TimelineLayout.positions(for: items)

    // Same month → same lane (x); earlier month sits left of later month.
    #expect(positions[jan1]!.x == positions[jan2]!.x)
    #expect(positions[jan1]!.x < positions[mar]!.x)
    // Two items in January get distinct rows (y).
    #expect(positions[jan1]!.y != positions[jan2]!.y)
}

@Test func timelineEmptyInputIsEmpty() {
    #expect(TimelineLayout.positions(for: []).isEmpty)
}
