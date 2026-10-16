import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import OSLog

@main
struct AudioMonitorHelper {
    static func main() {
        // Pump application events so Core Graphics delivers display connection callbacks.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        guard let monitor = AudioMonitor(), monitor.start() else { return }
        defer { monitor.stop() }
        application.run()
    }
}

private final class AudioMonitor {
    static let logger = Logger(subsystem: "com.user.audiomonitor", category: "AudioService")
    static let setupWindow: TimeInterval = 5

    private struct OutputDevice {
        let id: AudioDeviceID
        let name: String
        let isAirPlay: Bool
    }

    private struct SetupProtection {
        let displays: Set<CGDirectDisplayID>
        var output: OutputDevice
        let deadline: TimeInterval
    }

    private struct RecentAirPlayChange {
        let previousOutput: OutputDevice
        let deviceID: AudioDeviceID
        let time: TimeInterval
    }

    // All mutable state is accessed on the main event queue.
    private var currentOutput: OutputDevice
    private var externalDisplays: Set<CGDirectDisplayID>
    private var setupProtection: SetupProtection?
    private var recentAirPlayChange: RecentAirPlayChange?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var displayListenerRegistered = false

    init?() {
        Self.logger.info("AudioMonitorHelper service starting up.")
        guard let output = Self.getDefaultOutputDevice(),
            let displays = Self.getExternalDisplays()
        else {
            Self.logger.error("Could not read the initial audio and display configuration. Exiting.")
            return nil
        }

        // Preserve existing choices, including AirPlay selected before the helper starts.
        currentOutput = output
        externalDisplays = displays
        Self.logger.info("Current audio output: '\(output.name)'")
    }

    func start() -> Bool {
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleOutputChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        guard status == noErr else {
            Self.logger.error("Failed to add audio property listener. Status: \(status).")
            return false
        }
        outputListener = listener

        let displayStatus = CGDisplayRegisterReconfigurationCallback(
            Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
        guard displayStatus == .success else {
            Self.logger.error("Failed to register display listener. Status: \(displayStatus.rawValue).")
            stop()
            return false
        }
        displayListenerRegistered = true

        // Catch changes between the initial snapshot and listener registration.
        handleDisplayChange()
        handleOutputChange()
        Self.logger.info("Monitoring audio output and display connections...")
        return true
    }

    func stop() {
        if displayListenerRegistered {
            CGDisplayRemoveReconfigurationCallback(
                Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
            displayListenerRegistered = false
        }
        if let listener = outputListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            outputListener = nil
        }
    }

    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard !flags.contains(.beginConfigurationFlag), let context = context else { return }
        let monitor = Unmanaged<AudioMonitor>.fromOpaque(context).takeUnretainedValue()
        // Keep audio writes out of the display reconfiguration callback itself.
        DispatchQueue.main.async {
            monitor.handleDisplayChange()
        }
    }

    private func handleDisplayChange() {
        guard let displays = Self.getExternalDisplays() else { return }
        let added = displays.subtracting(externalDisplays)
        let removed = externalDisplays.subtracting(displays)
        externalDisplays = displays

        if let protection = setupProtection, !protection.displays.isDisjoint(with: removed) {
            setupProtection = nil
        }
        guard !added.isEmpty else {
            if !removed.isEmpty { recentAirPlayChange = nil }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        var outputToPreserve = currentOutput
        // Core Audio may report the automatic switch before Core Graphics reports the display.
        if let change = recentAirPlayChange,
            now - change.time <= Self.setupWindow,
            currentOutput.id == change.deviceID
        {
            outputToPreserve = change.previousOutput
        }
        recentAirPlayChange = nil
        setupProtection = SetupProtection(
            displays: added, output: outputToPreserve, deadline: now + Self.setupWindow)
        Self.logger.info("Display connected. Protecting '\(outputToPreserve.name)' during setup.")

        // Read the actual output even if its notification has not yet been delivered.
        handleOutputChange()
        restoreOutputDuringSetup()
    }

    private func handleOutputChange() {
        let now = ProcessInfo.processInfo.systemUptime
        if let protection = setupProtection, now > protection.deadline {
            setupProtection = nil
        }
        guard let output = Self.getDefaultOutputDevice(), output.id != currentOutput.id else {
            return
        }

        let previousOutput = currentOutput
        currentOutput = output
        if output.isAirPlay {
            if restoreOutputDuringSetup() { return }
            // Outside connection setup, leave the user's output selection alone.
            recentAirPlayChange = RecentAirPlayChange(
                previousOutput: previousOutput, deviceID: output.id, time: now)
            Self.logger.info("Allowing AirPlay output: '\(output.name)'")
        } else {
            recentAirPlayChange = nil
            // Follow non-AirPlay selections and Bluetooth disconnect fallbacks during setup.
            setupProtection?.output = output
            Self.logger.info("Current audio output changed to: '\(output.name)'")
        }
    }

    @discardableResult
    private func restoreOutputDuringSetup() -> Bool {
        guard let protection = setupProtection,
            ProcessInfo.processInfo.systemUptime <= protection.deadline,
            currentOutput.isAirPlay, currentOutput.id != protection.output.id,
            Self.getDefaultOutputDevice()?.id == currentOutput.id
        else { return false }

        // Consume protection before writing: later selections are allowed immediately,
        // including notifications generated by this restoration. A reconnect arms it again.
        setupProtection = nil
        recentAirPlayChange = nil
        let status = Self.setDefaultOutputDevice(deviceID: protection.output.id)
        if status == noErr {
            Self.logger.notice("Requested restoration of audio output to: '\(protection.output.name)'")
        } else {
            Self.logger.error("Failed to restore audio output. Status: \(status).")
        }
        return true
    }

    private static func getExternalDisplays() -> Set<CGDirectDisplayID>? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return Set(displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 })
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)  // DEPRECATION FIX
        var deviceName: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &deviceName) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, $0)
        }
        return status == noErr ? (deviceName as String) : nil
    }

    static func getDeviceTransportType(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)  // DEPRECATION FIX
        var transportType = UInt32(0)
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &propertySize, &transportType)
        if status == noErr {
            return String(
                format: "%c%c%c%c", (transportType >> 24) & 0xFF, (transportType >> 16) & 0xFF,
                (transportType >> 8) & 0xFF, transportType & 0xFF
            ).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func setDefaultOutputDevice(deviceID: AudioDeviceID) -> OSStatus {
        var newDeviceID = deviceID
        var address = defaultOutputAddress
        let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, propertySize, &newDeviceID)
    }

    private static func getDefaultOutputDevice() -> OutputDevice? {
        var deviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultOutputAddress
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceID)
                == noErr, deviceID != kAudioObjectUnknown
        else { return nil }
        return OutputDevice(
            id: deviceID, name: getDeviceName(deviceID: deviceID) ?? "Unknown",
            isAirPlay: getDeviceTransportType(deviceID: deviceID) == "airp")
    }
}
