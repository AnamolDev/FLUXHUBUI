--[[
	spec 13 — the four field components: Slider, Dropdown, Input, ColorPicker.

	Everything here runs against the offline stub, so the interaction surface is exactly what a
	real client is *not*: instance-level MouseButton1Down/InputChanged do not exist, and unknown
	member reads raise. That is deliberate. The components must drive drags through the input
	service behind a hit test (the path every executor has), the specs prove that path works, and
	a seeded fake InputChanged signal — installed before construction, because the widgets
	resolve the service events when they are built — stands in for pointer motion.

	The load-bearing invariants are the ones the contract pins down: user interaction is the
	only thing that fires a Callback; `:Set` and config restore never do; per-drag listeners
	die with the drag; every instance and every theme binding a widget made is gone when the
	widget is destroyed; and a row costs at most 25 instances at build time.
]]

local Slider = assert(fluxRequire("Flux/Components/Slider"))
local Dropdown = assert(fluxRequire("Flux/Components/Dropdown"))
local Input = assert(fluxRequire("Flux/Components/Input"))
local ColorPicker = assert(fluxRequire("Flux/Components/ColorPicker"))

local Maid = assert(fluxRequire("Flux/Utilities/Maid"))
local Groupbox = assert(fluxRequire("Flux/Core/Groupbox"))
local Element = assert(fluxRequire("Flux/Core/Element"))
local InstUtil = assert(fluxRequire("Flux/Utilities/Instance"))
local ThemeManager = assert(fluxRequire("Flux/Systems/ThemeManager"))
local ConfigManager = assert(fluxRequire("Flux/Systems/ConfigManager"))
local SearchManager = assert(fluxRequire("Flux/Systems/SearchManager"))

ConfigManager.configure({ AutoSave = false })

local UIS = game:GetService("UserInputService")

--- A connectable/fireable stand-in for UIS.InputChanged with connection bookkeeping, so the
--- specs can assert the per-drag listeners are not just inert but *disconnected*.
local function fakeSignal()
	local sig = { handlers = {}, connects = 0, disconnects = 0 }
	sig.Connect = function(self, fn)
		self.connects += 1
		table.insert(self.handlers, fn)
		local conn = { alive = true }
		conn.Disconnect = function()
			if not conn.alive then
				return
			end
			conn.alive = false
			self.disconnects += 1
			for index = #self.handlers, 1, -1 do
				if self.handlers[index] == fn then
					table.remove(self.handlers, index)
					break
				end
			end
		end
		return conn
	end
	sig.Fire = function(self, ...)
		local snapshot = table.clone(self.handlers)
		for _, fn in ipairs(snapshot) do
			fn(...)
		end
	end
	return sig
end

-- Installed *before* any widget is constructed: Slider/ColorPicker resolve the service motion
-- event at build time, so a probe added afterwards would model a client they never see.
local inputChanged = fakeSignal()
UIS.InputChanged = inputChanged

local function mouseEvent(x: number, y: number): any
	return {
		EnumType = Enum.UserInputType.MouseButton1,
		Position = Vector2.new(x, y),
	}
end

local function pressAt(x: number, y: number)
	UIS.InputBegan:Fire(mouseEvent(x, y), false)
end

local function releaseAt(x: number, y: number)
	UIS.InputEnded:Fire(mouseEvent(x, y), false)
end

local function findPath(root: any, ...): any
	local node = root
	for _, name in ipairs({ ... }) do
		if node == nil then
			return nil
		end
		node = node:FindFirstChild(name)
	end
	return node
end

local function newGroup(title: string): any
	local tab = { Title = "Page13", Maid = Maid.new() }
	return Groupbox.new(tab, { Title = title, Collapsible = false })
end

local group = newGroup("Fields")

--[[ Slider -------------------------------------------------------------------- ]]

local speed = nil
local speedCallbacks = 0
local speedLastCallback = nil

runSpec("slider: build cost, default, and no config stampede", function()
	local before = InstUtil.count()
	speed = Slider.new(group, {
		Name = "Speed",
		Min = 0,
		Max = 100,
		Step = 1,
		Default = 25,
		Flag = "sl.fresh",
		Callback = function(value)
			speedCallbacks += 1
			speedLastCallback = value
		end,
	})
	local cost = InstUtil.count() - before
	check(cost <= 25, "a slider costs at most 25 instances at build", tostring(cost))
	checkEq(speed:GetValue(), 25, "the default is staged without any interaction")
	checkEq(speedCallbacks, 0, "building never fires the callback")
	checkEq(ConfigManager.get("sl.fresh", "unset"), "unset", "the declared default is not pushed into the store at build")
end)

