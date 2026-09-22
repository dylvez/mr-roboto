/// The parent/child graph over a set of part versions, for ancestry and descent queries.
public struct Lineage: Sendable {
    private let byID: [VersionID: PartVersion]
    private let children: [VersionID: [VersionID]]
    private let order: [VersionID: Int]

    /// Builds the graph from versions; later duplicates of an id are ignored.
    public init(_ versions: [PartVersion]) {
        var byID: [VersionID: PartVersion] = [:]
        var children: [VersionID: [VersionID]] = [:]
        var order: [VersionID: Int] = [:]
        for (index, version) in versions.enumerated() where byID[version.id] == nil {
            byID[version.id] = version
            order[version.id] = index
            for parent in version.parents { children[parent, default: []].append(version.id) }
        }
        self.byID = byID
        self.children = children
        self.order = order
    }

    public var versions: [PartVersion] { byID.values.sorted { order[$0.id, default: 0] < order[$1.id, default: 0] } }

    public func version(_ id: VersionID) -> PartVersion? { byID[id] }
    public func contains(_ id: VersionID) -> Bool { byID[id] != nil }

    /// Parents that are in the graph.
    public func parents(of id: VersionID) -> [PartVersion] { byID[id]?.parents.compactMap { byID[$0] } ?? [] }

    /// Direct children, in insertion order.
    public func children(of id: VersionID) -> [PartVersion] { (children[id] ?? []).compactMap { byID[$0] } }

    /// Every version this one descends from, nearest first (breadth-first), excluding itself.
    /// Parents outside the graph are skipped.
    public func ancestors(of id: VersionID) -> [PartVersion] {
        walk(from: id) { byID[$0]?.parents ?? [] }
    }

    /// Every version made from this one, directly or indirectly, nearest first (breadth-first), excluding itself.
    public func descendants(of id: VersionID) -> [PartVersion] {
        walk(from: id) { children[$0] ?? [] }
    }

    /// Ancestors with no parents in the graph: the versions everything else was made from.
    public func roots(of id: VersionID) -> [PartVersion] {
        let found = ancestors(of: id).filter { $0.parents.allSatisfy { byID[$0] == nil } }
        if found.isEmpty, let version = byID[id], version.parents.allSatisfy({ byID[$0] == nil }) { return [version] }
        return found
    }

    /// Versions with no parents in the graph.
    public var roots: [PartVersion] { versions.filter { $0.parents.allSatisfy { byID[$0] == nil } } }

    /// Versions nothing was made from.
    public var leaves: [PartVersion] { versions.filter { (children[$0.id] ?? []).isEmpty } }

    private func walk(from start: VersionID, next: (VersionID) -> [VersionID]) -> [PartVersion] {
        var seen: Set<VersionID> = [start]
        var queue = next(start)
        var result: [PartVersion] = []
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard seen.insert(id).inserted, let version = byID[id] else { continue }
            result.append(version)
            queue.append(contentsOf: next(id))
        }
        return result
    }
}

/// Everything feeding a section or experiment: the seeds, the parts, and every version along the way,
/// ending in the versions it stitches.
public struct LineageSubgraph: Hashable, Sendable {
    /// Seeds any version in the subgraph grew from, in song order.
    public var seeds: [Seed]
    /// Parts touched by the subgraph, in order of first appearance.
    public var partIDs: [PartID]
    /// Every version in the subgraph (ancestors plus the stitched versions), in song order.
    public var versions: [PartVersion]
    /// The versions the section or experiment uses directly.
    public var stitch: [PartVersion]

    public init(seeds: [Seed], partIDs: [PartID], versions: [PartVersion], stitch: [PartVersion]) {
        self.seeds = seeds
        self.partIDs = partIDs
        self.versions = versions
        self.stitch = stitch
    }

    public var versionIDs: Set<VersionID> { Set(versions.map(\.id)) }
}

extension Song {
    public var lineage: Lineage { Lineage(versions) }

    /// Every version `id` descends from, nearest first.
    public func ancestors(of id: VersionID) -> [PartVersion] { lineage.ancestors(of: id) }

    /// Every version made from `id`, nearest first.
    public func descendants(of id: VersionID) -> [PartVersion] { lineage.descendants(of: id) }

    /// The subgraph feeding these versions: seeds → parts → versions → stitch. Throws for versions not in the song.
    public func subgraph(feeding stitch: [VersionID]) throws -> LineageSubgraph {
        let graph = lineage
        var stitched: [PartVersion] = []
        for id in stitch {
            guard let version = graph.version(id) else { throw SongGraphError.unknownVersion(id) }
            stitched.append(version)
        }
        var included = Set(stitch)
        for id in stitch { included.formUnion(graph.ancestors(of: id).map(\.id)) }
        let ordered = versions.filter { included.contains($0.id) }
        let seedIDs = Set(ordered.compactMap(\.origin))
        var seenParts = Set<PartID>()
        return LineageSubgraph(
            seeds: seeds.filter { seedIDs.contains($0.id) },
            partIDs: ordered.compactMap { seenParts.insert($0.partID).inserted ? $0.partID : nil },
            versions: ordered,
            stitch: stitched
        )
    }

    /// The subgraph feeding a section: what each of its lanes plays right now.
    public func subgraph(feeding section: Section) throws -> LineageSubgraph {
        try subgraph(feeding: versions(playing: section).map(\.id))
    }

    /// The subgraph feeding a section by id.
    public func subgraph(feedingSection id: SectionID) throws -> LineageSubgraph {
        guard let section = section(id) else { throw SongGraphError.unknownSection(id) }
        return try subgraph(feeding: section)
    }

    /// The subgraph an experiment would stitch.
    public func subgraph(feeding experiment: Experiment) throws -> LineageSubgraph {
        try subgraph(feeding: experiment.versions)
    }

    /// The subgraph an experiment would stitch, by id.
    public func subgraph(feedingExperiment id: ExperimentID) throws -> LineageSubgraph {
        guard let experiment = experiment(id) else { throw SongGraphError.unknownExperiment(id) }
        return try subgraph(feeding: experiment)
    }

    /// Sections that play a version right now — its own part's lane, resolved.
    ///
    /// A section naming the part plays whatever is newest, so this answers about the version that
    /// is *sounding*, not about a name written down once. It used to be the same question because
    /// a stitch held version ids; it is the more useful one now.
    public func sections(using id: VersionID) -> [Section] {
        sections.filter { section in versions(playing: section).contains { $0.id == id } }
    }

    /// Experiments that propose a version.
    public func experiments(using id: VersionID) -> [Experiment] { experiments.filter { $0.versions.contains(id) } }

    /// Versions no section plays and no other version was made from.
    ///
    /// What a lane *resolves to*, not what part it names. For a following lane those are the same
    /// thing — the part's newest version is the leaf — but a pinned lane holds an older one, and
    /// then the leaf above it really is loose: made, and played by nothing.
    public var looseEnds: [PartVersion] {
        let playing = Set(sections.flatMap { versions(playing: $0) }.map(\.id))
        return lineage.leaves.filter { !playing.contains($0.id) }
    }
}
