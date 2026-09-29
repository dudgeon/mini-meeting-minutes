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
    case resume, pause, stop, name, visualizer, skin, help, follow
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
        for row in max(y, 0)..<min(y + h, height) {
            for column in max(x, 0)..<min(x + w, width) {
                self[column, row] = Cell(char: char, fg: fg ?? bg, bg: bg, bold: false)
            }
        }
    }

    mutating func region(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ action: ScreenAction) {
        regions.append(HitRegion(x: x, y: y, width: w, height: h, action: action))
    }
}

extension String {
    /// Pads with spaces or cuts to exactly `width` characters.
    func fitted(_ width: Int) -> String {
        count >= width ? String(prefix(width)) : self + String(repeating: " ", count: width - count)
    }
}
