import Darwin
import FluidAudio
import Foundation

/// Where mmm's own diagnostics go. FluidAudio writes timing lines straight to stderr, which would
/// scribble over the live screen, so `quietLibraries()` points the process's stderr at /dev/null
/// and mmm keeps a handle to the real one. Set MMM_DEBUG to leave stderr alone.
enum Console {
    static let errors = FileHandle(fileDescriptor: dup(STDERR_FILENO), closeOnDealloc: true)

    static func quietLibraries() {
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
        guard ProcessInfo.processInfo.environment["MMM_DEBUG"] == nil else { return }
        _ = errors
        let null = open("/dev/null", O_WRONLY)
        guard null >= 0 else { return }
        dup2(null, STDERR_FILENO)
        close(null)
    }

    static func note(_ message: String) {
        errors.write(Data((message + "\n").utf8))
    }
}
