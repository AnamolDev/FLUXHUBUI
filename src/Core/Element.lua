--[[
	Core/Element — the shared building blocks every widget is made of.

	Components should not be assembling UICorner + UIStroke + UIPadding by hand in twenty places:
	that is how a library ends up with three slightly different panels and a theme change that
	misses one of them. Everything here takes the component's Maid so the instance it creates is
	owned by the thing that asked for it, and takes a *role name* rather than a colour so a theme
	swap reaches it.

	Every function in this module is allowed to be called on a client that lacks half the engine:
	rounding, strokes and padding are all optional members, and Guard.set decides whether the
	element exists rather than the caller discovering it crashed.
]]

local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local ThemeManager = require("Flux/Systems/ThemeManager")
local IconManager = require("Flux/Systems/IconManager")
local AnimationManager = require("Flux/Systems/AnimationManager")
local Table = require("Flux/Utilities/Table")

local Players = Guard.service("Players")

local Element = {}

local defaultZIndex = 1

--- The ScreenGui a hub owns. Created once and reused, because a second ScreenGui means two click
--- capturers and two sets of ZIndex scopes.
function Element.root(maid: any, options: { Name: string?, Order: number?, ResetOnSpawn: boolean? }): any
	options = options or {}

	local player = Players and Players.LocalPlayer
	local parent = player and player:FindFirstChildOfClass("PlayerGui") or (player and player:FindFirstChildOfClass("CoreGui"))

	if parent == nil then
		parent = Guard.service("CoreGui")
	end

	local gui = Instance.new("ScreenGui", parent, {
		Name = options.Name or "FluxHub",
		ResetOnSpawn = options.ResetOnSpawn == true,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = options.Order or 1000,
		ResetOnSpawnBehavior = nil,
	})

	if maid ~= nil then
		maid:giveInstance(gui)
	end

	return gui
end

--- A filled, rounded, optionally bordered rectangle — the shape almost every surface is.
--- Returns the frame; the corner and stroke are given to the maid.
function Element.panel(maid: any, parent: any, name: string, options: {
	Color: string?,
	Transparency: number?,
	Radius: string?,
	RadiusOffset: number?,
	Stroke: string?,
	StrokeTransparency: number?,
	Thickness: number?,
	Clips: boolean?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	ZIndex: number?,
	Visible: boolean?,
}): any
	local frame = Instance.new("Frame", parent, {
		Name = name,
		BackgroundColor3 = ThemeManager.color(options and options.Color or "Panel"),
		BackgroundTransparency = options and options.Transparency or 0,
		Size = options and options.Size or UDim2.new(),
		Position = options and options.Position or UDim2.new(),
		AnchorPoint = options and options.AnchorPoint or Vector2.new(0, 0),
		LayoutOrder = options and options.LayoutOrder or 0,
		ZIndex = options and options.ZIndex or defaultZIndex,
		Visible = options.Visible ~= false,
		BorderSizePixel = 0,
	})

	if options and options.Clips then
		frame.ClipsDescendants = true
	end

	local role = options and options.Color or "Panel"
	if maid ~= nil then
		maid:give(ThemeManager.bind(frame, "BackgroundColor3", role))
	end

	if options and options.Radius ~= nil then
		local metric = ThemeManager.metric(options.Radius) or 0
		local radius = (options.RadiusOffset or 0) + metric
		local corner = Instance.corner(frame, UDim.new(0, math.max(0, radius)))
		if maid ~= nil then
			maid:giveFunction(function()
				corner:Destroy()
			end)
		end
	end

	if options and options.Stroke then
		local stroke = Instance.stroke(
			frame,
			ThemeManager.color(options.Stroke),
			options.Thickness or ThemeManager.metric("StrokeThickness") or 1,
			options.StrokeTransparency or 0
		)
		if stroke ~= nil then
			if maid ~= nil then
				maid:giveFunction(function()
					stroke:Destroy()
				end)
				maid:give(ThemeManager.bind(stroke, "Color", options.Stroke))
			end
		end
	end

	return frame
end

