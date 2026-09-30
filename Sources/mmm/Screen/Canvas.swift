import Foundation

/// A 24-bit color.
struct RGB: Equatable, Hashable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(_ hex: UInt32) {
        r = UInt8(hex >> 16 & 0xFF)
        g = UInt8(hex >> 8 & 0xFF)
        b = UInt8(hex & 0xFF)
    }

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Mixes `amount` (0–1) of `other` into this color.
    func mixed(with other: RGB, _ amount: Double) -> RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - amount) + Double(b) * amount).rounded()) }
        return RGB(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b))
    }
}

/// One character cell: every glyph drawn is one column wide.
struct Cell: Equatable, Sendable {
    var char: Character
    var fg: RGB
    var bg: RGB
    var bold: Bool
}

/// A clickable area of the screen.
struct HitRegion: Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let action: ScreenAction

    func contains(_ column: Int, _ row: Int) -> Bool {
        column >= x && column < x + width && row >= y && row < y + height
    }
}

/// What a click on the screen does.
enum ScreenAction: Sendable, Equatable {
    case resume, pause, stop, name, note, visualizer, skin, help, follow
    /// Before recording: everyone has agreed to it, or not yet.
    case consent, decline
    /// After saving: another recording, the minutes, or done.
    case newMeeting, open, reveal, quit
    /// Before recording or after saving: transcribe a recording instead, chosen in the Open window.
    case openRecording
}

/// An off-screen grid of cells that views draw into; `Screen` puts it on the terminal.
struct Canvas {
    let width: Int
    let height: Int
    var cells: [Cell]
    var regions: [HitRegion] = []

    init(width: Int, height: Int, background: RGB) {
        self.width = width
        self.height = height
        cells = Array(repeating: Cell(char: " ", fg: background, bg: background, bold: false), count: width * height)
    }

    subscript(x: Int, y: Int) -> Cell {
        get { cells[y * width + x] }
        set { cells[y * width + x] = newValue }
    }

    mutating func put(_ x: Int, _ y: Int, _ char: Character, fg: RGB? = nil, bg: RGB? = nil, bold: Bool = false) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        var cell = self[x, y]
        cell.char = char
        if let fg { cell.fg = fg }
        if let bg { cell.bg = bg }
        cell.bold = bold
        self[x, y] = cell
    }

    /// Writes text left to right, clipped at `limit` columns (or the canvas edge).
    mutating func text(
        _ x: Int, _ y: Int, _ string: String, fg: RGB? = nil, bg: RGB? = nil, bold: Bool = false, limit: Int? = nil
    ) {
        var column = x
        let end = min(width, limit.map { x + $0 } ?? width)
        for char in string {
            guard column < end else { break }
            put(column, y, char, fg: fg, bg: bg, bold: bold)
            column += 1
        }
    }

    mutating func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, bg: RGB, char: Character = " ", fg: RGB? = nil) {
        for row in max(y, 0)..<max(y, 0, min(y + h, height)) {
            for column in max(x, 0)..<max(x, 0, min(x + w, width)) {
                self[column, row] = Cell(char: char, fg: fg ?? bg, bg: bg, bold: false)
            }
        }
    }

    /// A box drawn with line characters, optionally filled, with a title set into its top edge.
    mutating func box(
        _ x: Int, _ y: Int, _ w: Int, _ h: Int, border: RGB, fill: RGB? = nil, lines: BoxLines = .rounded,
        title: String? = nil, titleColor: RGB? = nil
    ) {
        guard w >= 2, h >= 2 else { return }
        if let fill { self.fill(x, y, w, h, bg: fill) }
        put(x, y, lines.topLeft, fg: border)
        put(x + w - 1, y, lines.topRight, fg: border)
        put(x, y + h - 1, lines.bottomLeft, fg: border)
        put(x + w - 1, y + h - 1, lines.bottomRight, fg: border)
        for column in (x + 1)..<(x + w - 1) {
            put(column, y, lines.horizontal, fg: border)
            put(column, y + h - 1, lines.horizontal, fg: border)
        }
        for row in (y + 1)..<(y + h - 1) {
            put(x, row, lines.vertical, fg: border)
            put(x + w - 1, row, lines.vertical, fg: border)
        }
        if let title { text(x + 2, y, " \(title) ", fg: titleColor ?? border, bold: true, limit: w - 4) }
    }

    /// Writes a transcript line, setting redaction placeholders like [NAME] apart in their own colors.
    mutating func rich(
        _ x: Int, _ y: Int, _ line: String, fg: RGB, bg: RGB? = nil, token: RGB, tokenBackground: RGB? = nil,
        tokenBold: Bool = false, limit: Int
    ) {
        var column = x
        for segment in ScreenModel.segments(line) {
            let room = x + limit - column
            guard room > 0 else { break }
            text(
                column, y, segment.text, fg: segment.token ? token : fg, bg: segment.token ? tokenBackground ?? bg : bg,
                bold: segment.token && tokenBold, limit: room)
            column += segment.text.count
        }
    }

    mutating func region(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ action: ScreenAction) {
        regions.append(HitRegion(x: x, y: y, width: w, height: h, action: action))
    }
}

/// The characters a box is drawn with.
struct BoxLines {
    let topLeft: Character
    let topRight: Character
    let bottomLeft: Character
    let bottomRight: Character
    let horizontal: Character
    let vertical: Character

    static let rounded = BoxLines(
        topLeft: "╭", topRight: "╮", bottomLeft: "╰", bottomRight: "╯", horizontal: "─", vertical: "│")
    static let double = BoxLines(
        topLeft: "╔", topRight: "╗", bottomLeft: "╚", bottomRight: "╝", horizontal: "═", vertical: "║")
}

extension String {
    /// Cuts to at most `width` characters, ending in an ellipsis if anything was cut.
    func clipped(_ width: Int) -> String {
        guard count > width else { return self }
        return width > 1 ? prefix(width - 1) + "…" : String(prefix(max(width, 0)))
    }
}
