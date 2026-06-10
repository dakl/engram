import SwiftUI
import AppKit
import EngramCore

/// The Map lens (ADR 0019): a **memory-memory shared-tag graph** on the reused
/// canvas substrate. Memories are the only nodes; an edge joins two memories that
/// share a tag (idf-weighted and pruned, so very common tags don't fuse the cloud
/// into a clique). Position alone shows which memories cluster by their shared
/// tags. Clicking a dot opens it in the inspector and highlights it plus its
/// neighborhood. The bipartite tag-hub form was trialed and dropped; the MDS
/// projection (ADR 0018) is retired.
struct MapView: View {
    let model: EngramModel

    var body: some View {
        if model.memories.count >= 2 {
            MapCanvas(model: model)
        } else {
            ContentUnavailableView(
                "Not enough memories to map",
                systemImage: "circle.grid.2x2",
                description: Text("Store and tag a few more memories to see them linked by their tags.")
            )
        }
    }
}

/// Eases displayed node positions toward a target layout so a data refresh morphs
/// smoothly instead of teleporting. The layout is computed off-actor; this just
/// interpolates each frame.
@Observable
@MainActor
private final class SceneDriver {
    private(set) var positions: [UUID: SIMD2<Double>] = [:]
    private var target: [UUID: SIMD2<Double>] = [:]
    private(set) var settled = true

    private static let easing = 0.18
    private static let doneThreshold = 0.0006

    /// First layout: snap straight to it (no intro fly-in).
    func jump(to newTarget: [UUID: SIMD2<Double>]) {
        positions = newTarget
        target = newTarget
        settled = true
    }

    /// Subsequent layouts: animate toward them. New nodes start at their target;
    /// vanished nodes are dropped.
    func animate(to newTarget: [UUID: SIMD2<Double>]) {
        target = newTarget
        for (id, point) in newTarget where positions[id] == nil { positions[id] = point }
        positions = positions.filter { newTarget[$0.key] != nil }
        settled = false
    }

    func advance() {
        guard !settled else { return }
        var next = positions
        var maxDelta = 0.0
        for (id, destination) in target {
            let current = next[id] ?? destination
            let stepped = current + (destination - current) * Self.easing
            next[id] = stepped
            let delta = stepped - current
            maxDelta = max(maxDelta, (delta.x * delta.x + delta.y * delta.y).squareRoot())
        }
        positions = next
        if maxDelta < Self.doneThreshold {
            positions = target
            settled = true
        }
    }
}

/// The drawing surface: morphs node positions on the animation timeline and paints
/// links → memory dots → tooltip, with pan/zoom, hover, and tap-to-open (memory →
/// inspector). The selected memory and its neighborhood are emphasized; the rest
/// dims.
private struct MapCanvas: View {
    let model: EngramModel

    /// When set (system Reduce Motion), the layout snaps and zoom changes are
    /// instant instead of eased (P1 #11).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var driver = SceneDriver()
    /// Memory-memory shared-tag graph: memories are nodes, edges join shared tags.
    @State private var linkGraph = MemoryGraph(nodes: [], edges: [])
    @State private var hasLaidOut = false
    @State private var canvasSize: CGSize = .zero
    @State private var hoveredNodeID: UUID?

    @State private var committedZoom: CGFloat = 1
    @State private var committedPan: CGSize = .zero
    @GestureState private var gestureZoom: CGFloat = 1
    @GestureState private var gesturePan: CGSize = .zero

    @State private var showHelp = false

    private static let nodeRadius: CGFloat = 7
    private static let hoveredNodeRadius: CGFloat = 11
    private static let hitRadius: CGFloat = 16
    private static let padding: CGFloat = 60
    private static let minZoom: CGFloat = 0.3
    private static let maxZoom: CGFloat = 5

    private var effectiveZoom: CGFloat {
        min(max(committedZoom * gestureZoom, Self.minZoom), Self.maxZoom)
    }
    private var effectivePan: CGSize {
        CGSize(width: committedPan.width + gesturePan.width,
               height: committedPan.height + gesturePan.height)
    }

