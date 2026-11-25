--[[
	Core/Window — the shell: chrome, drag, navigation, and the content area a tab builds into.

	Three decisions here shape the rest of the library:

	  * The window is positioned by an offset of its own centre, in the layout's authored units,
	    with AnchorPoint (0.5, 0.5). A drag accumulates the pointer delta divided by the live
	    UIScale (LayoutManager.toLocal), because a screen pixel moves a window 1/scale authored
	    units — multiply the raw mouse delta instead and the window drifts away from the cursor on
	    any device that is not rendering at the authored size.
	  * Navigation is a horizontal strip under the header, not a left rail. A rail spends 196px of
	    a 900px window on nine words, and the page is what people read; the strip scrolls sideways
	    when it overflows instead of reflowing into a second layout.
	  * A tab's rows are not built until the tab is opened. The window itself is about forty
	    instances; the first page is the cost, so that is what gets sliced across frames.
]]

local Maid = require("Flux/Utilities/Maid")
local Instance = require("Flux/Utilities/Instance")
local Element = require("Flux/Core/Element")
local Guard = require("Flux/Utilities/Guard")
local ThemeManager = require("Flux/Systems/ThemeManager")
local LayoutManager = require("Flux/Systems/LayoutManager")
local AnimationManager = require("Flux/Systems/AnimationManager")
local NotificationManager = require("Flux/Systems/NotificationManager")
local TooltipManager = require("Flux/Systems/TooltipManager")
local InputManager = require("Flux/Systems/InputManager")
local SearchManager = require("Flux/Systems/SearchManager")
local Lifecycle = require("Flux/Core/Lifecycle")
local Math = require("Flux/Utilities/Math")

local UserInputService = Guard.service("UserInputService")

local Window = {}
Window.__index = Window

local SEARCH_WIDTH = 210
local SEARCH_HEIGHT = 30
local CLUSTER_WIDTH = 300

local function metric(role: string, fallback: number): number
	return ThemeManager.metric(role) or fallback
end

local function headerHeight(): number
	return metric("HeaderHeight", 72)
end

local function footerHeight(): number
	return metric("FooterHeight", 40)
end

--- A 28px square icon button in the header: minimise and close, and nothing else. The reference
--- design keeps the chrome quiet, so these never carry a border.
local function iconButton(maid: any, parent: any, name: string, glyph: string, onClick: () -> ()): any
	local button = Instance.new("TextButton", parent, {
		Name = name,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = ThemeManager.color("PanelSecondary"),
		Size = UDim2.fromOffset(28, 28),
		BorderSizePixel = 0,
		ZIndex = 6,
	})

	Element.round(maid, button, "RadiusChip")
	maid:give(ThemeManager.bind(button, "BackgroundColor3", "PanelSecondary"))

	Element.icon(maid, button, glyph, {
		Role = "TextSecondary",
		Size = UDim2.fromOffset(13, 13),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 7,
	})

	Element.interactive(button, { Maid = maid, OnClick = onClick })
	return button
end

