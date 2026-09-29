import Foundation

/// Puts canvases on the terminal. Only cells that changed since the previous frame are sent,
/// inside a synchronized update, so nothing flickers or tears even at 20 frames a second.
final class Screen {
    enum ColorMode { case truecolor, palette256 }

    let colorMode: ColorMode
    private var previous: [Cell]?
    private var size = (width: 0, height: 0)
    private var nearest: [RGB: Int] = [:]

    init() {
        let environment = ProcessInfo.processInfo.environment
        if let forced = environment["MMM_COLOR"] {
            colorMode = forced == "256" ? .palette256 : .truecolor
        } else {
            let advertised = (environment["COLORTERM"] ?? "").lowercased()
            colorMode = advertised.contains("truecolor") || advertised.contains("24bit") ? .truecolor : .palette256
        }
    }

    /// Escape sequences that turn the last frame into `canvas`.
    func frame(_ canvas: Canvas) -> String {
        var output = "\u{1B}[?2026h"
        let full = previous == nil || size != (canvas.width, canvas.height)
        if full { output += "\u{1B}[0m\u{1B}[2J" }
        var style: (fg: RGB, bg: RGB, bold: Bool)?
        var cursor: (x: Int, y: Int)?
        for y in 0..<canvas.height {
            for x in 0..<canvas.width {
                let cell = canvas[x, y]
                if !full, let previous, previous[y * canvas.width + x] == cell { continue }
                if cursor.map({ $0 != (x, y) }) ?? true { output += "\u{1B}[\(y + 1);\(x + 1)H" }
                if style.map({ $0.fg != cell.fg || $0.bg != cell.bg || $0.bold != cell.bold }) ?? true {
                    output += sgr(cell)
                    style = (cell.fg, cell.bg, cell.bold)
                }
                output.append(cell.char)
                cursor = (x + 1, y)
            }
        }
        previous = canvas.cells
        size = (canvas.width, canvas.height)
        return output + "\u{1B}[0m\u{1B}[?2026l"
    }

    /// Forces the next frame to redraw everything.
    func invalidate() {
        previous = nil
    }

    private func sgr(_ cell: Cell) -> String {
        let weight = cell.bold ? "1" : "22"
        switch colorMode {
        case .truecolor:
            return "\u{1B}[\(weight);38;2;\(cell.fg.r);\(cell.fg.g);\(cell.fg.b);48;2;\(cell.bg.r);\(cell.bg.g);\(cell.bg.b)m"
        case .palette256:
            return "\u{1B}[\(weight);38;5;\(index(cell.fg));48;5;\(index(cell.bg))m"
        }
    }

    /// The closest of the terminal's 256 standard colors (the 6×6×6 cube or the gray ramp).
    private func index(_ color: RGB) -> Int {
        if let known = nearest[color] { return known }
        let levels = [0, 95, 135, 175, 215, 255]
        func level(_ value: UInt8) -> Int {
            levels.indices.min { abs(levels[$0] - Int(value)) < abs(levels[$1] - Int(value)) }!
        }
        func distance(_ r: Int, _ g: Int, _ b: Int) -> Int {
            let dr = r - Int(color.r), dg = g - Int(color.g), db = b - Int(color.b)
            return 2 * dr * dr + 4 * dg * dg + 3 * db * db
        }
        let (r, g, b) = (level(color.r), level(color.g), level(color.b))
        var best = (index: 16 + 36 * r + 6 * g + b, distance: distance(levels[r], levels[g], levels[b]))
        let average = (Int(color.r) + Int(color.g) + Int(color.b)) / 3
        let step = max(0, min(23, (average - 3) / 10))
        let gray = 8 + step * 10
        if distance(gray, gray, gray) < best.distance { best = (232 + step, 0) }
        nearest[color] = best.index
        return best.index
    }
}
