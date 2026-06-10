import Foundation
import Testing
@testable import EngramCore

@Test func parseSplitsFacetsFromFreeform() {
    let facets = Facets.parse(tags: ["type:decision", "language:swift", "embeddings", "adr"])
    #expect(facets.types == ["decision"])
    #expect(facets.languages == ["swift"])
    #expect(facets.freeform == ["embeddings", "adr"])
}

@Test func parseFoldsSourceIntoProjectFacet() {
    let facets = Facets.parse(tags: ["type:fact"], source: "engram")
    #expect(facets.projects == ["engram"])
}

@Test func parseUnionsSourceWithExplicitProjectTags() {
    // Source is already an explicit tag: no duplicate, explicit order preserved.
    let withDuplicate = Facets.parse(tags: ["project:trantor", "project:engram"], source: "engram")
    #expect(withDuplicate.projects == ["trantor", "engram"])

    // Source absent from tags: capture origin is prepended so it leads.
    let withNewOrigin = Facets.parse(tags: ["project:trantor"], source: "engram")
    #expect(withNewOrigin.projects == ["engram", "trantor"])
}

@Test func parseSupportsMultipleProjects() {
    let facets = Facets.parse(tags: ["project:engram", "project:codez"], source: nil)
    #expect(facets.projects == ["engram", "codez"])
}

@Test func parseTreatsUnknownKeysAsGenericFacets() {
    let facets = Facets.parse(tags: ["status:wip", "plain"])
    #expect(facets.byKey["status"] == ["wip"])
    #expect(facets.freeform == ["plain"])
}

@Test func parseTreatsBareColonAndEmptyValueAsFreeform() {
    let facets = Facets.parse(tags: [":leading", "type:"])
    #expect(facets.freeform.contains(":leading"))
    #expect(facets.freeform.contains("type:"))
    #expect(facets.types.isEmpty)
}

@Test func matchesIsCaseInsensitive() {
    let facets = Facets.parse(tags: ["type:Decision"])
    #expect(facets.matches(.type, "decision"))
}

@Test func memoryFacetsConvenienceFoldsSource() {
    let memory = Memory(content: "x", tags: ["type:howto"], source: "engram")
    #expect(memory.facets.matches(.project, "engram"))
    #expect(memory.facets.types == ["howto"])
}
