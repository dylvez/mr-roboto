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

    /// Records for the crate: any number of audio files, and whether their stems are separated
    /// too. The choice is remembered. Nil when the panel is cancelled.
    static func chooseRecords(defaults: UserDefaults = .standard) -> (files: [URL], separating: Bool)? {
        let key = "crate.separates"
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Records for the crate. Each is copied into the library and read for its key, tempo and bars, in the background; no song is made."
        panel.prompt = "Import"
        let separates = NSButton(checkboxWithTitle: "Separate their stems too", target: nil, action: nil)
        separates.state = (defaults.object(forKey: key) as? Bool ?? true) ? .on : .off
        panel.accessoryView = separates
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        defaults.set(separates.state == .on, forKey: key)
        return (panel.urls, separates.state == .on)
    }

    /// An image for an album's cover.
    static func chooseImage() -> URL? {
        choose(types: [.png, .jpeg, .heic, .tiff], message: "An image for the cover. Square reads best; it is copied into the library.", prompt: "Use as Cover")
    }

    /// An SFZ pack's instrument file.
    static func chooseSFZ(message: String = "An SFZ instrument. Its samples are copied into the library; the pack is left where it is.") -> URL? {
        choose(types: [UTType(filenameExtension: "sfz") ?? .data], message: message, prompt: "Import")
    }

    /// A folder: VCSL's checkout, for its hand percussion.
    static func chooseFolder(message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
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