runSpec("slider: Set quantizes, clamps, and never calls back", function()
	local dispatched = 0
	local connection = speed.Changed:Connect(function()
		dispatched += 1
	end)

	speed:Set(47.4)
	checkEq(speed:GetValue(), 47, "step 1 rounds to the nearest notch")
	checkEq(speedCallbacks, 0, "Set is programmatic: no callback")
	checkEq(dispatched, 1, "Changed sees the move")

	speed:Set(47)
	checkEq(dispatched, 1, "an equal Set dispatches nothing")

	checkEq(speed:Set(1), speed, "Set returns self")
	checkEq(speed:GetValue(), 1, "and applied")

	local fine = Slider.new(group, { Name = "Fine", Min = 0.3, Max = 10, Step = 0.5, Default = 4.27 })
	checkEq(fine:GetValue(), 4.3, "a 0.5 step from a 0.3 floor lands exactly on 4.3")
	check(tostring(fine:GetValue()) == "4.3", "no float dust in the value")
	local readout = findPath(fine.Instance, "Body", "Gauge", "Value")
	check(readout ~= nil, "the readout label exists")
	checkEq(readout.Text, "4.3", "the readout prints the decimals the step implies")
	fine:Set(100)
	checkEq(fine:GetValue(), 10, "the ceiling clamps after the snap")
	fine:Set(-5)
	checkEq(fine:GetValue(), 0.3, "values below the floor snap back up to the floor")
	fine:Destroy()

	connection:Disconnect()
end)

runSpec("slider: config restore wins over the default and stays silent", function()
	local restoredCallbacks = 0
	ConfigManager.set("sl.restore", 42)
	local restored = Slider.new(group, {
		Name = "Restored",
		Default = 10,
		Flag = "sl.restore",
		Callback = function()
			restoredCallbacks += 1
		end,
	})
	checkEq(restored:GetValue(), 42, "the stored value beats the declared default")
	checkEq(ConfigManager.get("sl.restore"), 42, "a build-time default push does not clobber the file value")
	checkEq(restoredCallbacks, 0, "restoring never fires the callback")
	restored:Destroy()
end)

