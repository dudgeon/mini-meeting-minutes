import Foundation

/// A key press or mouse event from the terminal.
enum Key: Sendable, Equatable {
    case char(Character)
    case enter, escape, backspace, tab
    case up, down, pageUp, pageDown, home, end
    /// A left click on a cell (zero-based).
    case click(x: Int, y: Int)
    case wheelUp, wheelDown
    /// Pasted text, delivered whole (bracketed paste), so a paste can't set off shortcuts.
    case paste(String)
    /// F1 to F12, by number. On a Mac keyboard the ⏯ key is F8, with fn held.
    case function(Int)
}

/// Turns raw terminal input bytes into `Key`s: UTF-8 text, control keys, escape sequences for
/// arrows and paging, SGR mouse reports, and bracketed pastes.
struct KeyParser {
    private static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)
    private static let functionKeys: [String: Int] = [
        "P": 1, "Q": 2, "R": 3, "S": 4, "15~": 5, "17~": 6, "18~": 7, "19~": 8, "20~": 9, "21~": 10, "23~": 11,
        "24~": 12,
    ]

    /// F1 to F12 from the end of an escape sequence: "P" to "S" for F1–F4, "15~" to "24~" above,
    /// with any modifiers (";2") dropped.
    private static func functionKey(_ sequence: String) -> Int? {
        if sequence.hasSuffix("~") {
            return functionKeys[(sequence.dropLast().split(separator: ";").first.map(String.init) ?? "") + "~"]
        }
        guard let last = sequence.last, "PQRS".contains(last),
            sequence.dropLast().allSatisfy({ $0.isNumber || $0 == ";" })
        else { return nil }
        return functionKeys[String(last)]
    }

    private var escape: [UInt8] = []
    private var utf8: [UInt8] = []
    private var utf8Needed = 0
    /// Text pasted so far, between the terminal's paste start and end markers.
    private var pasted: [UInt8]?

    mutating func feed(_ byte: UInt8) -> [Key] {
        if pasted != nil { return continuePaste(byte) }
        if !escape.isEmpty { return continueEscape(byte) }
        if utf8Needed > 0 {
            utf8.append(byte)
            utf8Needed -= 1
            guard utf8Needed == 0 else { return [] }
            defer { utf8.removeAll() }
            return String(bytes: utf8, encoding: .utf8).flatMap(\.first).map { [.char($0)] } ?? []
        }
        switch byte {
        case 0x1B:
            escape = [byte]
            return []
        case 0x0D, 0x0A: return [.enter]
        case 0x7F, 0x08: return [.backspace]
        case 0x09: return [.tab]
        case 0x20...0x7E: return [.char(Character(UnicodeScalar(byte)))]
        case 0xC0...0xDF: utf8Needed = 1
        case 0xE0...0xEF: utf8Needed = 2
        case 0xF0...0xF7: utf8Needed = 3
        default: return []
        }
        utf8 = [byte]
        return []
    }

    /// No more input arrived for a moment: a lone Escape was the Escape key.
    mutating func idle() -> [Key] {
        guard escape == [0x1B] else { return [] }
        escape.removeAll()
        return [.escape]
    }

    private mutating func continueEscape(_ byte: UInt8) -> [Key] {
        escape.append(byte)
        if escape.count == 2 {
            // ESC [ and ESC O start sequences; anything else was Escape followed by a key.
            guard byte == UInt8(ascii: "[") || byte == UInt8(ascii: "O") else {
                escape.removeAll()
                return [.escape] + feed(byte)
            }
            return []
        }
        guard (0x40...0x7E).contains(byte), escape.count < 32 else {
            if escape.count >= 32 { escape.removeAll() }
            return []
        }
        let sequence = String(decoding: escape.dropFirst(2), as: UTF8.self)
        escape.removeAll()
        if let number = Self.functionKey(sequence) { return [.function(number)] }
        switch sequence {
        case "A": return [.up]
        case "B": return [.down]
        case "H", "1~", "7~": return [.home]
        case "F", "4~", "8~": return [.end]
        case "5~": return [.pageUp]
        case "6~": return [.pageDown]
        case "200~":
            pasted = []
            return []
        default: break
        }
        // SGR mouse: ESC [ < button ; column ; row (M press | m release)
        guard sequence.hasPrefix("<"), sequence.hasSuffix("M") else { return [] }
        let numbers = sequence.dropFirst().dropLast().split(separator: ";").compactMap { Int($0) }
        guard numbers.count == 3 else { return [] }
        switch numbers[0] {
        case 64: return [.wheelUp]
        case 65: return [.wheelDown]
        case 0: return [.click(x: numbers[1] - 1, y: numbers[2] - 1)]
        default: return []
        }
    }

    private mutating func continuePaste(_ byte: UInt8) -> [Key] {
        pasted?.append(byte)
        guard let text = pasted, text.count >= Self.pasteEnd.count,
            text.suffix(Self.pasteEnd.count).elementsEqual(Self.pasteEnd)
        else { return [] }
        pasted = nil
        return [.paste(String(decoding: text.dropLast(Self.pasteEnd.count), as: UTF8.self))]
    }
}
