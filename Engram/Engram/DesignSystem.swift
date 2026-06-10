import SwiftUI
import EngramCore

// The app's shared design tokens (ADR 0016): one type scale, one spacing rhythm,
// three radii — system font, system materials, system accent. Custom palettes are
// deliberately deferred to a later ADR.

enum Typo {
    /// A lens/section's own heading.
    static let viewTitle = Font.title3.weight(.semibold)
    /// THE memory title — leads every surface.
    static let rowTitle = Font.body.weight(.semibold)
    /// Content snippets, graph/dendrogram labels.
    static let body = Font.callout
    /// All dates, counts, scores — always monospaced digits.
    static let meta = Font.caption.monospacedDigit()
    /// The one uppercased micro-label (section headers, facet keys).
    static let eyebrow = Font.caption2.weight(.semibold)
}

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radii {
    static let chip: CGFloat = 5
    static let row: CGFloat = 8
    static let pane: CGFloat = 16
}

/// The app's honest, one-paragraph privacy posture — shown in first-run onboarding,
/// the install sheet, and the sidebar footer so the user always knows where their
/// memories live.
enum PrivacyCopy {
    static let summary = """
    Local-first: your memories stay on this Mac (plaintext in Application Support, \
    protected by file permissions + FileVault). No cloud, no accounts, no telemetry. \
    Don't store secrets.
    """
}

// MARK: - Chips (the scalpel rule: a fill only if the color encodes data)

/// The row's primary scope — the one filled chip. Value only (no `project:` noise).
struct ScopeChip: View {
    let value: String
    var body: some View {
        Text(value)
            .font(Typo.eyebrow)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: Radii.chip))
            .foregroundStyle(.tint)
    }
}

/// A secondary facet — tinted text, no fill: `type·decision`.
struct FacetText: View {
    let key: String
    let value: String
    var body: some View {
        (Text(key + "·").foregroundStyle(.tertiary) + Text(value).foregroundStyle(.secondary))
            .font(Typo.meta)
    }
}

/// A freeform tag — colored text only: `#infra`.
struct TagText: View {
    let tag: String
    var body: some View {
        Text("#" + tag).font(Typo.meta).foregroundStyle(.secondary)
    }
}

/// One cluster/source/community dot — shared by the dendrogram gutter, graph
/// legend, and list markers so the same color→meaning mapping reads everywhere.
struct ClusterDot: View {
    let index: Int?
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(GraphTheme.community(index)).frame(width: size, height: size)
    }
}

// MARK: - Canonical memory row

/// THE memory row, rendered as a native `List` row's label (the List provides
/// separators, selection, and hover). Semibold title leads; one filled chip max;
/// monospaced meta recedes (ADR 0016).
struct MemoryRow: View {
    let memory: Memory
    var score: Double? = nil
    /// Tapping a facet/freeform chip focuses that tag (ADR 0019). `nil` keeps the
    /// chips inert (e.g. design-system preview), so the row stays reusable.
    var onTapTag: ((EngramModel.TagFocus) -> Void)? = nil
    /// Tapping the source/project scope chip focuses that project (ADR 0019).
    var onTapSource: ((EngramModel.TagFocus) -> Void)? = nil

    /// Non-project facets (type/language/other keys) as key·value pairs.
    private var otherFacets: [FacetChipItem] {
        var items: [FacetChipItem] = []
        let facets = memory.facets
        for key in FacetKey.allCases where key != .project {
            for value in facets.values(key) { items.append(FacetChipItem(key: key.rawValue, value: value)) }
        }
        let reserved = Set(FacetKey.allCases.map(\.rawValue))
        for (key, values) in facets.byKey where !reserved.contains(key) {
            for value in values { items.append(FacetChipItem(key: key, value: value)) }
        }
        return items
    }

