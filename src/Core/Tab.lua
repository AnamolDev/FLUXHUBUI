--[[
	Core/Tab — one nav entry and the page it owns.

	A tab is lazy in two stages. Its page (the scrolling frame and two columns) is not created
	until the tab is first opened, and the groupboxes inside it are built through the renderer when
	the page is heavy. Both matter for the same reason: a hub with nine tabs costs one tab's worth
	of instances to open, not nine.

	The nav button and the page live in different parents on purpose — the strip belongs to the
	window, the content to this object — so switching tabs is two visibility writes.

	A pill is auto-width rather than a fixed cell: tab titles are authored by the host, and a
	30px column per character of "Configuration" is how a nav ends up truncating the one tab
	someone actually needs to find.
]]

local Maid = require("Flux/Utilities/Maid")
local Instance = require("Flux/Utilities/Instance")
local Element = require("Flux/Core/Element")
local Guard = require("Flux/Utilities/Guard")
local ThemeManager = require("Flux/Systems/ThemeManager")
local AnimationManager = require("Flux/Systems/AnimationManager")
local TooltipManager = require("Flux/Systems/TooltipManager")
local SearchManager = require("Flux/Systems/SearchManager")
local Renderer = require("Flux/Systems/Renderer")

local Tab = {}
Tab.__index = Tab

local function metric(role: string, fallback: number): number
	return ThemeManager.metric(role) or fallback
end

function Tab.new(window: any, options: {[string]: any})
	options = Element.options(options, {
		Title = "Tab",
		Icon = "dot",
		Desc = nil,
		Order = nil,
	})

	local self = setmetatable({
		Window = window,
		Title = tostring(options.Title),
		Icon = options.Icon,
		Desc = options.Desc,
		Groups = {},
		_deferred = {},
		Active = false,
		Built = false,
		Destroyed = false,
		SingleColumn = false,
		Matches = nil,
	}, Tab)

	self.Maid = Maid.new()
	window.Maid:giveFunction(function()
		self.Maid:cleanup()
	end)

	-- The pills go in the strip's scrolling frame, not the bar behind it: that frame is the one with
	-- the horizontal list and the automatic canvas width, so a hub with nine tabs can reach them.
	self:_buildNav(window.NavScroller or window.Nav, options)
	return self
end

function Tab:_buildNav(parent: any, options: {[string]: any})
	local maid = self.Maid

	local button = Instance.new("TextButton", parent, {
		Name = "Nav_" .. self.Title,
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 0, 0, 34),
		BorderSizePixel = 0,
		LayoutOrder = options.Order or (#self.Window.TabOrder + 1),
		ZIndex = 5,
	})
	maid:giveFunction(function()
		button:Destroy()
	end)
	button.AutomaticSize = Enum.AutomaticSize.X
	self.NavButton = button

	-- The fill is a sibling rather than the button's own background, because the button auto-sizes
	-- its width from its children and a rounded fill needs to inset from that box.
	local fill = Element.panel(maid, button, "Fill", {
		Color = "Selection",
		Radius = "RadiusField",
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 5,
		Visible = false,
	})
	self.NavFill = fill

	local bar = Instance.new("Frame", button, {
		Name = "ActiveBar",
		BackgroundColor3 = ThemeManager.color("Accent"),
		Size = UDim2.new(1, -16, 0, 2),
		Position = UDim2.new(0, 8, 1, 7),
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 6,
	})
	maid:give(ThemeManager.bind(bar, "BackgroundColor3", "Accent"))
	maid:giveFunction(function()
		bar:Destroy()
	end)
	Element.round(maid, bar, "RadiusChip", -2)
	self.NavBar = bar

	local row = Instance.new("UIListLayout", button, {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 7),
	})
	maid:giveFunction(function()
		row:Destroy()
	end)

	local inset = Instance.new("UIPadding", button, {
		PaddingLeft = UDim.new(0, 11),
		PaddingRight = UDim.new(0, 11),
	})
	maid:giveFunction(function()
		inset:Destroy()
	end)

	self.NavIcon = Element.icon(maid, button, self.Icon or "dot", {
		Role = "TextSecondary",
		Size = UDim2.fromOffset(15, 15),
		LayoutOrder = 0,
		ZIndex = 6,
	})

	self.NavLabel = Element.label(maid, button, "Label", {
		Text = self.Title,
		Role = "TextSecondary",
		TextSize = 13,
		AutoWidth = true,
		LayoutOrder = 1,
		Size = UDim2.new(0, 0, 1, 0),
		ZIndex = 6,
	})

	Element.interactive(button, {
		Maid = maid,
		OnClick = function()
			self:Open()
		end,
		OnEnter = function()
			if not self.Active then
				self.NavFill.Visible = true
			end
		end,
		OnLeave = function()
			if not self.Active then
				self.NavFill.Visible = false
			end
		end,
	})

	if type(self.Desc) == "string" and self.Desc ~= "" then
		TooltipManager.attach(button, self.Desc)
	end
