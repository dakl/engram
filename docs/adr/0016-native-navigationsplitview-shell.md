# 16. Native shell: NavigationSplitView + toolbar + inspector, system palette

- **Status:** Accepted
- **Date:** 2026-06-05
- **Deciders:** Daniel Klevebring

## Context

The app grew four modes — **List**, **Tree**, **Activity**, **Graph** — each
bolted on with its own chrome, and it stopped feeling like one app. Concretely
(diagnosed by a macOS-native-architecture and an information-design review):

1. **A "weird extra bar".** The root is a `VStack` stacking a custom `HeaderBar`
   (a hand-drawn titlebar with `.regularMaterial` + a manual `Divider`, sitting
   *under* the real system titlebar) and then a floating segmented
   `viewModePicker`. Three horizontal strips before any content.
2. **A non-native sidebar.** The List view's facet rail is a fixed
   `.frame(width: 220)` `VStack` in a `ScrollView` — it can't collapse or
   resize, has no sidebar material/selection/hover, and exists in List mode only.
3. **Four design languages.** Modes don't share chrome, selection model, or
   palette. Each carries its own floating control strip (`lensPicker`,
   `treeControls`, `LookbackBar`), and every tap opens the same modal
   560×620 editor sheet. Two palettes fight: system-grey (List/Activity/Editor)
   vs the warm `GraphTheme` parchment (Tree/Graph), with Activity leaking a
   one-off amber.

Three expert subagents (`.claude/agents/macos-native-architect`,
`information-design-craftsman`, `design-director`) produced and synthesized a
design. The one genuine fork — warm `GraphTheme` promoted app-wide vs. a neutral
system palette — was decided by the user: **make it look like a native Mac app;
custom color palettes can come later.**

## Decision

Adopt the standard macOS spine: **one `NavigationSplitView` (sidebar + detail)
with a trailing `.inspector`**, system chrome throughout.

### 1. Navigation & chrome
- **Real titlebar.** Delete `HeaderBar.swift`. The system titlebar + one
  `.toolbar` replace it.
- **Sidebar** = `List(selection:)` with `.listStyle(.sidebar)` — collapsible and
  resizable for free (fixes #2). It holds the **lens switcher** (List / Tree /
  Activity / Graph-if-beta) as `Label` rows, and — in the List lens — the
  **facet sections** (type / project / language) as grouped rows with counts.
  The lens switcher lives in the sidebar (not the toolbar `.principal`) so the
  window grows no third bar and navigation isn't split across two regions
  (fixes #1).
- **Detail column** hosts the active lens; no lens draws its own chrome strip.
- **One toolbar:** `.searchable(placement: .toolbar)` (replaces the custom search
  capsule); `.primaryAction` for Install CLI / Hooks & Skills / Refresh; and
  **contextual items** for per-lens controls (Graph lens picker, Activity
  lookback) shown only for that lens. Tree clustering controls already live in
  Settings — delete the in-canvas `treeControls` copy.

### 2. Selection & detail — inspector, not a modal sheet
Single-click a memory in **any** lens → it becomes `selectedMemory` and opens in
a trailing **`.inspector`** (read + inline edit; Save/Delete in the inspector).
One selection model across all four lenses, replacing the modal `MemoryEditorView`
sheet. (`.inspector` is macOS 14+, already the deployment target.)

### 3. Palette — system/native now, custom later
- App chrome and all non-canvas surfaces use **system materials and the system
  accent** (`.tint`, `.background`, `.regularMaterial`, semantic greys).
- **`GraphTheme` is scoped to the Tree/Graph `Canvas` drawing only** — it is no
  longer app chrome. Activity drops its one-off amber and `GraphTheme` chrome and
  uses system styling like the other list-like surfaces.
- A future ADR may introduce a custom palette app-wide; deliberately deferred.

### 4. One design system (craft)
- **Type scale (system font, 5 roles):** `viewTitle` (`.title3.semibold`),
  `rowTitle` (`.body.semibold` — the memory title **leads every surface**),
  `body` (`.callout`), `meta` (`.caption.monospacedDigit` — all dates/counts/
  scores), `eyebrow` (`.caption2.semibold`, the one uppercased micro-label).
- **Spacing** on a 4-pt base (4/8/12/16/24); **three radii** (chip 5 / row 8 /
  pane 16) replacing today's six.
- **Chip rule (scalpel):** a chip earns a *fill* only if its color encodes data.
  `project:` → one tinted **ScopeChip** (value only, prefix dropped);
  `type:`/`language:`/other facets → tinted **text**, no capsule; freeform tags →
  `#tag` text; **cap at 4 + "+N"**. Kills the grey-pill mush.
- **Shared components:** a canonical `MemoryRow` (semibold title leads, one fill
  max, mono meta) and a `ClusterDot`, reused across List / Tree / Activity /
  Graph legend / inspector so the surfaces read as one family. Within the native
  `List`, rows rely on system separators/selection/hover (no hand-rolled card
  background or manual divider).
- Delete the legacy `StatCard` grid + `TagChip`; the compact stats summary
  already replaced the grid.

## Consequences

**Positive**
- Standard macOS structure: the OS provides collapse/resize, selection, hover,
  search, and titlebar — far less custom chrome to maintain, and it *feels*
  native (the explicit goal).
- One sidebar, one toolbar, one selection model, one palette, one type/space
  scale across all four lenses — coherence.
- Most logic is reused (layout math, store/search/activity, editor body, row
  content); only chrome and styling change.

**Negative / trade-offs**
- A large, multi-file UI refactor touching the root, every view, and the model.
- Facet selection + `selectedMemory` must lift from view `@State` into
  `EngramModel` (touches the filtering path — cover with tests).
- The warm `GraphTheme` look the Tree/Graph had is no longer the app's identity;
  re-introducing warmth is a deferred, separate decision.
- Don't ship mid-migration: the interim has a half-migrated palette.

## Build order (PR-sized, smallest structural change first)
1. **State lift:** `ViewMode` → `Section` enum (`CaseIterable`/`Identifiable` +
   `title`/`systemImage`); lift facet `selected` + `selectedMemory` into
   `EngramModel`. Pure refactor; `make test`.
2. **Tokens:** add the type/spacing/radii constants + chip components; no layout
   change.
3. **Shell:** `NavigationSplitView` + sidebar `List(selection:)` (lenses +
   facets) + one toolbar + `.searchable`. Delete `HeaderBar`, `viewModePicker`,
   the 220-wide facet rail. (Fixes #1, #2.)
4. **Canonical `MemoryRow` + chips** in a native `List`; delete `StatCard`/`TagChip`.
5. **Inspector** replaces the editor sheet; single-click select+inspect+edit.
6. **Fold mode controls into the toolbar; de-skin Activity** (drop amber/
   `GraphTheme`, remap `SourceBadge` to system or a single data palette); scope
   `GraphTheme` to the canvas.
7. **Craft polish:** Tree/Graph hover + tooltip via tokens; eyebrow section
   headers; final spacing/radii sweep.

## Related
Supersedes the view-mode `VStack`/`HeaderBar` chrome and the graph-as-peer
framing in ADR 0011; complements ADR 0013/0014 (the faceted home content lives
in the new shell) and ADR 0015 (Activity becomes a lens in the shell). The
`.claude/agents/` designer subagents that produced this are reusable.
