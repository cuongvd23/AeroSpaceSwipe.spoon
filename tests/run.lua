-- Run with: nvim --headless -u NONE -i NONE -l /path/to/AeroSpaceSwipe.spoon/tests/run.lua
local testPath = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
local spoonPath = testPath .. "../"
local swipe = dofile(spoonPath .. "init.lua")._controllerModule
local passed = 0
local function equal(actual, expected, message)
	assert(
		actual == expected,
		(message or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)
	)
end
local function test(name, body)
	local ok, err = pcall(body)
	assert(ok, name .. ": " .. tostring(err))
	passed = passed + 1
	print("ok " .. passed .. " - " .. name)
end
local function frame(x, y, ids, phase)
	local touches = {}
	for i, id in ipairs(ids or { 1, 2, 3, 4 }) do
		touches[i] = {
			identity = id,
			type = "indirect",
			phase = phase or "moved",
			touching = phase ~= "ended" and phase ~= "cancelled",
			normalizedPosition = { x = type(x) == "table" and x[i] or x, y = y or 0.5 },
		}
	end
	return touches
end
local function recognizer()
	local r = swipe.newRecognizer()
	r:update(frame(0.5))
	return r
end

test("short flick counts its first movement", function()
	equal(recognizer():update(frame(0.48)), "left")
	equal(recognizer():update(frame(0.52)), "right")
end)
test("small movement accumulates from initial contact positions", function()
	local r = recognizer()
	equal(r:update(frame(0.496)), nil)
	equal(r:update(frame(0.493)), nil)
	equal(r:update(frame(0.489)), "left")
end)
test("a temporarily stationary finger retains its movement", function()
	local r = recognizer()
	r:update(frame(0.496))
	local touches = frame({ 0.48, 0.48, 0.48, 0.496 })
	touches[4].phase = "stationary"
	equal(r:update(touches), "left")
end)
test("two moving fingers and two resting palm contacts never arm", function()
	local r = recognizer()
	equal(r:update(frame({ 0.4, 0.4, 0.5, 0.5 })), nil)
end)
test("three-finger movement is not a workspace swipe", function()
	local r = swipe.newRecognizer()
	r:update(frame(0.5, nil, { 1, 2, 3 }))
	equal(r:update(frame(0.3, nil, { 1, 2, 3 })), nil)
end)
test("vertical motion does not consume later horizontal motion", function()
	local r = recognizer()
	equal(r:update(frame(0.5, 0.52)), nil)
	equal(r:update(frame(0.46, 0.52)), "left")
end)
test("diagonal motion must be predominantly horizontal", function()
	local r = recognizer()
	equal(r:update(frame(0.48, 0.48)), nil)
	equal(r:update(frame(0.46, 0.48)), "left")
end)
test("opposing finger movement is rejected", function()
	equal(recognizer():update(frame({ 0.45, 0.45, 0.45, 0.51 })), nil)
end)
test("replacement touch identities rebase and recover", function()
	local r = recognizer()
	equal(r:update(frame(0.48, nil, { 1, 2, 3, 5 })), nil)
	equal(r:update(frame(0.46, nil, { 1, 2, 3, 5 })), "left")
end)
test("staggered landing and a temporary extra contact rebase", function()
	local r = swipe.newRecognizer()
	r:update(frame(0.6, nil, { 1, 2, 3 }))
	r:update(frame(0.5))
	r:update(frame(0.49, nil, { 1, 2, 3, 4, 5 }))
	equal(r:update(frame(0.48)), nil)
	equal(r:update(frame(0.46)), "left")
end)
test("ended and touchbar contacts are excluded", function()
	local r = recognizer()
	local touches = frame(0.48)
	touches[5] = frame(0.8, nil, { 5 }, "ended")[1]
	touches[6] = { type = "direct", touching = true, identity = 6 }
	equal(r:update(touches), "left")
end)
test("continued movement, reversal and staggered lift fire only once", function()
	local r = recognizer()
	equal(r:update(frame(0.48)), "left")
	equal(r:update(frame(0.4)), nil)
	equal(r:update(frame(0.6)), nil)
	r:update(frame(0.6, nil, { 1, 2, 3 }))
	equal(r:update(frame(0.7)), nil)
	r:update({})
	r:update(frame(0.5))
	equal(r:update(frame(0.52)), "right")
end)
test("new identities cannot rearm a swipe before full release", function()
	local r = recognizer()
	equal(r:update(frame(0.48)), "left")
	local direction, released = r:update(frame(0.5, nil, { 5, 6, 7, 8 }))
	equal(direction, nil)
	equal(released, false)
	equal(r:update(frame(0.52, nil, { 5, 6, 7, 8 })), nil)
	direction, released = r:update(frame(0.52, nil, { 5, 6, 7, 8 }, "ended"))
	equal(direction, nil)
	equal(released, true)
	r:update(frame(0.5, nil, { 5, 6, 7, 8 }))
	equal(r:update(frame(0.52, nil, { 5, 6, 7, 8 })), "right")
end)
test("began phases cannot rearm a swipe before full release", function()
	local r = recognizer()
	equal(r:update(frame(0.48)), "left")
	local direction, released = r:update(frame(0.5, nil, nil, "began"))
	equal(direction, nil)
	equal(released, false)
	equal(r:update(frame(0.52)), nil)
	r:update({})
	r:update(frame(0.5, nil, nil, "began"))
	equal(r:update(frame(0.52)), "right")
end)
test("cancellation suppresses remaining contacts until release", function()
	local r = recognizer()
	local touches = frame(0.48)
	touches[4].phase, touches[4].touching = "cancelled", false
	local direction, released = r:update(touches)
	equal(direction, nil)
	equal(released, true)
	equal(r:update(frame(0.4)), nil)
	r:update(frame(0.5, nil, { 5, 6, 7, 8 }, "began"))
	equal(r:update(frame(0.4, nil, { 5, 6, 7, 8 })), nil)
	r:update({})
	r:update(frame(0.5))
	equal(r:update(frame(0.48)), "left")
end)
test("nil touches are harmless and inactivity cannot duplicate a held gesture", function()
	local r = recognizer()
	equal(r:update(nil), nil)
	equal(r:update(frame(0.48)), "left")
	equal(r:update(nil), nil)
	r:expire()
	equal(r:update(frame(0.4)), nil)
end)

