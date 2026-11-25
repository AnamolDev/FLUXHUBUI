--[[
	Components/ProgressBar — a determinate fill row.

	The readout half of a Slider: same rail, same accent fill, none of the drag surface — the
	number is written by a script (a download, a cooldown, a sweep counter), never by the
	pointer, so there is one rule instead of a hit test: every value lands clamped into
	[Min, Max], and anything that is not a number is refused with a warn rather than
	silently coercing the bar to one end. A host typo that painted "50%" at full would be
	unfindable.

	The fill tweens, and only when something changed: a row that existed at Min and was
	declared at 40% paints instantly (the Toggle rule — an entrance tween on a value the user
	never saw move reads as the hub acting by itself), and an idle bar costs no frame time,
	because AnimationManager's loop only exists while a tween is running.
]]

local Element = require("Flux/Core/Element")
local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local Math = require("Flux/Utilities/Math")
local Signal = require("Flux/Utilities/Signal")
local AnimationManager = require("Flux/Systems/AnimationManager")
local ThemeManager = require("Flux/Systems/ThemeManager")

local ProgressBar = {}

local BODY_W = 150
local BODY_H = 28
local TRACK_H = 6

function ProgressBar.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "ProgressBar",
		Title = nil,
		Desc = nil,
		Min = 0,
		Max = 1,
		Default = 0,
		Text = nil,
		ShowValue = true,
		Flag = nil,
		Callback = nil,
	})

	local title = options.Title or options.Name
	local maid = group.Maid
	local lower = tonumber(options.Min) or 0
	local upper = tonumber(options.Max) or 1
	if upper < lower then
		lower, upper = upper, lower
	end

	local row = Element.row(maid, group.Content, "Progress_" .. tostring(title), {
		Label = title,
		Desc = options.Desc,
		BodyWidth = BODY_W,
		Order = group:RowCount() + 1,
	})

	local gauge = Instance.new("Frame", row.Body, {
		Name = "Gauge",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(BODY_W, BODY_H),
		ZIndex = 5,
	})
	maid:giveFunction(function()
		gauge:Destroy()
	end)
	local gaugeList = Instance.new("UIListLayout", gauge, {
		FillDirection = Enum.FillDirection.Vertical,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 3),
	})
	maid:giveFunction(function()
		gaugeList:Destroy()
	end)

	local readout = nil
	if options.ShowValue ~= false then
		readout = Element.label(maid, gauge, "Value", {
			Text = "",
			Role = "TextSecondary",
			Font = "Mono",
			TextSize = 11,
			Alignment = Enum.TextXAlignment.Right,
			Size = UDim2.new(1, 0, 0, 12),
			LayoutOrder = 0,
			ZIndex = 6,
		})
	end

	local track = Element.panel(maid, gauge, "Track", {
		Color = "Chip",
		Radius = "RadiusPill",
		Size = UDim2.new(1, 0, 0, TRACK_H),
		LayoutOrder = 1,
		ZIndex = 6,
	})

	local fill = Element.panel(maid, track, "Fill", {
		Color = "Accent",
		Radius = "RadiusPill",
		Size = UDim2.fromScale(0, 1),
		ZIndex = 7,
	})

	-- The thin rail is the whole readout; only its ink follows the theme.
	maid:give(ThemeManager.bindFn(function(tokens)
		local color = tokens.colors.Accent
		if color ~= nil then
			fill.BackgroundColor3 = color
		end
	end, { "Accent" }))

	local self = {
		Instance = row.Root,
		Title = title,
		Changed = Signal.new(),
		_value = lower,
		_callback = options.Callback,
		_maid = maid,
		_group = group,
		_flag = options.Flag,
		_row = row,
	}

	local function format(value: number, frac: number): string
		local pct = math.floor(frac * 100 + 0.5)
		if type(options.Text) == "function" then
			local ok, out = pcall(options.Text, value, frac, pct)
			if ok and out ~= nil then
				return tostring(out)
			end
			warn("[Flux] progress '" .. tostring(title) .. "': text callback failed, showing percent")
			return pct .. "%"
		end
		if type(options.Text) == "string" and options.Text:find("%%d", 1, false) ~= nil then
			local ok, out = pcall(string.format, options.Text, pct)
			if ok then
				return out
			end
			warn("[Flux] progress '" .. tostring(title) .. "': bad format pattern, showing percent")
			return pct .. "%"
		end
		if type(options.Text) == "string" and options.Text ~= "" then
			return options.Text
		end
		return pct .. "%"
	end

	local function paint(value: number, animate: boolean?)
		local span = upper - lower
		local frac = 0
		if span > 0 then
			frac = Math.clamp((value - lower) / span, 0, 1)
		end
		local goal = UDim2.fromScale(frac, 1)
		if animate then
			AnimationManager.to(fill, { Size = goal }, { Duration = 0.25, Easing = "outQuint" })
		else
			fill.Size = goal
		end
		if readout ~= nil then
			readout.Text = format(value, frac)
		end
	end

	-- `silent` is the config-restore path: the value lands, the bar snaps to it, and neither the
	-- host callback nor a tween fires — a page re-entering must not animate numbers the user
	-- never saw move.
	local function set(rawValue: any, silent: boolean?)
		if self.Destroyed then
			return self
		end
		local value = tonumber(rawValue)
		if value == nil then
			warn(("[Flux] progress '%s': refusing '%s', the value must be a number"):format(
				tostring(title), tostring(rawValue)))
			return self
		end
		value = Math.clamp(value, lower, upper)

		local changed = value ~= self._value
		self._value = value

		if changed then
			paint(value, not silent)
			Element.pushConfig(self._flag, value)
			self.Changed:Dispatch(value)
			if not silent and self._callback ~= nil then
				local ok, err = pcall(self._callback, value)
				if not ok then
					warn("[Flux] progress '" .. tostring(title) .. "': " .. tostring(err))
				end
			end
		end
		return self
	end

	self.Set = function(a: any, b: any)
		local value = a
		if a == self then
			value = b
		end
		return set(value)
	end

	--- The clamped number the bar is actually showing, never the number the caller hoped for.
	self.SetValue = function()
		return self._value
	end

	self.GetValue = function()
		return self._value
	end

	self.SetCallback = function(fn)
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

	-- Groupbox calls this plain (`row.OnFilter(isMatch)`) and a host with a colon, so the flag arrives in
	-- either position; the shim reads whichever one carries it.
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
		AnimationManager.cancel(fill)
		self.Changed:Destroy()
		Element.releaseSearch(group, self)
		row.Root:Destroy()
	end

	self._value = Math.clamp(tonumber(options.Default) or lower, lower, upper)
	paint(self._value, false)

	Element.bindConfig(maid, self._flag, function(value)
		if not self.Destroyed then
			set(value, true)
		end
	end, function()
		return self._value
	end)

	self.SearchId = Element.searchable(group, self, tostring(title), options.Desc)
	Guard.set(row.Root, "LayoutOrder", group:RowCount())
	return self
end

return ProgressBar
