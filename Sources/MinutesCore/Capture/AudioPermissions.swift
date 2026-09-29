@preconcurrency import AVFoundation
import Darwin
import Foundation

/// Result of a TCC query. `unavailable` means the private SPI could not be resolved.
public enum TCCStatus: Sendable, Equatable {
    case authorized, denied, notDetermined, unavailable
}

/// Permission helpers for both capture paths.
///
/// System audio (process taps) is TCC service `kTCCServiceAudioCapture`, shown in System Settings >
/// Privacy & Security > Screen & System Audio Recording > "System Audio Recording Only".
/// There is no public preflight/request API for it; like insidegui/AudioCap
/// (AudioCap/ProcessTap/AudioRecordingPermission.swift) this uses the private TCC SPI via dlsym.
/// Do not ship private SPI in the Mac App Store.
///
/// TCC attributes a request to the *responsible process*. For a CLI started from a terminal that is
/// the terminal app, so the prompt names the terminal and the grant covers every program run in it.
public enum AudioPermissions {
    private static let tccPath = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    private static func tccSymbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(tccPath, RTLD_NOW), let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// Non-prompting. Observed on macOS 27: returns 2 (`notDetermined`) when never asked, matching
    /// AVCaptureDevice's `.notDetermined` for the microphone; AudioCap maps 0/1 to granted/denied.
    public static func systemAudioStatus() -> TCCStatus {
        guard let preflight = tccSymbol("TCCAccessPreflight", as: PreflightFn.self) else { return .unavailable }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unavailable
        }
    }

    /// Shows the "System Audio Recording" prompt if TCC is willing to prompt for the responsible app.
    /// Terminal.app can always prompt (private `com.apple.private.tcc.allow-prompting` entitlement);
    /// a third-party terminal needs `NSAudioCaptureUsageDescription` in *its* Info.plist (Ghostty has
    /// it, iTerm2 does not), otherwise this returns false without any UI and the tap records silence.
    public static func requestSystemAudio() async -> Bool {
        guard let request = tccSymbol("TCCAccessRequest", as: RequestFn.self) else { return false }
        return await withCheckedContinuation { continuation in
            request("kTCCServiceAudioCapture" as CFString, nil) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Prompts only when `.notDetermined`; otherwise returns the stored decision immediately.
    public static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// The process TCC will attribute this process's requests to (private libquarantine symbol,
    /// also used by daformat/subtitles and pasrom/meeting-transcriber). For `swift run` in
    /// Terminal this is /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal.
    public static func responsibleProcess() -> (pid: pid_t, path: String)? {
        typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        let pid = unsafeBitCast(symbol, to: ResponsibleFn.self)(getpid())
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return (pid, "?") }
        return (pid, String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
}
