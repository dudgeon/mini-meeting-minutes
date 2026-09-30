import ArgumentParser
import Foundation
import MinutesCore

/// First-run help: explains macOS's permission prompts before they appear, and walks through
/// fixing a denied permission.
enum Setup {
    static let microphoneSettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let systemAudioSettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    /// The app macOS asks permission for: the terminal running mmm, e.g. "Terminal" or "iTerm".
    static var hostApp: String {
        let path = AudioPermissions.responsibleProcess()?.path ?? ""
        let bundle = path.split(separator: "/").first { $0.hasSuffix(".app") }
        return bundle.map { String($0.dropLast(4)) } ?? "Terminal"
    }

    /// Checks devices and permissions for the channels about to be recorded, explaining any
    /// permission prompt first. Returns the channels that can actually be recorded.
    static func prepare(_ requested: Set<Channel>) throws -> Set<Channel> {
        var channels = requested
        if channels.contains(.room) && AudioDevices.inputs().isEmpty {
            guard channels.contains(.remote) else {
                throw FriendlyError("This Mac has no microphone. Connect one, or record a call with `mmm --no-mic`.")
            }
            print(Style.dim("No microphone found yet. Your call audio is recorded, and a microphone you connect is used too."))
            channels.remove(.room)
        }
        guard Terminal.isInteractive else { return channels }

        let app = hostApp
        if channels.contains(.room) && [.denied, .restricted].contains(AudioPermissions.microphoneStatus) {
            try blocked(
                "Mini Meeting Minutes isn't allowed to use the microphone.",
                fix: "In System Settings › Privacy & Security › Microphone, turn on \(app).",
                settings: microphoneSettings)
        }
        if channels.contains(.remote) && AudioPermissions.systemAudioStatus() == .denied {
            try blocked(
                "Mini Meeting Minutes isn't allowed to hear your calls.",
                fix: "In System Settings › Privacy & Security › Screen & System Audio Recording, turn on \(app) "
                    + "under System Audio Recording Only.",
                settings: systemAudioSettings)
        }

        var prompts: [String] = []
        if channels.contains(.room) && AudioPermissions.microphoneStatus == .notDetermined {
            prompts.append("the microphone, to hear people in the room")
        }
        if channels.contains(.remote) && AudioPermissions.systemAudioStatus() == .notDetermined {
            prompts.append("system audio, to hear people on your call")
        }
        guard !prompts.isEmpty else { return channels }
        print("")
        print(Style.bold("Welcome to Mini Meeting Minutes!"))
        print("Your Mac will now ask for permission to use:")
        for prompt in prompts { print("  • " + prompt) }
        print("The request will say \(Style.bold("“\(app)”")): that's expected, it's the app running Mini Meeting Minutes.")
        print("Click \(Style.bold("Allow")). Everything stays on this Mac, and no audio is ever saved.")
        print("")
        _ = ask("Press Return to continue…")
        return channels
    }

    /// Explains a denied permission, offers to open the right Settings page, and stops.
    static func blocked(_ problem: String, fix: String, settings: String) throws -> Never {
        print("")
        print(Style.bold(problem))
        print(fix)
        print("Then start Mini Meeting Minutes again.")
        if ask("\nPress Return to open System Settings…") != nil { open(settings) }
        throw ExitCode.failure
    }

    /// After a recording: says where the minutes are and offers to open them.
    static func finished(_ url: URL, turns: Int, speakers: Int, offerToOpen: Bool = true) {
        let minutesFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Minutes").path
        let place =
            url.deletingLastPathComponent().path == minutesFolder
            ? "Documents › Minutes › \(url.lastPathComponent)" : LiveView.abbreviate(url.path)
        print("")
        print(Style.green("✓ Saved your minutes") + "  " + Style.dim("(\(turns) turns, \(speakers) speakers)"))
        print("  " + place)
        guard offerToOpen, Terminal.isInteractive else { return }
        if ask("\nPress Return to open them, or close this window.") != nil {
            openMinutes(url.path)
        }
    }

    @discardableResult
    static func ask(_ prompt: String) -> String? {
        print(prompt, terminator: " ")
        fflush(stdout)
        return readLine()
    }

    static func open(_ target: String) {
        run("/usr/bin/open", [target])
    }

    /// Opens minutes in TextEdit, which is on every Mac; they're plain text with light markdown.
    static func openMinutes(_ path: String) {
        run("/usr/bin/open", ["-e", path])
    }

    static func showInFinder(_ path: String) {
        run("/usr/bin/open", ["-R", path])
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}

/// An error shown as a plain sentence, without command-line usage help.
struct FriendlyError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
