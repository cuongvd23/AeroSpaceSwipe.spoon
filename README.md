# AeroSpaceSwipe

Four-finger left/right swipes select the next/previous AeroSpace workspace on the
display under the pointer, wrapping once per gesture.
Lift all fingers before swiping again; continued movement or pauses while touching
the trackpad do not trigger another switch.

Requires Hammerspoon Accessibility permission and AeroSpace's `eval` command; tested with
Hammerspoon 1.1.1 and AeroSpace 0.21.3-Beta. Disable the native macOS four-finger
horizontal workspace gesture. Connected displays must have distinct names.

## Installation

Install [SpoonInstall](https://www.hammerspoon.org/Spoons/SpoonInstall.html) first,
then add this to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("SpoonInstall")
spoon.SpoonInstall.repos.aerospaceSwipe = {
    url = "https://github.com/cuongvd23/AeroSpaceSwipe.spoon",
    desc = "AeroSpaceSwipe",
    branch = "master",
}

spoon.SpoonInstall:andUse("AeroSpaceSwipe", {
    repo = "aerospaceSwipe",
    fn = function(s)
        local ok, err = s:start()
        if not ok then hs.alert.show(err) end
    end,
})
```

Reload Hammerspoon to activate. Add optional settings and bindings through `config`
and `hotkeys` in `andUse()`.

For manual installation, download [AeroSpaceSwipe.spoon.zip](https://github.com/cuongvd23/AeroSpaceSwipe.spoon/raw/master/Spoons/AeroSpaceSwipe.spoon.zip),
extract it, and copy the `AeroSpaceSwipe.spoon` folder into `~/.hammerspoon/Spoons/`. Add
`hs.loadSpoon("AeroSpaceSwipe"):start()` to your Hammerspoon configuration.

`andUse()` does not update installed Spoons. To update, reinstall the ZIP and reload
Hammerspoon.

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
| `windowFocusFollowsMouse` | `false` | Focus the window under the pointer within the focused workspace, checking at most every 100 ms while moving. |

Enable both options in your `andUse()` configuration for monitor and window focus:

```lua
config = {
    focusFollowsMouse = true,
    windowFocusFollowsMouse = true,
},
```

Keep AeroSpace's `focus-follows-mouse.enabled = false` when using these options.
Window hover pauses during swipes, scroll momentum, mouse-button presses, and
queued or active monitor/workspace commands. It only considers windows on the
focused workspace and never focuses through a covering window or dialog.
`windowFocusFollowsMouse` does not enable monitor crossings by itself.
Hover queries use `aerospacePath` and `commandTimeout`; failures appear in `errors`
and `lastError`. Sleep and stop cancel pending hover work; wake restores it.

Swipes always target the pointer's display. Movement accumulates across stationary
samples; resting palms do not qualify. Input blocking starts only after recognition.
Workspace ordering comes from AeroSpace. No native transition animation.
If an AeroSpace focus callback moves the pointer to another display during a
successful swipe, the Spoon restores its starting position on the swipe's display
before monitor-following resumes. Disconnected displays are never targeted.

## API

- `init()` prepares the logger; Hammerspoon calls it when loading.
- `start()` activates listeners and configured hotkeys; returns `self` or `nil, error`.
- `stop()` stops listeners/timers, deletes hotkeys, and cancels pending commands.
- `focusMonitor(direction)` queues `left`, `right`, `up`, or `down`; requires a running Spoon.
- `bindHotkeys(mapping)` replaces monitor bindings; `{}` clears them.
- `status()` returns listener state (including `hoverTapEnabled`), counters, command timings, and the last error.

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

## Local diagnostics and tests

```sh
hs -c 'return hs.inspect(spoon.AeroSpaceSwipe:status())'
lua5.4 tests/run.lua
```

Run the Lua suite locally from the source checkout before pushing runtime changes.
Neovim can run it if standalone Lua is unavailable:
`nvim --headless -u NONE -i NONE -l tests/run.lua`.

`recognized` counts accepted gestures; `switched` counts successful CLI commands,
including invisible single-workspace wraps. `recentCommandMs` holds the last 20
completed task durations, excluding queueing, recognition, and rendering. Counters
survive stop and reset on the next start. `lastError` includes startup failures.

The isolated tests use fake input, timers, and tasks. Check physical swipes on both
displays, after pointer crossings and sleep/wake, plus browser history, two-finger
scrolling with resting palms, and three-finger dragging.
With window hover enabled, also check continuous pointer movement between tiled
windows, workspace boundaries, and cancellation when a swipe begins.

Code and tests are MIT-licensed.
