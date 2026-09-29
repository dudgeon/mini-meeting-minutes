import Foundation
import MinutesCore

/// The retro, Winamp-inspired recording screen. Like Winamp's main window, equalizer and
/// playlist, it stacks three windows: the main window (clock, marquee, visualizer, transport),
/// speakers (talk time, who spoke when) and the transcript. Smaller terminals get fewer windows.
struct RetroView {
    enum Layout {
        case full, medium, small, tiny

        init(width: Int, height: Int) {
            if width >= 100 && height >= 36 {
                self = .full
            } else if width >= 80 && height >= 26 {
                self = .medium
            } else if width >= 50 && height >= 12 {
                self = .small
            } else {
                self = .tiny
            }
        }
    }

    let state: LiveState.Snapshot
    let skin: Skin
    let analyzers: [Channel: SpectrumAnalyzer]
    /// Seconds since the screen started, for animation.
    let time: Double
    /// Seconds since the previous frame, for the visualizer's motion.
    let frameInterval: Double
    var canvas: Canvas
    /// Transcript rows scrolled back, clamped while drawing.
    private(set) var maxScroll = 0

    private var width: Int { canvas.width }
    private var height: Int { canvas.height }
    private var blink: Bool { Int(time * 2) % 2 == 0 }

    static func render(
        _ state: LiveState.Snapshot, skin: Skin, analyzers: [Channel: SpectrumAnalyzer], width: Int, height: Int,
        time: Double, frameInterval: Double
    ) -> (canvas: Canvas, maxScroll: Int) {
        var view = RetroView(
            state: state, skin: skin, analyzers: analyzers, time: time, frameInterval: frameInterval,
            canvas: Canvas(width: width, height: height, background: skin.background))
        switch Layout(width: width, height: height) {
        case .full:
            view.drawMain(top: 0)
            view.drawSpeakers(top: 14)
            view.drawTranscript(top: 22)
        case .medium:
            view.drawMain(top: 0)
            view.drawTranscript(top: 14)
        case .small:
            view.drawCompactHeader()
            view.drawTranscript(top: 2)
        case .tiny:
            view.drawTooSmall()
            return (view.canvas, 0)
        }
        view.drawFooter()
        if state.help { view.drawHelp() }
        if let naming = state.naming { view.drawNaming(naming) }
        return (view.canvas, view.maxScroll)
    }

    // MARK: - Shared pieces

    private mutating func titleBar(_ y: Int, _ title: String, right: String = "", action: ScreenAction? = nil) {
        canvas.fill(0, y, width, 1, bg: skin.chrome)
        for x in 1..<(width - 1) { canvas.put(x, y, "═", fg: skin.stripe, bg: skin.chrome) }
        let label = " \(title) "
        canvas.text((width - label.count) / 2, y, label, fg: skin.title, bg: skin.chrome, bold: true)
        canvas.put(1, y, "◆", fg: skin.title, bg: skin.chrome)
        guard !right.isEmpty else { return }
        let x = width - right.count - 4
        canvas.text(x, y, " \(right) ", fg: skin.hint, bg: skin.chrome)
        if let action { canvas.region(x, y, right.count + 2, 1, action) }
    }

    /// A sunken display, with a shadow above and left and a highlight below and right.
    private mutating func inset(_ x: Int, _ y: Int, _ w: Int, _ h: Int, bevel: Bool = true) {
        canvas.fill(x, y, w, h, bg: skin.display)
        guard bevel else { return }
        for column in x..<(x + w) {
            canvas.put(column, y - 1, "▁", fg: skin.chromeDark, bg: skin.chrome)
            canvas.put(column, y + h, "▔", fg: skin.chromeLight, bg: skin.chrome)
        }
        for row in y..<(y + h) {
            canvas.put(x - 1, row, "▕", fg: skin.chromeDark, bg: skin.chrome)
            canvas.put(x + w, row, "▏", fg: skin.chromeLight, bg: skin.chrome)
        }
    }

    @discardableResult
    private mutating func button(_ x: Int, _ y: Int, _ label: String, lit: Bool = false, action: ScreenAction)
        -> Int
    {
        let text = " \(label) "
        canvas.text(x, y, text, fg: lit ? skin.lit : skin.buttonText, bg: skin.button, bold: true)
        canvas.region(x, y, text.count, 1, action)
        return x + text.count + 1
    }

