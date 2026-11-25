--[[
	harness/stub.lua — a Roblox engine stand-in so the library can be executed offline.

	The Node runner concatenates: stub + built bundle + spec bodies, as ONE chunk. That is
	not stylistic — this VM freezes table-field reads per loadstring chunk, so a driver in a
	later chunk reads stale copies of what the library wrote, and assertions go red against
	a build that is actually fine.

	Deliberate choices:
	  * AbsolutePosition / AbsoluteSize are derived from Position / Size / AnchorPoint
	    against a fixed viewport, so code that writes the wrong coordinate space is caught
	    rather than flattered;
	  * an unknown member read raises. A stub that shrugs is how `Frame.AbsoluteCenter`
	    passed every check and then crashed a real client once per mouse event;
	  * the executor-only globals are switchable, so "client has no file api" is a scenario;
	  * `os.clock()` is rewritten by the runner to `harnessClock()`, because this VM's `os`
	    table is readonly and cannot be monkey-patched.
]]

local CLASS_PARENTS = {
	Instance = nil,
	UICorner = "UIComponent",
	UIStroke = "UIComponent",
	UIPadding = "UIComponent",
	UIAspectRatioConstraint = "UIComponent",
	UILayout = "UIComponent",
	UIListLayout = "UILayout",
	UIGridLayout = "UILayout",
	UIComponent = "LayerCollector",
	GuiBase = "Instance",
	GuiBase2d = "GuiBase",
	GuiObject = "GuiBase2d",
	Frame = "GuiObject",
	TextLabel = "GuiObject",
	TextBox = "GuiObject",
	TextButton = "GuiObject",
	ImageLabel = "GuiObject",
	ImageButton = "GuiObject",
	ScrollingFrame = "GuiObject",
	ViewportFrame = "GuiObject",
	LayerCollector = "GuiBase2d",
	ScreenGui = "LayerCollector",
	CanvasGroup = "GuiObject",
	Folder = "Instance",
	BillboardGui = "LayerCollector",
	BindableEvent = "Instance",
	BindableFunction = "Instance",
	Camera = "Node",
	Node = "Instance",
	Service = "Instance",
	DataModel = "Instance",
	Player = "Instance",
}

-- Properties that legitimately read as nil, exactly as on the engine.
local NILABLE = {
	Parent = true,
	PaddingTop = true,
	PaddingBottom = true,
	PaddingLeft = true,
	PaddingRight = true,
	CellSize = true,
	CellPadding = true,
	MaximumSize = true,
	MinimumSize = true,
	MaxScrollDistance = true,
}

-- Every key here is a real property of at least one class in the stub, and each gets a
-- concrete default. A default table with nil holes would silently turn ordinary reads into
-- "not a valid member" failures, because pairs() cannot see the keys that hold nil.
local DEFAULT_VALUES = {
	Name = "",
	Visible = true,
	Active = true,
	Selectable = false,
	ZIndex = 1,
	BackgroundTransparency = 0,
	BorderSizePixel = 1,
	Rotation = 0,
	LayoutOrder = 1,
	Text = "",
	TextTransparency = 0,
	TextSize = 14,
	TextWrapped = false,
	TextEditable = true,
	MultiLine = false,
	PlaceholderText = "",
	Image = "",
	ImageTransparency = 0,
	ClipsDescendants = false,
	ScrollingEnabled = false,
	ScrollBarThickness = 6,
	Thickness = 1,
	Transparency = 0,
	AspectRatio = 1,
	IgnoreGuiInset = false,
	ResetOnStartup = true,
	DisplayOrder = 0,
	AutoButtonColor = true,
	RichText = false,
	TextScaled = false,
	Enabled = true,
	Wrap = false,
	ClassCategory = "",
	TouchEnabled = false,
	KeyboardEnabled = true,
	GamepadEnabled = false,
}

-- Enum-valued defaults are applied after the Enum factory exists. They are stored as real
-- enum items so a read-back compares equal to what the library wrote.
local ENUM_DEFAULTS = {
	Font = "Font.Gotham",
	TextXAlignment = "TextXAlignment.Left",
	TextYAlignment = "TextYAlignment.Center",
	SortOrder = "SortOrder.LayoutOrder",
	FillDirection = "FillDirection.TopToBottom",
	ApplyStrokeMode = "ApplyStrokeMode.Border",
	ImageSizeConstraint = "ImageSizeConstraint.Fit",
	ScrollerInputSource = "ScrollerInputSource.Discrete",
}

-- Every name the stub considers a real property, for the strict-write mode below.
local WRITABLE = {}
for key in pairs(DEFAULT_VALUES) do
	WRITABLE[key] = true
