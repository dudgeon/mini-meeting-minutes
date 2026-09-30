import Foundation
import MinutesCore

/// The default recording screen, in the style of Claude's apps: a quiet sidebar (status,
/// speakers, what's being heard, privacy, keys) beside a transcript that reads like a
/// conversation, with a prompt-style box underneath. Narrow windows drop the sidebar.
struct SidebarView {
    enum Palette {
        static let background = RGB(0x191918)
        static let side = RGB(0x222220)
        static let text = RGB(0xECEBE7)
        static let dim = RGB(0x9A9893)
        static let quiet = RGB(0x62605A)
        static let rule = RGB(0x3A3935)
        static let accent = RGB(0xD97757)
        static let green = RGB(0x8FB37A)
        static let amber = RGB(0xE5B567)
        static let live = RGB(0x2A2825)
        static let note = RGB(0x33312D)
        static let tokenText = RGB(0xF2C4AE)
        static let tokenBackground = RGB(0x3B2A22)
        static let room = [RGB(0xE08A6A), RGB(0xB89BD9), RGB(0x8FB37A), RGB(0xD98AB0)]
        static let remote = [RGB(0x6FB3B8), RGB(0xD9B25F), RGB(0x8AA6E0), RGB(0xC9A27A)]
    }

    private static let eighths = Array("▁▂▃▄▅▆▇█")

    let model: ScreenModel
    let analyzers: [Channel: SpectrumAnalyzer]
    /// Seconds since the screen started, for animation.
    let time: Double
    /// Seconds since the previous frame, for the visualizers' motion.
    let frameInterval: Double
    var canvas: Canvas
    /// Transcript rows that can be scrolled back.
    private(set) var maxScroll = 0

    private var state: LiveState.Snapshot { model.state }
    private var width: Int { canvas.width }
    private var height: Int { canvas.height }

    static func render(
        _ state: LiveState.Snapshot, analyzers: [Channel: SpectrumAnalyzer], width: Int, height: Int, time: Double,
        frameInterval: Double
    ) -> (canvas: Canvas, maxScroll: Int) {
        var view = SidebarView(
            model: ScreenModel(state), analyzers: analyzers, time: time, frameInterval: frameInterval,
            canvas: Canvas(width: width, height: height, background: Palette.background))
        guard width >= 50, height >= 12 else {
            view.drawTooSmall()
            return (view.canvas, 0)
        }
        let sidebar = width >= 84 && height >= 20 ? (width >= 110 ? 32 : 28) : 0
        if sidebar > 0 { view.drawSidebar(width: sidebar) }
        view.drawMain(x: sidebar > 0 ? sidebar + 2 : 2, withSidebar: sidebar > 0)
        return (view.canvas, view.maxScroll)
    }

    static func color(for speaker: SpeakerID) -> RGB {
        let palette = speaker.channel == .room ? Palette.room : Palette.remote
        return palette[max(speaker.number - 1, 0) % palette.count]
    }

    /// The recording status as a symbol, its color, and a word.
    private var status: (symbol: String, color: RGB, label: String) {
        if state.saved != nil { return ("✓", Palette.green, "Saved") }
        if !state.started && !state.stopping { return ("○", Palette.dim, "Ready") }
        if state.finished { return ("✓", Palette.green, "Done") }
        if state.stopping { return (String(ScreenModel.spinner(time)), Palette.accent, "Finishing") }
        if state.paused { return ("❚❚", Palette.amber, "Paused") }
        // A slow pulse shows it's live without blinking.
        let pulse = Palette.side.mixed(with: Palette.accent, 0.85 + 0.15 * sin(time * 3))
        return state.recording == nil ? ("●", pulse, "Recording") : ("▶", pulse, "Transcribing")
    }

    private var keyList: [(key: String, label: String, action: ScreenAction?)] {
        if state.saved != nil {
            return [
                ("space", "new recording", .newMeeting), ("o", "open a recording", .openRecording),
                ("return", "open minutes", .open), ("c", "copy the path", .copyPath),
                ("t", "copy the transcript", .copyTranscript), ("r", "show in Finder", .reveal), ("q", "quit", .quit),
            ]
        }
        if state.askingConsent {
            return state.recording == nil
                ? [("y", "yes, start", .consent), ("n", "not yet", .decline)]
                : [("y", "yes, transcribe", .consent), ("n", "not now", .decline)]
        }
        if let draft = state.draft {
            return Command.isCommand(draft.text)
                ? [("return", "run it", nil), ("tab", "complete it", nil), ("esc", "cancel", nil)]
                : [("return", "add the note", nil), ("esc", "cancel", nil)]
        }
        if state.finished || state.stopping { return [("↑↓", "scroll", .follow), ("k", "synthwave", .skin)] }
        if !state.started {
            return [("space", "start recording", .pause), ("o", "open a recording", .openRecording)]
                + (state.microphoneChoosable ? [("m", "microphone", .chooseMicrophone)] : [])
                + [("q", "quit", .stop), ("k", "synthwave", .skin), ("?", "all shortcuts", .help)]
        }
        // During a meeting, typing takes notes, so commands start with a slash. Space still pauses:
        // a note never starts with one.
        return [
            ("space", state.paused ? "resume" : "pause", .pause), ("/stop", "stop and save", .stop),
            ("/name", "name speakers", .name),
        ] + (state.microphoneChoosable ? [("/mic", "microphone", .chooseMicrophone)] : [])
            + [
                ("/copy", "copy transcript", .copyTranscript), ("/look", "synthwave", .skin),
                ("/help", "all commands", .help),
            ]
    }