    private var memoryByID: [UUID: Memory] {
        Dictionary(model.memories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Selection + highlight

    /// The currently selected memory's id (driven by clicking a dot; persists while
    /// the inspector is open).
    private var selectedID: UUID? { model.selectedMemory?.id }

    /// Memories directly linked to the selection (its neighborhood). Empty when
    /// nothing is selected.
    private var selectedNeighborIDs: Set<UUID> {
        guard let selectedID else { return [] }
        var neighbors: Set<UUID> = []
        for edge in linkGraph.edges {
            if edge.a == selectedID { neighbors.insert(edge.b) }
            else if edge.b == selectedID { neighbors.insert(edge.a) }
        }
        return neighbors
    }

    // MARK: - Coloring

    /// Dots are a single neutral color: on a tag-graph, *position* already encodes
    /// grouping (a memory sits by its tags), so coloring by cluster/source/type
    /// would re-encode the same thing (ADR 0019 amendment). Color is reserved for
    /// the things position can't show — search highlight and selection.
    private var highlightIDs: Set<UUID>? { model.isSearching ? model.searchResultIDs : nil }

    /// Rebuild the layout whenever the memory set changes.
    private var layoutKey: String {
        model.memories.map { $0.id.uuidString }.sorted().joined().hashValue.description
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: driver.settled)) { _ in
            let _ = driver.advance()
            Canvas { context, size in
                let positions = driver.positions
                let transform = Self.makeTransform(positions: positions, size: size,
                                                   zoom: effectiveZoom, pan: effectivePan)
                drawLinks(in: context, positions: positions, transform: transform)
                drawMemoryDots(in: context, positions: positions, transform: transform)
                drawTooltip(in: context, positions: positions, transform: transform, size: size)
            }
            .background(GeometryReader { proxy in
                Color.clear.onAppear { canvasSize = proxy.size }
                    .onChange(of: proxy.size) { _, new in canvasSize = new }
            })
        }
        .background(GraphTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: Radii.pane))
        .overlay(RoundedRectangle(cornerRadius: Radii.pane).strokeBorder(GraphTheme.border))
        .contentShape(Rectangle())
        .overlay(ScrollZoomCatcher { applyScrollZoom($0) })
        .gesture(panGesture)
        .simultaneousGesture(zoomGesture)
        .onTapGesture { location in handleTap(at: location) }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location): hoveredNodeID = nearestNodeID(to: location)
            case .ended: hoveredNodeID = nil
            }
        }
        .overlay(alignment: .topTrailing) { helpButton }
        .overlay(alignment: .bottomTrailing) { zoomControls.padding(12) }
        .accessibilityRepresentation { memoryAccessibilityList }
        .task(id: layoutKey) { await relayout() }
    }

    /// VoiceOver-only fallback (P1 #11): the Canvas is opaque to assistive tech, so
    /// expose every memory as a labeled, activatable list element. Activating one
    /// selects it (opening the inspector), matching a tap on its dot.
    private var memoryAccessibilityList: some View {
        List(model.memories) { memory in
            Button {
                model.selectedMemory = memory
            } label: {
                Text(memory.displayTitle)
            }
            .accessibilityLabel(memory.displayTitle)
            .accessibilityHint("Opens this memory in the inspector")
        }
        .accessibilityLabel("Memories on the map")
    }

    // MARK: - Layout

    private func relayout() async {
        let memories = model.memories
        let (built, target) = await Task.detached(priority: .userInitiated) { () -> (MemoryGraph, [UUID: SIMD2<Double>]) in
            let graph = Self.buildLinkGraph(memories)
            return (graph, Self.layoutLinkGraph(graph).mapValues { $0 * 1000 })
        }.value
        if Task.isCancelled { return }
        linkGraph = built
        applyLayout(target)
    }

    private func applyLayout(_ target: [UUID: SIMD2<Double>]) {
        // Reduce Motion: snap to every layout (no eased morph).
        if hasLaidOut && !reduceMotion {
            driver.animate(to: target)
        } else {
            driver.jump(to: target)
            hasLaidOut = true
        }
    }

    // MARK: - Link graph + layout (memory ↔ memory, shared-tag)

    /// Tags carried by more than this fraction of memories are dropped before
    /// building the link graph, so a catch-all `source`/tag can't fully connect
    /// the cloud into a clique (idf already de-weights them; this is the guard).
    private static let ubiquitousLinkTagThreshold = 0.9

    /// Builds a **memory-only** graph whose edges join memories that share a tag,
    /// idf-weighted and pruned (top-k per node) so it stays sparse. Tags are the
    /// facet-derived tokens the Map already uses (so `source` folds into
    /// `project`), minus ubiquitous tags. No semantic/source signal — pure tags.
    private static func buildLinkGraph(_ memories: [Memory]) -> MemoryGraph {
        let memoryCount = memories.count
        guard memoryCount > 1 else {
            return MemoryGraph(nodes: memories.map(GraphNode.init), edges: [])
        }

        // Facet-derived tag tokens per memory (unique per facet:value / #freeform).
        var tokensByMemory: [UUID: [String]] = [:]
        var documentFrequency: [String: Int] = [:]
        for memory in memories {
            let tokens = tagTokens(of: memory)
            tokensByMemory[memory.id] = tokens
            for token in Set(tokens) { documentFrequency[token, default: 0] += 1 }
        }
        let ubiquitousLimit = Double(memoryCount) * ubiquitousLinkTagThreshold
        let droppedTokens = Set(documentFrequency.filter { Double($0.value) > ubiquitousLimit }.keys)

        // Feed blend Memory copies whose `tags` are the surviving tokens and whose
        // `source` is cleared (so only shared tags drive edges).
        let projected: [Memory] = memories.map { memory in
            var copy = memory
            copy.tags = (tokensByMemory[memory.id] ?? []).filter { !droppedTokens.contains($0) }
            copy.source = nil
            return copy
        }

        let config = GraphConfig(
            semanticWeight: 0,
            tagWeight: 1,
            sourceWeight: 0,
            neighborsPerNode: 5,
            edgeFloor: 0.6
        )
        let edges = MemoryGraphBuilder.blend(memories: projected, neighbors: [:], config: config)
        return MemoryGraph(nodes: memories.map(GraphNode.init), edges: edges)
    }

    /// A memory's facet-derived tag tokens (`source` folds into the `project` facet
    /// via `Memory.facets`). Faceted tags are namespaced `facet:value`, freeform
    /// tags `#value`, so the two can't collide.
    private static func tagTokens(of memory: Memory) -> [String] {
        let facets = memory.facets
        var tokens: [String] = []
        for (facet, values) in facets.byKey {
            for value in Set(values) { tokens.append("\(facet):\(value)") }
        }
        for value in Set(facets.freeform) { tokens.append("#\(value)") }
        return tokens
    }

    /// Deterministic force layout of the link graph: fixed iterations of
    /// `ForceDirectedLayout.step()` off-actor, then a percentile-robust
    /// normalization so a stray node can't squish the cloud.
    private static func layoutLinkGraph(_ graph: MemoryGraph, iterations: Int = 400) -> [UUID: SIMD2<Double>] {
        guard graph.nodes.count > 1 else {
            return graph.nodes.first.map { [$0.id: SIMD2(0, 0)] } ?? [:]
        }
        var layout = ForceDirectedLayout(
            graph: graph,
            config: .init(springLength: 60, centerStrength: 0.06, maxSteps: iterations)
        )
        for _ in 0..<iterations where !layout.isSettled { layout.step() }

        // Normalize on a sorted-id ordering (deterministic — dict iteration order isn't).
        let positions = layout.positions()
        let ids = graph.nodes.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let ordered = ids.map { positions[$0] ?? SIMD2<Double>(0, 0) }
        let normalized = Self.normalizeToBox(ordered)
        var result: [UUID: SIMD2<Double>] = [:]
        for (index, id) in ids.enumerated() { result[id] = normalized[index] }
        return result
    }

    /// Percentile-robust rescale into ~`[-1, 1]²` (centroid + 95th-pct radius +
    /// clamp) so an outlier can't squish the bulk.
    private static func normalizeToBox(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard !points.isEmpty else { return points }
        let centroid = points.reduce(SIMD2<Double>(0, 0), +) / Double(points.count)
        func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
        let radii = points.map { length($0 - centroid) }.sorted()
        let index = max(0, min(radii.count - 1, Int((Double(radii.count) - 1) * 0.95)))
        let scale = max(radii[index], 1e-9)
        let clampRadius = 1.15
        return points.map { point in
            let v = (point - centroid) / scale
            let r = length(v)
            return r > clampRadius ? v / r * clampRadius : v
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture()
            .updating($gesturePan) { value, state, _ in state = value.translation }
            .onEnded { value in
                committedPan.width += value.translation.width
                committedPan.height += value.translation.height
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($gestureZoom) { value, state, _ in state = value }
            .onEnded { value in
                committedZoom = min(max(committedZoom * value, Self.minZoom), Self.maxZoom)
            }
    }

    private func nudgeZoom(_ factor: CGFloat) {
        let clamped = min(max(committedZoom * factor, Self.minZoom), Self.maxZoom)
        if reduceMotion {
            committedZoom = clamped
        } else {
            withAnimation(.easeInOut(duration: 0.15)) { committedZoom = clamped }
        }
    }

    /// Scroll-wheel / trackpad zoom: scroll up to zoom in. Multiplicative for an
    /// even feel; the delta is pre-scaled (mouse wheel boosted, trackpad as-is)
    /// and clamped per event so a fast flick can't jump the whole range.
    private func applyScrollZoom(_ delta: CGFloat) {
        let clamped = max(-30, min(30, delta))
        let factor = 1 + clamped * 0.01
        committedZoom = min(max(committedZoom * factor, Self.minZoom), Self.maxZoom)
    }

    private func resetView() {
        if reduceMotion {
            committedZoom = 1
            committedPan = .zero
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                committedZoom = 1
                committedPan = .zero
            }
        }
    }

    /// A tap selects the nearest memory dot, opening it in the inspector (ADR 0019).
    /// A tap on empty space leaves the current selection alone.
    private func handleTap(at location: CGPoint) {
        guard let id = nearestNodeID(to: location) else { return }
        model.selectedMemory = memoryByID[id]
    }

    // MARK: - Overlays

    private var helpButton: some View {
        Button { showHelp.toggle() } label: {
            Image(systemName: "info.circle").font(.body).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("How to read the map")
        .accessibilityLabel("Map help")
        .padding(10)
        .popover(isPresented: $showHelp, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reading the map").font(.headline)
                Label("Each dot is a memory; a line links two memories that share a tag.",
                      systemImage: "circle.grid.2x2")
                Label("Memories that share tags settle near each other.", systemImage: "point.3.connected.trianglepath.dotted")
                Label("Click a dot to open it and highlight its connections.", systemImage: "hand.tap")
                Divider()
                Text("Drag to pan · pinch to zoom").font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout).padding(16).frame(width: 340)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { nudgeZoom(0.8) } label: { Image(systemName: "minus") }
                .help("Zoom out")
                .accessibilityLabel("Zoom out")
            Button { nudgeZoom(1.25) } label: { Image(systemName: "plus") }
                .help("Zoom in")
                .accessibilityLabel("Zoom in")
            Divider().frame(height: 16)
            Button { resetView() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Reset zoom and fit")
                .accessibilityLabel("Fit to view")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Coordinate transform

    private struct Transform {
        let scale: CGFloat
        let worldCenter: SIMD2<Double>
        let viewCenter: CGPoint
        func point(_ world: SIMD2<Double>) -> CGPoint {
            CGPoint(x: viewCenter.x + CGFloat(world.x - worldCenter.x) * scale,
                    y: viewCenter.y + CGFloat(world.y - worldCenter.y) * scale)
        }
    }

    private static func makeTransform(positions: [UUID: SIMD2<Double>], size: CGSize,
                                      zoom: CGFloat, pan: CGSize) -> Transform {
        let values = Array(positions.values)
        let viewCenter = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        guard let first = values.first else {
            return Transform(scale: zoom, worldCenter: .zero, viewCenter: viewCenter)
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for position in values {
            minX = min(minX, position.x); maxX = max(maxX, position.x)
            minY = min(minY, position.y); maxY = max(maxY, position.y)
        }
        let worldWidth = max(maxX - minX, 1e-6)
        let worldHeight = max(maxY - minY, 1e-6)
        let usableWidth = max(size.width - 2 * padding, 1)
        let usableHeight = max(size.height - 2 * padding, 1)
        let fitScale = min(usableWidth / CGFloat(worldWidth), usableHeight / CGFloat(worldHeight))
        return Transform(scale: fitScale * zoom,
                         worldCenter: SIMD2((minX + maxX) / 2, (minY + maxY) / 2),
                         viewCenter: viewCenter)
    }

    // MARK: - Links (memory ↔ memory, shared-tag)

    /// Draw an edge between each pair of memories that share a tag, opacity scaled
    /// by the (idf-weighted) edge weight. When a memory is selected, its incident
    /// edges draw at full strength and the rest dim, so the selection's
    /// neighborhood pops.
    private func drawLinks(in context: GraphicsContext, positions: [UUID: SIMD2<Double>], transform: Transform) {
        let weights = linkGraph.edges.map(\.weight)
        let maxWeight = max(weights.max() ?? 1, 1e-6)
        let selectedID = selectedID
        for edge in linkGraph.edges {
            guard let from = positions[edge.a], let to = positions[edge.b] else { continue }
            var path = Path()
            path.move(to: transform.point(from))
            path.addLine(to: transform.point(to))
            let base = 0.08 + (edge.weight / maxWeight) * 0.24
            // Selected memory's incident edges: full strength; the rest dim.
            let opacity: Double
            if let selectedID {
                let incident = edge.a == selectedID || edge.b == selectedID
                opacity = incident ? min(base * 2.2, 0.6) : base * 0.25
            } else {
                opacity = base
            }
            let lineWidth: CGFloat = (selectedID != nil && (edge.a == selectedID || edge.b == selectedID)) ? 1.5 : 1
            context.stroke(path, with: .color(GraphTheme.edgeFaint.opacity(opacity)), lineWidth: lineWidth)
        }
    }

    // MARK: - Memory dots

    private func drawMemoryDots(in context: GraphicsContext, positions: [UUID: SIMD2<Double>], transform: Transform) {
        let highlight = highlightIDs
        let selectedID = selectedID
        let neighborIDs = selectedNeighborIDs
        let hasSelection = selectedID != nil
        for node in linkGraph.nodes {
            let memoryID = node.id
            guard let world = positions[memoryID] else { continue }
            let center = transform.point(world)
            let isHovered = memoryID == hoveredNodeID
            let isSelected = memoryID == selectedID
            let isNeighbor = neighborIDs.contains(memoryID)

            // Visual priority: selection > search highlight > neutral. When a
            // memory is selected, dim everything outside its neighborhood; when
            // searching (and nothing selected), dim non-matches.
            let isMatch = highlight?.contains(memoryID)
            let dimmed: Bool
            if hasSelection {
                dimmed = !isSelected && !isNeighbor
            } else {
                dimmed = isMatch == false
            }
            let baseColor: Color = (isSelected || isMatch == true) ? Color.accentColor : GraphTheme.fallback
            let radius = isHovered ? Self.hoveredNodeRadius : Self.nodeRadius
            // Neighbors of the selection stay near full strength so the cluster reads.
            // The dim floor is 0.45 (not lower) so backgrounded dots stay legible
            // against the light-mode white canvas.
            let dimOpacity = (hasSelection && isNeighbor) ? 0.85 : 0.45
            let color = baseColor.opacity(dimmed ? dimOpacity : 1.0)

            // Persistent selection ring/halo (distinct from the transient hover halo
            // — it stays while the inspector is open).
            if isSelected {
                let ringRadius = radius + 5
                let ringRect = CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                      width: ringRadius * 2, height: ringRadius * 2)
                context.stroke(Path(ellipseIn: ringRect), with: .color(Color.accentColor.opacity(0.9)), lineWidth: 2.5)
            } else if isHovered {
                let haloRect = CGRect(x: center.x - radius - 4, y: center.y - radius - 4,
                                      width: (radius + 4) * 2, height: (radius + 4) * 2)
                context.stroke(Path(ellipseIn: haloRect), with: .color(baseColor.opacity(0.5)), lineWidth: 2)
            }
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(GraphTheme.background))
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    // MARK: - Tooltip (memory dots)

    private func drawTooltip(in context: GraphicsContext, positions: [UUID: SIMD2<Double>], transform: Transform, size: CGSize) {
        guard let hoveredNodeID, let world = positions[hoveredNodeID],
              let memory = memoryByID[hoveredNodeID] else { return }
        let center = transform.point(world)
        let dotColor = GraphTheme.fallback
        let label = Text(memory.displayTitle).font(.callout).fontWeight(.medium).foregroundStyle(.primary)
        let resolved = context.resolve(label)
        let textSize = resolved.measure(in: CGSize(width: 280, height: 100))

        let dotGap: CGFloat = 6
        let dotDiameter: CGFloat = 7
        let hPad: CGFloat = 10, vPad: CGFloat = 7, edge: CGFloat = 4
        let cardWidth = hPad * 2 + dotDiameter + dotGap + textSize.width
        let cardHeight = vPad * 2 + textSize.height
        let gap = Self.hoveredNodeRadius + 10
        var originX = center.x + gap
        if originX + cardWidth > size.width - edge { originX = center.x - gap - cardWidth }
        originX = max(edge, min(originX, size.width - edge - cardWidth))
        var originY = center.y - cardHeight / 2
        originY = max(edge, min(originY, size.height - edge - cardHeight))

        let cardRect = CGRect(x: originX, y: originY, width: cardWidth, height: cardHeight)
        let cardPath = Path(roundedRect: cardRect, cornerRadius: 8)
        context.fill(cardPath, with: .color(GraphTheme.surface))
        context.stroke(cardPath, with: .color(GraphTheme.border), lineWidth: 1)
        let dotRect = CGRect(x: cardRect.minX + hPad, y: cardRect.midY - dotDiameter / 2,
                             width: dotDiameter, height: dotDiameter)
        context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
        let textRect = CGRect(x: dotRect.maxX + dotGap, y: cardRect.minY + vPad,
                              width: textSize.width, height: textSize.height)
        context.draw(resolved, in: textRect)
    }

    // MARK: - Hit testing

    /// Nearest memory dot to a point.
    private func nearestNodeID(to location: CGPoint) -> UUID? {
        let positions = driver.positions
        let transform = Self.makeTransform(positions: positions, size: canvasSize,
                                           zoom: effectiveZoom, pan: effectivePan)
        var nearest: (id: UUID, distance: CGFloat)?
        for node in linkGraph.nodes {
            guard let world = positions[node.id] else { continue }
            let point = transform.point(world)
            let distance = hypot(point.x - location.x, point.y - location.y)
            if distance <= Self.hitRadius, distance < (nearest?.distance ?? .greatestFiniteMagnitude) {
                nearest = (node.id, distance)
            }
        }
        return nearest?.id
    }
}

/// Captures scroll-wheel / trackpad scroll over the Map and reports a zoom delta.
/// Uses a local event monitor scoped to this view's bounds, and a passthrough
/// NSView (`hitTest` → nil) so it never blocks the SwiftUI pan/tap gestures below.
private struct ScrollZoomCatcher: NSViewRepresentable {
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.attach(to: view, onZoom: onZoom)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onZoom = onZoom
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var onZoom: ((CGFloat) -> Void)?
        private weak var view: NSView?
        private var monitor: Any?

        func attach(to view: NSView, onZoom: @escaping (CGFloat) -> Void) {
            self.view = view
            self.onZoom = onZoom
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      event.window == window else { return event }
                let pointInView = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(pointInView) else { return event }
                // Mouse wheel reports coarse "line" deltas; trackpad reports precise
                // point deltas — boost the former so both feel comparable.
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
                if delta != 0 { self.onZoom?(delta) }
                return nil // consume so the scroll doesn't bubble to a parent scroll view
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

#if DEBUG
#Preview("Map — empty") {
    MapView(model: .preview())
        .frame(width: 600, height: 500)
}
#endif
