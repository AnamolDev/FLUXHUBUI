--[[
	Components/Button — an action row.

	A button spans the card instead of sitting beside a label, because that is what the reference
	design does with the two actions at the bottom of each section. Variant picks the palette role,
	never a hex, so `SetTheme` moves a danger button along with everything else.

	Clicks are reported through a `Clicked` signal as well as the callback: a host that wires three
	buttons to one handler should not have to write the same closure three times.
]]

local Element = require("Flux/Core/Element")
local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local Signal = require("Flux/Utilities/Signal")
local ThemeManager = require("Flux/Systems/ThemeManager")
local AnimationManager = require("Flux/Systems/AnimationManager")
local TooltipManager = require("Flux/Systems/TooltipManager")

local Button = {}

local VARIANTS = {
	accent = { Fill = "Accent", Text = "TextPrimary", Radius = "RadiusField" },
	soft = { Fill = "PanelSecondary", Text = "TextPrimary", Radius = "RadiusField" },
	outline = { Fill = "Field", Text = "TextSecondary", Radius = "RadiusField" },
	danger = { Fill = "Error", Text = "TextPrimary", Radius = "RadiusField" },
	success = { Fill = "Success", Text = "TextPrimary", Radius = "RadiusField" },
}

function Button.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "Button",
		Text = nil,
		Desc = nil,
		Icon = nil,
		Variant = "accent",
		Disabled = false,
		Callback = nil,
		Tooltip = nil,
		Height = 34,
	})

	local variant = VARIANTS[options.Variant] or VARIANTS.accent
	local label = options.Text or options.Name
	local maid = group.Maid

	local root = Instance.new("TextButton", group.Content, {
		Name = "Button_" .. tostring(label),
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = ThemeManager.color(variant.Fill),
		Size = UDim2.new(1, 0, 0, options.Height),
		LayoutOrder = group:RowCount() + 1,
		BorderSizePixel = 0,
		ZIndex = 5,
	})
	maid:giveFunction(function()
		root:Destroy()
	end)
	maid:give(ThemeManager.bind(root, "BackgroundColor3", variant.Fill))
	Element.round(maid, root, variant.Radius)

	local content = Instance.new("Frame", root, {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
		ZIndex = 6,
	})
	maid:giveFunction(function()
		content:Destroy()
	end)
	Instance.new("UIListLayout", content, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 7),
	})

	if options.Icon ~= nil then
		Element.icon(maid, content, options.Icon, {
			Role = variant.Text,
			Size = UDim2.fromOffset(14, 14),
			ZIndex = 6,
		})
	end

	local text = Element.label(maid, content, "Text", {
		Text = tostring(label),
		Role = variant.Text,
		Font = "Title",
		TextSize = 13,
		Alignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, options.Icon ~= nil and -30 or 0, 1, 0),
		AutoWidth = true,
		ZIndex = 6,
	})

	local self = {
		Instance = root,
		Title = label,
		Clicked = Signal.new(),
		_callback = options.Callback,
		_disabled = options.Disabled == true,
		Destroyed = false,
	}

	local function refreshDisabled()
		-- Transparency on the whole surface, rather than recolouring two children: a disabled
		-- button must look dimmed identically in every variant, including a custom palette.
		root.BackgroundTransparency = self._disabled and 0.55 or 0
		for _, child in ipairs(content:GetChildren()) do
			Guard.set(child, "TextTransparency", self._disabled and 0.35 or 0)
		end
	end

	local function fire(source: string)
		if self._disabled then
			return false
		end
		self.Clicked:Dispatch(source)
		if self._callback ~= nil then
			local ok, err = pcall(self._callback)
			if not ok then
				warn("[Flux] button '" .. tostring(label) .. "': " .. tostring(err))
			end
		end
		return true
	end

	root.MouseButton1Click:Connect(function()
		if self._disabled then
			return
		end
		-- A press is confirmed by a small squash rather than the engine's own highlight, which is
		-- tuned for saturated buttons and invisible on a dark theme.
		AnimationManager.to(root, { Size = UDim2.new(1, 0, 0, options.Height - 2) }, {
			Duration = 0.06,
			Easing = "outQuad",
		})
		task.delay(0.07, function()
			if not self.Destroyed then
				AnimationManager.to(root, { Size = UDim2.new(1, 0, 0, options.Height) }, {
					Duration = 0.1,
					Easing = "outQuad",
				})
			end
		end)
		fire("click")
	end)

	self.Click = function()
		return fire("script")
	end

	self.SetCallback = function(a: any, b: any)
		self._callback = Element.recv(self, a, b)
		return self
	end

	self.SetText = function(a: any, b: any)
		local value = tostring(Element.recv(self, a, b))
		self.Title = value
		root.Name = "Button_" .. tostring(value)
		local inner = content:FindFirstChild("Text")
		if inner ~= nil then
			inner.Text = value
		end
		return self
	end

	self.SetIcon = function(a: any, b: any)
		local glyph = tostring(Element.recv(self, a, b))
		local existing = content:FindFirstChildOfClass("ImageLabel") or content:FindFirstChildOfClass("Frame")
		if existing ~= nil then
			existing:Destroy()
		end
		local icon = Element.icon(maid, content, glyph, {
			Role = variant.Text,
			Size = UDim2.fromOffset(14, 14),
			ZIndex = 6,
		})
		icon.instance.LayoutOrder = -1
		return self
	end

	self.SetDisabled = function(a: any, b: any)
		self._disabled = Element.recv(self, a, b) == true
		refreshDisabled()
		return self
	end

	self.IsDisabled = function(): boolean
		return self._disabled
	end

	self.SetVisible = function(a: any, b: any)
		root.Visible = Element.recv(self, a, b) == true
		return self
	end

	self.OnFilter = function(a: any, b: any)
		root.Visible = Element.recv(self, a, b) == true
	end

	self.Destroy = function()
		if self.Destroyed then
			return
		end
		self.Destroyed = true
		AnimationManager.cancel(root)
		self.Clicked:Destroy()
		Element.releaseSearch(group, self)
		root:Destroy()
	end

	refreshDisabled()
	if type(options.Tooltip) == "string" and options.Tooltip ~= "" then
		TooltipManager.attach(root, options.Tooltip)
	end

	self.SearchId = Element.searchable(group, self, tostring(label), options.Desc)
	return self
end

return Button