    // MARK: - Sidebar

    private mutating func drawSidebar(width w: Int) {
        let bg = Palette.side
        canvas.fill(0, 0, w, height, bg: bg)
        canvas.put(2, 1, "✻", fg: Palette.accent, bg: bg)
        canvas.text(4, 1, "mmm", fg: Palette.text, bg: bg, bold: true)
        if w >= 30 { canvas.text(8, 1, "mini meeting minutes", fg: Palette.dim, bg: bg) }
        let current = status
        canvas.text(2, 3, current.symbol, fg: current.color, bg: bg)
        canvas.text(3 + current.symbol.count, 3, current.label, fg: Palette.text, bg: bg, bold: true)
        canvas.text(w - 2 - model.clock.count, 3, model.clock, fg: Palette.text, bg: bg, bold: true)
        canvas.region(0, 3, w, 1, .pause)
        canvas.text(4, 4, state.title.clipped(w - 6), fg: Palette.dim, bg: bg)
        if state.recording != nil { drawProgress(y: 5, width: w) }

        // Keys sit at the bottom, in the same place whichever keys apply. The other sections fill
        // down from the top; in a short window speakers get one row each, then privacy and
        // listening make way.
        let keysTop = height - 8
        heading("KEYS", y: keysTop)
        for (index, key) in keyList.enumerated() {
            let y = keysTop + 1 + index
            canvas.text(4, y, key.key, fg: Palette.accent, bg: bg)
            canvas.text(11, y, key.label, fg: Palette.dim, bg: bg, limit: w - 12)
            if let action = key.action { canvas.region(0, y, w, 1, action) }
        }

        let top = 7
        let available = keysTop - 1 - top
        let privacyRows = state.channels.count == 2 || state.recording != nil ? 5 : 4
        // A heading, a row per source (and one for the microphone's name), then a gap.
        let listeningRows = state.recording != nil ? 3 : state.microphoneChoosable ? 5 : 4
        let speakers = model.talk.count
        var perSpeaker = 2
        var listening = true
        var privacy = true
        func others() -> Int { (listening ? listeningRows : 0) + (privacy ? privacyRows + 1 : 0) }
        func needed() -> Int { 1 + max(1, speakers * perSpeaker) + others() }
        if needed() > available { perSpeaker = 1 }
        if needed() > available { privacy = false }
        if needed() > available { listening = false }
        let rows = max(1, min(max(1, speakers * perSpeaker), available - 1 - others()))
        drawSpeakers(top: top, rows: rows, perSpeaker: perSpeaker, width: w)
        var y = top + 1 + rows + 1
        if listening {
            drawListening(top: y, width: w)
            y += listeningRows
        }
        if privacy { drawPrivacy(top: y, width: w) }
    }

    /// How much of a recording has been read: a bar, and the share done.
    private mutating func drawProgress(y: Int, width w: Int) {
        let bg = Palette.side
        let done = model.progress ?? 0
        let percent = "\(Int((done * 100).rounded(.down)))%"
        let bar = max(4, w - 7 - percent.count)
        let filled = Int((done * Double(bar)).rounded())
        for cell in 0..<bar {
            let done = cell < filled
            canvas.put(4 + cell, y, done ? "━" : "─", fg: done ? Palette.accent : Palette.rule, bg: bg)
        }
        canvas.text(w - 2 - percent.count, y, percent, fg: Palette.dim, bg: bg)
    }

    private mutating func heading(_ title: String, y: Int) {
        canvas.text(2, y, title, fg: Palette.dim, bg: Palette.side, bold: true)
    }

