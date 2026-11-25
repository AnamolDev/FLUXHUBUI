--[[
	Components/Slider — a draggable value row.

	The pointer is followed through the input *service*, not the track: a GuiObject stops
	receiving motion the frame the cursor leaves it, and a slider that drops the drag the moment
	the pointer overshoots the 6 px rail is the bug every user notices first. The track's own
	MouseButton1Down is still used when the client has it; the service path behind a hit test
	covers click-to-position and the clients that never surface the instance signal at all.

	Positions are computed from the track's AbsoluteSize against input.Position because both are
	engine-space pixels: the UIScale the layout manager puts on the ScreenGui is already baked into
	absolute geometry by the engine, so dividing one by the other cancels it. Multiplying the
	pointer back through the scale (or a local-layout offset) is how a slider ends up moving half
	as fast on a phone.

	The user callback is held until the interaction ends. A drag produces one commit, not two
	hundred `host:rebuild()` calls, while `Changed` and the config store still see every value
	the knob passes — the store debounces its own write.
]]

local Element = require("Flux/Core/Element")
local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local Math = require("Flux/Utilities/Math")
local Signal = require("Flux/Utilities/Signal")

local UserInputService = Guard.service("UserInputService")

local Slider = {}

local BODY_W = 150
local BODY_H = 28
local TRACK_H = 6
local KNOB = 14
local HIT_PAD = 10

local function isPress(input: any): boolean
	local kind = Guard.get(input, "EnumType")
	return kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch
end

