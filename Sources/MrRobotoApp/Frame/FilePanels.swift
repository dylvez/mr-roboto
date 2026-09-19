import AppKit
import UniformTypeIdentifiers

/// The open dialogs behind every place a file can also be dropped: a drop is a shortcut, never
/// the only way in.
@MainActor
enum FilePanels {
    /// An audio file to import as a record.
    static func chooseAudio() -> URL? {
        choose(types: [.audio], message: "An audio file becomes a song package: key, tempo, bars, sections and a take.", prompt: "Import")
    }

    /// An image for an album's cover.
    static func chooseImage() -> URL? {
        choose(types: [.png, .jpeg, .heic, .tiff], message: "An image for the cover. Square reads best; it is copied into the library.", prompt: "Use as Cover")
    }

    private static func choose(types: [UTType], message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}
