import CoreAudio
import Foundation

enum SystemOutputVolume {
    static func balancedValues(_ current: [Float32], percent: Int) throws -> [Float32] {
        guard (0...100).contains(percent), !current.isEmpty,
              current.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw NativeActionFailure.volumeUnavailable }
        let target = Float32(percent) / 100
        let largest = current.max() ?? 0
        return current.map { largest > 0 ? min(1, $0 / largest * target) : target }
    }

    static func set(_ percent: Int) throws {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { throw NativeActionFailure.volumeUnavailable }
        var master = volumeAddress(kAudioObjectPropertyElementMain)
        var masterWritable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &master),
           AudioObjectIsPropertySettable(device, &master, &masterWritable) == noErr, masterWritable.boolValue {
            try write(Float32(percent) / 100, device: device, address: master)
            return
        }
        var stereo = [UInt32](repeating: 0, count: 2)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<UInt32>.size * 2)
        let status = stereo.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!)
        }
        let candidates = status == noErr ? stereo : [1, 2]
        let channels = Array(Set(candidates.filter { $0 > 0 })).sorted().filter { channel in
            var property = volumeAddress(channel)
            return AudioObjectHasProperty(device, &property)
        }
        guard !channels.isEmpty else { throw NativeActionFailure.volumeUnavailable }
        let values = try channels.map { channel -> Float32 in
            var property = volumeAddress(channel)
            var value: Float32 = 0
            var bytes = UInt32(MemoryLayout<Float32>.size)
            var writable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &property, &writable) == noErr, writable.boolValue,
                  AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, &value) == noErr else {
                throw NativeActionFailure.volumeUnavailable
            }
            return value
        }
        let targets = try balancedValues(values, percent: percent)
        var written = 0
        do {
            for index in channels.indices {
                try write(targets[index], device: device, address: volumeAddress(channels[index]))
                written += 1
            }
        } catch {
            var rollbackFailed = false
            for index in 0..<written {
                do { try write(values[index], device: device, address: volumeAddress(channels[index])) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed { throw NativeActionFailure.volumePartiallyChanged }
            throw error
        }
    }

    private static func volumeAddress(_ channel: UInt32) -> AudioObjectPropertyAddress {
        .init(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
    }

    private static func write(_ value: Float32, device: AudioObjectID, address: AudioObjectPropertyAddress) throws {
        var property = address
        var writable: DarwinBoolean = false
        var scalar = value
        guard scalar.isFinite, (0...1).contains(scalar),
              AudioObjectIsPropertySettable(device, &property, &writable) == noErr, writable.boolValue,
              AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr else {
            throw NativeActionFailure.volumeUnavailable
        }
    }
}
