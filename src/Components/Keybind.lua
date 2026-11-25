--[[
	Components/Keybind — a rebindable key row built entirely on Systems/InputManager.

	The row owns no input hooks of its own: every trigger goes through one InputManager binding,
	so chords, the typed-TextBox filter, auto-repeat latching and focus-loss release behave exactly
	like the binds a host registers itself. Clicking the row opens the manager's capture session
	(Escape cancels, Delete clears per the session's own ClearOnDelete rule), and the resolved
	payload — an Enum member plus the modifier set at the moment of the press — is written back
	through the binding's own Set.

	Hold rows are pulled, not pushed. The manager only reports a falling edge when the engine
	surfaces InputEnded, and that edge is missing whenever the window loses focus with the key
	down — so a hold row registers its binding *without* a callback and reads `GetState()` from
	ONE shared RenderStepped pass that serves every keybind row in the hub. A hub with sixty
	keybinds costs one connection and sixty polls per frame, never sixty coroutines.

	Toggle rows are the opposite: the pushed rising edge is exactly the semantics wanted, so the
	binding's Callback forwards straight to the host. Neither style ever calls the host callback
	because a bind was (re)set — capture, Set and a config restore change the trigger, not the
	feature state.

	The config value is a plain string ("Q", "Shift+K", "MouseButton2") — never a UserInput object,
	never an Enum member — so a file written today decodes tomorrow, and restoring hands the name
	back to the manager, which is the only place enum resolution lives.
]]

local Element = require("Flux/Core/Element")
local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local Signal = require("Flux/Utilities/Signal")
local String = require("Flux/Utilities/String")
local ThemeManager = require("Flux/Systems/ThemeManager")
local InputManager = require("Flux/Systems/InputManager")

local RunService = Guard.service("RunService")

local Keybind = {}

local CHIP_W = 74
local CHIP_H = 24

-- The row's whole UI budget stays inside the library's 25-instance ceiling (spec 14 counts it).

--[[ shared hold loop ------------------------------------------------------------

	One RenderStepped connection for every keybind row, opened with the first hold row and
	closed again when the last one is destroyed — the same lifecycle LayoutManager uses for its
	poll. `frames` counts passes so a spec can prove N rows cost one poll per frame, not N
	connections each firing their own callback. ]]

local pollers: {any} = {}
local pollConnection = nil
local frames = 0

local function runFrame()
	frames += 1
	local index = 1
	while index <= #pollers do
		local row = pollers[index]
		if row.Destroyed then
			-- A destroyed row drops itself even if Destroy's removal was missed (a row torn
			-- down from inside another row's callback, for instance).
			table.remove(pollers, index)
		else
			local down = row._binding ~= nil and row._binding:GetState() or false
			if down ~= row._lastState then
				row._lastState = down
				row._edge(down)
			end
			index += 1
		end
	end
end

local function addPoller(row: any)
	for _, existing in ipairs(pollers) do
		if existing == row then
			return
		end
	end
	table.insert(pollers, row)
	if pollConnection == nil and RunService ~= nil then
		pollConnection = RunService.RenderStepped:Connect(runFrame)
	end
end

local function removePoller(row: any)
	for index = #pollers, 1, -1 do
		if pollers[index] == row then
			table.remove(pollers, index)
		end
	end
	if #pollers == 0 and pollConnection ~= nil then
		pollConnection:Disconnect()
		pollConnection = nil
	end
end

--- How many hold rows the shared frame loop is currently polling.
function Keybind.pollerCount(): number
	return #pollers
end

--- Whether the shared RenderStepped connection is live.
function Keybind.loopRunning(): boolean
	return pollConnection ~= nil
end

--- Frame passes so far, so a spec can show the loop runs ONCE per frame for any row count.
function Keybind.pollFrames(): number
	return frames
end

--[[ trigger parsing --------------------------------------------------------------

	Displayed short names are accepted back as input (String.keyName prints MB2, the row must
	take "MB2"), and full Left/Right modifier spellings collapse onto the manager's three
	modifier tokens. A bare bind stores the plain enum name; chords store "Shift+K" style.
	Empty tokens are malformed ("+K", "Shift+") and rejected rather than bound to nothing; a
	whitespace-only value means "clear the bind". ]]

local MOD_ORDER = { "Ctrl", "Shift", "Alt" }
local MOD_ALIASES = {
	ctrl = "Ctrl", control = "Ctrl", leftcontrol = "Ctrl", rightcontrol = "Ctrl",
	shift = "Shift", leftshift = "Shift", rightshift = "Shift",
	alt = "Alt", leftalt = "Alt", rightalt = "Alt",
}
local KEY_ALIASES = {
	mb1 = "MouseButton1", mb2 = "MouseButton2", mb3 = "MouseButton3",
}
-- A lone modifier word in the key slot binds the physical left-hand key: the Enum has no
-- "Ctrl" member, so handing the bare word to the manager would store an inert trigger.
local MOD_KEY_NAMES = {
	ctrl = "LeftControl", control = "LeftControl",
	shift = "LeftShift",
	alt = "LeftAlt",
}

--- Returns (key, mods) for a bindable spelling, or (nil, nil) when it is not one. `key` is the
--- raw enum name handed to the manager's binding, `mods` the chord words folded onto the
--- manager's three modifier tokens.
local function parseString(value: string): (string?, {[string]: boolean}?)
	local tokens = {}
	for _, raw in ipairs(String.split(value, "+")) do
		local token = String.trim(raw)
		if token == "" then
			return nil, nil
		end
		table.insert(tokens, token)
	end
	if #tokens > 4 then
		return nil, nil
	end

	local mods = {}
	for index = 1, #tokens - 1 do
		local mod = MOD_ALIASES[tokens[index]:lower()]
		if mod == nil then
			return nil, nil
		end
		mods[mod] = true
	end

	-- A lone modifier word still binds *something* (the physical left key), unlike the chord
	-- prefix slot where "Shift+Shift" would be nonsense the manager could not match.
	local key = tokens[#tokens]
	local lower = key:lower()
	local alias = KEY_ALIASES[lower] or MOD_KEY_NAMES[lower]
	if alias ~= nil then
		key = alias
	end
	return key, mods
end

--- The config/display spelling: canonical modifier words first, then the raw key name.
local function serialize(key: string, mods: {[string]: boolean}?): string
	local parts = {}
	for _, mod in ipairs(MOD_ORDER) do
		if mods ~= nil and mods[mod] then
			table.insert(parts, mod)
		end
	end
	table.insert(parts, key)
	return table.concat(parts, "+")
end

--- Normalise any accepted trigger form to (stored, key, mods). Non-empty third result means
--- the value is not bindable at all and the row must keep what it had.
local function normalize(value: any): (string?, string?, {[string]: boolean}?, boolean?)
	if value == nil then
		return nil, nil, nil, nil
	end

	if type(value) == "string" then
		if String.trim(value) == "" then
			-- An empty config value is "no bind", not "a bind the row refuses to show".
			return nil, nil, nil, nil
		end
		local key, mods = parseString(value)
		if key == nil then
			return nil, nil, nil, true
		end
		return serialize(key, mods), key, mods, nil
	end

	-- A live EnumItem on a real client is userdata; the offline harness models one as a table.
	-- Both shapes are identified by their string Name, which is also what a config stores, and
	-- a restored { Name = "MouseButton1", Enum = "UserInputType" } entry carries the same Name.
	if typeof(value) == "EnumItem" or type(value) == "table" then
		local name = Guard.get(value, "Name")
		if type(name) == "string" and name ~= "" then
			local key, mods = parseString(name)
			if key ~= nil then
				return serialize(key, mods), key, mods, nil
			end
			return name, name, {}, nil
		end
	end

	return nil, nil, nil, true
end

function Keybind.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "Keybind",
		Title = nil,
		Desc = nil,
		Default = nil,
		Hold = false,
		Callback = nil,
		Flag = nil,
		ClearOnDelete = true,
		Prompt = "Press a key…",
		AllowWhileTyping = false,
	})

	local title = options.Title or options.Name
	local maid = group.Maid
	local hold = options.Hold == true

	local row = Element.row(maid, group.Content, "Keybind_" .. tostring(title), {
		Label = title,
		Desc = options.Desc,
		BodyWidth = CHIP_W,
		Order = group:RowCount() + 1,
	})

	-- A TextButton, not a Frame: an unparented or Active=false frame never reports clicks on a
	-- real client, and the chip — like Toggle's HitArea — must be clickable wherever the row is.
	local chip = Instance.new("TextButton", row.Body, {
		Name = "Chip",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(CHIP_W, CHIP_H),
		ZIndex = 7,
	})
	maid:giveFunction(function()
		chip:Destroy()
	end)
	Element.round(maid, chip, "RadiusChip")

	local chipStroke = Instance.stroke(
		chip,
		ThemeManager.color("BorderSecondary"),
		ThemeManager.metric("StrokeThickness") or 1
	)
	if chipStroke ~= nil then
		maid:giveFunction(function()
			chipStroke:Destroy()
		end)
	end

	local chipText = Element.label(maid, chip, "Text", {
		Text = "Unbound",
		Role = "TextMuted",
		Font = "Mono",
		TextSize = 11,
		Size = UDim2.new(1, -8, 1, 0),
		Position = UDim2.new(0, 4, 0, 0),
		ZIndex = 8,
	})

	-- The whole row opens the capture, not just the 74px chip: on the reference layout the chip
	-- is a read-out, and hunting it with a thumb on a phone is the usual complaint. The hit
	-- layer sits above the chip (Toggle's row does the same) — both buttons call the same
	-- latched beginCapture, so a client that delivers the click to either gets identical state.
	local hit = Instance.new("TextButton", row.Root, {
		Name = "HitArea",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 9,
		BorderSizePixel = 0,
	})
	maid:giveFunction(function()
		hit:Destroy()
	end)

	local self = {
		Instance = row.Root,
		Title = title,
		Changed = Signal.new(),
		Hold = hold,
		_value = nil,
		_binding = nil,
		_capturing = false,
		_session = nil,
		_lastState = false,
		_callback = options.Callback,
		_maid = maid,
		_group = group,
		_flag = options.Flag,
		_row = row,
	}

	local function paint()
		-- Idle and capture differ in text and role through Element.tint, so a theme swap while
		-- a capture is open repaints onto the capture roles, not the resting palette.
		if self._capturing then
			chipText.Text = tostring(options.Prompt)
			Element.tint(maid, chipText, "TextColor3", "Accent")
			if chipStroke ~= nil then
				Element.tint(maid, chipStroke, "Color", "Accent")
			end
			Element.tint(maid, chip, "BackgroundColor3", "Selection")
		else
			chipText.Text = self._binding ~= nil and self._binding:GetLabel() or "Unbound"
			if self._value == nil then
				Element.tint(maid, chipText, "TextColor3", "TextMuted")
			else
				Element.tint(maid, chipText, "TextColor3", "TextSecondary")
			end
			if chipStroke ~= nil then
				Element.tint(maid, chipStroke, "Color", "BorderSecondary")
			end
			Element.tint(maid, chip, "BackgroundColor3", "Field")
		end
	end

	local function runCallback(state: boolean)
		if self._callback == nil then
			return
		end
		local ok, err = pcall(self._callback, state)
		if not ok then
			warn("[Flux] keybind '" .. tostring(title) .. "': " .. tostring(err))
		end
	end

	-- The frame loop's only per-row work: hand a polled edge to the host. Toggle rows never
	-- enter it; their edges arrive pushed through the manager's own Callback.
	self._edge = function(state: boolean)
		if not self.Destroyed then
			runCallback(state)
		end
	end

	--- Rebuild the manager binding for the current trigger. Destroy-and-replace rather than
	--- handle.Set because clearing must also drop the manager's `held` latch: a handle has no
	--- way to forget its input, and a stale one would keep matching presses.
	local function attach(key: string?, mods: {[string]: boolean}?)
		if self._binding ~= nil then
			self._binding:Destroy()
		end
		local spec = {
			Name = self._flag or tostring(title),
			Mode = hold and "hold" or "toggle",
			AllowWhileTyping = options.AllowWhileTyping == true,
		}
		-- A hold bind is registered *without* a Callback on purpose: the manager's pushed
		-- edges and the frame loop's polled ones would otherwise double-fire the host
		-- (spec 14 counts the calls). `and nil or` would not express that — `true and nil`
		-- falls through to the function — so the field is set only for the toggle mode.
		if not hold then
			spec.Callback = function(state)
				if not self.Destroyed then
					runCallback(state)
				end
			end
		end
		self._binding = InputManager.bind(spec)
		if key ~= nil then
			self._binding:Set(key, mods)
		end
		self._lastState = false
	end

	local function apply(stored: string?, key: string?, mods: {[string]: boolean}?, silent: boolean?): boolean
		if stored == self._value then
			return true
		end
		self._value = stored
		attach(key, mods)
		paint()
		if not silent then
			Element.pushConfig(self._flag, self._value)
			self.Changed:Dispatch(self._value)
		end
		return true
	end

	local function setTrigger(value: any, silent: boolean?): boolean
		if self.Destroyed then
			return false
		end
		local stored, key, mods, rejected = normalize(value)
		if rejected then
			-- A trigger this client cannot resolve never lands: the row keeps its old bind
			-- rather than showing a key it will not react to.
			return false
		end
		return apply(stored, key, mods, silent)
	end

	local function endCapture()
		if not self._capturing then
			return
		end
		self._capturing = false
		self._session = nil
		paint()
	end

	local function beginCapture()
		if self.Destroyed or self._capturing then
			return self
		end
		self._capturing = true
		paint()

		local session = InputManager.capture({
			ClearOnDelete = options.ClearOnDelete,
			OnCancel = endCapture,
		})
		self._session = session
		session.Done:Connect(function(payload: {[string]: any}?)
			if payload == nil then
				return
			end
			if payload.cancelled then
				-- Escape, a timeout, or the manager refusing a second concurrent session:
				-- every cancelled path leaves the previous trigger standing, untouched.
				endCapture()
				return
			end
			if payload.cleared then
				endCapture()
				setTrigger(nil)
				return
			end
			if payload.input ~= nil then
				-- Rebuild the stored spelling from the resolved Enum member plus the modifier
				-- snapshot the manager took at the moment of the press: capture is the only
				-- path that can produce a chord, so the chord words are written from
				-- payload.mods directly rather than re-read from the keyboard.
				local capturedStored, capturedKey = normalize(payload.input)
				local names = {}
				local mods = {}
				if payload.mods ~= nil then
					for _, mod in ipairs(MOD_ORDER) do
						if payload.mods[mod] == true then
							table.insert(names, mod)
							mods[mod] = true
						end
					end
				end
				if capturedKey ~= nil then
					table.insert(names, capturedStored)
					endCapture()
					apply(table.concat(names, "+"), capturedKey, mods)
				else
					endCapture()
				end
			end
		end)
		return self
	end

	chip.MouseButton1Click:Connect(function()
		beginCapture()
	end)
	hit.MouseButton1Click:Connect(function()
		beginCapture()
	end)

	-- Methods live on the table as fields while hosts call them with a colon; accept both, the
	-- way Slider and Dropdown do.
	local function recv(a: any, b: any): any
		if a == self then
			return b
		end
		return a
	end

	self.Set = function(a: any, b: any)
		if self._capturing then
			-- A programmatic rebind closes an open capture: the picker would otherwise resolve
			-- later and overwrite the trigger the host just wrote.
			if self._session ~= nil then
				self._session.Cancel()
			end
			endCapture()
		end
		local value = recv(a, b)
		if not setTrigger(value) then
			return false
		end
		return self
	end

	self.Clear = function(a: any, b: any)
		setTrigger(nil)
		return self
	end

	self.GetValue = function()
		return self._value
	end

	self.GetTrigger = function()
		return self._value
	end

	self.GetLabel = function()
		if self._binding ~= nil then
			return self._binding:GetLabel()
		end
		return "Unbound"
	end

	self.GetBinding = function()
		return self._binding
	end

	--- Live "is the key down right now" poll, straight through to the manager (chord included).
	self.GetState = function()
		if self._binding == nil then
			return false
		end
		return self._binding:GetState()
	end

	self.IsCapturing = function()
		return self._capturing
	end

	self.StartCapture = function(a: any, b: any)
		beginCapture()
		return self
	end

	self.CancelCapture = function(a: any, b: any)
		if self._session ~= nil then
			self._session.Cancel()
		end
		endCapture()
		return self
	end

	self.SetCallback = function(a: any, b: any)
		self._callback = recv(a, b)
		return self
	end

	self.SetText = function(a: any, b: any)
		self.Title = tostring(recv(a, b))
		row.Title.Text = self.Title
		return self
	end
	self.SetTitle = self.SetText

	self.SetVisible = function(a: any, b: any)
		row.Root.Visible = recv(a, b) == true
		return self
	end

	self.OnFilter = function(a: any, b: any)
		local matched = recv(a, b)
		if matched ~= true then
			self:CancelCapture()
		end
		row.Root.Visible = matched == true
	end

	self.Destroy = function()
		if self.Destroyed then
			return
		end
		if self._session ~= nil then
			self._session.Cancel()
		end
		endCapture()
		self.Destroyed = true
		removePoller(self)
		if self._binding ~= nil then
			self._binding:Destroy()
			self._binding = nil
		end
		self.Changed:Destroy()
		Element.releaseSearch(group, self)
		row.Root:Destroy()
	end

	-- The default trigger is staged, not pushed: bindConfig below applies a restored value on
	-- top of it, and pushing now would stamp the default over a config that was just loaded.
	local defaultStored, defaultKey, defaultMods, defaultRejected = normalize(options.Default)
	if defaultRejected then
		warn("[Flux] keybind '" .. tostring(title) .. "': default " .. tostring(options.Default) .. " is not bindable")
	end
	self._value = defaultStored
	attach(defaultKey, defaultMods)
	if hold then
		addPoller(self)
	end
	paint()

	-- Restoring is silent all the way down: a load pushes every flag at once, and a hub that
	-- rebuilds on Changed would thrash forty times for one file read. No callback either.
	Element.bindConfig(maid, self._flag, function(value)
		if not self.Destroyed then
			setTrigger(value, true)
		end
	end, function()
		return self._value
	end)

	self.SearchId = Element.searchable(group, self, tostring(title), options.Desc)
	Guard.set(row.Root, "LayoutOrder", group:RowCount())
	return self
end

return Keybind
