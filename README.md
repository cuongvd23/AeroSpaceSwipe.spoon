# AeroSpaceSwipe

Four-finger left/right swipes select the next/previous AeroSpace workspace on the
display under the pointer, wrapping once per gesture.

Copy the entire `.spoon` directory into `~/.hammerspoon/Spoons/`. Requires
Hammerspoon Accessibility permission and AeroSpace's `eval` command; tested with
Hammerspoon 1.1.1 and AeroSpace 0.21.3-Beta. Disable the native macOS four-finger
horizontal workspace gesture. Connected displays must have distinct names.

```lua
hs.loadSpoon("AeroSpaceSwipe")
spoon.AeroSpaceSwipe.focusFollowsMouse = true -- Optional monitor focus on pointer crossings.
local ok, err = spoon.AeroSpaceSwipe:start()
if not ok then hs.alert.show(err) end
```

## Settings

Set before starting; apply later changes with `:stop():start()`.

| Field | Default | Meaning |
| --- | --- | --- |
| `aerospacePath` | `nil` | Try `/opt/homebrew/bin/aerospace`, then `/usr/local/bin/aerospace`; override with an absolute executable path. |
| `threshold` | `0.01` | Average horizontal travel as a fraction of trackpad width. |
| `fingerThreshold` | `0.002` | Minimum horizontal contribution from each finger. |
| `horizontalRatio` | `1.5` | Required horizontal/vertical travel ratio. |
| `touchTimeout` | `0.5` | Seconds without touch updates before blocking expires. |
| `commandTimeout` | `1` | CLI timeout in seconds; expiry discards queued commands. |
| `focusFollowsMouse` | `false` | Focus monitors on pointer crossings, polled every 250 ms. |

Swipes always target the pointer's display. Movement accumulates across stationary
samples; resting palms do not qualify. Input blocking starts only after recognition.
Workspace ordering comes from AeroSpace. No native transition animation.

## API

- `init()` prepares the logger; Hammerspoon calls it when loading.
- `start()` activates listeners and configured hotkeys; returns `self` or `nil, error`.
- `stop()` stops listeners/timers, deletes hotkeys, and cancels pending commands.
- `focusMonitor(direction)` queues `left`, `right`, `up`, or `down`; requires a running Spoon.
- `bindHotkeys(mapping)` replaces monitor bindings; `{}` clears them.
- `status()` returns listener state, counters, command timings, and the last error.

Loading is inactive. Start/stop are idempotent. Hotkeys configured while stopped
activate on start. Use `logger:setLogLevel(...)` after initialization to change logging.

```lua
spoon.AeroSpaceSwipe:bindHotkeys({
    focusMonitorLeft  = { { "ctrl", "alt" }, "h" },
    focusMonitorDown  = { { "ctrl", "alt" }, "j" },
    focusMonitorUp    = { { "ctrl", "alt" }, "k" },
    focusMonitorRight = { { "ctrl", "alt" }, "l" },
})
```

No bindings are installed by default. Add `message = "..."` to a binding for an
alert. Keep fn/right-control-specific detection in your config and call `focusMonitor()`.

## Diagnostics and tests

```sh
hs -c 'return hs.inspect(spoon.AeroSpaceSwipe:status())'
nvim --headless -u NONE -i NONE -l /path/to/AeroSpaceSwipe.spoon/tests/run.lua
```

`recognized` counts accepted gestures; `switched` counts successful CLI commands,
including invisible single-workspace wraps. `recentCommandMs` holds the last 20
completed task durations, excluding queueing, recognition, and rendering. Counters
survive stop and reset on the next start. `lastError` includes startup failures.

The isolated tests use fake input, timers, and tasks. Check physical swipes on both
displays, after pointer crossings and sleep/wake, plus browser history, two-finger
scrolling with resting palms, and three-finger dragging.

API help is bundled in `docs.json`. Code and tests are MIT-licensed.
