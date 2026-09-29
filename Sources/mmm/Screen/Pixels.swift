import Foundation

/// A small picture for the terminal, drawn two pixels per character cell with half blocks.
/// Pixels left empty show whatever is behind them.
struct Bitmap {
    let width: Int
    let height: Int
    private var pixels: [RGB?]

    init(width: Int, height: Int) {
        self.width = max(width, 0)
        self.height = max(height, 0)
        pixels = Array(repeating: nil, count: self.width * self.height)
    }

    /// Reading outside the bitmap gives nothing; drawing outside it does nothing.
    subscript(x: Int, y: Int) -> RGB? {
        get { contains(x, y) ? pixels[y * width + x] : nil }
        set { if contains(x, y) { pixels[y * width + x] = newValue } }
    }

    private func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    mutating func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: RGB) {
        for row in max(y, 0)..<max(y, 0, min(y + h, height)) {
            for column in max(x, 0)..<max(x, 0, min(x + w, width)) {
                pixels[row * width + column] = color
            }
        }
    }

    /// A horizontal run of pixels from `x0` to `x1`, inclusive.
    mutating func row(_ y: Int, from x0: Int, to x1: Int, _ color: RGB) {
        fill(min(x0, x1), y, abs(x1 - x0) + 1, 1, color)
    }

    /// A straight line between two points, both included (Bresenham's algorithm).
    mutating func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ color: RGB) {
        let dx = abs(x1 - x0)
        let dy = -abs(y1 - y0)
        let stepX = x0 < x1 ? 1 : -1
        let stepY = y0 < y1 ? 1 : -1
        var (x, y, error) = (x0, y0, dx + dy)
        while true {
            self[x, y] = color
            if x == x1 && y == y1 { return }
            let doubled = 2 * error
            if doubled >= dy {
                error += dy
                x += stepX
            }
            if doubled <= dx {
                error += dx
                y += stepY
            }
        }
    }

    /// Draws a one-color pattern ("#" marks a pixel), coloring each of its rows with `color(row)`.
    mutating func stamp(_ pattern: [String], x: Int, y: Int, color: (Int) -> RGB) {
        for (dy, line) in pattern.enumerated() {
            let ink = color(dy)
            for (dx, char) in line.enumerated() where char == "#" {
                self[x + dx, y + dy] = ink
            }
        }
    }
}

extension Canvas {
    /// Draws a bitmap with its top-left pixel in cell (x, y). Each cell shows two pixels: the
    /// upper one as an upper-half block, the lower one as the cell's background.
    mutating func draw(_ bitmap: Bitmap, x: Int, y: Int) {
        for row in 0..<((bitmap.height + 1) / 2) {
            for column in 0..<bitmap.width {
                let (cx, cy) = (x + column, y + row)
                guard cx >= 0, cy >= 0, cx < width, cy < height else { continue }
                let upper = bitmap[column, row * 2]
                let lower = bitmap[column, row * 2 + 1]
                guard upper != nil || lower != nil else { continue }
                let behind = self[cx, cy].bg
                let (top, bottom) = (upper ?? behind, lower ?? behind)
                self[cx, cy] =
                    top == bottom
                    ? Cell(char: " ", fg: top, bg: top, bold: false) : Cell(char: "▀", fg: top, bg: bottom, bold: false)
            }
        }
    }
}

/// "MINUTES" as pixel art, for titles drawn with half blocks.
enum PixelTitle {
    /// Ten pixels tall, with two-pixel strokes.
    static let large = word(
        [
            ["##....##", "###..###", "########", "##.##.##", "##....##", "##....##", "##....##", "##....##",
             "##....##", "##....##"],
            Array(repeating: "##", count: 10),
            ["###..##", "###..##", "####.##", "####.##", "####.##", "##.####", "##.####", "##.####", "##..###",
             "##..###"],
            Array(repeating: "##...##", count: 8) + ["#######", ".#####."],
            ["######", "######"] + Array(repeating: "..##..", count: 8),
            ["######", "######", "##....", "##....", "#####.", "#####.", "##....", "##....", "######", "######"],
            [".######", "#######", "##.....", "##.....", "######.", ".######", ".....##", ".....##", "#######",
             "######."],
        ], spacing: 2)

    /// Six pixels tall, with one-pixel strokes.
    static let small = word(
        [
            ["#...#", "##.##", "#.#.#", "#...#", "#...#", "#...#"],
            Array(repeating: "#", count: 6),
            ["#..#", "##.#", "#.##", "#..#", "#..#", "#..#"],
            ["#..#", "#..#", "#..#", "#..#", "#..#", ".##."],
            ["#####", "..#..", "..#..", "..#..", "..#..", "..#.."],
            ["####", "#...", "###.", "#...", "#...", "####"],
            [".###", "#...", ".##.", "...#", "...#", "###."],
        ], spacing: 1)

    private static func word(_ letters: [[String]], spacing: Int) -> [String] {
        let gap = String(repeating: ".", count: spacing)
        return (0..<(letters.first?.count ?? 0)).map { row in letters.map { $0[row] }.joined(separator: gap) }
    }
}
