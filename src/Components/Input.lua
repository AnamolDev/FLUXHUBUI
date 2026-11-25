--[[
	Components/Input — a labelled text field.

	Commit happens on both FocusLost and Return, and the two paths must collapse into one
	callback: on a real client Return releases focus, so an unguarded implementation fires twice
	per Enter press. A `_dirty` latch set by user keystrokes makes the second commit a no-op
	while still committing a value the engine's own focus release hands over.

	Numeric filtering runs inside `GetPropertyChangedSignal("Text")` rather than on commit, so
	a pasted "1e5 apples" never reaches the label; the rewrite re-enters the same signal, which
	is why the filter is wrapped in a re-entry guard instead of a plain assignment. The empty
	string is allowed through — a field mid-edit is not a field holding zero.

	Restore from config runs the identical coercion as a typed commit: a file edited by hand to
	`"vol": "900"` clamps to Max exactly like typing 900 would, instead of showing a value the
	slider next to it refuses to accept.
]]

local Element = require("Flux/Core/Element")
local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local Math = require("Flux/Utilities/Math")
local Signal = require("Flux/Utilities/Signal")
local ThemeManager = require("Flux/Systems/ThemeManager")

local UserInputService = Guard.service("UserInputService")

local Input = {}

local BODY_W = 170
local FIELD_H = 24
local MULTI_H = 64