function Window.new(owner: any, options: {[string]: any}?)
	options = Element.options(options, {
		Title = "Flux Hub",
		Subtitle = "",
		Icon = "layers",
		ToggleKey = Enum.KeyCode.RightControl,
		DisplayOrder = 1000,
	})

	-- A host that authors its UI larger or smaller than 900x560 says so here; the responsive
	-- layer derives everything else from that one number.
	local size = options.Size
	if type(size) == "number" then
		LayoutManager.setBase(size, size * 0.62)
	elseif type(size) == "table" and (size.X ~= nil or size.width ~= nil) then
		local width = size.X or size.width
		local height = size.Y or size.height or (width * 0.62)
		LayoutManager.setBase(math.max(320, width :: any), math.max(240, height :: any))
	end
	options.Size = nil

	LayoutManager.watch()

	local base = LayoutManager.base()
	local viewport = LayoutManager.viewport()

	local self = setmetatable({
		Owner = owner,
		Title = options.Title,
		Subtitle = options.Subtitle,
		TabOrder = {},
		Tabs = {},
		Active = nil,
		Open = true,
		Minimised = false,
		Destroyed = false,
		_offset = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5),
		_fullHeight = base.Y,
	}, Window)

	local maid = Maid.new()
	self.Maid = maid
	Lifecycle.register(self)

	local gui = Element.root(maid, {
		Name = options.Name or "FluxHub",
		Order = options.DisplayOrder,
		ResetOnSpawn = options.ResetOnSpawn == true,
	})
	self.Gui = gui
	LayoutManager.apply(gui)

	self.Root = Element.panel(maid, gui, "Root", {
		Color = "WindowBackground",
		Radius = "RadiusWindow",
		Stroke = "BorderPrimary",
		Size = UDim2.fromOffset(base.X, base.Y),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(self._offset.X, self._offset.Y),
		Clips = true,
		ZIndex = 2,
	})

	self:_buildHeader(maid, options)
	self:_buildBody(maid)
	self:_buildFooter(maid)
	self:_applyResponsive(LayoutManager.isMobile())

	maid:give(LayoutManager.Changed:Connect(function()
		self:onViewportChanged()
	end))

	NotificationManager.attach(gui)

	-- `ToggleKey = false` is how a host says "I own my own hotkey"; an omitted one takes the default
	-- from the options table, so the two cases must not be collapsed into `~= nil`.
	if options.ToggleKey ~= nil and options.ToggleKey ~= false then
		self._toggle = InputManager.bind({
			Name = "window:" .. tostring(options.Title),
			Key = options.ToggleKey,
			AllowWhileTyping = true,
			Callback = function()
				self:Toggle()
			end,
		})
	end

	AnimationManager.play(self.Root, "PopIn", { Duration = 0.22 })
	return self
end

