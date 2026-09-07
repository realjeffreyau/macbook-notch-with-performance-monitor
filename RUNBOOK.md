# Dynamic Notch runbook

Run these commands from the repository root.

## Build and run

Run the normal accessory without Spotify integration:

``@@BT@sh
swift run DynamicNotch
``@@BT@

For the optional Spotify read path, build and package the executable first:

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
→ Automation when macOS asks. Relaunch the same bundle after approval. Add
`--enable-spotify-commands` only for a manual controls test:

``@@BT@sh
open "$PWD/.build/DynamicNotch.app" \
  --args --enable-spotify-read --enable-spotify-commands
``@@BT@

The raw `swift run` executable deliberately rejects the Spotify switch because
it has no stable application-bundle identity or Automation usage description.
Spotify access is opt-in; it does not use OAuth, the Spotify Web API,
or a network request.

## Menu-bar and page checks

The status-item menu remains available when the notch is disabled. Check:

- `Open / Expand Notch` opens the panel when enabled.
- `Settings…` opens the native settings window.
- The enable/disable item applies the preference immediately.
- `Quit Dynamic Notch` stops the accessory process.

In the expanded surface:

- Media shows the selected session, inferred progress, and only advertised
  controls.
- System shows native CPU, memory, and battery values while that page is
  visible.
- Files accepts Finder file drags and keeps only bounded URL/display metadata
  plus a security-scoped bookmark when available.
- Settings changes apply immediately and persist through relaunch.

The File Shelf never copies, uploads, moves, or deletes the source file. Quick
Look and Finder reveal are delegated to macOS after an explicit user action.

## Privacy-indicator check

With Dynamic Notch running, start and stop a trusted camera or microphone call
in another application. Confirm the corresponding indicator appears and
disappears. Dynamic Notch should not request camera or microphone access or
start a capture session.

## Resource check

With the notch collapsed and the app running, use Activity Monitor or these
advisory commands to inspect idle behavior:

``@@BT@sh
pid="$(pgrep -x DynamicNotch | head -1)"
ps -p "$pid" -o pid=,etime=,%cpu=,%mem=,rss=,state=,command=
vmmap -summary "$pid" | rg "Physical footprint|CoreAnimation|IOAccelerator"
``@@BT@

The collapsed surface is event-driven. It has no polling timer, display link,
network activity, or continuous animation driver. Media progress refreshes
only while expanded; System samples only while visible.

## Verify the build

``@@BT@sh
swift test
swift test --filter Spotify
swift build
swift build -c release
``@@BT@

The isolated generic-media diagnostic is bounded and redacts user media
metadata:

``@@BT@sh
swift run DynamicNotchMediaDiagnostic
``@@BT@

Exit codes are `0` session found, `1` internal error, `2` no session, `3`
provider unavailable, and `4` timeout. A no-session result from the private
generic provider does not disprove the separate Spotify adapter. The
diagnostic never sends a playback command.

## Restart and stop

After source changes, replace the packaged executable before reopening it:

``@@BT@sh
for pid in $(pgrep -x DynamicNotch 2>/dev/null); do
  kill "$pid"
done
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

To stop only the exact executable:

``@@BT@sh
for pid in $(pgrep -x DynamicNotch 2>/dev/null); do
  kill "$pid"
done
``@@BT@

No output from this check means the process is stopped:

``@@BT@sh
for pid in $(pgrep -x DynamicNotch 2>/dev/null); do
  ps -p "$pid" -o pid=,etime=,command=
done
``@@BT@

## Troubleshooting

### No visible notch

Use a notched MacBook display. The panel is not ordered on displays whose
geometry does not expose a credible physical notch. If the notch was disabled
in Settings, use the status-item menu to enable it again.

### The media card says `No media playing`

For Spotify, confirm the app is playing, the packaged bundle was launched with
`--enable-spotify-read`, Automation access is allowed, and the bundle was
relaunched after permission was granted.

### A rebuilt app still shows old behavior

Stop the running process, rebuild, replace the executable inside
`.build/DynamicNotch.app`, and reopen the bundle. Opening an existing app bundle
without copying the new executable runs the old build.

### A File Shelf drag is rejected

Drag a file directly from Finder. Text, web URLs, and unsupported
pasteboard providers are intentionally ignored. Stale or deleted file
references should be removed and dragged in again.

### Private media diagnostic returns no session

The generic MediaRemote provider is a best-effort private-framework
integration. It may be unavailable or return no session on a given macOS
release. This result is not a failure of the Spotify adapter.
