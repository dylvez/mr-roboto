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
    ///     the list — never inserted — so the fourteen schemas before them keep their bytes and a
    ///     session that started without a frame and one that started with it share a cached prefix
    ///     up to the fourteenth tool. Nil is the tool layer on its own, which is how every tool
    ///     test runs.
    public static func toolbox(workbench: DirectorWorkbench,
                               workspace: any DirectorWorkspace,
                               audition: (any DirectorAudition)? = nil,
                               stage: (any DirectorStage)? = nil,
                               pad: DirectorStagePad? = nil) -> DirectorToolbox {
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
            CreatePartVersionTool(workbench: workbench, workspace: workspace).erased(),
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
    ]

    /// The two the frame adds. Appended after `names`, never among them: a session with no frame
    /// (a tool test, a headless run) and a session with one share every byte up to here.
    public static let stageNames = ["open_surface", "propose"]

    /// The whole list a running app sends.
    public static var allNames: [String] { names + stageNames }
}
