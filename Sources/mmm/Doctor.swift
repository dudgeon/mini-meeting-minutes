import ArgumentParser
import Foundation
import MinutesCore

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the models, macOS version and capture permissions.")

    @Flag(help: "Also verify every model file's SHA-256 and load the models.")
    var full = false

    func run() async throws {
        var healthy = true
        func report(_ ok: Bool, _ message: String, _ help: String? = nil) {
            print((ok ? Style.green("✓") : Style.red("✗")) + " " + message)
            if let help, !ok { print("  " + Style.dim(help)) }
            if !ok { healthy = false }
        }
        func note(_ message: String) { print(Style.yellow("•") + " " + message) }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        report(
            version.majorVersion >= 15, "macOS \(version.majorVersion).\(version.minorVersion)",
            "Parakeet Redux needs macOS 15 or later.")
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        report(machine == "arm64", "Apple silicon (\(machine))", "mini-meeting-minutes needs an Apple silicon Mac.")

        do {
            let store = try ModelStore.locate()
            try store.prepare()
            report(true, "Models at \(LiveView.abbreviate(store.root.path))")
            for source in store.sources {
                print("  " + Style.dim("\(source.name): \(source.repo)@\(source.revision.prefix(8)) (\(source.license))"))
            }
            if full {
                let problems = store.verify()
                report(problems.isEmpty, "Model checksums", problems.joined(separator: "\n  "))
                let start = Date()
                _ = try ModelLoader.load(from: store)
                report(true, String(format: "Models load (%.1f s)", Date().timeIntervalSince(start)))
            }
        } catch {
            report(false, "Models", error.localizedDescription)
        }

        let responsible = AudioPermissions.responsibleProcess()?.path ?? "your terminal"
        let app = responsible.components(separatedBy: "/").first { $0.hasSuffix(".app") } ?? responsible
        print(Style.dim("Permissions are granted to the app that runs mmm: \(app)"))

        switch AudioPermissions.microphoneStatus {
        case .authorized: report(true, "Microphone access")
        case .notDetermined: note("Microphone access not requested yet; `mmm` asks on first run.")
        default:
            report(
                false, "Microphone access denied",
                "System Settings › Privacy & Security › Microphone: enable \(app).")
        }

        switch AudioPermissions.systemAudioStatus() {
        case .authorized: report(true, "System audio recording access")
        case .notDetermined: note("System audio access not requested yet; `mmm` asks on first run.")
        case .denied:
            report(false, "System audio recording denied", Record.systemPermissionHelp)
        case .unavailable:
            note("Can't read the system audio permission. If remote speech is missing: " + Record.systemPermissionHelp)
        }

        let inputs = AudioDevices.inputs()
        if inputs.isEmpty {
            note("No microphone found. Use `mmm --no-mic` to record system audio only.")
        } else {
            print(Style.dim("Input devices (use a UID with `mmm --mic-device`):"))
            for device in inputs {
                print("  " + (device.isDefault ? "* " : "  ") + device.name + Style.dim("  \(device.uid)"))
            }
        }
        if !healthy { throw ExitCode.failure }
    }
}
