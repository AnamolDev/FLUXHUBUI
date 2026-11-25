--[[
	Systems/InputManager — the keybind layer: registration, chords, capture, release.

	Three things this has to get right that a naive version does not:

	  * A HOLD binding is pulled, not pushed. The engine's InputEnded is unreliable for a key
	    released while the game window does not have focus, so a hold-style feature (boost while
	    held) reads `binding:GetState()` on its own frame loop and cannot get stuck on. The
	    down/up callbacks are still dispatched for callers that want them.
	  * A chord must match the modifier set exactly. A bind on Ctrl+G that also fires on a bare G
	    is worse than no bind, and the reverse (a bare bind that fires while a modifier is down) is
	    how "I pressed it and nothing happened" bug reports start.
	  * Releasing everything on unload has to be idempotent, because the cleanup path runs from a
	    Maid, from the keybind picker's cancel, and from the window's destroy.
]]

local Signal = require("Flux/Utilities/Signal")
local Guard = require("Flux/Utilities/Guard")
local String = require("Flux/Utilities/String")
local Table = require("Flux/Utilities/Table")

local UserInputService = Guard.service("UserInputService")

local InputManager = {}

--- Keys the capture session refuses to bind, because the UI needs them to stay reachable.
InputManager.forbidden = {
	Escape = true,
	Home = true,
}

local bindings = {}
local captureSessions = {}
local held = {}
local connections = {}

InputManager.Changed = Signal.new()

local function inputName(input: any): string?
	if input == nil then
		return nil
	end

	-- A UserInput object has no Name: the member that identifies the press is its KeyCode (a key)
	-- or its UserInputType (a mouse button, touch). Names are compared rather than the objects
	-- because a restored config carries the same trigger as a string.
	local code = Guard.get(input, "KeyCode")
	-- Unknown is what the engine puts on a press that has no key, so it is not a name.
	if code ~= nil and code ~= Enum.KeyCode.Unknown then
		local name = Guard.get(code, "Name")
		if type(name) == "string" then
			return name
		end
	end

	local kind = Guard.get(input, "UserInputType")
	if kind ~= nil then
		local name = Guard.get(kind, "Name")
		if type(name) == "string" then
			return name
		end
	end

	local direct = Guard.get(input, "Name")
	return type(direct) == "string" and direct or nil
end

--- Does this engine input fire this binding? A binding stores an Enum member and the engine hands
--- over a UserInput object, so the two are never equal and the comparison has to go through the
--- object's own KeyCode / UserInputType member.
local function matchesInput(binding: any, input: any): boolean
	if binding == nil or binding.input == nil or input == nil then
		return false
	end
	local wanted = binding.input
	if Guard.get(input, "KeyCode") == wanted or Guard.get(input, "UserInputType") == wanted then
		return true
	end
	return inputName(input) == inputName(wanted)
end

--- A binding's trigger can be a KeyCode, a UserInputType (mouse buttons), or the name of either
--- as typed in a config file.
local function resolve(value: any): any
	local enumItem = Guard.get(value, "Name")
	if enumItem ~= nil and typeof(value) == "EnumItem" then
		return value
	end

	if type(value) == "string" then
		local byKey = Guard.get(Enum.KeyCode, value)
		if byKey ~= nil then
			return byKey
		end
		return Guard.get(Enum.UserInputType, value)
	end

	if type(value) == "table" then
		-- A config restores { Name = "G", Enum = "KeyCode" }.
		local name = value.Name
		if type(name) == "string" then
			local wanted = value.Enum == "UserInputType" and Enum.UserInputType or Enum.KeyCode
			return Guard.get(wanted, name) or Guard.get(Enum.KeyCode, name) or Guard.get(Enum.UserInputType, name)
		end
	end

	return nil
end