    @discardableResult
    private mutating func led(_ x: Int, _ y: Int, _ label: String, lit: Bool) -> Int {
        canvas.text(x, y, " \(label) ", fg: lit ? skin.lit : skin.ghost, bg: skin.display, bold: true)
        return x + label.count + 3
    }

    private func name(of speaker: SpeakerID) -> String {
        if let name = state.names[speaker]?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return speaker.description.uppercased()
    }

    private var clock: String { MinutesDocument.timestamp(state.elapsed) }

    // MARK: - Main window

    private mutating func drawMain(top: Int) {
        titleBar(top, "MINI·MEETING·MINUTES", right: skin.name.uppercased(), action: .skin)
        canvas.fill(0, top + 1, width, 13, bg: skin.chrome)

        // The LCD: status, big clock, level meters.
        inset(2, top + 2, 38, 8)
        drawStatus(3, top + 2)
        let mode =
            state.channels.count == 2 ? "ROOM+CALL" : state.channels.contains(.room) ? "ROOM ONLY" : "CALL ONLY"
        canvas.text(39 - mode.count, top + 2, mode, fg: skin.displayDim, bg: skin.display)
        bigClock(4, top + 3, clock)
        for (index, channel) in [Channel.room, .remote].enumerated() {
            let x = 3 + index * 18
            let active = state.channels.contains(channel)
            canvas.text(x, top + 8, channel == .room ? "MIC" : "SYS", fg: skin.displayDim, bg: skin.display)
            let decibels = 20 * log10(Double(max(state.levels[channel] ?? 0, 1e-6)))
            let lit = active && !state.paused ? Int(((decibels + 60) / 60 * 12).rounded()) : 0
            for cell in 0..<12 {
                let color = cell < lit ? skin.spectrumColor(row: cell, of: 12) : skin.ghost
                canvas.put(x + 4 + cell, top + 8, "▆", fg: color, bg: skin.display)
            }
        }

        // Right side: marquee, status lights, visualizer, memory.
        let rx = 43
        let rw = width - 3 - rx
        inset(rx, top + 2, rw, 1)
        drawMarquee(rx, top + 2, rw)

        var x = led(rx, top + 4, "16", lit: true)
        canvas.text(x - 1, top + 4, "kHz", fg: skin.hint, bg: skin.chrome)
        x += 4
        x = led(x, top + 4, "MIC", lit: state.channels.contains(.room))
        x = led(x, top + 4, "SYS", lit: state.channels.contains(.remote))
        x = led(x, top + 4, "AEC", lit: state.echoCancellation)
        x = led(x, top + 4, "PII", lit: state.redaction)
        if width - 3 - x >= 15 { canvas.text(x, top + 4, "PARAKEET·REDUX", fg: skin.hint, bg: skin.chrome) }

        drawVisualizers(rx, top + 6, rw, 5)

        x = button(2, top + 12, "● REC", lit: !state.paused && !state.stopping, action: .resume)
        x = button(x, top + 12, "❚❚", lit: state.paused, action: .pause)
        x = button(x, top + 12, "■", action: .stop)
        x = button(x, top + 12, "NAME", action: .name)
        button(x, top + 12, "VIS", action: .visualizer)
        drawMemory(rx, top + 12, rw)
    }

    private mutating func drawStatus(_ x: Int, _ y: Int) {
        if state.finished {
            canvas.text(x, y, "■ DONE", fg: skin.lit, bg: skin.display, bold: true)
        } else if state.stopping {
            canvas.text(x, y, "■ FINISHING", fg: blink ? skin.key : skin.displayDim, bg: skin.display, bold: true)
        } else if state.paused {
            canvas.text(x, y, "❚❚ PAUSED", fg: blink ? skin.key : skin.displayDim, bg: skin.display, bold: true)
        } else {
            canvas.put(x, y, "●", fg: blink ? skin.record : skin.ghost, bg: skin.display)
            canvas.text(x + 2, y, "REC", fg: skin.record, bg: skin.display, bold: true)
        }
    }

