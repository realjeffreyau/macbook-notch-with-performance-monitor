# Dynamic Notch for MacOS

Dynamic Notch is a native macOS utility that places a small interactive
surface over the MacBook camera notch. It combines AppKit window management
with SwiftUI content for media, system stats, privacy indicators, a File Shelf,
settings, and menu-bar recovery.

## Features

- Notch-aware AppKit panel with SwiftUI content and display-change handling.
- Media surface with a provider-agnostic session model, a best-effort system
  provider, and an optional Spotify adapter.
- Event-driven camera and microphone indicators without starting capture
  sessions or requesting capture permission.
- CPU, memory, battery, and output-device information from native macOS APIs.
- Bounded File Shelf for Finder file URLs, bookmarks, Quick Look, and Finder
  actions. File contents are never copied or uploaded.
- Native Settings window and a status-item recovery menu.
- Automated tests for geometry, state, lifecycle, media mapping, settings, and
  diagnostic redaction.

## Requirements

- macOS 14 or later
- Swift 6 and the Xcode Command Line Tools
- A notched MacBook for visual validation of the panel

The package has no third-party dependencies. On a Mac without credible notch
geometry, the accessory can run without ordering a visible panel.

## Build and test

Run these commands from the repository root:

``@@BT@sh
swift test
swift build
swift build -c release
``@@BT@

To run the accessory:

``@@BT@sh
swift run DynamicNotch
``@@BT@

The app runs as an accessory and provides a status-item menu for opening the
notch, settings, recovery, and quitting. The separate read-only diagnostic can
be run with:

``@@BT@sh
swift run DynamicNotchMediaDiagnostic
``@@BT@

Its exit codes are `0` for a session, `1` for an internal error, `2` for no
session, `3` for an unavailable provider, and `4` for a timeout. Its output is
redacted and it never sends a playback command.

## Optional Spotify support

Spotify support is disabled by default. The adapter uses Apple Events
only after an explicit launch switch and user approval in System Settings. It
does not use the Spotify Web API, OAuth, or a network request.

Because a raw SwiftPM executable has no stable application identity for
Automation permission, package the release executable into the supplied
bundle template:

``@@BT@sh
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
bundle_dir="$PWD/.build/DynamicNotch.app"
mkdir -p "$bundle_dir/Contents/MacOS"
cp "$bin_dir/DynamicNotch" "$bundle_dir/Contents/MacOS/DynamicNotch"
cp Packaging/DynamicNotch-Info.plist "$bundle_dir/Contents/Info.plist"
codesign --force --deep --sign - "$bundle_dir"
codesign --verify --deep --strict "$bundle_dir"
open "$bundle_dir" --args --enable-spotify-read
``@@BT@

Approve `Dynamic Notch → Spotify` under System Settings → Privacy & Security
→ Automation if macOS asks. Relaunch the same bundle after approval. The
separate `--enable-spotify-commands` switch exposes playback controls for a
manual experiment; no command is issued at startup or by tests.

The generic system provider dynamically loads a private MediaRemote framework
when its required symbols are present. It is best effort, unstable across
macOS releases, and not an App Store compatibility promise. The Spotify
adapter is Spotify-only and does not imply browser or system-wide support.

## Resource and privacy boundary

The collapsed surface is event-driven: it has no polling loop, display link,
network activity, or continuous animation driver. Media progress refreshes
only while expanded, and system statistics sample only while their page is
visible.

The File Shelf stores bounded display metadata and security-scoped bookmarks
when available. It does not read, copy, upload, or delete a user's files.
Privacy indicators observe device-use state without opening a camera,
microphone, or capture session. The media diagnostic reports only redacted
presence, lengths, and bounded status values.

## Project layout

``@@BT@text
Sources/DynamicNotch/                 AppKit shell and SwiftUI surfaces
Sources/DynamicNotchMedia/            Media providers and session model
Sources/MediaRemoteBridge/            Isolated Objective-C bridge
Sources/DynamicNotchMediaDiagnostic/  Read-only diagnostic executable
Tests/                                Unit and lifecycle tests
Packaging/                            Manual application-bundle template
RUNBOOK.md                            Build and validation guide
``@@BT@

## Manual validation

The automated suite does not replace hardware checks. Use the
[runbook](RUNBOOK.md) to validate notch geometry, media behavior, external
display changes, privacy indicators, File Shelf actions, Settings persistence,
fullscreen and Spaces behavior, and teardown on a notched MacBook.
