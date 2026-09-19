import SwiftUI

/// One screen: what the take is for, the button, the level, the last captures with a way to
/// share each — AirDrop to the Mac and the inbox takes it by its name.
struct CaptureView: View {
    @State private var recorder = Recorder()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                target
                button
                level
                captures
                Spacer(minLength: 0)
                if let error = recorder.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
                }
            }
            .padding(.top, 16)
            .navigationTitle("Roboto Capture")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var target: some View {
        VStack(spacing: 8) {
            TextField("Song (empty for an idea)", text: $recorder.song)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            TextField("Section (verse, hook…)", text: $recorder.section)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Text(recorder.song.isEmpty ? "This will land in the library as an idea."
                 : "Take \(recorder.nextPass) of \(recorder.section.isEmpty ? "the song" : recorder.section) on \(recorder.song).")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var button: some View {
        Button {
            Task { await recorder.toggle() }
        } label: {
            ZStack {
                Circle().fill(recorder.isRecording ? Color.red : Color.red.opacity(0.85)).frame(width: 128, height: 128)
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 8).fill(.white).frame(width: 44, height: 44)
                } else {
                    Circle().fill(.white).frame(width: 52, height: 52)
                }
            }
            .shadow(radius: recorder.isRecording ? 12 : 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Stop" : "Record")
    }

    private var level: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(recorder.level > 0.9 ? Color.red : Color.accentColor)
                        .frame(width: geometry.size.width * CGFloat(recorder.level))
                }
            }
            .frame(height: 10)
            Text(recorder.isRecording ? String(format: "%.1f s", recorder.seconds) : "Ready")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }

    private var captures: some View {
        List {
            Section("Captures") {
                if recorder.captures.isEmpty {
                    Text("None yet. Press the button, sing, press it again; then share the take to your Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(recorder.captures.prefix(6)) { capture in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capture.title).font(.body)
                            Text(String(format: "%.1f s · %@", capture.seconds, capture.stamp))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: capture.url) { Image(systemName: "square.and.arrow.up") }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { recorder.delete(capture) } }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