    private mutating func drawMarquee(_ x: Int, _ y: Int, _ w: Int) {
        let entries = transcriptEntries()
        let message: String
        if state.finished {
            message = "DONE · \(entries.count) LINES · \(speakerStats().count) SPEAKERS"
        } else if state.stopping {
            message = "FINISHING UP · CHECKING EVERY SPEAKER"
        } else if state.paused {
            message = "PAUSED · PRESS SPACE TO CONTINUE"
        } else if let last = entries.last {
            message = "\(last.number). \(name(of: last.speaker)) · \(last.text) (\(Self.shortTime(last.start)))"
        } else {
            message = "LISTENING · SPEECH APPEARS BELOW AS IT'S HEARD"
        }
        let text = "***  \(message)  ***"
        if text.count <= w {
            canvas.text(x + (w - text.count) / 2, y, text, fg: skin.displayText, bg: skin.display)
            return
        }
        let loop = Array(text + "     ")
        let offset = Int(time * 8) % loop.count
        let visible = (0..<w).map { loop[(offset + $0) % loop.count] }
        canvas.text(x, y, String(visible), fg: skin.displayText, bg: skin.display)
    }

    private mutating func drawVisualizers(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        let channels = [Channel.room, .remote].filter(state.channels.contains)
        let count = max(channels.count, 1)
        let panelWidth = (w - 2 * (count - 1)) / count
        for (index, channel) in channels.enumerated() {
            let px = x + index * (panelWidth + 2)
            inset(px, y, panelWidth, h)
            canvas.region(px, y, panelWidth, h, .visualizer)
            let live = !state.paused && !state.stopping && !state.finished
            let samples = live ? state.recent[channel] ?? [] : []
            switch state.visualizer {
            case .spectrum:
                drawSpectrum(channel, px, y, panelWidth, h, samples: samples)
            case .scope:
                drawScope(px, y, panelWidth, h, samples: samples)
            case .off:
                let label = "VISUALIZER OFF"
                canvas.text(px + max(0, (panelWidth - label.count) / 2), y + h / 2, label, fg: skin.ghost, bg: skin.display)
            }
            let label = channel == .room ? "MIC" : "SYS"
            canvas.text(px + panelWidth - label.count - 1, y, label, fg: skin.displayDim, bg: skin.display)
        }
    }

    private mutating func drawSpectrum(_ channel: Channel, _ x: Int, _ y: Int, _ w: Int, _ h: Int, samples: [Float]) {
        guard let analyzer = analyzers[channel] else { return }
        let bars = max(1, (w - 1) / 2)
        analyzer.update(samples: samples, bars: bars, elapsed: frameInterval)
        for bar in 0..<bars {
            let bx = x + 1 + bar * 2
            let eighths = Int(analyzer.levels[bar] * Double(h * 8))
            for row in 0..<h {
                let fill = eighths - row * 8
                let char: Character = fill >= 8 ? "█" : fill > 0 ? Array(" ▁▂▃▄▅▆▇")[fill] : " "
                canvas.put(bx, y + h - 1 - row, char, fg: skin.spectrumColor(row: row, of: h), bg: skin.display)
            }
            let peakRow = min(h - 1, Int(analyzer.peaks[bar] * Double(h)))
            let peakY = y + h - 1 - peakRow
            if analyzer.peaks[bar] > 0.02, canvas[bx, peakY].char == " " {
                canvas.put(bx, peakY, "▔", fg: skin.peak, bg: skin.display)
            }
        }
    }

    /// A Winamp-style oscilloscope: the newest few milliseconds of audio as a connected trace,
    /// scaled to fill the display, two dots per cell vertically.
    private mutating func drawScope(_ x: Int, _ y: Int, _ w: Int, _ h: Int, samples: [Float]) {
        let columns = w - 2
        let dotsHigh = h * 2
        guard columns > 0 else { return }
        let window = Array(samples.suffix(columns * 6))
        var values = [Double](repeating: 0, count: columns)
        if window.count >= columns {
            let step = window.count / columns
            for column in 0..<columns {
                let slice = window[(column * step)..<((column + 1) * step)]
                values[column] = Double(slice.reduce(0, +)) / Double(slice.count)
            }
        }
        // Scale to the loudest point, but don't blow faint noise up to full height.
        let gain = 0.9 / max(values.map(abs).max() ?? 0, 0.02)
        var dots = [Set<Int>](repeating: [], count: columns)
        var previous: Int?
        for column in 0..<columns {
            let amplitude = max(-1, min(1, values[column] * gain))
            let dot = Int(((1 - amplitude) / 2 * Double(dotsHigh - 1)).rounded())
            for filled in min(previous ?? dot, dot)...max(previous ?? dot, dot) { dots[column].insert(filled) }
            previous = dot
        }
        for column in 0..<columns {
            for row in 0..<h {
                let upper = dots[column].contains(row * 2)
                let lower = dots[column].contains(row * 2 + 1)
                guard upper || lower else { continue }
                let distance = abs(Double(row) - Double(h - 1) / 2) / (Double(h) / 2)
                let color = skin.spectrumColor(row: Int(distance * Double(h)), of: h)
                canvas.put(x + 1 + column, y + row, upper && lower ? "█" : upper ? "▀" : "▄", fg: color, bg: skin.display)
            }
        }
    }

