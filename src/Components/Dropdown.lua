--[[
	Components/Dropdown — a labelled picker over a list of choices.

	The list closes on an outside click and never on focus loss. Focus leaves a widget on
	*mouse-down*, so a FocusLost-driven close would collapse the list between the press and the
	release and the first click on every row would miss. `Element.outsideClick` sees the same
	mouse-down, which is why the watcher is anchored to the row and the row grows by the list's
	height while open: a click on a row must read as inside the watched rectangle.

	Choice rows are built on open, not at declaration — a hub with six profile dropdowns of forty
	configs each is two hundred and forty instances no one looks at until a list is clicked. The
	module keeps one list of open dropdowns so opening the second closes the first, the way every
	desktop combo box behaves.

	Entries accept plain strings or { Label, Value, Disabled } records; the stored value is what
	the callback and the config see, while the label is display-only, so renaming an option cannot
	orphan a saved profile.
]]

local Element = require("Flux/Core/Element")
local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local Maid = require("Flux/Utilities/Maid")
local Signal = require("Flux/Utilities/Signal")
local ThemeManager = require("Flux/Systems/ThemeManager")
local Icons = require("Flux/Systems/IconManager")

local Dropdown = {}

local BODY_W = 150
local BUTTON_H = 26
local OPTION_H = 22
local POPUP_GAP = 4

--- Open dropdowns, module-wide. Kept here rather than on a manager because closing is a one-line
--- call on the widget itself — a system for it would only exist to hold this list.
local openOnes: {any} = {}

local glyph: string? = nil
local function chevronName(): string?
	if glyph == nil then
		for _, name in ipairs({ "caret", "chevronDown", "bullet" }) do
			if Icons.has(name) then
				glyph = name
				break
			end
		end
		if glyph == nil then
			glyph = false :: any
		end
	end
	return glyph
end

local function normalize(source: {any}?): {{label: string, value: any, disabled: boolean}}
	local out = {}
	for _, item in ipairs(source or {}) do
		if type(item) == "table" then
			local value = item.Value
			if value == nil then
				value = item.Label
			end
			table.insert(out, { label = tostring(item.Label or value), value = value, disabled = item.Disabled == true })
		elseif item ~= nil then
			table.insert(out, { label = tostring(item), value = item, disabled = false })
		end
	end
	return out
end

