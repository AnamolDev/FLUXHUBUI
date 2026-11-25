--[[
	Components/ColorPicker — a swatch row that opens a hue/saturation popup.

	The value is carried as three numbers (hue, saturation, value) *and* a Color3: the swatch and
	the hex box paint from the Color3, while the two drag fields need the HSV form. Deriving hue
	from RGB on every repaint is how pickers drift a few units per theme swap, and the engine's
	Color3:ToHSV is not callable everywhere, so the conversion is written out here. A Color3 that
	arrives through `Set` is stored verbatim, so a hand-typed "#FF8000" round-trips through the
	hex box exactly instead of returning from the HSV round trip as #FF7F00.

	Colours on the square, the strip and the swatch are literal writes, not theme roles: they show
	the user's colour, not a token. Everything around them — panel, stroke, hex text — binds
	through Element, so a theme swap still restyles the popup itself.

	The gradient layers are built under Guard because the offline VM and several old executors
	have no ColorSequence/NumberSequence at all: each layer is created and destroyed as a unit,
	so a client without gradients gets flat (still clickable) fields rather than a black box,
	and the pixel math that turns a click into an HSV coordinate works either way.
]]

local Element = require("Flux/Core/Element")
local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local Math = require("Flux/Utilities/Math")
local Signal = require("Flux/Utilities/Signal")
local String = require("Flux/Utilities/String")
local ThemeManager = require("Flux/Systems/ThemeManager")

local UserInputService = Guard.service("UserInputService")

local ColorPicker = {}

local BODY_W = 150
local SWATCH_W = 44
local SWATCH_H = 24
local SV_H = 88
local STRIP_H = 12
local POPUP_PAD = 6
local POPUP_W = 170

local function isPress(input: any): boolean
	local kind = Guard.get(input, "EnumType")
	return kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch
end

--- Standard RGB->HSV over 0..1 components, computed by hand for the reason in the header.
local function toHsv(color: any): (number, number, number)
	local r, g, b = color.R, color.G, color.B
	local peak = math.max(r, g, b)
	local lowest = math.min(r, g, b)
	local delta = peak - lowest
	local hue = 0
	if delta > 0 then
		if peak == r then
			hue = ((g - b) / delta) % 6
		elseif peak == g then
			hue = (b - r) / delta + 2
		else
			hue = (r - g) / delta + 4
		end
		hue = hue / 6
		if hue < 0 then
			hue += 1
		end
	end
	local saturation = peak > 0 and delta / peak or 0
	return hue, saturation, peak
end

--- A gradient-painted overlay frame, or nil where the client cannot build one. The caller keeps
--- working without it; only the look degrades.
local function addGradientLayer(maid: any, parent: any, options: {
	Color: string,
	Stops: {{t: number, rgb: {[number]: number}}},
	Alpha: {number}?,
	Rotation: number?,
}): any
	local ok, layer = Guard.try(function()
		if ColorSequence == nil or ColorSequenceKeypoint == nil then
			return nil
		end
		local frame = Instance.new("Frame", parent, {
			Name = "Layer_" .. options.Color,
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			ZIndex = parent.ZIndex + 1,
		})
		local keys = {}
		for _, stop in ipairs(options.Stops) do
			table.insert(keys, ColorSequenceKeypoint.new(stop.t, Color3.fromRGB(stop.rgb[1], stop.rgb[2], stop.rgb[3])))
		end
		local gradient = Instance.new("UIGradient", frame, { Name = "Gradient" })
		gradient.Color = ColorSequence.new(keys)
		if options.Alpha ~= nil and NumberSequence ~= nil and NumberSequenceKeypoint ~= nil then
			local alphas = {}
			for index, alpha in ipairs(options.Alpha) do
				table.insert(alphas, NumberSequenceKeypoint.new(options.Stops[index].t, alpha))
			end
			gradient.Transparency = NumberSequence.new(alphas)
		end
		if options.Rotation ~= nil then
			gradient.Rotation = options.Rotation
		end
		frame.BackgroundColor3 = Color3.fromRGB(options.Stops[1].rgb[1], options.Stops[1].rgb[2], options.Stops[1].rgb[3])
		frame.BackgroundTransparency = options.Alpha ~= nil and 0 or 1
		return frame
	end)

	if not ok or layer == nil then
		return nil
	end
	maid:giveFunction(function()
		layer:Destroy()
	end)
	return layer