    private mutating func drawMemory(_ x: Int, _ y: Int, _ w: Int) {
        let held = state.buffered.values.max() ?? 0
        let label = "AUDIO IN MEMORY"
        let amount = String(format: "%2.0fs/60s", min(held, 99))
        let barWidth = w - label.count - amount.count - 2
        guard barWidth >= 4 else { return }
        canvas.text(x, y, label, fg: skin.hint, bg: skin.chrome)
        let bx = x + label.count + 1
        let filled = Int((min(held, 60) / 60 * Double(barWidth)).rounded())
        for cell in 0..<barWidth {
            canvas.put(
                bx + cell, y, cell < filled ? "█" : "░", fg: cell < filled ? skin.lit : skin.ghost, bg: skin.display)
        }
        canvas.text(bx + barWidth + 1, y, amount, fg: skin.displayText, bg: skin.chrome)
    }

    // MARK: - Speakers window

    private mutating func drawSpeakers(top: Int) {
        titleBar(top, "SPEAKERS")
        canvas.fill(0, top + 1, width, 7, bg: skin.chrome)
        let stats = speakerStats()
        let most = stats.map(\.seconds).max() ?? 1
        let total = max(stats.reduce(0) { $0 + $1.seconds }, 1)
        let shown = stats.prefix(4)
        if stats.isEmpty {
            canvas.text(4, top + 3, "No one has spoken yet.", fg: skin.hint, bg: skin.chrome)
        }
        for (index, stat) in shown.enumerated() {
            let x = 5 + index * 11
            let color = skin.color(for: stat.speaker)
            let percent = "\(Int((stat.seconds / total * 100).rounded()))%"
            canvas.text(x + 1 - percent.count / 2, top + 1, percent, fg: skin.title, bg: skin.chrome, bold: true)
            let eighths = Int(stat.seconds / most * 32)
            for row in 0..<4 {
                let y = top + 5 - row
                let fill = eighths - row * 8
                canvas.put(x, y, "┃", fg: skin.chromeDark, bg: skin.chrome)
                canvas.put(x + 2, y, "┃", fg: skin.chromeDark, bg: skin.chrome)
                if fill > 0 {
                    canvas.put(x + 1, y, fill >= 8 ? "█" : Array(" ▁▂▃▄▅▆▇")[fill], fg: color, bg: skin.chrome)
                } else {
                    canvas.put(x + 1, y, "┃", fg: skin.chromeDark, bg: skin.chrome)
                }
            }
            let label = String(name(of: stat.speaker).prefix(9))
            canvas.text(x + 1 - label.count / 2, top + 6, label, fg: color, bg: skin.chrome, bold: true)
        }
        if stats.count > shown.count {
            canvas.text(5 + 4 * 11 - 3, top + 6, "+\(stats.count - shown.count)", fg: skin.hint, bg: skin.chrome)
        }

        // Who spoke when: one row per channel, each cell colored by whoever talked most in it.
        let tx = 60
        let tw = width - 3 - tx
        canvas.text(51, top + 1, "WHO SPOKE WHEN", fg: skin.title, bg: skin.chrome, bold: true)
        inset(tx, top + 3, tw, 2)
        let span = max(120, state.elapsed * 1.15)
        for (row, channel) in [Channel.room, .remote].enumerated() {
            canvas.text(51, top + 3 + row, channel == .room ? "ROOM" : "REMOTE", fg: skin.hint, bg: skin.chrome)
            let turns = state.turns.filter { $0.channel == channel }
            for cell in 0..<tw {
                let from = Double(cell) * span / Double(tw)
                let to = from + span / Double(tw)
                guard from <= state.elapsed else {
                    canvas.put(tx + cell, top + 3 + row, "·", fg: skin.ghost, bg: skin.display)
                    continue
                }
                var talk: [SpeakerID: Double] = [:]
                for turn in turns where turn.end > from && turn.start < to {
                    talk[turn.speaker, default: 0] += min(turn.end, to) - max(turn.start, from)
                }
                if let speaker = talk.max(by: { $0.value < $1.value })?.key {
                    canvas.put(tx + cell, top + 3 + row, "█", fg: skin.color(for: speaker), bg: skin.display)
                } else {
                    canvas.put(tx + cell, top + 3 + row, "▁", fg: skin.ghost, bg: skin.display)
                }
            }
        }
        let playhead = tx + min(tw - 1, Int(state.elapsed / span * Double(tw)))
        canvas.put(playhead, top + 2, "▼", fg: skin.record, bg: skin.chrome)
        canvas.text(tx, top + 6, Self.shortTime(0), fg: skin.hint, bg: skin.chrome)
        let middle = Self.shortTime(span / 2)
        canvas.text(tx + (tw - middle.count) / 2, top + 6, middle, fg: skin.hint, bg: skin.chrome)
        let end = Self.shortTime(span)
        canvas.text(tx + tw - end.count, top + 6, end, fg: skin.hint, bg: skin.chrome)
    }