    private mutating func drawSpeakers(top: Int, rows: Int, perSpeaker: Int, width w: Int) {
        let bg = Palette.side
        heading("SPEAKERS", y: top)
        guard !model.talk.isEmpty else {
            canvas.text(4, top + 1, "No one yet", fg: Palette.dim, bg: bg)
            return
        }
        let fits = max(1, rows / perSpeaker)
        let shown = model.talk.count <= fits ? model.talk : Array(model.talk.prefix(fits - 1))
        let most = model.talk.map(\.seconds).max() ?? 0
        var y = top + 1
        for talk in shown {
            let color = Self.color(for: talk.speaker)
            let percent = "\(Int((model.share(of: talk) * 100).rounded()))%"
            canvas.put(2, y, "●", fg: color, bg: bg)
            canvas.text(4, y, model.name(of: talk.speaker).clipped(w - 8 - percent.count), fg: Palette.text, bg: bg)
            canvas.text(w - 2 - percent.count, y, percent, fg: Palette.dim, bg: bg)
            canvas.region(0, y, w, perSpeaker, .name)
            if perSpeaker == 2 {
                let bar = w - 6
                let filled = most > 0 ? Int((talk.seconds / most * Double(bar)).rounded()) : 0
                for cell in 0..<bar {
                    canvas.put(4 + cell, y + 1, cell < filled ? "━" : "─", fg: cell < filled ? color : Palette.rule, bg: bg)
                }
            }
            y += perSpeaker
        }
        if shown.count < model.talk.count {
            canvas.text(4, y, "+\(model.talk.count - shown.count) more", fg: Palette.dim, bg: bg)
        }
    }

    private mutating func drawListening(top: Int, width w: Int) {
        heading("LISTENING TO", y: top)
        let rows: [(Channel, String)] =
            state.recording == nil ? [(.room, "mic"), (.remote, "system")] : [(.room, "file")]
        var y = top + 1
        for (channel, label) in rows {
            canvas.text(4, y, label, fg: Palette.text, bg: Palette.side)
            drawLevels(channel, x: 12, y: y, width: w - 15)
            canvas.region(0, y, w, 1, .visualizer)
            y += 1
            if channel == .room && state.microphoneChoosable {
                // Which microphone it is; a click chooses another.
                let name = state.sources[.room] ?? (state.awaitingMicrophone ? "none connected yet" : "…")
                canvas.text(6, y, name.clipped(w - 8), fg: Palette.dim, bg: Palette.side)
                canvas.region(0, y, w, 1, .chooseMicrophone)
                y += 1
            }
        }
    }

    /// One channel's visualizer, in one row: spectrum bars, a braille waveform, or a level meter.
    private mutating func drawLevels(_ channel: Channel, x: Int, y: Int, width w: Int) {
        let bg = Palette.side
        guard w > 0 else { return }
        guard state.channels.contains(channel) else {
            let waiting = channel == .room && state.awaitingMicrophone
            canvas.text(x, y, waiting ? "none connected" : "off", fg: Palette.quiet, bg: bg, limit: w)
            return
        }
        let ink = model.listening ? Palette.accent : Palette.quiet
        switch state.visualizer {
        case .spectrum:
            guard let analyzer = analyzers[channel] else { return }
            analyzer.update(samples: model.recent(channel), bars: w, elapsed: frameInterval)
            for bar in 0..<w {
                let level = min(8, Int((analyzer.levels[bar] * 8).rounded()))
                canvas.put(x + bar, y, Self.eighths[max(level - 1, 0)], fg: level > 0 ? ink : Palette.rule, bg: bg)
            }
        case .scope:
            let trace = ScreenModel.braille(ScreenModel.waveform(model.recent(channel), count: w * 2))
            canvas.text(x, y, trace, fg: ink, bg: bg)
        case .off:
            let filled = Int((model.meter(channel) * Double(w)).rounded())
            for cell in 0..<w {
                canvas.put(x + cell, y, cell < filled ? "━" : "─", fg: cell < filled ? ink : Palette.rule, bg: bg)
            }
        }
    }

    private mutating func drawPrivacy(top: Int, width w: Int) {
        let bg = Palette.side
        heading("PRIVACY", y: top)
        var checks = [(true, "no audio saved")]
        checks.append(
            state.redaction.isEmpty
                ? (false, "redaction is off")
                : (true, state.redaction.contains(.name) ? "names and numbers hidden" : "sensitive numbers hidden"))
        if state.channels.count == 2 {
            checks.append(state.echoCancellation ? (true, "speaker echo removed") : (false, "echo removal is off"))
        }
        if state.recording != nil { checks.append((true, "the recording is only read")) }
        for (index, check) in checks.enumerated() {
            let y = top + 1 + index
            canvas.put(2, y, check.0 ? "✓" : "○", fg: check.0 ? Palette.green : Palette.amber, bg: bg)
            canvas.text(4, y, check.1, fg: check.0 ? Palette.text : Palette.dim, bg: bg, limit: w - 5)
        }
        canvas.text(
            4, top + 1 + checks.count, "\(model.heldAudio)s of audio in memory", fg: Palette.dim, bg: bg, limit: w - 5)
    }

    // MARK: - Main pane