--- Text bound to a type role: colour, font and size all follow the theme.
function Element.label(maid: any, parent: any, name: string, options: {
	Text: string?,
	Role: string?,
	Font: string?,
	TextSize: number?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	Alignment: Enum.TextXAlignment?,
	Vertical: Enum.TextYAlignment?,
	Wrap: boolean?,
	AutoWidth: boolean?,
	MaxWidth: number?,
	SizeConstraint: Enum.SizeConstraint?,
	ZIndex: number?,
	Transparency: number?,
}): any
	options = options or {}
	local role = options.Role or "TextPrimary"

	local label = Instance.new("TextLabel", parent, {
		Name = name,
		Text = options.Text or "",
		BackgroundTransparency = 1,
		TextColor3 = ThemeManager.color(role) or Color3.fromRGB(231, 231, 237),
		Font = ThemeManager.font(options.Font or "Body"),
		TextSize = options.TextSize or 14,
		TextXAlignment = options.Alignment or Enum.TextXAlignment.Left,
		TextYAlignment = options.Vertical or Enum.TextYAlignment.Center,
		TextWrapped = options.Wrap == true,
		Size = options.Size or UDim2.fromScale(1, 1),
		Position = options.Position or UDim2.new(),
		AnchorPoint = options.AnchorPoint or Vector2.new(0, 0),
		LayoutOrder = options.LayoutOrder or 0,
		ZIndex = options.ZIndex or defaultZIndex,
		TextTransparency = options.Transparency or 0,
	})

	-- Auto-sizing text is a TextLabel's default behaviour; opting into a width constraint is what
	-- stops a long paragraph running off a panel.
	if options.AutoWidth then
		label.AutomaticSize = Enum.AutomaticSize.X
		if options.MaxWidth then
			label.TextWrapped = true
			label.Size = UDim2.fromOffset(options.MaxWidth, label.Size.Y.Offset)
		end
	elseif options.Wrap then
		label.AutomaticSize = Enum.AutomaticSize.Y
	end

	if maid ~= nil then
		maid:give(ThemeManager.bind(label, "TextColor3", role))
	end

	return label
end

--- Bind a property to a role, replacing whatever role that property was bound to before.
--- Selection states need this: a nav label is TextSecondary until it becomes the active tab, and
--- a plain re-write would then be undone by the next theme swap.
local binds = setmetatable({}, { __mode = "k" })

function Element.tint(maid: any, instance: any, property: string, role: string): boolean
	if instance == nil or role == nil then
		return false
	end

	local perInstance = binds[instance]
	if perInstance == nil then
		perInstance = {}
		binds[instance] = perInstance
	end

	local previous = perInstance[property]
	if previous ~= nil then
		previous()
	end

	local unbind = ThemeManager.bind(instance, property, role)
	perInstance[property] = unbind

	if maid ~= nil then
		maid:giveFunction(function()
			local entry = binds[instance]
			if entry ~= nil then
				entry[property] = nil
			end
			unbind()
		end)
	end

	return true
end

--- A glyph, coloured by role. Returns the IconManager handle so the caller can re-tint it.
function Element.icon(maid: any, parent: any, name: string, options: {
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Role: string?,
	LayoutOrder: number?,
	ZIndex: number?,
	Transparency: number?,
}): any
	options = options or {}
	local role = options.Role or "TextSecondary"

	local handle = IconManager.attach(parent, name, {
		Name = "Icon_" .. name,
		Size = options.Size,
		Position = options.Position,
		AnchorPoint = options.AnchorPoint,
		Color = ThemeManager.color(role),
		LayoutOrder = options.LayoutOrder,
		ZIndex = options.ZIndex,
		Transparency = options.Transparency,
	})

	if maid ~= nil then
		maid:giveFunction(function()
			if handle.instance ~= nil then
				handle.instance:Destroy()
			end
		end)

		-- Unfiltered on purpose: `setRole` below moves the colour this closure reads, so a role
		-- list captured now would wake the repaint for the wrong token after a selection change.
		maid:give(ThemeManager.bindFn(function(tokens)
			local value = tokens.colors[role]
			if value ~= nil then
				handle:setColor(value)
			end
		end, nil))
	end

	handle.setRole = function(nextRole: string)
		role = nextRole
		local value = ThemeManager.color(role)
		if value ~= nil then
			handle:setColor(value)
		end
	end

	return handle
