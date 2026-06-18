import Darwin
import Foundation

let requiredVersion = OperatingSystemVersion(
    majorVersion: 14,
    minorVersion: 4,
    patchVersion: 0
)

guard ProcessInfo.processInfo.isOperatingSystemAtLeast(requiredVersion) else {
    fputs("ProcessTapDSP requires macOS 14.4 or newer.\n", stderr)
    exit(EXIT_FAILURE)
}

let prototype = ProcessTapDSPPrototype()

signal(SIGINT, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruptSource.setEventHandler {
    prototype.stop(reason: "SIGINT / Control-C") {
        exit(EXIT_SUCCESS)
    }
}
interruptSource.resume()

do {
    try prototype.start()
    RunLoop.main.run()
} catch {
    let startupError = error
    prototype.stop(reason: "startup failure") {
        fputs("\(startupError)\n", stderr)
        if let coreAudioError = startupError as? CoreAudioError,
           coreAudioError.operation == "AudioHardwareCreateProcessTap" {
            fputs("\nTap creation failed at the system audio capture boundary.\n", stderr)
            fputs("On current macOS versions this can mean the OS version is unsupported, the app bundle is missing NSAudioCaptureUsageDescription, or the user denied audio capture permission.\n", stderr)
            fputs("If permission was denied, enable this app in System Settings > Privacy & Security. Apple's UI wording for audio capture varies by macOS release.\n", stderr)
        }
        exit(EXIT_FAILURE)
    }
    RunLoop.main.run()
}