    private mutating func drawMain(x: Int, withSidebar: Bool) {
        let w = width - x - 1
        let saved = model.savedStatus
        if withSidebar {
            let file = model.file
            let nameX = x + 1 + file.folder.count + 3
            canvas.text(x + 1, 1, file.folder, fg: Palette.dim)
            canvas.put(nameX - 2, 1, "›", fg: Palette.quiet)
            let name = state.started ? file.name : "a new file, once you start"
            canvas.text(
                nameX, 1, name.clipped(x + w - saved.count - 2 - nameX), fg: state.started ? Palette.text : Palette.quiet)
        } else {
            drawCompactStatus(x: x, room: w - saved.count - 2)
        }
        canvas.text(x + w - saved.count, 1, saved, fg: Palette.dim)
        for column in x..<(x + w) { canvas.put(column, 2, "─", fg: Palette.rule) }

        // The bottom: a panel (the prompt box, naming or shortcuts) with a line of hints under it.
        let panelBottom = height - 2
        var panelTop = panelBottom - 2
        if let naming = state.naming {
            let visible = min(naming.speakers.count, max(1, height - 14))
            panelTop = panelBottom - visible - 1
            drawNaming(naming, x: x, top: panelTop, width: w, visible: visible)
            hint(
                naming.final
                    ? "type a name · return for the next · esc when you're done"
                    : "type a name · return next · ↑↓ move · esc done · the same name twice combines them",
                x: x, width: w)
        } else if let picker = state.microphones {
            let visible = min(picker.options.count, max(1, height - 14))
            panelTop = panelBottom - visible - 1
            drawMicrophones(picker, x: x, top: panelTop, width: w, visible: visible)
            hint("↑↓ move · return or a number chooses · esc keeps the one in use", x: x, width: w)
        } else if let saved = state.saved {
            panelTop = panelBottom - 3
            drawSaved(saved, x: x, top: panelTop, width: w)
            hint(
                "return open the minutes · c copy the path · t copy the transcript · space new recording", x: x,
                width: w)
        } else if state.askingConsent {
            let text = state.recording == nil ? Self.consentText : Self.recordingConsentText
            let lines =
                text.wrapped(to: max(20, w - 6)).map { ($0, Palette.text) } + [("", Palette.text)]
                + Self.policyText.wrapped(to: max(20, w - 6)).map { ($0, Palette.dim) }
            panelTop = max(4, panelBottom - lines.count - 3)
            drawConsent(lines, x: x, top: panelTop, width: w)
            hint(
                state.recording == nil
                    ? "y yes, everyone has agreed: start recording · n not yet"
                    : "y yes, everyone in it agreed: transcribe it · n not now", x: x, width: w)
        } else if state.help {
            let rows = ScreenModel.shortcuts(switchingTo: "synthwave")
            let visible = min(rows.count + 1, max(1, height - 12))
            panelTop = panelBottom - visible - 1
            drawHelp(rows, x: x, top: panelTop, width: w, visible: visible)
            hint("press any key to close", x: x, width: w)
        } else if let draft = state.draft {
            let lines = draft.text.isEmpty ? [""] : draft.text.wrapped(to: max(10, w - 7))
            let visible = min(lines.count, 4)
            panelTop = panelBottom - visible - 1
            drawDraft(
                draft, lines: Array(lines.suffix(visible)), scrolled: lines.count > visible, x: x, top: panelTop,
                width: w)
            if Command.isCommand(draft.text) {
                let matches = Command.matching(draft.text)
                if !matches.isEmpty && panelTop - matches.count - 2 > 5 {
                    panelTop -= matches.count + 2
                    drawCommands(matches, chosen: Command.chosen(draft.text), x: x, top: panelTop, width: w)
                }
                hint(
                    Command.chosen(draft.text).map { "return runs /\($0.rawValue) · tab completes · esc cancels" }
                        ?? (matches.isEmpty
                            ? "no such command · esc clears it" : "keep typing to choose one · tab completes"),
                    x: x, width: w)
            } else {
                let time = ScreenModel.shortTime(draft.start ?? state.elapsed)
                hint("return adds the note at \(time) · esc cancels", x: x, width: w)
            }
        } else {
            drawPrompt(x: x, top: panelTop, width: w)
            if !withSidebar { drawKeyHints(x: x, width: w) }
        }

        var transcriptBottom = panelTop - 2
        if let warning = state.message {
            let lines = Array(warning.wrapped(to: max(10, w - 4)).prefix(3))
            let top = panelTop - 1 - lines.count
            canvas.put(x + 1, top, "!", fg: Palette.amber, bold: true)
            for (index, line) in lines.enumerated() {
                canvas.text(x + 3, top + index, line, fg: Palette.amber)
            }
            transcriptBottom = top - 2
        }
        drawTranscript(x: x, top: 4, bottom: transcriptBottom, width: w)
    }

    /// The status, clock and title on one line, for windows too narrow for the sidebar.
    private mutating func drawCompactStatus(x: Int, room: Int) {
        let current = status
        canvas.put(x + 1, 1, "✻", fg: Palette.accent)
        var column = x + 3
        canvas.text(column, 1, current.symbol, fg: current.color)
        column += current.symbol.count + 1
        canvas.text(column, 1, current.label, fg: Palette.text, bold: true)
        column += current.label.count + 2
        canvas.text(column, 1, model.clock, fg: Palette.text, bold: true)
        column += model.clock.count + 2
        if let done = model.progress {
            let percent = "\(Int((done * 100).rounded(.down)))%"
            canvas.text(column, 1, percent, fg: Palette.accent)
            column += percent.count + 2
        }
        canvas.region(x, 1, column - x, 1, .pause)
        canvas.text(column, 1, state.title.clipped(x + room - column), fg: Palette.dim)
    }