    // MARK: - Transcript window

    private mutating func drawTranscript(top: Int) {
        titleBar(top, "TRANSCRIPT", right: state.scroll > 0 ? "SCROLLED ▴" : "FOLLOWING ▾", action: .follow)
        canvas.fill(0, top + 1, width, height - 3 - top, bg: skin.chrome)
        let insetTop = top + 2
        let rows = height - 5 - insetTop + 1
        let insetWidth = width - 6
        guard rows >= 1 else { return }
        inset(2, insetTop, insetWidth, rows)

        let lines = transcriptLines(width: insetWidth)
        maxScroll = max(0, lines.count - rows)
        let scroll = min(state.scroll, maxScroll)
        let first = max(0, lines.count - rows - scroll)
        let visible = lines[first..<min(lines.count, first + rows)]
        if lines.isEmpty {
            let hint = "Listening… speech appears here as it's heard."
            canvas.text(2 + max(0, (insetWidth - hint.count) / 2), insetTop + rows / 2, hint, fg: skin.transcriptDim,
                        bg: skin.display)
        }
        for (offset, line) in visible.enumerated() {
            drawLine(line, x: 2, y: insetTop + offset, width: insetWidth)
        }

        // Scrollbar.
        let thumb = max(1, lines.isEmpty ? rows : rows * rows / max(lines.count, 1))
        let position = maxScroll == 0 ? rows - thumb : (rows - thumb) * (maxScroll - scroll) / maxScroll
        for row in 0..<rows {
            let inThumb = row >= position && row < position + thumb
            canvas.put(width - 3, insetTop + row, inThumb ? "█" : "░", fg: inThumb ? skin.chromeLight : skin.chromeDark,
                       bg: skin.chrome)
        }

        // Bottom bar: buttons and a small LCD of totals.
        let y = height - 3
        var x = button(2, y, "NAME", action: .name)
        x = button(x, y, "SKIN", action: .skin)
        button(x, y, "HELP", action: .help)
        let stats = speakerStats()
        let room = Set(stats.filter { $0.speaker.channel == .room }.map(\.speaker)).count
        let remote = stats.count - room
        let totals = " \(transcriptEntries().count) LINES   \(room)+\(remote) SPEAKERS   \(clock) "
        if width - 3 - totals.count > x + 20 {
            inset(width - 3 - totals.count, y, totals.count, 1, bevel: false)
            canvas.text(width - 3 - totals.count, y, totals, fg: skin.displayText, bg: skin.display)
        }
    }

    private struct Line {
        enum Kind { case said, live }
        let kind: Kind
        let number: Int?
        let label: String?
        let color: RGB
        let text: String
        let time: String?
    }

    /// Columns of a transcript line: number, speaker, text, then the time at the right.
    private static let textColumn = 18
    private static let timeColumns = 8

