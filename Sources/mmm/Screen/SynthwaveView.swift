import Foundation
import MinutesCore

/// Synthwave mode: a pixel-art sunset over a neon grid, where the city skyline is the live
/// spectrum analyzer (the microphone left of the sun, the call to its right), above a status
/// strip and the transcript.
struct SynthwaveView {
    enum Palette {
        static let night = RGB(0x0D0221)
        static let panel = RGB(0x12032C)
        static let strip = RGB(0x1A0536)
        static let field = RGB(0x08011A)
        static let cyan = RGB(0x00F0FF)
        static let pink = RGB(0xFF2E88)
        static let yellow = RGB(0xFFE45E)
        static let text = RGB(0xF3E9FF)
        static let dim = RGB(0x8A6FB8)
        static let unlit = RGB(0x3A1A66)
        static let note = RGB(0xFFF1A8)
        static let room = [RGB(0xFF2E88), RGB(0xFF9F1C), RGB(0xFF6AD5), RGB(0xFFD166)]
        static let remote = [RGB(0x00F0FF), RGB(0xB18CFF), RGB(0x7CFFCB), RGB(0x8FB8FF)]
    }

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
    private var blink: Bool { Int(time * 2) % 2 == 0 }

    static func render(
        _ state: LiveState.Snapshot, analyzers: [Channel: SpectrumAnalyzer], width: Int, height: Int, time: Double,
        frameInterval: Double
    ) -> (canvas: Canvas, maxScroll: Int) {
        var view = SynthwaveView(
            model: ScreenModel(state), analyzers: analyzers, time: time, frameInterval: frameInterval,
            canvas: Canvas(width: width, height: height, background: Palette.night))
        guard width >= 50, height >= 12 else {
            view.drawTooSmall()
            return (view.canvas, 0)
        }
        // The picture shrinks with the window, and goes when there's only room for words.
        let art = height >= 40 ? 19 : height >= 34 ? 15 : height >= 28 ? 11 : height >= 22 ? 7 : 0
        if art > 0 { view.drawScene(rows: art) }
        view.drawStrip(y: art)
        let footer = height >= 30 ? height - 2 : height - 1
        let warnings = view.warningLines()
        view.drawWarnings(warnings, bottom: footer - 1)
        view.drawTranscript(top: art + (height >= 24 ? 2 : 1), bottom: footer - 2 - warnings.count)
        view.drawFooter(y: footer)
        if state.help { view.drawHelp() }
        if state.askingConsent { view.drawConsent() }
        if let naming = state.naming { view.drawNaming(naming) }
        return (view.canvas, view.maxScroll)
    }

    static func color(for speaker: SpeakerID) -> RGB {
        let palette = speaker.channel == .room ? Palette.room : Palette.remote
        return palette[max(speaker.number - 1, 0) % palette.count]
    }

    // MARK: - Scene and status strip

    private mutating func drawScene(rows: Int) {
        let scene = SynthwaveScene(width: width, height: rows * 2)
        let buildings = scene.buildingsPerSide
        var left: [Double] = []
        var right: [Double] = []
        var waves: [(samples: [Float], color: RGB)] = []
        switch state.visualizer {
        case .spectrum:
            if buildings.left > 0, let analyzer = analyzers[.room] {
                analyzer.update(samples: model.recent(.room), bars: buildings.left, elapsed: frameInterval)
                left = analyzer.levels
            }
            if buildings.right > 0, let analyzer = analyzers[.remote] {
                analyzer.update(samples: model.recent(.remote), bars: buildings.right, elapsed: frameInterval)
                right = analyzer.levels
            }
        case .scope:
            if state.channels.contains(.room) { waves.append((model.recent(.room), Palette.pink)) }
            if state.channels.contains(.remote) { waves.append((model.recent(.remote), Palette.cyan)) }
        case .off:
            break
        }
        let moving = state.visualizer != .off && model.listening
        canvas.draw(scene.draw(time: time, left: left, right: right, waves: waves, moving: moving), x: 0, y: 0)
        canvas.region(0, 0, width, rows, .visualizer)
    }

