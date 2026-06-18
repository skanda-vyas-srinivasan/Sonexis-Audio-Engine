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

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--help") {
    print("Usage: ProcessTapDSP [--debug-pitch-up]")
    print("")
    print("Default mode is unity passthrough DSP with gain 1.0.")
    print("--debug-pitch-up enables the audible +7 semitone proof effect.")
    exit(EXIT_SUCCESS)
}

let configuration: DSPConfiguration = arguments.contains("--debug-pitch-up")
    ? .debugPitchUp
    : .productBaseline

let engine = ProcessTapDSPEngine(configuration: configuration)

signal(SIGINT, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruptSource.setEventHandler {
    engine.stop(reason: "SIGINT / Control-C") {
        exit(EXIT_SUCCESS)
    }
}
interruptSource.resume()

do {
    try engine.start()
    RunLoop.main.run()
} catch {
    let startupError = error
    engine.stop(reason: "startup failure") {
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
