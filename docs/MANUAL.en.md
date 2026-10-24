# User manual

[简体中文](MANUAL.md) · **English** · [Back to README](../README.en.md)

The [README](../README.en.md) gets you to a built app and the first sound. This manual picks up from there: **how each action and setting actually behaves**. How the code is organised is in the [architecture notes](ARCHITECTURE.md) (in Chinese). The interface is in Simplified Chinese; labels are quoted as they appear, followed by an English gloss.

## Contents

- [Opening and playback](#opening-and-playback)
- [Playlists](#playlists)
- [Playback modes](#playback-modes)
- [Saving and restoring](#saving-and-restoring)
- [Output and spatial audio](#output-and-spatial-audio)
- [Advanced spatial audio settings](#advanced-spatial-audio-settings)
- [Parametric EQ](#parametric-eq)
- [PoseBridge head tracking](#posebridge-head-tracking)

## Opening and playback

- `⌘O` opens one or more audio or video files. You can also drag files into the window, or choose to open them with SpatialUnlock Player in Finder.
- Double-click a list entry, or select it and press Return, to play.
- Space plays / pauses; `⌘←` / `⌘→` go to the previous / next item; `⌘⌥←` / `⌘⌥→` skip back / forward 10 seconds.
- Video supports the full-screen button, double-clicking the picture and `⌃⌘F`. Closing the window ends playback.
- Volume starts at 10%. Volume, spatial audio mode and output selection are remembered.

## Playlists

- The sidebar can create, rename, delete and switch between named playlists. Switching a list is for browsing and managing; playback only moves to it when you double-click an entry or select one and press Return. Click “正在播放：列表名” (Now playing: list name) to return to the playing list.
- Opened or dropped files are added to the list being browsed at the time. If there is already a current track they are only appended; if there is no current track and they are added to an empty list, the first one plays.
- Right-click to remove an entry or show the file in Finder; the list menu can clear the list. Removing an entry never deletes the file.
- Previous / next and automatic continuation always follow the playing list. Deleting or clearing that list stops playback; deleting lists or entries never deletes media files.

## Playback modes

The playback mode menu at the bottom and the “播放” (Playback) menu bar menu offer sequential, repeat all, repeat one and shuffle. All lists share the mode, and it is remembered.

- Sequential stops after the last item ends. Repeat one only affects automatic continuation; you can still change tracks by hand.
- Shuffle reshuffles every entry each round; with more than one item, the same item is not played twice in a row across a round boundary. Previous goes back through the actual playback history, and next after going back first moves forward along that history. Multiple entries for the same file each take part in shuffle.

## Saving and restoring

All lists (including empty ones), the browsed and playing lists, the current track and the playback position are saved automatically. Reopening restores them, paused. An older single list is migrated to “默认列表” (Default list).

List changes are saved immediately, the position every 5 seconds during playback, and also on pause and quit. Only file references are stored; media files are not copied. Files that are temporarily unavailable stay in their lists. The shuffle order and playback history last only for the current run; on reopening, a new round starts from the restored track.

## Output and spatial audio

“系统默认” (System default) in the output menu follows the current macOS output; you can also choose a device for this app alone.

| Mode | Behaviour |
|---|---|
| 自动 (Automatic, default) | Natively compatible devices use the system settings; ordinary stereo headphones that are positively identified use the compatibility layer; other devices use system native playback |
| 强制耳机空间音频 (Force headphone spatial audio) | Ordinary stereo outputs use the compatibility layer; natively compatible devices still use the system path; outputs with more than two channels stay on native playback |
| 关闭 (Off) | Turns the compatibility layer off and disallows spatialisation of the current AVPlayerItem |

3.5 mm headphones are identified through `BuiltInHeadphoneOutputDevice`; other headphones by the headphones terminal type of their audio stream. Native capability is confirmed with unspoofed CoreAudio property queries, not inferred from Bluetooth / USB transport alone.

Changing the output or the mode rebuilds the playback chain and restores the position and play state. When the output device leaves the device list or becomes unavailable, playback pauses rather than suddenly switching to another output.

## Advanced spatial audio settings

Click the slider icon next to the spatial audio picker to open the advanced panel. Settings are saved per actual output device; “系统默认” follows the current device and restores that device's settings. Both the ordinary-headphone and the AirPods headphone spatial rendering paths can use them, and both settings start as “系统决定” (System decides).

- **处理余量 (Processing headroom)**: choose “自定义” (Custom) to adjust between 0 and 20 dB in 0.1 dB steps; the first value is 20 dB. It takes effect when you release the slider or press Return in the number field; you can also click 0 / 20 dB. Custom 0 dB forces 0 / 0 dB, whereas System decides keeps the system's own configuration.
- **HRTF 模式 (HRTF mode)**: System decides, 通用 (Generic), 个性化 (Personalised). Personalised requests the system's existing profile without changing global settings. The panel shows the actual state, and says plainly when the profile is not in effect and the generic HRTF is still used.
- A change rebuilds the playback chain and restores the position and play / pause state. Switching devices discards an uncommitted value or drag. “恢复此设备的系统设置” (Restore this device's system settings) resets both settings.

Headroom attenuates before dynamics processing and compensates after it, changing the level the loudness compressor and true-peak limiter see; main volume is controlled separately. Measured on this machine, the AirPods path uses −20 / +20 dB and the FIIO's original path 0 / 0 dB. With the same HRTF fixed and headroom matched, the tested HAL PCM can be identical sample for sample; see the [in-process comparison](../Tests/ROUTE_COMPARISON.md) (in Chinese). After the HAL the two devices' USB PCM still differs, with AirPods attenuated by about 12 dB; that stage is not affected by this setting and the app does not compensate for it; see the [USB PCM comparison](../Tests/USB_AUDIO_COMPARISON.md) (in Chinese).

Advanced settings apply only on an actual two-channel headphone spatial rendering path. When nothing is playing, spatial audio is off or the chain is unavailable, the selection is kept and the status is shown. When the complete gain node pair cannot be confirmed, system processing stays in use.

## Parametric EQ

Click “EQ” next to the volume and choose “导入…” (Import…) to load AutoEQ / Equalizer APO parameter text. `Preamp`, `ON/OFF` and `PK` / `LSC` / `HSC` are supported, up to 32 bands. A successful import enables the EQ; the panel shows the preamp, the read-only parameters and the overall response curve including the preamp, and the master switch can bypass it at any time.

One configuration and switch are saved globally and restored on relaunch, independent of where the original file was. A failed import shows the line number and reason and keeps the current configuration. Text must be UTF-8 and under 64 KiB; blank lines, `#` / `;` comments and any line endings are supported.

In this first version, EQ only acts on the spatial audio rendering path. With spatialisation off, or when the current path has no spatial renderer, the panel shows it as not applied; the configuration and switch are kept. EQ processes the left and right channels after spatialisation and head tracking, uses the file's preamp value and adds no normalisation. Changing the configuration or switch crossfades over about 20 ms. When nothing is playing or the output format is unavailable, the curve is labelled as a 48 kHz preview.

## PoseBridge head tracking

Click “头部追踪” (Head tracking) in the toolbar and turn on “接收外部姿态” (Receive external pose). It listens on `127.0.0.1:9000` by default and supports [PoseBridge](https://github.com/SakuzyPeng/PoseBridge) **OSC 3** quaternion and Euler angle output. The player does not connect to or configure sensors; USB / Bluetooth capture, mounting orientation and device reconnection are handled by the external PoseBridge.

- Set the external PoseBridge's `--osc-target` to the local address and port shown in the panel.
- “来源名称” (Source name) corresponds to PoseBridge's `--source-id`; left empty, it locks onto the first valid pose source. Turn receiving off before changing the port or source.
- The first valid pose defines straight ahead. Face the screen and click “回正” (Recentre), or press `⌘⇧R`, to re-establish the listening reference; no zeroing or save command is sent to the device.
- With no new pose for more than 500 ms, or when the source reports stopped / failed, the last orientation is held. Heartbeats and duplicate packets do not extend a pose's validity. When the source reconnects or the reference changes, the sound field stays continuous, and you can recentre again.
- Turning receiving off restores the system orientation. With spatial audio off, poses are still received and shown but not applied to the renderer; they are applied again once spatial audio is back on.
- If another program holds the loopback port, an error is shown; the app does not take the port from another receiver.

You can verify this without a sensor. For example, in the PoseBridge repository run:

```sh
./target/release/posebridge simulate --source-id headset --pattern yaw \
  --sample-rate-hz 100 --osc-rate-hz 100 --osc-target 127.0.0.1:9000
```

The player must have receiving on and be playing content with spatial audio on; you can set the source name to `headset`. For hardware capture, use a verified device identifier and wearing mapping in the external PoseBridge. The app saves the receive switch, port and source, but not the last recentring reference.