end
for key in pairs(NILABLE) do
	WRITABLE[key] = true
end
for key in pairs(ENUM_DEFAULTS) do
	WRITABLE[key] = true
end
for _, extra in ipairs({
	"Parent",
	"ClassName",
	"BackgroundColor3",
	"BorderColor3",
	"TextColor3",
	"ImageColor3",
	"Color",
	"Size",
	"Position",
	"AnchorPoint",
	"CanvasSize",
	"CanvasPosition",
}) do
	WRITABLE[extra] = true
end

--[[ Datatypes ---------------------------------------------------------------- ]]

local Vector2_mt

local function vector2New(x, y)
	local v = { X = x or 0, Y = y or 0 }
	return setmetatable(v, Vector2_mt)
end

Vector2_mt = {
	__add = function(a, b)
		return vector2New(a.X + b.X, a.Y + b.Y)
	end,
	__sub = function(a, b)
		return vector2New(a.X - b.X, a.Y - b.Y)
	end,
	__mul = function(a, b)
		if type(b) == "number" then
			return vector2New(a.X * b, a.Y * b)
		end
		return vector2New(a.X * b.X, a.Y * b.Y)
	end,
	__div = function(a, b)
		if type(b) == "number" then
			return vector2New(a.X / b, a.Y / b)
		end
		return vector2New(a.X / b.X, a.Y / b.Y)
	end,
	__eq = function(a, b)
		return a.X == b.X and a.Y == b.Y
	end,
	__tostring = function(a)
		return "(" .. tostring(a.X) .. ", " .. tostring(a.Y) .. ")"
	end,
	__index = function(vector, key)
		if key == "Magnitude" then
			return math.sqrt(vector.X * vector.X + vector.Y * vector.Y)
		end
		error(("'%s' is not a valid member of Vector2"):format(tostring(key)))
	end,
}

Vector2 = {
	new = vector2New,
	zero = vector2New(0, 0),
	one = vector2New(1, 1),
	xAxis = vector2New(1, 0),
	yAxis = vector2New(0, 1),
}

local function vector3New(x, y, z)
	return { X = x or 0, Y = y or 0, Z = z or 0 }
end

Vector3 = { new = vector3New, zero = vector3New(0, 0, 0) }