function Slider.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "Slider",
		Title = nil,
		Desc = nil,
		Default = 0,
		Min = 0,
		Max = 100,
		Step = 1,
		Decimals = nil,
		Callback = nil,
		Flag = nil,
		Prefix = "",
		Suffix = "",
		ShowValue = true,
		Unit = nil,
	})

	local title = options.Title or options.Name
	local maid = group.Maid
	local lower = tonumber(options.Min) or 0
	local upper = tonumber(options.Max) or 100
	if upper < lower then
		lower, upper = upper, lower
	end
	local step = tonumber(options.Step) or 1
	local decimals = tonumber(options.Decimals) or Math.decimalsForStep(step)
	local tail = options.Unit or options.Suffix or ""

	local row = Element.row(maid, group.Content, "Slider_" .. tostring(title), {
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

	local knob = Element.panel(maid, track, "Knob", {
		Color = "Accent",
		Radius = "RadiusPill",
		Size = UDim2.fromOffset(KNOB, KNOB),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 8,
	})

	local self = {
		Instance = row.Root,
		Title = title,
		Changed = Signal.new(),
		_value = 0,
		_callback = options.Callback,
		_group = group,
		_flag = options.Flag,
		_row = row,
	}

	local function quantize(candidate: number): number
		-- snap owns the floor (a value below it rounds to one step *below* itself), so only the
		-- ceiling needs the clamp; reversing the order would let 0.7 round above Max unbounded.
		return Math.clamp(Math.snap(candidate, lower, step, decimals), lower, upper)
	end

	local function paint(value: number)
		local span = upper - lower
		local frac = Math.inverseLerp(value, lower, upper)
		if span <= 0 then
			frac = 0
		end
		fill.Size = UDim2.fromScale(frac, 1)
		knob.Position = UDim2.fromScale(frac, 0.5)
		if readout ~= nil then
			readout.Text = tostring(options.Prefix or "") .. string.format("%." .. decimals .. "f", value) .. tail
		end
	end

	local function set(rawValue: any): number
		local value = quantize(tonumber(rawValue) or lower)
		local changed = value ~= self._value
		self._value = value
		paint(value)
		if changed then
			Element.pushConfig(self._flag, value)
			self.Changed:Dispatch(value)
		end
		return value
	end

	local function fireCallback()
		if self._callback == nil then
			return
		end
		local ok, err = pcall(self._callback, self._value)
		if not ok then
			warn("[Flux] slider '" .. tostring(title) .. "': " .. tostring(err))
		end
	end

	local dragging = false
	local startValue = 0
	local moveConnection = nil
	local endConnection = nil

	-- Resolved once: a client without the service input events still gets the instance-level
	-- down path, and one without either simply gets a slider that responds to Set only.
	local movementSignal = UserInputService ~= nil and Guard.get(UserInputService, "InputChanged") or nil
	local releaseSignal = UserInputService ~= nil and Guard.get(UserInputService, "InputEnded") or nil

	local function updateFrom(input: any)
		local point = Guard.get(input, "Position")
		if point == nil then
			return
		end
		local origin = track.AbsolutePosition
		local size = track.AbsoluteSize
		if size.X <= 0 then
			return
		end
		set(lower + (upper - lower) * Math.inverseLerp(point.X, origin.X, origin.X + size.X))
	end

	local function stopDrag(fire: boolean)
		if not dragging then
			return
		end
		dragging = false
		if moveConnection ~= nil then
			moveConnection:Disconnect()
			moveConnection = nil
		end
		if endConnection ~= nil then
			endConnection:Disconnect()
			endConnection = nil
		end
		-- The per-drag listeners are gone; the resting colour replaces the active one through
		-- the same tint slot, so a later theme swap keeps moving the knob.
		Element.tint(maid, knob, "BackgroundColor3", "Accent")
		if fire and not self.Destroyed and self._value ~= startValue then
			fireCallback()
		end
	end

	local function beginDrag(input: any)
		if dragging or self.Destroyed then
			return
		end
		dragging = true
		startValue = self._value
		if movementSignal ~= nil then
			moveConnection = movementSignal:Connect(function(moved)
				if not self.Destroyed then
					updateFrom(moved)
				end
			end)
		end
		if releaseSignal ~= nil then
			endConnection = releaseSignal:Connect(function(over)
				if isPress(over) then
					stopDrag(true)
				end
			end)
		end
		Element.tint(maid, knob, "BackgroundColor3", "AccentHover")
		updateFrom(input)
	end

	local downSignal = Guard.get(track, "MouseButton1Down")
	if downSignal ~= nil then
		maid:giveConnection(downSignal:Connect(beginDrag))
	end

	local beganSignal = UserInputService ~= nil and Guard.get(UserInputService, "InputBegan") or nil
	if beganSignal ~= nil then
		maid:giveConnection(beganSignal:Connect(function(input)
			if not isPress(input) or dragging then
				return
			end
			local point = Guard.get(input, "Position")
			if point == nil then
				return
			end
			local origin = track.AbsolutePosition
			local size = track.AbsoluteSize
			local inside = point.X >= origin.X - HIT_PAD
				and point.X <= origin.X + size.X + HIT_PAD
				and point.Y >= origin.Y - HIT_PAD
				and point.Y <= origin.Y + size.Y + HIT_PAD
			if inside then
				beginDrag(input)
			end
		end))
	end

	-- Touch on a frame is a gesture stream of its own on the engine; it arrives alongside the
	-- service events, and beginDrag's `dragging` latch makes the duplication harmless.
	local frameBegan = Guard.get(track, "InputBegan")
	local frameMoved = Guard.get(track, "InputChanged")
	local frameEnded = Guard.get(track, "InputEnded")
	if frameBegan ~= nil and frameMoved ~= nil and frameEnded ~= nil then
		maid:giveConnection(frameBegan:Connect(function(input)
			if isPress(input) then
				beginDrag(input)
			end
		end))
		maid:giveConnection(frameMoved:Connect(function(input)
			if dragging and isPress(input) then
				updateFrom(input)
			end
		end))
		maid:giveConnection(frameEnded:Connect(function(input)
			if isPress(input) then
				stopDrag(true)
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
		set(recv(a, b))
		return self
	end

	self.GetValue = function()
		return self._value
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
		stopDrag(false)
		row.Root.Visible = recv(a, b) == true
	end

	self.Destroy = function()
		if self.Destroyed then
			return
		end
		stopDrag(false)
		self.Destroyed = true
		self.Changed:Destroy()
		Element.releaseSearch(group, self)
		row.Root:Destroy()
	end

	-- Staged without pushing: writing the default into the config store *before* bindConfig
	-- would overwrite the value a loaded config restored, and the file's number would be lost
	-- the moment the row is built after the load.
	self._value = quantize(tonumber(options.Default) or lower)
	paint(self._value)

	Element.bindConfig(maid, self._flag, function(value)
		if not self.Destroyed then
			set(value)
		end
	end, function()
		return self._value
	end)

	self.SearchId = Element.searchable(group, self, tostring(title), options.Desc)
	Guard.set(row.Root, "LayoutOrder", group:RowCount())
	return self
end

return Slider