    private mutating func drawStrip(y: Int) {
        let bg = Palette.strip
        canvas.fill(0, y, width, 1, bg: bg)
        let brand = "MINI MEETING MINUTES"
        let limit = width >= 90 ? width - brand.count - 4 : width - 2
        let (label, color): (String, RGB) =
            state.saved != nil
            ? ("✓ SAVED", Palette.cyan)
            : !state.started && !state.stopping
            ? ("○ READY", Palette.yellow)
            : state.finished
            ? ("■ DONE", Palette.cyan)
            : state.stopping
                ? ("■ FINISHING", blink ? Palette.yellow : Palette.dim)
                : state.paused
                ? ("❚❚ PAUSED", blink ? Palette.yellow : Palette.dim)
                : state.recording == nil ? ("▶ REC", Palette.pink) : ("▶ TRANSCRIBING", Palette.pink)
        canvas.text(2, y, label, fg: color, bg: bg, bold: true)
        canvas.region(2, y, label.count, 1, .pause)
        var x = 2 + label.count + 2
        var clock = ScreenModel.longTime(state.elapsed)
        if let recording = state.recording { clock += " / " + ScreenModel.longTime(recording.length) }
        canvas.text(x, y, clock, fg: Palette.yellow, bg: bg, bold: true)
        x += clock.count + 3
        let meters =
            state.recording == nil
            ? [(Channel.room, "MIC", Palette.pink), (Channel.remote, "SYS", Palette.cyan)]
            : [(Channel.room, "FILE", Palette.pink)]
        for (channel, name, ink) in meters {
            guard x + 14 <= limit else { break }
            canvas.text(x, y, name, fg: Palette.dim, bg: bg)
            let meterX = x + name.count + 1
            if state.channels.contains(channel) {
                let lit = Int((model.meter(channel) * 10).rounded())
                for cell in 0..<10 {
                    canvas.put(meterX + cell, y, cell < lit ? "▮" : "▯", fg: cell < lit ? ink : Palette.unlit, bg: bg)
                }
            } else {
                let waiting = channel == .room && state.awaitingMicrophone
                canvas.text(meterX, y, waiting ? "NONE YET" : "OFF", fg: Palette.unlit, bg: bg)
            }
            x = meterX + 13
        }
        let memory = "\(model.heldAudio)s IN MEMORY"
        if x + memory.count <= limit {
            canvas.text(x, y, memory, fg: Palette.yellow, bg: bg)
            x += memory.count + 3
        }
        var privacy = state.redaction.isEmpty ? "PII ✗" : "PII ✓"
        if state.channels.count == 2 { privacy += state.echoCancellation ? "  ECHO ✓" : "  ECHO ✗" }
        if x + privacy.count <= limit { canvas.text(x, y, privacy, fg: Palette.cyan, bg: bg) }
        if width >= 90 { canvas.text(width - 2 - brand.count, y, brand, fg: Palette.text, bg: bg, bold: true) }
    }

    // MARK: - Transcript

    private struct Row {
        var label = ""
        var labelColor = Palette.dim
        var labelBold = false
        var text = ""
        var live = false
        var cursor = false
        var note = false
    }

    private func transcriptRows(textWidth: Int) -> [Row] {
        var rows: [Row] = []
        for item in model.timeline {
            let (label, color, start, text, note): (String, RGB, TimeInterval, String, Bool)
            switch item {
            case .speech(let entry):
                (label, color, start, text, note) = (
                    model.name(of: entry.speaker).uppercased(), Self.color(for: entry.speaker), entry.start,
                    entry.text, false
                )
            case .note(let written):
                (label, color, start, text, note) = ("✎ NOTE", Palette.yellow, written.time, written.text, true)
            }
            let lines = text.wrapped(to: textWidth)
            for index in 0..<max(lines.count, 2) {
                var row = Row(text: index < lines.count ? lines[index] : "", note: note)
                if index == 0 {
                    (row.label, row.labelColor, row.labelBold) = (label, color, true)
                } else if index == 1 {
                    row.label = ScreenModel.shortTime(start)
                }
                rows.append(row)
            }
            rows.append(Row())
        }
        for pending in model.pending {
            let lines = pending.text.wrapped(to: textWidth)
            for index in 0..<max(lines.count, 2) {
                var row = Row(text: index < lines.count ? lines[index] : "", live: true, cursor: index == lines.count - 1)
                if index == 0 {
                    (row.label, row.labelColor, row.labelBold) = (pending.channel.label.uppercased(), Palette.text, true)
                } else if index == 1 {
                    (row.label, row.labelColor, row.labelBold) = ("LIVE", Palette.pink, true)
                }
                rows.append(row)
            }
            rows.append(Row())
        }
        if let last = rows.last, last.label.isEmpty, last.text.isEmpty { rows.removeLast() }
        return rows
    }