    private func transcriptLines(width: Int) -> [Line] {
        let textWidth = max(10, width - Self.textColumn - Self.timeColumns)
        var lines: [Line] = []
        let entries = transcriptEntries()
        for entry in entries {
            for (index, text) in entry.text.wrapped(to: textWidth).enumerated() {
                lines.append(
                    Line(
                        kind: .said, number: index == 0 ? entry.number : nil,
                        label: index == 0 ? name(of: entry.speaker) : nil, color: skin.color(for: entry.speaker),
                        text: text, time: index == 0 ? Self.shortTime(entry.start) : nil))
            }
        }
        var number = entries.count
        for channel in [Channel.room, .remote] {
            guard let pending = state.pending[channel], !pending.isEmpty else { continue }
            number += 1
            for (index, text) in pending.wrapped(to: textWidth).enumerated() {
                lines.append(
                    Line(
                        kind: .live, number: index == 0 ? number : nil,
                        label: index == 0 ? (channel == .room ? "ROOM …" : "REMOTE …") : nil,
                        color: skin.selectionText, text: text, time: index == 0 ? "live" : nil))
            }
        }
        return lines
    }

    private mutating func drawLine(_ line: Line, x: Int, y: Int, width: Int) {
        let live = line.kind == .live
        let background = live ? skin.selection : skin.display
        if live { canvas.fill(x, y, width, 1, bg: background) }
        if let number = line.number {
            let label = "\(number)."
            canvas.text(x + 5 - label.count, y, label, fg: live ? skin.selectionText : skin.transcriptDim, bg: background)
        }
        if let label = line.label {
            canvas.text(x + 6, y, label, fg: line.color, bg: background, bold: true, limit: 10)
        }
        let textColor = live ? skin.selectionText : skin.transcriptText
        canvas.text(x + Self.textColumn, y, line.text, fg: textColor, bg: background,
                    limit: width - Self.textColumn - Self.timeColumns)
        if let time = line.time {
            canvas.text(x + width - time.count - 1, y, time, fg: live ? skin.selectionText : skin.transcriptDim,
                        bg: background)
        }
    }

    // MARK: - Small layouts

    private mutating func drawCompactHeader() {
        titleBar(0, "MINI·MEETING·MINUTES")
        canvas.fill(0, 1, width, 1, bg: skin.chrome)
        drawStatusCompact()
    }

    private mutating func drawStatusCompact() {
        inset(2, 1, 12, 1, bevel: false)
        canvas.text(3, 1, clock, fg: skin.lit, bg: skin.display, bold: true)
        var x = 16
        if state.paused {
            canvas.text(x, 1, "❚❚ PAUSED", fg: skin.key, bg: skin.chrome, bold: true)
        } else if state.stopping || state.finished {
            canvas.text(x, 1, state.finished ? "■ DONE" : "■ FINISHING", fg: skin.key, bg: skin.chrome, bold: true)
        } else {
            canvas.put(x, 1, "●", fg: blink ? skin.record : skin.chromeDark, bg: skin.chrome)
            canvas.text(x + 2, 1, "REC", fg: skin.record, bg: skin.chrome, bold: true)
        }
        x += 12
        for channel in [Channel.room, .remote] where state.channels.contains(channel) {
            canvas.text(x, 1, channel == .room ? "MIC" : "SYS", fg: skin.hint, bg: skin.chrome)
            let decibels = 20 * log10(Double(max(state.levels[channel] ?? 0, 1e-6)))
            let lit = state.paused ? 0 : Int(((decibels + 60) / 60 * 6).rounded())
            for cell in 0..<6 {
                canvas.put(x + 4 + cell, 1, "▆", fg: cell < lit ? skin.spectrumColor(row: cell, of: 6) : skin.ghost,
                           bg: skin.chrome)
            }
            x += 12
        }
    }

    private mutating func drawTooSmall() {
        let lines = ["Make this window bigger", "to see Mini Meeting Minutes.", "", "Still recording · \(clock)"]
        for (index, line) in lines.enumerated() {
            canvas.text(max(0, (width - line.count) / 2), max(0, height / 2 - 2) + index, line,
                        fg: index == 3 ? skin.record : skin.title, bg: skin.background, bold: index == 3)
        }
    }

    // MARK: - Footer and dialogs

