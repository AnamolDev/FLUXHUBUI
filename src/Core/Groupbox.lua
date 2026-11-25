--[[
	Core/Groupbox — a titled card on a page, and the container every component is added to.

	The panel and its rows are built *without a parent* and only mounted into the tab's column when
	that tab is first opened. An unparented subtree costs the engine nothing to lay out, so a hub
	that declares nine tabs still renders one page — and `Tab:Open` mounts the groups through the
	renderer, so even that page arrives over several frames instead of one blocking pass.

	Creating instances at declaration is still what `group:Toggle{…}` means, because the call returns
	a usable handle immediately and an unparented instance is cheap; a host that wants even that
	deferred declares its page inside `window:Defer(function() … end)`, which runs when the tab opens.
]]

local Maid = require("Flux/Utilities/Maid")
local Instance = require("Flux/Utilities/Instance")
local Element = require("Flux/Core/Element")
local Guard = require("Flux/Utilities/Guard")
local Container = require("Flux/Core/Container")
local ThemeManager = require("Flux/Systems/ThemeManager")
local SearchManager = require("Flux/Systems/SearchManager")
local TooltipManager = require("Flux/Systems/TooltipManager")

local Groupbox = {}
Groupbox.__index = Groupbox

local function metric(role: string, fallback: number): number
	return ThemeManager.metric(role) or fallback
end