    private mutating func hint(_ text: String, x: Int, width w: Int) {
        canvas.text(x + 1, height - 1, text, fg: Palette.dim, limit: w - 1)
    }

    private mutating func drawKeyHints(x: Int, width w: Int) {
        var column = x + 1
        let keys: [(key: String, label: String, action: ScreenAction?)] =
            state.finished
            ? keyList
            : !state.started
                ? [
                    ("space", "start", .pause), ("o", "open", .openRecording), ("m", "mic", .chooseMicrophone),
                    ("q", "quit", .stop), ("k", "synthwave", .skin), ("?", "help", .help),
                ]
                : [
                ("space", state.paused ? "resume" : "pause", .pause), ("/stop", "stop", .stop),
                ("/name", "name", .name), ("/look", "synthwave", .skin), ("/help", "help", .help),
            ]
        for key in keys {
            let span = key.key.count + 1 + key.label.count
            guard column + span <= x + w else { break }
            canvas.text(column, height - 1, key.key, fg: Palette.accent)
            canvas.text(column + key.key.count + 1, height - 1, key.label, fg: Palette.dim)
            if let action = key.action { canvas.region(column, height - 1, span, 1, action) }
            column += span + 3
        }
    }

    private mutating func drawPrompt(x: Int, top: Int, width w: Int) {
        canvas.box(x, top, w, 3, border: Palette.rule)
        let y = top + 1
        if state.finished {
            canvas.put(x + 2, y, "✓", fg: Palette.green)
            canvas.text(x + 4, y, "Done. The minutes are saved when this screen closes.", fg: Palette.text, limit: w - 6)
        } else if state.stopping {
            canvas.put(x + 2, y, ScreenModel.spinner(time), fg: Palette.accent)
            canvas.text(
                x + 4, y, "Finishing up: placing the last words and checking every speaker…", fg: Palette.text,
                limit: w - 6)
        } else if state.choosingRecording {
            canvas.put(x + 2, y, ScreenModel.spinner(time), fg: Palette.accent)
            canvas.text(x + 4, y, "Choose a recording in the window that opened…", fg: Palette.text, limit: w - 6)
        } else if !state.started {
            let quit = "q to quit"
            canvas.put(x + 2, y, ">", fg: Palette.text)
            canvas.text(x + 4, y, "Press space to start recording".clipped(w - 8 - quit.count), fg: Palette.text, bold: true)
            canvas.text(x + w - 2 - quit.count, y, quit, fg: Palette.quiet)
            canvas.region(x, top, w, 3, .pause)
        } else if state.paused {
            canvas.text(x + 2, y, "❚❚", fg: Palette.amber)
            canvas.text(
                x + 5, y,
                state.recording == nil
                    ? "Paused: nothing is being recorded. Press space to carry on, or type a note."
                    : "Paused. Press space to carry on transcribing.", fg: Palette.amber, limit: w - 7)
            canvas.region(x, top, w, 3, .note)
        } else {
            var placeholder =
                state.recording == nil
                ? "Type a note, or / for commands" : "\(model.reading) · type a note, or / for commands"
            if let speaker = model.newestUnnamed { placeholder += " · /name to name \(speaker.description)" }
            let stop = "/stop to finish"
            canvas.put(x + 2, y, ">", fg: Palette.text)
            canvas.text(x + 4, y, placeholder.clipped(w - 8 - stop.count), fg: Palette.quiet)
            canvas.text(x + w - 2 - stop.count, y, stop, fg: Palette.quiet)
            canvas.region(x, top, w, 3, .note)
        }
    }

    static let consentText =
        "Everyone taking part, in the room and on the call, must know this conversation is being recorded "
        + "and transcribed, and agree to it. In some places, including California, recording without everyone's "
        + "consent is against the law, and that covers a transcript too, even though no audio is kept. Tell "
        + "anyone who joins later, too."

    /// The same question, for a recording made before.
    static let recordingConsentText =
        "Everyone in this recording must have known they were being recorded, and agreed to it. In some places, "
        + "including California, recording without everyone's consent is against the law, and so can be using "
        + "that recording, a transcript of it included."

    /// Shown with both questions: the app is for focused sessions, not every meeting.
    static let policyText =
        "Your company's policy may prohibit recording routine meetings by default. Mini Meeting Minutes is "
        + "intended for targeted use: focused sessions where everyone has agreed to a transcript, such as user "
        + "research or stakeholder interviews. Please consult your risk advisors before using it."

