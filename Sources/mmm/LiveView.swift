import Foundation
import MinutesCore
import Synchronization

/// Everything the live screen shows, updated from capture callbacks, the session and the keyboard.
final class LiveState: Sendable {
    struct Naming: Sendable {
        var speakers: [SpeakerID]
        var selected = 0
        /// The end-of-meeting dialog; closing it finishes the recording.
        var final = false
    }

    /// A note being typed.
    struct NoteDraft: Sendable {
        var text = ""
        /// When typing began: where the note goes in the transcript.
        var start: TimeInterval?
    }

    struct Snapshot: Sendable {
        var title = ""
        var elapsed: TimeInterval = 0
        var paused = false
        var stopping = false
        var finished = false
        var channels: Set<Channel> = []
        var levels: [Channel: Float] = [:]
        /// The newest ~128 ms of each channel's audio, for the visualizer only.
        var recent: [Channel: [Float]] = [:]
        /// Seconds of audio held for diarization, per channel.
        var buffered: [Channel: Double] = [:]
        var sources: [Channel: String] = [:]
        var turns: [Turn] = []
        var pending: [Channel: String] = [:]
        var names: [SpeakerID: String] = [:]
        var notes: [Note] = []
        var draft: NoteDraft?
        var warnings: [String] = []
        var outputPath = ""
        var redaction = true
        var echoCancellation = false
        var look = Look.sidebar
        var visualizer = VisualizerMode.spectrum
        /// `elapsed` when the minutes file was last brought up to date.
        var savedAt: TimeInterval?
        /// Rows scrolled back from the newest transcript line; 0 follows along.
        var scroll = 0
        var maxScroll = 0
        var help = false
        var naming: Naming?
        /// Clickable areas of the last frame drawn.
        var regions: [HitRegion] = []
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

    /// Keeps the newest samples of a channel for the visualizer.
    func listen(_ channel: Channel, _ samples: [Float], level: Float) {
        let keep = SpectrumAnalyzer.fftSize * 2
        update { snapshot in
            snapshot.levels[channel] = level
            var recent = snapshot.recent[channel] ?? []
            recent.append(contentsOf: samples.suffix(keep))
            if recent.count > keep { recent.removeFirst(recent.count - keep) }
            snapshot.recent[channel] = recent
        }
    }

    func apply(_ update: ChannelUpdate) {
        self.update { snapshot in
            switch update {
            case .pending(let channel, let text):
                snapshot.pending[channel] = text
            case .turns(let turns):
                snapshot.turns += turns
            case .buffered(let channel, let seconds):
                snapshot.buffered[channel] = seconds
            }
        }
    }
}

extension LiveState.Snapshot {
    /// Adds the note being typed, if it has any words, and closes it. Returns whether a note was
    /// added.
    mutating func addDraft() -> Bool {
        guard let draft else { return false }
        self.draft = nil
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        notes.append(Note(time: draft.start ?? elapsed, text: text))
        return true
    }
}

/// Helpers shared by the screen and the plain prompts.
enum LiveView {
    /// A 256-color code per speaker, for plain (non-full-screen) output.
    static func color(for speaker: SpeakerID) -> Int {
        let palette = speaker.channel == .room ? Style.roomColors : Style.remoteColors
        return palette[(speaker.number - 1) % palette.count]
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Shortens a path to `width` characters: first to just its file name, then that name's end.
    static func fit(_ path: String, _ width: Int) -> String {
        guard path.count > width else { return path }
        let name = "…/" + (path as NSString).lastPathComponent
        return name.count <= width ? name : "…" + name.suffix(max(width - 1, 0))
    }
}
