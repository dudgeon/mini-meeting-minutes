import Foundation
import MinutesCore
import Synchronization

/// Everything the live screen shows, updated from capture callbacks and the session.
final class LiveState: Sendable {
    struct Snapshot {
        var elapsed: TimeInterval = 0
        var paused = false
        var stopping = false
        var finished = false
        var levels: [Channel: Float] = [:]
        var sources: [Channel: String] = [:]
        var turns: [Turn] = []
        var pending: [Channel: String] = [:]
        var warnings: [String] = []
        var outputPath = ""
        var redaction = true
        var echoCancellation = false
    }

    private let state = Mutex(Snapshot())

    func update(_ change: (inout Snapshot) -> Void) {
        state.withLock { change(&$0) }
    }

    var snapshot: Snapshot { state.withLock { $0 } }

    func warn(_ message: String) {
        update { snapshot in
            if !snapshot.warnings.contains(message) { snapshot.warnings.append(message) }
        }
    }

    func apply(_ update: ChannelUpdate) {
        self.update { snapshot in
            switch update {
            case .pending(let channel, let text):
                snapshot.pending[channel] = text
            case .turns(let turns):
                snapshot.turns += turns
            }
        }
    }
}

/// Renders the live screen: a status header, the most recent transcript, and key hints.
enum LiveView {
    static func render(_ state: LiveState.Snapshot, columns: Int, rows: Int) -> String {
        let width = max(columns, 40)
        var header: [String] = []

        let recording =
            state.finished
            ? Style.green("■ done")
            : state.stopping
                ? Style.yellow("■ finishing")
                : state.paused ? Style.yellow("❚❚ paused") : Style.red("●") + " recording"
        let flags = [
            state.redaction ? "redaction on" : "redaction off",
            state.echoCancellation ? "echo cancel on" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        header.append(
            " " + Style.bold("mini-meeting-minutes") + "  \(recording)  "
                + MinutesDocument.timestamp(state.elapsed) + "   " + Style.dim(flags))

        var meters: [String] = []
        for channel in Channel.allCases {
            guard let source = state.sources[channel] else { continue }
            let label = channel == .room ? "mic" : "system"
            meters.append("\(label) \(meter(state.levels[channel] ?? 0))  \(Style.dim(source))")
        }
        header.append(" " + meters.joined(separator: "    "))
        header.append(Style.dim(String(repeating: "─", count: width)))

        var footer: [String] = [Style.dim(String(repeating: "─", count: width))]
        for warning in state.warnings.suffix(3) {
            footer.append(contentsOf: warning.wrapped(to: width - 3).enumerated().map { index, line in
                (index == 0 ? " " + Style.yellow("!") + " " : "   ") + line
            })
        }
        let hint =
            state.finished
            ? "Speaker labels are final. Next, name the speakers."
            : state.stopping
                ? "Finishing: attributing the last words and checking every speaker…"
                : Style.bold("p") + " pause  " + Style.bold("q") + " stop & save"
        let room = width - 1 - "Saving to ".count - 3 - hint.visibleWidth
        let saving = room >= 12 ? Style.dim("Saving to " + fit(abbreviate(state.outputPath), room)) + "   " : ""
        footer.append(" " + saving + hint)

        let available = max(rows - header.count - footer.count, 1)
        let body = transcriptLines(state, width: width).suffix(available)
        let padding = Array(repeating: "", count: available - body.count)

        return (header + padding + body + footer).map { $0.truncated(toVisibleWidth: width) + "\u{1B}[K" }
            .joined(separator: "\n")
    }

    /// Shortens a path to `width` characters: first to just its file name, then that name's end.
    static func fit(_ path: String, _ width: Int) -> String {
        guard path.count > width else { return path }
        let name = "…/" + (path as NSString).lastPathComponent
        return name.count <= width ? name : "…" + name.suffix(max(width - 1, 0))
    }

    private static func transcriptLines(_ state: LiveState.Snapshot, width: Int) -> [String] {
        let nameWidth = max(
            10, (state.turns.map { $0.speaker.description.count } + [8]).max() ?? 8)
        let indent = 1 + 8 + 2 + nameWidth + 2
        let textWidth = max(width - indent - 1, 20)
        var lines: [String] = []

        var previous: SpeakerID?
        for turn in state.turns.sorted(by: { $0.start < $1.start }).suffix(200) {
            let wrapped = turn.text.wrapped(to: textWidth)
            let name = turn.speaker == previous ? "" : turn.speaker.description
            let colored = Style.color(name.padding(toLength: nameWidth, withPad: " ", startingAt: 0), color(for: turn.speaker))
            let time = turn.speaker == previous ? String(repeating: " ", count: 8) : MinutesDocument.timestamp(turn.start)
            lines.append(" " + Style.dim(time) + "  " + Style.bold(colored) + "  " + (wrapped.first ?? ""))
            for line in wrapped.dropFirst() { lines.append(String(repeating: " ", count: indent) + line) }
            previous = turn.speaker
        }

        for channel in Channel.allCases {
            guard let text = state.pending[channel], !text.isEmpty else { continue }
            let label = "\(channel.label) …".padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let wrapped = text.wrapped(to: textWidth)
            lines.append(" " + String(repeating: " ", count: 8) + "  " + Style.dim(label) + "  " + Style.dim(wrapped.first ?? ""))
            for line in wrapped.dropFirst() { lines.append(String(repeating: " ", count: indent) + Style.dim(line)) }
        }
        if lines.isEmpty {
            lines.append(Style.dim(" Listening. Speech appears here as it's transcribed; speaker labels follow within about 30 seconds."))
        }
        return lines
    }

    static func color(for speaker: SpeakerID) -> Int {
        let palette = speaker.channel == .room ? Style.roomColors : Style.remoteColors
        return palette[(speaker.number - 1) % palette.count]
    }

    /// Eight-step bar for an RMS level, spanning -60 to 0 dBFS.
    static func meter(_ rms: Float) -> String {
        let steps = Array("▁▂▃▄▅▆▇█")
        let decibels = 20 * log10(max(rms, 1e-6))
        let filled = Int(((decibels + 60) / 60 * 8).rounded())
        let bar = (0..<8).map { $0 < filled ? String(steps[$0]) : " " }.joined()
        return filled > 0 ? Style.green(bar) : Style.dim("·" + String(repeating: " ", count: 7))
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
