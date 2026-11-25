--[[
	spec 12 — the shell: Library, Window, Tab, Groupbox, Container, Lifecycle.

	The promise this file exists to keep is the one the whole design hangs on: *declaring* a hub is
	cheap and *opening* a page is what costs. A host that writes nine tabs must pay for one page, so
	most of the assertions below are about mount flags and instance counts rather than pixels.

	The second promise is that teardown is real. This library is executed inside someone else's
	game, so a destroyed window has to release its binds, its search rows, its toast stack and its
	connections — otherwise running the hub twice doubles everything.
]]

local Library = assert(fluxRequire("Flux/Core/Library"))
local Lifecycle = assert(fluxRequire("Flux/Core/Lifecycle"))
local Container = assert(fluxRequire("Flux/Core/Container"))
local InstUtil = assert(fluxRequire("Flux/Utilities/Instance"))

local SearchManager = assert(fluxRequire("Flux/Systems/SearchManager"))
local ConfigManager = assert(fluxRequire("Flux/Systems/ConfigManager"))
local ThemeManager = assert(fluxRequire("Flux/Systems/ThemeManager"))
local NotificationManager = assert(fluxRequire("Flux/Systems/NotificationManager"))
local TooltipManager = assert(fluxRequire("Flux/Systems/TooltipManager"))
local InputManager = assert(fluxRequire("Flux/Systems/InputManager"))
local LayoutManager = assert(fluxRequire("Flux/Systems/LayoutManager"))
local Renderer = assert(fluxRequire("Flux/Systems/Renderer"))

-- A shell spec has no business writing config files; the components it builds carry flags.
ConfigManager.configure({ AutoSave = false })

local UIS = game:GetService("UserInputService")

--- Run the queued page work now. Mounting a card goes through the renderer on purpose, so a test
--- that asserts an end state has to say when it wants the frames skipped.
local function settle()
	Renderer.flush()
end

--- Close a hub and put the module singletons back the way the next block expects them. Every block
--- ends with this because a leaked window keeps its toggle bind alive, and the next block's key
--- press would then hide a hub it never made.
local function teardown(Flux: any)
	if Flux ~= nil and not Flux:IsUnloaded() then
		Flux:Unload()
	end
	SearchManager.clear()
	ConfigManager.reset({})
	InputManager.clear()
	NotificationManager.destroy()
	TooltipManager.destroy()
	ThemeManager.use("Dark")
	setViewport(1280, 720)
	LayoutManager.setMode(nil)
	LayoutManager.refresh()
end

--- The harness's own `pressKey`/`releaseKey` keep `IsKeyDown` consistent, which is what a
--- bind that checks modifiers actually reads.
local function tapKey(keyName: string)
	pressKey(keyName)
	releaseKey(keyName)
end