    /// The question before recording, in place of the prompt box: what the law asks, then what
    /// the app is for (dimmer), then the question.
    private mutating func drawConsent(_ lines: [(text: String, color: RGB)], x: Int, top: Int, width w: Int) {
        let height = height - 1 - top
        let recording = state.recording != nil
        canvas.box(
            x, top, w, height, border: Palette.accent, fill: Palette.background,
            title: recording ? "Before you transcribe" : "Before you record", titleColor: Palette.text)
        for (index, line) in lines.prefix(height - 4).enumerated() {
            canvas.text(x + 3, top + 1 + index, line.text, fg: line.color)
        }
        let y = top + height - 2
        let question = recording ? "Did everyone in it know, and agree?" : "Has everyone been told, and agreed?"
        canvas.text(x + 3, y, question, fg: Palette.text, bold: true, limit: w - 6)
        var column = x + 3 + question.count + 3
        let answers =
            recording
            ? [("y", "yes, transcribe it", ScreenAction.consent), ("n", "not now", .decline)]
            : [("y", "yes, start recording", ScreenAction.consent), ("n", "not yet", .decline)]
        for (key, label, action) in answers {
            guard column + key.count + label.count + 1 < x + w - 1 else { break }
            canvas.text(column, y, key, fg: Palette.accent, bold: true)
            canvas.text(column + key.count + 1, y, label, fg: Palette.dim)
            canvas.region(column, y, key.count + 1 + label.count, 1, action)
            column += key.count + label.count + 4
        }
    }

    /// Where the minutes went, in place of the prompt box, once they're saved.
    private mutating func drawSaved(_ saved: LiveState.Saved, x: Int, top: Int, width w: Int) {
        canvas.box(
            x, top, w, 3, border: Palette.green, fill: Palette.background,
            title: saved.copied ? "Saved · path copied to the clipboard" : "Saved", titleColor: Palette.text)
        let file = URL(fileURLWithPath: saved.path)
        let place = file.deletingLastPathComponent().lastPathComponent + " › " + file.lastPathComponent
        let counts = "\(saved.turns) turns · \(saved.speakers) speakers"
        canvas.put(x + 2, top + 1, "✓", fg: Palette.green)
        canvas.text(x + 4, top + 1, place.clipped(w - 8 - counts.count), fg: Palette.text)
        canvas.text(x + w - 2 - counts.count, top + 1, counts, fg: Palette.dim)
        canvas.region(x, top, w, 3, .open)
    }

    /// The commands that what's typed could be, above the prompt box; Return runs the chosen one.
    private mutating func drawCommands(_ commands: [Command], chosen: Command?, x: Int, top: Int, width w: Int) {
        canvas.box(x, top, w, commands.count + 2, border: Palette.rule, fill: Palette.background)
        for (index, command) in commands.enumerated() {
            let y = top + 1 + index
            let picked = command == chosen
            if picked { canvas.put(x + 2, y, "❯", fg: Palette.accent, bold: true) }
            canvas.text(x + 4, y, "/" + command.rawValue, fg: picked ? Palette.accent : Palette.text, bold: picked)
            canvas.text(x + 14, y, command.summary, fg: Palette.dim, limit: w - 16)
            canvas.region(x, y, w, 1, command.action)
        }
    }

    /// The prompt box while a note is typed: it grows to four lines, then shows the end.
    private mutating func drawDraft(
        _ draft: LiveState.NoteDraft, lines: [String], scrolled: Bool, x: Int, top: Int, width w: Int
    ) {
        canvas.box(x, top, w, lines.count + 2, border: Palette.accent)
        if !scrolled { canvas.put(x + 2, top + 1, ">", fg: Palette.text) }
        for (index, line) in lines.enumerated() {
            canvas.text(x + 4, top + 1 + index, line, fg: Palette.text)
        }
        let last = lines.last ?? ""
        let cursor = x + 4 + last.count + (draft.text.hasSuffix(" ") && !last.isEmpty ? 1 : 0)
        canvas.put(min(cursor, x + w - 2), top + lines.count, "▍", fg: Palette.accent)
        if draft.text.isEmpty {
            canvas.text(x + 5, top + 1, "Type a note, or / for commands…", fg: Palette.quiet, limit: w - 7)
        }
    }

    private mutating func drawNaming(_ naming: LiveState.Naming, x: Int, top: Int, width w: Int, visible: Int) {
        canvas.box(
            x, top, w, visible + 2, border: Palette.accent, fill: Palette.background, title: "Who was speaking?",
            titleColor: Palette.text)
        let first = max(0, min(naming.selected - visible / 2, naming.speakers.count - visible))
        for row in 0..<visible where naming.speakers.indices.contains(first + row) {
            let index = first + row
            let speaker = naming.speakers[index]
            let selected = index == naming.selected
            let y = top + 1 + row
            if selected { canvas.put(x + 2, y, "❯", fg: Palette.accent, bold: true) }
            canvas.text(x + 4, y, speaker.description, fg: Self.color(for: speaker), bold: true, limit: 11)
            let typed = state.names[speaker] ?? ""
            let field = 22
            canvas.text(x + 16, y, String(typed.suffix(field - 1)), fg: Palette.text, bold: true)
            if selected { canvas.put(x + 16 + min(typed.count, field - 1), y, "▍", fg: Palette.accent) }
            if w >= 60, let quote = model.sample(of: speaker) {
                canvas.text(x + 40, y, ScreenModel.quoted(quote, width: w - 42), fg: Palette.dim)
            }
        }
    }

