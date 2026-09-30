import Foundation
import MinutesCore
import Synchronization

/// Choices remembered from one run to the next, in the app's preferences.
enum Settings {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "com.github.dudgeon.mini-meeting-minutes") ?? .standard
    }

    /// The microphone chosen with M or /mic: its Core Audio ID and name. Nil follows the Mac's
    /// default input.
    static var microphone: (uid: String, name: String)? {
        get {
            guard let uid = defaults.string(forKey: "microphone") else { return nil }
            return (uid, defaults.string(forKey: "microphoneName") ?? uid)
        }
        set {
            defaults.set(newValue?.uid, forKey: "microphone")
            defaults.set(newValue?.name, forKey: "microphoneName")
        }
    }
}

/// The microphone meetings use, for the rest of the run: nil for the Mac's default input.
final class MicrophoneChoice: Sendable {
    private let uid: Mutex<String?>

    init(_ uid: String?) { self.uid = Mutex(uid) }

    var current: String? { uid.withLock { $0 } }

    func set(_ new: String?) { uid.withLock { $0 = new } }
}
