import Foundation
import MinutesCore

/// What both looks show, worked out from a snapshot of the live state: the transcript as
/// entries, talk time, names, levels and the like.
struct ScreenModel {
    struct Entry {
        let speaker: SpeakerID
        let start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    struct Talk {
        let speaker: SpeakerID
        let seconds: Double
    }

    enum Item {
        case speech(Entry)
        case note(Note)
    }

    let state: LiveState.Snapshot
    /// Speech and notes in time order. Back-to-back speech by the same person is one entry; a
    /// note typed during it comes right after it.
    let timeline: [Item]
    /// Talk time per speaker, in order of first appearance.
    let talk: [Talk]

    init(_ state: LiveState.Snapshot) {
        self.state = state
        var timeline: [Item] = []
        var order: [SpeakerID] = []
        var seconds: [SpeakerID: Double] = [:]
        let notes = state.notes.sorted { $0.time < $1.time }
        var nextNote = 0
        var held: [Note] = []  // typed during the open entry, which they follow, as in the file
        for turn in state.turns.sorted(by: { $0.start < $1.start }) {
            while nextNote < notes.count && notes[nextNote].time < turn.start {
                held.append(notes[nextNote])
                nextNote += 1
            }
            if seconds[turn.speaker] == nil { order.append(turn.speaker) }
            seconds[turn.speaker, default: 0] += max(turn.end - turn.start, 0)
            if case .speech(var last)? = timeline.last,
                Self.name(of: last.speaker, names: state.names) == Self.name(of: turn.speaker, names: state.names),
                turn.start - last.end < 10
            {
                last.text += " " + turn.text
                last.end = max(last.end, turn.end)
                timeline[timeline.count - 1] = .speech(last)
            } else {
                timeline += held.map { .note($0) }
                held = []
                timeline.append(.speech(Entry(speaker: turn.speaker, start: turn.start, end: turn.end, text: turn.text)))
            }
        }
        timeline += (held + notes[nextNote...]).map { .note($0) }
        self.timeline = timeline
        talk = order.map { Talk(speaker: $0, seconds: seconds[$0] ?? 0) }
    }

    /// The name given to a speaker, or their label, like "Room 1".
    func name(of speaker: SpeakerID) -> String {
        Self.name(of: speaker, names: state.names)
    }

    private static func name(of speaker: SpeakerID, names: [SpeakerID: String]) -> String {
        if let name = names[speaker]?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return speaker.description
    }

    /// A speaker's share of all the talking so far, 0–1.
    func share(of talk: Talk) -> Double {
        talk.seconds / max(self.talk.reduce(0) { $0 + $1.seconds }, 0.001)
    }

    /// The most recent speaker nobody has named yet.
    var newestUnnamed: SpeakerID? {
        talk.last { name(of: $0.speaker) == $0.speaker.description }?.speaker
    }

    /// Speech already transcribed but not yet attributed to a speaker, room first.
    var pending: [(channel: Channel, text: String)] {
        Channel.allCases.compactMap { channel in
            guard let text = state.pending[channel], !text.isEmpty else { return nil }
            return (channel, text)
        }
    }

    /// Something a speaker said, to remind whoever names them who they were.
    func sample(of speaker: SpeakerID) -> String? {
        state.turns.filter { $0.speaker == speaker }.max { $0.text.count < $1.text.count }?.text
    }

    /// True while audio is being captured and transcribed.
    var listening: Bool { !state.paused && !state.stopping && !state.finished }

    /// The newest audio of a channel, for the visualizers. Nothing while paused or finishing,
    /// so they settle.
    func recent(_ channel: Channel) -> [Float] {
        listening ? state.recent[channel] ?? [] : []
    }

    /// A level-meter reading: 0 at −60 dB or quieter, 1 at full scale.
    func meter(_ channel: Channel) -> Double {
        guard listening, state.channels.contains(channel) else { return 0 }
        let decibels = 20 * log10(Double(max(state.levels[channel] ?? 0, 1e-6)))
        return min(1, max(0, (decibels + 60) / 60))
    }

    /// Seconds of audio held in memory until its speakers are worked out.
    var heldAudio: Int { Int((state.buffered.values.max() ?? 0).rounded()) }

    var clock: String { Self.shortTime(state.elapsed) }

    /// How much of a recording has been read, 0–1; nil for a live meeting.
    var progress: Double? {
        guard let recording = state.recording else { return nil }
        return recording.length > 0 ? min(1, max(0, state.elapsed / recording.length)) : 0
    }

    /// What reading a recording is up to: "Transcribing at 24× speed".
    var reading: String {
        guard let speed = state.recording?.speed, speed.isFinite, speed > 0 else { return "Transcribing" }
        return "Transcribing at \(speed >= 10 ? String(Int(speed.rounded())) : String(format: "%.1f", speed))× speed"
    }

