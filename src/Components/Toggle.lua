--[[
	Components/Toggle — a labelled switch row.

	This is the reference component: everything the other nineteen follow. A widget

	  * builds through `Element.row` so the label and hint are placed identically everywhere,
	  * keeps its own value rather than reading the UI back, so `Set` is safe before the row is
	    mounted and a theme swap cannot change state,
	  * reports to the search index and the config store through Element helpers, and
	  * exposes `Set / GetValue / Destroy` plus a `Changed` signal, which is the whole public
	    surface a hub needs from any control.
]]

local Element = require("Flux/Core/Element")
local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local Signal = require("Flux/Utilities/Signal")
local ThemeManager = require("Flux/Systems/ThemeManager")
local AnimationManager = require("Flux/Systems/AnimationManager")
local TooltipManager = require("Flux/Systems/TooltipManager")

local Toggle = {}

local SWITCH_WIDTH = 42
local SWITCH_HEIGHT = 22
local KNOB = 16

function Toggle.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "Toggle",
		Title = nil,
		Desc = nil,
		Default = false,
		Callback = nil,
		Flag = nil,
		Icon = nil,
		Suffix = nil,
	})

	local title = options.Title or options.Name
	local maid = group.Maid
	local row = Element.row(maid, group.Content, "Toggle_" .. tostring(title), {
		Label = title,
		Desc = options.Desc,
		BodyWidth = SWITCH_WIDTH + 8,
		Order = group:RowCount() + 1,
	})

	local track = Element.panel(maid, row.Body, "Switch", {
		Color = "Field",
		Radius = "RadiusPill",
		Size = UDim2.fromOffset(SWITCH_WIDTH, SWITCH_HEIGHT),
		Stroke = "BorderSecondary",
		ZIndex = 6,
	})

	local knob = Element.panel(maid, track, "Knob", {
		Color = "TextMuted",
		Radius = "RadiusPill",
		Size = UDim2.fromOffset(KNOB, KNOB),
		Position = UDim2.new(0, 3, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
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

	-- Element.panel bound the stroke to BorderSecondary for the resting state; tinting replaces
	-- that binding rather than writing over it, so a later theme swap keeps the active colour.
	local stroke = track:FindFirstChildOfClass("UIStroke")

	local function paint(value: boolean, instant: boolean?)
		-- Colour and position move together: a knob that slides without lighting up reads as a
		-- hover effect rather than a state change.
		Element.tint(maid, track, "BackgroundColor3", value and "AccentSoft" or "Field")
		if stroke ~= nil then
			Element.tint(maid, stroke, "Color", value and "Accent" or "BorderSecondary")
		end
		Element.tint(maid, knob, "BackgroundColor3", value and "Accent" or "TextMuted")

		local goal = UDim2.new(0, value and (SWITCH_WIDTH - KNOB - 3) or 3, 0.5, 0)
		if instant then
			knob.Position = goal
		else
			AnimationManager.to(knob, { Position = goal }, { Duration = 0.16, Easing = "outQuad" })
		end
	end

	local function set(value: boolean, silent: boolean?)
		local on = value == true
		if self.Destroyed then
			return self
		end
		local changed = self._value ~= on
		self._value = on

		paint(on, silent)

		if changed then
			Element.pushConfig(self._flag, on)
			self.Changed:Dispatch(next)
			if not silent and self._callback ~= nil then
				local ok, err = pcall(self._callback, next)
				if not ok then
					warn("[Flux] toggle '" .. tostring(title) .. "': " .. tostring(err))
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

	-- The whole row is the target, not a 42px switch: on a phone the small version is unusable.
	if type(options.Desc) == "string" and options.Desc ~= "" then
		TooltipManager.attach(button, options.Desc)
	end

	-- Methods are fields on the handle (the library's internal style) while hosts call them with a
	-- colon, which prepends the handle. `Element.recv` reads the real argument either way.
	self.Set = function(a: any, b: any)
		return set(Element.recv(self, a, b), true)
	end

	self.Toggle = function()
		return set(not self._value)
	end

	self.GetValue = function()
		return self._value
	end

	self.SetCallback = function(a: any, b: any)
		self._callback = Element.recv(self, a, b)
		return self
	end

	self.SetTitle = function(a: any, b: any)
		local text = tostring(Element.recv(self, a, b))
		self.Title = text
		row.Title.Text = text
		return self
	end

	self.SetVisible = function(a: any, b: any)
		row.Root.Visible = Element.recv(self, a, b) == true
		return self
	end

	self.OnFilter = function(a: any, b: any)
		row.Root.Visible = Element.recv(self, a, b) == true
	end

	self.Destroy = function()
		if self.Destroyed then
			return
		end
		self.Destroyed = true
		AnimationManager.cancel(knob)
		self.Changed:Destroy()
		Element.releaseSearch(group, self)
		row.Root:Destroy()
	end

	Element.bindConfig(maid, self._flag, function(value)
		set(value == true, true)
	end, function()
		return self._value
	end)

	local searchId = Element.searchable(group, self, tostring(title), options.Desc)
	self.SearchId = searchId

	-- The value is painted, not animated, before the row has ever been on screen: an entrance
	-- tween on a switch that was already on looks like the hub turning features on by itself.
	paint(self._value, true)
	Guard.set(row.Root, "LayoutOrder", group:RowCount())
	return self
end

return Toggle
