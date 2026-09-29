import CoreAudio
import Darwin
import Foundation

// MARK: - Host time

/// Both capture paths stamp audio with mach host time: the clock behind `mach_absolute_time()`,
/// `AudioTimeStamp.mHostTime` and `AVAudioTime.hostTime`. On Apple Silicon one tick is 125/3 ns
/// (24 MHz), not 1 ns, so always convert through the timebase. The clock stops while the Mac sleeps.
public enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static var ticksPerSecond: Double { 1e9 * Double(timebase.denom) / Double(timebase.numer) }
    public static func now() -> UInt64 { mach_absolute_time() }
    public static func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }
    public static func ticks(_ seconds: Double) -> UInt64 { UInt64((max(0, seconds) * ticksPerSecond).rounded()) }
    /// `b - a` in seconds, negative if `b` is earlier.
    public static func seconds(from a: UInt64, to b: UInt64) -> Double {
        b >= a ? seconds(b - a) : -seconds(a - b)
    }
}

// MARK: - Errors

public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let status: OSStatus

    public init(_ operation: String, _ status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var description: String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        let code = bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? " '\(String(decoding: bytes, as: UTF8.self))'" : ""
        return "\(operation) failed: OSStatus \(status)\(code)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(operation(), status) }
}

// MARK: - Property access

enum CoreAudioSupport {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size (plain-old-data) property.
    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
                  "AudioObjectGetPropertyData(\(fourCC(address.mSelector)))")
        return value
    }

    /// Reads a variable-length array property of plain-old-data elements.
    static func readArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, zero: T) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size),
                  "AudioObjectGetPropertyDataSize(\(fourCC(address.mSelector)))")
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }
        var values = [T](repeating: zero, count: capacity)
        let status = values.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw.baseAddress!)
        }
        try check(status, "AudioObjectGetPropertyData(\(fourCC(address.mSelector)))")
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads a CFString property (returned +1 by the HAL).
    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
                  "AudioObjectGetPropertyData(\(fourCC(selector)))")
        guard let value else { throw CoreAudioError("nil CFString for \(fourCC(selector))", kAudioHardwareUnspecifiedError) }
        return value.takeRetainedValue() as String
    }

    static func write<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        try check(AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value),
                  "AudioObjectSetPropertyData(\(fourCC(address.mSelector)))")
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        (try? read(systemObject, address(selector), initial: AudioDeviceID(kAudioObjectUnknown)))
            ?? AudioDeviceID(kAudioObjectUnknown)
    }

    /// `kAudioObjectUnknown` if no device with this UID is currently present.
    static func device(forUID uid: String) -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let cfUID = uid as CFString
        let status = withExtendedLifetime(cfUID) {
            var qualifier: Unmanaged<CFString>? = Unmanaged.passUnretained(cfUID)
            return AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                                              &qualifier, &size, &device)
        }
        return status == noErr ? device : AudioDeviceID(kAudioObjectUnknown)
    }

    static func deviceName(_ device: AudioDeviceID) -> String? {
        device == kAudioObjectUnknown ? nil : try? readString(device, kAudioObjectPropertyName)
    }

    /// `kAudioObjectUnknown` if `pid` has no HAL process object (it has never talked to coreaudiod).
    static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &size, &object)
        return status == noErr ? object : AudioObjectID(kAudioObjectUnknown)
    }

    /// PIDs of processes currently sending audio to an output device (excluding `excludedPID`).
    static func processesOutputtingAudio(excluding excludedPID: pid_t) -> [pid_t] {
        let objects = (try? readArray(systemObject, address(kAudioHardwarePropertyProcessObjectList),
                                      zero: AudioObjectID(0))) ?? []
        return objects.compactMap { object in
            guard let running = try? read(object, address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0)),
                  running != 0,
                  let pid = try? read(object, address(kAudioProcessPropertyPID), initial: pid_t(0)),
                  pid != excludedPID else { return nil }
            return pid
        }
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : String(value)
    }
}

// MARK: - Listener registration

/// Owns one `AudioObjectAddPropertyListenerBlock` registration. Removal must pass the identical
/// block and queue, so both are stored. The handler should only hop to another queue with `async`:
/// removing a listener while its block is executing on the same queue can deadlock.
final class PropertyListenerToken: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var active = true

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
         handler: @escaping @Sendable () -> Void) throws {
        self.object = object
        self.address = address
        self.queue = queue
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        self.block = block
        var address = address
        try check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block),
                  "AudioObjectAddPropertyListenerBlock(\(CoreAudioSupport.fourCC(address.mSelector)))")
    }

    func invalidate() {
        guard active else { return }
        active = false
        _ = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    deinit { invalidate() }
}
