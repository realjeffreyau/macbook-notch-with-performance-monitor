# Dynamic Notch for macOS

[![CI](https://github.com/realjeffreyau/macbook-notch-with-performance-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/realjeffreyau/macbook-notch-with-performance-monitor/actions/workflows/ci.yml)

A native macOS utility with an expandable notch panel for media, local files,
system status, and Keep Awake.

![Dynamic Notch media view with example artwork, playback progress and controls](docs/images/overview.png)

*Native app views rendered with example media and file names.*

## Download

[Download Dynamic Notch for macOS](https://raw.githubusercontent.com/realjeffreyau/macbook-notch-with-performance-monitor/2bfbd2ff65fd7ecd1d1c79c245dc7dc36a94cf93/downloads/DynamicNotch-macOS.app.zip)

The archive contains `DynamicNotch.app`. Extract it and open the app. This
demo build is ad-hoc signed rather than notarized, so macOS may require
**Control-click → Open** on first launch.

## Latest updates

- Timed Keep Awake sessions are available from the notch and menu bar, with
  optional display-sleep and low-battery controls.
- Optional closed-lid Keep Awake is off by default and AC-only unless battery
  use is enabled. Support varies by Mac and macOS version; helper-backed power
  changes require a developer-signed app and explicit macOS approval.
- The Mirror page shows a live camera preview only while open. It does not use
  the microphone or save media.

## Features

- Media metadata, artwork, playback progress, and supported controls.
- A local File Shelf with drag and drop, Quick Look, and Finder reveal.
- Screenshot detection and an explicit copy action for pasting into another app.
- CPU, memory, battery, output-device information, and an energy-use estimate.
- Timed Keep Awake from the notch and menu bar, with display-sleep and
  low-battery options.
- Camera and microphone activity indicators, plus an optional live Mirror page.
- Native Settings, menu-bar recovery, reduced motion, and opt-in start at login.

![Native File Shelf and Keep Awake views showing example files, session presets and optional controls](docs/images/features.png)

## Build from source

Requirements:

- macOS 14 or later
- Swift 6 and the Xcode Command Line Tools
- A Mac with a camera notch for visual validation

Run these commands from the repository root:

```sh
swift test
swift build -c release
swift run DynamicNotch
```

The packaged app above is the quickest way to try the UI. The SwiftPM command
runs the raw executable and is intended for local development.

## Privacy and resource behavior

Dynamic Notch is local first. The core utility does not upload files or use a
cloud service. File Shelf stores bounded URL metadata and security-scoped
bookmarks when available; it does not copy, delete, or upload file contents.
Screenshot thumbnails are bounded, and the full image is read only after an
explicit copy action. Privacy indicators observe device-use state without
opening a capture session. The optional Mirror page requests camera access for
its live preview only while open; it does not capture audio or save media.

The collapsed surface is event-driven: it has no polling timer, display link,
or continuous animation driver. Media progress refreshes only while expanded,
system statistics sample only while their page is visible, and screenshot
discovery uses a filesystem event source rather than polling.

The generic system-media integration uses a private macOS framework on a
best-effort basis and may vary across macOS releases. Spotify support is
disabled by default and requires explicit local Automation approval. These
integrations are not App Store compatibility guarantees.

## Project layout

```text
Sources/DynamicNotch/                 AppKit shell and SwiftUI surfaces
Sources/DynamicNotchMedia/            Media providers and session model
Sources/DynamicNotchEnergyHelper/     Optional power-settings helper
Sources/MediaRemoteBridge/            Isolated Objective-C media bridge
Sources/PowerNotificationBridge/      Power-state event bridge
Sources/DynamicNotchMediaDiagnostic/  Read-only diagnostic executable
Tests/                                Unit and lifecycle tests
Packaging/                            Application-bundle templates
RUNBOOK.md                            Build and validation guide
```

## Validation

The automated suite does not replace hardware checks. Use the
[runbook](RUNBOOK.md) to validate notch geometry, media behavior, screenshot
discovery and copy, screenshot-overlay behavior, privacy indicators, File Shelf
actions, Keep Awake, Mirror, Settings persistence and recovery, reduced motion,
and menu-bar recovery.
