# M4 controller validation under the pinned engine (#17)

Rig: Mac mini M4, macOS 27.2, engine `ember-m0-r23` (DXVK prefix), Ember 1.1.2, Steam USF4 build 834219. `SSFIV.exe` imports `XINPUT1_3.dll`, `XINPUT9_1_0.dll` and `DINPUT8.dll`; the probe uses the same `xinput1_3` and DirectInput 8 calls as a 32-bit process in the game's prefix (`scripts/macos-engine/m0.sh pads [seconds]`).

## Support table

| Device | USB identity on macOS | macOS driver | Wine sees | Probe | In-game | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Hit Box (XInput mode) | `045e:028e` "Controller", wired USB | built-in `com.apple.gamecontroller.driver.XboxGamepad` (`Xbox360Gamepad`), no install | XInput slot 0 (gamepad), DInput "Controller" `045e:02e0` | all 14 buttons, both triggers, 4 directions, chords up to 6 buttons | menus and matches, reported by the player | **Playable** |
| Xbox 360 wired pad | `045e:028e` (same as above) | same built-in driver | expected same as Hit Box | not tested (no device) | not tested | Untested |
| PS5 DualSense | — | — | — | not tested (no device) | not tested | Untested |
| Fight stick / leverless in DInput or PS mode | — | — | — | not tested (no device) | not tested | Untested |

The only device available on the rig was a Hit Box that enumerates as an Xbox 360 wired controller, so the 360 pad row shares its driver path but has no physical evidence of its own.

## Hit Box evidence (2026-10-12)

- `ioreg`: `idVendor=1118 idProduct=654` (`045e:028e`), interface class 255 subclass 93, matched by Apple's `Xbox360Gamepad` dext and exposed as HID Generic Desktop / Game Pad (usage page 1, usage 5).
- Wine enumerates it as `WINEBUS\VID_045E&PID_02E0` with the `WINEXINPUT` child, so the game gets it through both XInput and DInput. Wine reports product `02e0`, not the USB `028e`; nothing in Ember or SF4 keys on the product ID.
- `m0.sh pads 90` with the probe window in front logged every input once on both APIs: D-pad Up/Down/Left/Right (DInput POV 0/180/270/90), A/B/X/Y (b0–b3), LB/RB (b4/b5), Back/Start (b6/b7), LS/RS (b8/b9), LT/RT (XInput triggers; DInput reports triggers on an axis the probe does not log).
- `m0.sh pads 45` with another app in front: presses still arrived, including chords of up to six buttons (`RB A B Y LT RT`). The game keeps receiving pad input when it is not the frontmost window.
- SOCD comes from the Hit Box firmware and passes through unchanged: Left+Right reads as neutral, Up+Down reads as Up.
- One LS press read as two 7 ms presses (switch bounce on the device, not a mapping fault).

## Quirks and overrides

- No mapping overrides are needed for XInput devices: macOS ships the Xbox 360 driver and Wine maps it to an XInput gamepad with the standard layout.
- Xbox-mode devices do not need any third-party macOS driver (the old 360Controller kext is unnecessary on current macOS).

## Still owed

- PS5 DualSense over USB and Bluetooth: DInput/HID path, button layout in the native controller menu.
- A fight stick or leverless in DInput or PS mode: the native type-4 DInput path described in `CONTROLLER_SELECTION_VALIDATION.md`.
- A real Xbox 360 or Xbox One/Series pad, to confirm the Hit Box result is not device-specific.

Run `scripts/macos-engine/m0.sh pads 60`, press every button and direction, then play a training session and record the row here.
