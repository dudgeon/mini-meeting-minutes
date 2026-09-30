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

    /// A recording someone already had, being transcribed instead of a live meeting.
    struct Recording: Sendable {
        let name: String
        let length: TimeInterval
        /// How many times faster than it plays it's being read, once that's known.
        var speed: Double?
    }

    /// The list of microphones to choose from, while it's open.
    struct MicrophonePicker: Sendable {
        struct Option: Sendable, Equatable {
            /// Nil follows the Mac's default input, whatever it is.
            let uid: String?
            let name: String
        }

        var options: [Option]
        var selected = 0

        /// The Mac's default first, then each microphone connected now.
        static func current(chosen: String?) -> MicrophonePicker {
            let devices = AudioDevices.inputs()
            let current = devices.first { $0.isDefault }
            let fallback = current.map { "The Mac's default (\($0.name))" } ?? "The Mac's default"
            let options = [Option(uid: nil, name: fallback)] + devices.map { Option(uid: $0.uid, name: $0.name) }
            return MicrophonePicker(options: options, selected: options.firstIndex { $0.uid == chosen } ?? 0)
        }
    }

    /// Minutes saved at the end of a meeting, shown until the next one or quitting.
    struct Saved: Sendable {
        let path: String
        let turns: Int
        let speakers: Int
        /// The full path went on the clipboard, to paste wherever it's wanted next.
        var copied = false
    }

    struct Snapshot: Sendable {
        var title = ""
        /// When recording began; nil while waiting for Space.
        var startedAt: Date?
        /// Asking whether everyone taking part knows about the recording and agrees.
        var askingConsent = false
        /// When the person recording confirmed it.
        var consentedAt: Date?
        var saved: Saved?
        var elapsed: TimeInterval = 0
        var paused = false
        var stopping = false
        var finished = false
        var channels: Set<Channel> = []
        /// Set when transcribing a recording rather than recording a meeting.
        var recording: Recording?
        /// The Mac's Open window is up, to choose a recording.
        var choosingRecording = false
        /// A microphone can be chosen: a live meeting that listens to the room.
        var microphoneChoosable = false
        /// The microphone chosen, by Core Audio ID; nil follows the Mac's default input.
        var microphoneChoice: String?
        /// The list of microphones, while it's open.
        var microphones: MicrophonePicker?
        /// No microphone was found at the start; one connected later will be used.
        var awaitingMicrophone = false
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
        /// A passing message, such as why a dropped file can't be transcribed; cleared on starting.
        var notice: String?
        /// A brief confirmation ("Copied…"), shown until `flashUntil`.
        var flash: String?
        var flashUntil: Date?
        var outputPath = ""
        /// What's being blanked out.
        var redaction: Set<PIICategory> = []
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
    var started: Bool { startedAt != nil }

    /// What to point out above the prompt: the newest warning, else a confirmation, else a notice.
    var message: String? { warnings.last ?? flash ?? notice }

    /// Shows a brief confirmation for a few seconds.
    mutating func confirm(_ text: String, now: Date = Date()) {
        flash = text
        flashUntil = now.addingTimeInterval(5)
    }

    /// Clears a confirmation whose time is up; the screen checks as it draws.
    mutating func fadeConfirmation(now: Date = Date()) {
        guard let until = flashUntil, until <= now else { return }
        flash = nil
        flashUntil = nil
    }

    /// The minutes as they'd be saved at this moment; nil before recording starts.
    func minutes(inProgress: Bool = true) -> MinutesDocument? {
        guard let startedAt else { return nil }
        return MinutesDocument(
            title: title, startDate: startedAt, duration: elapsed, sources: sources, redaction: redaction,
            echoCancellation: echoCancellation, turns: turns, names: names, notes: notes,
            consentConfirmedAt: consentedAt, inProgress: inProgress,
            recording: recording.map { MinutesDocument.Recording(name: $0.name, length: $0.length) })
    }

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