--- Count the children of a container whose name starts with a prefix, so the assertions are about
--- widgets and not about the layout objects that share their parent.
local function countNamed(parent: any, prefix: string): number
	local count = 0
	for _, child in ipairs(parent:GetChildren()) do
		if tostring(child.Name):sub(1, #prefix) == prefix then
			count += 1
		end
	end
	return count
end

--- Cards live inside a column, so a page's group count is not its direct-children count.
local function countDeep(parent: any, prefix: string): number
	local count = 0
	for _, child in ipairs(parent:GetDescendants()) do
		if tostring(child.Name):sub(1, #prefix) == prefix then
			count += 1
		end
	end
	return count
end

runSpec("the façade hands back a hub with nothing built yet", function()
	local Flux = Library.new({ Config = false })

	checkEq(type(Flux.Version), "string", "the bundle reports a version")
	checkEq(#Flux.Windows, 0, "no window exists until one is asked for")
	checkEq(Lifecycle.count(), 0, "and nothing is registered for teardown")
	checkEq(Flux.Primary, nil, "with no windows there is no primary")
	checkEq(Flux:IsUnloaded(), false, "a fresh hub is live")

	local before = InstUtil.count()
	local window = Flux:Window({ Title = "Flux", ToggleKey = false })
	local built = InstUtil.count() - before

	checkEq(Lifecycle.count(), 1, "a window registers itself so close-all can find it")
	checkEq(Flux.Primary, window, "the first window becomes the primary one")
	checkEq(Flux:GetWindow("Flux"), window, "findable by title")
	checkNe(window.Gui, nil, "the ScreenGui was made")
	checkNe(window.Root, nil, "the window panel")
	checkNe(window.Header, nil, "the header")
	checkNe(window.Nav, nil, "the tab strip lives in the body")
	checkNe(window.ContentHost, nil, "the page host")
	checkNe(window.Footer, nil, "the footer")
	checkNe(window.SearchBox, nil, "the search field sits in the header cluster")
	checkEq(window.Active, nil, "no tab, so no open page")
	-- Measured here rather than asserted as a vague "small": the chrome is what a host pays for on
	-- execute, and it is thirty-odd instances because the page host and controls are all that exist.
	check(built > 30, "the chrome is a real tree, not a placeholder (" .. built .. ")", tostring(built))
	check(built < 120, "and stays well inside one frame (" .. built .. ")", tostring(built))

	teardown(Flux)
end)

runSpec("declaring tabs builds one page, not several", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Lazy", ToggleKey = false })

	local aim = window:Tab({ Title = "Aim", Icon = "crosshair" })
	local esp = window:Tab({ Title = "ESP", Icon = "eye" })
	local world = window:Tab({ Title = "World" })
	world:GroupBox({ Title = "Terrain" })

	checkEq(aim.Built, true, "the first tab opened, so its page was built")
	checkNe(aim.Page, nil, "the page exists")
	checkEq(esp.Built, false, "the second tab is a pill and nothing else")
	checkEq(esp.Page, nil, "no scrolling frame was made for it")
	checkEq(world.Built, false, "nor for the third")
	checkEq(window.Active, aim, "the first tab is the open one")
	checkEq(aim.Active, true, "and knows it")
	checkEq(esp.Active, false, "the others are not active")

	checkEq(countNamed(window.NavScroller, "Nav_"), 3, "the strip holds one pill per tab")
	checkEq(aim.NavLabel.Text, "Aim", "the pill is labelled with its title")
	checkEq(aim.NavFill.Visible, true, "the selected pill is filled")
	checkEq(esp.NavFill.Visible, false, "the others are not")
	checkEq(aim.NavBar.Visible, true, "the active tab carries its bar")
	checkEq(esp.NavBar.Visible, false, "and an inactive one hides it")

	-- A card written on a tab nobody has opened exists only as an unparented panel, and enters the
	-- tree through the renderer when that tab finally opens.
	local espCard = esp:GroupBox({ Title = "Players" })
	checkEq(espCard.Mounted, false, "the tab was never opened, so nothing mounted")
	checkEq(espCard.Panel.Parent, nil, "the card is built but not in the tree")

	local before = InstUtil.count()
	checkEq(window:OpenTab("ESP"), true, "a tab opens by title")
	checkEq(Renderer.pending(), 1, "its card queues instead of parenting in the click", tostring(Renderer.pending()))
	checkEq(espCard.Mounted, false, "and stays out of the tree until that job runs")
	settle()

	local cost = InstUtil.count() - before
	checkEq(esp.Built, true, "its page was built on the way in")
	checkEq(espCard.Mounted, true, "the queued mount ran")
	checkEq(espCard.Panel.Parent, esp.ColumnLeft, "into the column chosen at declaration")
	-- Eight: the scrolling frame, its padding and list, two column panels and the empty notice. The
	-- card itself added nothing here, because it was already built and merely got a parent.
	checkEq(cost, 8, "and an empty page is eight instances (" .. cost .. ")", tostring(cost))
	checkEq(esp.Page.Visible, true, "the new page is on screen")
	checkEq(aim.Page.Visible, false, "the old one was hidden, not destroyed")
	checkEq(window.Active, esp, "the window tracks the open tab")
	checkNe(aim.Page, nil, "a hidden page keeps its rows for the next visit")

	checkEq(window:OpenTab("Nope"), false, "an unknown title says no instead of throwing")
	checkEq(window:OpenTab(world), true, "and a handle works as well as a name")
	checkEq(world.Built, true, "opened, so built")
	settle()

	-- A host switches tabs constantly; re-opening must not rebuild or duplicate anything.
	local settled = InstUtil.count()
	window:OpenTab("World")
	window:OpenTab(world)
	checkEq(InstUtil.count() - settled, 0, "re-opening a built tab creates nothing")
	checkEq(countNamed(window.NavScroller, "Nav_"), 3, "and never adds a second pill")
	checkEq(countDeep(world.Page, "Group_"), world:GroupCount(), "and does not duplicate its groups")

	checkEq(window:GetTab("Aim"), aim, "GetTab finds a tab by title")
	checkEq(window:GetTab("Nobody"), nil, "and nil for one that was never declared")
	checkEq(window:ListTabs(), window.TabOrder, "ListTabs is the declaration order")
	checkEq(#window.TabOrder, 3, "three tabs, in the order they were written")
	checkEq(window.CreateTab, window.Tab, "CreateTab is an alias of Tab")
	checkEq(window.AddTab, window.Tab, "AddTab too")
	checkEq(aim.SetActive, aim.Open, "Tab.SetActive is Tab.Open")

	teardown(Flux)
end)

runSpec("groups: columns, collapse, and mounting into a page that does not exist yet", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Groups", ToggleKey = false })
	local tab = window:Tab({ Title = "Aim" })

	local first = tab:GroupBox({ Title = "Legit" })
	local second = tab:GroupBox("Visuals")
	local right = tab:GroupBox({ Title = "Prefs", Side = "right" })
	settle()

	checkEq(tab:GroupCount(), 3, "every declaration is counted")
	checkEq(first.Panel.Parent, tab.ColumnLeft, "an unspecified side starts on the left")
	checkEq(second.Panel.Parent, tab.ColumnRight, "and alternates to the right")
	checkEq(right.Panel.Parent, tab.ColumnRight, "an explicit side wins")
	checkEq(first.Mounted, true, "a group on an open tab mounts immediately")
	checkEq(second.Title, "Visuals", "a string argument is the title")
	checkEq(tab.Section, tab.GroupBox, "Section is an alias of GroupBox")
	checkEq(tab.AddSection, tab.GroupBox, "AddSection too")
	checkEq(tab.AddGroupBox, tab.GroupBox, "AddGroupBox too")

	-- A group declared on a tab whose page does not exist is built unparented and waits.
	local later = window:Tab({ Title = "World" })
	local ghost = later:GroupBox({ Title = "Trees" })
	checkEq(ghost.Mounted, false, "declared before its page existed, so unmounted")
	checkEq(ghost.Panel.Parent, nil, "owned by nobody, which costs the layout nothing")
	later:Open()
	settle()
	checkEq(ghost.Mounted, true, "opening the tab mounts it")
	checkNe(ghost.Panel.Parent, nil, "into a column")
	checkEq(ghost:RowCount(), 0, "a group with no components has no rows")

	-- Collapse is the card's own control, and the only thing it has to animate.
	checkEq(first.Collapsible, true, "groups are collapsible unless told otherwise")
	checkEq(first.Collapsed, false, "and start open")
	checkEq(first.Content.Visible, true, "the rows are showing")
	checkNe(first.CollapseButton, nil, "the header carries a chevron button")

	checkEq(first:SetCollapsed(true), true, "collapsing reports the new state")
	checkEq(first.Content.Visible, false, "the row host is hidden")
	checkEq(first._chevron.instance.Rotation, -90, "the chevron turns to say the card is closed")

	checkEq(first:SetCollapsed(false), false, "and expanding back")
	checkEq(first.Content.Visible, true, "the rows are visible again")
	checkEq(first._chevron.instance.Rotation, 0, "the chevron returns level")

	local locked = tab:GroupBox({ Title = "Fixed", Collapsible = false })
	checkEq(locked.Collapsible, false, "a non-collapsible group says so")
	checkEq(locked:SetCollapsed(true), false, "and refuses the change")
	checkEq(locked.Content.Visible, true, "its rows stay up")
	checkEq(locked.CollapseButton, nil, "it gets no chevron to press")
	checkEq(locked._chevron, nil, "and no glyph was built for it")

	first:Toggle({ Name = "Silent aim", Flag = "shell.aim" })
	first:Toggle({ Name = "Hit probability", Flag = "shell.hp" })
	checkEq(first:RowCount(), 2, "the group tracks its own rows")
	checkEq(tab:Rows(), 2, "the tab adds them up across its groups")

	first:SetTitle("Legit aim")
	checkEq(first.Title, "Legit aim", "SetTitle moves the model")
	checkEq(first.TitleLabel.Text, "Legit aim", "and the label")
	checkEq(SearchManager.passes("group:Aim/Legit aim"), true, "the index kept up with the rename")

	teardown(Flux)
end)

runSpec("tab:Defer builds a page on first open instead of at boot", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Deferred", ToggleKey = false })
	-- The window's first tab opens as it is declared, so the tab under test has to be a later one.
	window:Tab({ Title = "Light" })
	local tab = window:Tab({ Title = "Heavy" })

	local built = 0
	local parked = tab:Defer(function(target)
		built += 1
		local card = target:GroupBox({ Title = "Made later" })
		card:Toggle({ Name = "Late toggle", Flag = "shell.late" })
		checkEq(target, tab, "the block is handed the tab it was parked on")
		checkEq(target.Built, true, "and the page exists by then")
	end)

	checkEq(parked, true, "parking a block reports success")
	checkEq(built, 0, "nothing was declared during boot")
	checkEq(tab.Built, false, "the page still does not exist")
	checkEq(tab:GroupCount(), 0, "so the tab has no groups yet")
	checkEq(SearchManager.size(), 0, "and the index has nothing to search")

	window:OpenTab("Heavy")
	settle()
	checkEq(built, 1, "opening the tab ran the block exactly once")
	checkEq(tab:GroupCount(), 1, "and what it declared is on the page")
	checkEq(countDeep(tab.Page, "Group_"), 1, "mounted into the page, not left unparented")
	checkEq(SearchManager.size(), 2, "the card and its row registered", tostring(SearchManager.size()))

	window:OpenTab("Heavy")
	settle()
	checkEq(built, 1, "re-opening does not run it a second time")
	checkEq(tab:GroupCount(), 1, "and the page is not doubled")

	-- A tab that is already open has nothing to wait for.
	local ran = 0
	checkEq(tab:Defer(function()
		ran += 1
	end), true, "deferring on a built tab succeeds")
	checkEq(ran, 1, "it simply ran at once")

	-- A block that throws is the host's bug, not the tab's: the page is already built and the tab
	-- keeps taking declarations afterwards.
	local before = tab:GroupCount()
	checkEq(tab:Defer(function()
		error("bad host block")
	end), false, "a throwing deferred block reports failure instead of propagating")
	checkEq(tab.Built, true, "the page survived it")
	checkNe(tab:GroupBox({ Title = "Still usable" }), nil, "the tab still builds cards")
	checkEq(tab:GroupCount(), before + 1, "and counts them")

	checkEq(tab:Defer("not a function"), false, "a non-function is refused, not called")
	checkEq(tab:Defer(nil), false, "including nil")

	teardown(Flux)
end)

runSpec("search: the window path, the header field, and the hiding", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Searchy", ToggleKey = false })
	local tab = window:Tab({ Title = "Renders" })
	local legit = tab:GroupBox({ Title = "Legit" })
	local visuals = tab:GroupBox({ Title = "Visuals", Side = "right" })
	settle()

	local aimRow = legit:Toggle({ Name = "Silent aim", Flag = "shell.a" })
	legit:Slider({ Name = "Field of view", Min = 0, Max = 120, Default = 60, Flag = "shell.fov" })
	visuals:Toggle({ Name = "Chams", Flag = "shell.b" })

	-- Two cards plus the rows they hold: everything the shell registers on the user's behalf.
	checkEq(SearchManager.size(), 5, "groups and rows are both in the index", tostring(SearchManager.size()))

	-- A whole word rather than "aim": the index also does subsequence matching, so a three-letter
	-- needle legitimately finds "Chams" too and the count would say nothing about the tiering.
	local matched = window:Search("silent")
	checkEq(matched, 1, "'silent' matched exactly the row that says it", tostring(matched))
	checkEq(SearchManager.term(), "silent", "the live term moved")
	checkEq(aimRow.Instance.Visible, true, "the matching row stays up")
	checkEq(visuals:IsVisibleToSearch(), false, "a card with no matching row hides")
	checkEq(legit:IsVisibleToSearch(), true, "the one with a match does not")
	checkEq(tab.NavButton.Visible, true, "the tab still has content, so its pill stays")

	-- An empty term is not a filter: every entry passes, which is what un-hides the page.
	checkEq(window:Search(""), SearchManager.size(), "an empty term lets everything through")
	checkEq(SearchManager.term(), "", "back to no query")
	checkEq(legit:IsVisibleToSearch(), true, "everything restored")
	checkEq(visuals:IsVisibleToSearch(), true, "including the card that had hidden")
	checkEq(aimRow.Instance.Visible, true, "and the rows are showing again")

	checkEq(window:Search("chams"), 1, "one row carries that word", tostring(window:Search("chams")))
	checkEq(visuals:IsVisibleToSearch(), true, "so its card shows")
	checkEq(legit:IsVisibleToSearch(), false, "and the other hides")
	checkEq(legit.Panel.Visible, false, "the card itself is off, not just empty")

	-- Typing in the field has to reach the same path the API uses.
	window.SearchBox.Text = "field of view"
	stepClock(0)
	checkEq(SearchManager.term(), "field of view", "typing filters through the header box")
	checkEq(aimRow.Instance.Visible, false, "and hides the rows that no longer match")

	window.SearchBox.Text = ""
	stepClock(0)
	checkEq(SearchManager.term(), "", "clearing the field clears the query")

	-- A row built while a search is live is filtered the moment it registers, because a host keeps
	-- adding controls after the user has started typing.
	window:Search("chams")
	local lateMiss = visuals:Toggle({ Name = "Tracers", Flag = "shell.c" })
	checkEq(lateMiss.Instance.Visible, false, "a row that does not match its own label starts hidden")
	local lateHit = legit:Toggle({ Name = "Chams colour", Flag = "shell.d" })
	checkEq(lateHit.Instance.Visible, true, "a matching row appears even inside a hidden card")
	checkEq(legit:IsVisibleToSearch(), true, "and brings its card back with it")
	checkEq(visuals:IsVisibleToSearch(), true, "the card that already had a match stays")

	-- Nothing on any page matches, so the open page says so rather than showing a void.
	checkEq(window:Search("zzzznothing"), 0, "no matches")
	checkEq(tab.EmptyNotice.Visible, true, "the open page explains itself")
	checkEq(tab:RefreshSearch(), false, "the tab reports it has nothing visible")
	checkEq(tab.NavButton.Visible, false, "so its pill is hidden too")

	window:Search("")
	checkEq(tab.EmptyNotice.Visible, false, "clearing takes the notice away")
	checkEq(tab.NavButton.Visible, true, "and brings the pill back")
	checkEq(tab:RefreshSearch(), true, "content again")
	checkEq(lateMiss.Instance.Visible, true, "the rows registered mid-search came back too")

	teardown(Flux)
end)

runSpec("a card found through its own description opens with its rows", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Described", ToggleKey = false })
	local tab = window:Tab({ Title = "World" })
	local card = tab:GroupBox({ Title = "Props", Desc = "spawn helpers" })
	local crate = card:Toggle({ Name = "Crate esp", Flag = "shell.crate" })
	settle()

	checkEq(window:Search("spawn"), 1, "only the card's index entry carries that word", tostring(window:Search("spawn")))
	checkEq(SearchManager.passes(crate.SearchId), false, "the row's own label does not match")
	checkEq(card:IsVisibleToSearch(), true, "the card the query reached shows up")
	checkEq(crate.Instance.Visible, true, "and its rows arrive with it, not an empty panel")
	checkEq(crate._row.Root.Visible, true, "the row's own root is the frame that opened")

	-- A row that matches on its own needs no help from the card.
	checkEq(window:Search("crate"), 1, "the row matches its own name", tostring(window:Search("crate")))
	checkEq(SearchManager.passes(crate.SearchId), true, "indexed under it")
	checkEq(crate.Instance.Visible, true, "showing")
	checkEq(card:IsVisibleToSearch(), true, "and so is its card")

	-- Neither the card nor the row matches the next query, so both go.
	checkEq(window:Search("zzz"), 0, "nothing matches", tostring(window:Search("zzz")))
	checkEq(card:IsVisibleToSearch(), false, "the card hid")
	checkEq(crate.Instance.Visible, false, "and the row with it")

	window:Search("")
	checkEq(card:IsVisibleToSearch(), true, "clearing the query brings the page back")
	checkEq(crate.Instance.Visible, true, "row and all")

	teardown(Flux)
end)

runSpec("a destroyed group takes its rows out of the index", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Gone", ToggleKey = false })
	local tab = window:Tab({ Title = "Aim" })
	local group = tab:GroupBox({ Title = "Legit" })
	local row = group:Toggle({ Name = "Silent aim", Flag = "shell.x" })

	local total = SearchManager.size()
	group:Destroy()

	checkEq(group.Destroyed, true, "the group knows it is gone")
	checkEq(SearchManager.size(), total - 2, "its card and its row left the index", tostring(SearchManager.size()))
	checkEq(group.Panel.Parent, nil, "the panel was destroyed")
	checkEq(tab:GroupCount(), 1, "the tab still lists it until the page goes — a host may re-add rows")

	checkNoError(function()
		window:Search("aim")
	end, "filtering over a destroyed card is quiet")

	checkNoError(function()
		row:Destroy()
		row:Destroy()
	end, "destroying a row twice, or after its group, is idempotent")

	teardown(Flux)
end)

runSpec("window chrome: labels, visibility, the toggle key, minimise", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Chrome", Subtitle = "rivals", ToggleKey = Enum.KeyCode.RightControl })
	local tab = window:Tab({ Title = "Aim" })
	tab:GroupBox({ Title = "Legit" }):Toggle({ Name = "Silent aim", Flag = "shell.y" })
	stepClock(1)

	checkEq(window.TitleLabel.Text, "Chrome", "the header shows the title")
	window:SetTitle("Chrome v2")
	checkEq(window.Title, "Chrome v2", "the model follows")
	checkEq(window.TitleLabel.Text, "Chrome v2", "and the label")

	checkEq(window.SubtitleLabel.Text, "rivals", "a subtitle was asked for")
	window:SetSubtitle("")
	checkEq(window.SubtitleLabel.Text, "", "and it can be taken away")

	checkEq(window.StatusLabel.Text, "", "the footer starts quiet")
	window:SetStatus("loaded 12 features")
	checkEq(window.StatusLabel.Text, "loaded 12 features", "SetStatus writes a line of state")

	checkEq(window.Open, true, "a new hub is open")
	window:Hide()
	checkEq(window.Open, false, "Hide closes it")
	checkEq(window.Gui.Enabled, false, "the whole ScreenGui is off, so input cannot reach it")
	window:Toggle()
	checkEq(window.Open, true, "Toggle brings it back")
	checkEq(window.Gui.Enabled, true, "and re-enables the gui")

	-- The hotkey is an ordinary InputManager bind, pressed the way the service reports it.
	checkEq(#InputManager.list(), 1, "the window owns exactly one bind")
	tapKey("RightControl")
	checkEq(window.Open, false, "RightControl hides the hub")
	checkEq(window.Gui.Enabled, false, "and the gui went with it")
	tapKey("RightControl")
	checkEq(window.Open, true, "again brings it back")

	-- AllowWhileTyping is why the key still works while the search field has focus.
	setFocusedTextBox(window.SearchBox)
	tapKey("RightControl")
	checkEq(window.Open, false, "the hotkey survives a focused text box")
	setFocusedTextBox(nil)

	checkEq(window.Minimised, false, "not minimised at boot")
	checkEq(window.Body.Visible, true, "body showing")
	checkEq(window.Footer.Visible, true, "footer showing")
	local fullHeight = window.Root.Size.Y.Offset
	local headerHeight = window.Header.Size.Y.Offset

	checkEq(window:Minimize(), true, "Minimize reports the new state")
	checkEq(window.Minimised, true, "minimised")
	checkEq(window.Body.Visible, false, "the page is gone")
	checkEq(window.Footer.Visible, false, "so is the footer")
	checkEq(window.Root.Size.Y.Offset, headerHeight, "the window shrank to its header")
	checkEq(window.Header.Visible, true, "the bar stays, which is the whole point")

	checkEq(window:Minimize(), false, "again restores it")
	checkEq(window.Body.Visible, true, "body back")
	checkEq(window.Footer.Visible, true, "footer back")
	checkEq(window.Root.Size.Y.Offset, fullHeight, "and the height came back")

	check(window:connections() > 0, "a live window holds connections", tostring(window:connections()))

	teardown(Flux)
end)

runSpec("destroying a window lets go of everything it took", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Dying", ToggleKey = Enum.KeyCode.RightControl })
	local tab = window:Tab({ Title = "Aim" })
	local group = tab:GroupBox({ Title = "Legit" })
	local row = group:Toggle({ Name = "Silent aim", Flag = "shell.z" })

	window:Notify({ Title = "bye", Text = "a toast", Duration = 30 })
	checkEq(NotificationManager.count(), 1, "the toast is on screen")
	checkEq(Lifecycle.count(), 1, "one window registered")

	local gui = window.Gui
	window:Destroy()

	checkEq(window.Destroyed, true, "the window is flagged dead")
	checkEq(Lifecycle.count(), 0, "and unregistered from close-all")
	checkEq(window:connections(), 0, "every connection it made is disconnected", tostring(window:connections()))
	checkEq(gui.Parent, nil, "the ScreenGui left the tree")
	checkEq(NotificationManager.count(), 0, "its toast stack went with it")
	checkEq(#InputManager.list(), 0, "the toggle bind was released, so the key is not stolen")
	checkEq(SearchManager.size(), 0, "no stale rows survive in the index")
	checkEq(row.Destroyed, nil, "a component is not told it was destroyed by the maid path")

	checkNoError(function()
		window:Destroy()
	end, "a second destroy is silent")

	checkEq(window:Tab({ Title = "After" }), nil, "a destroyed window refuses new tabs")
	checkNoError(function()
		window:Hide()
		window:Show()
		window:SetTitle("nope")
		window:SetStatus("nope")
		window:Minimize()
		window:Search("aim")
	end, "and its chrome methods stay inert")

	checkNoError(function()
		row:Set(true)
	end, "a row whose window is gone still accepts a scripted set")

	-- Notifying after a destroy must not parent a card under a dead gui.
	local handle = NotificationManager.notify({ Title = "after", Text = "still works", Duration = 5 })
	checkNe(handle, nil, "a notification with no window builds its own collector")
	checkEq(NotificationManager.count(), 1, "and shows")

	teardown(Flux)
end)

runSpec("responsive: a phone viewport collapses the page to one column", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Responsive", ToggleKey = false })
	local tab = window:Tab({ Title = "Aim" })
	local wideSearch = window.SearchHost.Size.X.Offset

	checkEq(tab.SingleColumn, false, "a desktop page is two columns")
	checkEq(tab.PageList.FillDirection, Enum.FillDirection.Horizontal, "the page list runs sideways")
	checkEq(tab.ColumnLeft.Size.X.Scale, 0.5, "each column takes half the width")

	setViewport(540, 960)
	LayoutManager.refresh()

	checkEq(LayoutManager.isMobile(), true, "the layout system switched")
	checkEq(tab.SingleColumn, true, "the open tab went single column")
	checkEq(tab.PageList.FillDirection, Enum.FillDirection.Vertical, "the page list runs down")
	checkEq(tab.ColumnLeft.Size.X.Scale, 1, "full width")
	checkEq(tab.ColumnRight.Size.X.Scale, 1, "both columns")
	check(window.SearchHost.Size.X.Offset < wideSearch, "the search field gave up width first", tostring(window.SearchHost.Size.X.Offset))
	checkEq(window.Nav.Size.X.Scale, 1, "the tab strip still spans the window")

	-- A tab built while the window is narrow is single-column from its first frame.
	local second = window:Tab({ Title = "ESP" })
	second:GroupBox({ Title = "Players" })
	second:Open()
	checkEq(second.SingleColumn, true, "the tab opened late matches the live mode")
	checkEq(second.ColumnLeft.Size.X.Scale, 1, "stacked")

	setViewport(1280, 720)
	LayoutManager.refresh()
	checkEq(tab.SingleColumn, false, "widening restored two columns")
	checkEq(tab.PageList.FillDirection, Enum.FillDirection.Horizontal, "and the direction")
	checkEq(window.SearchHost.Size.X.Offset, wideSearch, "the field took its width back")
	checkEq(second.SingleColumn, false, "including the tab that was built narrow")

	teardown(Flux)
end)

runSpec("the container hands every indexed component to a group", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Widgets", ToggleKey = false })
	local tab = window:Tab({ Title = "Aim" })
	local group = tab:GroupBox({ Title = "Legit" })

	local names = Container.names()
	check(#names >= 8, "the index ships a real component list", tostring(#names))
	checkEq(Container.has("Toggle"), true, "Toggle is listed")
	checkEq(Container.has("NoSuchWidget"), false, "and a made-up name is not")

	for _, name in ipairs(names) do
		checkEq(type(group[name]), "function", "group:" .. name .. " exists")
	end

	-- Each one has to actually build through the container path, not merely be a field on it.
	local builders = {
		Toggle = { Name = "t", Flag = "c.toggle" },
		Checkbox = { Name = "c", Flag = "c.checkbox" },
		Button = { Name = "b" },
		Slider = { Name = "s", Min = 0, Max = 1, Default = 0.5, Flag = "c.slider" },
		Dropdown = { Name = "d", Options = { "a", "b" }, Flag = "c.dropdown" },
		Input = { Name = "i", Placeholder = "text", Flag = "c.input" },
		Keybind = { Name = "k", Default = "Q", Flag = "c.keybind" },
		Label = { Name = "l", Value = "120", Flag = "c.label" },
		ColorPicker = { Name = "p", Default = Color3.fromRGB(255, 79, 104), Flag = "c.color" },
		Paragraph = { Name = "pa", Text = "a note about the section" },
		Divider = { Name = "dv", Text = "or" },
		ProgressBar = { Name = "pb", Max = 100, Default = 40, Flag = "c.progress" },
	}

	local built = 0
	for name, options in pairs(builders) do
		if Container.has(name) then
			local handle = group[name](group, options)
			checkNe(handle, nil, name .. " built a handle")
			built += 1
		end
	end
	checkEq(built, #names, "every indexed component constructed", tostring(built) .. "/" .. tostring(#names))
	checkEq(group:RowCount(), built, "and every one of them tracked a search row")

	-- A component registered at runtime reaches a *new* group, which is how a host script adds a
	-- widget without editing the library.
	local fake = {
		new = function(_container: any, options: any)
			return { Name = options.Name, Destroyed = false, Destroy = function() end }
		end,
	}
	checkEq(Container.register("Gauge", fake), true, "registration takes a name and a module")
	checkEq(Container.has("Gauge"), true, "it is listed now")
	local fresh = tab:GroupBox({ Title = "Fresh" })
	checkEq(type(fresh.Gauge), "function", "and available on a group made afterwards")
	checkNe(fresh:Gauge({ Name = "fps" }), nil, "which builds")

	checkEq(Container.register("Bad", nil), false, "a module without .new is refused")
	checkEq(Container.register("Bad2", {}), false, "including an empty table")

	teardown(Flux)
end)

runSpec("the façade: themes, config, systems, and unload", function()
	local Flux = Library.new({ Config = false, Theme = "Purple" })
	checkEq(ThemeManager.name(), "Purple", "the constructor applied the preset")

	local first = Flux:Window({ Title = "One", ToggleKey = false })
	local second = Flux:Window({ Title = "Two", ToggleKey = false })

	checkEq(#Flux:WindowList(), 2, "both windows are listed")
	checkEq(Flux.Primary, first, "the primary stays the first one")
	checkEq(Flux:GetWindow("Two"), second, "each is findable")
	checkEq(Flux.WindowCount(), 2, "and countable through the façade")
	checkEq(Flux.CreateWindow, Flux.Window, "CreateWindow is an alias")
	checkEq(Flux.NewWindow, Flux.Window, "NewWindow too")

	local accentBefore = ThemeManager.color("Accent")
	local snapshot = Flux:SetTheme("Dark")
	checkEq(type(snapshot), "table", "SetTheme returns the resulting snapshot")
	checkEq(ThemeManager.name(), "Dark", "a preset name switches wholesale")
	checkNe(ThemeManager.color("Accent"), accentBefore, "and repaints")

	Flux:SetTheme({ Accent = Color3.fromRGB(10, 200, 255) })
	checkEq(ThemeManager.color("Accent"), Color3.fromRGB(10, 200, 255), "a flat override table sets one colour")
	checkEq(ThemeManager.name(), "Dark", "without pretending to be a preset")

	Flux:SetTheme("NoSuchTheme")
	checkEq(ThemeManager.name(), "Dark", "and changed nothing")

	local themeHits = 0
	local unwatch = Flux:OnThemeChanged(function()
		themeHits += 1
	end)
	Flux:SetTheme("Blue")
	checkEq(themeHits, 1, "the façade's theme hook fired")
	unwatch()
	Flux:SetTheme("Red")
	checkEq(themeHits, 1, "and stopped when the returned unbind ran")

	checkEq(Flux:System("theme"), ThemeManager, "System exposes the theme manager")
	checkEq(Flux:System("CONFIG"), ConfigManager, "case-insensitively")
	checkEq(Flux:System("nonexistent"), nil, "and nil for a name it does not have")
	checkEq(Flux:Config(), ConfigManager, "Config() is the same manager")

	local toast = Flux:Notify({ Title = "hi", Text = "from the façade", Duration = 5 })
	checkNe(toast, nil, "Notify returns a handle")
	checkEq(NotificationManager.count(), 1, "and shows a toast")
	toast:Dismiss(true)
	checkEq(NotificationManager.count(), 0, "which dismisses")

	local group = second:Tab({ Title = "Cfg" }):GroupBox({ Title = "Values" })
	local persisted = group:Toggle({ Name = "persist", Default = true, Flag = "facade.persist" })
	settle()
	checkEq(ConfigManager.has("facade.persist"), false, "declaring a row binds its flag, it does not write it")
	checkEq(ConfigManager.collect(), 1, "collecting walks the bound rows")
	checkEq(ConfigManager.get("facade.persist"), true, "and pulls the live value out of the toggle")
	persisted:Set(false)
	checkEq(ConfigManager.get("facade.persist"), false, "a scripted change is what a save would write")

	checkEq(#Flux:Binds(), 0, "two windows with ToggleKey=nil own no binds")
	Flux:Window({ Title = "Three", ToggleKey = Enum.KeyCode.RightControl })
	checkEq(#Flux:Binds(), 1, "a third window with a hotkey adds exactly one")

	checkEq(Flux:Toggle(false), false, "Toggle(false) hides the primary window")
	checkEq(first.Open, false, "hidden")
	checkEq(Flux:Toggle(true), true, "Toggle(true) shows it")
	checkEq(Flux:Toggle(), false, "and a bare Toggle flips it again")
	checkEq(Flux:Toggle(), true, "back to open")

	local closedWith = nil
	Flux.Closed:Connect(function(count)
		closedWith = count
	end)

	checkEq(Flux:IsUnloaded(), false, "still live before unload")
	checkEq(Flux:Unload(), true, "unload reports it happened")
	checkEq(Flux:IsUnloaded(), true, "and is sticky")
	checkEq(closedWith, 3, "Closed dispatched with how many windows it took", tostring(closedWith))
	checkEq(Lifecycle.count(), 0, "nothing registered")
	checkEq(Lifecycle.isClosed(), true, "and the lifecycle says closed")
	checkEq(#Flux.Windows, 0, "the window list is empty")
	checkEq(Flux.Primary, nil, "no primary")
	checkEq(Flux:Unload(), false, "a second unload does nothing")
	checkEq(NotificationManager.count(), 0, "toasts are gone")
	checkEq(SearchManager.size(), 0, "the search index is empty")
	checkEq(#InputManager.list(), 0, "no bind survives")
	checkEq(TooltipManager.isShown(), false, "no floating surface is left")

	teardown(Flux)
end)

runSpec("a rebuilt hub does not inherit the last one's state", function()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "First", ToggleKey = Enum.KeyCode.RightControl })
	local group = window:Tab({ Title = "Aim" }):GroupBox({ Title = "Legit" })
	group:Toggle({ Name = "Silent aim", Default = true, Flag = "cycle.aim" })
	window:Search("aim")
	Flux:Unload()

	local again = Library.new({ Config = false })
	local nextWindow = again:Window({ Title = "Second", ToggleKey = Enum.KeyCode.RightControl })
	local nextGroup = nextWindow:Tab({ Title = "Aim" }):GroupBox({ Title = "Legit" })
	local row = nextGroup:Toggle({ Name = "Silent aim", Default = false, Flag = "cycle.aim" })

	checkEq(SearchManager.term(), "", "the new hub starts with no query")
	checkEq(ConfigManager.has("cycle.aim"), false, "and no staged values")
	checkEq(row.GetValue(), false, "so the row keeps its declared default")
	checkEq(#InputManager.list(), 1, "one hotkey, not two")
	checkEq(Lifecycle.count(), 1, "one window")
	checkEq(countNamed(nextWindow.NavScroller, "Nav_"), 1, "one pill")
	checkEq(SearchManager.size(), 2, "only the new card and row are registered", tostring(SearchManager.size()))

	tapKey("RightControl")
	checkEq(nextWindow.Open, false, "the surviving bind drives the new window")

	teardown(again)
end)
