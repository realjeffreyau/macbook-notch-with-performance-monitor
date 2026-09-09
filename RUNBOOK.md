# Dynamic Notch runbook

Run commands from the repository root.

## Build and run

Run the accessory without Spotify integration:

```sh
swift run DynamicNotch
```

Run the isolated, read-only media diagnostic:

```sh
swift run DynamicNotchMediaDiagnostic
```

Its exit codes are:

- `0` — session found
- `1` — internal error
- `2` — no session
- `3` — provider unavailable
- `4` — timeout

The diagnostic reports bounded, redacted metadata and never sends a playback
command.

## Optional Spotify read path

Package the executable before enabling Spotify. A raw SwiftPM executable is
deliberately rejected for this path because it has no stable Automation identity.

```sh
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
bundle_dir="$PWD/.build/DynamicNotch.app"
mkdir -p "$bundle_dir/Contents/MacOS"
cp "$bin_dir/DynamicNotch" "$bundle_dir/Contents/MacOS/DynamicNotch"
cp Packaging/DynamicNotch-Info.plist "$bundle_dir/Contents/Info.plist"
codesign --force --deep --sign - "$bundle_dir"
codesign --verify --deep --strict "$bundle_dir"
open "$bundle_dir" --args --enable-spotify-read
```

Approve the Automation request for Spotify in System Settings if macOS asks.
Relaunch the same bundle after approval. Add
`--enable-spotify-commands` only for an explicit manual controls test:

```sh
open "$PWD/.build/DynamicNotch.app" \
  --args --enable-spotify-read --enable-spotify-commands
```

Spotify support is disabled by default. It does not use OAuth, the Spotify Web
API, or a network request.

## Menu-bar and page checks

The status-item menu should remain available when the notch is disabled:

- **Open / Expand Notch** opens the panel when enabled.
- **Settings…** opens the native settings window.
- **Enable / Disable Dynamic Notch** applies immediately.
- **Quit Dynamic Notch** stops the accessory.

When expanded, check:

- **Media** shows the selected session, inferred progress, and only advertised
  controls. Progress refreshes only while this page is visible.
- **System** shows CPU, memory, battery, output device, and the bounded energy-use
  estimate while the page is visible. The estimate is not a watt measurement.
- **Files** accepts Finder file URLs and retains only bounded URL/display
  metadata plus a security-scoped bookmark when available.
- **Settings** applies preferences immediately and preserves them after relaunch.

The media, System, and Files pages share the same content inset. Switching pages
should not visibly jump the card. The Reduce Motion preference should use a
short finite transition without changing the panel's final geometry.

File Shelf actions delegate Quick Look and Finder reveal to macOS after an
explicit user action. Removing or clearing a row removes only its shelf
metadata; it never deletes the source file.

## Privacy-indicator check

With Dynamic Notch running, start and stop a trusted camera or microphone call
in another application. Confirm the corresponding indicator appears and
disappears. Dynamic Notch should not request camera or microphone access or
start a capture session.

## Resource check

With the notch collapsed, use Activity Monitor or these advisory commands:

```sh
pid="$(pgrep -x DynamicNotch | head -1)"
ps -p "$pid" -o pid=,etime=,%cpu=,%mem=,rss=,state=,command=
vmmap -summary "$pid" | rg "Physical footprint|CoreAnimation|IOAccelerator"
```

The collapsed surface is event-driven. It has no polling timer, display link,
network activity, or continuous animation driver. System sampling stops when
the System page is hidden.

## Verify the build

```sh
swift test
swift build
swift build -c release
```

For the full visual check, use a notched MacBook display and validate:

- notch alignment and resize behavior;
- media transitions, progress, and transport controls;
- external-display changes;
- privacy indicators;
- File Shelf drag-in, Quick Look, Finder reveal, drag-out, remove, and clear;
- Settings persistence and Reduce Motion;
- menu-bar enable/disable recovery;
- fullscreen, Spaces, and teardown behavior.

## Restart and stop

Stop the exact executable before replacing a packaged build:

```sh
for pid in $(pgrep -x DynamicNotch 2>/dev/null); do
  kill "$pid"
done
```

Then rebuild and repeat the packaging commands above. To confirm it is stopped:

```sh
pgrep -x DynamicNotch
```

No output means the process is stopped.

## Troubleshooting

### No visible notch

The panel is ordered only on a display whose `NSScreen` geometry indicates a
credible physical notch. Confirm the notched display is active and that
Dynamic Notch is enabled in the status-item menu.

### The media card says `No media playing`

For Spotify, confirm the packaged bundle was launched with
`--enable-spotify-read`, Automation access is allowed, Spotify is playing, and
the bundle was relaunched after permission was granted. The generic
`MediaRemote.framework` provider is best-effort and may return no session on a
given macOS release.

### A rebuilt app still shows old behavior

Stop the running process, rebuild, replace the executable inside
`.build/DynamicNotch.app`, and reopen the bundle.

### A File Shelf drag is rejected

Drag a file directly from Finder. Unsupported pasteboard providers, text, and
web URLs are intentionally ignored. Stale or deleted references should be
removed and added again.

### Dynamic Notch was disabled

Use the status-item menu to choose **Enable Dynamic Notch**. If the menu is not
visible, use:

```sh
defaults write com.dynamicnotch.app notch.enabled -bool true
```
