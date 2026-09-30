import Darwin
import Foundation
import Synchronization

/// Minimal full-screen terminal control: raw keyboard input, the alternate screen, and ANSI styling.
final class Terminal: Sendable {
    static let isInteractive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1

    private let original = Mutex<termios?>(nil)
    /// Bumped whenever a key reader starts or stops; each reader runs while it's current.
    private let readerGeneration = Atomic<Int>(0)
    private let fullScreen = Atomic<Bool>(false)

    var size: (columns: Int, rows: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return (100, 30) }
        return (Int(size.ws_col), Int(size.ws_row))
    }

    /// Switches to the alternate screen with unbuffered, unechoed input. Ctrl-C still raises SIGINT.
    func enterFullScreen() {
        guard !fullScreen.exchange(true, ordering: .relaxed) else { return }
        var attributes = termios()
        tcgetattr(STDIN_FILENO, &attributes)
        original.withLock { $0 = attributes }
        attributes.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        // Alternate screen, hidden cursor, no line wrap, mouse clicks and wheel (SGR reports), and
        // pastes marked as such.
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h")
    }

    func leaveFullScreen() {
        guard fullScreen.exchange(false, ordering: .relaxed) else { return }
        stopReadingKeys()
        write("\u{1B}[?2004l\u{1B}[?1000l\u{1B}[?1006l\u{1B}[?7h\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        if var attributes = original.withLock({ $0 }) {
            tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        }
    }

    /// Delivers keys and mouse events until `stopReadingKeys()`. Polls so the reader can stop
    /// without consuming input meant for a later prompt.
    func keys() -> AsyncStream<Key> {
        let generation = readerGeneration.wrappingAdd(1, ordering: .relaxed).newValue
        return AsyncStream { continuation in
            let thread = Thread { [self] in
                var parser = KeyParser()
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                while readerGeneration.load(ordering: .relaxed) == generation {
                    guard poll(&descriptor, 1, 50) > 0 else {
                        for key in parser.idle() { continuation.yield(key) }
                        continue
                    }
                    // A newer reader may have started while this one waited: leave the input to it.
                    guard readerGeneration.load(ordering: .relaxed) == generation else { break }
                    var byte: UInt8 = 0
                    let count = read(STDIN_FILENO, &byte, 1)
                    if count == 1 {
                        for key in parser.feed(byte) { continuation.yield(key) }
                    } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                        break  // the terminal has gone, e.g. its window was closed
                    }
                }
                continuation.finish()
            }
            thread.start()
        }
    }

    func stopReadingKeys() {
        readerGeneration.wrappingAdd(1, ordering: .relaxed)
    }

    /// Writes to the terminal, quietly doing nothing once it has gone (its window was closed).
    func write(_ text: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    }
}

/// ANSI styling helpers. Plain text when output isn't a terminal.
enum Style {
    static let enabled = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func bold(_ text: String) -> String { wrap(text, "1") }
    static func dim(_ text: String) -> String { wrap(text, "2") }
    static func color(_ text: String, _ code: Int) -> String { wrap(text, "38;5;\(code)") }
    static func red(_ text: String) -> String { wrap(text, "31") }
    static func yellow(_ text: String) -> String { wrap(text, "33") }
    static func green(_ text: String) -> String { wrap(text, "32") }

    private static func wrap(_ text: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    /// Distinct 256-color codes for speakers; room speakers take warm colors, remote ones cool.
    static let roomColors = [214, 43, 177, 221, 209, 150]
    static let remoteColors = [75, 141, 80, 111, 176, 117]
}

extension String {
    /// Visible width, ignoring ANSI escape sequences.
    var visibleWidth: Int {
        var width = 0
        var inEscape = false
        for scalar in unicodeScalars {
            if inEscape {
                if (0x40...0x7E).contains(scalar.value) && scalar != "[" { inEscape = false }
            } else if scalar == "\u{1B}" {
                inEscape = true
            } else {
                width += 1
            }
        }
        return width
    }

    /// Cuts the string at `width` visible columns, keeping escape sequences intact and resetting
    /// styles if anything was cut, so a line can never wrap and break the layout.
    func truncated(toVisibleWidth width: Int) -> String {
        guard visibleWidth > width else { return self }
        var result = ""
        var visible = 0
        var inEscape = false
        for scalar in unicodeScalars {
            if inEscape {
                result.unicodeScalars.append(scalar)
                if (0x40...0x7E).contains(scalar.value) && scalar != "[" { inEscape = false }
            } else if scalar == "\u{1B}" {
                inEscape = true
                result.unicodeScalars.append(scalar)
            } else if visible < width {
                result.unicodeScalars.append(scalar)
                visible += 1
            }
        }
        return result + "\u{1B}[0m"
    }

    /// Word-wraps plain text to `width` columns.
    func wrapped(to width: Int) -> [String] {
        guard width > 0 else { return [self] }
        var lines: [String] = []
        var line = ""
        for word in split(separator: " ", omittingEmptySubsequences: true) {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = String(word)
            }
            while line.count > width {
                lines.append(String(line.prefix(width)))
                line = String(line.dropFirst(width))
            }
        }
        if !line.isEmpty || lines.isEmpty { lines.append(line) }
        return lines
    }
}
