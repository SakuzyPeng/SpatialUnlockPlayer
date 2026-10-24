# SpatialUnlock Player

[简体中文](README.md) · **English**

A local audio and video player for macOS that lets **ordinary stereo headphones** (3.5 mm, USB DAC, Bluetooth) take Apple's native spatial audio rendering path — the same system renderer AirPods use, with no virtual audio device in between and no third-party HRTF.

> It is not a virtual audio driver and not a system-wide switch: it only affects what this app plays. It plays local files that AVFoundation supports, with no FFmpeg fallback, transcoding, network playback, media library or subtitle management.

**Requirements: Apple Silicon, macOS 27 or later. Currently validated on macOS 27.0.1.**

This page covers what the app solves, getting started and building. **For how each action and setting behaves, see the [user manual](docs/MANUAL.en.md)** ([简体中文](docs/MANUAL.md)). The app's interface is in Simplified Chinese; this page quotes labels as they appear, followed by an English gloss.

## Contents

- [What it solves](#what-it-solves)
- [What you can do with it](#what-you-can-do-with-it)
- [Getting the app](#getting-the-app)
- [Five steps to first playback](#five-steps-to-first-playback)
- [Choosing a spatial audio mode](#choosing-a-spatial-audio-mode)
- [Matching AirPods rendering on ordinary headphones](#matching-airpods-rendering-on-ordinary-headphones)
- [Output devices](#output-devices)
- [FAQ](#faq)
- [Known limits](#known-limits)
- [Building from source](#building-from-source)
- [Documentation](#documentation)
- [Related projects](#related-projects)
- [License](#license)

## What it solves

macOS opens its headphone spatial rendering path only to headphones it recognises as natively compatible, such as AirPods; ordinary headphones do not take that path by default. Inside its own process, this app answers the CoreAudio capability queries for "supports spatial audio" for the selected output device only, then plays through AVPlayer as usual. Decoding and spatial rendering are still done entirely by the system.

To find out how close this gets to AirPods, AirPods Max and a FIIO KA11 (both connected over USB) were compared sample by sample on this machine, from the spatial mixer all the way to the USB transfers:

- **Spatial rendering is identical.** With the same HRTF and head orientation, the two paths produce bit-identical spatial mixer output. Verified with low-level and high-peak 5.1, Atmos and 16-channel APAC.
- **The difference is downstream.** After the spatial mixer come loudness compression and a true-peak limiter. The AirPods path sets −20 / +20 dB of gain before and after those stages; the ordinary-headphone path sets 0 / 0 dB. Compression and limiting are non-linear, so the two settings treat the same signal differently.
- **It can be matched.** With that gain pair also set to −20 / +20 dB, the PCM this process hands to the HAL is bit-identical to AirPods. Swapping the parameters in both directions gives the same result, which establishes the cause.
- **There is still a difference after the HAL.** Synchronised captures of the USB transfers show that even when the HAL output is bit-identical, the two devices' USB PCM differs. On AirPods the signal is attenuated by about 12 dB after the HAL and uses a different sample container and quantisation. This is also present with spatial audio off, so it is unrelated to the compatibility layer or the headroom setting.

```mermaid
flowchart LR
    P[AVPlayer decoding] --> S[Apple spatial mixer<br/>HRTF + head orientation]
    S --> G1[Pre-gain]
    G1 --> D[Loudness compression<br/>true-peak limiter]
    D --> G2[Post-gain]
    G2 --> V[Player volume]
    V --> H[This process's HAL output]
    H --> U[System / driver stages<br/>USB payload]
```

| | AirPods (native) | Ordinary headphones (default) | Ordinary headphones + 20 dB headroom |
|---|---:|---:|---:|
| Pre / post gain | −20 / +20 dB | 0 / 0 dB | −20 / +20 dB |
| Spatial mixer PCM (same HRTF and orientation) | Reference | Bit-identical | Bit-identical |
| HAL PCM | Reference | Different | Bit-identical |
| USB PCM | Reference | Different | Different: about −12 dB on the AirPods side, different quantisation |

These results cover this machine, this system version, these devices and this material. What matches is the spatial mixer and this process's HAL output; the USB payloads differ, and the headphones' internal DSP, DAC and acoustic output were not measured, so this does not mean the sound you finally hear is the same. Methods and figures (in Chinese): [in-process comparison](Tests/ROUTE_COMPARISON.md) and [USB PCM comparison](Tests/USB_AUDIO_COMPARISON.md).

## What you can do with it

- **Spatial audio on ordinary headphones.** Multichannel PCM, Atmos, APAC and other content the system supports, rendered to binaural output by Apple's spatial renderer.
- **Tune spatial rendering per device.** Processing headroom (0–20 dB) and HRTF (generic / personalised) are saved per output device, and the panel shows what actually took effect, not just what was requested.
- **External head tracking.** Receives [PoseBridge](https://github.com/SakuzyPeng/PoseBridge) OSC poses, so the sound field turns with your head on ordinary headphones too, without relying on AirPods system head tracking.
- **Parametric EQ.** Imports AutoEQ / Equalizer APO parameter text and processes the final stereo output after spatialisation and head tracking.
- **Multiple playlists.** Named playlists with sequential, repeat all, repeat one and shuffle; reopen the app and it returns to the last track and position, paused.
- **Video playback.** AVKit picture with full screen.

## Getting the app

The source repository does not contain a built app. You can get one in these ways:

- **Release.** Open [Releases](https://github.com/SakuzyPeng/SpatialUnlockPlayer/releases) and download `SpatialUnlockPlayer-macos-arm64.zip` and its `.sha256` checksum file from the version's **Assets**. If no release is available yet, use a CI build.
- **CI build.** Open [Actions → CI](https://github.com/SakuzyPeng/SpatialUnlockPlayer/actions/workflows/ci.yml), select a green successful run on `main`, then download the app artifact whose name starts with `SpatialUnlockPlayer-macos-arm64-ad-hoc-` under **Artifacts** at the bottom of the page. Signing in to GitHub is required; artifacts are kept for 7 days.
- **Build it yourself.** See [Building from source](#building-from-source); one command exports an app you can double-click.

For a CI download, first unpack GitHub's outer artifact ZIP to get `SpatialUnlockPlayer-macos-arm64.zip` and its `.sha256` file. Keep the app ZIP and checksum in the same directory, then verify and extract:

```sh
shasum -a 256 -c SpatialUnlockPlayer-macos-arm64.zip.sha256
ditto -x -k SpatialUnlockPlayer-macos-arm64.zip .
```

This produces `SpatialUnlock Player.app`, which you can move to Applications and open.

The app is ad hoc signed and not notarised by Apple, so a downloaded copy may be blocked by Gatekeeper. Once you have confirmed it came from this repository, allow it as macOS prompts under System Settings → Privacy & Security, or build it yourself.

## Five steps to first playback

1. Double-click `SpatialUnlock Player.app`.
2. Press `⌘O` to open files, or drag them into the window. Double-click a list entry (or select it and press Return) to play.
3. Pick your headphones in the output menu, or leave it on “系统默认” (System default).
4. Leave the spatial audio mode on “自动” (Automatic). The status at the bottom should read “普通耳机兼容模式” (ordinary-headphone compatibility mode); if it reads “系统原生播放” (system native playback), switch to “强制耳机空间音频” (Force headphone spatial audio).
5. To get closer to AirPods, click the slider icon next to the mode to open the advanced settings; see [the next section](#matching-airpods-rendering-on-ordinary-headphones).

Space plays / pauses, `⌘←` / `⌘→` go to the previous / next item, and `⌘⌥←` / `⌘⌥→` skip back / forward 10 seconds. More in the [user manual](docs/MANUAL.en.md#opening-and-playback).

## Choosing a spatial audio mode

Changing the output or the mode rebuilds the playback chain and restores the position and play / pause state.

| Mode | Behaviour |
|---|---|
| **自动** (Automatic, default) | Natively compatible devices use the system settings; ordinary stereo headphones that are positively identified use the compatibility layer; other devices use system native playback |
| **强制耳机空间音频** (Force headphone spatial audio) | Ordinary stereo outputs use the compatibility layer; natively compatible devices still use the system path; outputs with more than two channels stay on native playback |
| **关闭** (Off) | Turns the compatibility layer off and disallows spatialisation of the current content |

**Not sure which to pick?** Stay on Automatic. If you use a USB DAC or Bluetooth headphones and the status reads “系统原生播放”, the device does not report itself as headphones; switch to Force headphone spatial audio. Device identification rules are in the [user manual](docs/MANUAL.en.md#output-and-spatial-audio).

## Matching AirPods rendering on ordinary headphones

The two advanced settings correspond exactly to the two variables in the comparison:

| Setting | What it does | To match AirPods |
|---|---|---|
| **处理余量** (Processing headroom) | Sets the gain pair around loudness compression and limiting; main volume is controlled separately | Custom **20 dB** |
| **HRTF 模式** (HRTF mode) | Requests the generic HRTF or the system's existing personalised one, without changing global settings | Whatever AirPods actually use: **personalised** if you have created a personalised spatial audio profile in the system, generic otherwise |

Both start as “系统决定” (System decides), which leaves system behaviour alone. Settings are saved per actual output device, and “恢复此设备的系统设置” (Restore this device's system settings) resets both. When a personalised profile is not actually in effect, the panel says plainly that the generic HRTF is still in use. See the [user manual](docs/MANUAL.en.md#advanced-spatial-audio-settings).

The match ends at the output this process hands to the HAL. The roughly −12 dB digital attenuation AirPods apply after the HAL is outside this app's control, and the app does not compensate for it. Adding or removing 12 dB by hand is not recommended: the host transfer level alone does not determine the headphones' internal processing, volume or final sound pressure. See the [USB PCM comparison](Tests/USB_AUDIO_COMPARISON.md#结论边界与产品含义) (in Chinese).

## Output devices

| Output | In Automatic mode |
|---|---|
| Built-in 3.5 mm headphone jack | Identified as headphones; compatibility layer on |
| USB DAC, ordinary Bluetooth headphones | Compatibility layer on when the audio stream reports headphones; otherwise system native playback, and Force mode can be used |
| AirPods and other natively compatible devices | System native path with no spoofing; advanced settings available too |
| Built-in speakers, multichannel interfaces | System native playback |

Native capability is confirmed with unspoofed CoreAudio queries rather than inferred from Bluetooth / USB transport alone. When the output device disappears or becomes unavailable, playback pauses instead of suddenly switching to another output. Validated on this machine with the built-in 3.5 mm jack, a FIIO KA11 (USB) and AirPods Max; see the [validation record](Tests/VALIDATION.md) (in Chinese).

## FAQ

**Why doesn't Control Center show my headphones as AirPods / spatial audio?**
The compatibility layer only works inside this app's process and does not change how the system identifies the device. The mode in the interface is the app's playback policy.

**The EQ panel says “当前播放路径未应用 EQ” (EQ not applied on the current playback path)?**
In this first version, EQ only acts on the spatial rendering path. With spatialisation off, or when the content does not pass through the spatial renderer, it has no effect; its configuration and switch are kept.

**Head tracking does nothing?**
Check that “接收外部姿态” (Receive external pose) is on, that PoseBridge's `--osc-target` matches the panel's port (`127.0.0.1:9000` by default), that the source name matches `--source-id`, and that you are playing content with spatial audio on. With no new pose for more than 500 ms, the last orientation is held. Without a sensor you can troubleshoot with `posebridge simulate`; see the [user manual](docs/MANUAL.en.md#posebridge-head-tracking).

**APAC files report a format error with spatial audio off?**
On this machine, 16- and 24-channel APAC fails in native AVPlayer with `fmt?` when spatialisation is explicitly off. The app keeps the position and asks you to switch back to Automatic or Force mode; it does not silently ignore Off.

**Are settings and playlists saved?**
Yes. Playlists, the current track and position, volume, mode, output selection, per-device advanced settings, EQ and head-tracking settings are all saved. Only file references are stored; media files are not copied. See the [user manual](docs/MANUAL.en.md#saving-and-restoring).

## Known limits

- Relies on private implementation details: the compatibility layer uses `spen` / `spmd`, and head tracking uses the private AUSpatialMixer quaternion property `3102`. These need revalidating after system updates; the panel shows whether the renderer accepts poses.
- Plays only local formats supported by the system's AVFoundation.
- Multichannel APAC cannot play with spatialisation off; see the [FAQ](#faq).
- In this first version, EQ only acts on the spatial rendering path.
- No virtual driver is installed, and there is no separate PCM relay or background spatial renderer; the personalised HRTF profile comes from the system.
- The actual wearing orientation of an external sensor is handled by PoseBridge and needs checking yourself.
- The comparison results only cover the tested system version, devices and material; see [What it solves](#what-it-solves).

## Building from source

Requires Xcode 27 and XcodeGen 2.44.1 or later (`brew install xcodegen`). There are no third-party package dependencies.

Quit any running SpatialUnlock Player first, then run:

```sh
zsh build.sh
```

The script generates the Xcode project, builds Release and exports `SpatialUnlock Player.app` to the project root, checking signatures, entitlements and diagnostic entry points on export. `zsh build.sh --debug` exports a Debug build, and `zsh build.sh --diagnostics` exports a diagnostics build with regression test entry points.

To develop in Xcode:

```sh
xcodegen generate
open SpatialUnlockPlayer.xcodeproj
```

`project.yml` is the source of truth for the project, and the generated `.xcodeproj` is not committed. To change targets, build settings or schemes, edit the YAML and regenerate. Signing, dynamic library embedding, configuration differences and icon generation are covered in the [architecture notes](docs/ARCHITECTURE.md#构建产物) (in Chinese).

`zsh Scripts/ci.sh` runs the same checks and packaging as CI locally (it also needs the Python dependencies in `Tests/requirements-ci.txt`); see [continuous integration](Tests/README.md#持续集成) (in Chinese).

## Documentation

- [User manual](docs/MANUAL.en.md) ([简体中文](docs/MANUAL.md)): playlists, playback modes, saving and restoring, output identification, advanced settings, parametric EQ, PoseBridge head tracking

The following are in Chinese:

- [Architecture](docs/ARCHITECTURE.md): modules, render chain, build artifacts, diagnostics build
- [In-process comparison](Tests/ROUTE_COMPARISON.md): sample-by-sample spatial mixer / HAL comparison of AirPods and ordinary headphones, and locating the downstream gain
- [USB PCM comparison](Tests/USB_AUDIO_COMPARISON.md): USB payloads after the HAL, their formats and the roughly 12 dB level difference
- [Validation record](Tests/VALIDATION.md): scope and results of acceptance for each feature
- [Test guide](Tests/README.md): regression scripts, probes and reproduction commands
- [Continuous integration](Tests/README.md#持续集成): what GitHub Actions checks, the ad hoc app package and logs

## Related projects

| Project | Relationship |
|---|---|
| [PoseBridge](https://github.com/SakuzyPeng/PoseBridge) | Captures head-tracking sensors and sends OSC; this app is a receiver |
| [MacinDecode Spatial Player](https://github.com/SakuzyPeng/MacinDecode-Spatial-Player) | A player with its own AC-4 / APAC decoders and SAF binaural rendering that also runs on Windows; SpatialUnlock Player instead uses system decoding and Apple's renderer throughout |

## License

This project is licensed under the [MIT License](LICENSE). The Sony MDR-MV1 parametric EQ test data comes from [AutoEq](https://github.com/jaakkopasanen/AutoEq); for copyright, licence and provenance see the [third-party notices](THIRD_PARTY_NOTICES.md) and the [test data notes](Tests/Fixtures/README.md).