function Dropdown.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "Dropdown",
		Title = nil,
		Desc = nil,
		Default = nil,
		Options = {},
		Callback = nil,
		Flag = nil,
		Placeholder = "Select…",
		MaxHeight = 200,
		Searchable = false,
	})

	local title = options.Title or options.Name
	local maid = group.Maid
	local entries = normalize(options.Options)

	local row = Element.row(maid, group.Content, "Dropdown_" .. tostring(title), {
		Label = title,
		Desc = options.Desc,
		BodyWidth = BODY_W,
		Order = group:RowCount() + 1,
	})
	local baseHeight = row.Root.Size.Y.Offset

	local button = Instance.new("TextButton", row.Body, {
		Name = "Selector",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = ThemeManager.color("Field"),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(BODY_W, BUTTON_H),
		ZIndex = 6,
	})
	maid:giveFunction(function()
		button:Destroy()
	end)
	Element.round(maid, button, "RadiusField")

	local display = Element.label(maid, button, "Text", {
		Text = "",
		Role = "TextPrimary",
		TextSize = 12,
		Alignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -22, 1, 0),
		ZIndex = 7,
	})

	local chevron = nil
	local chevronGlyph = chevronName()
	if chevronGlyph ~= nil then
		chevron = Element.icon(maid, button, chevronGlyph, {
			Role = "TextSecondary",
			Size = UDim2.fromOffset(11, 11),
			Position = UDim2.new(1, -15, 0.5, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 7,
		})
	end

	local popup = Instance.new("ScrollingFrame", row.Root, {
		Name = "List",
		BackgroundColor3 = ThemeManager.color("PanelSecondary"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		Position = UDim2.new(0, 0, 0, baseHeight + 2),
		ZIndex = 40,
		ScrollingEnabled = true,
		Visible = false,
	})
	maid:giveFunction(function()
		popup:Destroy()
	end)
	popup.ClipsDescendants = true
	Element.round(maid, popup, "RadiusField", -2)
	-- CanvasPosition is only written back through Guard because older clients read the property
	-- but refuse the write, and a failed reset on open must not abort the whole dropdown.
	local popupStroke = Instance.stroke(popup, ThemeManager.color("BorderPrimary"), ThemeManager.metric("StrokeThickness") or 1)
	if popupStroke ~= nil then
		maid:giveFunction(function()
			popupStroke:Destroy()
		end)
		maid:give(ThemeManager.bind(popupStroke, "Color", "BorderPrimary"))
	end
	local popupList = Instance.new("UIListLayout", popup, {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 2),
	})
	maid:giveFunction(function()
		popupList:Destroy()
	end)
	local popupPad = Instance.pad(popup, { Top = UDim.new(0, 3), Bottom = UDim.new(0, 3), Left = UDim.new(0, 3), Right = UDim.new(0, 3) })
	maid:giveFunction(function()
		popupPad:Destroy()
	end)

	local filterBox = nil
	if options.Searchable == true then
		filterBox = Instance.new("TextBox", popup, {
			Name = "Filter",
			BackgroundTransparency = 1,
			PlaceholderText = "search",
			TextColor3 = ThemeManager.color("TextSecondary"),
			TextSize = 12,
			Size = UDim2.new(1, 0, 0, 18),
			BorderSizePixel = 0,
			ZIndex = 41,
		})
		maid:giveFunction(function()
			filterBox:Destroy()
		end)
		maid:give(ThemeManager.bind(filterBox, "TextColor3", "TextSecondary"))
	end

	local self = {
		Instance = row.Root,
		Title = title,
		Changed = Signal.new(),
		Open = false,
		_value = nil,
		_index = nil,
		_callback = options.Callback,
		_group = group,
		_flag = options.Flag,
		_row = row,
		_entries = entries,
		_rows = {},
	}
	local rowsMaid = Maid.new()
	maid:chain(rowsMaid)

	local function findEntry(raw: any): number?
		for index, entry in ipairs(entries) do
			if entry.value == raw or entry.label == tostring(raw) then
				return index
			end
		end
		-- A bare number that matches no value is an index, so `Default = 2` works on string lists.
		if type(raw) == "number" then
			local position = math.floor(raw)
			if position >= 1 and position <= #entries then
				return position
			end
		end
		return nil
	end

	local function paintDisplay()
		local index = self._index
		if index ~= nil and entries[index] ~= nil then
			display.Text = entries[index].label
			-- Placeholder and selection are the same label in different roles; tinting (rather
			-- than writing TextColor3) keeps a later theme swap on the role that is showing.
			Element.tint(maid, display, "TextColor3", "TextPrimary")
		else
			display.Text = tostring(options.Placeholder)
			Element.tint(maid, display, "TextColor3", "TextMuted")
		end
	end

	local function clearRows()
		for _, node in ipairs(popup:GetChildren()) do
			if node ~= popupList and node ~= popupPad and node ~= filterBox and not node:IsA("UIComponent") then
				node:Destroy()
			end
		end
		-- The per-row theme bindings live on a sub-maid: rows are rebuilt on every open, and
		-- handing each generation to the group's maid would grow it one entry per click.
		rowsMaid:cleanup()
		table.clear(self._rows)
	end

	local function buildRows()
		clearRows()
		local query = filterBox ~= nil and string.lower(filterBox.Text or "") or ""
		local order = 0
		local shown = 0

		for index, entry in ipairs(entries) do
			local needle = string.lower(entry.label)
			if query == "" or needle:find(query, 1, true) ~= nil then
				order += 1
				shown += 1
				local option = Instance.new("TextButton", popup, {
					Name = "Option_" .. index,
					Text = " " .. entry.label,
					AutoButtonColor = true,
					Font = ThemeManager.font("Body"),
					TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left,
					BackgroundColor3 = ThemeManager.color("AccentSoft"),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					Size = UDim2.new(1, 0, 0, OPTION_H),
					LayoutOrder = order,
					ZIndex = 41,
				})
				self._rows[#self._rows + 1] = { button = option, index = index, entry = entry }

				if entry.disabled then
					option.Active = false
					Element.tint(rowsMaid, option, "TextColor3", "TextMuted")
				else
					option.MouseButton1Click:Connect(function()
						if not self.Destroyed then
							self:_pick(index)
						end
					end)
					Element.tint(rowsMaid, option, "TextColor3", "TextPrimary")
				end
			end
		end

		if shown == 0 then
			-- An empty list still has to say so: a 0-height popup that opens and closes without a
			-- pixel of feedback reads as a broken button.
			Instance.new("TextLabel", popup, {
				Name = "Empty",
				Text = "Nothing to select",
				BackgroundTransparency = 1,
				TextColor3 = ThemeManager.color("TextMuted"),
				TextSize = 12,
				Font = ThemeManager.font("Body"),
				Size = UDim2.new(1, 0, 0, OPTION_H),
				ZIndex = 41,
			})
			shown = 1
		end

		local height = math.min(options.MaxHeight, shown * (OPTION_H + 2) + 6)
		popup.Size = UDim2.new(1, 0, 0, height)
		Guard.set(popup, "CanvasSize", UDim2.new(0, 0, 0, math.max(0, shown * (OPTION_H + 2) + 6)))
		return height
	end

	function self:_pick(index: number)
		local entry = entries[index]
		if entry == nil or entry.disabled then
			return self
		end
		local changed = self._value ~= entry.value or self._index ~= index
		self._value = entry.value
		self._index = index
		paintDisplay()
		if changed then
			Element.pushConfig(self._flag, entry.value)
			self.Changed:Dispatch(entry.value)
			if self._callback ~= nil then
				local ok, err = pcall(self._callback, entry.value)
				if not ok then
					warn("[Flux] dropdown '" .. tostring(title) .. "': " .. tostring(err))
				end
			end
		end
		self:Close()
		return self
	end

	local function setRotation(angle: number)
		if chevron ~= nil and chevron.instance ~= nil then
			Guard.set(chevron.instance, "Rotation", angle)
		end
	end

	self.Close = function()
		if not self.Open then
			return self
		end
		self.Open = false
		popup.Visible = false
		popup.Size = UDim2.new(1, 0, 0, 0)
		row.Root.Size = UDim2.new(1, 0, 0, baseHeight)
		for index = #openOnes, 1, -1 do
			if openOnes[index] == self then
				table.remove(openOnes, index)
			end
		end
		setRotation(0)
		return self
	end
	self._close = self.Close

	self.OpenList = function()
		if self.Open or self.Destroyed then
			return self
		end
		for _, other in ipairs(table.clone(openOnes)) do
			if other ~= self then
				other:_close()
			end
		end
		self.Open = true
		table.insert(openOnes, self)
		local height = buildRows()
		-- The row grows so the watched rectangle covers the list: outsideClick compares the
		-- pointer against this frame, and a row click lands below its resting bottom edge.
		row.Root.Size = UDim2.new(1, 0, 0, baseHeight + height + POPUP_GAP + 2)
		popup.Visible = true
		setRotation(90)
		return self
	end

	self.IsOpen = function()
		return self.Open
	end

	local closeWatcher = Element.outsideClick(row.Root, function()
		self:Close()
	end)

	button.MouseButton1Click:Connect(function()
		if self.Destroyed then
			return
		end
		if self.Open then
			self:Close()
		else
			self:OpenList()
		end
	end)

	if filterBox ~= nil then
		local changed = Guard.get(filterBox, "GetPropertyChangedSignal")
		if changed ~= nil then
			maid:giveConnection(changed(filterBox, "Text"):Connect(function()
				if self.Open and not self.Destroyed then
					buildRows()
				end
			end))
		end
	end

	-- Methods live on the table as fields (the internal style of this library) while hosts call
	-- them with a colon. Accept both; with two positional arguments that means shifting the
	-- whole list by one when the leading one is the widget itself.
	local function take(widget: any, a: any, b: any, c: any): (any, any)
		if widget ~= nil and a == widget then
			return b, c
		end
		return a, b
	end

	self.Set = function(a: any, b: any, c: any)
		if self.Destroyed then
			return self
		end
		local value, silent = take(self, a, b, c)
		local index = findEntry(value)
		self._index = index
		self._value = index ~= nil and entries[index].value or nil
		paintDisplay()
		if index ~= nil then
			Element.pushConfig(self._flag, self._value)
			if not silent then
				self.Changed:Dispatch(self._value)
			end
		end
		return self
	end

	self.GetValue = function()
		return self._value
	end

	self.GetOptions = function()
		local out = {}
		for _, entry in ipairs(entries) do
			table.insert(out, entry.value)
		end
		return out
	end

	self.Refresh = function(a: any, b: any)
		local newOptions = take(self, a, b, nil)
		entries = normalize(newOptions)
		self._entries = entries
		local keep = self._value
		self._index = nil
		self._value = nil
		local index = findEntry(keep)
		if index ~= nil then
			self._index = index
			self._value = entries[index].value
		end
		paintDisplay()
		if self.Open then
			buildRows()
		end
		return self
	end

	self.SetText = function(a: any, b: any)
		self.Title = tostring(take(self, a, b, nil))
		row.Title.Text = self.Title
		return self
	end
	self.SetTitle = self.SetText

	self.SetVisible = function(a: any, b: any)
		local visible = take(self, a, b, nil)
		if not visible then
			self:Close()
		end
		row.Root.Visible = visible == true
		return self
	end

	self.OnFilter = function(a: any, b: any)
		local matched = take(self, a, b, nil)
		if not matched then
			self:Close()
		end
		row.Root.Visible = matched == true
	end

	self.Destroy = function()
		if self.Destroyed then
			return
		end
		self:Close()
		self.Destroyed = true
		if closeWatcher ~= nil then
			closeWatcher()
		end
		self.Changed:Destroy()
		Element.releaseSearch(group, self)
		row.Root:Destroy()
	end

	-- Staged directly instead of through Set: pushing the default into the config store before
	-- bindConfig runs would clobber the value a loaded config restored moments earlier.
	local initial = findEntry(options.Default)
	self._index = initial
	self._value = initial ~= nil and entries[initial].value or nil
	paintDisplay()
	Element.bindConfig(maid, self._flag, function(value)
		if not self.Destroyed then
			self:Set(value, true)
		end
	end, function()
		return self._value
	end)

	self.SearchId = Element.searchable(group, self, tostring(title), options.Desc)
	Guard.set(row.Root, "LayoutOrder", group:RowCount())
	return self
end

return Dropdown
