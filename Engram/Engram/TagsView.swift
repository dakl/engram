import SwiftUI
import EngramCore

/// The Tags lens (ADR 0019): a native `List` of **all tags**, grouped into
/// sections by facet — TYPE / PROJECT / LANGUAGE / TAGS (freeform) — each tag a
/// row with a member-count badge that expands (`DisclosureGroup`) into its
/// memories as canonical `MemoryRow`s. Clicking a memory opens it in the
/// inspector. Deterministic, authored labels, no projection. Replaces the old
/// Louvain icicle (Structure lens).
struct TagsView: View {
    let model: EngramModel

    /// Section order: the reserved facets, then freeform tags last.
    private static let facetSections: [FacetKey?] = [.type, .project, .language, nil]

    var body: some View {
        if model.memories.isEmpty {
            ContentUnavailableView(
                "No tags yet",
                systemImage: "tag",
                description: Text("Tag your memories (e.g. type:decision, language:swift) to see them grouped here.")
            )
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Self.facetSections, id: \.self) { facet in
                        let buckets = model.tagBuckets(for: facet)
                        if !buckets.isEmpty {
                            Section(Self.sectionTitle(facet)) {
                                ForEach(buckets) { bucket in
                                    TagRow(bucket: bucket, model: model)
                                        .id(bucket.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: model.focusedTag) { _, focus in
                    guard let focus else { return }
                    withAnimation { proxy.scrollTo(focusID(focus), anchor: .top) }
                }
                .task(id: anchorKey) {
                    // Honor a focus set before this view appeared (lens switch).
                    if let focus = model.focusedTag {
                        withAnimation { proxy.scrollTo(focusID(focus), anchor: .top) }
                    }
                }
            }
        }
    }

    private var anchorKey: String { model.focusedTag.map { "\($0.facet?.rawValue ?? "tag"):\($0.value)" } ?? "" }

    private func focusID(_ focus: EngramModel.TagFocus) -> String {
        "\(focus.facet?.rawValue ?? "tag"):\(focus.value)"
    }

    private static func sectionTitle(_ facet: FacetKey?) -> String {
        facet?.rawValue.uppercased() ?? "TAGS"
    }
}

/// One tag row: the tag value + a member-count badge, expandable into its
/// memories. Auto-expands when the model focuses this tag (click-through nav).
private struct TagRow: View {
    let bucket: EngramModel.TagBucket
    let model: EngramModel

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(bucket.memories) { memory in
                Button { model.selectedMemory = memory } label: {
                    MemoryRow(
                        memory: memory,
                        onTapTag: { model.focusTag($0) },
                        onTapSource: { model.focusTag($0) }
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    model.selectedMemory?.id == memory.id ? Color.accentColor.opacity(0.12) : Color.clear
                )
            }
        } label: {
            Label(bucket.value, systemImage: bucket.facet == nil ? "number" : "tag")
                .badge(bucket.count)
        }
        .onChange(of: model.focusedTag) { _, focus in
            if focus == bucket.focus { expanded = true }
        }
        .onAppear {
            if model.focusedTag == bucket.focus { expanded = true }
        }
    }
}

#if DEBUG
#Preview {
    TagsView(model: .preview())
        .frame(width: 520, height: 560)
}
#endif
