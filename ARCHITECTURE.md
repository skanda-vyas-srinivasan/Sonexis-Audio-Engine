# Architecture

## Pipeline

```text
Other apps
  -> current default output device stream
  -> private Core Audio Process Tap
  -> private aggregate device input IOProc
  -> hardcoded gain DSP with realtime gain ramp control
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

Receives Float32 tap buffers and writes gained samples into the realtime ring buffer.

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

Gain changes are requested from the main thread with atomics and applied inside the tap callback. Startup and route rebuilds initialize the processed path at unity and ramp down to the prototype's `0.1` gain. Shutdown and route rebuilds ramp back to unity before the tap is destroyed, so releasing `CATapMutedWhenTapped` does not abruptly jump from quiet processed audio to normal system volume.

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

## Feedback Prevention

The app excludes its own HAL process object from the tap and verifies the installed tap description after creation. If verification fails, playback does not start.

This matters because the app's processed playback is sent to the same default output route that the tap is monitoring. Without self-exclusion, the app could capture and replay its own output.
