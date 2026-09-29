import CoreAudio
import Foundation

/// Lists audio input devices, so users can pick one for `mmm record --mic-device`.
public enum AudioDevices {
    public struct Device: Sendable {
        public let name: String
        public let uid: String
        public let isDefault: Bool
    }

    public static func inputs() -> [Device] {
        let system = CoreAudioSupport.systemObject
        let devices =
            (try? CoreAudioSupport.readArray(
                system, CoreAudioSupport.address(kAudioHardwarePropertyDevices), zero: AudioDeviceID(0))) ?? []
        let defaultInput = CoreAudioSupport.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        return devices.compactMap { device in
            let streams =
                (try? CoreAudioSupport.readArray(
                    device, CoreAudioSupport.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
                    zero: AudioStreamID(0))) ?? []
            guard !streams.isEmpty, let name = CoreAudioSupport.deviceName(device),
                let uid = try? CoreAudioSupport.readString(device, kAudioDevicePropertyDeviceUID)
            else { return nil }
            return Device(name: name, uid: uid, isDefault: device == defaultInput)
        }
    }
}
