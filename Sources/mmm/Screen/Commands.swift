import Foundation

/// What can be typed after a slash while a meeting runs. During a meeting the prompt box always
/// takes a note, so commands start with a slash: then no sentence typed into it, "quick
/// question" or "please pause", can stop, pause or rearrange the meeting by accident.
enum Command: String, CaseIterable, Sendable {
    case stop, pause, name, mic, look, visual, help

    /// Other words that run it: `/resume` while paused, `/synthwave` and so on.
    var aliases: [String] {
        switch self {
        case .pause: ["resume"]
        case .mic: ["microphone"]
        case .look: ["synthwave", "sidebar", "skin"]
        case .visual: ["visualizer"]
        default: []
        }
    }

    /// What it does, for the menu and the help.
    var summary: String {
        switch self {
        case .stop: "stop and save the minutes"
        case .pause: "pause or resume (paused audio is dropped, not kept)"
        case .name: "name the speakers"
        case .mic: "choose the microphone"
        case .look: "switch between the sidebar and synthwave looks"
        case .visual: "visualizer: spectrum, waveform or off"
        case .help: "all the commands and keys"
        }
    }

    var action: ScreenAction {
        switch self {
        case .stop: .stop
        case .pause: .pause
        case .name: .name
        case .mic: .chooseMicrophone
        case .look: .skin
        case .visual: .visualizer
        case .help: .help
        }
    }

    /// Whether the prompt box holds a command rather than a note: a slash, then one word.
    static func isCommand(_ text: String) -> Bool {
        text.hasPrefix("/") && !text.dropFirst().contains(where: \.isWhitespace)
    }

    /// Commands that what's typed could be the start of.
    static func matching(_ text: String) -> [Command] {
        guard isCommand(text) else { return [] }
        let typed = text.dropFirst().lowercased()
        return allCases.filter { command in ([command.rawValue] + command.aliases).contains { $0.hasPrefix(typed) } }
    }

    /// The command Return runs: one named exactly, else the only one that fits.
    static func chosen(_ text: String) -> Command? {
        let matches = matching(text)
        let typed = String(text.dropFirst().lowercased())
        return matches.first { ([$0.rawValue] + $0.aliases).contains(typed) } ?? (matches.count == 1 ? matches[0] : nil)
    }
}