local function color3FromRGB(r, g, b)
	local color = { R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255 }
	color.Lerp = function(self, other, alpha)
		return color3FromRGB(
			(self.R + (other.R - self.R) * alpha) * 255,
			(self.G + (other.G - self.G) * alpha) * 255,
			(self.B + (other.B - self.B) * alpha) * 255
		)
	end
	color.ToHSV = function()
		return 0, 0, 0
	end
	color.__tostring = nil
	return setmetatable(color, {
		__tostring = function(c)
			return string.format("RGB(%d,%d,%d)", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
		end,
		__eq = function(a, b)
			return a.R == b.R and a.G == b.G and a.B == b.B
		end,
	})
end

local function color3FromHSV(hue, saturation, value)
	local h = math.floor(hue * 6)
	local f = value * (1 - saturation * (1 - math.abs((hue * 6) % 2 - 1)))
	local r, g, b = value, value, value

	if h == 0 then
		r, g, b = value, f, 0
	elseif h == 1 then
		r, g, b = f, value, 0
	elseif h == 2 then
		r, g, b = 0, value, f
	elseif h == 3 then
		r, g, b = 0, f, value
	elseif h == 4 then
		r, g, b = f, 0, value
	else
		r, g, b = value, 0, f
	end

	return color3FromRGB(r * 255, g * 255, b * 255)
end

Color3 = {
	new = function(r, g, b)
		return color3FromRGB((r or 0) * 255, (g or 0) * 255, (b or 0) * 255)
	end,
	fromRGB = color3FromRGB,
	fromHSV = color3FromHSV,
}

local function udimNew(scale, offset)
	return { Scale = scale or 0, Offset = offset or 0 }
end

local function udim2New(scaleX, offsetX, scaleY, offsetY)
	if type(scaleX) == "table" and scaleX.Scale ~= nil then
		-- UDim2.new(UDim, UDim)
		return { X = { Scale = scaleX.Scale, Offset = scaleX.Offset }, Y = { Scale = offsetX.Scale, Offset = offsetX.Offset } }
	end

	return {
		X = udimNew(scaleX, offsetX),
		Y = udimNew(scaleY, offsetY),
	}
end

UDim = { new = udimNew }
UDim2 = {
	new = udim2New,
	fromScale = function(scaleX, scaleY)
		return udim2New(scaleX, 0, scaleY, 0)
	end,
	fromOffset = function(offsetX, offsetY)
		return udim2New(0, offsetX, 0, offsetY)
	end,
	fromPixel = function(offsetX, offsetY)
		return udim2New(0, offsetX, 0, offsetY)
	end,
}

Rect = {
	new = function(x, y, width, height)
		return { X = x, Y = y, Width = width - x, Height = height - y }
	end,
}

TweenInfo = function(time, style, direction, repeatCount, delayTime, reverses)
	return {
		Time = time,
		EasingStyle = style,
		EasingDirection = direction,
		RepeatCount = repeatCount or 0,
		DelayTime = delayTime or 0,
		Reverses = reverses or false,
	}
end

CFrame = { new = function()
	return { Position = vector3New(0, 0, 0) }
end }

local enumItems: {[string]: any} = {}

Enum = setmetatable({}, {
	__index = function(_, typeName)
		local key = tostring(typeName)
		local cacheKey = "type:" .. key

		if enumItems[cacheKey] == nil then
			enumItems[cacheKey] = setmetatable({}, {
				__index = function(_, memberName)
					local itemKey = key .. "." .. tostring(memberName)
					if enumItems[itemKey] == nil then
						enumItems[itemKey] = {
							Name = tostring(memberName),
							Value = 0,
							EnumType = { Name = key },
						}
					end
					return enumItems[itemKey]
				end,
			})
		end

		return enumItems[cacheKey]
	end,
})

--[[ Signals ------------------------------------------------------------------ ]]

local function makeSignal()
	local signal = { handlers = {} }

	signal.Connect = function(self, fn)
		local entry = { fn = fn, alive = true }
		table.insert(self.handlers, entry)

		return {
			Connected = true,
			Disconnect = function()
				entry.alive = false
			end,
			Destroy = function()
				entry.alive = false
			end,
		}
	end

	signal.Once = function(self, fn)
		local entry = { fn = fn, alive = true, once = true }
		table.insert(self.handlers, entry)

		return {
			Connected = true,
			Disconnect = function()
				entry.alive = false
			end,
			Destroy = function()
				entry.alive = false
			end,
		}
	end

	signal.Fire = function(self, ...)
		local snapshot = table.clone(self.handlers)
		for _, entry in ipairs(snapshot) do
			if entry.alive then
				if entry.once then
					entry.alive = false
				end
				entry.fn(...)
			end
		end
	end

	signal.Fire = function(self, ...)
		local snapshot = table.clone(self.handlers)
		for _, entry in ipairs(snapshot) do
			if entry.alive then
				entry.fn(...)
			end
		end
	end

	signal.Wait = function()
		error("harness: signal Wait would yield")
	end

	signal.Destroy = function(self)
		table.clear(self.handlers)
	end

	return signal
end

--[[ Instances ---------------------------------------------------------------- ]]

local viewportSize = Vector2.new(1280, 720)

-- Deliberately (0, 0). The engine's topbar inset shifts AbsolutePosition but not mouse
-- coordinates, and a stub that guessed that offset wrong would teach the library to drag
-- wrong. Nothing here may depend on it: window dragging accumulates a delta between two
-- AbsolutePosition reads, which is inset-agnostic by construction.
local guiInset = Vector2.new(0, 0)

local instanceMeta

-- Declared before the geometry helpers because a `local function` is not in scope at the
-- point of its own definition; anything that calls it earlier would resolve to a nil global.
local function isA_safe(class: string, wanted: string): boolean
	local cursor = class
	local hops = 0

	while cursor ~= nil and hops < 32 do
		if cursor == wanted then
			return true
		end
		cursor = CLASS_PARENTS[cursor]
		hops += 1
	end

	return false
end

local function newInstance(class: string)
	local self = {
		_class = class,
		_children = {},
		_props = {},
		_signals = {},
		_propSignals = {},
		_destroyed = false,
	}

	setmetatable(self, instanceMeta)

	for key, value in pairs(DEFAULT_VALUES) do
		self._props[key] = value
	end

	-- The engine names a fresh instance "New Instance"; defaulting it to the class name
	-- would let a FindFirstChild("Frame") typo pass here and fail in Studio.
	self._props.Name = "New Instance"
	self._props.BackgroundColor3 = color3FromRGB(255, 255, 255)
	self._props.BorderColor3 = color3FromRGB(0, 0, 0)
	self._props.TextColor3 = color3FromRGB(0, 0, 0)
	self._props.ImageColor3 = color3FromRGB(255, 255, 255)
	self._props.Color = color3FromRGB(255, 255, 255)
	self._props.Size = udim2New(0, 0, 0, 0)
	self._props.Position = udim2New(0, 0, 0, 0)
	self._props.AnchorPoint = vector2New(0, 0)
	self._props.CanvasSize = vector2New(0, 0)
	self._props.CanvasPosition = vector2New(0, 0)

	for property, path in pairs(ENUM_DEFAULTS) do
		local enumName, member = path:match("^(%w+)%.(.+)$")
		self._props[property] = Enum[enumName][member]
	end

	return self
end

local function absoluteSizeOf(self): Vector2
	local props = rawget(self, "_props")
	local size = props.Size
	local parent = props.Parent
	local width = viewportSize.X
	local height = viewportSize.Y

	if parent ~= nil and isA_safe(parent._class, "GuiObject") then
		local parentSize = absoluteSizeOf(parent)
		width = parentSize.X
		height = parentSize.Y
	end

	return vector2New(size.X.Scale * width + size.X.Offset, size.Y.Scale * height + size.Y.Offset)
end

local function absoluteOf(self): Vector2
	local props = rawget(self, "_props")
	local position = props.Position
	local anchor = props.AnchorPoint
	local parent = props.Parent

	local originX = -guiInset.X
	local originY = -guiInset.Y
	local width = viewportSize.X
	local height = viewportSize.Y

	if parent ~= nil and isA_safe(parent._class, "GuiObject") then
		local parentOrigin = absoluteOf(parent)
		local parentSize = absoluteSizeOf(parent)
		originX = parentOrigin.X
		originY = parentOrigin.Y
		width = parentSize.X
		height = parentSize.Y
	end

	local drawn = absoluteSizeOf(self)
	local x = originX + position.X.Scale * width + position.X.Offset
	local y = originY + position.Y.Scale * height + position.Y.Offset

	return vector2New(x - anchor.X * drawn.X, y - anchor.Y * drawn.Y)
end

instanceMeta = {
	__index = function(self, key)
		local props = rawget(self, "_props")
		local value = props[key]

		if value ~= nil then
			return value
		end

		if key == "ClassName" then
			return rawget(self, "_class")
		end

		if key == "Parent" or NILABLE[key] then
			return nil
		end

		if key == "AbsolutePosition" then
			return absoluteOf(self)
		end

		if key == "AbsoluteSize" then
			return absoluteSizeOf(self)
		end

		if key == "AbsoluteContentSize" then
			return absoluteSizeOf(self)
		end

		if key == "TextBounds" then
			return vector2New(#props.Text * props.TextSize * 0.52, props.TextSize)
		end

		if key == "Changed" or key == "Destroyed" or key == "Event" or key == "MouseEnter" or key == "MouseLeave" then
			local signals = rawget(self, "_signals")
			signals[key] = signals[key] or makeSignal()
			return signals[key]
		end

		if key == "MouseButton1" or key == "MouseButton2" or key == "MouseButton1Click" or key == "MouseButton2Click" then
			local signals = rawget(self, "_signals")
			signals[key] = signals[key] or makeSignal()
			return signals[key]
		end

		if key == "Focused" or key == "FocusLost" or key == "Activated" then
			local signals = rawget(self, "_signals")
			signals[key] = signals[key] or makeSignal()
			return signals[key]
		end

		if key == "GetPropertyChangedSignal" then
			return function(inst: any, propertyName: string)
				local signals = rawget(inst, "_propSignals")
				signals[propertyName] = signals[propertyName] or makeSignal()
				return signals[propertyName]
			end
		end

		if key == "IsA" then
			return function(inst: any, wanted: string)
				return isA_safe(rawget(inst, "_class"), wanted)
			end
		end

		if key == "FindFirstChild" then
			return function(inst: any, name: string)
				for _, child in ipairs(rawget(inst, "_children")) do
					if child._props.Name == name then
						return child
					end
				end
				return nil
			end
		end

		if key == "FindFirstChildOfClass" then
			return function(inst: any, class: string)
				for _, child in ipairs(rawget(inst, "_children")) do
					if rawget(child, "_class") == class then
						return child
					end
				end
				return nil
			end
		end

		if key == "WaitForChild" then
			return function(inst: any, name: string)
				local found = inst:FindFirstChild(name)
				if found == nil then
					error("harness: WaitForChild(" .. name .. ") would yield")
				end
				return found
			end
		end

		if key == "GetChildren" then
			return function(inst: any)
				return table.clone(rawget(inst, "_children"))
			end
		end

		if key == "GetDescendants" then
			return function(inst: any)
				local out = {}
				local function walk(node)
					for _, child in ipairs(rawget(node, "_children")) do
						table.insert(out, child)
						walk(child)
					end
				end
				walk(inst)
				return out
			end
		end

		if key == "ClearAllChildren" then
			return function(inst: any)
				local children = rawget(inst, "_children")
				for index = #children, 1, -1 do
					children[index]:Destroy()
				end
			end
		end

		if key == "Destroy" then
			return function(inst: any)
				rawset(inst, "_destroyed", true)

				local parent = rawget(inst, "_props").Parent
				if parent ~= nil then
					local siblings = rawget(parent, "_children")
					for index = #siblings, 1, -1 do
						if siblings[index] == inst then
							table.remove(siblings, index)
							break
						end
					end
				end
				rawget(inst, "_props").Parent = nil

				local children = table.clone(rawget(inst, "_children"))
				for _, child in ipairs(children) do
					child:Destroy()
				end

				local signals = rawget(inst, "_signals")
				if signals.Destroyed ~= nil then
					signals.Destroyed:Fire(inst)
				end
			end
		end

		if key == "Clone" then
			return function(inst: any)
				local copy = newInstance(rawget(inst, "_class"))
				for prop, item in pairs(rawget(inst, "_props")) do
					if prop ~= "Parent" and prop ~= "Name" then
						copy._props[prop] = item
					end
				end
				return copy
			end
		end

		if key == "Fire" or key == "Invoke" then
			return function() end
		end

		error(("'%s' is not a valid member of %s"):format(tostring(key), tostring(rawget(self, "_class"))))
	end,

	__newindex = function(self, key, value)
		-- An engine member can read back a value and still refuse every write (AbsolutePosition,
		-- or a newer property whose setter the client stubbed out). Per-name so a spec can prove
		-- the animation loop drops such an entry instead of retrying it every frame.
		if readonlyWrites ~= nil and readonlyWrites[key] == true then
			error(("%s is read-only on this client"):format(tostring(key)))
		end

		-- Some clients treat unknown writes on protected instances as an error rather than as
		-- an expando. Guard.set has to survive both, so the behaviour is switchable.
		if strictPropertyWrites and not WRITABLE[key] then
			error(("%s is not a valid property of %s"):format(tostring(key), tostring(rawget(self, "_class"))))
		end

		if key == "Parent" then
			local props = rawget(self, "_props")
			local previous = props.Parent

			if previous ~= nil then
				local siblings = rawget(previous, "_children")
				for index = #siblings, 1, -1 do
					if siblings[index] == self then
						table.remove(siblings, index)
						break
					end
				end
			end

			props.Parent = value

			if value ~= nil then
				table.insert(rawget(value, "_children"), self)
			end
			return
		end

		local props = rawget(self, "_props")
		local previous = props[key]
		props[key] = value

		if previous ~= value then
			local signals = rawget(self, "_propSignals")
			if signals[key] ~= nil then
				signals[key]:Fire(value)
			end
			if rawget(self, "_signals").Changed ~= nil then
				self._signals.Changed:Fire(self)
			end
		end
	end,
}

Instance = {
	new = function(class, parent)
		local created = newInstance(class)
		instanceCounter += 1
		if parent ~= nil then
			created.Parent = parent
		end
		return created
	end,
}

instanceCounter = 0

--[[ Services ----------------------------------------------------------------- ]]

local services: {[string]: any} = {}
local steppedSignal = makeSignal()
local heartbeatSignal = makeSignal()
local downKeys: {[string]: boolean} = {}
local focusedBox: any = nil

local function jsonEncode(value): string
	if type(value) == "table" then
		local arrayLike = true

		for key in pairs(value) do
			if type(key) ~= "number" then
				arrayLike = false
			end
		end

		local parts = {}

		if arrayLike then
			for _, item in ipairs(value) do
				table.insert(parts, jsonEncode(item))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end

		-- Standard JSON: "key":value. Sorted so two encodes of the same table are equal,
		-- which is what the config round-trip specs compare.
		local keys = {}
		local lookup = {}
		for key in pairs(value) do
			local text = tostring(key)
			table.insert(keys, text)
			lookup[text] = key
		end
		table.sort(keys)

		for _, text in ipairs(keys) do
			table.insert(parts, '"' .. text .. '":' .. jsonEncode(value[lookup[text]]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(value) == "string" then
		return '"' .. value:gsub('"', '\\"') .. '"'
	elseif type(value) == "boolean" or type(value) == "number" then
		return tostring(value)
	end
	return "null"
end

local function jsonDecode(text: string)
	local position = 1

	local function skip()
		while text:sub(position, position):match("%s") ~= nil do
			position += 1
		end
	end

	local parseValue

	local function parseString()
		position += 1
		local parts = {}
		while position <= #text do
			local char = text:sub(position, position)
			if char == '"' then
				position += 1
				return table.concat(parts)
			end
			if char == "\\" then
				local escaped = text:sub(position + 1, position + 1)
				if escaped == "n" then
					table.insert(parts, "\n")
				elseif escaped == "t" then
					table.insert(parts, "\t")
				else
					table.insert(parts, escaped)
				end
				position += 2
			else
				table.insert(parts, char)
				position += 1
			end
		end
		error("harness: unterminated JSON string")
	end

	local function parseNumber()
		local start = position
		while text:sub(position, position):match("[%-%d%.eE%+]") ~= nil do
			position += 1
		end
		return tonumber(text:sub(start, position - 1))
	end

	parseValue = function()
		skip()
		local char = text:sub(position, position)

		if char == "{" then
			position += 1
			local out = {}
			skip()
			if text:sub(position, position) == "}" then
				position += 1
				return out
			end
			while true do
				skip()
				local key = parseString()
				skip()
				position += 1
				out[key] = parseValue()
				skip()
				local delimiter = text:sub(position, position)
				position += 1
				if delimiter == "}" then
					return out
				end
			end
		elseif char == "[" then
			position += 1
			local out = {}
			skip()
			if text:sub(position, position) == "]" then
				position += 1
				return out
			end
			while true do
				table.insert(out, parseValue())
				skip()
				local delimiter = text:sub(position, position)
				position += 1
				if delimiter == "]" then
					return out
				end
			end
		elseif char == '"' then
			return parseString()
		elseif char == "t" then
			position += 4
			return true
		elseif char == "f" then
			position += 5
			return false
		elseif char == "n" then
			position += 4
			return nil
		end

		return parseNumber()
	end

	return parseValue()
end

local function makeService(className: string)
	if services[className] ~= nil then
		return services[className]
	end

	local service = newInstance(className)

	if className == "RunService" then
		service._props.RenderStepped = steppedSignal
		service._props.Heartbeat = heartbeatSignal
	elseif className == "UserInputService" then
		service._props.InputBegan = makeSignal()
		service._props.InputEnded = makeSignal()
		service._props.TextBoxFocused = makeSignal()
		service._props.TextBoxFocusReleased = makeSignal()
		service.GetFocusedTextBox = function()
			return focusedBox
		end
		service.IsKeyDown = function(_, key)
			return downKeys[key.Name] == true
		end
		service.GetInputState = function()
			return false
		end
	elseif className == "GuiService" then
		service.GetGuiInset = function()
			return guiInset, guiInset
		end
	elseif className == "HttpService" then
		service.JSONEncode = function(_, value)
			return jsonEncode(value)
		end
		service.JSONDecode = function(_, text)
			return jsonDecode(text)
		end
	elseif className == "Players" then
		local player = newInstance("Player")
		player._props.Name = "Tester"
		player._props.DisplayName = "Tester"
		player._props.UserId = 1
		local playerGui = newInstance("PlayerGui")
		player._props.PlayerGui = playerGui
		player.GetMouse = function()
			return { X = viewportSize.X / 2, Y = viewportSize.Y / 2, ViewSizeX = viewportSize.X, ViewSizeY = viewportSize.Y }
		end
		service._props.LocalPlayer = player
		service.GetPlayers = function()
			return { player }
		end
	elseif className == "Workspace" then
		local camera = newInstance("Camera")
		camera._props.ViewportSize = viewportSize
		service._props.CurrentCamera = camera
	end

	services[className] = service
	return service
end

game = {
	PlaceId = 123456789,
	GameId = 987654321,
	Name = "Harness Place",
	GroupId = 0,
	GetService = function(_, className)
		return makeService(className)
	end,
	HttpGet = function(_, url)
		httpGetCalls += 1
		if httpGetHandler ~= nil then
			return httpGetHandler(url)
		end
		return ""
	end,
	GetChildren = function()
		return {}
	end,
}

workspace = makeService("Workspace")
CoreGui = makeService("CoreGui")
StarterGui = makeService("StarterGui")

--[[ Harness controls --------------------------------------------------------- ]]

fakeNow = 0

function harnessClock()
	return fakeNow
end

function harnessDate()
	return "2026-11-24"
end

function harnessTime()
	return 1766620800
end

pendingThreads = {}
-- { at = fakeNow + seconds, thread = thread, args = {…} } — the engine's scheduler is driven by
-- elapsed time, and a library that sleeps inside a spawned thread (a notification counting down,
-- a tooltip hover delay) only behaves if the stand-in does too.
pendingWaits = {}

local function schedule(seconds, thread, args, count)
	local at = fakeNow + math.max(0, seconds or 0)
	table.insert(pendingWaits, { at = at, thread = thread, args = args, count = count })
end

local function runDue()
	local index = 1
	while index <= #pendingWaits do
		local entry = pendingWaits[index]
		if entry.at <= fakeNow then
			table.remove(pendingWaits, index)
			if coroutine.status(entry.thread) ~= "dead" then
				if entry.args ~= nil then
					coroutine.resume(entry.thread, table.unpack(entry.args, 1, entry.count or #entry.args))
				else
					coroutine.resume(entry.thread)
				end
			end
		else
			index += 1
		end
	end
end

function stepClock(delta)
	fakeNow += delta
	steppedSignal:Fire(delta)

	local queued = pendingThreads
	pendingThreads = {}
	for _, thread in ipairs(queued) do
		if coroutine.status(thread) ~= "dead" then
			coroutine.resume(thread)
		end
	end

	runDue()
end

function pumpFrames(count, delta)
	for _ = 1, count do
		stepClock(delta or 1 / 60)
	end
end

function scheduledCount()
	return #pendingWaits
end

task = {
	-- task.wait suspends the caller when it is called from a coroutine, which is the only way a
	-- countdown loop can be tested at all. From the main chunk there is nothing to suspend, so it
	-- advances the clock directly and a spec can write it linearly.
	wait = function(seconds)
		local amount = seconds or 0.001
		if coroutine.isyieldable() then
			schedule(amount, coroutine.running(), nil, 0)
			local elapsed = coroutine.yield()
			return elapsed or amount
		end
		stepClock(amount)
		return amount
	end,
	spawn = function(fn, ...)
		local thread = coroutine.create(fn)
		coroutine.resume(thread, ...)
		return thread
	end,
	-- The engine forwards the trailing arguments into the deferred call, and a nil in them is
	-- meaningful (OnEnd(false) is a different report from OnEnd()). Capturing select("#") keeps
	-- that distinction instead of silently handing every callback a nil.
	defer = function(fn, ...)
		local args = { ... }
		local count = select("#", ...)
		local thread = coroutine.create(function()
			fn(table.unpack(args, 1, count))
		end)
		table.insert(pendingThreads, thread)
		return thread
	end,
	delay = function(seconds, fn, ...)
		local args = { ... }
		local count = select("#", ...)
		local thread = coroutine.create(function()
			fn(table.unpack(args, 1, count))
		end)
		schedule(seconds, thread, nil, 0)
		return thread
	end,
	loop = function(interval, fn)
		-- The engine hands the callback the elapsed time since the previous tick and re-arms
		-- itself, which is what a countdown or a debounce loop is written against.
		local last = fakeNow
		local thread
		local function arm()
			thread = coroutine.create(function()
				local elapsed = fakeNow - last
				last = fakeNow
				local stop = fn(elapsed)
				if stop ~= true and coroutine.status(thread) ~= "dead" then
					arm()
				end
			end)
			schedule(interval, thread, nil, 0)
		end
		arm()
		return thread
	end,
	cancel = function(thread)
		for index = #pendingThreads, 1, -1 do
			if pendingThreads[index] == thread then
				table.remove(pendingThreads, index)
			end
		end

		for index = #pendingWaits, 1, -1 do
			if pendingWaits[index].thread == thread then
				table.remove(pendingWaits, index)
			end
		end

		-- The engine kills the coroutine, it does not merely forget it. A Maid that only
		-- dropped its reference would leave a parked thread alive and the status assertion
		-- in spec 02 would pass for the wrong reason.
		--
		-- The thread doing the cancelling is the exception: a task.delay that has already fired
		-- runs its own callback, and closing it from there would cut that callback off
		-- mid-statement. The engine leaves a running thread to finish.
		if type(thread) == "thread" and coroutine.status(thread) ~= "dead" and thread ~= coroutine.running() then
			coroutine.close(thread)
		end
	end,
}

spawn = task.spawn
wait = task.wait

function warn(...)
	local parts = {}
	for _, value in ipairs({ ... }) do
		table.insert(parts, tostring(value))
	end
	print("[warn] " .. table.concat(parts, " "))
end

function tick()
	return fakeNow
end

function setViewport(width, height)
	viewportSize = vector2New(width, height)
	workspace.CurrentCamera.ViewportSize = viewportSize
end

function currentViewport()
	return viewportSize
end

function pressKey(name: string)
	downKeys[name] = true
	services.UserInputService._props.InputBegan:Fire({
		KeyCode = Enum.KeyCode[name],
		UserInputType = Enum.UserInputType.Keyboard,
		Position = Vector2.new(0, 0),
	})
end

function releaseKey(name: string)
	downKeys[name] = false
	services.UserInputService._props.InputEnded:Fire({
		KeyCode = Enum.KeyCode[name],
		UserInputType = Enum.UserInputType.Keyboard,
		Position = Vector2.new(0, 0),
	})
end

function isKeyDown(name: string)
	return downKeys[name] == true
end

function setFocusedTextBox(box)
	focusedBox = box
end

function getFocusedTextBoxStub()
	return focusedBox
end

function clickInstance(inst: any)
	if inst._signals.MouseButton1Click ~= nil then
		inst._signals.MouseButton1Click:Fire()
	end
end

-- The engine leaves the widget under the pointer before it enters the next one, and a stub that only
-- announced the arrival would let a tooltip that never hides on its own pass the suite.
local hovered = nil

function hoverInstance(inst: any)
	if inst == nil or inst == hovered then
		return
	end
	if hovered ~= nil then
		unhoverInstance(hovered)
	end
	hovered = inst
	if inst._signals.MouseEnter ~= nil then
		inst._signals.MouseEnter:Fire()
	end
end

function unhoverInstance(inst: any)
	if hovered == inst then
		hovered = nil
	end
	if inst ~= nil and inst._signals.MouseLeave ~= nil then
		inst._signals.MouseLeave:Fire()
	end
end

--[[ Executor globals --------------------------------------------------------- ]]

fileApiOn = true

-- When true, writing a property the class does not have raises instead of quietly becoming
-- an expando. Off by default because that is what the engine does; specs flip it on to prove
-- the library degrades on the clients that do not.
strictPropertyWrites = false

-- property name -> true to make writes of it raise while reads keep working. See __newindex.
readonlyWrites = {}

-- A global cannot carry a type annotation in Luau, so this one is a local that the file
-- helpers below close over.
local virtualFiles: {[string]: {bytes: string?, folder: boolean?}} = {}

local function requireFileApi(name: string)
	if not fileApiOn then
		error(name .. " is not available")
	end
end

makefolder = function(path)
	requireFileApi("makefolder")
	virtualFiles[path] = virtualFiles[path] or {}
	virtualFiles[path].folder = true
end

isfile = function(path)
	requireFileApi("isfile")
	local entry = virtualFiles[path]
	return entry ~= nil and entry.bytes ~= nil
end

isfolder = function(path)
	requireFileApi("isfolder")
	return virtualFiles[path] ~= nil
end

writefile = function(path, bytes)
	requireFileApi("writefile")
	virtualFiles[path] = { bytes = bytes }
end

readfile = function(path)
	requireFileApi("readfile")
	local entry = virtualFiles[path]
	if entry == nil or entry.bytes == nil then
		error("harness: no such file " .. path)
	end
	return entry.bytes
end

delfile = function(path)
	requireFileApi("delfile")
	virtualFiles[path] = nil
end

listfiles = function(path)
	requireFileApi("listfiles")
	local out = {}
	for file, entry in pairs(virtualFiles) do
		if file:sub(1, #path) == path and entry.bytes ~= nil then
			table.insert(out, file)
		end
	end
	table.sort(out)
	return out
end

getcustomasset = function(path)
	requireFileApi("getcustomasset")
	return "rbxasset://custom/" .. path
end

getsynasset = function(bytes)
	requireFileApi("getsynasset")
	return "rbxasset://syn/" .. tostring(#bytes)
end

genvTable = {}

function getgenv()
	return genvTable
end

httpGetCalls = 0
httpRequestCalls = 0
httpGetHandler = nil
httpHandler = nil

request = function(spec)
	httpRequestCalls += 1
	if httpHandler ~= nil then
		return httpHandler(spec)
	end
	return { Success = true, StatusCode = 200, Body = "" }
end

--[[ Counters the specs assert against ---------------------------------------- ]]

function resetInstanceCounter()
	instanceCounter = 0
end

function instanceCount()
	return instanceCounter
end

function countDescendants(root: any): number
	local total = 0
	local stack = { root }
	local cursor = 1

	while stack[cursor] ~= nil do
		local node = stack[cursor]
		cursor += 1
		for _, child in ipairs(node:GetChildren()) do
			total += 1
			table.insert(stack, child)
		end
	end

	return total
end
