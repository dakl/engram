import SwiftUI
import EngramCore

/// The Activity lens (ADR 0015/0016/0017/0020): a reverse-chronological timeline of
/// what happened to memories — reads (recall/search/fetch/…) and writes
/// (store/update/delete) — rendered as a native `Table` with sortable, resizable
/// columns. The lookback window is a contextual toolbar control (`LensToolbar`);
/// selecting a row opens it in the inspector.
struct ActivityView: View {
    let model: EngramModel

    @State private var sortOrder = [KeyPathComparator(\EngramModel.ActivityRow.event.at, order: .reverse)]

    /// `model.activityRows` is `private(set)`, so sort a local copy by the user's
    /// chosen order for display.
    private var sortedRows: [EngramModel.ActivityRow] {
        model.activityRows.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if model.activityRows.isEmpty {
                ContentUnavailableView(
                    "No recent activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("No activity in the last \(model.activityLookback.rawValue).")
                )
            } else {
                Table(sortedRows, selection: selection, sortOrder: $sortOrder) {
                    TableColumn("Time", value: \.event.at) { row in
                        Text(row.event.at, format: .dateTime.hour().minute().second())
                            .font(Typo.meta)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 96)

                    TableColumn("Action", value: \.event.kind.rawValue) { row in
                        ActivityBadge(kind: row.event.kind)
                    }
                    .width(min: 80, ideal: 104)

                    TableColumn("Memory", value: \.sortTitle) { row in
                        Text(row.memory?.displayTitle ?? "(deleted memory)")
                            .font(Typo.rowTitle)
                            .lineLimit(1)
                            .foregroundStyle(isGone(row) ? .secondary : .primary)
                    }

                    TableColumn("Query") { row in
                        Text(row.event.query ?? "")
                            .font(Typo.meta)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .onAppear { model.loadActivity() }
        .onChange(of: model.activityLookback) { _, _ in model.loadActivity() }
    }

    private func isGone(_ row: EngramModel.ActivityRow) -> Bool {
        row.memory == nil || row.memory?.deletedAt != nil
    }

    /// Table selection (a single row id) projected to the inspector's selected
    /// memory; gone memories don't select.
    private var selection: Binding<EngramModel.ActivityRow.ID?> {
        Binding(
            get: { model.selectedMemory.flatMap { selected in
                model.activityRows.first { $0.memory?.id == selected.id }?.id
            } },
            set: { id in
                guard let id, let row = model.activityRows.first(where: { $0.id == id }),
                      let memory = row.memory, memory.deletedAt == nil else {
                    model.selectedMemory = nil
                    return
                }
                model.selectedMemory = memory
            }
        )
    }
}

/// The activity kind as tinted eyebrow text (ADR 0017, Option A; 0020): no fill,
/// sized to content; the hue is the lone color per row and comes from the shared
/// community palette via `ActivityKind.colorIndex`. Writes (`STORE`/`UPDATE`/
/// `DELETE`) take their own hues, distinct from the read modes.
private struct ActivityBadge: View {
    let kind: ActivityKind

    var body: some View {
        Text(kind.label)
            .font(Typo.eyebrow)
            .foregroundStyle(GraphTheme.community(kind.colorIndex))
    }
}

private extension EngramModel.ActivityRow {
    /// Stable, case-insensitive title for sorting the Memory column.
    var sortTitle: String {
        (memory?.displayTitle ?? "\u{FFFF}").lowercased()
    }
}

#Preview {
    ActivityView(model: .preview())
        .frame(width: 760, height: 480)
        .padding()
}
