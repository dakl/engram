import SwiftUI
import MarkdownUI
import EngramCore

/// The trailing inspector (ADR 0016): shows the selected memory and edits it in
/// place — the single detail surface across every lens, replacing the old modal
/// editor sheet. A pane-wide Preview/Edit toggle gates mutability: Preview renders
/// everything read-only, Edit makes the whole card (title/source/content/tags)
/// editable. Re-keyed per memory id so its working copy resets on selection.
struct MemoryInspector: View {
    let model: EngramModel

    var body: some View {
        if let memory = model.selectedMemory {
            MemoryInspectorEditor(memory: memory, model: model,
                                  retrievalQuery: model.selectedRetrievalQuery)
                .id(memory.id)
        } else {
            ContentUnavailableView("No memory selected",
                                   systemImage: "sidebar.right",
                                   description: Text("Select a memory to view and edit it."))
        }
    }
}

private struct MemoryInspectorEditor: View {
    let memory: Memory
    let model: EngramModel
    /// The full retrieving prompt, shown above the memory in the Activity lens.
    let retrievalQuery: String?

    @State private var workingTitle: String
    @State private var workingSource: String
    @State private var workingContent: String
    @State private var workingTags: String
    @State private var mode: Mode = .preview
    @State private var confirmingDelete = false

    private enum Mode: String, CaseIterable { case preview = "Preview", edit = "Edit" }

    init(memory: Memory, model: EngramModel, retrievalQuery: String?) {
        self.memory = memory
        self.model = model
        self.retrievalQuery = retrievalQuery
        _workingTitle = State(initialValue: memory.title ?? "")
        _workingSource = State(initialValue: memory.source ?? "")
        _workingContent = State(initialValue: memory.content)
        _workingTags = State(initialValue: memory.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if let query = retrievalQuery {
                        retrievalBanner(query)
                        Divider()
                    }
                    modeToggle
                    titleField
                    sourceField
                    metadata
                    Divider()
                    contentField
                    tagsField
                }
                .padding(Space.l)
            }
            Divider()
            footer
        }
    }

    /// One pane-wide mode: `Preview` renders everything read-only, `Edit` makes the
    /// title, source, content, and tags mutable. The read-only metadata (class,
    /// created, recalls) never changes either way.
    private var modeToggle: some View {
        Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 180)
    }

    private func retrievalBanner(_ query: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("RETRIEVED FOR").font(Typo.eyebrow).foregroundStyle(.secondary)
            Text(query)
                .font(Typo.meta)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleField: some View {
        labeledField("TITLE") {
            if mode == .edit {
                TextField(memory.displayTitle, text: $workingTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(Typo.rowTitle)
            } else {
                Text(workingTitle.isEmpty ? memory.displayTitle : workingTitle)
                    .font(Typo.rowTitle)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    /// Source is editable: it folds into the `project` facet (ADR 0013), so
    /// correcting it re-files the memory under the right project across the lenses.
    private var sourceField: some View {
        labeledField("SOURCE") {
            if mode == .edit {
                TextField("project / repo name", text: $workingSource)
                    .textFieldStyle(.roundedBorder)
                    .font(Typo.body)
            } else {
                Text(editedSource ?? "—")
                    .font(Typo.body)
                    .foregroundStyle(editedSource == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.s) {
            GridRow {
                metaCell("CLASS", memory.verifiability.rawValue)
                metaCell("CREATED", memory.createdAt.formatted(date: .abbreviated, time: .omitted))
            }
            GridRow {
                metaCell("RECALLS", "\(memory.accessCount)")
            }
        }
    }

    private func metaCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(Typo.eyebrow).foregroundStyle(.secondary)
            Text(value).font(Typo.meta).foregroundStyle(.primary)
        }
    }

    private var contentField: some View {
        Group {
            if mode == .edit {
                TextEditor(text: $workingContent)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .padding(6)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radii.row))
            } else {
                Markdown(workingContent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tagsField: some View {
        labeledField("TAGS") {
            if mode == .edit {
                TextField("type:decision, language:swift, …", text: $workingTags)
                    .textFieldStyle(.roundedBorder)
            } else if parsedTags.isEmpty {
                Text("—").font(Typo.meta).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: Space.xs) {
                    ForEach(parsedTags, id: \.self) { tag in
                        tagChip(for: tag)
                    }
                }
            }
        }
    }

    /// Renders a tag with the same scalpel rule as `MemoryRow` (no grey-pill mush,
    /// ADR 0016): `project:` → one filled `ScopeChip`, other `key:value` →
    /// `FacetText`, plain → `TagText`.
    @ViewBuilder
    private func tagChip(for tag: String) -> some View {
        if let colon = tag.firstIndex(of: ":"), colon != tag.startIndex {
            let key = String(tag[..<colon])
            let value = String(tag[tag.index(after: colon)...])
            if key == FacetKey.project.rawValue {
                ScopeChip(value: value)
            } else {
                FacetText(key: key, value: value)
            }
        } else {
            TagText(tag: tag)
        }
    }

    /// A labeled section: the uppercase eyebrow label over its content, mode-aware.
    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).font(Typo.eyebrow).foregroundStyle(.secondary)
            content()
        }
    }

    private var footer: some View {
        HStack {
            Button("Delete", role: .destructive) { confirmingDelete = true }
            Spacer()
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(!hasValidChanges)
        }
        .padding(Space.m)
        .confirmationDialog("Delete this memory?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.delete(memory.id)
                model.selectedMemory = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var parsedTags: [String] {
        workingTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// The trimmed source, or `nil` when blank (no source rather than an empty one).
    private var editedSource: String? {
        let trimmed = workingSource.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var hasValidChanges: Bool {
        let trimmed = workingContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let titleChanged = workingTitle.trimmingCharacters(in: .whitespaces) != (memory.title ?? "")
        let sourceChanged = editedSource != memory.source
        return workingContent != memory.content || parsedTags != memory.tags || titleChanged || sourceChanged
    }

    private func save() {
        model.saveEdit(id: memory.id, title: workingTitle, content: workingContent,
                       tags: parsedTags, source: editedSource)
    }
}
