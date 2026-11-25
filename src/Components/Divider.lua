--[[
	Components/Divider — a hairline separator with an optional inline caption.

	A group already has a header; a divider exists for the quieter break inside one — between a
	block of toggles and the paragraph that explains them. One line, one token: the hairline is
	`BorderPrimary` at the theme's `StrokeThickness`, so a preset that thickens borders thickens
	this too, and a host that pins the metric sees the row grow without a rebuild.

	The caption sits *on* the line with a `Panel`-bound chip behind it, rather than splitting the
	line into two segments: two segments have to be measured against the text and re-measured on
	every theme font change, and a centred chip costs one frame and one binding.
]]

local Element = require("Flux/Core/Element")
local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local ThemeManager = require("Flux/Systems/ThemeManager")

local Divider = {}

local SPACING = 6
local CHIP_H = 16

function Divider.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "Divider",
		Text = nil,
		Thickness = nil,
		Spacing = nil,
	})

	local maid = group.Maid
	local name = tostring(options.Name)
	local override = tonumber(options.Thickness)
	local spacing = tonumber(options.Spacing) or SPACING
	local lineH = override or ThemeManager.metric("StrokeThickness") or 1

	local root = Element.panel(maid, group.Content, "Divider_" .. name, {
		Transparency = 1,
		Size = UDim2.new(1, 0, 0, lineH + spacing * 2),
		LayoutOrder = group:RowCount() + 1,
		ZIndex = 5,
	})

	local line = Element.panel(maid, root, "Line", {
		Color = "BorderPrimary",
		Size = UDim2.new(1, 0, 0, lineH),
		Position = UDim2.new(0, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 6,
	})

	local caption = nil
	if type(options.Text) == "string" and options.Text ~= "" then
		local chip = Instance.new("Frame", root, {
			Name = "Caption",
			BackgroundColor3 = ThemeManager.color("Panel"),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			BorderSizePixel = 0,
			ZIndex = 7,
		})
		chip.AutomaticSize = Enum.AutomaticSize.XY
		maid:giveFunction(function()
			chip:Destroy()
		end)
		maid:give(ThemeManager.bind(chip, "BackgroundColor3", "Panel"))
		local padding = Instance.pad(chip, {
			Top = UDim.new(0, 1),
			Bottom = UDim.new(0, 1),
			Left = UDim.new(0, 6),
			Right = UDim.new(0, 6),
		})
		maid:giveFunction(function()
			padding:Destroy()
		end)
		Element.round(maid, chip, "RadiusChip")

		caption = Element.label(maid, chip, "Text", {
			Text = options.Text,
			Role = "TextMuted",
			TextSize = 11,
			Alignment = Enum.TextXAlignment.Center,
			AutoWidth = true,
			Size = UDim2.fromOffset(0, CHIP_H),
			ZIndex = 8,
		})
	end

	local self = {
		Instance = root,
		Title = name,
		_maid = maid,
		_group = group,
		_text = (type(options.Text) == "string" and options.Text) or "",
	}

	-- The line height follows the theme's stroke metric unless the host overrode it; a pinned
	-- Thickness is the host's own number and no preset gets to move it.
	maid:give(ThemeManager.bindFn(function(tokens)
		lineH = override or tokens.metrics.StrokeThickness or lineH
		line.Size = UDim2.new(1, 0, 0, lineH)
		root.Size = UDim2.new(1, 0, 0, lineH + spacing * 2)
	end, { "StrokeThickness" }))

	self.SetText = function(a: any, b: any)
		local value = a
		if a == self then
			value = b
		end
		if self.Destroyed or caption == nil then
			return self
		end
		self._text = tostring(value)
		caption.Text = self._text
		return self
	end

	self.Set = self.SetText

	self.GetValue = function()
		return self._text
	end

	self.GetText = self.GetValue

	-- A divider draws no title of its own (the line IS the row), so SetTitle keeps the family
	-- surface honest: it renames the widget's identity without touching the artwork.
	self.SetTitle = function(a: any, b: any)
		local text = a
		if a == self then
			text = b
		end
		self.Title = tostring(text)
		return self
	end

	self.SetVisible = function(a: any, b: any)
		local visible = a
		if a == self then
			visible = b
		end
		root.Visible = visible == true
		return self
	end

	-- Groupbox calls this plain and a host calls it with a colon, hence the (a, b) read.
	self.OnFilter = function(a: any, b: any)
		local matched = a
		if a == self then
			matched = b
		end
		root.Visible = matched == true
	end

	self.Destroy = function()
		if self.Destroyed then
			return
		end
		self.Destroyed = true
		Element.releaseSearch(group, self)
		root:Destroy()
	end

	self.SearchId = Element.searchable(group, self, name, self._text)
	Guard.set(root, "LayoutOrder", group:RowCount())
	return self
end

return Divider