end

--- The page is built the first time the tab is opened, not when it is declared.
function Tab:_buildPage()
	if self.Built then
		return
	end
	self.Built = true

	local maid = self.Maid
	local padding = metric("ContentPadding", 18)

	local page = Instance.new("ScrollingFrame", self.Window.ContentHost, {
		Name = "Page_" .. self.Title,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = ThemeManager.color("BorderSecondary"),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollingEnabled = true,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 3,
	})
	maid:give(ThemeManager.bind(page, "ScrollBarImageColor3", "BorderSecondary"))
	maid:giveFunction(function()
		page:Destroy()
	end)
	self.Page = page
	self.Window.Pages[self.Title] = page

	Instance.new("UIPadding", page, {
		PaddingTop = UDim.new(0, padding),
		PaddingBottom = UDim.new(0, padding),
		PaddingLeft = UDim.new(0, padding),
		PaddingRight = UDim.new(0, padding),
	})

	local list = Instance.new("UIListLayout", page, {
		Padding = UDim.new(0, metric("ColumnGap", 16)),
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	maid:giveFunction(function()
		list:Destroy()
	end)
	self.PageList = list

	self.ColumnLeft = self:_buildColumn("ColumnLeft", 0)
	self.ColumnRight = self:_buildColumn("ColumnRight", 1)

	-- Cards declared before this page existed enter it now, in the column their declaration chose.
	for _, group in ipairs(self.Groups) do
		self:_mount(group, group.Side)
	end

	-- Blocks parked with `tab:Defer` build here, once the columns they declare into actually exist.
	self:_runDeferred()

	self.EmptyNotice = Element.label(maid, page, "Empty", {
		Text = "Nothing matches that search.",
		Role = "TextMuted",
		TextSize = 13,
		Alignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 20),
		Visible = false,
		ZIndex = 4,
	})
	-- A label inside a list layout joins the column flow; pinning it to the page keeps it centred
	-- over whatever is left once every group has been filtered out.
	self.EmptyNotice.LayoutOrder = 999
end

--- Park a block of declarations until the page exists. `tab:Toggle{…}` creates instances at the
--- moment it is called, which is the boot frame for a hub that declares every tab up front; a page
--- built inside `Defer` is created on the tab's first open instead. A tab that is already open has
--- nothing to wait for, so the block runs immediately.
function Tab:Defer(build: any): boolean
	if type(build) ~= "function" then
		warn("[Flux] tab:Defer needs a function")
		return false
	end

	if self.Built then
		local ok, err = pcall(build, self)
		if not ok then
			warn("[Flux] deferred block on tab '" .. tostring(self.Title) .. "': " .. tostring(err))
		end
		return ok
	end

	table.insert(self._deferred, build)
	return true
end

function Tab:_runDeferred()
	local blocks = self._deferred
	if #blocks == 0 then
		return
	end
	self._deferred = {}

	for _, build in ipairs(blocks) do
		local ok, err = pcall(build, self)
		if not ok then
			warn("[Flux] deferred block on tab '" .. tostring(self.Title) .. "': " .. tostring(err))
		end
	end
end

function Tab:_buildColumn(name: string, order: number): any
	local maid = self.Maid
	local column = Element.panel(maid, self.Page, name, {
		Transparency = 1,
		Size = UDim2.new(0.5, -8, 0, 0),
		LayoutOrder = order,
		ZIndex = 3,
	})
	column.AutomaticSize = Enum.AutomaticSize.Y

	local list = Instance.new("UIListLayout", column, {
		Padding = UDim.new(0, metric("GroupGap", 14)),
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	maid:giveFunction(function()
		list:Destroy()
	end)
	return column
end

--- Build a groupbox into this tab. `Side` picks the column; on a compact page both columns are
--- full width and stacked, so the side becomes row order instead.
function Tab:GroupBox(options: any)
	if type(options) == "string" then
		options = { Title = options }
	end

	local Groupbox = require("Flux/Core/Groupbox")
	local group = Groupbox.new(self, options or {})

	table.insert(self.Groups, group)

	-- The side is chosen at declaration, before the page exists, so the alternation the author wrote
	-- survives a tab that is opened much later.
	group.Side = self:_sideFor(options)
	if self.Built then
		self:_mount(group, group.Side)
	end
	return group
end

--- Put a card's panel into its column, through the renderer. Mounting is the expensive half of
--- opening a page — parenting a subtree is what makes the engine lay it out — so it is queued with
--- a cost instead of happening in the click handler.
function Tab:_mount(group: any, side: string?): boolean
	if group == nil or group.Mounted or group.Destroyed or not self.Built then
		return false
	end

	local column = side == "left" and self.ColumnLeft or self.ColumnRight
	if column == nil then
		return false
	end

	Renderer.enqueue({
		Name = "mount/" .. tostring(self.Title) .. "/" .. tostring(group.Title),
		Cost = 6 + group:RowCount() * 6,
		Run = function()
			-- The tab can close, or the card be destroyed, while its job waits in the queue.
			if self.Destroyed or self.Page == nil then
				return
			end
			group:Mount(column)
		end,
	})
	return true
end

Tab.Section = Tab.GroupBox
Tab.AddSection = Tab.GroupBox
Tab.AddGroupBox = Tab.GroupBox

--- Which column a card belongs in, resolved at declaration so the alternation follows the order the
--- author wrote the sections in rather than the order their pages happened to open.
function Tab:_sideFor(options: {[string]: any}): string
	local side = options and options.Side
	if side == nil then
		-- Unspecified sides alternate, which is what makes a page of six sections read as two
		-- columns of three rather than one long ribbon.
		self._side = self._side == "left" and "right" or "left"
		side = self._side
	end
	return string.lower(tostring(side)) == "left" and "left" or "right"
end

function Tab:_columnFor(options: {[string]: any}): any
	local side = self:_sideFor(options)
	if side == "left" then
		return self.ColumnLeft
	end
	return self.ColumnRight
end

function Tab:Open()
	if self.Destroyed then
		return
	end

	self:_buildPage()
	self.Window:_setActive(self)
	for _, other in ipairs(self.Window.TabOrder) do
		if other.Page ~= nil then
			other.Page.Visible = other == self
		end
		other:SetSelected(other == self)
	end

	self.Active = true
	if self.Page ~= nil then
		AnimationManager.play(self.Page, "FadeIn", { Duration = 0.18 })
	end

	self.Window:onViewportChanged()
	if self.Window._onTabChanged ~= nil then
		self.Window._onTabChanged(self)
	end
end

Tab.SetActive = Tab.Open

function Tab:SetSelected(selected: boolean)
	self.Active = selected
	if self.NavButton == nil then
		return
	end

	self.NavFill.Visible = selected
	self.NavBar.Visible = selected

	-- Re-bound rather than written: a plain colour assignment here is exactly what the next theme
	-- swap would repaint away.
	Element.tint(self.Maid, self.NavLabel, "TextColor3", selected and "TextPrimary" or "TextSecondary")
	self.NavIcon:setRole(selected and "Accent" or "TextSecondary")
end

--- A phone-sized window stacks the page into one column. The strip is unaffected — it already
--- scrolls sideways — so this is the only responsive write a tab makes.
function Tab:SetSingleColumn(single: boolean)
	self.SingleColumn = single
	if not self.Built then
		return
	end

	if single then
		self.PageList.FillDirection = Enum.FillDirection.Vertical
		self.ColumnLeft.Size = UDim2.new(1, 0, 0, 0)
		self.ColumnRight.Size = UDim2.new(1, 0, 0, 0)
	else
		self.PageList.FillDirection = Enum.FillDirection.Horizontal
		self.ColumnLeft.Size = UDim2.new(0.5, -8, 0, 0)
		self.ColumnRight.Size = UDim2.new(0.5, -8, 0, 0)
	end
end

--
-- Search
--

--- Called by `Window:Search` after the index has filtered every row. Rows and groups already hid
--- themselves through their match callbacks, so what is left are the two decisions only a tab can
--- make: whether its page has anything to show, and whether its pill should stay clickable.
function Tab:Filter(query: string): boolean
	local has = query == "" or self:AnyGroupVisible()

	if self.NavButton ~= nil then
		self.NavButton.Visible = has
	end

	-- An unopened page has no visible notice to speak of, and hiding a pill the user can still
	-- open would strand them on a page they cannot reach.
	if query == "" then
		self:SetEmptyNotice(false)
	elseif self.Active then
		self:SetEmptyNotice(not has)
	end

	return has
end

function Tab:RefreshSearch(): boolean
	local visible = 0
	for _, group in ipairs(self.Groups) do
		if group:IsVisibleToSearch() then
			visible += 1
		end
	end

	if self.NavButton ~= nil then
		local query = SearchManager.term()
		self.NavButton.Visible = query == "" or visible > 0
	end

	return visible > 0
end

function Tab:AnyGroupVisible(): boolean
	for _, group in ipairs(self.Groups) do
		if group:IsVisibleToSearch() then
			return true
		end
	end
	return false
end

--- The page has nothing to show but is still the open tab, so say so instead of rendering a void.
function Tab:SetEmptyNotice(state: boolean)
	if self.EmptyNotice == nil then
		return
	end
	self.EmptyNotice.Visible = state == true
end

function Tab:GroupCount(): number
	return #self.Groups
end

function Tab:Rows(): number
	local rows = 0
	for _, group in ipairs(self.Groups) do
		rows += group:RowCount()
	end
	return rows
end

return Tab