-- Fake runtime: no real input interception, timers, or AeroSpace commands.
local function fixture(noStart)
	local f = { time = 0, tasks = {}, timers = {}, taps = {}, failStart = false, failNew = false }
	f.screenA = {
		name = function()
			return "Built-in Retina Display"
		end,
	}
	f.screenB = {
		name = function()
			return "LG HDR 4K"
		end,
	}
	f.screen = f.screenA
	local function timer(delay, callback, repeats)
		local t = { delay = delay, callback = callback, repeats = repeats }
		function t:start()
			self.due = f.time + self.delay
			return self
		end
		function t:setNextTrigger(seconds)
			self.due = f.time + seconds
			return self
		end
		function t:stop()
			self.due = nil
			return self
		end
		f.timers[#f.timers + 1] = t
		return t
	end
	local types = { gesture = 29, scrollWheel = 22, mouseMoved = 5, leftMouseDragged = 6 }
	local props =
		{ scrollWheelEventMomentumPhase = 1, scrollWheelEventScrollPhase = 2, scrollWheelEventIsContinuous = 3 }
	local runtime = {
		timer = {
			absoluteTime = function()
				return f.time * 1e9
			end,
			delayed = {
				new = function(delay, callback)
					return timer(delay, callback, false)
				end,
			},
			new = function(delay, callback)
				return timer(delay, callback, true)
			end,
		},
		mouse = {
			getCurrentScreen = function()
				return f.screen
			end,
		},
		logger = {
			new = function()
				return { w = function() end }
			end,
		},
		eventtap = {
			event = { types = types, properties = props },
			new = function(events, callback)
				local tap = { callback = callback, enabled = false }
				function tap:start()
					self.enabled = true
					return self
				end
				function tap:stop()
					self.enabled = false
					return self
				end
				function tap:isEnabled()
					return self.enabled
				end
				for _, event in ipairs(events) do
					f.taps[event] = tap
				end
				return tap
			end,
		},
		task = {
			new = function(_, callback, args)
				if f.failNew then
					return nil
				end
				local task = { callback = callback, args = args }
				function task:start()
					f.tasks[#f.tasks + 1] = self
					return not f.failStart and self or false
				end
				function task:terminate()
					self.terminated = true
				end
				return task
			end,
		},
		caffeinate = {
			watcher = {
				systemWillSleep = 1,
				screensDidSleep = 2,
				screensDidLock = 3,
				systemDidWake = 4,
				screensDidWake = 5,
				screensDidUnlock = 6,
				new = function(callback)
					f.wake = callback
					return { start = function() end, stop = function() end }
				end,
			},
		},
	}
	function f:advance(seconds)
		local target = self.time + seconds
		for _ = 1, 1000 do
			local nextTimer
			for _, t in ipairs(self.timers) do
				if t.due and t.due <= target and (not nextTimer or t.due < nextTimer.due) then
					nextTimer = t
				end
			end
			if not nextTimer then
				self.time = target
				return
			end
			self.time = nextTimer.due
			nextTimer.due = nextTimer.repeats and self.time + nextTimer.delay or nil
			nextTimer.callback()
		end
		error("timer loop")
	end
	function f:touch(touches)
		return self.taps[types.gesture].callback({
			getType = function()
				return types.gesture
			end,
			getTouches = function()
				return touches
			end,
		})
	end
	function f:swipe(x)
		self:touch({})
		self:touch(frame(0.5))
		self:touch(frame(x or 0.48))
	end
	function f:scroll(momentum, phase, continuous)
		local values = { momentum, phase, continuous == nil and 1 or continuous }
		return self.taps[types.scrollWheel].callback({
			getProperty = function(_, key)
				return values[key]
			end,
		})
	end
	function f:finish(index, code)
		self.tasks[index].callback(code or 0, "", code and "test error" or "")
	end
	f.runtime = runtime
	if not noStart then
		f.controller =
			swipe.new({ aerospacePath = "/opt/homebrew/bin/aerospace", focusFollowsMouse = true }, runtime):start()
	end
	return f, f.controller
end

test("blocking is immediate; only the command is deferred", function()
	local f, c = fixture()
	equal(c:status().pointerTapEnabled, false)
	f:swipe()
	equal(c:status().gestureActive, true)
	equal(c:status().pointerTapEnabled, true)
	equal(f:scroll(0, 2), true)
	equal(#f.tasks, 0)
	f:advance(0)
	equal(#f.tasks, 1)
end)
test("normal scrolling and three-finger dragging never block", function()
	local f, c = fixture()
	f:touch(frame(0.5))
	f:touch(frame({ 0.4, 0.4, 0.5, 0.5 }))
	equal(f:scroll(0, 1), false)
	equal(f:scroll(2, 0), false)
	f:touch(frame(0.4, nil, { 1, 2, 3 }))
	equal(c:status().pointerTapEnabled, false)
end)
test("a short swipe ending before dispatch cannot rearm blocking", function()
	local f, c = fixture()
	f:swipe()
	f:touch({})
	f:advance(0)
	equal(#f.tasks, 1)
	equal(c:status().gestureActive, false)
	equal(c:status().pointerTapEnabled, false)
end)
test("old scroll-end preserves blocked momentum; fresh scroll clears it", function()
	local f, c = fixture()
	f:swipe()
	f:touch({})
	equal(f:scroll(0, 4), true)
	equal(f:scroll(1, 0), true)
	equal(f:scroll(2, 0), true)
	equal(f:scroll(0, 1), false)
	equal(f:scroll(2, 0), false)
	equal(c:status().momentumBlocked, false)
end)
test("momentum end and tail inactivity both release suppression", function()
	local f, c = fixture()
	f:swipe()
	f:touch({})
	equal(f:scroll(3, 0), true)
	equal(c:status().momentumBlocked, false)
	f:swipe()
	f:touch({})
	f:advance(0.51)
	equal(f:scroll(0, 2), false)
end)
test("physical mouse wheel passes without unblocking trackpad momentum", function()
	local f = fixture()
	f:swipe()
	f:touch({})
	equal(f:scroll(0, 0, 0), false)
	equal(f:scroll(2, 0), true)
end)
test("held swipe stays latched after timeout and rearms only on full release", function()
	local f, c = fixture()
	f:swipe()
	f:advance(0)
	f:finish(1)
	f:advance(0.51)
	equal(c:status().gestureActive, false)
	equal(c:status().pointerTapEnabled, false)
	f:touch(frame(0.4))
	f:touch(frame(0.5, nil, { 5, 6, 7, 8 }, "began"))
	f:touch(frame(0.6, nil, { 5, 6, 7, 8 }))
	f:advance(0)
	equal(c:status().recognized, 1)
	equal(c:status().switched, 1)
	equal(#f.tasks, 1)
	f:swipe(0.52)
	f:advance(0)
	equal(c:status().recognized, 2)
	equal(#f.tasks, 2)
	f:finish(2)
	equal(c:status().switched, 2)
end)
test("display is captured before dispatch and both directions map correctly", function()
	local f = fixture()
	f.screen = f.screenB
	f:swipe()
	f.screen = f.screenA
	f:advance(0)
	equal(f.tasks[1].args[1], "eval")
	equal(f.tasks[1].args[2], 'focus-monitor "^LG HDR 4K$" && workspace --no-stdin --wrap-around next')
	f:finish(1)
	f:swipe(0.52)
	f:advance(0)
	equal(f.tasks[2].args[2], 'focus-monitor "^Built-in Retina Display$" && workspace --no-stdin --wrap-around prev')
end)
test("display regex and expression metacharacters are escaped", function()
	local f = fixture()
	f.screen = {
		name = function()
			return 'A.(B) "C"'
		end,
	}
	f:swipe()
	f:advance(0)
	equal(f.tasks[1].args[2], 'focus-monitor "^A\\\\.\\\\(B\\\\) \\"C\\"$" && workspace --no-stdin --wrap-around next')
end)
test("keyboard focus and rapid swipes execute in order", function()
	local f, c = fixture()
	c:focusMonitor("down")
	f:advance(0)
	f:swipe()
	f:swipe(0.52)
	f:advance(0)
	equal(#f.tasks, 1)
	f:finish(1)
	f:advance(0)
	equal(#f.tasks, 2)
	f:finish(2)
	f:advance(0)
	equal(#f.tasks, 3)
	f:finish(3)
	equal(c:status().switched, 2)
end)
test("new focus intent coalesces pending pointer requests", function()
	local f, c = fixture()
	f.screen = f.screenB
	c.monitorTimer.callback()
	c.monitorTimer.callback()
	equal(c:status().queuedCommands, 1)
	f:swipe()
	equal(c:status().queuedCommands, 1)
	f:advance(0)
	equal(f.tasks[1].args[1], "eval")
end)
test("polling pauses during swipe and resyncs after pointer moves again", function()
	local f, c = fixture()
	f.screen = f.screenB
	f:swipe()
	f:advance(0.3)
	equal(#f.tasks, 1)
	f:finish(1)
	f:touch({})
	f:advance(0.2)
	equal(#f.tasks, 1)
	f.screen = f.screenA
	f:advance(0.25)
	equal(#f.tasks, 2)
	equal(f.tasks[2].args[2], "^Built-in Retina Display$")
	equal(c:status().errors, 0)
end)
test("command failures release blocking and discard pending requests", function()
	local f, c = fixture()
	f:swipe()
	f:advance(0)
	f:swipe()
	f:finish(1, 1)
	equal(c:status().errors, 1)
	equal(c:status().queuedCommands, 0)
	equal(c:status().gestureActive, false)
	f:advance(0.3)
	equal(#f.tasks, 1)
end)
test("CLI construction and launch failures are handled", function()
	for _, mode in ipairs({ "failStart", "failNew" }) do
		local f, c = fixture()
		f[mode] = true
		f:swipe()
		f:advance(0)
		equal(c:status().errors, 1)
		equal(c:status().commandBusy, false)
		equal(c:status().gestureActive, false)
	end
end)
test("timeout flushes commands; a late callback cannot finish a newer one", function()
	local f, c = fixture()
	f:swipe()
	f:advance(0)
	f:swipe()
	f:advance(1.01)
	equal(f.tasks[1].terminated, true)
	equal(c:status().timedOut, 1)
	equal(c:status().queuedCommands, 0)
	f:swipe()
	f:advance(0)
	f:finish(1)
	equal(c:status().commandBusy, true)
	f:finish(2)
	equal(c:status().switched, 1)
end)
test("sleep and wake clear state and restart listeners", function()
	local f, c = fixture()
	f:swipe()
	f:advance(0)
	f.wake(1)
	equal(f.tasks[1].terminated, true)
	equal(c:status().gestureActive, false)
	equal(c.monitorTimer.due, nil)
	f.wake(4)
	equal(c:status().gestureTapEnabled, true)
	equal(c:status().scrollTapEnabled, true)
	equal(c:status().pointerTapEnabled, false)
end)
test("stop cancels deferred commands and start is idempotent", function()
	local f, c = fixture()
	f:swipe()
	c:stop()
	f:advance(2)
	equal(#f.tasks, 0)
	equal(c:status().gestureTapEnabled, false)
	equal(c:status().scrollTapEnabled, false)
	c:start():start()
	f:swipe()
	f:advance(0)
	equal(#f.tasks, 1)
end)
test("missing display does not block input or dispatch", function()
	local f, c = fixture()
	f.screen = nil
	f:swipe()
	f:advance(0)
	equal(#f.tasks, 0)
	equal(c:status().errors, 1)
	equal(c:status().gestureActive, false)
end)
test("status returns a bounded copy of recent command timings", function()
	local f, c = fixture()
	for i = 1, 25 do
		f:swipe()
		f:advance(0.01)
		f:finish(i)
	end
	local status = c:status()
	equal(#status.recentCommandMs, 20)
	status.recentCommandMs[1] = -1
	assert(c:status().recentCommandMs[1] >= 0)
end)

local function loadSpoon(runtime)
	local environment = setmetatable({ hs = runtime }, { __index = _G })
	local chunk
	if setfenv then
		chunk = assert(loadfile(spoonPath .. "init.lua"))
		setfenv(chunk, environment)
	else
		chunk = assert(loadfile(spoonPath .. "init.lua", "t", environment))
	end
	return chunk()
end

local function spoonFixture()
	local f = fixture(true)
	f.files = {
		["/opt/homebrew/bin/aerospace"] = { mode = "file", permissions = "rwxr-xr-x" },
		["/usr/local/bin/aerospace"] = { mode = "file", permissions = "rwxr-xr-x" },
	}
	f.hotkeys = {}
	f.runtime.fs = {
		attributes = function(path)
			return f.files[path]
		end,
	}
	f.runtime.hotkey = {
		new = function(modifiers, key, message, callback)
			if f.failHotkey then
				return nil
			end
			if f.throwHotkey then
				error("Invalid key")
			end
			assert(message ~= nil, "Omit the message argument to bind a key-press callback")
			if type(message) == "function" then
				callback, message = message, nil
			end
			local hotkey = { modifiers = modifiers, key = key, message = message, callback = callback }
			function hotkey:enable()
				if f.failHotkeyEnable then
					return nil
				end
				self.enabled = true
				return self
			end
			function hotkey:delete()
				self.enabled = false
				self.deleted = true
			end
			f.hotkeys[#f.hotkeys + 1] = hotkey
			return hotkey
		end,
	}
	f.spoon = loadSpoon(f.runtime)
	return f, f.spoon
end

test("Spoon load, init, and status allocate no background resources", function()
	local f, s = spoonFixture()
	s:init():init()
	equal(s.name, "AeroSpaceSwipe")
	equal(s.version, "0.1.0")
	equal(s:status().running, false)
	equal(#f.timers, 0)
	equal(next(f.taps), nil)
	equal(#f.tasks, 0)
	equal(#f.hotkeys, 0)
	s:stop():stop()
end)

test("Spoon start is idempotent and stop actually stops every timer", function()
	local f, s = spoonFixture()
	s.focusFollowsMouse = true
	s:start()
	local count = #f.timers
	s:start()
	equal(#f.timers, count)
	f:swipe()
	s:stop():stop()
	for _, t in ipairs(f.timers) do
		equal(t.due, nil)
	end
	f:advance(2)
	equal(#f.tasks, 0)
	s:start()
	equal(#f.timers, count * 2)
	for i = 1, count do
		equal(f.timers[i].due, nil)
	end
	s:stop()
	for _, t in ipairs(f.timers) do
		equal(t.due, nil)
	end
end)

test("configuration is snapshotted per run and changes apply on restart", function()
	local f, s = spoonFixture()
	s.threshold = 0.04
	s:start()
	s.threshold = 0.01
	f:swipe()
	equal(s:status().recognized, 0)
	s:stop():start()
	f:swipe()
	equal(s:status().recognized, 1)
end)

test("Spoon auto-discovers Apple Silicon then Intel CLI locations", function()
	local f, s = spoonFixture()
	s:start()
	equal(s:status().aerospacePath, "/opt/homebrew/bin/aerospace")
	s:stop()
	f.files["/opt/homebrew/bin/aerospace"] = nil
	s:start()
	equal(s:status().aerospacePath, "/usr/local/bin/aerospace")
	f:swipe()
	f:advance(0)
	equal(#f.tasks, 1)
end)

test("explicit executable paths take precedence and never silently fall back", function()
	local f, s = spoonFixture()
	f.files["/custom/aerospace"] = { mode = "file", permissions = "rwx------" }
	s.aerospacePath = "/custom/aerospace"
	s:start()
	equal(s:status().aerospacePath, "/custom/aerospace")
	s:stop()
	s.aerospacePath = "/missing/aerospace"
	local result, err = s:start()
	equal(result, nil)
	assert(err:find("executable", 1, true))
	equal(s:status().running, false)
end)

test("missing, non-executable, and directory paths fail before listeners start", function()
	for _, attributes in ipairs({
		false,
		{ mode = "file", permissions = "rw-r--r--" },
		{ mode = "directory", permissions = "rwxr-xr-x" },
	}) do
		local f, s = spoonFixture()
		f.files = { ["/opt/homebrew/bin/aerospace"] = attributes or nil }
		local result, err = s:start()
		equal(result, nil)
		assert(type(err) == "string")
		equal(#f.timers, 0)
		equal(next(f.taps), nil)
		equal(s:status().lastError, err)
	end
end)

test("invalid sensitivity and timeout settings fail without background work", function()
	for _, value in ipairs({ 0, -1, math.huge, "0.01", 0 / 0 }) do
		local f, s = spoonFixture()
		s.threshold = value
		equal(s:start(), nil)
		equal(#f.timers, 0)
	end
	local f, s = spoonFixture()
	s.focusFollowsMouse = "true"
	equal(s:start(), nil)
	equal(#f.timers, 0)
end)

test("failed event-tap activation cleans up all background work", function()
	local f, s = spoonFixture()
	local newTap = f.runtime.eventtap.new
	f.runtime.eventtap.new = function(events, callback)
		local tap = newTap(events, callback)
		tap.start = function()
			return tap
		end
		return tap
	end
	equal(s:start(), nil)
	for _, t in ipairs(f.timers) do
		equal(t.due, nil)
	end
	equal(s:status().running, false)
end)

test("pointer focus is off by default, including after wake; swipes still target the pointer", function()
	local f, s = spoonFixture()
	s:start()
	f.screen = f.screenB
	f:advance(0.3)
	equal(#f.tasks, 0)
	f.wake(4)
	f:advance(0.3)
	equal(#f.tasks, 0)
	f:swipe()
	f:advance(0)
	assert(f.tasks[1].args[2]:find("LG HDR 4K", 1, true))
end)

test("pointer focus can be enabled explicitly", function()
	local f, s = spoonFixture()
	s.focusFollowsMouse = true
	s:start()
	f.screen = f.screenB
	f:advance(0.3)
	equal(f.tasks[1].args[1], "focus-monitor")
end)

test("hotkeys are opt-in, inert before start, and share command serialization", function()
	local f, s = spoonFixture()
	s:bindHotkeys({ focusMonitorUp = { { "ctrl", "alt" }, "k", message = "Focus up" } })
	equal(#f.hotkeys, 0)
	s:start()
	equal(#f.hotkeys, 1)
	equal(f.hotkeys[1].enabled, true)
	equal(f.hotkeys[1].message, "Focus up")
	f.hotkeys[1].callback()
	f:advance(0)
	equal(f.tasks[1].args[2], "up")
	f:swipe()
	f:advance(0)
	equal(#f.tasks, 1)
	f:finish(1)
	f:advance(0)
	equal(f.tasks[2].args[1], "eval")
end)

test("hotkey replacement and stop delete previous bindings", function()
	local f, s = spoonFixture()
	s:bindHotkeys({ focusMonitorUp = { { "ctrl" }, "k" } }):start()
	s:bindHotkeys({ focusMonitorDown = { { "ctrl" }, "j" } })
	equal(f.hotkeys[1].deleted, true)
	equal(f.hotkeys[2].enabled, true)
	s:stop()
	equal(f.hotkeys[2].deleted, true)
	s:start()
	equal(f.hotkeys[3].enabled, true)
	s:bindHotkeys({})
	equal(f.hotkeys[3].deleted, true)
	equal(s:status().boundHotkeys, 0)
end)

test("hotkey configuration is copied and unknown actions rejected", function()
	local f, s = spoonFixture()
	local mapping = { focusMonitorLeft = { { "ctrl" }, "h" } }
	s:bindHotkeys(mapping)
	mapping.focusMonitorLeft[1][1] = "alt"
	mapping.focusMonitorLeft[2] = "j"
	equal(s:bindHotkeys({ unknown = { {}, "k" } }), nil)
	s:start()
	equal(f.hotkeys[1].modifiers[1], "ctrl")
	equal(f.hotkeys[1].key, "h")
end)

test("hotkey creation failure stops a partially started Spoon", function()
	for _, failure in ipairs({ "failHotkey", "throwHotkey", "failHotkeyEnable" }) do
		local f, s = spoonFixture()
		f[failure] = true
		s:bindHotkeys({ focusMonitorUp = { {}, "k" } })
		equal(s:start(), nil)
		equal(s:status().running, false)
		for _, t in ipairs(f.timers) do
			equal(t.due, nil)
		end
		for _, hotkey in ipairs(f.hotkeys) do
			equal(hotkey.deleted, true)
		end
	end
end)

test("public focusMonitor rejects invalid directions and calls while stopped", function()
	local f, s = spoonFixture()
	equal(s:focusMonitor("up"), nil)
	s:start()
	equal(s:focusMonitor("elsewhere"), nil)
	equal(s:focusMonitor("down"), s)
	f:advance(0)
	equal(f.tasks[1].args[2], "down")
end)

test("status retains an isolated snapshot after stop and resets on the next run", function()
	local f, s = spoonFixture()
	s:start()
	f:swipe()
	f:advance(0.02)
	f:finish(1)
	s:stop()
	local state = s:status()
	equal(state.switched, 1)
	state.recentCommandMs[1] = -1
	assert(s:status().recentCommandMs[1] >= 0)
	s:start()
	equal(s:status().switched, 0)
	equal(#s:status().recentCommandMs, 0)
end)

print("Passed " .. passed .. " tests")
