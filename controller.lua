local M = {}

function M.newRecognizer(options)
	options = options or {}
	local recognizer = {}
	function recognizer:reset()
		self.origins, self.contacts, self.latched = nil, nil, false
	end

	function recognizer:expire()
		-- Keep the fired latch until fingers lift.
		self.origins = nil
	end

	function recognizer:update(touches)
		if not touches then
			return nil, false
		end
		local active, continuing, cancelled = {}, false, false
		for _, touch in ipairs(touches) do
			if touch.type == "indirect" and touch.identity and touch.normalizedPosition then
				if touch.touching then
					active[#active + 1] = touch
					if self.contacts and self.contacts[touch.identity] and touch.phase ~= "began" then
						continuing = true
					end
				elseif touch.phase == "cancelled" then
					cancelled = true
				end
			end
		end
		if #active == 0 then
			self:reset()
			return nil, true
		end
		if cancelled then
			self.origins, self.contacts, self.latched = nil, {}, true
			for _, touch in ipairs(active) do
				self.contacts[touch.identity] = true
			end
			return nil, true
		end
		local released = self.latched and not continuing
		if released then
			self:reset()
		end
		if self.latched then
			return nil, false
		end
		if #active ~= 4 then
			self.origins = nil
			return nil, released
		end
		local sameContacts = self.origins ~= nil
		for _, touch in ipairs(active) do
			sameContacts = sameContacts and self.origins[touch.identity] ~= nil and touch.phase ~= "began"
		end
		if not sameContacts then
			self.origins, self.contacts = {}, {}
			for _, touch in ipairs(active) do
				self.origins[touch.identity] = { x = touch.normalizedPosition.x, y = touch.normalizedPosition.y }
				self.contacts[touch.identity] = true
			end
			return nil, released
		end
		local dx, dy, left, right = 0, 0, true, true
		local minimumFingerTravel = options.fingerThreshold or 0.002
		for _, touch in ipairs(active) do
			local origin = self.origins[touch.identity]
			local x = touch.normalizedPosition.x - origin.x
			dx, dy = dx + x, dy + touch.normalizedPosition.y - origin.y
			left, right = left and x <= -minimumFingerTravel, right and x >= minimumFingerTravel
		end
		dx, dy = dx / 4, dy / 4
		if
			math.abs(dx) >= (options.threshold or 0.01)
			and math.abs(dx) >= math.abs(dy) * (options.horizontalRatio or 1.5)
			and (left or right)
		then
			self.latched = true
			return left and "left" or "right", released
		end
		return nil, released
	end

	recognizer:reset()
	return recognizer
end

local function displayPattern(name)
	return "^"
		.. name:gsub(".", function(char)
			return ("\\^$.*+?()[]{}|"):find(char, 1, true) and "\\" .. char or char
		end)
		.. "$"
end

local function quoteArgument(value)
	return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local Controller = {}
Controller.__index = Controller

local function oneShot(timers, delay, callback)
	local timer
	timer = timers.new(delay, function()
		timer:stop()
		callback()
	end)
	return {
		start = function()
			timer:setNextTrigger(delay)
		end,
		stop = function()
			timer:stop()
		end,
	}
end

function M.new(options, runtime)
	local self = setmetatable({
		options = options,
		runtime = runtime,
		logger = options.logger or runtime.logger.new("AeroSpaceSwipe", "warning"),
		recognizer = M.newRecognizer(options),
		queue = {},
		retiring = {},
		durations = {},
		recognized = 0,
		switched = 0,
		errors = 0,
		timedOut = 0,
	}, Controller)
	local types = runtime.eventtap.event.types
	self.gestureTap = runtime.eventtap.new({ types.gesture }, function(event)
		if event:getType(true) == types.gesture then
			self:handleTouches(event:getTouches())
		end
		return false
	end)
	self.scrollTap = runtime.eventtap.new({ types.scrollWheel }, function(event)
		return self:shouldBlockScroll(event)
	end)
	self.pointerTap = runtime.eventtap.new({ types.mouseMoved, types.leftMouseDragged }, function()
		return self.swipeActive == true
	end)
	self.touchTimeout = oneShot(runtime.timer, options.touchTimeout or 0.5, function()
		self.recognizer:expire()
		self:releaseInput(false)
	end)
	self.momentumTimeout = oneShot(runtime.timer, 0.5, function()
		self.blockMomentum = false
	end)
	self.dispatchTimer = oneShot(runtime.timer, 0, function()
		self.dispatchScheduled = false
		self:runNextCommand()
	end)
	self.commandTimeout = oneShot(runtime.timer, options.commandTimeout or 1, function()
		self.timedOut = self.timedOut + 1
		self:recordError("AeroSpace command timed out; pending commands discarded")
		self:cancelCommands()
		self.lastScreen = runtime.mouse.getCurrentScreen()
		self:releaseInput(false)
	end)
	self.monitorTimer = runtime.timer.new(0.25, function()
		self:focusPointerMonitor()
	end)
	self.wakeWatcher = runtime.caffeinate.watcher.new(function(event)
		self:handleSleepWake(event)
	end)
	return self
end

function Controller:now()
	return self.runtime.timer.absoluteTime() / 1e9
end

function Controller:scheduleCommand()
	if not self.activeCommand and not self.dispatchScheduled and #self.queue > 0 then
		self.dispatchScheduled = true
		self.dispatchTimer:start()
	end
end

function Controller:focusPointerMonitor()
	if self.swipeActive or self.activeCommand or #self.queue > 0 then
		return
	end
	local screen = self.runtime.mouse.getCurrentScreen()
	if screen and screen ~= self.lastScreen then
		self:queueCommand({
			kind = "pointer",
			screen = screen,
			args = { "focus-monitor", displayPattern(screen:name()) },
		})
	end
end

function Controller:handleSleepWake(event)
	local watcher = self.runtime.caffeinate.watcher
	local sleeping = event == watcher.systemWillSleep
		or event == watcher.screensDidSleep
		or event == watcher.screensDidLock
	local waking = event == watcher.systemDidWake
		or event == watcher.screensDidWake
		or event == watcher.screensDidUnlock
	if not sleeping and not waking then
		return
	end
	self:cancelCommands()
	self:releaseInput(false)
	self.recognizer:reset()
	self.lastScreen = nil
	self.monitorTimer:stop()
	if self.running and waking then
		self.gestureTap:start()
		self.scrollTap:start()
		if self.options.focusFollowsMouse then
			self.monitorTimer:start()
		end
	end
end

function Controller:recordError(message)
	self.errors, self.lastError = self.errors + 1, message
	self.logger:w(message)
end

function Controller:releaseInput(keepMomentum)
	self.swipeActive = false
	self.pointerTap:stop()
	self.touchTimeout:stop()
	self.blockMomentum = keepMomentum
	if keepMomentum then
		self.momentumTimeout:start()
	else
		self.momentumTimeout:stop()
	end
end

function Controller:cancelCommands()
	self.queue = {}
	self.dispatchScheduled = false
	self.dispatchTimer:stop()
	self.commandTimeout:stop()
	local request = self.activeCommand
	self.activeCommand = nil
	if request and request.task then
		self.retiring[request.task] = true
		request.task:terminate()
	end
end

function Controller:completeCommand(request, code, stderr)
	if request.task then
		self.retiring[request.task] = nil
	end
	if self.activeCommand ~= request then
		return -- Ignore completion from a cancelled task.
	end
	self.commandTimeout:stop()
	self.activeCommand = nil
	self.durations[#self.durations + 1] = (self:now() - request.started) * 1000
	if #self.durations > 20 then
		table.remove(self.durations, 1)
	end
	if code == 0 then
		if request.kind == "swipe" then
			self.switched = self.switched + 1
		end
		self.lastScreen = request.screen or self.runtime.mouse.getCurrentScreen()
	else
		self:recordError("AeroSpace " .. request.kind .. " failed (" .. tostring(code) .. "): " .. (stderr or ""))
		self.queue = {}
		self.lastScreen = self.runtime.mouse.getCurrentScreen()
		self:releaseInput(false)
	end
	if self.running and #self.queue > 0 then
		self:scheduleCommand()
	end
end

function Controller:runNextCommand()
	if not self.running or self.activeCommand or #self.queue == 0 then
		return
	end
	local request = table.remove(self.queue, 1)
	request.started = self:now()
	self.activeCommand = request
	request.task = self.runtime.task.new(self.options.aerospacePath, function(code, _, stderr)
		self:completeCommand(request, code, stderr)
	end, request.args)
	if not request.task or not request.task:start() then
		self:completeCommand(request, "start", "Unable to start CLI")
	elseif self.activeCommand == request then
		self.commandTimeout:start()
	end
end

function Controller:queueCommand(request)
	if not self.running then
		return
	end
	for i = #self.queue, 1, -1 do
		if self.queue[i].kind == "pointer" then
			table.remove(self.queue, i)
		end
	end
	self.queue[#self.queue + 1] = request
	self:scheduleCommand()
end

function Controller:focusMonitor(direction)
	self:queueCommand({ kind = "keyboard", args = { "focus-monitor", direction } })
end

function Controller:handleTouches(touches)
	local direction, released = self.recognizer:update(touches)
	if released then
		self:releaseInput(self.swipeActive or self.blockMomentum)
	end
	if direction then
		self.recognized = self.recognized + 1
		local screen = self.runtime.mouse.getCurrentScreen()
		if not screen then
			self:recordError("No display under pointer for swipe")
			return
		end
		self.swipeActive = true
		self.pointerTap:start()
		self.blockMomentum = false
		self.momentumTimeout:stop()
		local expression = "focus-monitor "
			.. quoteArgument(displayPattern(screen:name()))
			.. " && workspace --no-stdin --wrap-around "
			.. (direction == "left" and "next" or "prev")
		self:queueCommand({ kind = "swipe", screen = screen, args = { "eval", expression } })
	end
	if touches and self.swipeActive then
		self.touchTimeout:start()
	end
end

function Controller:shouldBlockScroll(event)
	if self.swipeActive then
		return true
	end
	if not self.blockMomentum then
		return false
	end
	local properties = self.runtime.eventtap.event.properties
	if event:getProperty(properties.scrollWheelEventIsContinuous) == 0 then
		return false
	end
	local momentum = event:getProperty(properties.scrollWheelEventMomentumPhase)
	local phase = event:getProperty(properties.scrollWheelEventScrollPhase)
	local newScroll = phase % 2 == 1 or phase >= 128
	if momentum == 0 and newScroll then
		self.blockMomentum = false
		self.momentumTimeout:stop()
		return false
	end
	if momentum == 3 then
		self.blockMomentum = false
		self.momentumTimeout:stop()
	else
		self.momentumTimeout:start()
	end
	return true
end

function Controller:start()
	if self.running then
		return self
	end
	self.running = true
	self.recognizer:reset()
	self.lastScreen = self.runtime.mouse.getCurrentScreen()
	self.gestureTap:start()
	self.scrollTap:start()
	if self.options.focusFollowsMouse then
		self.monitorTimer:start()
	end
	self.wakeWatcher:start()
	return self
end

function Controller:stop()
	self.running = false
	self:cancelCommands()
	self:releaseInput(false)
	self.recognizer:reset()
	self.gestureTap:stop()
	self.scrollTap:stop()
	self.monitorTimer:stop()
	self.wakeWatcher:stop()
	return self
end

function Controller:status()
	local durations = {}
	for i, value in ipairs(self.durations) do
		durations[i] = value
	end
	return {
		running = self.running == true,
		gestureActive = self.swipeActive == true,
		momentumBlocked = self.blockMomentum == true,
		gestureTapEnabled = self.gestureTap:isEnabled(),
		scrollTapEnabled = self.scrollTap:isEnabled(),
		pointerTapEnabled = self.pointerTap:isEnabled(),
		commandBusy = self.activeCommand ~= nil,
		queuedCommands = #self.queue,
		recognized = self.recognized,
		switched = self.switched,
		errors = self.errors,
		timedOut = self.timedOut,
		lastError = self.lastError,
		recentCommandMs = durations,
	}
end

return M