    /// The microphones to choose from, numbered, with the one in use marked.
    private mutating func drawMicrophones(
        _ picker: LiveState.MicrophonePicker, x: Int, top: Int, width w: Int, visible: Int
    ) {
        canvas.box(
            x, top, w, visible + 2, border: Palette.accent, fill: Palette.background, title: "Microphone",
            titleColor: Palette.text)
        let first = max(0, min(picker.selected - visible / 2, picker.options.count - visible))
        for row in 0..<visible where picker.options.indices.contains(first + row) {
            let index = first + row
            let option = picker.options[index]
            let selected = index == picker.selected
            let y = top + 1 + row
            if selected { canvas.put(x + 2, y, "❯", fg: Palette.accent, bold: true) }
            canvas.text(x + 4, y, "\(index + 1)", fg: Palette.quiet)
            canvas.text(x + 7, y, option.name, fg: selected ? Palette.text : Palette.dim, bold: selected, limit: w - 20)
            if option.uid == state.microphoneChoice { canvas.text(x + w - 11, y, "✓ in use", fg: Palette.green) }
            canvas.region(x, y, w, 1, .microphone(index))
        }
    }

    private mutating func drawHelp(
        _ rows: [(key: String, action: String)], x: Int, top: Int, width w: Int, visible: Int
    ) {
        canvas.box(
            x, top, w, visible + 2, border: Palette.rule, fill: Palette.background, title: "Shortcuts",
            titleColor: Palette.text)
        var lines = rows.map { ($0.key, $0.action, Palette.text) }
        lines.append(("", "Click the keys in the sidebar too. Hold ⌥ Option to select text.", Palette.dim))
        for (index, line) in lines.prefix(visible).enumerated() {
            canvas.text(x + 3, top + 1 + index, line.0, fg: Palette.accent, bold: true)
            canvas.text(x + 11, top + 1 + index, line.1, fg: line.2, limit: w - 13)
        }
    }

    // MARK: - Transcript

    private struct Row {
        enum Kind { case label, text, gap, pad, liveLabel, liveText, note }
        var kind: Kind
        var color = Palette.text
        var text = ""
        var time = ""
        /// False while someone else is being named, so the speaker being named stands out.
        var focused = true
        /// The last line of live text, where the cursor goes.
        var last = false
    }

    private func transcriptRows(textWidth: Int) -> [Row] {
        var rows: [Row] = []
        let focus = state.naming.flatMap { $0.speakers.indices.contains($0.selected) ? $0.speakers[$0.selected] : nil }
        for item in model.timeline {
            switch item {
            case .speech(let entry):
                let color = Self.color(for: entry.speaker)
                let focused = focus == nil || focus == entry.speaker
                rows.append(
                    Row(
                        kind: .label, color: color, text: model.name(of: entry.speaker),
                        time: ScreenModel.shortTime(entry.start), focused: focused))
                for line in entry.text.wrapped(to: textWidth) {
                    rows.append(Row(kind: .text, color: color, text: line, focused: focused))
                }
            case .note(let note):
                // Notes look like your own messages in Claude: after a ">", on a band of their own.
                for (index, line) in note.text.wrapped(to: max(10, textWidth - 8)).enumerated() {
                    rows.append(
                        Row(
                            kind: .note, text: line, time: index == 0 ? ScreenModel.shortTime(note.time) : "",
                            focused: focus == nil))
                }
            }
            rows.append(Row(kind: .gap))
        }
        for pending in model.pending {
            rows.append(Row(kind: .pad))
            rows.append(Row(kind: .liveLabel, text: pending.channel.label))
            let lines = pending.text.wrapped(to: textWidth)
            for (index, line) in lines.enumerated() {
                rows.append(Row(kind: .liveText, text: line, last: index == lines.count - 1))
            }
            rows.append(Row(kind: .pad))
            rows.append(Row(kind: .gap))
        }
        if rows.last?.kind == .gap { rows.removeLast() }
        return rows
    }

    private mutating func drawTranscript(x: Int, top: Int, bottom: Int, width w: Int) {
        let rows = bottom - top + 1
        guard rows > 0 else { return }
        let lines = transcriptRows(textWidth: max(10, w - 5))
        guard !lines.isEmpty else {
            drawEmptyTranscript(x: x, top: top, rows: rows, width: w)
            return
        }
        maxScroll = max(0, lines.count - rows)
        let scroll = min(state.scroll, maxScroll)
        let first = max(0, lines.count - rows - scroll)
        for (offset, line) in lines[first..<min(lines.count, first + rows)].enumerated() {
            draw(line, x: x, y: top + offset, width: w)
        }
        if scroll > 0 {
            let pill = " ↓ newer lines · end "
            canvas.text(x + w - pill.count, bottom, pill, fg: Palette.accent, bg: Palette.live)
            canvas.region(x + w - pill.count, bottom, pill.count, 1, .follow)
        }
    }