runSpec("slider: pointer drag through the input service", function()
	local track = findPath(speed.Instance, "Body", "Gauge", "Track")
	check(track ~= nil, "the rail exists")
	local origin = track.AbsolutePosition
	local size = track.AbsoluteSize
	check(size.X > 0, "and it has measurable width in the stub", tostring(size.X))

	local callbacksBefore = speedCallbacks
	pressAt(origin.X + size.X * 0.5, origin.Y + size.Y * 0.5)
	checkEq(speed:GetValue(), 50, "a press jumps the knob to the pointer")
	checkEq(#inputChanged.handlers, 1, "the drag connects exactly one motion listener")

	inputChanged:Fire({ Position = Vector2.new(origin.X + size.X * 0.75, origin.Y + size.Y * 0.2) })
	checkEq(speed:GetValue(), 75, "motion tracks the pointer")
	checkEq(speedCallbacks, callbacksBefore, "no callback fires mid-drag")

	releaseAt(900, 40)
	checkEq(speedCallbacks, callbacksBefore + 1, "one commit per interaction")
	checkEq(speedLastCallback, 75, "carrying the released value")
	checkEq(#inputChanged.handlers, 0, "the per-drag listeners are disconnected on release")
	checkEq(ConfigManager.get("sl.fresh"), 75, "the store sees the committed drag value")

	-- A press-release that lands on the current value is not an interaction worth reporting.
	pressAt(origin.X + size.X * 0.75, origin.Y + size.Y * 0.5)
	releaseAt(400, 90)
	checkEq(speedCallbacks, callbacksBefore + 1, "a no-op drag commits nothing")
end)

runSpec("slider: keyboard presses are ignored", function()
	local before = speed:GetValue()
	pressKey("A")
	releaseKey("A")
	checkEq(speed:GetValue(), before, "a key event does not move the knob")
	checkEq(#inputChanged.handlers, 0, "and does not open a drag")
end)

runSpec("slider: destroy mid-drag releases everything", function()
	-- The stub's UIListLayout does not actually lay rows out, so every row shares one absolute
	-- rectangle: a press aimed at this slider would also hit any other live slider. Retiring
	-- `speed` first keeps the handler counts below honest.
	speed:Destroy()
	local doomed = Slider.new(group, { Name = "Doomed", Flag = "sl.doomed" })
	local track = findPath(doomed.Instance, "Body", "Gauge", "Track")
	local origin = track.AbsolutePosition
	local size = track.AbsoluteSize
	local callbacksBefore = speedCallbacks
	pressAt(origin.X + size.X * 0.2, origin.Y + 1)
	checkEq(#inputChanged.handlers, 1, "the drag is live")
	doomed:Destroy()
	checkEq(#inputChanged.handlers, 0, "destroy disconnects the in-flight drag")
	releaseAt(0, 0)
	checkEq(speedCallbacks, callbacksBefore, "the orphaned release commits nothing")
	doomed:Destroy()
	checkEq(doomed.Destroyed, true, "Destroy is idempotent and marks the widget")
end)

--[[ Dropdown ------------------------------------------------------------------- ]]

local mode = nil
local modeCallbacks = 0

runSpec("dropdown: build, default, and the placeholder", function()
	local before = InstUtil.count()
	mode = Dropdown.new(group, {
		Name = "Mode",
		Options = { "Slow", "Medium", "Fast" },
		Default = "Medium",
		Flag = "dd.mode",
		Callback = function(value)
			modeCallbacks += 1
		end,
	})
	local cost = InstUtil.count() - before
	check(cost <= 25, "a dropdown with three declared options costs <=25 at build", tostring(cost))
	checkEq(mode:GetValue(), "Medium", "the default selects by value")
	checkEq(modeCallbacks, 0, "building never fires the callback")
	checkEq(ConfigManager.get("dd.mode", "unset"), "unset", "and stages nothing into the store")

	local display = findPath(mode.Instance, "Body", "Selector", "Text")
	checkEq(display.Text, "Medium", "the selector shows the label")

	mode:Set("Fast")
	checkEq(display.Text, "Fast", "Set repaints the label")
	checkEq(modeCallbacks, 0, "Set is silent to the callback")
	checkEq(ConfigManager.get("dd.mode"), "Fast", "but Set does stage the value")
	checkEq(#mode:GetOptions(), 3, "the option list is readable")
end)

runSpec("dropdown: records, index fallback, and restore", function()
	local rec = Dropdown.new(group, {
		Name = "Rate",
		Options = { { Label = "Half", Value = 0.5 }, { Label = "Double", Value = 2 }, { Label = "Locked", Value = "x", Disabled = true } },
	})
	local display = findPath(rec.Instance, "Body", "Selector", "Text")
	rec:Set(2)
	checkEq(display.Text, "Double", "record options match by Value")
	checkEq(rec:GetValue(), 2, "and store the value, not the label")

	local strings = Dropdown.new(group, { Name = "Index", Options = { "a", "b", "c" }, Default = 2 })
	checkEq(strings:GetValue(), "b", "a numeric default falls back to the position")

	ConfigManager.set("dd.restore", "b")
	local restored = Dropdown.new(group, { Name = "Restored", Options = { "a", "b", "c" }, Default = "a", Flag = "dd.restore" })
	checkEq(restored:GetValue(), "b", "the config wins over the declared default")
	checkEq(ConfigManager.get("dd.restore"), "b", "and survives the build untouched")

	rec:Destroy()
	strings:Destroy()
	restored:Destroy()
end)

runSpec("dropdown: open, single-open, pick, outside", function()
	local selector = findPath(mode.Instance, "Body", "Selector")
	local popup = findPath(mode.Instance, "List")
	check(popup ~= nil, "the list frame is built with the row")
	checkEq(popup.Visible, false, "closed at rest")

	local second = Dropdown.new(group, { Name = "Second", Options = { "p", "q" } })
	local secondSelector = findPath(second.Instance, "Body", "Selector")
	local baseHeight = mode.Instance.Size.Y.Offset

	clickInstance(selector)
	checkEq(mode:IsOpen(), true, "clicking the selector opens the list")
	checkEq(popup.Visible, true, "and reveals it")
	local rowCount = 0
	for _, node in ipairs(popup:GetChildren()) do
		if string.sub(node._props.Name or "", 1, 6) == "Option" then
			rowCount += 1
		end
	end
	checkEq(rowCount, 3, "rows are built lazily, one per option")
	check(mode.Instance.Size.Y.Offset > baseHeight, "the row grows to cover the open list", tostring(mode.Instance.Size.Y.Offset))

	clickInstance(secondSelector)
	checkEq(second:IsOpen(), true, "the second opens")
	checkEq(mode:IsOpen(), false, "and closes the first — one list at a time")

	clickInstance(secondSelector)
	checkEq(second:IsOpen(), false, "clicking the selector again collapses it")

	clickInstance(selector)
	local callbacksBefore = modeCallbacks
	clickInstance(findPath(popup, "Option_1"))
	checkEq(modeCallbacks, callbacksBefore + 1, "picking commits one callback")
	checkEq(mode:GetValue(), "Slow", "and the value")
	local display = findPath(mode.Instance, "Body", "Selector", "Text")
	checkEq(display.Text, "Slow", "and the label")
	checkEq(ConfigManager.get("dd.mode"), "Slow", "and the config")
	checkEq(mode:IsOpen(), false, "picking closes the list")

	clickInstance(selector)
	pressAt(2, 2)
	checkEq(mode:IsOpen(), false, "a click far outside closes it")
	checkEq(mode.Instance.Size.Y.Offset, baseHeight, "the row height is restored", tostring(mode.Instance.Size.Y.Offset))

	-- Focus loss must never close the list: on a real client focus leaves the button on
	-- *mouse-down*, so a FocusLost-driven close would eat the first click on every row.
	clickInstance(selector)
	local popupSignals = rawget(popup, "_signals")
	checkEq(popupSignals == nil or popupSignals.FocusLost == nil or #popupSignals.FocusLost.handlers == 0, true,
		"the list has no FocusLost close handler wired")
	local buttonSignals = rawget(selector, "_signals")
	checkEq(buttonSignals == nil or buttonSignals.FocusLost == nil or #buttonSignals.FocusLost.handlers == 0, true,
		"nor does the selector button")
	checkEq(mode:IsOpen(), true, "still open")
	mode:Close()

	second:Destroy()
end)

runSpec("dropdown: disabled rows, empty lists, filtering, refresh", function()
	local locked = Dropdown.new(group, { Name = "Locked", Options = { "one", { Label = "Locked", Value = "lock", Disabled = true } } })
	local popup = findPath(locked.Instance, "List")
	locked:OpenList()
	local row = findPath(popup, "Option_2")
	checkEq(row.Active, false, "a disabled entry is inert")
	local valueBefore = locked:GetValue()
	clickInstance(row)
	checkEq(locked:GetValue(), valueBefore, "clicking a disabled row changes nothing")
	checkEq(locked:IsOpen(), true, "and does not even close the list")
	locked:Close()

	local empty = Dropdown.new(group, { Name = "Empty", Options = {} })
	empty:OpenList()
	check(findPath(empty.Instance, "List", "Empty") ~= nil, "an empty list says so instead of showing a 0px popup")
	empty:Close()

	local filter = Dropdown.new(group, { Name = "Filter", Options = { "alpha", "beta", "gamma" }, Searchable = true })
	filter:OpenList()
	local box = findPath(filter.Instance, "List", "Filter")
	check(box ~= nil, "Searchable adds a filter box")
	box.Text = "bet"
	checkEq(#filter._rows, 1, "typing filters the rows live")
	box.Text = ""
	checkEq(#filter._rows, 3, "clearing brings them back")
	filter:Close()

	mode:Refresh({ "Slow", "Medium", "Fast" })
	checkEq(mode:GetValue(), "Slow", "refresh keeps a still-valid selection")
	mode:Refresh({ "only" })
	checkEq(mode:GetValue(), nil, "a vanished selection falls back to the placeholder")
	local display = findPath(mode.Instance, "Body", "Selector", "Text")
	checkEq(display.Text, "Select…", "and the label follows")

	filter:Destroy()
	empty:Destroy()
	locked:Destroy()
end)

runSpec("dropdown: destroy cleans up open state", function()
	local watchersBefore = Element.watcherCount()
	local doomed = Dropdown.new(group, { Name = "Doomed", Options = { "x" }, Flag = "dd.doomed" })
	doomed:OpenList()
	checkEq(doomed:IsOpen(), true, "open when destroyed")
	doomed:Destroy()
	checkEq(doomed:IsOpen(), false, "Destroy closes it first")
	checkEq(Element.watcherCount(), watchersBefore, "the outside-click watcher is released")
	-- Another dropdown must still work afterwards: a stale entry in the module's open list
	-- would make every later open throw when it tries to close the ghost.
	mode:OpenList()
	mode:Close()
	doomed:Destroy()
	checkEq(doomed.Destroyed, true, "and Destroy stays idempotent")
end)

--[[ Input ---------------------------------------------------------------------- ]]

local nick = nil
local typed = {}
local nickCommits = 0
local nickLastCommit = nil

runSpec("input: build, Set, and the per-keystroke hook", function()
	local before = InstUtil.count()
	nick = Input.new(group, {
		Name = "Nickname",
		Default = "neo",
		Flag = "in.nick",
		Callback = function(value)
			nickCommits += 1
			nickLastCommit = value
		end,
		OnChanged = function(text)
			table.insert(typed, text)
		end,
	})
	local cost = InstUtil.count() - before
	check(cost <= 25, "an input costs at most 25 instances", tostring(cost))
	checkEq(nick:GetValue(), "neo", "the default is applied at build")
	checkEq(nick:GetText(), "neo", "and written into the box")
	checkEq(nickCommits, 0, "building fires no commit callback")
	checkEq(ConfigManager.get("in.nick", "unset"), "unset", "and pushes nothing to the store")

	nick:Set("trinity")
	checkEq(nickCommits, 0, "Set is silent to the callback")
	checkEq(nick:GetValue(), "trinity", "but moves the value")
	checkEq(ConfigManager.get("in.nick"), "trinity", "Set does stage the config")
	checkEq(#typed, 0, "and Set is not typing: no keystroke event")

	local box = findPath(nick.Instance, "Body", "Field", "Box")
	box.Text = "tra"
	checkEq(#typed, 1, "a keystroke reaches OnChanged")
	checkEq(typed[1], "tra", "with the raw text")
	checkEq(nickCommits, 0, "but nothing is committed until Enter or blur")
	checkEq(nick:GetValue(), "trinity", "the committed value still stands")
end)

runSpec("input: Enter and FocusLost collapse into one commit", function()
	local box = findPath(nick.Instance, "Body", "Field", "Box")
	setFocusedTextBox(box)
	pressKey("Return")
	checkEq(nickCommits, 1, "Enter commits")
	checkEq(nickLastCommit, "tra", "with the typed text")

	local signals = rawget(box, "_signals")
	signals.FocusLost:Fire(true)
	checkEq(nickCommits, 1, "the focus release the same Enter causes on a real client adds no second commit")

	box.Text = "xyz"
	pressKey("Return")
	signals.FocusLost:Fire(true)
	checkEq(nickCommits, 2, "a fresh edit commits exactly once again")
	checkEq(nick:GetValue(), "xyz", "and holds it")
	setFocusedTextBox(nil)
end)

runSpec("input: Enter only commits a focused box", function()
	local box = findPath(nick.Instance, "Body", "Field", "Box")
	box.Text = "unsent"
	setFocusedTextBox(nil)
	pressKey("Return")
	checkEq(nickCommits, 2, "Return while nothing is focused does not commit")
	checkEq(nick:GetValue(), "xyz", "the value is untouched")

	local other = Input.new(group, { Name = "Other" })
	setFocusedTextBox(findPath(other.Instance, "Body", "Field", "Box"))
	pressKey("Return")
	checkEq(nickCommits, 2, "and focus in a *different* box does not commit this one either")
	setFocusedTextBox(nil)
	other:Destroy()
end)

runSpec("input: numeric filtering, clamping, and rejection", function()
	local commits = 0
	local pitch = Input.new(group, {
		Name = "Pitch",
		Numeric = true,
		Min = 0.5,
		Max = 2,
		Default = "1",
		Flag = "in.pitch",
		Callback = function() commits += 1 end,
	})
	local box = findPath(pitch.Instance, "Body", "Field", "Box")
	checkEq(pitch:GetValue(), 1, "a numeric default is coerced at build")
	checkEq(type(pitch:GetValue()), "number", "and stored as a number")

	box.Text = "1.5x"
	checkEq(box.Text, "1.5", "garbage characters are stripped as they are typed")
	setFocusedTextBox(box)
	pressKey("Return")
	checkEq(pitch:GetValue(), 1.5, "a clean commit stores the number")
	checkEq(ConfigManager.get("in.pitch"), 1.5, "and pushes it")
	checkEq(commits, 1, "one callback for the commit")

	box.Text = "9"
	pressKey("Return")
	checkEq(pitch:GetValue(), 2, "a value above Max clamps on commit")
	checkEq(box.Text, "2", "and the box shows the clamped number")

	box.Text = "-3"
	pressKey("Return")
	checkEq(pitch:GetValue(), 0.5, "below Min clamps up")

	local commitsBefore = commits
	box.Text = "abc"
	checkEq(box.Text, "", "every letter is stripped while typing")
	pressKey("Return")
	checkEq(pitch:GetValue(), 0.5, "an unparseable number reverts to the last value instead of storing 0")
	checkEq(box.Text, "0.5", "and the box is written back")
	checkEq(commits, commitsBefore, "the rejection is not a change to report")

	setFocusedTextBox(nil)
	pitch:Destroy()
end)

runSpec("input: multi-line, length limit, focus helpers", function()
	local note = Input.new(group, { Name = "Note", Multi = true })
	local box = findPath(note.Instance, "Body", "Field", "Box")
	checkEq(box.MultiLine, true, "Multi turns on multiline editing")
	checkEq(box.TextWrapped, true, "and wrapping")
	checkEq(note.Instance.Size.Y.Offset, 78, "the row grows for the taller field", tostring(note.Instance.Size.Y.Offset))

	local limited = Input.new(group, { Name = "Limited", LengthLimit = 8 })
	checkEq(findPath(limited.Instance, "Body", "Field", "Box").MaxLength, 8, "LengthLimit becomes MaxLength")

	checkEq(type(note.Focus), "function", "Focus exists")
	note:Blur()
	note:SetText("Memo")
	checkEq(findPath(note.Instance, "Text", "Title").Text, "Memo", "SetText renames the row")

	note:Destroy()
	limited:Destroy()
end)

runSpec("input: config restore coerces like a typed commit", function()
	ConfigManager.set("in.restore", "900")
	local vol = Input.new(group, { Name = "Vol", Numeric = true, Min = 0, Max = 100, Default = "5", Flag = "in.restore" })
	checkEq(vol:GetValue(), 100, "a hand-edited config clamps exactly like typing 900 would")
	checkEq(vol:GetText(), "100", "and the box matches")
	vol:Destroy()
end)

--[[ ColorPicker ---------------------------------------------------------------- ]]

local accent = nil
local accentCallbacks = 0

runSpec("colorpicker: build, hex round trip, and restore", function()
	local before = InstUtil.count()
	accent = ColorPicker.new(group, {
		Name = "Accent",
		Default = Color3.fromRGB(10, 20, 30),
		Flag = "cp.main",
		Callback = function() accentCallbacks += 1 end,
	})
	local cost = InstUtil.count() - before
	check(cost <= 25, "a picker costs at most 25 instances at build", tostring(cost))
	checkEq(accent:GetHex(), "0A141E", "the default paints the hex field")
	checkEq(accentCallbacks, 0, "building fires nothing")
	checkEq(ConfigManager.get("cp.main", "unset"), "unset", "and stages nothing")

	accent:Set("#FF8000")
	checkEq(accent:GetHex(), "FF8000", "a hand-typed hex round-trips exactly")
	checkEq(accentCallbacks, 0, "Set is silent")
	local stored = ConfigManager.get("cp.main")
	checkEq(type(stored), "table", "the value persists as numbers, not a Color3")
	checkEq(stored[1], 255, "r")
	checkEq(stored[2], 128, "g")
	checkEq(stored[3], 0, "b")

	accent:Set("#FF8000")
	checkEq(accentCallbacks, 0, "re-setting the same colour changes nothing")

	ConfigManager.set("cp.restore", { 10, 20, 30 })
	local restored = ColorPicker.new(group, { Name = "Restored", Default = Color3.fromRGB(1, 2, 3), Flag = "cp.restore" })
	checkEq(restored:GetHex(), "0A141E", "the stored triple wins over the declared default")
	checkEq(accentCallbacks, 0, "and restoring fires no callback")
	restored:Destroy()
end)

runSpec("colorpicker: open, close, and focus rules", function()
	local swatch = findPath(accent.Instance, "Body", "Swatch")
	local popup = findPath(accent.Instance, "Popup")
	check(popup ~= nil, "the popup exists inside the row")
	checkEq(popup.Visible, false, "closed at rest")
	checkEq(accent.Open, false, "and reported closed")

	local baseHeight = accent.Instance.Size.Y.Offset
	clickInstance(swatch)
	checkEq(accent.Open, true, "the swatch opens the popup")
	checkEq(popup.Visible, true, "and it is shown")
	check(accent.Instance.Size.Y.Offset > baseHeight, "the row grows over the popup so clicks inside it count as inside")

	-- Hex blur commits the field, but the popup itself must stay open: closing on focus loss is
	-- how pickers eat the first click on the square.
	local hex = findPath(popup, "Hex")
	local signals = rawget(hex, "_signals")
	check(signals ~= nil and signals.FocusLost ~= nil and #signals.FocusLost.handlers > 0, "hex blur is wired (to commit)")
	hex.Text = "ABCDEF"
	signals.FocusLost:Fire(true)
	checkEq(accent.Open, true, "blur commits the hex but keeps the popup open")
	checkEq(accent:GetHex(), "ABCDEF", "the entered hex landed as the value")

	pressAt(2, 2)
	checkEq(accent.Open, false, "an outside click closes it")
	checkEq(accent.Instance.Size.Y.Offset, baseHeight, "the row shrinks back", tostring(accent.Instance.Size.Y.Offset))
end)

runSpec("colorpicker: hex commit accepts, rejects, and calls back", function()
	accent:Set("#0A141E")
	accent:OpenList()
	local popup = findPath(accent.Instance, "Popup")
	local hex = findPath(popup, "Hex")
	local signals = rawget(hex, "_signals")
	local callbacksBefore = accentCallbacks

	hex.Text = "zzz"
	signals.Activated:Fire()
	checkEq(accent:GetHex(), "0A141E", "garbage is rejected, not applied as black")
	checkEq(hex.Text, "0A141E", "and the field reverts to the truth")
	checkEq(accentCallbacks, callbacksBefore, "a rejection calls back nothing")

	hex.Text = "00FF00"
	signals.Activated:Fire()
	checkEq(accent:GetHex(), "00FF00", "a valid hex commits on Enter")
	checkEq(accentCallbacks, callbacksBefore + 1, "as a user interaction")
	local stored = ConfigManager.get("cp.main")
	checkEq(stored[1], 0, "the triple lands in the config")
	checkEq(stored[2], 255, "exactly")
	checkEq(stored[3], 0, "as three 0-255 numbers")
end)

runSpec("colorpicker: dragging the square and the strip", function()
	accent:Set("#0A141E")
	accent:OpenList()
	local popup = findPath(accent.Instance, "Popup")
	local sv = findPath(popup, "SV")
	local origin = sv.AbsolutePosition
	local size = sv.AbsoluteSize
	check(size.X > 0 and size.Y > 0, "the square has measurable size", tostring(size.X) .. "x" .. tostring(size.Y))

	local callbacksBefore = accentCallbacks
	pressAt(origin.X + size.X * 0.25, origin.Y + size.Y * 0.5)
	checkEq(#inputChanged.handlers, 1, "the grab connects one motion listener")
	inputChanged:Fire({ Position = Vector2.new(origin.X + size.X * 0.6, origin.Y + size.Y * 0.2) })
	checkNe(accent:GetHex(), "0A141E", "the colour followed the pointer")
	checkEq(accentCallbacks, callbacksBefore, "and no callback ran mid-drag")
	releaseAt(700, 300)
	checkEq(accentCallbacks, callbacksBefore + 1, "one callback on release")
	checkEq(#inputChanged.handlers, 0, "the drag listeners are gone")

	local hue = findPath(popup, "Hue")
	local hueOrigin = hue.AbsolutePosition
	local hueSize = hue.AbsoluteSize
	pressAt(hueOrigin.X + hueSize.X * 0.75, hueOrigin.Y + hueSize.Y * 0.5)
	releaseAt(700, 301)
	checkEq(accentCallbacks, callbacksBefore + 2, "the hue strip is a second drag surface")
	checkNe(accent:GetHex(), "0A141E", "and it moved the colour too")
end)

runSpec("colorpicker: transparency and presets", function()
	accent:Close() -- no open popup may overlap the fade picker's drag rects
	local fade = ColorPicker.new(group, {
		Name = "Fade",
		Transparency = true,
		Flag = "cp.fade",
		Presets = { "#FF0000", Color3.fromRGB(0, 255, 0) },
	})
	checkEq(fade.Open, false, "closed")
	fade:OpenList()
	local popup = findPath(fade.Instance, "Popup")
	check(findPath(popup, "Alpha") ~= nil, "Transparency adds the alpha strip")
	local presets = findPath(popup, "Presets")
	check(presets ~= nil, "presets materialise on open, not at build")
	local chips = 0
	for _, node in ipairs(presets:GetChildren()) do
		if string.sub(node._props.Name or "", 1, 6) == "Preset" then
			chips += 1
		end
	end
	checkEq(chips, 2, "one chip per preset")

	clickInstance(findPath(presets, "Preset_1"))
	checkEq(fade:GetHex(), "FF0000", "a preset chip picks its colour")
	local stored = ConfigManager.get("cp.fade")
	checkEq(#stored, 4, "with alpha the triple grows a fourth component")

	clickInstance(findPath(presets, "Preset_2"))
	checkEq(fade:GetHex(), "00FF00", "the Color3 preset works too")

	local alpha = findPath(popup, "Alpha")
	local alphaOrigin = alpha.AbsolutePosition
	local alphaSize = alpha.AbsoluteSize
	pressAt(alphaOrigin.X + alphaSize.X * 0.25, alphaOrigin.Y + alphaSize.Y * 0.5)
	releaseAt(600, 500)
	local faded = ConfigManager.get("cp.fade")
	checkEq(#faded, 4, "the alpha drag commits the fourth component as well")
	check(faded[4] < 255, "and it moved off opaque", tostring(faded[4]))

	fade:Destroy()
end)

runSpec("colorpicker: destroy releases watcher and open state", function()
	local watchersBefore = Element.watcherCount()
	local doomed = ColorPicker.new(group, { Name = "Doomed" })
	doomed:OpenList()
	checkEq(doomed.Open, true, "open when destroyed")
	doomed:Destroy()
	checkEq(doomed.Open, false, "Destroy closes the popup first")
	checkEq(Element.watcherCount(), watchersBefore, "the outside watcher is released")
	-- Stray clicks and releases after teardown must not resurrect the drag state.
	pressAt(10, 10)
	releaseAt(10, 10)
	doomed:Destroy()
	checkEq(doomed.Destroyed, true, "and Destroy stays idempotent")
end)

--[[ Cross-cutting --------------------------------------------------------------- ]]

runSpec("every widget owns the contract surface", function()
	local widgets = {}
	local costs = {}
	local names = { "Slider", "Dropdown", "Input", "ColorPicker" }
	for _, name in ipairs(names) do
		local module = nil
		if name == "Slider" then
			module = Slider
		elseif name == "Dropdown" then
			module = Dropdown
		elseif name == "Input" then
			module = Input
		else
			module = ColorPicker
		end
		local before = InstUtil.count()
		local widget = module.new(group, { Name = name .. "Surface" })
		costs[name] = InstUtil.count() - before
		table.insert(widgets, { name = name, widget = widget })
	end
	for _, item in ipairs(widgets) do
		local w = item.widget
		check(w.Instance ~= nil, item.name .. " exposes Instance")
		checkEq(type(w.Title), "string", item.name .. " exposes Title")
		check(w.Changed ~= nil and type(w.Changed.Connect) == "function", item.name .. " exposes Changed as a signal")
		checkEq(type(w.Set), "function", item.name .. " exposes Set")
		checkEq(type(w.GetValue), "function", item.name .. " exposes GetValue")
		checkEq(type(w.SetText), "function", item.name .. " exposes SetText")
		checkEq(type(w.SetVisible), "function", item.name .. " exposes SetVisible")
		checkEq(type(w.OnFilter), "function", item.name .. " exposes OnFilter")
		checkEq(type(w.Destroy), "function", item.name .. " exposes Destroy")
		checkEq(w:SetVisible(false), w, item.name .. " SetVisible returns self")
		w:SetVisible(true)
		checkEq(w:SetText("Renamed"), w, item.name .. " SetText returns self")
		check(costs[item.name] <= 25, item.name .. " stays inside the 25-instance budget", tostring(costs[item.name]))
	end

	-- Bindings are owned by the *group* maid (every instance is), so a widget destroy releases
	-- them through ThemeManager's dead-instance pruning on the next repaint. The loop below
	-- forces a repaint between measurements so the delta it proves is real ownership, not
	-- accounting lag: after the widget is gone and the repaint has run, nothing is left.
	local function liveBindings(): number
		ThemeManager.use(ThemeManager.name())
		return ThemeManager.bindingCount()
	end

	local bindingBase = liveBindings()
	local counted = Slider.new(group, { Name = "Counted" })
	check(ThemeManager.bindingCount() > bindingBase, "a live slider holds theme bindings")
	counted:Destroy()
	checkEq(liveBindings(), bindingBase, "and releases every one of them on destroy")

	local countedDrop = Dropdown.new(group, { Name = "CountedDrop", Options = { "a" } })
	local countedBox = Input.new(group, { Name = "CountedBox" })
	local countedColor = ColorPicker.new(group, { Name = "CountedColor" })
	check(ThemeManager.bindingCount() > bindingBase, "the other three also bind to the theme")
	countedDrop:Destroy()
	countedBox:Destroy()
	countedColor:Destroy()
	checkEq(liveBindings(), bindingBase, "all four leave the binding count exactly where they found it")

	for _, item in ipairs(widgets) do
		item.widget:Destroy()
	end
end)

runSpec("a callback that throws cannot take the hub down", function()
	local exploded = Slider.new(group, {
		Name = "Explodes",
		Flag = "sl.explode",
		Callback = function()
			error("host bug")
		end,
	})
	local track = findPath(exploded.Instance, "Body", "Gauge", "Track")
	local origin = track.AbsolutePosition
	local size = track.AbsoluteSize
	checkNoError(function()
		pressAt(origin.X + size.X * 0.4, origin.Y + 1)
		releaseAt(300, 300)
	end, "a throwing slider callback is pcall'd")
	checkEq(exploded:GetValue(), 40, "the value landed anyway")
	exploded:Destroy()

	local dropExplodes = Dropdown.new(group, {
		Name = "DropExplodes",
		Options = { "a", "b" },
		Callback = function()
			error("host bug")
		end,
	})
	checkNoError(function()
		dropExplodes:OpenList()
		clickInstance(findPath(dropExplodes.Instance, "List", "Option_2"))
	end, "a throwing dropdown callback is pcall'd too")
	checkEq(dropExplodes:GetValue(), "b", "and the pick still applied")
	dropExplodes:Destroy()
end)

runSpec("search filtering drives OnFilter", function()
	-- Each widget self-registers with the group's search row via Element.searchable, so the
	-- filtering exercised here is exactly the path a live tab drives during a user search.
	local filterSlider = Slider.new(group, { Name = "Walk speed", Default = 16 })
	local drop = Dropdown.new(group, { Name = "Quality", Options = { "low", "high" } })
	drop:OpenList()
	checkEq(drop.Open, true, "the list opens before the first filter pass")

	checkEq(SearchManager.set("walk"), 1, "the term matches exactly one registered row")
	checkEq(filterSlider.Instance.Visible, true, "the matching row stays visible")
	checkEq(drop.Instance.Visible, false, "non-matching rows are filtered out")
	checkEq(drop.Open, false, "an open list closes when its row is filtered out")

	checkEq(SearchManager.set("nothingmatches"), 0, "a dead term matches nothing")
	checkEq(filterSlider.Instance.Visible, false, "and the row hides")
	SearchManager.set("")
	checkEq(filterSlider.Instance.Visible, true, "clearing the search shows it again")

	filterSlider:Destroy()
	drop:Destroy()
end)

runSpec("a theme swap repaints the fields without touching their values", function()
	local hexBefore = accent:GetHex()
	local display = findPath(mode.Instance, "Body", "Selector", "Text")
	checkNoError(function()
		ThemeManager.use(ThemeManager.name())
	end, "re-applying the current preset must not throw")
	checkEq(accent:GetHex(), hexBefore, "the picker keeps the picked colour across a repaint")
	local swatch = findPath(accent.Instance, "Body", "Swatch")
	checkEq(swatch.BackgroundColor3.R, accent:GetValue().R, "the swatch still paints the user's colour, not a token")
	checkEq(display.TextColor3, ThemeManager.color("TextMuted"), "the placeholder rides its theme role")
end)

runSpec("the whole group tears down cleanly", function()
	check(ThemeManager.bindingCount() > 0, "there are live bindings to release", tostring(ThemeManager.bindingCount()))
	group:Destroy()
	checkEq(ThemeManager.bindingCount(), 0, "group destruction takes every widget binding with it")
	checkNoError(function()
		pressAt(400, 240)
		releaseAt(400, 240)
	end, "a stray click after teardown cannot crash the released watchers")
end)