    private mutating func drawTranscript(top: Int, bottom: Int) {
        guard bottom >= top else { return }
        let bg = Palette.panel
        canvas.fill(1, top, width - 2, bottom - top + 1, bg: bg)
        var first = top + 1
        if bottom - top >= 12 {
            // A header: the meeting, and where its minutes go.
            let title = state.title.uppercased().clipped(width / 2 - 4)
            canvas.text(3, top + 1, title, fg: Palette.dim, bg: bg, bold: true)
            let room = width - 8 - title.count
            let path =
                state.saved != nil
                ? "✓ SAVED → " + LiveView.fit(LiveView.abbreviate(state.outputPath), max(room - 10, 0))
                : state.started
                ? "→ " + LiveView.fit(LiveView.abbreviate(state.outputPath), max(room - 2, 0))
                : "A NEW FILE, ONCE YOU START"
            if room > 12 { canvas.text(width - 3 - path.count, top + 1, path, fg: Palette.dim, bg: bg) }
            first = top + 3
        }
        let rows = bottom - 1 - first + 1
        guard rows > 0 else { return }
        let lines = transcriptRows(textWidth: max(10, width - 19))
        guard !lines.isEmpty else {
            let message =
                !state.started && !state.stopping
                ? state.recording.map { "READY TO TRANSCRIBE “\($0.name.uppercased())”" }
                    ?? "PRESS SPACE TO START RECORDING · O TO OPEN A RECORDING"
                : !model.listening
                    ? "NOTHING HEARD YET"
                    : state.recording == nil
                        ? "LISTENING… WORDS APPEAR HERE AS THEY'RE SPOKEN"
                        : "READING THE RECORDING… WORDS APPEAR AS THEY'RE RECOGNIZED"
            canvas.text(
                max(1, (width - message.count) / 2), first + rows / 2, message.clipped(width - 2), fg: Palette.dim,
                bg: bg)
            return
        }
        maxScroll = max(0, lines.count - rows)
        let scroll = min(state.scroll, maxScroll)
        let start = max(0, lines.count - rows - scroll)
        for (offset, row) in lines[start..<min(lines.count, start + rows)].enumerated() {
            draw(row, y: first + offset)
        }
        if scroll > 0 {
            let note = " ▲ SCROLLED BACK · F FOLLOWS "
            canvas.text(width - 3 - note.count, bottom, note, fg: Palette.night, bg: Palette.yellow, bold: true)
            canvas.region(width - 3 - note.count, bottom, note.count, 1, .follow)
        }
    }

    private mutating func draw(_ row: Row, y: Int) {
        let bg = Palette.panel
        if !row.label.isEmpty {
            canvas.text(3, y, row.label.clipped(12), fg: row.labelColor, bg: bg, bold: row.labelBold)
        }
        canvas.rich(
            16, y, row.text, fg: row.live ? Palette.dim : row.note ? Palette.note : Palette.text, bg: bg,
            token: Palette.night, tokenBackground: Palette.yellow, tokenBold: true, limit: width - 19)
        if row.cursor && blink { canvas.put(17 + row.text.count, y, "█", fg: Palette.cyan, bg: bg) }
    }

    // MARK: - Footer, warnings and dialogs