end

--- A full-bleed hover/press layer: the affordance almost every interactive row has.
--- Returns the instance it attached to, plus whether motion is available.
function Element.interactive(instance: any, options: {
	Maid: any,
	HoverColor: string?,
	OnEnter: (() -> ())?,
	OnLeave: (() -> ())?,
	OnClick: (() -> ())?,
}): any
	options = options or {}
	local maid = options.Maid

	local baseColor = Guard.get(instance, "BackgroundColor3")
	local hoverRole = options.HoverColor or "Hover"
	local pressed = false

	local function paint(color: Color3?, transparency: number?)
		if color ~= nil then
			Guard.set(instance, "BackgroundColor3", color)
		end
		if transparency ~= nil then
			Guard.set(instance, "BackgroundTransparency", transparency)
		end
	end

	local function restore(instant: boolean?)
		local goals = { BackgroundColor3 = baseColor }
		if instant then
			paint(baseColor)
			return
		end
		AnimationManager.to(instance, goals, { Duration = 0.12, Easing = "outQuad" })
	end

	if maid ~= nil then
		maid:give(ThemeManager.bindFn(function(tokens)
			-- The base colour is a role, so a theme change must move it even while the pointer is
			-- sitting on the row; otherwise the hovered element keeps the old palette.
			if not pressed then
				paint(tokens.colors[hoverRole] or baseColor)
			end
		end, { hoverRole }))
	end

	local enter = Guard.get(instance, "MouseEnter")
	if enter ~= nil then
		if maid ~= nil then
			maid:giveConnection(enter:Connect(function()
				AnimationManager.to(instance, { BackgroundColor3 = ThemeManager.color(hoverRole) or baseColor }, {
					Duration = 0.12,
					Easing = "outQuad",
				})
				if options.OnEnter ~= nil then
					options.OnEnter()
				end
			end))
		else
			enter:Connect(function()
				if options.OnEnter ~= nil then
					options.OnEnter()
				end
			end)
		end
	end

	local leave = Guard.get(instance, "MouseLeave")
	if leave ~= nil and maid ~= nil then
		maid:giveConnection(leave:Connect(function()
			pressed = false
			restore()
			if options.OnLeave ~= nil then
				options.OnLeave()
			end
		end))
	end

	local down = Guard.get(instance, "MouseButton1Down")
	if down ~= nil and maid ~= nil then
		maid:giveConnection(down:Connect(function()
			pressed = true
			AnimationManager.to(instance, { BackgroundColor3 = ThemeManager.color("Selection") or baseColor }, {
				Duration = 0.08,
				Easing = "outQuad",
			})
		end))
	end

	local up = Guard.get(instance, "MouseButton1Up")
	if up ~= nil and maid ~= nil then
		maid:giveConnection(up:Connect(function()
			pressed = false
			restore()
			if options.OnClick ~= nil then
				options.OnClick()
			end
		end))
	end

	return instance
end

--- A click-anywhere-else detector, used by dropdowns, colour pickers and context menus. One
--- connection is shared for the whole library: a per-widget InputBegan listener is how a menu
--- with forty open widgets costs forty callbacks per click.
local clickWatchers = {}
local clickConnection: RBXScriptConnection? = nil
local UserInputService = Guard.service("UserInputService")

local function ensureClickWatcher()
	if clickConnection ~= nil or UserInputService == nil then
		return
	end

	clickConnection = UserInputService.InputBegan:Connect(function(input, processed)
		local targets = {}
		for _, watcher in pairs(clickWatchers) do
			table.insert(targets, watcher)
		end

		for _, watcher in ipairs(targets) do
			watcher(input, processed)
		end
	end)
end