    private mutating func drawFooter() {
        canvas.fill(0, height - 2, width, 2, bg: skin.background)
        if let warning = state.warnings.last {
            canvas.text(1, height - 2, " ! ", fg: skin.background, bg: skin.warning, bold: true)
            canvas.text(5, height - 2, warning, fg: skin.warning, bg: skin.background, limit: width - 6)
        } else {
            // Paths outside the home folder (temporary folders, say) show just the file name.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path =
                state.outputPath.hasPrefix(home)
                ? LiveView.abbreviate(state.outputPath) : "…/" + (state.outputPath as NSString).lastPathComponent
            let saving = "Saving to " + LiveView.fit(path, width - 14)
            canvas.text(2, height - 2, saving, fg: skin.hint, bg: skin.background)
        }
        let y = height - 1
        if state.naming != nil {
            canvas.text(2, y, "Type a name · Return next · ↑↓ move · Esc done", fg: skin.hint, bg: skin.background)
            return
        }
        if state.stopping && !state.finished {
            canvas.text(2, y, "Finishing: attributing the last words and checking every speaker…", fg: skin.hint,
                        bg: skin.background)
            return
        }
        var x = 2
        let keys =
            state.finished
            ? [("↑↓", "scroll"), ("K", "skin")]
            : [("SPACE", state.paused ? "resume" : "pause"), ("Q", "stop & save"), ("N", "name speakers"),
               ("V", "visualizer"), ("↑↓", "scroll"), ("K", "skin"), ("?", "help")]
        for (key, label) in keys {
            guard x + key.count + label.count + 2 < width else { break }
            canvas.text(x, y, key, fg: skin.key, bg: skin.background, bold: true)
            canvas.text(x + key.count + 1, y, label, fg: skin.hint, bg: skin.background)
            x += key.count + label.count + 4
        }
    }

    /// A window drawn over the others, with a striped title bar.
    private mutating func dialog(_ title: String, width w: Int, height h: Int) -> (x: Int, y: Int) {
        let x = max(0, (width - w) / 2)
        let y = max(0, (height - h) / 2)
        canvas.fill(x, y, w, h, bg: skin.chrome)
        for column in (x + 1)..<(x + w - 1) { canvas.put(column, y, "═", fg: skin.stripe, bg: skin.chrome) }
        canvas.put(x + 1, y, "◆", fg: skin.title, bg: skin.chrome)
        let label = " \(title) "
        canvas.text(x + (w - label.count) / 2, y, label, fg: skin.title, bg: skin.chrome, bold: true)
        for column in x..<(x + w) { canvas.put(column, y + h - 1, "▔", fg: skin.chromeLight, bg: skin.chrome) }
        return (x, y)
    }

    private mutating func drawHelp() {
        let rows: [(String, String)] = [
            ("SPACE", "pause or resume (paused audio is dropped)"),
            ("Q", "stop and save the minutes"),
            ("N", "name the speakers"),
            ("V", "spectrum · oscilloscope · off"),
            ("K", "switch skin"),
            ("↑ ↓", "scroll the transcript (or use the mouse wheel)"),
            ("F", "jump back to the newest line"),
            ("?", "close this help"),
        ]
        let w = min(width - 2, 62)
        let (x, y) = dialog("HELP", width: w, height: rows.count + 6)
        for (index, row) in rows.enumerated() {
            canvas.text(x + 3, y + 2 + index, row.0, fg: skin.key, bg: skin.chrome, bold: true)
            canvas.text(x + 11, y + 2 + index, row.1, fg: skin.buttonText, bg: skin.chrome, limit: w - 13)
        }
        canvas.text(x + 3, y + rows.count + 3, "You can click the buttons too. Hold ⌥ Option to select text.",
                    fg: skin.hint, bg: skin.chrome, limit: w - 5)
    }

    private mutating func drawNaming(_ naming: LiveState.Naming) {
        let w = min(width - 2, 84)
        let visible = min(naming.speakers.count, max(1, height - 12))
        let (x, y) = dialog("WHO WAS SPEAKING?", width: w, height: visible + 8)
        canvas.text(x + 3, y + 2, "Type a name, then Return. Leave it empty to keep the label.", fg: skin.buttonText,
                    bg: skin.chrome, limit: w - 5)
        let first = max(0, min(naming.selected - visible / 2, naming.speakers.count - visible))
        for row in 0..<visible {
            let index = first + row
            let speaker = naming.speakers[index]
            let selected = index == naming.selected
            let ry = y + 4 + row
            canvas.text(x + 2, ry, selected ? "▸" : " ", fg: skin.key, bg: skin.chrome, bold: true)
            canvas.text(x + 4, ry, speaker.description.uppercased(), fg: skin.color(for: speaker), bg: skin.chrome,
                        bold: true)
            let field = 22
            let typed = state.names[speaker] ?? ""
            canvas.fill(x + 15, ry, field, 1, bg: selected ? skin.button : skin.display)
            canvas.text(x + 16, ry, String(typed.suffix(field - 2)), fg: skin.lit, bg: selected ? skin.button : skin.display,
                        bold: true)
            if selected && blink {
                canvas.put(x + 16 + min(typed.count, field - 2), ry, "▌", fg: skin.lit, bg: skin.button)
            }
            if let quote = sample(of: speaker) {
                let room = w - 43
                let shown = quote.count > room ? String(quote.prefix(max(room - 1, 0))) + "…" : quote
                canvas.text(x + 39, ry, "“\(shown)”", fg: skin.hint, bg: skin.chrome, limit: w - 41)
            }
        }
        canvas.text(x + 3, y + visible + 5, "Giving two speakers the same name combines them.", fg: skin.hint,
                    bg: skin.chrome, limit: w - 5)
    }