--- Which modifiers are down right now, as a name-keyed set.
function InputManager.modifiers(): {[string]: boolean}
	local out = { Ctrl = false, Shift = false, Alt = false }
	if UserInputService == nil then
		return out
	end

	local ok, mods = pcall(function()
		return UserInputService:GetModifiersState()
	end)

	if ok and mods ~= nil then
		out.Ctrl = Guard.get(mods, "Ctrl") == true
		out.Shift = Guard.get(mods, "Shift") == true
		out.Alt = Guard.get(mods, "Alt") == true
		out.Meta = Guard.get(mods, "Meta") == true
		return out
	end

	-- Older clients have no GetModifiersState. Keycode polling is not exactly the same (it misses
	-- the synthetic modifier some emulated inputs produce) but a chord that never matches is
	-- worse than one that occasionally over-matches.
	local lctrl = Guard.get(Enum.KeyCode, "LeftControl")
	local rctrl = Guard.get(Enum.KeyCode, "RightControl")
	out.Ctrl = (lctrl and InputManager.isDown(lctrl)) or (rctrl and InputManager.isDown(rctrl)) or false

	local lshift = Guard.get(Enum.KeyCode, "LeftShift")
	local rshift = Guard.get(Enum.KeyCode, "RightShift")
	out.Shift = (lshift and InputManager.isDown(lshift)) or (rshift and InputManager.isDown(rshift)) or false

	local lalt = Guard.get(Enum.KeyCode, "LeftAlt")
	local ralt = Guard.get(Enum.KeyCode, "RightAlt")
	out.Alt = (lalt and InputManager.isDown(lalt)) or (ralt and InputManager.isDown(ralt)) or false

	return out
end

--- A key that is itself a modifier has to be excused from the modifier check when it is the
--- trigger, or the classic `ToggleKey = RightControl` could never fire: holding the right control
--- key down is exactly what makes `GetModifiersState().Ctrl` read true.
local MODIFIER_KEYS = {
	Ctrl = { LeftControl = true, RightControl = true },
	Shift = { LeftShift = true, RightShift = true },
	Alt = { LeftAlt = true, RightAlt = true },
	Meta = { LeftMeta = true, RightMeta = true },
}

local function effectiveMods(mods: {[string]: boolean}, trigger: any): {[string]: boolean}
	local name = trigger ~= nil and inputName(trigger) or nil
	if name == nil then
		return mods
	end

	local out = {}
	for key, down in pairs(mods) do
		local family = MODIFIER_KEYS[key]
		out[key] = down == true and (family == nil or family[name] ~= true)
	end
	return out
end

--- Match a requested modifier set against what is down. Keys are compared case-insensitively and
--- Left/Right variants collapse, so a config written as { Ctrl = true } works.
local function modifiersMatch(requested: {[string]: boolean}?, mods: {[string]: boolean}): boolean
	if requested == nil or next(requested) == nil then
		-- A bare bind must not fire while a modifier is held: Ctrl+S reaching a "S" bind would
		-- fight the browser-style save the user expects.
		return not (mods.Ctrl or mods.Shift or mods.Alt or mods.Meta)
	end

	-- The names a caller may ask for are normalised by InputManager.modifiers(), so Ctrl matches
	-- either control key. Mods the caller did not list are not checked: a Shift+G bind still fires
	-- with Ctrl held, which is the least surprising rule once a config file is hand-written.
	for name, wanted in pairs(requested) do
		if wanted ~= (mods[name] == true) then
			return false
		end
	end
	return true
end

--- Poll the engine for a key or mouse button.
function InputManager.isDown(input: any): boolean
	local resolved = resolve(input)
	if resolved == nil then
		return false
	end
	if UserInputService == nil then
		return false
	end
	local ok, down = pcall(function()
		return UserInputService:IsKeyDown(resolved)
	end)
	if ok then
		return down == true
	end
	return false
end

--- A released binding is a table with these fields; every method is safe to call twice.
local handle = {}
handle.__index = handle

function handle.Set(self: any, input: any, mods: {[string]: boolean}?)
	local resolved = resolve(input)
	if resolved == nil then
		warn("[Flux] input: cannot bind " .. tostring(input))
		return false
	end
	self.input = resolved
	self.mods = mods
	held[self] = false
	InputManager.Changed:Dispatch(self)
	return true
end

function handle.GetInput(self: any): any
	return self.input
end

--- The text a keybind row shows.
function handle.GetLabel(self: any): string
	if self.input == nil then
		return "Unbound"
	end
	local base = String.keyName(self.input)
	if self.mods == nil or next(self.mods) == nil then
		return base
	end

	local parts = {}
	for _, name in ipairs({ "Ctrl", "Shift", "Alt" }) do
		if self.mods[name] then
			table.insert(parts, name)
		end
	end
	table.insert(parts, base)
	return table.concat(parts, " + ")
