import Testing
@testable import SongGraph

@Suite struct LineageTests {
    @Test func ancestorsWalkParentsNearestFirst() throws {
        let g = try Fixtures.graph()
        #expect(g.song.ancestors(of: g.melody1.id).isEmpty)
        #expect(g.song.ancestors(of: g.melody2.id).map(\.id) == [g.melody1.id])
        // progression2's parents are progression1 and melody2; both lead back to melody1.
        let ancestors = g.song.ancestors(of: g.progression2.id).map(\.id)
        #expect(ancestors == [g.progression1.id, g.melody2.id, g.melody1.id])
        let deep = g.song.ancestors(of: g.progression3.id).map(\.id)
        #expect(deep == [g.progression2.id, g.progression1.id, g.melody2.id, g.melody1.id])
    }

    @Test func descendantsWalkChildren() throws {
        let g = try Fixtures.graph()
        let fromMelody1 = Set(g.song.descendants(of: g.melody1.id).map(\.id))
        #expect(fromMelody1 == [g.melody2.id, g.progression1.id, g.progression2.id, g.progression3.id])
        #expect(g.song.descendants(of: g.melody2.id).map(\.id) == [g.progression2.id, g.progression3.id])
        #expect(g.song.descendants(of: g.progression3.id).isEmpty)
    }

    @Test func rootsAndLeaves() throws {
        let g = try Fixtures.graph()
        let lineage = g.song.lineage
        #expect(lineage.roots.map(\.id) == [g.melody1.id])
        #expect(lineage.roots(of: g.progression3.id).map(\.id) == [g.melody1.id])
        #expect(lineage.roots(of: g.melody1.id).map(\.id) == [g.melody1.id])
        #expect(Set(lineage.leaves.map(\.id)) == [g.progression3.id])
    }

    @Test func sectionSubgraphReachesTheSeed() throws {
        let g = try Fixtures.graph()
        let subgraph = try g.song.subgraph(feeding: g.section)
        #expect(subgraph.seeds.map(\.id) == [g.seed.id])
        #expect(subgraph.stitch.map(\.id) == [g.melody2.id, g.progression2.id])
        #expect(subgraph.versionIDs == [g.melody1.id, g.melody2.id, g.progression1.id, g.progression2.id])
        #expect(!subgraph.versionIDs.contains(g.progression3.id))
        #expect(subgraph.partIDs == [g.melody1.partID, g.progression1.partID])
        // Song order is preserved.
        #expect(subgraph.versions.map(\.id) == [g.melody1.id, g.melody2.id, g.progression1.id, g.progression2.id])
        #expect(try g.song.subgraph(feedingSection: g.section.id) == subgraph)
    }

    @Test func experimentSubgraphIncludesTheProposedReharm() throws {
        let g = try Fixtures.graph()
        let subgraph = try g.song.subgraph(feeding: g.experiment)
        #expect(subgraph.stitch.map(\.id) == [g.melody2.id, g.progression3.id])
        #expect(subgraph.versionIDs.contains(g.progression3.id))
        #expect(subgraph.seeds.map(\.id) == [g.seed.id])
        #expect(try g.song.subgraph(feedingExperiment: g.experiment.id) == subgraph)
        let section = g.experiment.stitched(lengthInBars: 8)
        #expect(section.stitch == g.experiment.versions)
        #expect(section.name == "reharm verse")
    }

    @Test func unknownReferencesAreTypedErrors() throws {
        let g = try Fixtures.graph()
        let stray = VersionID()
        #expect(throws: SongGraphError.unknownVersion(stray)) { try g.song.subgraph(feeding: [stray]) }
        let section = SectionID()
        #expect(throws: SongGraphError.unknownSection(section)) { try g.song.subgraph(feedingSection: section) }
        let experiment = ExperimentID()
        #expect(throws: SongGraphError.unknownExperiment(experiment)) { try g.song.subgraph(feedingExperiment: experiment) }
    }

    @Test func usageQueries() throws {
        let g = try Fixtures.graph()
        #expect(g.song.sections(using: g.progression2.id).map(\.id) == [g.section.id])
        #expect(g.song.sections(using: g.progression3.id).isEmpty)
        #expect(g.song.experiments(using: g.progression3.id).map(\.id) == [g.experiment.id])
        #expect(g.song.looseEnds.map(\.id) == [g.progression3.id])
        #expect(g.song.versions(of: g.progression1.partID).map(\.id) == [g.progression1.id, g.progression2.id, g.progression3.id])
        #expect(g.song.latestVersion(of: g.melody1.partID)?.id == g.melody2.id)
        #expect(g.song.partIDs == [g.melody1.partID, g.progression1.partID])
    }
}
