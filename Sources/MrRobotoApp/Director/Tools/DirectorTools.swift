import Foundation

/// The app's whole tool surface, assembled.
///
/// The order below is the order the tools go out in, and it is the order of the work: a record
/// comes in, gets read, gets separated, gets cut, gets classified, meets a feel, gets played, gets
/// recorded. Keeping it in that order is not decoration — it is the list the model reads top to
/// bottom, and it is the byte sequence at position 0 of every request in the session.
///
/// **Adding a tool:** append it. Inserting one in the middle, renaming one, or reordering the list
/// changes the cached prefix for every session in the field, and `DirectorToolboxTests` will say
/// so. That is the point of the test.
public enum DirectorTools {
    /// - Parameters:
    ///   - stage: the frame, when there is one. Given, the two surface tools are **appended** to
    ///     the list — never inserted — so the fifteen schemas before them keep their bytes and a
    ///     session that started without a frame and one that started with it share a cached prefix
    ///     up to the fifteenth tool. Nil is the tool layer on its own, which is how every tool
    ///     test runs.
    ///   - persona: who signs a version the model names nobody for. Nil is the Director itself.
    ///     It reaches `create_part_version` and `degrade_part` only, and only their `run`: no schema reads it, so a
    ///     persona-scoped session and the Director's own share every byte of the frozen prefix.
    public static func toolbox(workbench: DirectorWorkbench,
                               workspace: any DirectorWorkspace,
                               audition: (any DirectorAudition)? = nil,
                               stage: (any DirectorStage)? = nil,
                               pad: DirectorStagePad? = nil,
                               persona: String? = nil,
                               cast: Cast = .standard) -> DirectorToolbox {
        var tools: [AnyDirectorTool] = [
            ReadSongTool(workspace: workspace).erased(),
            ImportRecordTool(workbench: workbench, workspace: workspace).erased(),
            AnalyseRecordTool(workbench: workbench).erased(),
            ListBarsTool(workbench: workbench).erased(),
            SeparateStemsTool(workbench: workbench).erased(),
            ChopBarTool(workbench: workbench).erased(),
            ClassifySlicesTool(workbench: workbench).erased(),
            ListFeelsTool(workbench: workbench).erased(),
            DescribeFeelTool(workbench: workbench).erased(),
            RegrooveChopTool(workbench: workbench).erased(),
            SetSwingTool(workbench: workbench).erased(),
            SetVelocityTool(workbench: workbench).erased(),
            AuditionTool(workbench: workbench, audition: audition).erased(),
            CreatePartVersionTool(workbench: workbench, workspace: workspace,
                                  acting: persona ?? CreatePartVersionTool.director).erased(),
            // Appended after the fourteen, never among them: every schema above keeps its bytes.
            DegradePartTool(workbench: workbench, workspace: workspace,
                            acting: persona ?? CreatePartVersionTool.director).erased(),
            // M2, appended after the fifteen: the band's first written parts.
            SetProgressionTool(workspace: workspace, acting: persona ?? CreatePartVersionTool.director).erased(),
            WriteBasslineTool(workspace: workspace).erased(),
            // M2's Gate C, appended after the seventeen: the form.
            StitchSectionTool(workspace: workspace).erased(),
            ArrangeTool(workspace: workspace).erased(),
            // M3, appended after the nineteen: the library, and two things becoming one.
            ReadLibraryTool(workspace: workspace).erased(),
            AdoptTool(workspace: workspace).erased(),
            MergeTool(workspace: workspace).erased(),
            // M4, appended after the twenty-two: the room, read and convened.
            CastTool(workspace: workspace, cast: cast).erased(),
            ConveneTool(workspace: workspace, cast: cast).erased(),
            // M5, appended after the twenty-four: a take read in cents and milliseconds.
            ReadTakeTool(workspace: workspace).erased(),
            // M6, appended after the twenty-five: the mix read, one strip moved, the master set.
            ReadMixTool(workspace: workspace).erased(),
            SetMixTool(workspace: workspace).erased(),
            MasterTool(workspace: workspace).erased(),
            ExportTool(workspace: workspace).erased(),
            // M7, appended after the twenty-nine: the record read, put in order, released.
            ReadAlbumTool(workspace: workspace).erased(),
            SequenceTool(workspace: workspace).erased(),
            ReleaseTool(workspace: workspace).erased(),
            // Mashup, appended after the thirty-two: two songs on one grid, planned and made.
            PlanMashupTool(workspace: workspace).erased(),
            MashupTool(workspace: workspace).erased(),
            // From an idea, appended after the thirty-four: a song with nothing imported, a beat written.
            StartSongTool(workspace: workspace).erased(),
            WriteGrooveTool(workbench: workbench, workspace: workspace).erased(),
            // Writing, appended after the thirty-six: a tune and words in the Melodist's and the
            // Lyricist's names, the song's settings, an instrument, the takes comped, another song.
            WriteMelodyTool(workspace: workspace).erased(),
            WriteLyricsTool(workspace: workspace).erased(),
            SetSongTool(workspace: workspace).erased(),
            SetInstrumentTool(workspace: workspace).erased(),
            CompTakesTool(workspace: workspace, acting: persona ?? CreatePartVersionTool.director).erased(),
            OpenSongTool(workspace: workspace).erased(),
        ]
        if let stage {
            let pad = pad ?? DirectorStagePad()
            tools.append(OpenSurfaceTool(stage: stage, pad: pad).erased())
            tools.append(ProposeTool(stage: stage, pad: pad).erased())
        }
        return DirectorToolbox(tools)
    }

    /// The names, in order. Written down separately so a test can assert the list rather than
    /// re-derive it from the thing it is testing.
    public static let names = [
        "read_song",
        "import_record",
        "analyse_record",
        "list_bars",
        "separate_stems",
        "chop_bar",
        "classify_slices",
        "list_feels",
        "describe_feel",
        "regroove_chop",
        "set_swing",
        "set_velocity",
        "audition",
        "create_part_version",
        // The fifteenth, appended: dust written onto the chop or groove it dirties.
        "degrade_part",
        // M2, appended: harmony as a lead sheet says it, and a bass line in a named player's hands.
        "set_progression",
        "write_bassline",
        // M2's Gate C, appended: one section with what it plays, and the whole form in a line.
        "stitch_section",
        "arrange",
        // M3, appended: the library read, an item adopted, and two fragments merged.
        "read_library",
        "adopt",
        "merge",
        // M4, appended: who is in the room, and the room convened on a question.
        "cast",
        "convene",
        // M5, appended: a take, read.
        "read_take",
        // M6, appended: the Engineer's hands.
        "read_mix",
        "set_mix",
        "master",
        "export",
        // M7, appended: the record.
        "read_album",
        "sequence",
        "release",
        // Mashup, appended.
        "plan_mashup",
        "mashup",
        // From an idea, appended.
        "start_song",
        "write_groove",
        // Writing, appended: the tune and the words, the song's settings, an instrument, a comp, another song.
        "write_melody",
        "write_lyrics",
        "set_song",
        "set_instrument",
        "comp_takes",
        "open_song",
    ]

    /// The two the frame adds. Appended after `names`, never among them: a session with no frame
    /// (a tool test, a headless run) and a session with one share every byte up to here.
    public static let stageNames = ["open_surface", "propose"]

    /// The whole list a running app sends.
    public static var allNames: [String] { names + stageNames }
}
