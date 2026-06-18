import CoreAudio
import Foundation

private let hardcodedGain: Float = 0.1

private func tapInputIOProc(
    _ inDevice: AudioObjectID,
    _ inNow: UnsafePointer<AudioTimeStamp>,
    _ inInputData: UnsafePointer<AudioBufferList>,
    _ inInputTime: UnsafePointer<AudioTimeStamp>,
    _ outOutputData: UnsafeMutablePointer<AudioBufferList>,
    _ inOutputTime: UnsafePointer<AudioTimeStamp>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return noErr }
    let prototype = Unmanaged<ProcessTapDSPPrototype>
        .fromOpaque(inClientData)
        .takeUnretainedValue()
    prototype.captureCallback(inputData: inInputData)
    return noErr
}

private func outputIOProc(
    _ inDevice: AudioObjectID,
    _ inNow: UnsafePointer<AudioTimeStamp>,
    _ inInputData: UnsafePointer<AudioBufferList>,
    _ inInputTime: UnsafePointer<AudioTimeStamp>,
    _ outOutputData: UnsafeMutablePointer<AudioBufferList>,
    _ inOutputTime: UnsafePointer<AudioTimeStamp>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return noErr }
    let prototype = Unmanaged<ProcessTapDSPPrototype>
        .fromOpaque(inClientData)
        .takeUnretainedValue()
    prototype.outputCallback(outputData: outOutputData)
    return noErr
}

final class ProcessTapDSPPrototype {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var tapAggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var defaultOutputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var tapIOProcID: AudioDeviceIOProcID?
    private var outputIOProcID: AudioDeviceIOProcID?
    private var ringBuffer: OpaquePointer?
    private var statusTimer: DispatchSourceTimer?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var routeChangeWorkItem: DispatchWorkItem?
    private var activeTapSourceDevice: AudioDeviceSummary?
    private var activePlaybackDevice: AudioDeviceSummary?
    private var lastWrittenFrames: UInt64 = 0
    private var lastReadFrames: UInt64 = 0
    private var statusTick: UInt64 = 0
    private var isStopped = true

    func start() throws {
        isStopped = false
        try installDefaultOutputListener()
        try rebuildPipeline(reason: "initial start")
    }

    func stop(reason: String = "shutdown") {
        print("")
        print("Stopping ProcessTapDSP: \(reason)")

        if isStopped {
            print("Shutdown skipped: app is already stopped.")
            return
        }

        isStopped = true
        if routeChangeWorkItem != nil {
            routeChangeWorkItem?.cancel()
            print("Cleanup: canceled pending route-change rebuild.")
        }
        routeChangeWorkItem = nil
        removeDefaultOutputListener(log: true)
        teardownPipeline(log: true, reason: reason)
        print("Shutdown complete. Normal system audio should be restored.")
    }

    fileprivate func captureCallback(inputData: UnsafePointer<AudioBufferList>) {
        guard let ringBuffer else { return }
        _ = SonexisAudioRingBufferWriteFromAudioBufferList(
            ringBuffer,
            inputData,
            hardcodedGain
        )
    }

    fileprivate func outputCallback(outputData: UnsafeMutablePointer<AudioBufferList>) {
        guard let ringBuffer else { return }
        _ = SonexisAudioRingBufferReadToAudioBufferList(ringBuffer, outputData)
    }

    private func rebuildPipeline(reason: String) throws {
        print("")
        print("Rebuilding audio pipeline: \(reason)")
        printRouteDiagnostics(context: "before rebuild")

        do {
            teardownPipeline(log: reason != "initial start", reason: "rebuild cleanup")
            try buildPipeline()
            printRouteDiagnostics(context: "after rebuild")
            print("Started Process Tap -> gain DSP -> default output playback.")
            print("Play system audio in another app. Press Control-C to stop.")
        } catch {
            teardownPipeline(log: true, reason: "rebuild failure cleanup")
            throw error
        }
    }