--- Call the function when the pointer clicks outside `instance`. Returns an unbind.
function Element.outsideClick(instance: any, fn: () -> ()): () -> ()
	local key = tostring(instance)
	local tracker = function(input: any, _processed: boolean)
		local inputType = Guard.get(input, "EnumType")
		local isClick = inputType ~= nil
			and (inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch)
		if not isClick then
			return
		end

		local ok, parent = pcall(function()
			return instance.Parent
		end)
		if not ok or parent == nil then
			-- The widget is gone, so this watcher is dead weight; unhook rather than keep
			-- testing an instance that no longer exists.
			clickWatchers[key] = nil
			return
		end

		local position = Guard.get(input, "Position")
		local absolute = Guard.get(instance, "AbsolutePosition")
		local size = Guard.get(instance, "AbsoluteSize")
		if position == nil or absolute == nil or size == nil then
			return
		end

		local inside = position.X >= absolute.X
			and position.X <= absolute.X + size.X
			and position.Y >= absolute.Y
			and position.Y <= absolute.Y + size.Y

		if not inside then
			fn()
		end
	end

	clickWatchers[key] = tracker
	ensureClickWatcher()

	return function()
		clickWatchers[key] = nil
		if next(clickWatchers) == nil and clickConnection ~= nil then
			clickConnection:Disconnect()
			clickConnection = nil
		end
	end
end

function Element.watcherCount(): number
	local count = 0
	for _ in pairs(clickWatchers) do
		count += 1
	end
	return count
end

--- Rounded corners the theme owns: pass the metric role, not a number, so the radius moves with
--- the preset. Returns whether the client accepted the corner.
function Element.round(maid: any, instance: any, role: string, offset: number?): boolean
	local metric = ThemeManager.metric(role)
	if metric == nil then
		return false
	end
	local corner = Instance.corner(instance, UDim.new(0, math.max(0, metric + (offset or 0))))
	if corner == nil then
		return false
	end
	if maid ~= nil then
		maid:giveFunction(function()
			corner:Destroy()
		end)
	end
	return true
end

--- Padding from a role-defined number, e.g. Element.pad(maid, frame, "ContentPadding").
function Element.pad(maid: any, instance: any, role: string): boolean
	local metric = ThemeManager.metric(role)
	if metric == nil then
		return false
	end
	local padding = Instance.pad(instance, {
		Top = UDim.new(0, metric),
		Bottom = UDim.new(0, metric),
		Left = UDim.new(0, metric),
		Right = UDim.new(0, metric),
	})
	if padding == nil then
		return false
	end
	if maid ~= nil then
		maid:giveFunction(function()
			padding:Destroy()
		end)
	end
	return true
end

--- A vertical stack that owns its spacing, so a group of rows does not need to know the metric.
function Element.stack(maid: any, parent: any, options: { Gap: string?, Sort: boolean?, Padding: number? }): any
	local gap = options.Padding or 8
	if options.Gap ~= nil then
		gap = ThemeManager.metric(options.Gap) or gap
	end

	local list = Instance.list(parent, {
		Padding = UDim.new(0, gap),
		SortOrder = options.Sort ~= false and Enum.SortOrder.LayoutOrder or Enum.SortOrder.Name,
	})

	if maid ~= nil and list ~= nil then
		maid:giveFunction(function()
			list:Destroy()
		end)

		if options.Gap then
			maid:give(ThemeManager.bindFn(function(tokens)
				local value = tokens.metrics[options.Gap]
				if value ~= nil then
					Guard.set(list, "Padding", UDim.new(0, value))
				end
			end, { options.Gap }))
		end
	end

	return list
end

