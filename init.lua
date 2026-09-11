local ControllerModule = {}
local releaseConfirmationDelay = 0.05

function ControllerModule.newRecognizer(options)
	options = options or {}
	local recognizer = {}
	function recognizer:reset()
		self.origins, self.latched, self.releasePending = nil, false, false
	end

	function recognizer:confirmRelease()
		if not self.releasePending then
			return false
		end
		self:reset()
		return true
	end

	function recognizer:expire()
		-- Keep the fired latch until fingers lift.
		self.origins = nil
	end

	function recognizer:update(touches)
		if not touches then
			return nil, false
		end
		local active, cancelled = {}, false
		for _, touch in ipairs(touches) do
			if touch.type == "indirect" and touch.identity and touch.normalizedPosition then
				if touch.touching then
					active[#active + 1] = touch
				elseif touch.phase == "cancelled" then
					cancelled = true
				end
			end
		end
		if #active == 0 then
			-- Empty frames can occur between movements from the same fingers.
			self.releasePending = true
			return nil, false
		end
		self.releasePending = false
		if cancelled then
			self.origins, self.latched = nil, true
			return nil, true
		end
		-- Only a full release rearms recognition, even if touch IDs or phases change.
		if self.latched then
			return nil, false
		end
		if #active ~= 4 then
			self.origins = nil
			return nil, false
		end
		local sameContacts = self.origins ~= nil
		for _, touch in ipairs(active) do
			sameContacts = sameContacts and self.origins[touch.identity] ~= nil and touch.phase ~= "began"
		end
		if not sameContacts then
			self.origins = {}
			for _, touch in ipairs(active) do
				self.origins[touch.identity] = { x = touch.normalizedPosition.x, y = touch.normalizedPosition.y }
			end
			return nil, false
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
			return left and "left" or "right", false
		end
		return nil, false
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

function ControllerModule.new(options, runtime)
	local self = setmetatable({
		options = options,
		runtime = runtime,
		logger = options.logger or runtime.logger.new("AeroSpaceSwipe", "warning"),
		recognizer = ControllerModule.newRecognizer(options),
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
	self.releaseTimeout = oneShot(runtime.timer, releaseConfirmationDelay, function()
		if self.recognizer:confirmRelease() then
			self:releaseInput(self.swipeActive or self.blockMomentum)
		end
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
	self.releaseTimeout:stop()
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
	local wasReleasePending = self.recognizer.releasePending
	local direction, released = self.recognizer:update(touches)
	if self.recognizer.releasePending then
		if not wasReleasePending then
			self.releaseTimeout:start()
		end
	else
		self.releaseTimeout:stop()
	end
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
	self.releaseTimeout:stop()
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
	self.releaseTimeout:stop()
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

local Spoon = {
	name = "AeroSpaceSwipe",
	version = "0.1.0",
	author = "Cuong Vu",
	homepage = "https://github.com/cuongvd23/AeroSpaceSwipe.spoon",
	license = "MIT - https://opensource.org/licenses/MIT",
	threshold = 0.01,
	fingerThreshold = 0.002,
	horizontalRatio = 1.5,
	touchTimeout = 0.5,
	commandTimeout = 1,
	focusFollowsMouse = false,
	_controllerModule = ControllerModule, -- Internal constructors for local tests.
	_hotkeys = {},
	_mapping = {},
}

local monitorDirections = {
	focusMonitorLeft = "left",
	focusMonitorRight = "right",
	focusMonitorUp = "up",
	focusMonitorDown = "down",
}
local positiveSettings = { "threshold", "fingerThreshold", "horizontalRatio", "touchTimeout", "commandTimeout" }

local function isExecutable(path)
	local attributes = hs.fs.attributes(path)
	return attributes and attributes.mode == "file" and attributes.permissions:find("x", 1, true)
end

local function findAeroSpace(explicit)
	if explicit ~= nil then
		if type(explicit) == "string" and explicit:sub(1, 1) == "/" and isExecutable(explicit) then
			return explicit
		end
		return nil, "aerospacePath must name an executable file at an absolute path"
	end
	for _, path in ipairs({ "/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace" }) do
		if isExecutable(path) then
			return path
		end
	end
	return nil, "AeroSpace CLI not found; set spoon.AeroSpaceSwipe.aerospacePath"
end

function Spoon:_clearHotkeys()
	for _, hotkey in ipairs(self._hotkeys) do
		hotkey:delete()
	end
	self._hotkeys = {}
end

function Spoon:_enableHotkeys()
	self:_clearHotkeys()
	for action, binding in pairs(self._mapping) do
		local direction = monitorDirections[action]
		local callback = function()
			self:focusMonitor(direction)
		end
		local ok, hotkey = pcall(function()
			-- Omit nil; Hammerspoon would bind key release.
			if binding.message ~= nil then
				return hs.hotkey.new(binding[1], binding[2], binding.message, callback)
			end
			return hs.hotkey.new(binding[1], binding[2], callback)
		end)
		if not ok or not hotkey then
			self:_clearHotkeys()
			return nil, "Unable to create hotkey for " .. action
		end
		self._hotkeys[#self._hotkeys + 1] = hotkey
		if not hotkey:enable() then
			self:_clearHotkeys()
			return nil, "Unable to enable hotkey for " .. action
		end
	end
	return self
end

function Spoon:init()
	self.logger = self.logger or hs.logger.new("AeroSpaceSwipe", "warning")
	return self
end

function Spoon:start()
	if self._controller then
		return self
	end
	self:init()
	local options = { logger = self.logger, focusFollowsMouse = self.focusFollowsMouse }
	local function fail(message)
		self._startError = message
		self.logger:w(message)
		return nil, message
	end
	for _, key in ipairs(positiveSettings) do
		local value = self[key]
		if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
			return fail(key .. " must be a positive finite number")
		end
		options[key] = value
	end
	if type(options.focusFollowsMouse) ~= "boolean" then
		return fail("focusFollowsMouse must be a boolean")
	end
	local path, err = findAeroSpace(self.aerospacePath)
	if not path then
		return fail(err)
	end
	options.aerospacePath = path
	local controller = ControllerModule.new(options, hs):start()
	local state = controller:status()
	if not state.gestureTapEnabled or not state.scrollTapEnabled then
		controller:stop()
		return fail("Unable to start input listeners; check Hammerspoon Accessibility permission")
	end
	self._controller, self._resolvedPath, self._startError = controller, path, nil
	local ok, hotkeyError = self:_enableHotkeys()
	if not ok then
		self:stop()
		return fail(hotkeyError)
	end
	return self
end

function Spoon:stop()
	self:_clearHotkeys()
	if self._controller then
		self._controller:stop()
		self._lastStatus = self._controller:status()
		self._controller = nil
	end
	return self
end

function Spoon:status()
	local source = self._controller and self._controller:status()
		or self._lastStatus
		or {
			running = false,
			gestureActive = false,
			momentumBlocked = false,
			gestureTapEnabled = false,
			scrollTapEnabled = false,
			pointerTapEnabled = false,
			commandBusy = false,
			queuedCommands = 0,
			recognized = 0,
			switched = 0,
			errors = 0,
			timedOut = 0,
			recentCommandMs = {},
		}
	local state = {}
	for key, value in pairs(source) do
		state[key] = value
	end
	state.recentCommandMs = {}
	for i, value in ipairs(source.recentCommandMs) do
		state.recentCommandMs[i] = value
	end
	state.lastError = self._startError or source.lastError
	state.aerospacePath = self._resolvedPath
	state.boundHotkeys = #self._hotkeys
	return state
end

function Spoon:focusMonitor(direction)
	if direction ~= "left" and direction ~= "right" and direction ~= "up" and direction ~= "down" then
		return nil, "Invalid monitor direction"
	end
	if not self._controller then
		return nil, "AeroSpaceSwipe is stopped"
	end
	self._controller:focusMonitor(direction)
	return self
end

function Spoon:bindHotkeys(mapping)
	if type(mapping) ~= "table" then
		return nil, "Hotkey mapping must be a table"
	end
	local bindings = {}
	for action, binding in pairs(mapping) do
		if
			not monitorDirections[action]
			or type(binding) ~= "table"
			or type(binding[1]) ~= "table"
			or (type(binding[2]) ~= "string" and type(binding[2]) ~= "number")
			or (binding.message ~= nil and type(binding.message) ~= "string")
		then
			return nil, "Invalid hotkey binding: " .. tostring(action)
		end
		local modifiers = {}
		for i, modifier in ipairs(binding[1]) do
			modifiers[i] = modifier
		end
		bindings[action] = { modifiers, binding[2], message = binding.message }
	end
	self._mapping = bindings
	if self._controller then
		return self:_enableHotkeys()
	end
	return self
end

return Spoon