    private func buildPipeline() throws {
        defaultOutputDeviceID = try CoreAudioSupport.defaultOutputDevice()
        let defaultOutput = try CoreAudioSupport.deviceSummary(defaultOutputDeviceID)
        let streamIDs = try CoreAudioSupport.outputStreamIDs(defaultOutputDeviceID)

        guard !streamIDs.isEmpty else {
            throw PrototypeError(message: "The default output device has no output streams")
        }

        guard let ownProcessObjectID = try CoreAudioSupport.processObjectID(forPID: getpid()) else {
            throw PrototypeError(
                message: "This process is not present in the HAL process-object list. Playback mode refuses to start without self-exclusion because that can create recursive capture."
            )
        }

        print("Excluding this process from the tap: AudioObjectID \(ownProcessObjectID)")
        print("Current default output device: \(defaultOutput)")
        print("Using output stream index 0 of \(streamIDs.count)")

        let outputStreamFormat = try CoreAudioSupport.streamVirtualFormat(streamIDs[0])
        print("Default output stream format: \(outputStreamFormat.formatSummary)")

        let tapDescription = CATapDescription(
            excludingProcesses: [ownProcessObjectID],
            deviceUID: defaultOutput.uid,
            stream: 0
        )
        tapDescription.name = "ProcessTapDSP System Output Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = CATapMuteBehavior(rawValue: 2)!

        var createdTapID = kAudioObjectUnknown
        try checkOSStatus(
            AudioHardwareCreateProcessTap(tapDescription, &createdTapID),
            operation: "AudioHardwareCreateProcessTap"
        )
        tapID = createdTapID
        print("Created process tap: AudioObjectID \(tapID)")

        let installedTapDescription = try CoreAudioSupport.tapDescription(tapID)
        guard installedTapDescription.isExclusive,
              installedTapDescription.processes.contains(ownProcessObjectID) else {
            throw PrototypeError(
                message: "Process tap self-exclusion verification failed. Refusing to start playback to avoid recursive capture."
            )
        }
        guard installedTapDescription.deviceUID == defaultOutput.uid else {
            throw PrototypeError(
                message: "Process tap source UID mismatch. Expected \(defaultOutput.uid), got \(installedTapDescription.deviceUID ?? "nil")."
            )
        }
        print("Verified tap exclusion includes this process.")
        print("Tap source device: \(defaultOutput)")

        let tapFormat = try CoreAudioSupport.tapFormat(tapID)
        print("Tap format: \(tapFormat.formatSummary)")
        guard tapFormat.isPlaybackCompatible(with: outputStreamFormat) else {
            throw PrototypeError(
                message: "This PoC requires matching Float32 tap/output formats and does not perform sample-rate conversion. Tap: \(tapFormat.formatSummary). Output: \(outputStreamFormat.formatSummary)"
            )
        }

        let channelCount = tapFormat.mChannelsPerFrame
        guard channelCount > 0 else {
            throw PrototypeError(message: "Tap reported zero channels")
        }

        let ringCapacityFrames = max(UInt32(tapFormat.mSampleRate * 2.0), 4_096)
        guard let createdRingBuffer = SonexisAudioRingBufferCreate(ringCapacityFrames, channelCount) else {
            throw PrototypeError(message: "Could not allocate realtime audio ring buffer")
        }
        ringBuffer = createdRingBuffer
        print("Created realtime ring buffer: \(ringCapacityFrames) frames, \(channelCount) channels")
        print("Hardcoded gain: \(hardcodedGain)")

        let tapUID = try CoreAudioSupport.tapUID(tapID)
        tapAggregateDeviceID = try createPrivateAggregateDevice(tapUID: tapUID)
        print("Created private aggregate device: AudioDeviceID \(tapAggregateDeviceID)")

        try createIOProcs()
        try startIO()

        activeTapSourceDevice = defaultOutput
        activePlaybackDevice = defaultOutput
        startStatusTimer()
    }

