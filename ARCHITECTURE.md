# Architecture

## Pipeline

```text
Other apps
  -> current default output device stream
  -> private Core Audio Process Tap
  -> private aggregate device input IOProc
  -> hardcoded bass boost DSP with unity gain and realtime gain ramp control
  -> preallocated realtime ring buffer
  -> default output device output IOProc
  -> speakers/headphones
```

## Core Audio Objects

`AudioObjectSystemObject`

Used to read the current default output device and install a listener for `kAudioHardwarePropertyDefaultOutputDevice`.

HAL process object

The app looks up its own HAL process object by matching `kAudioProcessPropertyPID` to `getpid()`. Playback mode refuses to start if this object cannot be found, because self-exclusion is required to prevent feedback.

Default output `AudioDeviceID`

The currently selected output device. The app opens an output IOProc on this device but does not make it default or change the user's route.

Output stream object

The prototype uses stream index 0 of the default output device. The tap is scoped to that device UID and stream index.

`CATapDescription`

Created with `excludingProcesses:deviceUID:stream:`. The app excludes its own HAL process object and sets `CATapMutedWhenTapped`.

Process Tap `AudioObjectID`

Created with `AudioHardwareCreateProcessTap`. The tap is not read directly; it is attached to a private aggregate device.

Private aggregate `AudioDeviceID`

Created with `AudioHardwareCreateAggregateDevice` and `kAudioAggregateDeviceTapListKey`. This is the readable endpoint for the tap.

Tap aggregate IOProc

Receives Float32 tap buffers and writes bass-boosted samples into the realtime ring buffer.

Default output IOProc

Reads from the realtime ring buffer and writes to the selected output device. It writes silence on underrun.

## Realtime Constraints

Audio callbacks must not:

- allocate memory;
- take locks;
- print/log;
- block;
- call Core Audio property APIs;
- perform file or network I/O.

The current callback path uses a small C11-atomic single-producer/single-consumer ring buffer to avoid Swift macOS 15-only atomics and to keep callback work predictable on macOS 14.4.

Gain changes are requested from the main thread with atomics and applied inside the tap callback. The current prototype keeps its processing gain at `1.0` so the bass boost can be evaluated without an overall attenuation masking the result. Startup and route rebuilds initialize the processed path at unity and hold output reads until the ring has a small preroll buffer. If capture has started but the target fill is not reached, the app can accept a partial fill after a short timeout. Shutdown and route rebuilds confirm the processed path is at unity before the tap is destroyed, so releasing `CATapMutedWhenTapped` does not abruptly change overall gain.

The bass boost is a hardcoded one-pole low-frequency shelf implemented in `RealtimeAudioRing.c`. It tracks a low-pass state per channel and mixes that low band back into the signal. This is intentionally simple and audible; it is not a production EQ.

The startup preroll gate is implemented in the C ring buffer with an atomic read-enabled flag. While the gate is closed, the output IOProc writes silence without draining captured frames. Once the main thread observes enough fill, it enables reads and requests the gain ramp. This avoids locks, allocation, and Swift state mutation in realtime callbacks.

## Route Changes

Process Taps created with a device UID are device-scoped. When the default output changes, the existing tap remains associated with the original device.

The app handles this by rebuilding the whole pipeline rather than mutating the existing tap. That is the safest prototype behavior because it refreshes:

- tap description;
- tap object;
- private aggregate device;
- tap IOProc;
- playback IOProc;
- ring buffer;
- source/playback diagnostics.

## Sleep/Wake And Disconnects

The app uses `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification` from AppKit. This keeps the prototype headless but adds an AppKit framework dependency.

On sleep, the app cancels pending route/recovery work, marks the pipeline as suspended, and tears down the active Core Audio objects through the same smooth ramp path used for route changes. On wake, it waits briefly before attempting a full rebuild so Core Audio has time to publish the post-wake default output route.

The app also installs `kAudioDevicePropertyDeviceIsAlive` on the active output device. If the active device disappears before or without a default-output property change, that listener schedules the same full route rebuild path.

If rebuild fails because no default output device exists, the app leaves the pipeline stopped and unmuted. The default-output listener remains installed so connecting or selecting a route can trigger recovery. Other transient rebuild failures are retried a small number of times before the app logs that manual route change or restart is needed.

## Feedback Prevention

The app excludes its own HAL process object from the tap and verifies the installed tap description after creation. If verification fails, playback does not start.

This matters because the app's processed playback is sent to the same default output route that the tap is monitoring. Without self-exclusion, the app could capture and replay its own output.

## Source Ownership

`ProcessTapDSPApp.swift`

Coordinates app lifecycle, route changes, sleep/wake handling, startup preroll, shutdown ramp timing, status diagnostics, and recovery policy. It does not own individual tap/output IOProc callback implementations.

`TapCaptureEngine.swift`

Owns `CATapDescription`, the Process Tap `AudioObjectID`, the private aggregate `AudioDeviceID`, and the tap aggregate IOProc. Its realtime callback only forwards incoming tap buffers to `RealtimeRingBuffer`.

`AudioOutputEngine.swift`

Owns the current default output device IOProc. Its realtime callback only reads processed samples from `RealtimeRingBuffer` into the Core Audio output buffer.

`DSPProcessor.swift`

Owns the hardcoded unity gain, bass boost settings, and ramp durations. It configures the ring buffer from the main thread; it does not allocate or run Swift DSP inside Core Audio callbacks.

`RealtimeRingBuffer.swift`

Provides Swift lifetime and metrics access around the C realtime ring buffer. The actual audio-thread storage, atomics, startup read gate, gain ramp, bass boost, and sample copy/multiply path remain in `RealtimeAudioRing.c`.

`CoreAudioSupport.swift`

Contains shared HAL property helpers, error types, format checks, device summaries, and cleanup logging.
