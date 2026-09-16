local testPath = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
local hover = dofile(testPath .. "../init.lua")._controllerModule

local function fixture()
	local f = { state = { running = true, queuedCommands = 0 }, buttons = {}, point = { x = 150, y = 50 }, focused = 1 }
	local screen = {
		id = function()
			return 1
		end,
		frame = function()
			return { x = 0, y = 0, w = 200, h = 100 }
		end,
	}
	local function window(id, x)
		return {
			id = function()
				return id
			end,
			screen = function()
				return screen
			end,
			frame = function()
				return { x = x, y = 0, w = 100, h = 100 }
			end,
			isStandard = function()
				return true
			end,
			focus = function()
				f.focused = id
			end,
		}
	end
	f.windows = { window(1, 0), window(2, 100) }
	f.pointerScreen = screen
	local runtime = {
		mouse = {
			absolutePosition = function()
				return f.point
			end,
			getCurrentScreen = function()
				return f.pointerScreen
			end,
		},
		window = {
			focusedWindow = function()
				return f.windows[f.focused]
			end,
			orderedWindows = function()
				return f.windows
			end,
		},
		timer = {
			new = function(delay, callback)
				local t = {}
				function t:setNextTrigger()
					if delay == 0.1 then
						f.armed = true
						f.starts = (f.starts or 0) + 1
					end
				end
				function t:stop()
					if delay == 0.1 then
						f.armed = false
					end
				end
				if delay == 0.1 then
					f.fire = callback
				else
					f.expire = callback
				end
				return t
			end,
		},
		eventtap = {
			event = { types = { mouseMoved = 1 } },
			checkMouseButtons = function()
				return f.buttons
			end,
			new = function(_, callback)
				f.move = callback
				return {
					start = function(self)
						f.enabled = true
						return self
					end,
					stop = function()
						f.enabled = false
					end,
					isEnabled = function()
						return f.enabled
					end,
				}
			end,
		},
		task = {
			new = function(path, callback, args)
				assert(path == "/custom/aerospace")
				if f.failNew then
					return nil
				end
				assert(table.concat(args, " ") == "list-windows --workspace focused --format %{window-id}")
				f.complete = callback
				return {
					start = function()
						return not f.failStart
					end,
					terminate = function()
						f.terminated = true
					end,
				}
			end,
		},
	}
	f.errors = {}
	f.handler = hover
		.newHoverFocus({ aerospacePath = "/custom/aerospace", commandTimeout = 1 }, runtime, function()
			return not f.state.running
				or f.state.gestureActive
				or f.state.momentumBlocked
				or f.state.commandBusy
				or f.state.queuedCommands > 0
		end, function(message)
			f.errors[#f.errors + 1] = message
		end)
		:start()
	return f
end

local count = 0
local function test(name, run)
	run(fixture())
	count = count + 1
	print("PASS " .. name)
end

test("hover focuses another window on the focused workspace", function(f)
	f.move()
	assert(f.armed)
	f.fire()
	f.complete(0, "1\n2\n")
	assert(f.focused == 2)
end)
test("other workspace windows cannot receive hover focus", function(f)
	f.move()
	f.fire()
	f.complete(0, "1\n")
	assert(f.focused == 1)
end)
for _, key in ipairs({ "gestureActive", "momentumBlocked", "commandBusy" }) do
	test("blocked during " .. key, function(f)
		f.state[key] = true
		f.move()
		assert(not f.armed)
	end)
end
test("queued monitor commands block hover", function(f)
	f.state.queuedCommands = 1
	f.move()
	assert(not f.armed)
end)
test("dragging blocks hover", function(f)
	f.buttons = { left = true }
	f.move()
	assert(not f.armed)
end)
test("monitor crossings remain owned by AeroSpaceSwipe", function(f)
	f.pointerScreen = {
		id = function()
			return 2
		end,
	}
	f.move()
	f.fire()
	assert(not f.complete)
end)
test("a swipe beginning during the query blocks focus", function(f)
	f.move()
	f.fire()
	f.state.gestureActive = true
	f.complete(0, "1\n2\n")
	assert(f.focused == 1)
end)
test("continuous movement does not restart the hover delay", function(f)
	f.move()
	f.move()
	f.move()
	assert(f.starts == 1)
	f.fire()
	f.complete(0, "1\n2\n")
	assert(f.focused == 2)
end)
test("continuous movement does not cancel the workspace query", function(f)
	f.move()
	f.fire()
	local old = f.complete
	f.point = { x = 160, y = 50 }
	f.move()
	old(0, "1\n2\n")
	assert(not f.terminated and f.focused == 2)
end)
test("focus uses the latest pointer position", function(f)
	f.move()
	f.fire()
	f.point = { x = 50, y = 50 }
	f.complete(0, "1\n2\n")
	assert(f.focused == 1)
end)
test("moving to another monitor while querying cannot steal focus", function(f)
	f.move()
	f.fire()
	f.pointerScreen = {
		id = function()
			return 2
		end,
	}
	f.complete(0, "1\n2\n")
	assert(f.focused == 1)
end)
test("a swipe cancels an in-flight hover query", function(f)
	f.move()
	f.fire()
	f.state.gestureActive = true
	f.move()
	f.complete(0, "1\n2\n")
	assert(f.terminated and f.focused == 1)
end)
test("query failures leave focus untouched", function(f)
	f.move()
	f.fire()
	f.complete(1, "")
	assert(f.focused == 1)
end)
test("covering dialogs block focus to windows behind them", function(f)
	f.windows[1].frame = f.windows[2].frame
	f.move()
	f.fire()
	f.complete(0, "1\n2\n")
	assert(f.focused == 1)
end)
test("stopping cancels pending focus", function(f)
	f.move()
	f.fire()
	f.handler:stop()
	f.complete(0, "1\n2\n")
	assert(f.terminated and f.focused == 1)
end)
test("timeout cancels hung queries and permits later hover", function(f)
	f.move()
	f.fire()
	local stale = f.complete
	f.expire()
	assert(f.terminated and #f.errors == 1)
	f.move()
	f.fire()
	stale(0, "1\n2\n")
	assert(f.focused == 1)
	f.complete(0, "1\n2\n")
	assert(f.focused == 2)
end)
test("task creation failure permits the next hover attempt", function(f)
	f.failNew = true
	f.move()
	f.fire()
	assert(#f.errors == 1)
	f.failNew = false
	f.move()
	f.fire()
	f.complete(0, "1\n2\n")
	assert(f.focused == 2)
end)
test("task startup failure permits the next hover attempt", function(f)
	f.failStart = true
	f.move()
	f.fire()
	assert(#f.errors == 1)
	f.failStart = false
	f.move()
	f.fire()
	f.complete(0, "1\n2\n")
	assert(f.focused == 2)
end)
test("stop and restart retain one working hover listener", function(f)
	assert(f.handler:isEnabled())
	f.handler:stop()
	assert(not f.handler:isEnabled())
	f.handler:start()
	f.move()
	f.fire()
	f.complete(0, "1\n2\n")
	assert(f.focused == 2)
end)
print(count .. " hover focus checks passed")
return count
