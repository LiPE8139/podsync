import Foundation
import CoreAudio

/// 控制系统输出音量（与 macOS 音量同步）
enum SystemVolume {
    private static func defaultOutputDevice() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr ? device : 0
    }

    private static func addresses() -> [AudioObjectPropertyAddress] {
        [
            // 'vmvl' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume（SDK 未导出，用四字符码）
            AudioObjectPropertyAddress(mSelector: 0x766D766C,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: 1),
        ]
    }

    static func get() -> Double? {
        let device = defaultOutputDevice()
        guard device != 0 else { return nil }
        for addr in addresses() {
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            var a = addr
            if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &vol) == noErr, vol.isFinite {
                return Double(min(max(vol, 0), 1))
            }
        }
        return nil
    }

    @discardableResult
    static func set(_ value: Double) -> Bool {
        let device = defaultOutputDevice()
        guard device != 0 else { return false }
        let v = Float32(min(max(value, 0), 1))
        var ok = false
        for addr in addresses() {
            var a = addr
            if AudioObjectSetPropertyData(device, &a, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), [v]) == noErr {
                ok = true
            }
        }
        return ok
    }
}