    /// The folder and file name the minutes are saved to.
    var file: (folder: String, name: String) {
        let url = URL(fileURLWithPath: state.outputPath)
        return (url.deletingLastPathComponent().lastPathComponent, url.lastPathComponent)
    }

    /// When the minutes on disk were last brought up to date.
    var savedStatus: String {
        guard state.started else { return "" }
        guard let saved = state.savedAt else { return "not saved yet" }
        let ago = Int(max(0, state.elapsed - saved))
        return ago < 10 ? "saved just now" : ago < 60 ? "saved \(ago)s ago" : "saved \(ago / 60) min ago"
    }

    // MARK: - Formatting

    /// "04:05", or "1:02:03" after an hour.
    static func shortTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// A recording's length in words: "58 minutes", "1 hour 5 minutes", "40 seconds".
    static func lengthText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return total == 1 ? "1 second" : "\(total) seconds" }
        let minutes = (total + 30) / 60
        func plural(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s")" }
        guard minutes >= 60 else { return plural(minutes, "minute") }
        return plural(minutes / 60, "hour") + (minutes % 60 == 0 ? "" : " " + plural(minutes % 60, "minute"))
    }

    /// Always hours, minutes and seconds: "00:04:05".
    static func longTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// Claude's spinner: a star that grows and shrinks.
    static func spinner(_ time: Double) -> Character {
        let frames: [Character] = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
        return frames[Int(max(time, 0) * 8) % frames.count]
    }

    /// Text in curly quotes, cut short with an ellipsis to fit `width`.
    static func quoted(_ text: String, width: Int) -> String {
        guard width >= 3 else { return "" }
        return text.count + 2 <= width ? "“\(text)”" : "“\(text.prefix(width - 2))…"
    }

    /// Splits a transcript line into plain runs and redaction placeholders like [NAME].
    static func segments(_ line: String) -> [(text: String, token: Bool)] {
        var result: [(text: String, token: Bool)] = []
        var plain = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "[") {
            plain += rest[..<open]
            let tail = rest[open...]
            if let close = tail.firstIndex(of: "]") {
                let inner = tail[tail.index(after: open)..<close]
                if !inner.isEmpty && inner.allSatisfy(\.isUppercase) {
                    if !plain.isEmpty { result.append((plain, false)) }
                    plain = ""
                    result.append((String(tail[open...close]), true))
                    rest = tail[tail.index(after: close)...]
                    continue
                }
            }
            plain.append("[")
            rest = tail.dropFirst()
        }
        plain += rest
        if !plain.isEmpty { result.append((plain, false)) }
        return result
    }

    /// Every command and key, for the help lists. `other` names the look /look switches to.
    static func shortcuts(switchingTo other: String) -> [(key: String, action: String)] {
        [
            ("space", "start a meeting; during one, pause or resume when no note is being typed (F8 too)"),
            ("type", "during a meeting, a note: return adds it where you started typing, esc drops it"),
            ("/stop", "stop and save the minutes (ctrl-c does too)"),
            ("/name", "name the speakers"),
            ("/look", "switch to \(other)"),
            ("/visual", "visualizer: spectrum, waveform or off"),
            ("tab", "finish typing a command's name"),
            ("↑ ↓", "scroll the transcript, or use the mouse wheel; end jumps back to the newest line"),
            ("o", "before a meeting: transcribe a recording instead (q quits)"),
        ]
    }

    // MARK: - Waveforms

    /// The newest audio as one value per column, −1 to 1, scaled up to fill the height (but
    /// without blowing faint noise up to full size).
    static func waveform(_ samples: [Float], count: Int, samplesPerPoint: Int = 6) -> [Double] {
        guard count > 0 else { return [] }
        let window = Array(samples.suffix(count * max(samplesPerPoint, 1)))
        guard window.count >= count else { return Array(repeating: 0, count: count) }
        let step = window.count / count
        let values = (0..<count).map { column in
            Double(window[(column * step)..<((column + 1) * step)].reduce(0, +)) / Double(step)
        }
        let gain = 0.9 / max(values.map(abs).max() ?? 0, 0.02)
        return values.map { max(-1, min(1, $0 * gain)) }
    }

    /// A waveform drawn in a single row of braille: two points per cell, four dots high, joined
    /// up so the trace is continuous.
    static func braille(_ values: [Double]) -> String {
        let bits = [[0x01, 0x02, 0x04, 0x40], [0x08, 0x10, 0x20, 0x80]]
        let rows = values.map { Int(((1 - $0) / 2 * 3).rounded()) }
        var result = ""
        var previous = rows.first ?? 2
        for cell in 0..<(rows.count / 2) {
            var code = 0
            for side in 0..<2 {
                let row = rows[cell * 2 + side]
                for dot in min(previous, row)...max(previous, row) { code |= bits[side][dot] }
                previous = row
            }
            result.unicodeScalars.append(UnicodeScalar(UInt32(0x2800 + code))!)
        }
        return result
    }
}
