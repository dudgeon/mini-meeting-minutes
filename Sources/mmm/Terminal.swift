import Darwin
import Foundation
import Synchronization

/// Minimal full-screen terminal control: raw keyboard input, the alternate screen, and ANSI styling.
final class Terminal: Sendable {
    static let isInteractive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1

    private let original = Mutex<termios?>(nil)
    private let reading = Atomic<Bool>(false)

    var size: (columns: Int, rows: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return (100, 30) }
        return (Int(size.ws_col), Int(size.ws_row))
    }

    /// Switches to the alternate screen with unbuffered, unechoed input. Ctrl-C still raises SIGINT.
    func enterFullScreen() {
        var attributes = termios()
        tcgetattr(STDIN_FILENO, &attributes)
        original.withLock { $0 = attributes }
        attributes.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        write("\u{1B}[?1049h\u{1B}[?25l")
    }

    func leaveFullScreen() {
        stopReadingKeys()
        write("\u{1B}[?25h\u{1B}[?1049l")
        if var attributes = original.withLock({ $0 }) {
            tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        }
    }

    /// Delivers key presses until `stopReadingKeys()`. Polls so the reader can stop without
    /// consuming input meant for a later prompt.
    func keys() -> AsyncStream<UInt8> {
        reading.store(true, ordering: .relaxed)
        return AsyncStream { continuation in
            let thread = Thread { [self] in
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                while reading.load(ordering: .relaxed) {
                    guard poll(&descriptor, 1, 100) > 0 else { continue }
                    var byte: UInt8 = 0
                    if read(STDIN_FILENO, &byte, 1) == 1 { continuation.yield(byte) }
                }
                continuation.finish()
            }
            thread.start()
        }
    }

    func stopReadingKeys() {
        reading.store(false, ordering: .relaxed)
    }

    func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
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