end

--- Component equality rather than `==`: Color3 is a userdata on the engine but a plain table
--- with no __eq on some stubs and older executors, where identity comparison would report every
--- re-application of the same colour as a change.
local function sameColor(a: any, b: any): boolean
	if a == b then
		return true
	end
	local ar, ag, ab = Guard.get(a, "R"), Guard.get(a, "G"), Guard.get(a, "B")
	local br, bg, bb = Guard.get(b, "R"), Guard.get(b, "G"), Guard.get(b, "B")
	if ar == nil or br == nil then
		return false
	end
	return ar == br and ag == bg and ab == bb
end

function ColorPicker.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "ColorPicker",
		Title = nil,
		Desc = nil,
		Default = Color3.fromRGB(255, 255, 255),
		Callback = nil,
		Flag = nil,
		Presets = nil,
		Transparency = false,
	})

	local title = options.Title or options.Name
	local maid = group.Maid
	local withAlpha = options.Transparency == true

	local row = Element.row(maid, group.Content, "ColorPicker_" .. tostring(title), {
		Label = title,
		Desc = options.Desc,
		BodyWidth = BODY_W,
		Order = group:RowCount() + 1,
	})
	local baseHeight = row.Root.Size.Y.Offset

	local swatch = Instance.new("TextButton", row.Body, {
		Name = "Swatch",
		Text = "",
		AutoButtonColor = false,
		-- The swatch paints the picked colour, not a theme token: a binding here would let a
		-- palette swap silently rewrite the user's choice.
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(SWATCH_W, SWATCH_H),
		ZIndex = 6,
	})
	maid:giveFunction(function()
		swatch:Destroy()
	end)
	Element.round(maid, swatch, "RadiusChip")

	local popup = Element.panel(maid, row.Root, "Popup", {
		Color = "Panel",
		Radius = "RadiusField",
		Stroke = "BorderPrimary",
		Size = UDim2.fromOffset(POPUP_W, 0),
		Position = UDim2.new(1, 0, 0, baseHeight + 2),
		AnchorPoint = Vector2.new(1, 0),
		Clips = true,
		Visible = false,
		ZIndex = 40,
	})

	local sv = Instance.new("Frame", popup, {
		Name = "SV",
		BackgroundColor3 = Color3.fromRGB(255, 0, 0),
		BorderSizePixel = 0,
		Size = UDim2.new(1, -POPUP_PAD * 2, 0, SV_H),
		Position = UDim2.new(0, POPUP_PAD, 0, POPUP_PAD),
		ZIndex = 41,
	})
	-- white -> hue across, transparent -> black down: the two overlays every SV square uses.
	addGradientLayer(maid, sv, {
		Color = "Saturation",
		Stops = { { t = 0, rgb = { 255, 255, 255 } }, { t = 1, rgb = { 255, 255, 255 } } },
		Alpha = { 0, 1 },
	})
	addGradientLayer(maid, sv, {
		Color = "Value",
		Stops = { { t = 0, rgb = { 0, 0, 0 } }, { t = 1, rgb = { 0, 0, 0 } } },
		Alpha = { 1, 0 },
	})
	local svMarker = Instance.new("Frame", sv, {
		Name = "Marker",
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 2,
		Size = UDim2.fromOffset(9, 9),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 45,
	})

	local stripY = POPUP_PAD + SV_H + 6
	local hueStrip = Instance.new("Frame", popup, {
		Name = "Hue",
		BackgroundColor3 = Color3.fromRGB(255, 0, 0),
		BorderSizePixel = 0,
		Size = UDim2.new(1, -POPUP_PAD * 2, 0, STRIP_H),
		Position = UDim2.new(0, POPUP_PAD, 0, stripY),
		ZIndex = 41,
	})
	addGradientLayer(maid, hueStrip, {
		Color = "Hue",
		Stops = {
			{ t = 0, rgb = { 255, 0, 0 } },
			{ t = 0.1667, rgb = { 255, 255, 0 } },
			{ t = 0.3333, rgb = { 0, 255, 0 } },
			{ t = 0.5, rgb = { 0, 255, 255 } },
			{ t = 0.6667, rgb = { 0, 0, 255 } },
			{ t = 0.8333, rgb = { 255, 0, 255 } },
			{ t = 1, rgb = { 255, 0, 0 } },
		},
	})
	local hueMarker = Instance.new("Frame", hueStrip, {
		Name = "Marker",
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(3, STRIP_H),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 45,
	})

	local alphaStrip = nil
	local alphaMarker = nil
	if withAlpha then
		alphaStrip = Instance.new("Frame", popup, {
			Name = "Alpha",
			BackgroundColor3 = Color3.fromRGB(128, 128, 128),
			BorderSizePixel = 0,
			Size = UDim2.new(1, -POPUP_PAD * 2, 0, STRIP_H),
			Position = UDim2.new(0, POPUP_PAD, 0, stripY + STRIP_H + 6),
			ZIndex = 41,
		})
		addGradientLayer(maid, alphaStrip, {
			Color = "Fade",
			Stops = { { t = 0, rgb = { 0, 0, 0 } }, { t = 1, rgb = { 0, 0, 0 } } },
			Alpha = { 1, 0 },
		})
		alphaMarker = Instance.new("Frame", alphaStrip, {
			Name = "Marker",
			BackgroundColor3 = Color3.fromRGB(255, 255, 255),
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(3, STRIP_H),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 45,
		})
	end

	local hexY = stripY + STRIP_H + 6 + (withAlpha and STRIP_H + 6 or 0)
	local hexBox = Instance.new("TextBox", popup, {
		Name = "Hex",
		Text = "",
		PlaceholderText = "RRGGBB",
		BackgroundColor3 = ThemeManager.color("Field"),
		TextColor3 = ThemeManager.color("TextPrimary"),
		Font = ThemeManager.font("Mono"),
		TextSize = 12,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -POPUP_PAD * 2, 0, 20),
		Position = UDim2.new(0, POPUP_PAD, 0, hexY),
		ZIndex = 41,
	})
	maid:giveFunction(function()
		hexBox:Destroy()
	end)
	maid:give(ThemeManager.bind(hexBox, "TextColor3", "TextPrimary"))

	local popupHeight = hexY + 20 + POPUP_PAD

	local self = {
		Instance = row.Root,
		Title = title,
		Changed = Signal.new(),
		Open = false,
		_color = Color3.fromRGB(255, 255, 255),
		_h = 0,
		_s = 0,
		_v = 1,
		_alpha = 0,
		_callback = options.Callback,
		_group = group,
		_flag = options.Flag,
		_row = row,
	}

	local function triple(): {number}
		local color = self._color
		local out = {
			math.floor((Guard.get(color, "R") or 1) * 255 + 0.5),
			math.floor((Guard.get(color, "G") or 0) * 255 + 0.5),
			math.floor((Guard.get(color, "B") or 0) * 255 + 0.5),
		}
		if withAlpha then
			table.insert(out, math.floor((1 - self._alpha) * 255 + 0.5))
		end
		return out
	end

	local function paint()
		swatch.BackgroundColor3 = self._color
		sv.BackgroundColor3 = Color3.fromHSV(self._h, 1, 1)
		svMarker.Position = UDim2.fromScale(Math.clamp(self._s, 0, 1), Math.clamp(1 - self._v, 0, 1))
		hueMarker.Position = UDim2.fromScale(Math.clamp(self._h, 0, 1), 0)
		if alphaMarker ~= nil then
			alphaMarker.Position = UDim2.fromScale(Math.clamp(1 - self._alpha, 0, 1), 0)
		end
		hexBox.Text = String.colorToHex(self._color)
	end

	local function applyColor(color: any, fromUser: boolean)
		local coerced = ThemeManager.coerceColor(color)
		if coerced == nil then
			return false
		end
		local changed = false
		if not sameColor(coerced, self._color) then
			changed = true
		end
		self._color = coerced
		local h, s, v = toHsv(coerced)
		self._h, self._s, self._v = h, s, v
		paint()
		if changed then
			Element.pushConfig(self._flag, triple())
			self.Changed:Dispatch(coerced)
			if fromUser and self._callback ~= nil then
				local ok, err = pcall(self._callback, coerced)
				if not ok then
					warn("[Flux] color picker '" .. tostring(title) .. "': " .. tostring(err))
				end
			end
		end
		return changed
	end

	local region: string? = nil
	local moveConnection = nil
	local endConnection = nil
	local moved = false

	-- AbsoluteSize is the denominator for the same reason it is on the slider: input.Position and
	-- absolute geometry are both engine-space pixels, so their quotient already cancels UIScale.
	local function fractionIn(frame: any, point: any, horizontal: boolean): number
		local origin = frame.AbsolutePosition
		local size = frame.AbsoluteSize
		local span = horizontal and size.X or size.Y
		if span <= 0 then
			return 0
		end
		local start = horizontal and origin.X or origin.Y
		local cursor = horizontal and point.X or point.Y
		return Math.clamp((cursor - start) / span, 0, 1)
	end

	local function updateRegion(input: any)
		local point = Guard.get(input, "Position")
		if point == nil or region == nil then
			return
		end
		local before = self._color
		if region == "sv" then
			self._s = fractionIn(sv, point, true)
			self._v = 1 - fractionIn(sv, point, false)
			applyColor(Color3.fromHSV(self._h, self._s, self._v), false)
		elseif region == "hue" then
			self._h = fractionIn(hueStrip, point, true)
			applyColor(Color3.fromHSV(self._h, self._s, self._v), false)
		elseif region == "alpha" then
			self._alpha = 1 - fractionIn(alphaStrip, point, true)
			paint()
		end
		if not sameColor(self._color, before) or (region == "alpha" and withAlpha) then
			moved = true
		end
	end

	local function releaseDrag(fire: boolean)
		if region == nil then
			return
		end
		region = nil
		if moveConnection ~= nil then
			moveConnection:Disconnect()
			moveConnection = nil
		end
		if endConnection ~= nil then
			endConnection:Disconnect()
			endConnection = nil
		end
		if fire and not self.Destroyed and moved then
			moved = false
			Element.pushConfig(self._flag, triple())
			if self._callback ~= nil then
				local ok, err = pcall(self._callback, self._color)
				if not ok then
					warn("[Flux] color picker '" .. tostring(title) .. "': " .. tostring(err))
				end
			end
		end
		moved = false
	end

	local function grab(target: string, input: any)
		if self.Destroyed then
			return
		end
		region = target
		local movementSignal = UserInputService ~= nil and Guard.get(UserInputService, "InputChanged") or nil
		local releaseSignal = UserInputService ~= nil and Guard.get(UserInputService, "InputEnded") or nil
		if movementSignal ~= nil then
			moveConnection = movementSignal:Connect(function(nextInput)
				if region ~= nil and not self.Destroyed then
					updateRegion(nextInput)
				end
			end)
		end
		if releaseSignal ~= nil then
			endConnection = releaseSignal:Connect(function(over)
				if isPress(over) then
					releaseDrag(true)
				end
			end)
		end
		updateRegion(input)
	end

	local function overRect(frame: any, point: any, pad: number): boolean
		local origin = frame.AbsolutePosition
		local size = frame.AbsoluteSize
		return point.X >= origin.X - pad
			and point.X <= origin.X + size.X + pad
			and point.Y >= origin.Y - pad
			and point.Y <= origin.Y + size.Y + pad
	end

	for _, pair in ipairs({ { sv, "sv" }, { hueStrip, "hue" }, { alphaStrip, "alpha" } }) do
		local frame = pair[1]
		if frame ~= nil then
			local down = Guard.get(frame, "MouseButton1Down")
			if down ~= nil then
				maid:giveConnection(down:Connect(function(input)
					grab(pair[2], input)
				end))
			end
			-- Touch rides the frame's own gesture stream on the engine and the service's on
			-- mobile; the `region ~= nil` latch keeps the two from double-grabbing.
			local touchBegan = Guard.get(frame, "InputBegan")
			local touchMoved = Guard.get(frame, "InputChanged")
			local touchEnded = Guard.get(frame, "InputEnded")
			if touchBegan ~= nil and touchMoved ~= nil and touchEnded ~= nil then
				maid:giveConnection(touchBegan:Connect(function(input)
					if isPress(input) then
						grab(pair[2], input)
					end
				end))
				maid:giveConnection(touchMoved:Connect(function(input)
					if region == pair[2] and isPress(input) then
						updateRegion(input)
					end
				end))
				maid:giveConnection(touchEnded:Connect(function(input)
					if isPress(input) then
						releaseDrag(true)
					end
				end))
			end
		end
	end

	local beganSignal = UserInputService ~= nil and Guard.get(UserInputService, "InputBegan") or nil
	if beganSignal ~= nil then
		maid:giveConnection(beganSignal:Connect(function(input)
			if region ~= nil or not self.Open or not isPress(input) then
				return
			end
			local point = Guard.get(input, "Position")
			if point == nil then
				return
			end
			if overRect(sv, point, 0) then
				grab("sv", input)
			elseif overRect(hueStrip, point, 3) then
				grab("hue", input)
			elseif alphaStrip ~= nil and overRect(alphaStrip, point, 3) then
				grab("alpha", input)
			end
		end))
	end

	local ensurePresets: () -> ()
	local presetHost = nil

	ensurePresets = function()
		if presetHost ~= nil or options.Presets == nil or self.Destroyed then
			return
		end
		presetHost = Instance.new("Frame", popup, {
			Name = "Presets",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, -POPUP_PAD * 2, 0, 18),
			Position = UDim2.new(0, POPUP_PAD, 0, popupHeight + 2),
			ZIndex = 41,
		})
		maid:giveFunction(function()
			presetHost:Destroy()
		end)
		local layout = Instance.new("UIListLayout", presetHost, {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		})
		maid:giveFunction(function()
			layout:Destroy()
		end)
		local order = 0
		for _, entry in ipairs(options.Presets) do
			local color = ThemeManager.coerceColor(entry)
			if color ~= nil then
				order += 1
				local chip = Instance.new("TextButton", presetHost, {
					Name = "Preset_" .. order,
					Text = "",
					AutoButtonColor = false,
					BackgroundColor3 = color,
					BorderSizePixel = 0,
					Size = UDim2.fromOffset(16, 16),
					LayoutOrder = order,
					ZIndex = 42,
				})
				maid:giveFunction(function()
					chip:Destroy()
				end)
				chip.MouseButton1Click:Connect(function()
					applyColor(color, true)
				end)
			end
		end
		if order > 0 then
			popupHeight = popupHeight + 24
			if self.Open then
				popup.Size = UDim2.fromOffset(POPUP_W, popupHeight)
				row.Root.Size = UDim2.new(1, 0, 0, baseHeight + popupHeight + 6)
			end
		end
	end

	self.OpenList = function()
		if self.Open or self.Destroyed then
			return self
		end
		self.Open = true
		ensurePresets()
		popup.Visible = true
		popup.Size = UDim2.fromOffset(POPUP_W, popupHeight)
		-- The row grows to cover the popup so the outside-click watcher counts a click inside
		-- the square as a click on the widget; a list pinned *outside* the watched rectangle
		-- would close itself a mouse-down before the row's click ever lands.
		row.Root.Size = UDim2.new(1, 0, 0, baseHeight + popupHeight + 6)
		return self
	end

	self.Close = function()
		if not self.Open then
			return self
		end
		releaseDrag(false)
		self.Open = false
		popup.Visible = false
		popup.Size = UDim2.fromOffset(POPUP_W, 0)
		row.Root.Size = UDim2.new(1, 0, 0, baseHeight)
		return self
	end

	local closeWatcher = Element.outsideClick(row.Root, function()
		self:Close()
	end)

	swatch.MouseButton1Click:Connect(function()
		if self.Destroyed then
			return
		end
		if self.Open then
			self:Close()
		else
			self:OpenList()
		end
	end)

	local function commitHex()
		if self.Destroyed then
			return
		end
		local parsed = String.hexToColor(hexBox.Text)
		if parsed == nil then
			-- Reject, do not guess: applying black to garbage is how a picker "loses" a colour
			-- the first time the field is mistyped.
			hexBox.Text = String.colorToHex(self._color)
			return
		end
		local changed = applyColor(parsed, true)
		if not changed and self._callback ~= nil then
			-- Re-committing the same colour is still a finished edit the host expects to hear.
			local ok, err = pcall(self._callback, self._color)
			if not ok then
				warn("[Flux] color picker '" .. tostring(title) .. "': " .. tostring(err))
			end
		end
	end

	local focusLost = Guard.get(hexBox, "FocusLost")
	if focusLost ~= nil then
		maid:giveConnection(focusLost:Connect(function(entered: boolean)
			if entered then
				commitHex()
			end
		end))
	end
	local activated = Guard.get(hexBox, "Activated")
	if activated ~= nil then
		maid:giveConnection(activated:Connect(commitHex))
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
		applyColor(recv(a, b), false)
		return self
	end
	self.SetColor = self.Set

	self.GetValue = function()
		return self._color
	end

	self.GetHex = function()
		return String.colorToHex(self._color)
	end

	self.GetText = function()
		return hexBox.Text
	end

	self.SetText = function(a: any, b: any)
		self.Title = tostring(recv(a, b))
		row.Title.Text = self.Title
		return self
	end
	self.SetTitle = self.SetText

	self.SetVisible = function(a: any, b: any)
		local visible = recv(a, b)
		if not visible then
			self:Close()
		end
		row.Root.Visible = visible == true
		return self
	end

	self.OnFilter = function(a: any, b: any)
		local matched = recv(a, b)
		if not matched then
			self:Close()
		end
		row.Root.Visible = matched == true
	end

	self.Destroy = function()
		if self.Destroyed then
			return
		end
		releaseDrag(false)
		self:Close()
		self.Destroyed = true
		if closeWatcher ~= nil then
			closeWatcher()
		end
		self.Changed:Destroy()
		Element.releaseSearch(group, self)
		row.Root:Destroy()
	end

	local initial = ThemeManager.coerceColor(options.Default)
	if initial == nil then
		initial = Color3.fromRGB(255, 255, 255)
	end
	self._color = initial
	local h, s, v = toHsv(initial)
	self._h, self._s, self._v = h, s, v
	paint()

	Element.bindConfig(maid, self._flag, function(value)
		if not self.Destroyed then
			applyColor(value, false)
		end
	end, function()
		return triple()
	end)

	self.SearchId = Element.searchable(group, self, tostring(title), options.Desc)
	Guard.set(row.Root, "LayoutOrder", group:RowCount())
	return self
end

return ColorPicker
