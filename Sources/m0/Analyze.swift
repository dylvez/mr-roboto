import Analysis
import ArgumentParser
import Foundation
import MusicTheory

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Key ranges, tempo, bars, sections, instrument presence and loudness of a file.",
        discussion: "Runs the default analysis providers (Music Understanding). Reports are cached on disk per file; pass --no-cache to analyse again."
    )

    @Argument(help: "Audio file (mp3, m4a, wav, aiff …).")
    var file: String

    @Flag(help: "Print the AnalysisReport as JSON instead of the summary.")
    var json = false

    @Option(help: "Also write the report JSON to this path.")
    var out: String?

    @Flag(name: .customLong("no-cache"), help: "Ignore the cached report and analyse again.")
    var noCache = false

    func run() async throws {
        let url = try resolveInputFile(file)
        let watch = Stopwatch()
        let (report, cached) = try await analysisReport(for: url, useCache: !noCache)
        let wall = watch.elapsed

        if let out {
            let target = fileURL(out)
            try report.write(to: target)
            note("wrote \(target.path)")
        }
        if json {
            print(try report.jsonString())
            return
        }
        print(AnalysisSummary.render(report, cached: cached, wall: wall))
    }
}

/// The readable form of a report: one block per capability, times as m:ss.mmm.
enum AnalysisSummary {
    static func render(_ report: AnalysisReport, cached: Bool, wall: Double) -> String {
        var lines: [String] = []
        let duration = report.duration.map { secondsText($0, 2) } ?? "unknown length"
        lines.append("\(report.sourceURL.lastPathComponent)  \(duration)")

        if let key = report.key {
            let dominant = key.dominantKey?.name ?? "unknown"
            lines.append("key       \(dominant)" + (key.isStable ? "" : "  (\(key.ranges.count) ranges)"))
            for range in key.ranges {
                lines.append("          \(timestamp(range.start))–\(timestamp(range.end))  \(range.key.name)")
            }
        } else {
            lines.append("key       not analysed")
        }

        if let beats = report.beats {
            let grid = beats.grid
            let bpm = beats.bpm.map { String(format: "%.1f", $0) } ?? grid.bpm.map { String(format: "%.1f (from beat spacing)", $0) } ?? "?"
            lines.append("tempo     \(bpm) bpm, \(grid.timeSignature)")
            var counts = "beats     \(beats.beats.count) beats, \(beats.downbeats.count) bars"
            if let first = beats.beats.first { counts += "  first beat \(timestamp(first))" }
            if let firstBar = beats.downbeats.first { counts += ", first bar \(timestamp(firstBar))" }
            if let end = grid.endOfLastBar { counts += ", last bar ends \(timestamp(end))" }
            lines.append(counts)
        } else {
            lines.append("beats     not analysed")
        }

        if let structure = report.structure {
            lines.append("sections  \(structure.sections.count) sections, \(structure.segments.count) segments, \(structure.phrases.count) phrases")
            for (index, section) in structure.sections.enumerated() {
                var text = String(format: "          %2d  %@–%@  (%.1f s)", index + 1, timestamp(section.start), timestamp(section.end), section.duration)
                if let grid = report.beatGrid, let bar = grid.barIndex(at: section.start + 1e-3) {
                    text += "  from bar \(bar)"
                }
                lines.append(text)
            }
        } else {
            lines.append("sections  not analysed")
        }

        if let instruments = report.instruments {
            let parts = Instrument.allCases.map { instrument -> String in
                let ranges = instruments.presence[instrument] ?? []
                if ranges.isEmpty { return "\(instrument) absent" }
                return String(format: "%@ %.0f s in %d range%@", instrument.rawValue, instruments.presentDuration(of: instrument),
                              ranges.count, ranges.count == 1 ? "" : "s")
            }
            lines.append("instruments  " + parts.joined(separator: "; "))
        } else {
            lines.append("instruments  not analysed")
        }

        if let loudness = report.loudness {
            var text = String(format: "loudness  %.1f LUFS integrated, peak %.1f dB", loudness.integrated, loudness.truePeak)
            if let range = loudness.range { text += String(format: ", range %.1f LU", range) }
            lines.append(text)
        } else {
            lines.append("loudness  not analysed")
        }

        let providers = report.provenance.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        lines.append("providers \(providers)")
        if cached {
            lines.append(String(format: "time      cached report (analysed in %.1f s on %@); loaded in %.2f s",
                                report.wallTime, report.analyzedAt.formatted(date: .abbreviated, time: .shortened), wall))
        } else {
            lines.append(String(format: "time      analysis %.1f s, wall %.1f s", report.wallTime, wall))
        }
        for line in report.notes { lines.append("note      \(line)") }
        return lines.joined(separator: "\n")
    }
}
