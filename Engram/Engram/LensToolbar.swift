import SwiftUI
import EngramCore

/// Per-lens controls that live in the one toolbar (ADR 0016/0018/0019): the
/// Activity lookback window, shown only for its lens. The Map and Tags lenses
/// need none.
struct LensToolbar: ToolbarContent {
    let model: EngramModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            switch model.section {
            case .activity:
                Picker("Lookback", selection: lookback) {
                    ForEach(Lookback.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            default:
                EmptyView()
            }
        }
    }

    private var lookback: Binding<Lookback> {
        Binding(get: { model.activityLookback }, set: { model.activityLookback = $0 })
    }
}
