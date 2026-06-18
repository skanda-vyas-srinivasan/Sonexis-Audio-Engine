import AppKit
import CoreAudio
import Foundation

private let processingGain: Float = 0.1
private let unityGain: Float = 1.0
private let startupPrerollTargetFrames: UInt32 = 1_024
private let startupPrerollPollInterval: TimeInterval = 0.005
private let startupPartialPrerollTimeout: TimeInterval = 0.35
private let startupRampDuration: TimeInterval = 0.40
private let shutdownRampDuration: TimeInterval = 0.25
private let routeChangeRampDuration: TimeInterval = 0.15
private let rampSettleDuration: TimeInterval = 0.03
private let wakeRebuildDelay: TimeInterval = 1.0
private let rebuildRetryDelay: TimeInterval = 1.5
private let rebuildRetryLimit = 4

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
    private var activeDeviceAliveListenerBlock: AudioObjectPropertyListenerBlock?
    private var activeDeviceAliveListenerDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var routeChangeWorkItem: DispatchWorkItem?
    private var recoveryWorkItem: DispatchWorkItem?
    private var smoothTeardownWorkItem: DispatchWorkItem?
    private var startupPrerollTimer: DispatchSourceTimer?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var activeTapSourceDevice: AudioDeviceSummary?
    private var activePlaybackDevice: AudioDeviceSummary?
    private var activeSampleRate: Double = 48_000.0
    private var lastWrittenFrames: UInt64 = 0
    private var lastReadFrames: UInt64 = 0
    private var statusTick: UInt64 = 0
    private var isStopped = true
    private var isSuspendedForSleep = false

    func start() throws {
        isStopped = false
        isSuspendedForSleep = false
        try installDefaultOutputListener()
        installSleepWakeObservers()
        try rebuildPipeline(reason: "initial start")
    }

    func stop(reason: String = "shutdown", completion: @escaping () -> Void = {}) {
        print("")
        print("Stopping ProcessTapDSP: \(reason)")

        if isStopped {
            print("Shutdown skipped: app is already stopped.")
            completion()
            return
        }

        isStopped = true
        if routeChangeWorkItem != nil {
            routeChangeWorkItem?.cancel()
            print("Cleanup: canceled pending route-change rebuild.")
        }
        routeChangeWorkItem = nil
        if recoveryWorkItem != nil {
            recoveryWorkItem?.cancel()
            print("Cleanup: canceled pending recovery rebuild.")
        }
        recoveryWorkItem = nil
        removeSleepWakeObservers(log: true)
        removeDefaultOutputListener(log: true)
        smoothTeardownPipeline(log: true, reason: reason, rampDuration: shutdownRampDuration) {
            print("Shutdown complete. Normal system audio should be restored.")
            completion()
        }
    }

    fileprivate func captureCallback(inputData: UnsafePointer<AudioBufferList>) {
        guard let ringBuffer else { return }
        _ = SonexisAudioRingBufferWriteFromAudioBufferList(
            ringBuffer,
            inputData
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
        activeSampleRate = tapFormat.mSampleRate
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
        SonexisAudioRingBufferSetGainImmediate(createdRingBuffer, unityGain)
        SonexisAudioRingBufferSetReadEnabled(createdRingBuffer, false)
        ringBuffer = createdRingBuffer
        print("Created realtime ring buffer: \(ringCapacityFrames) frames, \(channelCount) channels")
        print("Initial gain: \(unityGain); hardcoded target gain: \(processingGain)")
        print("Startup preroll target: \(startupPrerollTargetFrames) frames")

        let tapUID = try CoreAudioSupport.tapUID(tapID)
        tapAggregateDeviceID = try createPrivateAggregateDevice(tapUID: tapUID)
        print("Created private aggregate device: AudioDeviceID \(tapAggregateDeviceID)")

        try createIOProcs()
        try installActiveDeviceAliveListener(deviceID: defaultOutputDeviceID)
        try startIO()
        scheduleStartupPreroll(context: "pipeline start")

        activeTapSourceDevice = defaultOutput
        activePlaybackDevice = defaultOutput
        startStatusTimer()
    }

    private func scheduleStartupPreroll(context: String) {
        guard ringBuffer != nil else { return }

        startupPrerollTimer?.cancel()
        var firstFillTime: DispatchTime?
        let partialTimeoutNanoseconds = UInt64(startupPartialPrerollTimeout * 1_000_000_000.0)

        print(
            "Startup: holding processed output until ring fill reaches \(startupPrerollTargetFrames) frames; partial fill accepted \(Int(startupPartialPrerollTimeout * 1000.0)) ms after capture begins."
        )

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: startupPrerollPollInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped, let ringBuffer = self.ringBuffer else { return }

            let fill = SonexisAudioRingBufferGetFillFrames(ringBuffer)
            let now = DispatchTime.now()

            if fill >= startupPrerollTargetFrames {
                self.finishStartupPreroll(context: context, reason: "ring fill \(fill) frames")
            } else if fill > 0 {
                if firstFillTime == nil {
                    firstFillTime = now
                }

                if let firstFillTime,
                   now.uptimeNanoseconds - firstFillTime.uptimeNanoseconds >= partialTimeoutNanoseconds {
                    self.finishStartupPreroll(context: context, reason: "partial ring fill \(fill) frames")
                }
            }
        }
        startupPrerollTimer = timer
        timer.resume()
    }

    private func finishStartupPreroll(context: String, reason: String) {
        guard let ringBuffer else { return }

        startupPrerollTimer?.cancel()
        startupPrerollTimer = nil
        SonexisAudioRingBufferSetReadEnabled(ringBuffer, true)
        print("Startup: releasing processed output after \(reason).")
        requestProcessingGainRamp(context: context)
    }

    private func cancelStartupPreroll(enableRead: Bool, log: Bool) {
        let hadTimer = startupPrerollTimer != nil
        startupPrerollTimer?.cancel()
        startupPrerollTimer = nil

        if enableRead, let ringBuffer {
            SonexisAudioRingBufferSetReadEnabled(ringBuffer, true)
        }

        if log, hadTimer {
            print("Cleanup: canceled startup preroll gate.")
        }
    }

    private func requestProcessingGainRamp(context: String) {
        guard let ringBuffer else { return }

        let rampFrames = rampFrameCount(for: startupRampDuration)
        let milliseconds = Int((startupRampDuration * 1000.0).rounded())
        print("Gain: ramping processed path to \(processingGain) over \(milliseconds) ms (\(context)).")
        SonexisAudioRingBufferRequestGainRamp(ringBuffer, processingGain, rampFrames)
    }

    private func smoothTeardownPipeline(
        log: Bool,
        reason: String,
        rampDuration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        cancelStartupPreroll(enableRead: true, log: log)
        smoothTeardownWorkItem?.cancel()
        smoothTeardownWorkItem = nil

        guard let ringBuffer else {
            teardownPipeline(log: log, reason: reason)
            completion()
            return
        }

        let rampFrames = rampFrameCount(for: rampDuration)
        if log {
            let milliseconds = Int((rampDuration * 1000.0).rounded())
            print("Cleanup: ramping processed gain to unity over \(milliseconds) ms before releasing Process Tap.")
        }
        SonexisAudioRingBufferRequestGainRamp(ringBuffer, unityGain, rampFrames)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                completion()
                return
            }
            self.smoothTeardownWorkItem = nil
            self.teardownPipeline(log: log, reason: reason)
            completion()
        }
        smoothTeardownWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + rampDuration + rampSettleDuration,
            execute: workItem
        )
    }

    private func rampFrameCount(for duration: TimeInterval) -> UInt32 {
        max(UInt32((activeSampleRate * duration).rounded(.up)), 1)
    }

    private func teardownPipeline(log: Bool = false, reason: String = "pipeline teardown") {
        if log {
            print("Cleanup: tearing down audio pipeline (\(reason)).")
        }

        cancelStartupPreroll(enableRead: false, log: log)
        removeActiveDeviceAliveListener(log: log)

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
        activeSampleRate = 48_000.0
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
            self?.scheduleRouteRebuild(reason: "default output changed")
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

    private func installActiveDeviceAliveListener(deviceID: AudioDeviceID) throws {
        removeActiveDeviceAliveListener(log: false)

        var address = activeDeviceAliveAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRouteRebuild(reason: "active output device availability changed")
        }

        try checkOSStatus(
            AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                DispatchQueue.main,
                block
            ),
            operation: "Install active output device alive listener"
        )

        activeDeviceAliveListenerBlock = block
        activeDeviceAliveListenerDeviceID = deviceID
    }

    private func removeActiveDeviceAliveListener(log: Bool = false) {
        guard let activeDeviceAliveListenerBlock,
              activeDeviceAliveListenerDeviceID != kAudioObjectUnknown else {
            return
        }

        var address = activeDeviceAliveAddress()
        let status = AudioObjectRemovePropertyListenerBlock(
            activeDeviceAliveListenerDeviceID,
            &address,
            DispatchQueue.main,
            activeDeviceAliveListenerBlock
        )
        if log { printCleanupResult("removed active output device alive listener", status: status) }
        self.activeDeviceAliveListenerBlock = nil
        activeDeviceAliveListenerDeviceID = kAudioObjectUnknown
    }

    private func installSleepWakeObservers() {
        guard sleepWakeObservers.isEmpty else { return }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        let willSleep = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemWillSleep()
        }
        let didWake = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemDidWake()
        }
        sleepWakeObservers = [willSleep, didWake]
        print("Installed sleep/wake observers.")
    }

    private func removeSleepWakeObservers(log: Bool = false) {
        guard !sleepWakeObservers.isEmpty else { return }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers {
            notificationCenter.removeObserver(observer)
        }
        sleepWakeObservers.removeAll()
        if log { print("Cleanup: removed sleep/wake observers.") }
    }

    private func handleSystemWillSleep() {
        guard !isStopped else { return }

        routeChangeWorkItem?.cancel()
        routeChangeWorkItem = nil
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        isSuspendedForSleep = true

        print("")
        print("System sleep notification received.")
        printRouteDiagnostics(context: "before sleep")

        smoothTeardownPipeline(log: true, reason: "system sleep", rampDuration: routeChangeRampDuration) {
            print("Sleep: audio pipeline stopped. It will rebuild after wake.")
        }
    }

    private func handleSystemDidWake() {
        guard !isStopped else { return }

        isSuspendedForSleep = false
        print("")
        print("System wake notification received.")
        scheduleRecoveryRebuild(reason: "system wake", delay: wakeRebuildDelay, attemptsRemaining: rebuildRetryLimit)
    }

    private func scheduleRouteRebuild(reason: String) {
        guard !isStopped, !isSuspendedForSleep else { return }

        routeChangeWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil

        let workItem = DispatchWorkItem { [weak self] in
            self?.handleRouteChange(reason: reason)
        }
        routeChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func handleRouteChange(reason: String) {
        guard !isStopped, !isSuspendedForSleep else { return }
        routeChangeWorkItem = nil

        print("")
        print("Route change detected: \(reason).")
        printRouteDiagnostics(context: "route-change notification")

        smoothTeardownPipeline(log: true, reason: "route-change rebuild", rampDuration: routeChangeRampDuration) { [weak self] in
            guard let self, !self.isStopped, !self.isSuspendedForSleep else { return }

            do {
                try self.buildPipeline()
                self.printRouteDiagnostics(context: "after rebuild")
                print("Started Process Tap -> gain DSP -> default output playback.")
                print("Play system audio in another app. Press Control-C to stop.")
            } catch {
                self.handleRebuildFailure(
                    error,
                    reason: reason,
                    retryAttemptsRemaining: rebuildRetryLimit
                )
            }
        }
    }

    private func scheduleRecoveryRebuild(
        reason: String,
        delay: TimeInterval,
        attemptsRemaining: Int
    ) {
        guard !isStopped, !isSuspendedForSleep else { return }

        recoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptRecoveryRebuild(reason: reason, attemptsRemaining: attemptsRemaining)
        }
        recoveryWorkItem = workItem

        let milliseconds = Int((delay * 1000.0).rounded())
        print("Recovery: scheduling rebuild for \(reason) in \(milliseconds) ms.")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func attemptRecoveryRebuild(reason: String, attemptsRemaining: Int) {
        guard !isStopped, !isSuspendedForSleep else { return }
        recoveryWorkItem = nil

        print("")
        print("Recovery: attempting rebuild (\(reason)); attempts remaining after this: \(attemptsRemaining).")
        printRouteDiagnostics(context: "before recovery rebuild")

        do {
            try rebuildPipeline(reason: reason)
            print("Recovery: rebuild succeeded.")
        } catch {
            handleRebuildFailure(error, reason: reason, retryAttemptsRemaining: attemptsRemaining)
        }
    }

    private func handleRebuildFailure(
        _ error: Error,
        reason: String,
        retryAttemptsRemaining: Int
    ) {
        teardownPipeline(log: true, reason: "rebuild failure cleanup")
        print("Rebuild failed (\(reason)): \(error)")

        if error is NoDefaultOutputDeviceError {
            print("No output device is currently available. The pipeline is stopped and normal system audio should be unmuted.")
            print("Connect or select an output device; the default-output listener will retry when Core Audio reports a route.")
            return
        }

        guard retryAttemptsRemaining > 0 else {
            print("Recovery retries exhausted. Change routes again or restart the app to retry.")
            return
        }

        scheduleRecoveryRebuild(
            reason: reason,
            delay: rebuildRetryDelay,
            attemptsRemaining: retryAttemptsRemaining - 1
        )
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
            let gainPPM = SonexisAudioRingBufferGetCurrentGainPPM(ringBuffer)
            let writtenDelta = written - lastWrittenFrames
            let readDelta = read - lastReadFrames
            lastWrittenFrames = written
            lastReadFrames = read

            let peak = max(Double(peakPPM) / 1_000_000.0, 1.0e-12)
            let peakDB = 20.0 * log10(peak)
            let gain = Double(gainPPM) / 1_000_000.0
            print(
                String(
                    format: "ring fill: %u frames, in/s: %llu, out/s: %llu, input peak: %.1f dBFS, gain: %.3f, dropped: %llu, underflow: %llu",
                    fill,
                    writtenDelta,
                    readDelta,
                    peakDB,
                    gain,
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

    private func activeDeviceAliveAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
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
