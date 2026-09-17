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
    public static func toolbox(workbench: DirectorWorkbench,
                               workspace: any DirectorWorkspace,
                               audition: (any DirectorAudition)? = nil) -> DirectorToolbox {
        DirectorToolbox([
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
        ])
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
}