    private mutating func drawFooter(y: Int) {
        if state.naming != nil {
            canvas.text(2, y, "TYPE A NAME · RETURN NEXT · ↑↓ MOVE · ESC DONE", fg: Palette.dim, limit: width - 4)
            return
        }
        if state.stopping && !state.finished {
            canvas.text(
                2, y, "FINISHING: PLACING THE LAST WORDS AND CHECKING EVERY SPEAKER…", fg: blink ? Palette.yellow : Palette.dim,
                limit: width - 4)
            return
        }
        if let draft = state.draft {
            drawDraft(draft, y: y)
            return
        }
        if state.askingConsent {
            canvas.text(
                2, y,
                state.recording == nil
                    ? "Y YES, EVERYONE HAS AGREED · N NOT YET" : "Y YES, EVERYONE IN IT AGREED · N NOT NOW",
                fg: Palette.dim, limit: width - 4)
            return
        }
        if state.choosingRecording {
            canvas.text(2, y, "CHOOSE A RECORDING IN THE WINDOW THAT OPENED…", fg: blink ? Palette.yellow : Palette.dim,
                limit: width - 4)
            return
        }
        var keys: [(String, String, ScreenAction)] =
            state.saved != nil
            ? [("SPACE", "NEW", .newMeeting), ("O", "OPEN FILE", .openRecording), ("RETURN", "MINUTES", .open),
               ("R", "FINDER", .reveal), ("K", "SIDEBAR", .skin), ("Q", "QUIT", .quit)]
            : state.finished
            ? [("↑↓", "SCROLL", .follow), ("K", "SIDEBAR", .skin)]
            : !state.started
            ? [("SPACE", "START", .pause), ("O", "OPEN FILE", .openRecording), ("Q", "QUIT", .stop),
               ("V", "VISUALS", .visualizer), ("K", "SIDEBAR", .skin), ("?", "HELP", .help)]
            : [
                ("SPACE", state.paused ? "RESUME" : "PAUSE", .pause), ("Q", "STOP & SAVE", .stop),
                ("RETURN", "NOTE", .note), ("N", "NAME", .name), ("V", "VISUALS", .visualizer), ("K", "SIDEBAR", .skin),
                ("?", "HELP", .help),
            ]
        // In a narrow window the visualizer key goes first, then help; K (the way back) stays.
        func fits() -> Bool { keys.reduce(2) { $0 + $1.0.count + $1.1.count + 4 } - 3 <= width - 2 }
        for dropped in ["V", "?", "R", "O"] where !fits() { keys.removeAll { $0.0 == dropped } }
        var x = 2
        for (key, label, action) in keys {
            let span = key.count + 1 + label.count
            guard x + span <= width - 2 else { break }
            canvas.text(x, y, key, fg: Palette.night, bg: Palette.yellow, bold: true)
            canvas.text(x + key.count + 1, y, label, fg: Palette.pink, bold: true)
            canvas.region(x, y, span, 1, action)
            x += span + 3
        }
    }

    /// The footer while a note is typed: the note's end, a cursor, and what Return and Escape do.
    private mutating func drawDraft(_ draft: LiveState.NoteDraft, y: Int) {
        let label = " ✎ NOTE "
        let help = "RETURN ADDS IT AT \(ScreenModel.shortTime(draft.start ?? state.elapsed)) · ESC CANCELS"
        let x = 2 + label.count + 1
        let room = max(8, width - x - help.count - 5)
        canvas.text(2, y, label, fg: Palette.night, bg: Palette.yellow, bold: true)
        let shown = draft.text.count > room ? "…" + draft.text.suffix(room - 1) : draft.text
        canvas.text(x, y, shown, fg: Palette.note)
        if draft.text.isEmpty { canvas.text(x + 1, y, "TYPE YOUR NOTE", fg: Palette.dim) }
        if blink || draft.text.isEmpty { canvas.put(x + shown.count, y, "█", fg: Palette.cyan) }
        if width - help.count - 2 > x + room { canvas.text(width - 2 - help.count, y, help, fg: Palette.dim) }
    }

    private func warningLines() -> [String] {
        guard let warning = state.message else { return [] }
        return Array(warning.wrapped(to: max(10, width - 8)).prefix(2))
    }

    private mutating func drawWarnings(_ lines: [String], bottom: Int) {
        for (index, line) in lines.enumerated() {
            let y = bottom - lines.count + 1 + index
            if index == 0 { canvas.text(2, y, " ! ", fg: Palette.night, bg: Palette.yellow, bold: true) }
            canvas.text(6, y, line, fg: Palette.yellow)
        }
    }

    /// A neon window over the others, with its title set into the top edge.
    private mutating func dialog(_ title: String, width w: Int, height h: Int) -> (x: Int, y: Int) {
        let x = max(0, (width - w) / 2)
        let y = max(0, (height - h) / 2)
        canvas.box(x, y, w, h, border: Palette.pink, fill: Palette.strip, lines: .double)
        let label = " \(title) "
        canvas.text(x + max(0, (w - label.count) / 2), y, label, fg: Palette.yellow, bg: Palette.strip, bold: true)
        return (x, y)
    }