function Input.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "Input",
		Title = nil,
		Desc = nil,
		Default = "",
		Placeholder = "",
		Callback = nil,
		OnChanged = nil,
		Flag = nil,
		Numeric = false,
		Min = nil,
		Max = nil,
		LengthLimit = 0,
		Multi = false,
		Height = nil,
	})

	local title = options.Title or options.Name
	local maid = group.Maid
	local numeric = options.Numeric == true
	local multi = options.Multi == true
	local lower = tonumber(options.Min)
	local upper = tonumber(options.Max)
	local height = tonumber(options.Height) or (multi and MULTI_H or FIELD_H)

	local row = Element.row(maid, group.Content, "Input_" .. tostring(title), {
		Label = title,
		Desc = options.Desc,
		BodyWidth = BODY_W,
		Height = multi and height + 14 or nil,
		Order = group:RowCount() + 1,
	})

	local field = Element.panel(maid, row.Body, "Field", {
		Color = "Field",
		Radius = "RadiusField",
		Size = UDim2.fromOffset(BODY_W, height),
		Stroke = "BorderSecondary",
		ZIndex = 6,
	})

	local box = Instance.new("TextBox", field, {
		Name = "Box",
		Text = "",
		PlaceholderText = tostring(options.Placeholder or ""),
		BackgroundTransparency = 1,
		TextColor3 = ThemeManager.color("TextPrimary"),
		Font = ThemeManager.font(numeric and "Mono" or "Body"),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = multi,
		MultiLine = multi,
		ClearTextOnFocus = false,
		Size = UDim2.new(1, -10, 1, 0),
		Position = UDim2.new(0, 5, 0, 0),
		BorderSizePixel = 0,
		ZIndex = 7,
	})
	maid:giveFunction(function()
		box:Destroy()
	end)
	maid:give(ThemeManager.bind(box, "TextColor3", "TextPrimary"))
	if multi then
		-- AutomaticSize would shrink a wrapped box to one line's height and clip the rest of
		-- the paragraph, so multi-line fields opt out of it explicitly.
		box.AutomaticSize = Enum.AutomaticSize.None
		box.TextYAlignment = Enum.TextYAlignment.Top
	end
	if type(options.LengthLimit) == "number" and options.LengthLimit > 0 then
		box.MaxLength = math.floor(options.LengthLimit)
	end
	Guard.set(box, "CaretColor", ThemeManager.color("Accent"))

	local self = {
		Instance = row.Root,
		Title = title,
		Changed = Signal.new(),
		_value = "",
		_callback = options.Callback,
		_onChanged = options.OnChanged,
		_group = group,
		_flag = options.Flag,
		_row = row,
		_dirty = false,
	}

	-- Set while the component itself rewrites box.Text (numeric filtering, clamp coercion) so
	-- the keystroke listener can tell a programmatic write from the user typing.
	local internal = false
	-- Held off until after bindConfig: staging the declared default into the store before the
	-- restore runs would overwrite a loaded config the same way a push-on-build slider would.
	local canPush = false

	local function coerce(raw: any): string
		local text = tostring(raw == nil and "" or raw)
		if numeric then
			local cleaned = ""
			for index = 1, #text do
				local char = text:sub(index, index)
				if char:match("%d") or char == "-" or char == "." then
					cleaned = cleaned .. char
				end
			end
			text = cleaned
		end
		return text
	end

	local function clampNumber(text: string): (string, number?)
		local parsed = tonumber(text)
		if parsed == nil then
			return text, nil
		end
		if lower ~= nil then
			parsed = math.max(parsed, lower)
		end
		if upper ~= nil then
			parsed = math.min(parsed, upper)
		end
		return tostring(parsed), parsed
	end

	local function writeText(text: string)
		internal = true
		box.Text = coerce(text)
		internal = false
	end

	local function apply(rawValue: any, fromUser: boolean)
		local text = coerce(rawValue)
		local value: any = text
		if numeric then
			local coerced, parsed = clampNumber(text)
			if parsed == nil then
				-- An unparseable number is not zero: revert to the last value the field owned
				-- rather than quietly saving 0 over whatever the user meant to erase.
				value = self._value
				writeText(self._value)
			else
				value = parsed
				if coerced ~= text then
					writeText(coerced)
				end
			end
		end

		local changed = value ~= self._value
		self._value = value
		if changed then
			if canPush then
				Element.pushConfig(self._flag, value)
			end
			self.Changed:Dispatch(value)
		end
		if fromUser and changed and self._callback ~= nil then
			local ok, err = pcall(self._callback, value)
			if not ok then
				warn("[Flux] input '" .. tostring(title) .. "': " .. tostring(err))
			end
		end
		return value
	end

	local textChanged = Guard.get(box, "GetPropertyChangedSignal")
	if textChanged ~= nil then
		maid:giveConnection(textChanged(box, "Text"):Connect(function()
			if internal or self.Destroyed then
				return
			end
			-- Rewriting Text from inside this handler re-enters it, so the guard is set before
			-- the filtered write and cleared after.
			local filtered = coerce(box.Text)
			if filtered ~= box.Text then
				internal = true
				box.Text = filtered
				internal = false
			end
			self._dirty = true
			if self._onChanged ~= nil then
				local ok, err = pcall(self._onChanged, filtered)
				if not ok then
					warn("[Flux] input '" .. tostring(title) .. "': " .. tostring(err))
				end
			end
		end))
	end

	local function commit()
		if self.Destroyed or not self._dirty then
			return
		end
		self._dirty = false
		apply(box.Text, true)
	end

	local focusLost = Guard.get(box, "FocusLost")
	if focusLost ~= nil then
		maid:giveConnection(focusLost:Connect(function(_enter: boolean)
			commit()
		end))
	end

	local beganSignal = UserInputService ~= nil and Guard.get(UserInputService, "InputBegan") or nil
	if beganSignal ~= nil then
		maid:giveConnection(beganSignal:Connect(function(input)
			if self.Destroyed or not self._dirty then
				return
			end
			if Guard.get(input, "KeyCode") ~= Enum.KeyCode.Return then
				return
			end
			local getter = Guard.get(UserInputService, "GetFocusedTextBox")
			if getter ~= nil then
				local ok, focused = pcall(function()
					return UserInputService:GetFocusedTextBox()
				end)
				if not ok or focused ~= box then
					return
				end
			end
			commit()
			local release = Guard.get(box, "ReleaseFocus")
			if release ~= nil then
				pcall(function()
					box:ReleaseFocus()
				end)
			end
		end))
	end

	-- Methods live on the table as fields (the internal style of this library) while hosts call
	-- them with a colon. Accept both: when the first argument is the widget itself, the real
	-- argument is the one behind it.
	local function recv(a: any, b: any): any
		if a == self then
			return b
		end
		return a
	end

	self.Set = function(a: any, b: any)
		if self.Destroyed then
			return self
		end
		local value = recv(a, b)
		writeText(value)
		apply(box.Text, false)
		return self
	end

	self.SetValue = self.Set

	self.GetText = function()
		return box.Text
	end

	self.GetValue = function()
		return self._value
	end

	self.Focus = function()
		local capture = Guard.get(box, "CaptureFocus")
		if capture ~= nil then
			pcall(function()
				box:CaptureFocus()
			end)
		end
		return self
	end

	self.Blur = function()
		local release = Guard.get(box, "ReleaseFocus")
		if release ~= nil then
			pcall(function()
				box:ReleaseFocus()
			end)
		end
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
		row.Root.Visible = recv(a, b) == true
	end

	self.Destroy = function()
		if self.Destroyed then
			return
		end
		self.Destroyed = true
		self.Changed:Destroy()
		Element.releaseSearch(group, self)
		row.Root:Destroy()
	end

	writeText(options.Default)
	self._value = apply(box.Text, false)

	Element.bindConfig(maid, self._flag, function(value)
		if not self.Destroyed then
			writeText(value)
			apply(box.Text, false)
		end
	end, function()
		return self._value
	end)
	canPush = true

	self.SearchId = Element.searchable(group, self, tostring(title), options.Desc)
	Guard.set(row.Root, "LayoutOrder", group:RowCount())
	return self
end

return Input
