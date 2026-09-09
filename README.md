# Dynamic Notch for macOS

[![CI](https://github.com/realjeffreyau/macbook-notch-with-performance-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/realjeffreyau/macbook-notch-with-performance-monitor/actions/workflows/ci.yml)

A native macOS utility that turns the camera notch into a compact, expandable
surface for media, system status, privacy indicators, and a local File Shelf.

## Download

[Download Dynamic Notch for macOS](https://github.com/realjeffreyau/macbook-notch-with-performance-monitor/raw/refs/heads/main/downloads/DynamicNotch-macOS.app.zip)

The archive contains `DynamicNotch.app`. Extract it and open the app. This
demo build is ad-hoc signed rather than notarized, so macOS may require
**Control-click → Open** on first launch.

## Features

- Notch-aware AppKit window with SwiftUI content and display-change handling.
- Media surface with inferred progress and capability-gated controls.
- Optional local Spotify metadata support through explicit Apple Events access.
- CPU, memory, battery, output-device, and bounded energy-use information.
- Camera and microphone activity indicators without opening capture sessions.
- File Shelf for local file references, Quick Look, Finder reveal, URL-only
  drag-out, and bounded persistence.
- Automatic detection of standard macOS screenshots in the configured
  screenshot folder, with small thumbnails and an explicit copy-to-pasteboard
  action for pasting the image into another app.
- Native Settings and menu-bar recovery controls, including an opt-in startup
  preference that is off by default.
- Reduced-motion support and no third-party runtime dependencies.

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

Dynamic Notch is local-first. The core utility does not upload files or use a
cloud service. File Shelf stores bounded URL metadata and security-scoped
bookmarks when available; it does not copy, delete, or upload file contents.
Screenshot thumbnails are bounded, and the full image is read only after an
explicit copy action. Privacy indicators observe device-use state without
opening a camera, microphone, or capture session.

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
Sources/MediaRemoteBridge/            Isolated Objective-C media bridge
Sources/DynamicNotchMediaDiagnostic/  Read-only diagnostic executable
Tests/                                Unit and lifecycle tests
Packaging/                            Application-bundle template
RUNBOOK.md                            Build and validation guide
```

## Validation

The automated suite does not replace hardware checks. Use the
[runbook](RUNBOOK.md) to validate notch geometry, media behavior, screenshot
discovery and copy, privacy indicators, File Shelf actions, Settings
persistence, reduced motion, and menu-bar recovery.