    private mutating func drawNaming(_ naming: LiveState.Naming) {
        let bg = Palette.strip
        let w = min(width - 2, 90)
        let visible = min(naming.speakers.count, max(1, height - 12))
        let (x, y) = dialog("WHO WAS SPEAKING?", width: w, height: visible + 7)
        canvas.text(
            x + 3, y + 2, "Type a name, then Return. Leave it empty to keep the label.", fg: Palette.text, bg: bg,
            limit: w - 5)
        let first = max(0, min(naming.selected - visible / 2, naming.speakers.count - visible))
        for row in 0..<visible where naming.speakers.indices.contains(first + row) {
            let index = first + row
            let speaker = naming.speakers[index]
            let selected = index == naming.selected
            let ry = y + 4 + row
            if selected { canvas.put(x + 2, ry, "▸", fg: Palette.yellow, bg: bg, bold: true) }
            canvas.text(x + 4, ry, speaker.description.uppercased(), fg: Self.color(for: speaker), bg: bg, bold: true, limit: 10)
            let field = 22
            let fieldColor = selected ? Palette.unlit : Palette.field
            let typed = state.names[speaker] ?? ""
            canvas.fill(x + 15, ry, field, 1, bg: fieldColor)
            canvas.text(x + 16, ry, String(typed.suffix(field - 2)), fg: Palette.cyan, bg: fieldColor, bold: true)
            if selected && blink { canvas.put(x + 16 + min(typed.count, field - 2), ry, "█", fg: Palette.cyan, bg: fieldColor) }
            if w >= 60, let quote = model.sample(of: speaker) {
                canvas.text(x + 39, ry, ScreenModel.quoted(quote, width: w - 42), fg: Palette.dim, bg: bg)
            }
        }
        canvas.text(
            x + 3, y + visible + 5, "Giving two speakers the same name combines them.", fg: Palette.dim, bg: bg,
            limit: w - 5)
    }

    /// The question before recording, or before transcribing a recording.
    private mutating func drawConsent() {
        let bg = Palette.strip
        let w = min(width - 2, 76)
        let recording = state.recording != nil
        let lines = (recording ? SidebarView.recordingConsentText : SidebarView.consentText).wrapped(to: w - 6)
        let title = recording ? "BEFORE YOU TRANSCRIBE" : "BEFORE YOU RECORD"
        let (x, y) = dialog(title, width: w, height: lines.count + 7)
        for (index, line) in lines.enumerated() {
            canvas.text(x + 3, y + 2 + index, line, fg: Palette.text, bg: bg)
        }
        let row = y + lines.count + 3
        canvas.text(
            x + 3, row, recording ? "DID EVERYONE IN IT KNOW, AND AGREE?" : "HAS EVERYONE BEEN TOLD, AND AGREED?",
            fg: Palette.yellow, bg: bg, bold: true)
        var column = x + 3
        let answers =
            recording
            ? [("Y", "YES, TRANSCRIBE IT", ScreenAction.consent), ("N", "NOT NOW", .decline)]
            : [("Y", "YES, START RECORDING", ScreenAction.consent), ("N", "NOT YET", .decline)]
        for (key, label, action) in answers {
            canvas.text(column, row + 2, key, fg: Palette.night, bg: Palette.yellow, bold: true)
            canvas.text(column + key.count + 1, row + 2, label, fg: Palette.pink, bg: bg, bold: true)
            canvas.region(column, row + 2, key.count + 1 + label.count, 1, action)
            column += key.count + label.count + 4
        }
    }

    private mutating func drawHelp() {
        let bg = Palette.strip
        let rows = ScreenModel.shortcuts(switchingTo: "the calmer sidebar look")
        let w = min(width - 2, 68)
        let visible = min(rows.count, max(1, height - 8))
        let (x, y) = dialog("HELP", width: w, height: visible + 5)
        for (index, row) in rows.prefix(visible).enumerated() {
            canvas.text(x + 3, y + 2 + index, row.key.uppercased(), fg: Palette.yellow, bg: bg, bold: true)
            canvas.text(x + 11, y + 2 + index, row.action, fg: Palette.text, bg: bg, limit: w - 13)
        }
        canvas.text(
            x + 3, y + visible + 3, "The keys along the bottom are clickable. Hold ⌥ Option to select text.",
            fg: Palette.dim, bg: bg, limit: w - 5)
    }