function Window:_buildHeader(maid: any, options: {[string]: any})
	local header = Element.panel(maid, self.Root, "Header", {
		Transparency = 1,
		Size = UDim2.new(1, 0, 0, headerHeight()),
		ZIndex = 5,
	})
	self.Header = header

	-- One hairline separates the title block from the page. The window reads as a single surface,
	-- so this is a line rather than a second panel.
	local separator = Instance.new("Frame", header, {
		Name = "Separator",
		BackgroundColor3 = ThemeManager.color("BorderPrimary"),
		BackgroundTransparency = 0.4,
		Size = UDim2.new(1, -32, 0, 1),
		Position = UDim2.new(0, 16, 1, -1),
		BorderSizePixel = 0,
		ZIndex = 5,
	})
	maid:give(ThemeManager.bind(separator, "BackgroundColor3", "BorderPrimary"))
	maid:giveFunction(function()
		separator:Destroy()
	end)

	local brand = Element.panel(maid, header, "Brand", {
		Color = "AccentSoft",
		Radius = "RadiusField",
		Size = UDim2.fromOffset(34, 34),
		Position = UDim2.new(0, 16, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 6,
	})
	Element.icon(maid, brand, options.Icon or "layers", {
		Role = "Accent",
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 7,
	})

	local titleBlock = Instance.new("Frame", header, {
		Name = "TitleBlock",
		BackgroundTransparency = 1,
		-- 34 brand + 12 gap on the left, the control cluster on the right, 16px of air between.
		Size = UDim2.new(1, -(58 + CLUSTER_WIDTH + 16), 1, 0),
		Position = UDim2.new(0, 58, 0, 0),
		BorderSizePixel = 0,
		ZIndex = 6,
	})
	maid:giveFunction(function()
		titleBlock:Destroy()
	end)
	Instance.new("UIListLayout", titleBlock, {
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	self.TitleBlock = titleBlock

	self.TitleLabel = Element.label(maid, titleBlock, "Title", {
		Text = self.Title,
		Role = "TextPrimary",
		Font = "Title",
		TextSize = 17,
		Size = UDim2.new(1, 0, 0, 21),
		ZIndex = 6,
	})

	self.SubtitleLabel = Element.label(maid, titleBlock, "Subtitle", {
		Text = self.Subtitle,
		Role = "TextMuted",
		TextSize = 12,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 15),
		ZIndex = 6,
	})

	local controls = Instance.new("Frame", header, {
		Name = "Controls",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(CLUSTER_WIDTH, 30),
		Position = UDim2.new(1, -16, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BorderSizePixel = 0,
		ZIndex = 6,
	})
	maid:giveFunction(function()
		controls:Destroy()
	end)
	Instance.new("UIListLayout", controls, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	-- The search field is part of the chrome, not of the page: it filters whatever is open. It is
	-- held as `SearchHost` because `Window:Search` is the filtering method and an instance field of
	-- that name would shadow it on the object.
	self.SearchHost = self:_buildSearch(maid, controls)

	self.MinimizeButton = iconButton(maid, controls, "Minimize", "minus", function()
		self:Minimize()
	end)
	self.CloseButton = iconButton(maid, controls, "Close", "close", function()
		self:Close()
	end)
	self.MinimizeButton.LayoutOrder = 1
	self.CloseButton.LayoutOrder = 2

	TooltipManager.attach(self.MinimizeButton, "Minimise the window")
	TooltipManager.attach(self.CloseButton, "Close the hub")

	self:_enableDrag(header)
end

--- The header is the grab handle. Movement is tracked on UserInputService rather than the frame
--- so a fast drag that outruns the header keeps following the pointer instead of dropping.
function Window:_enableDrag(handle: any)
	local dragging = false
	local last: Vector2? = nil

	local function remember(input: any): Vector2?
		local point = Guard.get(input, "Position")
		if point == nil then
			return nil
		end
		return LayoutManager.toLocal(point)
	end

	local function begin(input: any)
		if self.Minimised then
			return
		end
		dragging = true
		last = remember(input)
	end

	local function move(input: any)
		if not dragging then
			return
		end
		local now = remember(input)
		if now == nil or last == nil then
			return
		end
		self:_move(self._offset.X + (now.X - last.X), self._offset.Y + (now.Y - last.Y))
		last = now
	end

	local function finish()
		dragging = false
		last = nil
	end

	local down = Guard.get(handle, "MouseButton1Down")
	local up = Guard.get(handle, "MouseButton1Up")
	if down ~= nil and up ~= nil then
		self.Maid:giveConnection(down:Connect(begin))
		self.Maid:giveConnection(up:Connect(finish))
	end

	if UserInputService ~= nil then
		local changed = Guard.get(UserInputService, "InputChanged")
		if changed ~= nil then
			self.Maid:giveConnection(changed:Connect(function(input)
				if Guard.get(input, "EnumType") == Enum.UserInputType.MouseMovement then
					move(input)
				end
			end))
		end

		local ended = Guard.get(UserInputService, "InputEnded")
		if ended ~= nil then
			self.Maid:giveConnection(ended:Connect(function(input)
				local kind = Guard.get(input, "EnumType")
				if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
					finish()
				end
			end))
		end
	end

	-- Touch has no separate movement stream on the service in the way a mouse does, so the
	-- gesture is also handled on the frame itself.
	local inputChanged = Guard.get(handle, "InputChanged")
	local inputBegan = Guard.get(handle, "InputBegan")
	local inputEnded = Guard.get(handle, "InputEnded")

	if inputBegan ~= nil and inputChanged ~= nil and inputEnded ~= nil then
		self.Maid:giveConnection(inputBegan:Connect(function(input)
			if Guard.get(input, "EnumType") == Enum.UserInputType.Touch then
				begin(input)
			end
		end))
		self.Maid:giveConnection(inputChanged:Connect(function(input)
			if Guard.get(input, "EnumType") == Enum.UserInputType.Touch then
				move(input)
			end
		end))
		self.Maid:giveConnection(inputEnded:Connect(function(input)
			if Guard.get(input, "EnumType") == Enum.UserInputType.Touch then
				finish()
			end
		end))
	end
end

--- Place the window's centre at (x, y) authored units, kept inside the viewport with a margin so
--- a drag can never park the whole menu off screen.
function Window:_move(x: number, y: number)
	local base = LayoutManager.base()
	local viewport = LayoutManager.viewport()
	local margin = 12

	local minX = margin + base.X * 0.35
	local maxX = math.max(minX, viewport.X - margin - base.X * 0.35)
	local minY = margin + headerHeight() * 0.5
	local maxY = math.max(minY, viewport.Y - margin - headerHeight() * 0.5)

	self._offset = Vector2.new(Math.clamp(x, minX, maxX), Math.clamp(y, minY, maxY))
	self.Root.Position = UDim2.fromOffset(self._offset.X, self._offset.Y)
end

function Window:_clampIntoView()
	self:_move(self._offset.X, self._offset.Y)
end

function Window:_buildBody(maid: any)
	local top = headerHeight()
	local bottom = footerHeight()
	local strip = metric("NavHeight", 52)

	local body = Element.panel(maid, self.Root, "Body", {
		Transparency = 1,
		Size = UDim2.new(1, 0, 1, -(top + bottom)),
		Position = UDim2.new(0, 0, 0, top),
		ZIndex = 3,
	})
	self.Body = body

	local bar = Element.panel(maid, body, "TabBar", {
		Transparency = 1,
		Size = UDim2.new(1, 0, 0, strip),
		ZIndex = 4,
	})
	self.Nav = bar

	-- Nine tabs will not fit a 900px strip, and a wrapped second row would put the active tab out
	-- of reach of the eye. The strip scrolls sideways instead, so it keeps one baseline.
	local scroller = Instance.new("ScrollingFrame", bar, {
		Name = "Tabs",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 0,
		ScrollingEnabled = true,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 4,
	})
	maid:giveFunction(function()
		scroller:Destroy()
	end)
	self.NavScroller = scroller

	self.NavStack = Instance.new("UIListLayout", scroller, {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 2),
	})
	maid:giveFunction(function()
		self.NavStack:Destroy()
	end)

	local inset = Instance.new("UIPadding", scroller, {
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
	})
	maid:giveFunction(function()
		inset:Destroy()
	end)

	-- The strip is told apart from the page by a hairline, the same device the header uses; a fill
	-- difference alone disappears on a panel that is already two steps off black.
	local edge = Instance.new("Frame", bar, {
		Name = "Edge",
		BackgroundColor3 = ThemeManager.color("BorderPrimary"),
		BackgroundTransparency = 0.4,
		Size = UDim2.new(1, -28, 0, 1),
		Position = UDim2.new(0, 14, 1, -1),
		BorderSizePixel = 0,
		ZIndex = 5,
	})
	maid:give(ThemeManager.bind(edge, "BackgroundColor3", "BorderPrimary"))
	maid:giveFunction(function()
		edge:Destroy()
	end)

	local host = Element.panel(maid, body, "ContentHost", {
		Transparency = 1,
		Size = UDim2.new(1, 0, 1, -strip),
		Position = UDim2.new(0, 0, 0, strip),
		ZIndex = 3,
	})
	self.ContentHost = host

	-- Each tab owns a page inside this host. Sharing one scrolling frame across tabs would mean
	-- re-parenting groupboxes on every click, which throws away their scroll position, re-runs
	-- their entrance animations and, on a big page, re-creates the instances the lazy build was
	-- written to avoid.
	self.Pages = {}
end

--- The box filters the page that is open. It lives in the header so the strip and the page each
--- get the window's full width, and because a field at the head of the chrome is where a person
--- looks for one; a rail-internal box is a second layout to keep in sync for no gain.
function Window:_buildSearch(maid: any, parent: any): any
	local field = Element.panel(maid, parent, "Search", {
		Color = "Field",
		Radius = "RadiusField",
		Size = UDim2.fromOffset(SEARCH_WIDTH, SEARCH_HEIGHT),
		LayoutOrder = 0,
		ZIndex = 6,
	})

	local box = Instance.new("TextBox", field, {
		Name = "Input",
		BackgroundTransparency = 1,
		Text = "",
		ClearTextOnFocus = false,
		PlaceholderText = "Search",
		Font = ThemeManager.font("Body"),
		TextSize = 13,
		TextColor3 = ThemeManager.color("TextPrimary"),
		PlaceholderColor = ThemeManager.color("TextMuted"),
		Size = UDim2.new(1, -34, 1, 0),
		Position = UDim2.new(0, 30, 0, 0),
		BorderSizePixel = 0,
		ZIndex = 7,
	})
	maid:give(ThemeManager.bind(box, "TextColor3", "TextPrimary"))
	maid:give(ThemeManager.bind(box, "PlaceholderColor", "TextMuted"))

	Element.icon(maid, field, "search", {
		Role = "TextMuted",
		Size = UDim2.fromOffset(13, 13),
		Position = UDim2.new(0, 10, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 7,
	})

	local onInput = Guard.get(box, "GetPropertyChangedSignal")
	if onInput ~= nil then
		maid:giveConnection(onInput(box, "Text"):Connect(function()
			self:Search(box.Text)
		end))
	end

	self.SearchBox = box
	return field
end

function Window:_buildFooter(maid: any)
	local height = footerHeight()

	local footer = Element.panel(maid, self.Root, "Footer", {
		Transparency = 1,
		Size = UDim2.new(1, 0, 0, height),
		Position = UDim2.new(0, 0, 1, -height),
		ZIndex = 4,
	})
	self.Footer = footer

	local edge = Instance.new("Frame", footer, {
		Name = "Edge",
		BackgroundColor3 = ThemeManager.color("BorderPrimary"),
		Size = UDim2.new(1, -32, 0, 1),
		Position = UDim2.new(0, 16, 0, 0),
		BorderSizePixel = 0,
		ZIndex = 4,
	})
	maid:give(ThemeManager.bind(edge, "BackgroundColor3", "BorderPrimary"))
	maid:giveFunction(function()
		edge:Destroy()
	end)

	self.StatusLabel = Element.label(maid, footer, "Status", {
		Text = "",
		Role = "TextMuted",
		TextSize = 11,
		Size = UDim2.new(1, -180, 1, 0),
		Position = UDim2.new(0, 16, 0, 0),
		ZIndex = 5,
	})

	Element.label(maid, footer, "Version", {
		Text = "Flux " .. tostring(self.Owner and self.Owner.Version or "0.0.0"),
		Role = "TextMuted",
		TextSize = 11,
		Alignment = Enum.TextXAlignment.Right,
		Size = UDim2.fromOffset(150, 0),
		Position = UDim2.new(1, -16, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 5,
	})
end

--
-- Building
--

function Window:Tab(options: any)
	if self.Destroyed then
		-- The strip this pill would join no longer exists, so building it would leak a tab nobody
		-- can ever open.
		warn("[Flux] tab added to a destroyed window")
		return nil
	end

	if type(options) == "string" then
		options = { Title = options }
	end

	-- Imported late to break the cycle: a tab creates components, and a component asks its
	-- container (which is a tab or a groupbox) for the window it belongs to.
	local Tab = require("Flux/Core/Tab")
	local tab = Tab.new(self, options)

	table.insert(self.TabOrder, tab)
	self.Tabs[tab.Title] = tab

	if self.Active == nil then
		tab:Open()
	end
	return tab
end

Window.CreateTab = Window.Tab
Window.AddTab = Window.Tab

function Window:GetTab(title: string): any
	return self.Tabs[title]
end

function Window:ListTabs(): {any}
	return self.TabOrder
end

function Window:SetTitle(title: string)
	self.Title = title
	if self.TitleLabel ~= nil then
		self.TitleLabel.Text = title
	end
end

function Window:SetSubtitle(text: string)
	self.Subtitle = text
	if self.SubtitleLabel ~= nil then
		self.SubtitleLabel.Text = text
	end
end

--- A line of state in the footer: what the hub is doing, without interrupting with a toast.
function Window:SetStatus(text: string)
	if self.StatusLabel ~= nil then
		self.StatusLabel.Text = text
	end
end

function Window:Notify(options: any)
	return NotificationManager.notify(options)
end

--- Runs the search over every registered control and asks each tab to hide what did not match.
--- Returns how many controls matched.
function Window:Search(term: string): number
	local query = tostring(term or "")
	-- `set` is the entry point that moves the live term; `apply` re-runs whatever term is already
	-- stored and would filter the UI against the previous keystroke.
	local matched = SearchManager.set(query)

	for _, tab in ipairs(self.TabOrder) do
		tab:Filter(query)
	end

	if self.Active ~= nil then
		self.Active:SetEmptyNotice(query ~= "" and matched == 0)
	end

	return matched
end

function Window:OpenTab(titleOrTab: any): boolean
	local tab = titleOrTab
	if type(titleOrTab) == "string" then
		tab = self.Tabs[titleOrTab]
	end
	if tab == nil then
		return false
	end
	tab:Open()
	return true
end

function Window:_setActive(tab: any)
	self.Active = tab
	for _, other in ipairs(self.TabOrder) do
		other:SetSelected(other == tab)
	end
end

--
-- Visibility
--

function Window:Show()
	self.Open = true
	self.Gui.Enabled = true
	AnimationManager.play(self.Root, "FadeIn", { Duration = 0.16 })
end

function Window:Hide()
	self.Open = false
	AnimationManager.cancel(self.Root)
	self.Gui.Enabled = false
end

function Window:Toggle()
	if self.Open then
		self:Hide()
	else
		self:Show()
	end
end

--- Minimising hides everything below the header and shrinks the window to it. The centre is
--- nudged up by half the height that went away so the header stays exactly where it was —
--- otherwise the bar the person is aiming for jumps under their cursor.
function Window:Minimize()
	self.Minimised = not self.Minimised
	local base = LayoutManager.base()

	if self.Minimised then
		self._restoreHeight = base.Y
		self.Body.Visible = false
		self.Footer.Visible = false
		local collapsed = headerHeight()
		self.Root.Size = UDim2.fromOffset(base.X, collapsed)
		self:_move(self._offset.X, self._offset.Y - (base.Y - collapsed) * 0.5)
	else
		self.Body.Visible = true
		self.Footer.Visible = true
		self.Root.Size = UDim2.fromOffset(base.X, base.Y)
		self:_move(self._offset.X, self._offset.Y + (base.Y - headerHeight()) * 0.5)
	end

	if self.MinimizeButton ~= nil then
		self.MinimizeButton.LayoutOrder = 0
	end

	return self.Minimised
end

function Window:_applyResponsive(mobile: boolean)
	if self.Nav == nil or self.ContentHost == nil then
		return
	end

	-- A narrow window cannot show a 210px field and two chrome buttons beside a title, so the
	-- search gives up width before anything else does.
	if self.SearchHost ~= nil then
		self.SearchHost.Size = UDim2.fromOffset(mobile and 132 or SEARCH_WIDTH, SEARCH_HEIGHT)
	end

	-- Each tab owns its page, so the column collapse is the tab's business, not the window's.
	for _, tab in ipairs(self.TabOrder) do
		tab:SetSingleColumn(mobile)
	end
end

function Window:onViewportChanged()
	if self.Destroyed then
		return
	end

	LayoutManager.apply(self.Gui)

	local base = LayoutManager.base()
	local top = headerHeight()
	local bottom = footerHeight()

	self.Root.Size = UDim2.fromOffset(base.X, self.Minimised and top or base.Y)
	self.Header.Size = UDim2.new(1, 0, 0, top)
	local strip = metric("NavHeight", 52)
	self.Body.Size = UDim2.new(1, 0, 1, -(top + bottom))
	self.Body.Position = UDim2.new(0, 0, 0, top)
	self.Nav.Size = UDim2.new(1, 0, 0, strip)
	self.ContentHost.Size = UDim2.new(1, 0, 1, -strip)
	self.ContentHost.Position = UDim2.new(0, 0, 0, strip)
	self.Footer.Size = UDim2.new(1, 0, 0, bottom)
	self.Footer.Position = UDim2.new(0, 0, 1, -bottom)

	self:_clampIntoView()
	self:_applyResponsive(LayoutManager.isMobile())
end

function Window:Close()
	self:Destroy()
end

function Window:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true

	if self._toggle ~= nil then
		self._toggle:Destroy()
		self._toggle = nil
	end

	-- The tabs share this maid, so they do not each need destroying; the flag stops a deferred
	-- row builder from mounting into a panel that no longer exists.
	for _, tab in ipairs(self.TabOrder) do
		tab.Destroyed = true
	end

	TooltipManager.hide()
	NotificationManager.detach(self.Gui)
	Lifecycle.unregister(self)
	self.Maid:cleanup()

	if self.Gui ~= nil then
		self.Gui:Destroy()
	end
end

--- Every connection this window made, for a test that asserts closing really does let go.
function Window:connections(): number
	local count = 0
	for _, task in ipairs(self.Maid._tasks) do
		if type(task) == "table" and (task.type == "connection" or task.type == "thread") then
			count += 1
		end
	end
	return count
end

return Window