end

--- True while the key is physically down. A hold-style feature reads this each frame.
function handle.GetState(self: any): boolean
	if self.input == nil then
		return false
	end
	if not InputManager.isDown(self.input) then
		return false
	end
	return modifiersMatch(self.mods, effectiveMods(InputManager.modifiers(), self.input))
end

function handle.IsHeld(self: any): boolean
	return held[self] == true
end

--- Force the binding off. Called when the feature it gates is switched off, so a key held across
--- the toggle does not leave the effect running.
function handle.Release(self: any)
	if held[self] then
		held[self] = false
		if self.onUp ~= nil then
			self.onUp(self)
		end
	end
end

function handle.Destroy(self: any)
	if self.destroyed then
		return
	end
	self.destroyed = true
	held[self] = nil

	for index = #bindings, 1, -1 do
		if bindings[index] == self then
			table.remove(bindings, index)
		end
	end
end

--- Register a keybind.
---   Key     — Enum.KeyCode / Enum.UserInputType member, its name, or a restored config table.
---   OnDown / OnUp / Callback — Callback fires on press for a toggle bind, and on both edges for
---           a hold bind (so the caller can drive either style from one registration).
---   Mode    — "toggle" (default) or "hold".
function InputManager.bind(options: {
	Name: string?,
	Key: any,
	Mods: {[string]: boolean}?,
	Mode: string?,
	Callback: ((boolean) -> ())?,
	OnDown: ((any) -> ())?,
	OnUp: ((any) -> ())?,
	AllowWhileTyping: boolean?,
}): any
	local input = resolve(options.Key)

	local binding = setmetatable({
		name = options.Name or "bind",
		mode = options.Mode or "toggle",
		input = input,
		mods = options.Mods,
		callback = options.Callback,
		onDown = options.OnDown,
		onUp = options.OnUp,
		allowWhileTyping = options.AllowWhileTyping == true,
		enabled = true,
	}, handle)

	InputManager.listen()
	table.insert(bindings, binding)
	return binding
end

function InputManager.list(): {any}
	return Table.copy(bindings)
end

--- How many bindings currently point at this key, which is what a conflict warning counts.
function InputManager.conflictsFor(input: any): {any}
	local resolved = resolve(input)
	local out = {}
	if resolved == nil then
		return out
	end
	for _, binding in ipairs(bindings) do
		if not binding.destroyed and binding.input == resolved then
			table.insert(out, binding)
		end
	end
	return out
end

--- Release every held binding without unregistering them: the window hid, the game lost focus.
function InputManager.releaseAll(reason: string?)
	for _, binding in ipairs(Table.copy(bindings)) do
		if not binding.destroyed then
			binding:Release()
		end
	end
	return reason
end

function InputManager.clear()
	for index = #bindings, 1, -1 do
		bindings[index]:Destroy()
	end
	table.clear(bindings)
end

local function focused(): boolean
	if UserInputService == nil then
		return false
	end
	local ok, box = pcall(function()
		return UserInputService:GetFocusedTextBox()
	end)
	return ok and box ~= nil
end

