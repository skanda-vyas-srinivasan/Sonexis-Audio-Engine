# ProcessTapDSP

Standalone macOS 14.4+ proof of concept for system-wide audio processing with Core Audio Process Taps.

The project proves this pipeline:

```text
system audio -> Core Audio Process Tap -> unity passthrough DSP -> current default output device
```

It does not use BlackHole, a virtual audio driver, or manual output-device switching.

## Confirmed Behavior

- `AudioHardwareCreateProcessTap` captures live outgoing system audio.
- `CATapMutedWhenTapped` suppresses the original direct output path while the app reads the tap.
- The default app mode keeps processing gain at unity and passes audio through unchanged.
- A `--debug-pitch-up` flag enables the audible pitch-shift proof effect.
- Processed audio plays through the selected default output device.
- Self-exclusion prevents the app's own playback from being recursively captured.
- Input peak confirms real capture and drops to silence when source audio is paused.
- macOS output volume does not affect input peak, which is expected because the tap captures before hardware volume.
- Default-output route changes trigger full pipeline teardown and rebuild.

## Requirements

- macOS 14.4 or newer.
- Xcode or Xcode Command Line Tools with a macOS SDK that exposes Core Audio Process Tap APIs.
- System audio capture permission when macOS prompts for it.

The Process Tap API is public from macOS 14.2, but this prototype intentionally gates at macOS 14.4.

## Build

```sh
cd /Users/skandavyassrinivasan/dev/ProcessTapDSP
make
```

The build creates:

```text
.build/ProcessTapDSP.app
```

The app is ad-hoc signed by the Makefile.

## Run

```sh
cd /Users/skandavyassrinivasan/dev/ProcessTapDSP
make run
```

Then play audio in another app such as Spotify, YouTube, Music, or a browser.

Expected signs of success:

- Audio remains on the normal selected output device.
- On startup, processed playback waits for a small preroll buffer and remains at unity gain.
- In default mode, source audio should sound unchanged except for the prototype handoff behavior.
- Pressing `Control-C` briefly ramps processed playback back to unity gain, then stops the app and returns normal system output.
- Terminal diagnostics show nonzero `in/s`, nonzero `out/s`, and input peak above silence while source audio is playing.

For an obvious audible DSP proof:

```sh
cd /Users/skandavyassrinivasan/dev/ProcessTapDSP
make run RUN_ARGS=--debug-pitch-up
```

In debug pitch mode, source audio should sound pitched up by roughly seven semitones.

Example diagnostic:

```text
ring fill: 512 frames, in/s: 48000, out/s: 48000, input peak: -12.4 dBFS, gain: 1.000, dropped: 0, underflow: 0
```

## Route Changes

The tap is device-scoped. It is created for the current default output device UID and stream index 0.

When the default output device changes, the app:

1. Stops tap and playback IOProcs.
2. Destroys the private aggregate device.
3. Destroys the Process Tap.
4. Frees the realtime ring buffer.
5. Reads the new default output device.
6. Recreates the full capture/playback pipeline on the new device.
7. Waits for a small preroll buffer and starts the new processed path at unity gain.

Diagnostics print:

- current default output device;
- tap source device;
- playback output device.

After a successful rebuild, all three should identify the same output device.

## Sleep/Wake And Disconnects

The prototype uses `NSWorkspace` sleep/wake notifications and a Core Audio device-alive listener on the active output device.

On sleep, the app ramps back toward unity and tears down the Process Tap, aggregate device, IOProcs, and ring buffer. On wake, it waits briefly for Core Audio routes to settle and attempts to rebuild the pipeline.

If an output route disappears or temporarily fails to rebuild, the app leaves the pipeline stopped and unmuted, then retries transient failures. If Core Audio reports no default output device, the app logs a graceful stopped state and waits for the default-output listener to fire again.

Manual validation checklist: [MILESTONE_4_TESTS.md](MILESTONE_4_TESTS.md).

## Shutdown

Press `Control-C` to stop the app. Shutdown logs confirm that the app:

1. Removes the default-output route listener.
2. Confirms processed playback is at unity gain before releasing the Process Tap.
3. Stops the tap aggregate IOProc.
4. Stops the playback output IOProc.
5. Destroys both IOProc IDs.
6. Destroys the private aggregate device.
7. Destroys the Process Tap.
8. Frees the realtime ring buffer.

The expected audible result is that normal system audio returns without a sudden quiet-to-loud jump when the tap releases `CATapMutedWhenTapped`.

## Current Limitations

- Captures stream index 0 of the selected output device only.
- Requires matching Float32 tap/output formats.
- No sample-rate conversion.
- No channel remixing.
- Startup preroll intentionally adds a small buffer before processed playback begins; this improves handoff smoothness but adds a small amount of latency.
- Pitch shifting is a rough realtime proof-of-concept and can produce audible artifacts.
- Pitch shifting is disabled by default and exists only as a debug proof effect.
- No UI.
- No configurable DSP.
- No Audio Unit, VST, or plugin hosting.
- No app sandbox support has been validated.
- Sleep/wake and device-disconnect recovery are best-effort and need systematic manual testing on each hardware route.
- Bluetooth, AirPods, HDMI, and aggregate-device behavior still need systematic manual testing.

## Source Layout

```text
Info.plist
Makefile
Sources/
  AudioOutputEngine.swift
  CoreAudioSupport.swift
  DSPConfiguration.swift
  DSPProcessor.swift
  ProcessTapDSPApp.swift
  ProcessTapDSPEngine.swift
  RealtimeAudioRing.c
  RealtimeAudioRing.h
  RealtimeRingBuffer.swift
  TapCaptureEngine.swift
  main.swift
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the current Core Audio object model and realtime constraints.
