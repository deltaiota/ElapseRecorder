# Elapse Recorder

A native macOS menu bar utility that periodically screenshots whitelisted apps while you work, so you can turn long, fragmented sessions — drawing, coding, 3D modeling — into a fast-forward **process timelapse** without ever manually starting or stopping a screen recording.

Elapse Recorder lives in the menu bar, watches for the apps you care about, and quietly captures their windows on a schedule. When you're done, browse what you captured and export it as a video.

## Features

- **Whitelist-driven capture** — Add specific applications to a whitelist; Elapse Recorder automatically begins capturing whenever one of them is running and stops when it quits. Already-running apps are picked up immediately.
- **Per-window screenshots** — On every tick it enumerates *all* capturable windows of the target app (via ScreenCaptureKit) and captures each one separately, skipping minimized, off-screen, or zero-size windows.
- **Sessions & stable window numbering** — Each continuous run of an app is one *session*. Windows get friendly, stable per-session numbers (Window 1, Window 2, …) so you can answer "what did I do last time I opened this app?"
- **Flexible scheduling** — Per-app capture intervals plus Auto and Manual capture modes, controlled from the menu bar.
- **Durable, efficient storage** — Captures enter a crash-recoverable HEIC/PNG spool, then HEIC frames are automatically sealed into verified HEVC segments. Metadata lives in indexed GRDB/SQLite; upgrades import the previous SwiftData library once.
- **Native viewer** — Browse by app → session → window, scan a per-window **timeline graph**, view a flat per-app gallery, and open standalone or video-backed frames in Quick Look.
- **Timelapse video export** — Stream any selection of standalone or segment-backed frames to **H.264 or HEVC** (`.mp4` / `.mov`) at source resolution, with adjustable frame rate and optional crossfade interpolation. The export panel shows a live duration estimate.
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

Elapse Recorder is built with **SwiftUI** and **The Composable Architecture (TCA)**. The backend uses **GRDB/SQLite** for indexed metadata, a durable image spool, and verified AVFoundation HEVC segments. Live system APIs — ScreenCaptureKit, NSWorkspace events, the filesystem, and media encoding — stay behind dependency clients.

- `Backend/` — recording service, monotonic scheduler, GRDB database, storage coordinator, recovery, maintenance, and streaming library
- `Domain/` — value types and capture/window-filtering rules
- `Dependencies/` — TCA dependency clients and live system implementations
- `Persistence/` — GRDB persistence operations and database models
- `Features/` — TCA reducers
- `Views/` — SwiftUI views

Built with [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture), [Defaults](https://github.com/sindresorhus/Defaults), [TranslateKit](https://github.com/FlineDev/TranslateKit), [SFSafeSymbols](https://github.com/SFSafeSymbols/SFSafeSymbols), [LogOutLoud](https://github.com/Aeastr/LogOutLoud), and [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern).