    private func teardownPipeline(log: Bool = false, reason: String = "pipeline teardown") {
        if log {
            print("Cleanup: tearing down audio pipeline (\(reason)).")
        }

        if statusTimer != nil {
            statusTimer?.cancel()
            if log { print("Cleanup: canceled status timer.") }
        }
        statusTimer = nil

        if tapAggregateDeviceID != kAudioObjectUnknown, let tapIOProcID {
            let status = AudioDeviceStop(tapAggregateDeviceID, tapIOProcID)
            if log { printCleanupResult("stopped tap aggregate IOProc", status: status) }
        } else if log {
            print("Cleanup: no tap aggregate IOProc to stop.")
        }

        if defaultOutputDeviceID != kAudioObjectUnknown, let outputIOProcID {
            let status = AudioDeviceStop(defaultOutputDeviceID, outputIOProcID)
            if log { printCleanupResult("stopped playback output IOProc", status: status) }
        } else if log {
            print("Cleanup: no playback output IOProc to stop.")
        }

        if tapAggregateDeviceID != kAudioObjectUnknown, let tapIOProcID {
            let status = AudioDeviceDestroyIOProcID(tapAggregateDeviceID, tapIOProcID)
            if log { printCleanupResult("destroyed tap aggregate IOProc ID", status: status) }
            self.tapIOProcID = nil
        } else if log {
            print("Cleanup: no tap aggregate IOProc ID to destroy.")
        }

        if defaultOutputDeviceID != kAudioObjectUnknown, let outputIOProcID {
            let status = AudioDeviceDestroyIOProcID(defaultOutputDeviceID, outputIOProcID)
            if log { printCleanupResult("destroyed playback output IOProc ID", status: status) }
            self.outputIOProcID = nil
        } else if log {
            print("Cleanup: no playback output IOProc ID to destroy.")
        }

        if tapAggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(tapAggregateDeviceID)
            if log { printCleanupResult("destroyed private aggregate device", status: status) }
            tapAggregateDeviceID = kAudioObjectUnknown
        } else if log {
            print("Cleanup: no private aggregate device to destroy.")
        }

        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if log { printCleanupResult("destroyed Process Tap", status: status) }
            tapID = kAudioObjectUnknown
        } else if log {
            print("Cleanup: no Process Tap to destroy.")
        }

        if let ringBuffer {
            SonexisAudioRingBufferDestroy(ringBuffer)
            self.ringBuffer = nil
            if log { print("Cleanup: freed realtime ring buffer.") }
        } else if log {
            print("Cleanup: no realtime ring buffer to free.")
        }

        defaultOutputDeviceID = kAudioObjectUnknown
        activeTapSourceDevice = nil
        activePlaybackDevice = nil
        lastWrittenFrames = 0
        lastReadFrames = 0
        statusTick = 0
    }

    private func createPrivateAggregateDevice(tapUID: String) throws -> AudioDeviceID {
        let aggregateUID = "com.sonexis.prototype.ProcessTapDSP.aggregate.\(UUID().uuidString)"
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ProcessTapDSP Private Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [tapEntry],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        var deviceID = kAudioObjectUnknown
        try checkOSStatus(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &deviceID),
            operation: "AudioHardwareCreateAggregateDevice"
        )
        return deviceID
    }

    private func createIOProcs() throws {
        let clientData = Unmanaged.passUnretained(self).toOpaque()

        var createdOutputIOProcID: AudioDeviceIOProcID?
        try checkOSStatus(
            AudioDeviceCreateIOProcID(
                defaultOutputDeviceID,
                outputIOProc,
                clientData,
                &createdOutputIOProcID
            ),
            operation: "Create default output IOProc"
        )

        guard let createdOutputIOProcID else {
            throw PrototypeError(message: "Create default output IOProc returned nil IOProcID")
        }
        outputIOProcID = createdOutputIOProcID

        var createdTapIOProcID: AudioDeviceIOProcID?
        try checkOSStatus(
            AudioDeviceCreateIOProcID(
                tapAggregateDeviceID,
                tapInputIOProc,
                clientData,
                &createdTapIOProcID
            ),
            operation: "Create tap aggregate IOProc"
        )

        guard let createdTapIOProcID else {
            throw PrototypeError(message: "Create tap aggregate IOProc returned nil IOProcID")
        }
        tapIOProcID = createdTapIOProcID
    }

    private func startIO() throws {
        guard let outputIOProcID, let tapIOProcID else {
            throw PrototypeError(message: "IOProcs were not created")
        }

        try checkOSStatus(
            AudioDeviceStart(defaultOutputDeviceID, outputIOProcID),
            operation: "Start default output IOProc"
        )

        do {
            try checkOSStatus(
                AudioDeviceStart(tapAggregateDeviceID, tapIOProcID),
                operation: "Start tap aggregate IOProc"
            )
        } catch {
            _ = AudioDeviceStop(defaultOutputDeviceID, outputIOProcID)
            throw error
        }
    }

    private func installDefaultOutputListener() throws {
        guard defaultOutputListenerBlock == nil else { return }

        var address = defaultOutputDeviceAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRouteRebuild()
        }

        try checkOSStatus(
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            ),
            operation: "Install default output device listener"
        )

        defaultOutputListenerBlock = block
    }

    private func removeDefaultOutputListener(log: Bool = false) {
        guard let defaultOutputListenerBlock else { return }

        var address = defaultOutputDeviceAddress()
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            defaultOutputListenerBlock
        )
        if log { printCleanupResult("removed default-output route listener", status: status) }
        self.defaultOutputListenerBlock = nil
    }

    private func scheduleRouteRebuild() {
        guard !isStopped else { return }

        routeChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleRouteChange()
        }
        routeChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func handleRouteChange() {
        guard !isStopped else { return }
        routeChangeWorkItem = nil

        print("")
        print("Default output device change detected.")
        printRouteDiagnostics(context: "route-change notification")

        do {
            try rebuildPipeline(reason: "default output changed")
        } catch {
            print("Route rebuild failed: \(error)")
            print("The pipeline is stopped; normal system output should be unmuted. Change routes again or restart the app to retry.")
        }
    }

    private func startStatusTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let ringBuffer else { return }

            let fill = SonexisAudioRingBufferGetFillFrames(ringBuffer)
            let dropped = SonexisAudioRingBufferGetDroppedFrames(ringBuffer)
            let underflows = SonexisAudioRingBufferGetUnderflowFrames(ringBuffer)
            let written = SonexisAudioRingBufferGetWrittenFrames(ringBuffer)
            let read = SonexisAudioRingBufferGetReadFrames(ringBuffer)
            let peakPPM = SonexisAudioRingBufferGetLastInputPeakPPM(ringBuffer)
            let writtenDelta = written - lastWrittenFrames
            let readDelta = read - lastReadFrames
            lastWrittenFrames = written
            lastReadFrames = read

            let peak = max(Double(peakPPM) / 1_000_000.0, 1.0e-12)
            let peakDB = 20.0 * log10(peak)
            print(
                String(
                    format: "ring fill: %u frames, in/s: %llu, out/s: %llu, input peak: %.1f dBFS, dropped: %llu, underflow: %llu",
                    fill,
                    writtenDelta,
                    readDelta,
                    peakDB,
                    dropped,
                    underflows
                )
            )

            statusTick += 1
            if statusTick % 5 == 0 {
                printRouteDiagnostics(context: "periodic")
            }
        }
        statusTimer = timer
        timer.resume()
    }

    private func printRouteDiagnostics(context: String) {
        print("Route diagnostics (\(context)):")

        if let currentDefaultDevice = try? CoreAudioSupport.defaultOutputDevice(),
           let currentDefault = try? CoreAudioSupport.deviceSummary(currentDefaultDevice) {
            print("  Current default output: \(currentDefault)")
        } else {
            print("  Current default output: unavailable")
        }

        if let activeTapSourceDevice {
            print("  Tap source device:      \(activeTapSourceDevice)")
        } else {
            print("  Tap source device:      none")
        }

        if let activePlaybackDevice {
            print("  Playback output device: \(activePlaybackDevice)")
        } else {
            print("  Playback output device: none")
        }
    }

    private func defaultOutputDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func printCleanupResult(_ label: String, status: OSStatus) {
        if status == noErr {
            print("Cleanup: \(label).")
        } else {
            print("Cleanup warning: \(label) returned \(status.osStatusDescription).")
        }
    }
}
