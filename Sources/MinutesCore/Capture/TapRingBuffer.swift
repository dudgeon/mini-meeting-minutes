import CoreAudio
import Synchronization

/// Lock-free single-producer/single-consumer ring of fixed-size mono Float32 slots.
///
/// Producer: the Core Audio IO thread, via `ingest` (downmix + copy + publish). `ingest` is marked
/// `@_noLocks`, so the Swift compiler rejects any locking, allocation, ARC retain/release,
/// metadata instantiation or existential use inside it (verified: it errors on an Array or a
/// class-reference copy). Consumer: exactly one serial queue, via `consumeNext`.
/// All storage is preallocated; a full ring drops the newest frames and counts them.
final class TapRingBuffer: @unchecked Sendable {
    let slotFrames: Int
    let slotCount: Int
    /// Host ticks per frame at the device rate, to stamp slots split out of one large IO buffer.
    let ticksPerFrame: Double

    private let samples: UnsafeMutablePointer<Float>
    private let hostTimes: UnsafeMutablePointer<UInt64>
    private let frameCounts: UnsafeMutablePointer<Int>
    private let published = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)

    let callbacks = Atomic<Int>(0)
    let droppedFrames = Atomic<Int>(0)
    let malformedBuffers = Atomic<Int>(0)

    init(sampleRate: Double, slotFrames: Int = 1024, slotCount: Int = 512) {
        self.slotFrames = slotFrames
        self.slotCount = slotCount
        self.ticksPerFrame = HostTime.ticksPerSecond / sampleRate
        samples = .allocate(capacity: slotFrames * slotCount)
        samples.initialize(repeating: 0, count: slotFrames * slotCount)
        hostTimes = .allocate(capacity: slotCount)
        hostTimes.initialize(repeating: 0, count: slotCount)
        frameCounts = .allocate(capacity: slotCount)
        frameCounts.initialize(repeating: 0, count: slotCount)
    }

    deinit {
        samples.deallocate()
        hostTimes.deallocate()
        frameCounts.deallocate()
    }

    /// Real-time: called from the IOProc. Downmixes every input buffer/channel to mono and publishes
    /// it in one or more slots stamped with `inInputTime.mHostTime` (0 when the stamp is invalid).
    @_noLocks
    func ingest(_ inputData: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>) {
        callbacks.wrappingAdd(1, ordering: .relaxed)
        // Walk the variable-length AudioBufferList by hand: UnsafeMutableAudioBufferListPointer is
        // not inlinable, so @_noLocks rejects it. mBuffers is the trailing member of the struct.
        let bufferCount = Int(inputData.pointee.mNumberBuffers)
        let buffers = (UnsafeRawPointer(inputData) + (MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size))
            .assumingMemoryBound(to: AudioBuffer.self)
        var frames = -1
        var totalChannels = 0
        var index = 0
        while index < bufferCount {
            let buffer = buffers[index]
            index += 1
            let channels = Int(buffer.mNumberChannels)
            guard buffer.mData != nil, channels > 0 else { continue }
            let bufferFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            if frames < 0 {
                frames = bufferFrames
            } else if bufferFrames != frames {
                malformedBuffers.wrappingAdd(1, ordering: .relaxed)
                return
            }
            totalChannels += channels
        }
        guard frames > 0, totalChannels > 0 else { return }

        let time = inputTime.pointee
        let baseHostTime: UInt64 = (time.mFlags.rawValue & AudioTimeStampFlags.hostTimeValid.rawValue) != 0
            ? time.mHostTime : 0
        let gain = 1 / Float(totalChannels)
        var done = 0
        while done < frames {
            let written = published.load(ordering: .relaxed)
            if written - consumed.load(ordering: .acquiring) >= slotCount {
                droppedFrames.wrappingAdd(frames - done, ordering: .relaxed)
                return
            }
            let slot = written % slotCount
            let count = min(slotFrames, frames - done)
            let destination = samples + slot * slotFrames
            destination.update(repeating: 0, count: count)
            index = 0
            while index < bufferCount {
                let buffer = buffers[index]
                index += 1
                let channels = Int(buffer.mNumberChannels)
                guard let data = buffer.mData, channels > 0 else { continue }
                let source = data.assumingMemoryBound(to: Float.self) + done * channels
                var frame = 0
                while frame < count {
                    var sum: Float = 0
                    var channel = 0
                    while channel < channels {
                        sum += source[frame * channels + channel]
                        channel += 1
                    }
                    destination[frame] += sum
                    frame += 1
                }
            }
            if totalChannels > 1 {
                var frame = 0
                while frame < count {
                    destination[frame] *= gain
                    frame += 1
                }
            }
            hostTimes[slot] = baseHostTime == 0 ? 0 : baseHostTime &+ UInt64(Double(done) * ticksPerFrame)
            frameCounts[slot] = count
            published.store(written &+ 1, ordering: .releasing)
            done += count
        }
    }

    /// Consumer side. Calls `body` with the oldest unread slot and returns true, or returns false
    /// when the ring is empty. The pointer is only valid inside `body`.
    func consumeNext(_ body: (UnsafeBufferPointer<Float>, UInt64) -> Void) -> Bool {
        let read = consumed.load(ordering: .relaxed)
        guard read < published.load(ordering: .acquiring) else { return false }
        let slot = read % slotCount
        body(UnsafeBufferPointer(start: samples + slot * slotFrames, count: frameCounts[slot]), hostTimes[slot])
        consumed.store(read &+ 1, ordering: .releasing)
        return true
    }
}

/// The C IOProc registered with `AudioDeviceCreateIOProcID`. The client data is an unretained
/// `TapRingBuffer`; `_withUnsafeGuaranteedRef` borrows it without ARC traffic. The owner keeps the
/// ring alive until `AudioDeviceDestroyIOProcID` has returned.
let tapIOProc: AudioDeviceIOProc = { _, _, inputData, inputTime, _, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<TapRingBuffer>.fromOpaque(clientData)._withUnsafeGuaranteedRef { ring in
        ring.ingest(inputData, inputTime)
    }
    return noErr
}