    private mutating func draw(_ row: Row, x: Int, y: Int, width w: Int) {
        let bar = row.focused ? row.color : Palette.rule
        switch row.kind {
        case .gap:
            break
        case .label:
            canvas.put(x + 1, y, "▎", fg: bar)
            canvas.text(x + 3, y, row.text.clipped(w - 12), fg: row.focused ? row.color : Palette.quiet, bold: true)
            canvas.text(x + w - row.time.count, y, row.time, fg: Palette.dim)
        case .text:
            canvas.put(x + 1, y, "▎", fg: bar)
            canvas.rich(
                x + 3, y, row.text, fg: row.focused ? Palette.text : Palette.quiet, token: Palette.tokenText,
                tokenBackground: Palette.tokenBackground, limit: w - 4)
        case .pad:
            canvas.fill(x, y, w, 1, bg: Palette.live)
        case .liveLabel:
            canvas.fill(x, y, w, 1, bg: Palette.live)
            canvas.put(x + 1, y, "▎", fg: Palette.accent, bg: Palette.live)
            canvas.text(x + 3, y, row.text, fg: Palette.text, bg: Palette.live, bold: true)
            canvas.text(
                x + 4 + row.text.count, y, "\(ScreenModel.spinner(time)) identifying speaker…", fg: Palette.accent,
                bg: Palette.live, limit: w - 6 - row.text.count)
        case .liveText:
            canvas.fill(x, y, w, 1, bg: Palette.live)
            canvas.put(x + 1, y, "▎", fg: Palette.accent, bg: Palette.live)
            canvas.rich(
                x + 3, y, row.text, fg: Palette.dim, bg: Palette.live, token: Palette.tokenText,
                tokenBackground: Palette.tokenBackground, limit: w - 4)
            if row.last { canvas.put(x + 4 + row.text.count, y, "▍", fg: Palette.accent, bg: Palette.live) }
        case .note:
            let ink = row.focused ? Palette.text : Palette.quiet
            canvas.fill(x, y, w, 1, bg: Palette.note)
            if !row.time.isEmpty {
                canvas.put(x + 1, y, ">", fg: ink, bg: Palette.note)
                canvas.text(x + w - row.time.count, y, row.time, fg: Palette.dim, bg: Palette.note)
            }
            canvas.text(x + 3, y, row.text, fg: ink, bg: Palette.note, limit: w - 12)
        }
    }

    private mutating func drawEmptyTranscript(x: Int, top: Int, rows: Int, width w: Int) {
        let title: String
        let detail: String
        if let recording = state.recording, !state.started && !state.stopping {
            title = "Ready to transcribe"
            detail =
                "“\(recording.name)”, \(ScreenModel.lengthText(recording.length)) long. It's only read: nothing but "
                + "the minutes is saved."
        } else if !state.started && !state.stopping {
            title = "Ready when you are"
            detail =
                "Nothing is recorded until you press space."
                + (width >= 84 ? " The meters under LISTENING TO show what the microphone and the Mac can hear." : "")
                + " To transcribe a recording you already have, like a voice memo, press O or drag it onto this window."
        } else if state.stopping || state.finished {
            title = "Nothing was heard"
            detail = "No speech was picked up in this recording."
        } else if state.paused {
            title = "❚❚ Paused"
            detail = "Press space to start listening again."
        } else if state.recording != nil {
            title = "\(ScreenModel.spinner(time)) Reading the recording"
            detail = "Words appear here as they're recognized, much faster than they were spoken, and who said them "
                + "follows moments later."
        } else {
            title = "\(ScreenModel.spinner(time)) Listening"
            detail = "Words appear here as they're spoken, and who said them follows within about half a minute."
        }
        let y = top + max(0, rows / 2 - 2)
        canvas.text(x + max(0, (w - title.count) / 2), y, title, fg: Palette.accent, bold: true)
        for (index, line) in detail.wrapped(to: max(10, w - 8)).enumerated() where y + 2 + index <= top + rows - 1 {
            canvas.text(x + max(0, (w - line.count) / 2), y + 2 + index, line, fg: Palette.dim)
        }
    }

    // MARK: - Too small

    private mutating func drawTooSmall() {
        let current = status
        let still = ["Recording": "Still recording", "Transcribing": "Still transcribing"]
        let label = still[current.label] ?? current.label
        let lines = ["Make this window bigger", "to see Mini Meeting Minutes.", "", "\(label) · \(model.clock)"]
        let top = max(0, height / 2 - 2)
        for (index, line) in lines.enumerated() {
            canvas.text(
                max(0, (width - line.count) / 2), top + index, line, fg: index == 3 ? Palette.accent : Palette.text,
                bold: index == 3)
        }
    }
}
