# Dynamic Notch runbook

Run these commands from the repository root. The packaged application in the
README is the fastest way to try the project.

## Open the packaged app

1. Download and extract `DynamicNotch-macOS.app.zip`.
2. Open `DynamicNotch.app`.
3. If macOS blocks the first launch, use **Control-click → Open**.

The demo bundle is ad-hoc signed and is not notarized. A Mac with a camera
notch is required for visual validation; the app can still build on other
displays.

## Build and launch from source

```sh
swift test
swift build -c release
swift run DynamicNotch
```

The raw SwiftPM executable does not have a stable application identity for
Automation permissions. To create a local app bundle for optional Spotify
metadata access:

```sh
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
bundle_dir="$TMPDIR/DynamicNotch.app"
mkdir -p "$bundle_dir/Contents/MacOS"
cp "$bin_dir/DynamicNotch" "$bundle_dir/Contents/MacOS/DynamicNotch"
cp Packaging/DynamicNotch-Info.plist "$bundle_dir/Contents/Info.plist"
codesign --force --deep --sign - "$bundle_dir"
codesign --verify --deep --strict "$bundle_dir"
open "$bundle_dir" --args --enable-spotify-read
```

Spotify access is read-only and opt-in. Approve the Automation request only if
that integration is wanted. Playback commands require a separate explicit
switch and are never sent during startup or automated tests.

## File Shelf and screenshot copy

Open the expanded notch and choose **Files**. Local files dragged from Finder
are represented by bounded URL metadata and can be previewed with Quick Look,
revealed in Finder, dragged back out as URLs, or removed from the shelf.

Standard macOS screenshots are detected in the screenshot folder configured by
macOS. The watcher is event-driven and does not poll. A detected screenshot
gets a bounded thumbnail and a copy button. Select the copy button to write the
image to the macOS pasteboard, then paste it into another image-capable app
with **Command-V**. The full image is read only for that explicit action.

When the notch is expanded, press **Command-Shift-4** and select an area. The
click-away handler ignores Apple's Screenshot selection overlay. If the overlay
still causes a brief collapse, the detected screenshot restores the expanded
presentation; ordinary clicks in another window continue to collapse the
notch. The filesystem watcher delivers background events through safe relays,
so taking a screenshot should not terminate the app.

Unsupported text and web-URL drags are ignored. Clearing the shelf removes its
metadata only; it never deletes or moves the source files.

## Settings and recovery

The gear button opens native Settings. Changes apply immediately and persist
locally, including:

- notch enablement and motion behavior;
- media, output-device, artwork, and privacy indicators;
- System and File Shelf visibility;
- the bounded File Shelf item count;
- optional resource diagnostics; and
- the explicit startup preference, which is off by default.

Under **Recovery**, **Refresh & restart app** relaunches the packaged app with
its current launch arguments and resets transient observers and in-memory
artwork state. Preferences, File Shelf references, screenshot items, and the
media artwork cache are preserved. The action reports an error when the app is
running as a raw executable instead of a packaged application.

The menu-bar item remains available for opening the notch, opening Settings,
enabling or disabling the notch, and quitting. It is also the recovery path
when the notch is disabled.

## Resource check

The collapsed notch is designed to remain idle without a polling timer, display
link, network activity, or helper process. Media progress updates only while
expanded. System statistics sample only while the System page is visible.
File Shelf monitoring uses filesystem events, and thumbnails are bounded.

For a quick local observation after launching:

```sh
pid="$(pgrep -x DynamicNotch | head -1)"
ps -p "$pid" -o pid=,etime=,%cpu=,%mem=,rss=,state=,command=
```

This is an observation aid, not a performance guarantee across hardware or
macOS releases.

## Automated verification

```sh
swift test
swift build -c release
```

The separate diagnostic is read-only and bounded:

```sh
swift run DynamicNotchMediaDiagnostic
```

Its exit codes are:

- `0` — session found
- `1` — internal error
- `2` — no session
- `3` — provider unavailable
- `4` — timeout

The diagnostic does not issue playback commands or print raw media metadata.
