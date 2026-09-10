local Controller = dofile(hs.spoons.resourcePath("controller.lua"))
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
	local controller = Controller.new(options, hs):start()
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