    private mutating func drawTooSmall() {
        let status =
            state.finished
            ? "DONE" : state.stopping ? "FINISHING" : state.paused ? "PAUSED"
            : state.recording == nil ? "STILL RECORDING" : "STILL TRANSCRIBING"
        let lines = ["MAKE THIS WINDOW BIGGER", "to see Mini Meeting Minutes.", "", "\(status) · \(model.clock)"]
        let top = max(0, height / 2 - 2)
        for (index, line) in lines.enumerated() {
            canvas.text(
                max(0, (width - line.count) / 2), top + index, line, fg: index == 3 ? Palette.pink : Palette.cyan,
                bold: index != 1)
        }
    }
}

/// The picture at the top of synthwave mode, in pixels: a sky with stars, a striped sun, a
/// city whose buildings are spectrum-analyzer bars, and a neon grid rolling toward the viewer.
struct SynthwaveScene {
    static let buildingWidth = 4
    private static let sky = [RGB(0x07011A), RGB(0x240A4D), RGB(0x6E1566), RGB(0xE0457B)]
    private static let sunColors = [RGB(0xFFF38A), RGB(0xFFB01F), RGB(0xFF3D8B)]
    private static let titleColors = [RGB(0xFFFFFF), RGB(0x9FF8FF), RGB(0x00F0FF), RGB(0xFF2E88)]

