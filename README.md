# Dynamic Notch for macOS

[![CI](https://github.com/realjeffreyau/macbook-notch-with-performance-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/realjeffreyau/macbook-notch-with-performance-monitor/actions/workflows/ci.yml)

A native macOS utility that turns a MacBook camera notch into a compact,
expandable surface for media, system performance, privacy indicators, and file
actions.

## Highlights

- Notch-aware AppKit panel with SwiftUI content and display-change handling.
- Provider-agnostic media surface with inferred progress and capability-gated
  transport controls.
- Optional Spotify read support through explicit Apple Events opt-in.
- System page with CPU, memory, battery, output-device, and bounded energy-use
  information.
- Camera and microphone activity indicators without opening capture sessions.
- File Shelf for bounded Finder URLs, Quick Look, Finder reveal, and URL-only
  drag-out.
- Native Settings window, reduced-motion support, and menu-bar recovery
  controls.
- No third-party package dependencies.

## Download

The supported download is the source tree:

[Download the latest source ZIP](https://github.com/realjeffreyau/macbook-notch-with-performance-monitor/archive/refs/heads/main.zip)

- Choose **Code → Download ZIP** on GitHub, or clone the repository:

  ```sh
  git clone https://github.com/realjeffreyau/macbook-notch-with-performance-monitor.git
  cd macbook-notch-with-performance-monitor
  ```

- Build the release executable:

  ```sh
  swift build -c release
  ```

There is no signed prebuilt application attached yet. A source build is
required. A notched MacBook is needed for visual validation; on other displays,
the utility can run without ordering a visible notch panel.

## Requirements

- macOS 14 or later
- Swift 6 and the Xcode Command Line Tools
- A notched MacBook for visual validation

Run the test suite and launch the accessory with:

```sh
swift test
swift run DynamicNotch
```

The separate media diagnostic is read-only and has bounded runtime behavior:

```sh
swift run DynamicNotchMediaDiagnostic
```

Its exit codes are `0` for a session, `1` for an internal error, `2` for no
session, `3` for an unavailable provider, and `4` for a timeout. Output is
redacted and no playback command is sent.

## Optional Spotify support

Spotify support is disabled by default. The adapter reads Spotify through its
local Apple Events interface only after `--enable-spotify-read` is explicitly
enabled. It does not use the Spotify Web API, OAuth, or a network request.

Because a raw SwiftPM executable has no stable Automation identity, package the
release executable into an application bundle before enabling the read path:

```sh
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
bundle_dir="$PWD/.build/DynamicNotch.app"
mkdir -p "$bundle_dir/Contents/MacOS"
cp "$bin_dir/DynamicNotch" "$bundle_dir/Contents/MacOS/DynamicNotch"
cp Packaging/DynamicNotch-Info.plist "$bundle_dir/Contents/Info.plist"
codesign --force --deep --sign - "$bundle_dir"
open "$bundle_dir" --args --enable-spotify-read
```

Approve the Automation request for Spotify in System Settings if macOS asks.
The separate `--enable-spotify-commands` switch is required for a manual
controls experiment; no playback command is sent during launch or automated
tests.

The generic system-media provider dynamically loads a private
`MediaRemote.framework` when its required symbols are present. It is
best-effort, may vary across macOS releases, and is not an App Store
compatibility promise.

## Privacy and resource boundaries

The collapsed surface is event-driven: it has no polling timer, display link,
network activity, or continuous animation driver. Media progress refreshes
only while expanded, and system statistics sample only while their page is
visible.

File Shelf stores bounded display metadata and security-scoped bookmarks when
available. It never reads, copies, uploads, or deletes file contents. Privacy
indicators observe device-use state without opening a camera, microphone, or
capture session.

## Project layout

```text
Sources/DynamicNotch/                 AppKit shell and SwiftUI surfaces
Sources/DynamicNotchMedia/            Media providers and session model
Sources/MediaRemoteBridge/            Isolated Objective-C bridge
Sources/DynamicNotchMediaDiagnostic/  Read-only diagnostic executable
Tests/                                Unit and lifecycle tests
Packaging/                            Application-bundle template
RUNBOOK.md                            Build and validation guide
```

## Validation

The automated suite does not replace hardware checks. Use the
[runbook](RUNBOOK.md) to validate notch geometry, media behavior, display
changes, privacy indicators, File Shelf actions, Settings persistence, reduced
motion, and menu-bar recovery.
