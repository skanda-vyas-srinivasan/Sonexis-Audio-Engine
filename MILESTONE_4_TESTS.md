# Milestone 4 Manual Tests

Use this checklist to validate sleep/wake and device-disconnect behavior.

## Baseline

1. Start audio in another app.
2. Run:

   ```sh
   cd /Users/skandavyassrinivasan/dev/ProcessTapDSP
   make run
   ```

3. Confirm startup reaches:

   ```text
   Startup: releasing processed output after ring fill ...
   Gain: ramping processed path to 0.1 ...
   ```

4. Confirm diagnostics show nonzero `in/s`, nonzero `out/s`, and `gain: 0.100`.

## Sleep/Wake

1. Keep source audio playing.
2. Put the Mac to sleep from the Apple menu or by closing the lid.
3. Wake the Mac.
4. Confirm the terminal shows:

   ```text
   System sleep notification received.
   Sleep: audio pipeline stopped. It will rebuild after wake.
   System wake notification received.
   Recovery: scheduling rebuild for system wake ...
   Recovery: rebuild succeeded.
   ```

5. Confirm audio is audible after wake.
6. Confirm route diagnostics after recovery show the same current default output, tap source device, and playback output device.
7. Press `Control-C` and confirm normal cleanup logs still appear.

## Wired Headphones

1. Start with speakers as default output.
2. Run the app and verify processed audio.
3. Plug in wired headphones.
4. Confirm a route-change rebuild occurs.
5. Confirm diagnostics identify the headphones as:
   - current default output;
   - tap source device;
   - playback output device.
6. Unplug the headphones.
7. Confirm another rebuild occurs and audio returns to speakers.

## Bluetooth/AirPods

1. Start with speakers as default output.
2. Run the app and verify processed audio.
3. Connect AirPods or another Bluetooth output.
4. Switch system output to that device.
5. Confirm route-change rebuild logs and matching diagnostics.
6. Disconnect or turn off the Bluetooth device.
7. Confirm either:
   - the app rebuilds on the new default output, or
   - the app logs that no output device is available and leaves the pipeline stopped/unmuted.

## HDMI/Display Audio

1. Start with speakers as default output.
2. Run the app and verify processed audio.
3. Connect HDMI or display audio.
4. Switch system output to the display.
5. Confirm route-change rebuild logs and matching diagnostics.
6. Disconnect HDMI/display audio.
7. Confirm the app rebuilds on the fallback output or logs a graceful no-output state.

## Expected Failure Handling

If no usable output route exists, the app should log:

```text
No output device is currently available. The pipeline is stopped and normal system audio should be unmuted.
Connect or select an output device; the default-output listener will retry when Core Audio reports a route.
```

This is a graceful stopped state, not a crash.

## Remaining Bugs To Record

Record any of the following if observed:

- app exits unexpectedly;
- audio stays muted after sleep, wake, disconnect, or Control-C;
- diagnostics show mismatched default/tap/playback devices after rebuild;
- repeated rebuild loop;
- route changes recover only after restarting the app;
- startup preroll never releases while source audio is playing;
- feedback or echo after rebuild.
