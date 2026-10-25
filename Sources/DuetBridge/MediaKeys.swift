import AppKit
@preconcurrency import ApplicationServices
import CoreAudio
@preconcurrency import CoreGraphics

enum MediaKey: Int {
    case volumeUp = 0
    case volumeDown = 1
    case mute = 7
}

struct MediaKeyPress {
    let key: MediaKey
    let isRepeat: Bool
    let flags: CGEventFlags
}

/// Intercepts the volume/mute keys while Duet is the default output. The tap
/// callback only decides and enqueues; the real work happens on the next run
/// loop turn, so macOS never disables the tap for being slow.
final class MediaKeyTap {
    var shouldIntercept: () -> Bool = { true }
    var onPress: ((MediaKeyPress) -> Void)?
    private(set) var isInstalled = false

    private var tap: CFMachPort?
    private static let systemDefined = CGEventType(rawValue: 14)!

    func install() -> Bool {
        let mask = CGEventMask(1 << Self.systemDefined.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else {
            isInstalled = false
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isInstalled = true
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            debugLog("event tap disabled (\(type.rawValue)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == Self.systemDefined,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data = nsEvent.data1
        guard let key = MediaKey(rawValue: (data & 0xFFFF_0000) >> 16), shouldIntercept() else {
            return Unmanaged.passUnretained(event)
        }

        let isKeyDown = (data & 0xFF00) >> 8 == 0x0A
        if isKeyDown {
            let press = MediaKeyPress(key: key, isRepeat: data & 0x1 == 1, flags: event.flags)
            DispatchQueue.main.async { [weak self] in self?.onPress?(press) }
        }
        // Swallow both key down and key up so macOS does not also act on them.
        return nil
    }
}

/// Tracks whether the system default output is the Duet, without querying
/// CoreAudio on every key press.
final class DefaultOutputWatcher {
    private(set) var isDuet = false
    private(set) var deviceName = "Unknown"

    init() {
        refresh()
        var address = Self.address
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.refresh()
        }
    }

    private static let address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func refresh() {
        var address = Self.address
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            isDuet = false
            return
        }

        let name = Self.string(deviceID, kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"
        let manufacturer = Self.string(deviceID, kAudioDevicePropertyDeviceManufacturerCFString) ?? ""
        deviceName = name
        isDuet = name.localizedCaseInsensitiveContains("Duet") || manufacturer.localizedCaseInsensitiveContains("Apogee")
        debugLog("default output: \(name) duet=\(isDuet)")
    }

    private static func string(_ deviceID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String? : nil
    }
}