    let width: Int
    let height: Int
    let horizon: Int
    let sun: (x: Int, y: Int, radius: Int)
    /// Sizes are designed for a picture 38 pixels tall and scaled from there.
    private let scale: Double

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        scale = Double(height) / 38
        horizon = Int((Double(height) * 0.63).rounded())
        sun = (width / 2, horizon - max(1, Int((3 * scale).rounded())), max(3, Int((11 * scale).rounded())))
    }

    private var leftEdge: Int { sun.x - sun.radius - 2 }
    private var rightStart: Int { sun.x + sun.radius + 3 }

    /// Buildings on each side of the sun, one per spectrum band, counted outward from the sun.
    var buildingsPerSide: (left: Int, right: Int) {
        let width = Self.buildingWidth
        return (max(0, (leftEdge + width - 1) / width), max(0, (self.width - rightStart + width - 1) / width))
    }

    /// `left` and `right` are spectrum levels (0–1) for the buildings; `waves` are traces of
    /// audio to draw across the sky; `moving` sets the grid rolling and the stars twinkling.
    func draw(
        time: Double, left: [Double], right: [Double], waves: [(samples: [Float], color: RGB)], moving: Bool
    ) -> Bitmap {
        var image = Bitmap(width: width, height: height)
        guard horizon > 0 else { return image }
        drawSky(&image, time: time, moving: moving)
        drawSun(&image)
        drawCity(&image, left: left, right: right)
        drawGround(&image, time: time, moving: moving)
        for wave in waves { drawWave(&image, wave.samples, wave.color) }
        drawTitle(&image)
        return image
    }

    private func drawSky(_ image: inout Bitmap, time: Double, moving: Bool) {
        for y in 0..<horizon {
            image.row(y, from: 0, to: width - 1, Self.gradient(Self.sky, Double(y) / Double(horizon)))
        }
        let starRows = max(1, horizon * 42 / 100)
        for star in 0..<max(4, width * 3 / 20) {
            let (x, y) = (Self.noise(star, 1) % max(width, 1), Self.noise(star, 2) % starRows)
            let glow = moving ? 0.8 + 0.2 * sin(time * 1.9 + Double(star) * 2.1) : 0.9
            image[x, y] = Self.gradient(Self.sky, Double(y) / Double(horizon)).mixed(with: RGB(0xFFE6FF), glow)
        }
    }

    private func drawSun(_ image: inout Bitmap) {
        let radius = sun.radius
        let stripesBelow = sun.y - Int((4 * scale).rounded())
        for y in max(0, sun.y - radius)..<horizon {
            let dy = y - sun.y
            if height >= 26 && y > stripesBelow && ((dy % 3) + 3) % 3 == 2 { continue }
            let half = Double(max(radius * radius - dy * dy, 0)).squareRoot()
            let color = Self.gradient(Self.sunColors, Double(dy + radius) / (Double(radius) * 1.5))
            image.row(y, from: Int((Double(sun.x) - half).rounded()), to: Int((Double(sun.x) + half).rounded()), color)
        }
    }

    private func drawCity(_ image: inout Bitmap, left: [Double], right: [Double]) {
        let counts = buildingsPerSide
        let width = Self.buildingWidth
        for (side, levels, count) in [(0, left, counts.left), (1, right, counts.right)] {
            for index in 0..<count {
                let x0 = side == 0 ? leftEdge - (index + 1) * width : rightStart + index * width
                let level = levels.isEmpty ? 0 : levels[min(levels.count - 1, index * levels.count / count)]
                let base = Double(2 + Self.noise(index, 3 + side) % 4) * scale
                let tall = min(horizon - 1, max(1, Int((base + level * 9 * scale).rounded())))
                let top = horizon - tall
                image.fill(x0, top, width, tall, RGB(0x180530))
                image.row(top, from: x0, to: x0 + width - 1, index % 4 == 0 ? RGB(0x00F0FF) : RGB(0xFF2E88))
                for y in stride(from: top + 2, to: horizon - 1, by: 2) where Self.noise(index * 97 + y, 7 + side) % 4 == 0 {
                    image[x0 + 1 + y % 2, y] = RGB(0xFFE45E)
                }
            }
        }
    }

    private func drawGround(_ image: inout Bitmap, time: Double, moving: Bool) {
        let bottom = height - 1
        guard bottom > horizon else { return }
        image.fill(0, horizon, width, height - horizon, RGB(0x0D0221))
        // Lines fanning out from a vanishing point above the horizon...
        let vanish = Double(horizon) - 6 * scale
        let spacing = max(6, width / 10)
        for k in -12...12 {
            let bottomX = Double(sun.x + k * spacing)
            let horizonX = Double(sun.x) + (bottomX - Double(sun.x)) * (Double(horizon) - vanish) / (Double(bottom) - vanish)
            image.line(Int(horizonX.rounded()), horizon, Int(bottomX.rounded()), bottom, RGB(0x9628DC))
        }
        // ...crossed by lines that roll toward the viewer, spreading out as they come closer.
        let depth = Double(bottom - horizon)
        let phase = moving ? (time * 0.6).truncatingRemainder(dividingBy: 1) : 0.35
        for line in 0..<5 {
            let t = (Double(line) + phase) / 5
            let y = horizon + Int((t * t * depth).rounded())
            guard y > horizon, y <= bottom else { continue }
            image.row(y, from: 0, to: width - 1, RGB(0x96196E).mixed(with: RGB(0xE6288C), t))
        }
        image.row(horizon, from: 0, to: width - 1, RGB(0xFF71CE))
    }

    private func drawWave(_ image: inout Bitmap, _ samples: [Float], _ color: RGB) {
        let top = height >= 30 ? Double(12) * scale : Double(horizon) * 0.2
        let middle = (top + Double(horizon)) / 2
        let amplitude = (Double(horizon) - top) * 0.45
        var previous: (x: Int, y: Int)?
        for (x, value) in ScreenModel.waveform(samples, count: width, samplesPerPoint: 2).enumerated() {
            let y = Int((middle - value * amplitude).rounded())
            if let previous { image.line(previous.x, previous.y, x, y, color) } else { image[x, y] = color }
            previous = (x, y)
        }
    }

    private func drawTitle(_ image: inout Bitmap) {
        let pattern: [String]
        if height >= 30 && width >= 64 {
            pattern = PixelTitle.large
        } else if height >= 18 && width >= 44 {
            pattern = PixelTitle.small
        } else {
            return
        }
        let rows = pattern.count
        let x = (width - (pattern.first?.count ?? 0)) / 2
        image.stamp(pattern, x: x, y: height >= 30 ? Int((2 * scale).rounded()) : 1) { row in
            Self.gradient(Self.titleColors, Double(row) / Double(max(rows - 1, 1)))
        }
    }

    static func gradient(_ stops: [RGB], _ t: Double) -> RGB {
        guard stops.count > 1 else { return stops.first ?? RGB(0) }
        let position = min(1, max(0, t)) * Double(stops.count - 1)
        let index = min(Int(position), stops.count - 2)
        return stops[index].mixed(with: stops[index + 1], position - Double(index))
    }

    /// A repeatable pseudo-random number for a pair of integers, so the stars and windows stay put.
    static func noise(_ a: Int, _ b: Int) -> Int {
        var x = UInt64(truncatingIfNeeded: a) &* 0x9E37_79B9_7F4A_7C15
        x ^= UInt64(truncatingIfNeeded: b) &* 0xC2B2_AE3D_27D4_EB4F
        x ^= x >> 31
        x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 29
        return Int(x % 1_000_003)
    }
}
