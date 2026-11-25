--[[
	Components/Checkbox — a square check row.

	The pill `Toggle` says "a live feature is running"; a checkbox reads as a configuration
	mark, and hosts want both shapes in the same page. Same anatomy as the toggle, different
	artwork: a small radius-chip box with the `check` glyph inside, accent border and fill when
	on, quiet field fill when off. No new chrome, no new tokens.

	The state machine is the toggle's verbatim, because it is the contract every row follows:
	the value lives on the widget (so `Set` is safe before the tab mounts), `Set` is silent to
	the callback and only a user click commits, the store is staged through `Element.pushConfig`
	only on a real change, and `Destroy` is idempotent.
]]

local Element = require("Flux/Core/Element")
local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local Signal = require("Flux/Utilities/Signal")
local TooltipManager = require("Flux/Systems/TooltipManager")

local Checkbox = {}

local BOX = 18
local GLYPH = 12

function Checkbox.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "Checkbox",
		Title = nil,
		Desc = nil,
		Default = false,
		Callback = nil,
		Flag = nil,
		Icon = nil,
	})

	local title = options.Title or options.Name
	local maid = group.Maid
	local row = Element.row(maid, group.Content, "Checkbox_" .. tostring(title), {
		Label = title,
		Desc = options.Desc,
		BodyWidth = BOX + 8,
		Order = group:RowCount() + 1,
	})

	local box = Element.panel(maid, row.Body, "Box", {
		Color = "Field",
		Radius = "RadiusChip",
		Size = UDim2.fromOffset(BOX, BOX),
		Stroke = "BorderSecondary",
		ZIndex = 6,
	})

	-- Element.panel bound the stroke to BorderSecondary for the resting state; tinting replaces
	-- that binding rather than writing over it, so a later theme swap keeps the active colour.
	local stroke = box:FindFirstChildOfClass("UIStroke")

	local glyph = Element.icon(maid, box, "check", {
		Size = UDim2.fromOffset(GLYPH, GLYPH),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Role = "Accent",
		ZIndex = 7,
	})

	if options.Icon ~= nil then
		Element.icon(maid, row.Body, options.Icon, {
			Role = "TextMuted",
			Size = UDim2.fromOffset(13, 13),
			LayoutOrder = -1,
			ZIndex = 6,
		})
	end

	local self = {
		Instance = row.Root,
		Title = title,
		Changed = Signal.new(),
		_value = options.Default == true,
		_callback = options.Callback,
		_maid = maid,
		_group = group,
		_flag = options.Flag,
		_row = row,
	}

	local function paint(value: boolean)
		-- Quiet fill, loud border: a fully accent box would outshine the row's own label.
		Element.tint(maid, box, "BackgroundColor3", value and "AccentSoft" or "Field")
		if stroke ~= nil then
			Element.tint(maid, stroke, "Color", value and "Accent" or "BorderSecondary")
		end
		glyph.instance.Visible = value
	end

	local function set(value: boolean, silent: boolean?)
		local on = value == true
		if self.Destroyed then
			return self
		end
		local changed = self._value ~= on
		self._value = on

		paint(on)

		if changed then
			Element.pushConfig(self._flag, on)
			self.Changed:Dispatch(on)
			if not silent and self._callback ~= nil then
				local ok, err = pcall(self._callback, on)
				if not ok then
					warn("[Flux] checkbox '" .. tostring(title) .. "': " .. tostring(err))
				end
			end
		end
		return self
	end

	local button = Instance.new("TextButton", row.Root, {
		Name = "HitArea",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 8,
		BorderSizePixel = 0,
	})
	maid:giveFunction(function()
		button:Destroy()
	end)

	button.MouseButton1Click:Connect(function()
		set(not self._value)
	end)

	-- The whole row is the target, not an 18px box: on a phone the small version is unusable.
	if type(options.Desc) == "string" and options.Desc ~= "" then
		TooltipManager.attach(button, options.Desc)
	end

	-- Every entry point below takes the (a, b) shape: a host calls `w:Set(x)` with a colon, which
	-- arrives as (self, x), while the library calls it plain. One shim reads the same either way,
	-- and Groupbox fires OnFilter the same plain way, so this is the library's own idiom.
	self.Set = function(a: any, b: any)
		local value = a
		if a == self then
			value = b
		end
		return set(value, true)
	end

	self.Toggle = function()
		return set(not self._value)
	end

	self.GetValue = function()
		return self._value
	end

	self.SetCallback = function(a: any, b: any)
		local fn = a
		if a == self then
			fn = b
		end
		self._callback = fn
		return self
	end

	self.SetTitle = function(a: any, b: any)
		local text = a
		if a == self then
			text = b
		end
		self.Title = tostring(text)
		row.Title.Text = self.Title
		return self
	end

	self.SetVisible = function(a: any, b: any)
		local visible = a
		if a == self then
			visible = b
		end
		row.Root.Visible = visible == true
		return self
	end

	self.OnFilter = function(a: any, b: any)
		local matched = a
		if a == self then
			matched = b
		end
		row.Root.Visible = matched == true
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

	-- The default is staged, not pushed: writing it into the store before bindConfig would
	-- clobber the value a loaded config is about to restore.
	Element.bindConfig(maid, self._flag, function(value)
		set(value == true, true)
	end, function()
		return self._value
	end)

	self.SearchId = Element.searchable(group, self, tostring(title), options.Desc)

	-- Painted, not animated: the row has never been on screen, and a switch lighting up by
	-- itself as a tab opens reads as the hub toggling features on its own.
	paint(self._value)
	Guard.set(row.Root, "LayoutOrder", group:RowCount())
	return self
end

return Checkbox