    // MARK: - Data

    struct Entry {
        let number: Int
        let speaker: SpeakerID
        let start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// Turns merged into entries: consecutive speech by the same person becomes one entry.
    private func transcriptEntries() -> [Entry] {
        var entries: [Entry] = []
        for turn in state.turns.sorted(by: { $0.start < $1.start }) {
            if var last = entries.last, name(of: last.speaker) == name(of: turn.speaker), turn.start - last.end < 10 {
                last.text += " " + turn.text
                last.end = max(last.end, turn.end)
                entries[entries.count - 1] = last
            } else {
                entries.append(
                    Entry(number: entries.count + 1, speaker: turn.speaker, start: turn.start, end: turn.end,
                          text: turn.text))
            }
        }
        return entries
    }

    /// Talk time per speaker, in order of first appearance.
    private func speakerStats() -> [(speaker: SpeakerID, seconds: Double)] {
        var order: [SpeakerID] = []
        var seconds: [SpeakerID: Double] = [:]
        for turn in state.turns.sorted(by: { $0.start < $1.start }) {
            if seconds[turn.speaker] == nil { order.append(turn.speaker) }
            seconds[turn.speaker, default: 0] += max(turn.end - turn.start, 0)
        }
        return order.map { ($0, seconds[$0] ?? 0) }
    }

    private func sample(of speaker: SpeakerID) -> String? {
        state.turns.filter { $0.speaker == speaker }.max { $0.text.count < $1.text.count }?.text
    }

    static func shortTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Big clock

    /// Seven-segment digits, four pixels wide and seven tall, drawn two pixels per cell with half
    /// blocks. Unlit segments glow faintly, like an LCD.
    private mutating func bigClock(_ x: Int, _ y: Int, _ string: String) {
        let segments: [Character: String] = [
            "0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc", "5": "afgcd", "6": "afgedc",
            "7": "abc", "8": "abcdefg", "9": "abcdfg",
        ]
        let pixels: [Character: [(Int, Int)]] = [
            "a": [(1, 0), (2, 0)], "f": [(0, 1), (0, 2)], "b": [(3, 1), (3, 2)], "g": [(1, 3), (2, 3)],
            "e": [(0, 4), (0, 5)], "c": [(3, 4), (3, 5)], "d": [(1, 6), (2, 6)],
        ]
        var column = x
        for char in string {
            if char == ":" {
                canvas.put(column, y + 1, "▀", fg: skin.lit, bg: skin.display)
                canvas.put(column, y + 2, "▄", fg: skin.lit, bg: skin.display)
                column += 2
                continue
            }
            let lit = Set((segments[char] ?? "").flatMap { pixels[$0] ?? [] }.map { $0.0 * 8 + $0.1 })
            let all = Set(pixels.values.flatMap { $0 }.map { $0.0 * 8 + $0.1 })
            func color(_ px: Int, _ py: Int) -> RGB {
                let key = px * 8 + py
                return lit.contains(key) ? skin.lit : all.contains(key) ? skin.ghost : skin.display
            }
            for cx in 0..<4 {
                for row in 0..<4 {
                    let upper = color(cx, row * 2)
                    let lower = color(cx, row * 2 + 1)
                    if upper == lower {
                        canvas.put(column + cx, y + row, upper == skin.display ? " " : "█", fg: upper, bg: skin.display)
                    } else {
                        canvas.put(column + cx, y + row, "▀", fg: upper, bg: lower)
                    }
                }
            }
            column += 5
        }
    }
}
