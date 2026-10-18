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
    // Set to false before building to restore the original always-revert policy.
    static let connectionAwareBehaviorEnabled: Bool = true
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
    private var legacyPreferredOutput: OutputDevice?
    private var externalDisplays = Set<CGDirectDisplayID>()
    private var setupProtection: SetupProtection?
    private var recentAirPlayChange: RecentAirPlayChange?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var displayListenerRegistered = false

    init?() {
        Self.logger.info("AudioMonitorHelper service starting up.")
        let initialOutput = Self.getDefaultOutputDevice()
        var preferredOutput: OutputDevice?
        if !Self.connectionAwareBehaviorEnabled {
            if let output = initialOutput, !output.isAirPlay {
                preferredOutput = output
            } else {
                preferredOutput = Self.findLegacyFallbackOutput()
            }
            guard preferredOutput != nil else {
                Self.logger.error("Could not establish a non-AirPlay output. Exiting.")
                return nil
            }
        }
        guard let output = initialOutput ?? preferredOutput else {
            Self.logger.error("Could not read the initial audio output. Exiting.")
            return nil
        }

        currentOutput = output
        legacyPreferredOutput = preferredOutput
        if Self.connectionAwareBehaviorEnabled {
            guard let displays = Self.getExternalDisplays() else {
                Self.logger.error("Could not read the initial display configuration. Exiting.")
                return nil
            }
            // Preserve existing choices, including AirPlay selected before the helper starts.
            externalDisplays = displays
        }
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

        if Self.connectionAwareBehaviorEnabled {
            let displayStatus = CGDisplayRegisterReconfigurationCallback(
                Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
            guard displayStatus == .success else {
                Self.logger.error("Failed to register display listener. Status: \(displayStatus.rawValue).")
                stop()
                return false
            }
            displayListenerRegistered = true
            handleDisplayChange()
            Self.logger.info("Monitoring audio output and display connections...")
        } else {
            Self.logger.info("Connection-aware behavior disabled. Reverting every AirPlay selection.")
        }

        // Catch changes between the initial snapshot and listener registration.
        handleOutputChange()
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
        guard Self.connectionAwareBehaviorEnabled, let displays = Self.getExternalDisplays() else {
            return
        }
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
        guard Self.connectionAwareBehaviorEnabled else {
            handleLegacyOutputChange()
            return
        }
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

    private func handleLegacyOutputChange() {
        guard let output = Self.getDefaultOutputDevice() else { return }
        currentOutput = output
        if output.isAirPlay {
            if let preferredOutput = legacyPreferredOutput {
                restoreOutput(to: preferredOutput)
            }
        } else if legacyPreferredOutput?.id != output.id {
            legacyPreferredOutput = output
            Self.logger.info("Preferred non-AirPlay output changed to: '\(output.name)'")
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
        restoreOutput(to: protection.output)
        return true
    }

    private func restoreOutput(to output: OutputDevice) {
        let status = Self.setDefaultOutputDevice(deviceID: output.id)
        if status == noErr {
            Self.logger.notice("Requested restoration of audio output to: '\(output.name)'")
        } else {
            Self.logger.error("Failed to restore audio output. Status: \(status).")
        }
    }

    private static func findLegacyFallbackOutput() -> OutputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
            size > 0
        else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }

        // Match the original preference order, accepting only devices with output streams.
        for transport in ["blue", "bltn"] {
            for deviceID in devices where getDeviceTransportType(deviceID: deviceID) == transport {
                var streamsAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreams,
                    mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
                var streamsSize: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(
                    deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0
                else { continue }
                return OutputDevice(
                    id: deviceID, name: getDeviceName(deviceID: deviceID) ?? "Unknown", isAirPlay: false)
            }
        }
        return nil
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
