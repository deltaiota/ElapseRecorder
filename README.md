# Elapse Recorder

A native macOS menu bar utility that periodically screenshots whitelisted apps while you work, so you can turn long, fragmented sessions — drawing, coding, 3D modeling — into a fast-forward **process timelapse** without ever manually starting or stopping a screen recording.

Elapse Recorder lives in the menu bar, watches for the apps you care about, and quietly captures their windows on a schedule. When you're done, browse what you captured and export it as a video.

## Features

- **Whitelist-driven capture** — Add specific applications to a whitelist; Elapse Recorder automatically begins capturing whenever one of them is running and stops when it quits. Already-running apps are picked up immediately.
- **Per-window screenshots** — On every tick it enumerates *all* capturable windows of the target app (via ScreenCaptureKit) and captures each one separately, skipping minimized, off-screen, or zero-size windows.
- **Sessions & stable window numbering** — Each continuous run of an app is one *session*. Windows get friendly, stable per-session numbers (Window 1, Window 2, …) so you can answer "what did I do last time I opened this app?"
- **Flexible scheduling** — Per-app capture intervals plus Auto and Manual capture modes, controlled from the menu bar.
- **Efficient storage** — Screenshots are saved as HEIC by default (PNG supported) to keep footprint small while staying clear, with queryable SwiftData metadata for sessions, windows, and screenshots.
- **Native viewer** — Browse by app → session → window, scan a per-window **timeline graph**, view a flat per-app gallery, and open frames in Quick Look.
- **Timelapse video export** — Export any selection of screenshots to **H.264 or HEVC** (`.mp4` / `.mov`) with an adjustable frame rate and optional **crossfade interpolation** between frames. The export panel shows a live estimate of the resulting video length.
- **Localized** — Available in English and Simplified Chinese (简体中文).

## Requirements

- macOS 15.7 or later
- **Screen Recording** permission (System Settings → Privacy & Security → Screen & System Audio Recording)

## Building

The Xcode project resolves all Swift Package Manager dependencies directly — there is no `Package.swift`.

```sh
# Build
xcodebuild build -project ElapseRecorder.xcodeproj -scheme ElapseRecorder \
  -destination 'platform=macOS,arch=arm64' \
  -skipMacroValidation -skipPackagePluginValidation

# Test
xcodebuild test -project ElapseRecorder.xcodeproj -scheme ElapseRecorder \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ElapseRecorderTests \
  -skipMacroValidation -skipPackagePluginValidation -quiet
```

Or just open `ElapseRecorder.xcodeproj` in Xcode and run.

## Architecture

Elapse Recorder is built with **SwiftUI** and **The Composable Architecture (TCA)**, with **SwiftData** for persistence. Live system APIs — ScreenCaptureKit, NSWorkspace events, the filesystem, AVFoundation encoding — are wrapped behind TCA dependency clients so features stay testable.

- `Domain/` — value types and capture/window-filtering rules
- `Dependencies/` — dependency clients and their live implementations
- `Persistence/` — SwiftData models and the persistence client
- `Features/` — TCA reducers
- `Views/` — SwiftUI views

Built with [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture), [Defaults](https://github.com/sindresorhus/Defaults), [TranslateKit](https://github.com/FlineDev/TranslateKit), [SFSafeSymbols](https://github.com/SFSafeSymbols/SFSafeSymbols), [LogOutLoud](https://github.com/Aeastr/LogOutLoud), and [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern).