--- The anatomy of a settings row: a label (with optional description) on the left, the control
--- itself on the right. Twelve components are this shape, so it is written once — and a change to
--- the spacing between a title and its hint reaches all twelve.
---
--- The text block auto-sizes and the body is pinned to the right edge, so a two-line description
--- grows the row instead of overlapping the control, which is what a fixed-height row does badly.
function Element.row(maid: any, parent: any, name: string, options: {
	Label: string?,
	Desc: string?,
	Height: number?,
	Order: number?,
	ZIndex: number?,
	BodyWidth: number?,
}): {[string]: any}
	options = options or {}
	local height = options.Height or ThemeManager.metric("RowHeight") or 30
	local zIndex = options.ZIndex or 5

	local root = Element.panel(maid, parent, name, {
		Transparency = 1,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = options.Order or 0,
		ZIndex = zIndex,
	})

	local text = Instance.new("Frame", root, {
		Name = "Text",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -(options.BodyWidth or 130), 1, 0),
		ZIndex = zIndex,
	})
	text.AutomaticSize = Enum.AutomaticSize.None
	Instance.new("UIListLayout", text, {
		FillDirection = Enum.FillDirection.Vertical,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	local title = Element.label(maid, text, "Title", {
		Text = options.Label or "",
		Role = "TextPrimary",
		TextSize = 13,
		Size = UDim2.new(1, 0, 0, options.Desc ~= nil and 15 or height),
		ZIndex = zIndex,
	})

	local desc = nil
	if type(options.Desc) == "string" and options.Desc ~= "" then
		desc = Element.label(maid, text, "Hint", {
			Text = options.Desc,
			Role = "TextMuted",
			TextSize = 11,
			Wrap = true,
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 13),
			ZIndex = zIndex,
		})
		-- Two lines need two lines' worth of height, or the hint is clipped by the row.
		root.Size = UDim2.new(1, 0, 0, height + 12)
	end

	local body = Instance.new("Frame", root, {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromOffset(options.BodyWidth or 120, height),
		Position = UDim2.new(1, 0, 0.5, 0),
		ZIndex = zIndex,
	})
	Instance.new("UIListLayout", body, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
	})

	return { Root = root, Text = text, Title = title, Hint = desc, Body = body }
end

--- Wire a widget to a config flag: restore what was saved, keep the store current, and release the
--- binding when the widget is destroyed. Components take a Flag and get persistence for free.
function Element.bindConfig(maid: any, key: string?, apply: (any) -> (), read: (() -> any)?): boolean
	if type(key) ~= "string" or key == "" then
		return false
	end

	local ConfigManager = require("Flux/Systems/ConfigManager")
	local unbind = ConfigManager.bind(key, { Apply = apply, Read = read })
	maid:giveFunction(unbind)
	return true
end

--- Stage a widget's value under its flag. Nil keys are a no-op rather than an error, because a
--- host that does not use configs should not have to pass Flag=false everywhere.
function Element.pushConfig(key: string?, value: any, options: { Immediate: boolean }?)
	if type(key) ~= "string" or key == "" then
		return false
	end
	local ConfigManager = require("Flux/Systems/ConfigManager")
	return ConfigManager.set(key, value, options)
end

--- Register a finished row with the search index so it can be filtered out by term. Returns the id.
function Element.searchable(group: any, row: any, label: string, extra: string?): any
	if group == nil or type(group.track) ~= "function" then
		return nil
	end
	return group:track(row, label, extra)
end

--- Read the argument of a widget method that may have been called with a colon.
---
--- The component handles expose their methods as fields, so the library can call them plain
--- (`handle.Set(true)`) while a host almost always writes `handle:Set(true)` — which hands the
--- method the handle as its first argument. One shim keeps both readings correct, so a component
--- never has to decide which caller it was written for.
function Element.recv(self: any, a: any, b: any): any
	if a == self then
		return b
	end
	return a
end

--- Release a row's slot in its card when the component is destroyed on its own. Going through the
--- group rather than the search index alone is what keeps the card's match count honest.
function Element.releaseSearch(group: any, row: any): boolean
	local id = row ~= nil and row.SearchId or nil
	if id == nil then
		return false
	end
	if group ~= nil and type(group.forget) == "function" then
		return group:forget(id)
	end
	local SearchManager = require("Flux/Systems/SearchManager")
	return SearchManager.unregister(id)
end

--- Values a component commonly needs defaulted, in one place, so every widget's option table reads
--- the same way.
function Element.options(options: {[string]: any}?, defaults: {[string]: any}): {[string]: any}
	return Table.withDefaults(options, defaults)
end

return Element
