import ArgumentParser
import MinutesCore

/// A color scheme for the retro screen. Winamp was all about skins.
struct Skin: Sendable {
    let name: String
    let background: RGB
    let chrome: RGB  // window bodies
    let chromeLight: RGB  // bevel highlight
    let chromeDark: RGB  // bevel shadow
    let stripe: RGB  // title bar stripes
    let title: RGB
    let display: RGB  // LCD and transcript backgrounds
    let lit: RGB  // LCD segments, lit LEDs
    let ghost: RGB  // unlit LCD segments
    let displayText: RGB
    let displayDim: RGB
    let transcriptText: RGB
    let transcriptDim: RGB
    let selection: RGB  // the live line
    let selectionText: RGB
    let record: RGB
    let button: RGB
    let buttonText: RGB
    let key: RGB
    let hint: RGB
    let peak: RGB
    let warning: RGB
    /// Bottom to top.
    let spectrum: [RGB]
    let roomSpeakers: [RGB]
    let remoteSpeakers: [RGB]

    func color(for speaker: SpeakerID) -> RGB {
        let palette = speaker.channel == .room ? roomSpeakers : remoteSpeakers
        return palette[(speaker.number - 1) % palette.count]
    }

    func spectrumColor(row: Int, of rows: Int) -> RGB {
        spectrum[min(spectrum.count - 1, row * spectrum.count / max(rows, 1))]
    }

    static let classic = Skin(
        name: "classic",
        background: RGB(0x0B0B12), chrome: RGB(0x272739), chromeLight: RGB(0x55557A), chromeDark: RGB(0x131320),
        stripe: RGB(0xC9A043), title: RGB(0xFFE7A3), display: RGB(0x030803), lit: RGB(0x3DFF5F),
        ghost: RGB(0x0D2412), displayText: RGB(0x34E35A), displayDim: RGB(0x1D6B2C),
        transcriptText: RGB(0x1EE61E), transcriptDim: RGB(0x0F7A1F), selection: RGB(0x1010C8),
        selectionText: RGB(0xFFFFFF), record: RGB(0xFF2E4D), button: RGB(0x3A3A55), buttonText: RGB(0xE8E8F5),
        key: RGB(0xFFB000), hint: RGB(0x8A8AA8), peak: RGB(0xD8D8D8), warning: RGB(0xFFB000),
        spectrum: [
            RGB(0x009B12), RGB(0x1FB510), RGB(0x58CC0E), RGB(0x98DE0C), RGB(0xD7EA0A), RGB(0xFFD000),
            RGB(0xFF8A00), RGB(0xFF3A00),
        ],
        roomSpeakers: [RGB(0xFFB000), RGB(0xFF5FA2), RGB(0xC38BFF), RGB(0xFF8F6B)],
        remoteSpeakers: [RGB(0x34D6FF), RGB(0xFFE14D), RGB(0xFF7A45), RGB(0x9DF0B0)])

    static let synthwave = Skin(
        name: "synthwave",
        background: RGB(0x0D0221), chrome: RGB(0x1D0B3A), chromeLight: RGB(0x6B3FA0), chromeDark: RGB(0x08010F),
        stripe: RGB(0xFF2A6D), title: RGB(0xFFD1F0), display: RGB(0x05010D), lit: RGB(0x05D9E8),
        ghost: RGB(0x10193A), displayText: RGB(0x05D9E8), displayDim: RGB(0x1A5F7A),
        transcriptText: RGB(0xD1F7FF), transcriptDim: RGB(0x6B5B95), selection: RGB(0xFF2A6D),
        selectionText: RGB(0xFFFFFF), record: RGB(0xFF2A6D), button: RGB(0x3B1A6B), buttonText: RGB(0xF7E7FF),
        key: RGB(0xF9C80E), hint: RGB(0x8C7AB8), peak: RGB(0xFFFFFF), warning: RGB(0xF9C80E),
        spectrum: [
            RGB(0x3A0CA3), RGB(0x5A189A), RGB(0x7B2CBF), RGB(0x9D4EDD), RGB(0xC77DFF), RGB(0xFF4ECD),
            RGB(0xFF2A6D), RGB(0xFF9E00),
        ],
        roomSpeakers: [RGB(0xF9C80E), RGB(0xFF6C11), RGB(0xFF4ECD), RGB(0xFFA7C4)],
        remoteSpeakers: [RGB(0x05D9E8), RGB(0x7CFFCB), RGB(0xC77DFF), RGB(0x8FB8FF)])

    static let all = [classic, synthwave]
}

/// The `--skin` option.
enum SkinName: String, ExpressibleByArgument, CaseIterable {
    case classic, synthwave

    var skin: Skin { self == .classic ? .classic : .synthwave }
}