function Groupbox.new(tab: any, options: {[string]: any})
	options = Element.options(options, {
		Title = "",
		Desc = nil,
		Icon = nil,
		Side = nil,
		Collapsible = true,
	})

	local self = setmetatable({
		Tab = tab,
		Window = tab.Window,
		Title = tostring(options.Title),
		Desc = options.Desc,
		Mounted = false,
		Destroyed = false,
		Collapsed = false,
		Collapsible = options.Collapsible == true,
		_rows = {},
		_rowsById = {},
		_titleMatched = false,
		_matchedSet = {},
		_matched = 0,
		_hidden = false,
	}, Groupbox)

	self.Maid = Maid.new()
	tab.Maid:giveFunction(function()
		self.Maid:cleanup()
	end)
	-- Registered on the maid rather than only in `Destroy`, because the window chain tears the
	-- groups down by cleaning maids: a card that outlived its window in the search index would put
	-- dead rows in every result list.
	self.Maid:giveFunction(function()
		SearchManager.unregister(self.SearchId)
		for _, id in ipairs(self._rows) do
			SearchManager.unregister(id)
		end
		table.clear(self._rows)
	end)

	local padding = metric("GroupPadding", 16)
	-- The header is a row of its own height: a 24px control needs 24px, and the content offsets
	-- itself by whatever the header ended up being.
	local headerH = (options.Icon ~= nil or options.Collapsible == true) and 24 or 18

	self.Panel = Element.panel(self.Maid, nil, "Group_" .. self.Title, {
		Color = "Panel",
		Radius = "RadiusPanel",
		Stroke = "BorderPrimary",
		Size = UDim2.new(1, 0, 0, 0),
		ZIndex = 4,
	})
	self.Panel.AutomaticSize = Enum.AutomaticSize.Y

	self.Header = Instance.new("Frame", self.Panel, {
		Name = "GroupHeader",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -padding * 2, 0, headerH),
		Position = UDim.new(0, padding, 0, padding),
		BorderSizePixel = 0,
		ZIndex = 5,
	})
	Instance.new("UIListLayout", self.Header, {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 7),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	Guard.set(self.Header, "AutomaticSize", Enum.AutomaticSize.Y)

	if options.Icon ~= nil then
		local badge = Element.panel(self.Maid, self.Header, "Badge", {
			Color = "AccentSoft",
			Radius = "RadiusChip",
			Size = UDim2.fromOffset(18, 18),
			ZIndex = 6,
		})
		badge.LayoutOrder = 0
		Element.icon(self.Maid, badge, options.Icon, {
			Role = "Accent",
			Size = UDim2.fromOffset(11, 11),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 7,
		})
	end

	-- The title gives up the width of the badge and the chevron it sits between, or the row layout
	-- would push the control off the card on a full parent-width label.
	local inset = (options.Icon ~= nil and 25 or 0) + (options.Collapsible == true and 31 or 0)

	self.TitleLabel = Element.label(self.Maid, self.Header, "Title", {
		Text = self.Title,
		Role = "TextPrimary",
		Font = "Title",
		TextSize = 14,
		LayoutOrder = 1,
		Size = UDim2.new(1, -inset, 1, 0),
		ZIndex = 5,
	})

	if options.Collapsible == true then
		self:_buildChevron()
	end

	-- Content sits under the header by explicit offset rather than as a sibling in a list layout:
	-- the header auto-sizes with its title, and a second list inside the panel would fight the
	-- group's own AutomaticSize on a client that resolves them in a different order.
	self.Content = Element.panel(self.Maid, self.Panel, "Rows", {
		Transparency = 1,
		Size = UDim2.new(1, -padding * 2, 0, 0),
		Position = UDim2.new(0, padding, 0, headerH + 10),
		ZIndex = 4,
	})
	self.Content.AutomaticSize = Enum.AutomaticSize.Y
	self.RowList = Instance.new("UIListLayout", self.Content, {
		Padding = UDim.new(0, 8),
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	self._bottomPadding = Instance.new("UIPadding", self.Panel, {
		PaddingBottom = UDim.new(0, padding),
	})
	self._topGap = headerH + 10 + padding

	local text = self.Title
	if type(self.Desc) == "string" and self.Desc ~= "" then
		text = self.Title .. " — " .. self.Desc
	end

	self.SearchId = "group:" .. tostring(tab.Title) .. "/" .. self.Title
	SearchManager.register({
		Id = self.SearchId,
		Label = self.Title,
		Text = text,
		Tab = tab.Title,
		OnMatch = function(_entry, isMatch)
			self:_onMatch(isMatch)
		end,
	})

	Container.decorate(self, {
		Maid = self.Maid,
		Parent = self.Content,
		Window = self.Window,
		Tab = tab,
		Group = self,
	})

	return self
end

--- The card's own collapse control, in its header at the far right. Rotating the glyph rather
--- than swapping it keeps one icon instance, and an icon swap on a themed glyph would have to
--- re-resolve its colour anyway.
function Groupbox:_buildChevron()
	local maid = self.Maid

	local button = Instance.new("TextButton", self.Header, {
		Name = "Collapse",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(24, 24),
		LayoutOrder = 2,
		BorderSizePixel = 0,
		ZIndex = 6,
	})
	maid:giveFunction(function()
		button:Destroy()
	end)
	self.CollapseButton = button

	self._chevron = Element.icon(maid, button, "chevronDown", {
		Role = "TextMuted",
		Size = UDim2.fromOffset(12, 12),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 7,
	})

	Element.interactive(button, {
		Maid = maid,
		OnClick = function()
			self:SetCollapsed(not self.Collapsed)
		end,
	})

	TooltipManager.attach(button, "Collapse this section")
end

--- Show or hide the card's rows. The panel auto-sizes from its children, so hiding the content is
--- the whole animation budget — no height bookkeeping to fall out of sync with the rows.
function Groupbox:SetCollapsed(collapsed: boolean): boolean
	if not self.Collapsible then
		return self.Collapsed
	end

	self.Collapsed = collapsed == true
	self.Content.Visible = not self.Collapsed

	if self._chevron ~= nil and self._chevron.instance ~= nil then
		Guard.set(self._chevron.instance, "Rotation", self.Collapsed and -90 or 0)
	end

	return self.Collapsed
end

Groupbox.Collapse = Groupbox.SetCollapsed

function Groupbox:Mount(parent: any)
	if self.Destroyed or self.Mounted or parent == nil then
		return false
	end
	self.Panel.Parent = parent
	self.Mounted = true
	self:_applyFilter()
	return true
end

--- A group mounted while a search is running has to honour it immediately: its rows were built
--- before the panel ever reached the tree, so nothing has told them to hide.
function Groupbox:_applyFilter()
	local query = SearchManager.term()
	if query == "" or self.Destroyed then
		return
	end

	self._titleMatched = SearchManager.passes(self.SearchId)
	self._matchedSet = {}
	self._matched = 0
	for _, id in ipairs(self._rows) do
		if self._titleMatched or SearchManager.passes(id) then
			self._matchedSet[id] = true
			self._matched += 1
		end
	end

	-- Rows built while the query was live hid themselves on registration, against the card they were
	-- not yet mounted into. A card that the query reaches through its own title or description comes
	-- back open with them.
	if self._titleMatched then
		for _, id in ipairs(self._rows) do
			local row = self._rowsById[id]
			if row ~= nil and not row.Destroyed then
				if row.Instance ~= nil then
					row.Instance.Visible = true
				end
				if row.OnFilter ~= nil then
					row.OnFilter(true)
				end
			end
		end
	end

	self:_updateVisibility()
end

--- Called by a component row when the live search term includes or excludes it. The count is
--- incremental because a page of forty rows must not rescan the index on every keystroke.
function Groupbox:reportRow(id: any, isMatch: boolean)
	-- A row reporting "no match" for the first time is not a row that stopped matching: treating the
	-- absent entry as a transition would put the count negative on any card whose first row fails,
	-- and a card with a real match alongside it would hide.
	local was = self._matchedSet[id] == true
	local now = isMatch == true
	if was == now then
		return
	end

	self._matchedSet[id] = now
	self._matched += now and 1 or -1
	self:_updateVisibility()
end

--- Release a row that was destroyed on its own. Leaving its count set is what keeps a filtered page
--- honest: a card held open by a row the user can no longer click is the stale-index bug the search
--- system exists to avoid. The id stays in `_rows` on purpose — that list is the card's ordering
--- cursor, and a slot that opened behind a survivor would put the next row beside it, not last.
function Groupbox:forget(id: any): boolean
	if id == nil then
		return false
	end

	SearchManager.unregister(id)
	self._rowsById[id] = nil

	if self._matchedSet[id] == true then
		self._matchedSet[id] = nil
		self._matched -= 1
	end

	self:_updateVisibility()
	return true
end

function Groupbox:RowCount(): number
	return #self._rows
end

function Groupbox:_onMatch(isMatch: boolean)
	-- Set before the rows report: a card found through its own title or description opens with its
	-- rows in it, because its index entry is the only place those words are written.
	self._titleMatched = isMatch == true
	self:_updateVisibility()
end

function Groupbox:_updateVisibility()
	if self.Destroyed or not self.Mounted then
		return
	end

	local query = SearchManager.term()
	if query == "" then
		self:_setVisible(false)
		return
	end

	local anyRow = self._matched > 0
	-- `hidden` is the awkward polarity here: the caller below passes the boolean the panel's own
	-- `Visible` must be inverted from, so a card with a matching row or a matching title stays up.
	self:_setVisible(not (anyRow or self._titleMatched == true))
end

function Groupbox:_setVisible(hidden: boolean)
	if self._hidden == hidden then
		return
	end
	self._hidden = hidden
	self.Panel.Visible = not hidden
end

function Groupbox:IsVisibleToSearch(): boolean
	return not self._hidden
end

--- Components call this to have a row participate in search filtering.
function Groupbox:track(row: any, label: string, extra: string?)
	local id = "row:" .. tostring(self.Title) .. "/" .. tostring(label)
	local haystack = table.concat({ self.Title, self.Tab.Title, label, extra or "" }, " "):lower()

	SearchManager.register({
		Id = id,
		Label = label,
		Text = haystack,
		Tab = self.Tab.Title,
		OnMatch = function(_entry, isMatch)
			-- Destroying a row releases it through `Groupbox:forget`, so by the time a keystroke
			-- reaches this callback the index no longer holds a card for it.
			if row.Destroyed then
				return
			end

			-- The card is indexed under its own title and description, which no row repeats, so a
			-- section found that way opens with its rows instead of as an empty panel.
			local show = isMatch == true or self._titleMatched == true

			self:reportRow(id, show)
			if row.Instance ~= nil then
				row.Instance.Visible = show
			end
			if row.OnFilter ~= nil then
				-- Called plain, because a handle's methods are fields: the shim each widget uses
				-- (`Element.recv`) reads the boolean from the first argument when the library calls
				-- it this way and from the second when a host calls the same method with a colon.
				row.OnFilter(show)
			end
		end,
	})

	table.insert(self._rows, id)
	self._rowsById[id] = row
	return id
end

--- Rename the card. The index entry is re-registered under the new title rather than left pointing
--- at the old one, because a host that renames a section at runtime expects the new name to be
--- searchable. The rows keep the ids they were registered with; only their card's entry moves.
function Groupbox:SetTitle(text: string)
	self.Title = text
	self.TitleLabel.Text = text

	local haystack = text
	if type(self.Desc) == "string" and self.Desc ~= "" then
		haystack = text .. " — " .. tostring(self.Desc)
	end

	local previous = self.SearchId
	self.SearchId = "group:" .. tostring(self.Tab.Title) .. "/" .. text
	if previous ~= self.SearchId then
		SearchManager.unregister(previous)
	end

	SearchManager.register({
		Id = self.SearchId,
		Label = text,
		Text = haystack,
		Tab = self.Tab.Title,
		OnMatch = function(_entry, isMatch)
			self:_onMatch(isMatch)
		end,
	})
	self:_applyFilter()
end

function Groupbox:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	-- The maid owns the search bookkeeping (see the note in `new`), so destroying the card takes its
	-- rows out of the index as well.
	self.Maid:cleanup()
	self.Panel:Destroy()
end

return Groupbox