    var body: some View {
        let facets = memory.facets
        let scope = facets.projects.first
        // Cap secondary chips at 4 (across facets + tags), overflow as "+N".
        let secondary = otherFacets.map { ChipKind.facet($0) } + facets.freeform.map { ChipKind.tag($0) }
        let shown = Array(secondary.prefix(4))
        let overflow = secondary.count - shown.count

        return VStack(alignment: .leading, spacing: Space.xs) {
            Text(memory.displayTitle)
                .font(Typo.rowTitle)
                .lineLimit(1)
                .foregroundStyle(.primary)

            if scope != nil || !secondary.isEmpty {
                FlowLayout(spacing: Space.xs) {
                    if let scope {
                        tappable(focus: EngramModel.TagFocus(facet: .project, value: scope),
                                 handler: onTapSource) {
                            ScopeChip(value: scope)
                        }
                    }
                    ForEach(shown) { chip in
                        switch chip {
                        case .facet(let item):
                            tappable(focus: EngramModel.TagFocus(facet: facetKey(item.key), value: item.value),
                                     handler: onTapTag) {
                                FacetText(key: item.key, value: item.value)
                            }
                        case .tag(let tag):
                            tappable(focus: EngramModel.TagFocus(facet: nil, value: tag),
                                     handler: onTapTag) {
                                TagText(tag: tag)
                            }
                        }
                    }
                    if overflow > 0 {
                        Text("+\(overflow)").font(Typo.meta).foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: Space.s) {
                if let score {
                    Text(score, format: .percent.precision(.fractionLength(0)))
                }
                Text(memory.createdAt, format: .dateTime.month().day().year())
                if memory.accessCount > 0 {
                    Text("· \(memory.accessCount) recalls")
                }
                Spacer(minLength: 0)
            }
            .font(Typo.meta)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
    }

    /// Wraps a chip so tapping it fires `handler` (focusing the tag) without also
    /// selecting the row. On macOS a `.plain` Button nested in the row's selection
    /// button takes the tap first; with no handler the chip stays inert and the
    /// tap falls through to row selection.
    @ViewBuilder
    private func tappable<Chip: View>(
        focus: EngramModel.TagFocus,
        handler: ((EngramModel.TagFocus) -> Void)?,
        @ViewBuilder _ chip: () -> Chip
    ) -> some View {
        if let handler {
            Button { handler(focus) } label: { chip() }
                .buttonStyle(.plain)
        } else {
            chip()
        }
    }

    /// Maps a chip's raw facet key to a reserved `FacetKey`, or `nil` for a
    /// non-reserved key (focusing it as a freeform-style value still works).
    private func facetKey(_ raw: String) -> FacetKey? {
        FacetKey(rawValue: raw)
    }
}

/// A renderable secondary chip in a `MemoryRow`.
private enum ChipKind: Identifiable {
    case facet(FacetChipItem)
    case tag(String)
    var id: String {
        switch self {
        case .facet(let item): return "f:\(item.id)"
        case .tag(let tag): return "t:\(tag)"
        }
    }
}

private struct FacetChipItem: Identifiable, Hashable {
    let key: String
    let value: String
    var id: String { "\(key):\(value)" }
}

#if DEBUG
// MARK: - Preview gallery
//
// The "storyboard" for the design system: one canvas (⌥⌘↩ in Xcode) showing every
// token and component against the real types, so spacing/type edits diff visually
// without launching the app. `.tint(.accentColor)` so the filled chips resolve a color.

private extension Memory {
    /// A clean, realistic memory — the happy path. The "project:" tag becomes the one
    /// filled ScopeChip; "type:decision" renders as "type·decision"; accessCount drives recalls.
    static var sample: Memory {
        Memory(
            title: "Engram keeps everything in one shared SQLite store",
            content: "Both the app and the CLI open the same engram.sqlite — no App Group, no dev/prod split.",
            tags: ["project:engram", "type:decision", "storage"],
            accessCount: 3
        )
    }

    /// A deliberately nasty memory that stress-tests the row: a long title that must
    /// truncate, and 6 secondary facets/tags so the row trips the "+N" overflow
    /// (capped at 4 in MemoryRow, line ~105). Zero recalls so that branch is exercised too.
    static var stressSample: Memory {
        Memory(
            title: "Backticks in `engram store` content get shell-substituted and silently corrupt the stored memory",
            content: "Pass content via a temp file and \"$(cat file.md)\" so the shell never re-scans the backticks.",
            tags: ["project:engram", "type:gotcha", "language:bash", "area:cli", "shell", "ranking", "adr"],
            accessCount: 0
        )
    }
}

#Preview("Design System") {
    ScrollView {
        VStack(alignment: .leading, spacing: Space.l) {
            Group {
                Text("TYPE SCALE").font(Typo.eyebrow).foregroundStyle(.secondary)
                Text("viewTitle — a lens heading").font(Typo.viewTitle)
                Text("rowTitle — the memory title").font(Typo.rowTitle)
                Text("body — content snippet").font(Typo.body)
                Text("meta — 92% · Jun 6 · 3 recalls").font(Typo.meta).foregroundStyle(.secondary)
                Text("EYEBROW").font(Typo.eyebrow).foregroundStyle(.secondary)
            }

            Divider()

            Text("CHIPS").font(Typo.eyebrow).foregroundStyle(.secondary)
            HStack(spacing: Space.s) {
                ScopeChip(value: "engram")
                FacetText(key: "type", value: "decision")
                TagText(tag: "infra")
                ClusterDot(index: 0)
                ClusterDot(index: 3)
                ClusterDot(index: nil)
            }

            Divider()

            Text("MEMORY ROW").font(Typo.eyebrow).foregroundStyle(.secondary)
            List {
                MemoryRow(memory: .sample, score: 0.92)
                MemoryRow(memory: .stressSample)
            }
            .frame(height: 200)
        }
        .padding(Space.xl)
    }
    .tint(.accentColor)
    .frame(width: 420)
}
#endif