--- One capture session per picker. Resolves with { Input, Mods, Cancelled }.
function InputManager.capture(options: { OnCancel: (() -> ())?, ClearOnDelete: boolean?, Timeout: number? }): any
	local result = Signal.new()

	local session = { finished = false, options = options or {} }

	local function finish(payload: {[string]: any})
		if session.finished then
			return
		end
		session.finished = true

		if session.inputConnection ~= nil then
			session.inputConnection:Disconnect()
		end
		if session.endedConnection ~= nil then
			session.endedConnection:Disconnect()
		end
		if session.thread ~= nil then
			task.cancel(session.thread)
		end

		for index = #captureSessions, 1, -1 do
			if captureSessions[index] == session then
				table.remove(captureSessions, index)
			end
		end

		if payload.cancelled and options ~= nil and options.OnCancel ~= nil then
			options.OnCancel()
		end
		result:Dispatch(payload)
	end

	table.insert(captureSessions, session)

	if UserInputService == nil or #captureSessions > 1 then
		-- Two pickers open at once is not a thing in this UI, and a client without the input
		-- service cannot capture at all. Fail the session rather than hang the picker: a session
		-- with no listener behind it has no way to end on its own.
		if UserInputService == nil then
			task.defer(finish, { cancelled = true, blocked = "no-input-service" })
		else
			task.defer(finish, { cancelled = true, blocked = "another-session" })
		end
		return {
			Done = result,
			Cancel = function()
				finish({ cancelled = true })
			end,
		}
	end

	session.inputConnection = UserInputService.InputBegan:Connect(function(input, processed)
		if session.finished then
			return
		end

		local name = inputName(input)

		if name == "Escape" then
			finish({ cancelled = true })
			return
		end

		if name == "Backspace" or name == "Delete" then
			if session.options.ClearOnDelete ~= false then
				finish({ cleared = true })
			end
			return
		end

		-- A mouse button is a legitimate bind even when the click also hit UI, so `processed`
		-- only filters keys the game already consumed through a TextBox.
		local code = Guard.get(input, "KeyCode")
		if processed and code ~= nil and code ~= Enum.KeyCode.Unknown then
			return
		end

		if InputManager.forbidden[name] then
			return
		end

		if focused() then
			return
		end

		-- Hand back the Enum member, not the UserInput object: the payload goes straight into
		-- handle.Set, which stores what resolve() can turn back into a trigger later.
		local trigger = code ~= nil and code ~= Enum.KeyCode.Unknown and code or Guard.get(input, "UserInputType")
		finish({ input = trigger, mods = effectiveMods(InputManager.modifiers(), trigger) })
	end)

	if type(session.options.Timeout) == "number" then
		session.thread = task.delay(session.options.Timeout, function()
			finish({ cancelled = true, timedOut = true })
		end)
	end

	return {
		Done = result,
		Cancel = function()
			finish({ cancelled = true })
		end,
	}
end

--- Any open capture sessions, for tests and for the picker's own "is someone else listening" check.
function InputManager.capturing(): number
	return #captureSessions
end

--- Install the engine listeners. Idempotent, and called by `bind` as well as at load: `unload`
--- disconnects these, and a host that runs the loader again after `Flux:Unload()` expects its
--- hotkeys to work in the new hub without restarting the client.
function InputManager.listen()
	if UserInputService == nil or #connections > 0 then
		return false
	end

	connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end

		-- A key the game already consumed (typing in a TextBox) only reaches bindings that asked
		-- for it, which is what AllowWhileTyping is for.
		local typing = focused()
		local mods = InputManager.modifiers()
		for _, binding in ipairs(bindings) do
			if not binding.destroyed and binding.enabled and matchesInput(binding, input)
				and modifiersMatch(binding.mods, effectiveMods(mods, binding.input))
				and (binding.allowWhileTyping or not typing) then
				if not held[binding] then
					held[binding] = true
					if binding.mode == "hold" then
						if binding.onDown ~= nil then
							binding.onDown(binding)
						end
						if binding.callback ~= nil then
							binding.callback(true)
						end
					else
						if binding.callback ~= nil then
							binding.callback(true)
						end
						if binding.onDown ~= nil then
							binding.onDown(binding)
						end
					end
				end
			end
		end
	end)

	connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input)
		for _, binding in ipairs(bindings) do
			if not binding.destroyed and matchesInput(binding, input) and held[binding] then
				held[binding] = false
				if binding.mode == "hold" then
					if binding.onUp ~= nil then
						binding.onUp(binding)
					end
					if binding.callback ~= nil then
						binding.callback(false)
					end
				end
			end
		end
	end)

	-- Focus loss is the case InputEnded misses: alt-tab with a hold key down and the engine never
	-- reports the release.
	local blur = Guard.get(UserInputService, "WindowFocusReleased")
	if blur ~= nil then
		connections[#connections + 1] = blur:Connect(function()
			InputManager.releaseAll("focus")
		end)
	end

	return true
end

InputManager.listen()

function InputManager.connections(): number
	return #connections
end

--- Tear down the engine listeners. Only used by the hub's own unload.
function InputManager.unload()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	InputManager.clear()
end

return InputManager
