--[[
	spec 15 — the readout family: Checkbox, Label, Paragraph, Divider, ProgressBar.

	These five share one contract: they are built while their tab is closed, updated before they
	ever reach the screen, filtered by the live search term, repainted by a theme swap they never
	asked for, and destroyed without leaving the group they came from unusable. So the specs here
	are less about pixel placement (the stub lays nothing out) than about that lifecycle: the
	value lives on the widget, every input is clamped or refused rather than trusted, and every
	binding, tween, and store write a row owns is gone when the row is.

	The invariants that carry weight: only user interaction fires a Callback (Set and config
	restore stay silent), an equal value dispatches nothing, a refused value cannot corrupt the
	bar, a destroyed widget is inert, and a theme swap moves role-bound colours without touching
	a single value.
]]

local Checkbox = assert(fluxRequire("Flux/Components/Checkbox"))
local Label = assert(fluxRequire("Flux/Components/Label"))
local Paragraph = assert(fluxRequire("Flux/Components/Paragraph"))
local Divider = assert(fluxRequire("Flux/Components/Divider"))
local ProgressBar = assert(fluxRequire("Flux/Components/ProgressBar"))

local Maid = assert(fluxRequire("Flux/Utilities/Maid"))
local Groupbox = assert(fluxRequire("Flux/Core/Groupbox"))
local ThemeManager = assert(fluxRequire("Flux/Systems/ThemeManager"))
local Theme = assert(fluxRequire("Flux/Assets/Theme"))
local ConfigManager = assert(fluxRequire("Flux/Systems/ConfigManager"))
local SearchManager = assert(fluxRequire("Flux/Systems/SearchManager"))
local AnimationManager = assert(fluxRequire("Flux/Systems/AnimationManager"))
local InstUtil = assert(fluxRequire("Flux/Utilities/Instance"))

ConfigManager.configure({
	Name = "spec15",
	Folder = "FluxHub/Spec15",
	AutoSave = false,
	SaveTheme = false,
})
ConfigManager.reset({ DeleteFile = true })

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
	local tab = { Title = "Page15", Maid = Maid.new() }
	return Groupbox.new(tab, { Title = title, Collapsible = false })
end

local main = newGroup("Readout")

--[[ Checkbox -------------------------------------------------------------------- ]]

local cb = nil
local cbCallbacks = 0

runSpec("checkbox: build, click commits, Set stays silent", function()
	local before = InstUtil.count()
	cb = Checkbox.new(main, {
		Name = "Autofire",
		Desc = "aim assist note",
		Default = false,
		Flag = "rd.auto",
		Callback = function(value)
			cbCallbacks += 1
		end,
	})
	local cost = InstUtil.count() - before
	check(cost <= 25, "a checkbox costs at most 25 instances at build", "cost " .. tostring(cost))
	checkEq(cb:GetValue(), false, "the default is off")
	checkEq(cbCallbacks, 0, "building never fires the callback")
	checkEq(ConfigManager.get("rd.auto", "unset"), "unset", "the declared default is not pushed at build")

	local hit = findPath(cb.Instance, "HitArea")
	check(hit ~= nil, "the whole row is clickable")
	clickInstance(hit)
	checkEq(cb:GetValue(), true, "a click commits")
	checkEq(cbCallbacks, 1, "exactly one callback")
	checkEq(ConfigManager.get("rd.auto"), true, "and the store is staged")

	local changed = {}
	cb.Changed:Connect(function(value)
		changed[#changed + 1] = value
	end)

	cb:Set(false)
	checkEq(#changed, 1, "Set dispatches Changed")
	checkEq(changed[1], false, "with the new state")
	checkEq(cbCallbacks, 1, "Set is programmatic: no callback")
	cb:Set(false)
	checkEq(#changed, 1, "an equal Set dispatches nothing")
	checkEq(cb:Set(true), cb, "Set returns self")
	checkEq(#changed, 2, "and a real move dispatches")

	local box = findPath(cb.Instance, "Body", "Box")
	check(box ~= nil, "the square exists in the body")
	checkEq(box.Size.X.Offset, box.Size.Y.Offset, "the artwork is a square, not the toggle's pill",
		"got " .. tostring(box.Size.X.Offset) .. "x" .. tostring(box.Size.Y.Offset))
	local glyph = findPath(box, "Icon_check")
	check(glyph ~= nil, "the check glyph ships inside the box")
	checkEq(glyph.Visible, true, "on shows the glyph")
	cb:Set(false)
	checkEq(glyph.Visible, false, "off hides it again")

	cb:Set(true)
	local clicks = cbCallbacks
	cb:Toggle()
	checkEq(cbCallbacks, clicks + 1, "Toggle is a user action and calls back")
	checkEq(cb:GetValue(), false, "and flips the state")

	checkEq(cb:SetTitle("Autofire+"), cb, "SetTitle returns self")
	checkEq(findPath(cb.Instance, "Text", "Title").Text, "Autofire+", "and renames the row")
	checkEq(cb:SetVisible(false), cb, "SetVisible returns self")
	checkEq(cb.Instance.Visible, false, "and hides the row")
	cb:SetVisible(true)

	cb:SetCallback(function()
		error("host bug")
	end)
	checkNoError(function()
		clickInstance(hit)
	end, "a throwing checkbox callback is contained")
	checkEq(cb:GetValue(), true, "the click still landed")
	cb:SetCallback(function()
		cbCallbacks += 1
	end)
end)

runSpec("checkbox: config restore wins and stays silent", function()
	ConfigManager.set("rd.restore", true)
	local restoreCallbacks = 0
	local restoreChanges = 0
	local cb2 = Checkbox.new(main, {
		Name = "Trigger bot",
		Default = false,
		Flag = "rd.restore",
		Callback = function()
			restoreCallbacks += 1
		end,
	})
	checkEq(cb2:GetValue(), true, "the stored value beats the declared default")
	checkEq(restoreCallbacks, 0, "restoring never fires the callback")
	checkEq(ConfigManager.get("rd.restore"), true, "and survives the build untouched")
	local box = findPath(cb2.Instance, "Body", "Box")
	checkEq(findPath(box, "Icon_check").Visible, true, "the restored state is painted, not just stored")

	cb2.Changed:Connect(function()
		restoreChanges += 1
	end)
	cb2:Set(true)
	checkEq(restoreChanges, 0, "an equal Set dispatches nothing")
	cb2:Set(false)
	checkEq(restoreChanges, 1, "a programmatic move still fires Changed")
	checkEq(restoreCallbacks, 0, "but stays silent to the callback")
	checkEq(findPath(box, "Icon_check").Visible, false, "and repaints")
	cb2:Set(true)

	-- the stub keeps signals on unparented instances, so a click routed here is exactly the
	-- stray input a detached row still receives in a live client
	local hit2 = findPath(cb2.Instance, "HitArea")
	cb2:Destroy()
	clickInstance(hit2)
	checkEq(restoreCallbacks, 0, "a click after destroy calls back nothing")
	checkEq(restoreChanges, 2, "and dispatches nothing either")
	checkEq(cb2.Destroyed, true, "Destroy marks the widget idempotently")
	checkEq(SearchManager.unregister(cb2.SearchId), false, "Destroy unregistered the search row")
end)

runSpec("checkbox: destroy stops updates and leaves the group usable", function()
	local strayClicks = 0
	local strayChanges = 0
	local late = Checkbox.new(main, {
		Name = "Late mark",
		Flag = "rd.late",
		Callback = function()
			strayClicks += 1
		end,
	})
	local hit = findPath(late.Instance, "HitArea")
	late.Changed:Connect(function()
		strayChanges += 1
	end)
	clickInstance(hit)
	checkEq(strayClicks, 1, "live clicks call back once")
	checkEq(strayChanges, 1, "and Changed sees them")

	late:Destroy()
	clickInstance(hit)
	late:Set(false)
	late:Toggle()
	checkEq(strayClicks, 1, "nothing after teardown calls back again")
	checkEq(strayChanges, 1, "and nothing dispatches")
	checkEq(late:GetValue(), true, "the value froze at destruction")
	checkEq(ConfigManager.get("rd.late"), true, "no post-destroy push reached the store")
	late:Destroy()
	checkEq(late.Destroyed, true, "Destroy stays idempotent")
	checkEq(SearchManager.unregister(late.SearchId), false, "the search entry was released by Destroy")

	local after = Checkbox.new(main, { Name = "Aftermath" })
	checkEq(after.Instance.LayoutOrder, main:RowCount(), "a new row still lands after the survivors")
	after:Destroy()
end)

--[[ Label ------------------------------------------------------------------------ ]]

local latency = nil
local zone = nil
local fps = nil

runSpec("label: rendering, format, and SetValue round trips", function()
	latency = Label.new(main, {
		Name = "Latency",
		Value = 12.5,
		Format = "%.1f",
		Suffix = " ms",
		Flag = "rd.latency",
	})
	local node = findPath(latency.Instance, "Body", "Value")
	check(node ~= nil, "the readout label ships with the row")
	checkEq(node.Text, "12.5 ms", "the declared value renders through Format + Suffix")
	checkEq(latency:GetValue(), 12.5, "the raw value survives, formatted only on screen")
	checkEq(ConfigManager.get("rd.latency", "unset"), "unset", "building pushes nothing")

	checkEq(latency:SetValue(30), latency, "SetValue returns self")
	checkEq(node.Text, "30.0 ms", "the visible text follows")
	checkEq(ConfigManager.get("rd.latency"), 30, "and the value is staged")

	local dispatched = 0
	latency.Changed:Connect(function(value)
		if value == 30 then
			dispatched += 1
		end
	end)
	latency:SetValue(30)
	checkEq(dispatched, 0, "an equal update dispatches nothing")

	zone = Label.new(main, { Name = "Server zone" })
	checkEq(findPath(zone.Instance, "Body", "Value").Text, "", "no value, no text")
	zone:SetValue("eu-west")
	checkEq(findPath(zone.Instance, "Body", "Value").Text, "eu-west", "strings render verbatim")
	checkEq(zone:GetValue(), "eu-west", "and round-trip raw")
	zone:SetValue(nil)
	checkEq(findPath(zone.Instance, "Body", "Value").Text, "", "nil clears the slot")
	checkEq(zone:GetValue(), nil, "and the value")

	fps = Label.new(main, { Name = "FPS", Value = 240 })
	checkEq(findPath(fps.Instance, "Body", "Value").Text, "240", "the default %g format prints integers plain")

	checkEq(latency:SetTitle("Ping"), latency, "SetTitle returns self")
	checkEq(findPath(latency.Instance, "Text", "Title").Text, "Ping", "and renames the row")
end)

runSpec("label: states colour the readout by role", function()
	local node = findPath(fps.Instance, "Body", "Value")
	checkEq(node.TextColor3, ThemeManager.color("TextSecondary"), "the resting readout is TextSecondary")
	checkEq(fps:SetState("good"), fps, "SetState returns self")
	checkEq(node.TextColor3, ThemeManager.color("Success"), "good paints Success")
	fps:SetState("bad")
	checkEq(node.TextColor3, ThemeManager.color("Error"), "bad paints Error")
	checkEq(fps:GetState(), "bad", "and the state is readable")
	checkEq(fps:SetState("no-such-state"), fps, "an unknown state returns self")
	checkEq(node.TextColor3, ThemeManager.color("Error"), "and changes nothing")
	fps:SetState("accent")
	checkEq(node.TextColor3, ThemeManager.color("Accent"), "accent rides the accent token")
	checkEq(latency:SetCallback(function() end), latency, "SetCallback on a readout is a warned no-op")
end)

--[[ Paragraph --------------------------------------------------------------------- ]]

local note = nil

runSpec("paragraph: the block sizes itself to its text", function()
	local before = InstUtil.count()
	note = Paragraph.new(main, {
		Title = "Fair play",
		Text = "short one",
		Width = 200,
		Size = 12,
	})
	local cost = InstUtil.count() - before
	check(cost <= 25, "a paragraph costs at most 25 instances", "cost " .. tostring(cost))
	local rootH = note.Instance.Size.Y.Offset
	checkEq(rootH, 8 * 2 + 18 + 16, "one line: padding + title + the line itself", "got " .. tostring(rootH))
	checkEq(note:LineCount(), 1, "a nine-character line is one line")
	checkEq(findPath(note.Instance, "Body").Text, "short one", "the text is the block's payload")
	checkEq(note.Instance.ClipsDescendants, false, "nothing clips: a bad estimate must lose whitespace, not words")
	checkEq(findPath(note.Instance, "Title").Text, "Fair play", "the optional title renders")

	local longText = string.rep("alpha ", 40)
	note:SetText(longText)
	check(note.Instance.Size.Y.Offset > rootH, "wrapped text grows the row instead of overlapping the next one",
		"height " .. tostring(note.Instance.Size.Y.Offset))
	checkEq(note:LineCount(), 8, "40 five-letter words in a 30-character column wrap to eight lines")
	checkEq(note.Instance.Size.Y.Offset, 8 * 2 + 18 + 8 * 16, "the height is exactly the measured lines")

	note:SetText("one\ntwo\nthree")
	checkEq(note:LineCount(), 3, "explicit newlines count as their own lines")
	note:SetText("back")
	checkEq(note.Instance.Size.Y.Offset, rootH, "and shrinking the text shrinks the block back")
	checkEq(note:GetText(), "back", "GetText reports the raw text")
	checkEq(note:GetValue(), "back", "GetValue agrees (the family alias)")

	local bareNote = Paragraph.new(main, { Name = "Bare note" })
	checkEq(bareNote.Instance.Size.Y.Offset, 8 * 2 + 16, "an empty paragraph still owns one line",
		"got " .. tostring(bareNote.Instance.Size.Y.Offset))
	check(bareNote:LineCount() == 1, "and measures as one line")
	checkEq(findPath(bareNote.Instance, "Title"), nil, "no Title means no title label")

	-- colon calls are the host idiom; the recv shim must accept them
	bareNote:Set("host style")
	checkEq(bareNote:GetText(), "host style", "Set with a colon still lands")
	checkEq(bareNote:SetTitle("ignored"), bareNote, "SetTitle on a titleless block returns self")
	bareNote:SetVisible(false)
	checkEq(bareNote.Instance.Visible, false, "SetVisible hides the block")
	bareNote:Destroy()
	bareNote:SetText("too late")
	checkEq(bareNote:GetText(), "host style", "a destroyed paragraph ignores updates")
	bareNote:Destroy()
	checkEq(bareNote.Destroyed, true, "and Destroy is idempotent")
end)

--[[ Divider ------------------------------------------------------------------------ ]]

local rule = nil

runSpec("divider: hairline, caption, and spacing from the theme", function()
	local before = InstUtil.count()
	rule = Divider.new(main, { Name = "Section break", Text = "then again" })
	local cost = InstUtil.count() - before
	check(cost <= 25, "a divider costs at most 25 instances", "cost " .. tostring(cost))

	local darkStroke = ThemeManager.metric("StrokeThickness")
	local line = findPath(rule.Instance, "Line")
	check(line ~= nil, "the hairline is built with the row")
	checkEq(line.Size.Y.Offset, darkStroke, "its height is the theme's stroke metric")
	checkEq(rule.Instance.Size.Y.Offset, darkStroke + 12, "the row adds even spacing above and below",
		"got " .. tostring(rule.Instance.Size.Y.Offset))
	local captionNode = findPath(rule.Instance, "Caption", "Text")
	check(captionNode ~= nil, "the caption sits in a chip on the line")
	checkEq(captionNode.Text, "then again", "showing the text")
	checkEq(captionNode.TextXAlignment, Enum.TextXAlignment.Center, "centred")
	checkEq(findPath(rule.Instance, "Caption").Position.X.Scale, 0.5, "at the middle of the row")

	checkEq(rule:SetText("rewritten"), rule, "SetText returns self")
	checkEq(captionNode.Text, "rewritten", "and rewrites the caption")
	checkEq(rule:GetValue(), "rewritten", "GetValue reads it back")

	local bare = Divider.new(main, { Name = "Plain break" })
	check(findPath(bare.Instance, "Caption") == nil, "no Text means just the line")
	checkEq(bare:SetText("ignored"), bare, "SetText on a captionless divider is inert")
	checkEq(bare:GetValue(), "", "and stored nothing")
	checkEq(findPath(bare.Instance, "Line").Size.Y.Offset, darkStroke, "the bare line still uses the metric")

	local thick = Divider.new(main, { Name = "Heavy break", Thickness = 4, Spacing = 10 })
	checkEq(findPath(thick.Instance, "Line").Size.Y.Offset, 4, "Thickness overrides the metric")
	checkEq(thick.Instance.Size.Y.Offset, 4 + 20, "and Spacing sets the breathing room")

	bare:Destroy()
	bare:Destroy()
	checkEq(bare.Destroyed, true, "Destroy is idempotent")
	thick:Destroy()
end)

--[[ ProgressBar --------------------------------------------------------------------- ]]

local bar = nil
local barCallbacks = 0

runSpec("progress: the default paints instantly and costs no frame time", function()
	local before = InstUtil.count()
	local animBefore = AnimationManager.activeCount()
	bar = ProgressBar.new(main, {
		Name = "Sweep",
		Min = 0,
		Max = 1,
		Default = 0.4,
		Flag = "rd.bar",
		Callback = function()
			barCallbacks += 1
		end,
	})
	local cost = InstUtil.count() - before
	check(cost <= 25, "a progress row costs at most 25 instances", "cost " .. tostring(cost))
	checkEq(AnimationManager.activeCount(), animBefore, "a bar that only exists runs no tween",
		"active " .. tostring(AnimationManager.activeCount()))

	local fill = findPath(bar.Instance, "Body", "Gauge", "Track", "Fill")
	check(fill ~= nil, "the fill lives inside the rail")
	checkEq(fill.Size.X.Scale, 0.4, "the default lands painted, not queued on a tween")
	checkEq(bar:SetValue(), 0.4, "SetValue reports the clamped number")
	checkEq(bar:GetValue(), 0.4, "GetValue agrees")
	local readout = findPath(bar.Instance, "Body", "Gauge", "Value")
	checkEq(readout.Text, "40%", "the readout shows percent by default")
	checkEq(ConfigManager.get("rd.bar", "unset"), "unset", "build pushes nothing to the store")
	checkEq(barCallbacks, 0, "building never fires the callback")
end)

runSpec("progress: Set clamps at both ends, animates, and refuses junk", function()
	local fill = findPath(bar.Instance, "Body", "Gauge", "Track", "Fill")
	local readout = findPath(bar.Instance, "Body", "Gauge", "Value")
	local dispatched = 0
	bar.Changed:Connect(function()
		dispatched += 1
	end)

	local animBefore = AnimationManager.activeCount()
	bar:Set(0.8)
	checkEq(AnimationManager.activeCount(), animBefore + 1, "a real move queues exactly one fill tween")
	checkEq(fill.Size.X.Scale, 0.4, "the width is animated, so nothing jumped yet")
	checkEq(bar:GetValue(), 0.8, "but the value landed now")
	checkEq(dispatched, 1, "Changed sees the move")
	stepClock(1)
	checkEq(fill.Size.X.Scale, 0.8, "and the tween finishes exactly on the goal, float dust and all")
	checkEq(AnimationManager.activeCount(), animBefore, "the shared loop is gone once nothing moves")

	bar:Set(50)
	checkEq(bar:SetValue(), 1, "a value above Max clamps to full")
	stepClock(1)
	checkEq(fill.Size.X.Scale, 1, "with the fill painted full")
	bar:Set(-3)
	checkEq(bar:GetValue(), 0, "a value below Min clamps to empty")
	stepClock(1)
	checkEq(fill.Size.X.Scale, 0, "and the rail is bare")

	local callbacksBefore = barCallbacks
	local dispatchedBefore = dispatched
	bar:Set("half")
	checkEq(bar:GetValue(), 0, "a string is refused, not treated as zero-or-max")
	checkEq(bar:Set(nil), bar, "and nil is refused with self back")
	checkEq(barCallbacks, callbacksBefore, "a refusal calls back nothing")
	checkEq(dispatched, dispatchedBefore, "dispatches nothing")
	checkEq(AnimationManager.activeCount(), 0, "and queues no motion")
	checkEq(ConfigManager.get("rd.bar"), 0, "the store kept the last honest value")

	bar:Set(0)
	checkEq(dispatched, dispatchedBefore, "an equal value dispatches nothing")

	checkEq(bar:Set(0.5), bar, "Set returns self")
	checkEq(barCallbacks, callbacksBefore + 1, "a real change calls back once")
	checkEq(ConfigManager.get("rd.bar"), 0.5, "and stages the clamped number")
	checkEq(readout.Text, "50%", "with the readout following")
	stepClock(1)
end)

runSpec("progress: custom text, spans, and ShowValue off", function()
	local wide = ProgressBar.new(main, {
		Name = "XP fill",
		Min = 200,
		Max = 400,
		Default = 300,
		Text = "%d%% of the way",
	})
	local out = findPath(wide.Instance, "Body", "Gauge", "Value")
	checkEq(wide:SetValue(), 300, "defaults clamp into the declared range")
	checkEq(out.Text, "50% of the way", "a %d format token fills with the percent of the span")
	wide:Set(400)
	checkEq(out.Text, "100% of the way", "and follows every Set")
	stepClock(1)

	local quota = ProgressBar.new(main, {
		Name = "Quota",
		Min = 0,
		Max = 3,
		Default = 2,
		Text = function(value, _frac, _pct)
			return tostring(value) .. "/3"
		end,
	})
	checkEq(findPath(quota.Instance, "Body", "Gauge", "Value").Text, "2/3", "a callback owns the readout text")

	local quiet = ProgressBar.new(main, { Name = "Quiet meter", ShowValue = false })
	check(findPath(quiet.Instance, "Body", "Gauge", "Value") == nil, "ShowValue=false drops the readout")
	checkEq(quiet:GetValue(), 0, "while the bar itself still builds")

	-- a swapped range is the author's typo, not a crash
	local flipped = ProgressBar.new(main, { Name = "Flipped", Min = 10, Max = 0, Default = 12 })
	checkEq(flipped:GetValue(), 10, "Min > Max is swapped, and the default clamps into it")

	wide:Destroy()
	quota:Destroy()
	quiet:Destroy()
	flipped:Destroy()
end)

runSpec("progress: restore is instant and silent; destroy freezes the bar", function()
	ConfigManager.set("rd.bar2", 0.75)
	local restoreCallbacks = 0
	local animBefore = AnimationManager.activeCount()
	local r = ProgressBar.new(main, {
		Name = "Restored sweep",
		Default = 0.1,
		Flag = "rd.bar2",
		Callback = function()
			restoreCallbacks += 1
		end,
	})
	checkEq(r:GetValue(), 0.75, "the stored value beats the declared default")
	checkEq(restoreCallbacks, 0, "restoring never fires the callback")
	checkEq(AnimationManager.activeCount(), animBefore, "and paints instead of tweening",
		"active " .. tostring(AnimationManager.activeCount()))
	local fill = findPath(r.Instance, "Body", "Gauge", "Track", "Fill")
	checkEq(fill.Size.X.Scale, 0.75, "the restored width is exact at build")

	r:Destroy()
	checkEq(r:Set(0.2), r, "Set after destroy returns self")
	checkEq(r:GetValue(), 0.75, "and moves nothing")
	checkEq(ConfigManager.get("rd.bar2"), 0.75, "no post-destroy write reached the store")
	r:Destroy()
	checkEq(r.Destroyed, true, "Destroy stays idempotent")
	checkEq(AnimationManager.activeCount(), animBefore, "Destroy cancelled the in-flight tween budget too")
end)

--[[ Config round trip ----------------------------------------------------------------- ]]

runSpec("config: set, save, reset, fresh rows, load", function()
	local writer = Label.new(main, { Name = "Profile name", Value = "default", Flag = "rd15.profile" })
	writer:SetValue("ghost")
	local pusher = Checkbox.new(main, { Name = "Record hitlog", Default = false, Flag = "rd15.record" })
	pusher:Set(true)
	local meter = ProgressBar.new(main, { Name = "Batch size", Min = 0, Max = 10, Default = 2, Flag = "rd15.batch" })
	meter:Set(7)
	stepClock(1)

	checkEq(ConfigManager.get("rd15.profile"), "ghost", "the label staged its raw value")
	checkEq(ConfigManager.get("rd15.record"), true, "the checkbox staged its boolean")
	checkEq(ConfigManager.get("rd15.batch"), 7, "the bar staged its clamped number")

	checkEq(ConfigManager.save(), true, "the profile reaches the disk")
	ConfigManager.reset({})
	checkEq(ConfigManager.get("rd15.batch"), nil, "and the store empties on reset")

	local laterLabel = Label.new(main, { Name = "Profile name 2", Value = "vanilla", Flag = "rd15.profile" })
	local laterBox = Checkbox.new(main, { Name = "Record hitlog 2", Default = false, Flag = "rd15.record" })
	local laterMeter = ProgressBar.new(main, { Name = "Batch size 2", Min = 0, Max = 10, Default = 1, Flag = "rd15.batch" })
	checkEq(laterLabel:GetValue(), "vanilla", "against an empty store the declared default stands")
	checkEq(laterBox:GetValue(), false, "for every component")
	checkEq(laterMeter:SetValue(), 1, "of the family")

	checkEq(ConfigManager.load(), true, "the saved profile loads back")
	checkEq(laterLabel:GetValue(), "ghost", "each fresh row shows the stored value")
	checkEq(findPath(laterLabel.Instance, "Body", "Value").Text, "ghost", "rendered, not just stored")
	checkEq(laterBox:GetValue(), true, "the checkbox restored")
	checkEq(findPath(laterBox.Instance, "Body", "Box", "Icon_check").Visible, true, "and repainted")
	checkEq(laterMeter:SetValue(), 7, "the bar landed clamped into its own range")
	checkEq(findPath(laterMeter.Instance, "Body", "Gauge", "Value").Text, "70%", "with the percent following")

	laterLabel:Destroy()
	laterBox:Destroy()
	laterMeter:Destroy()
	writer:Destroy()
	pusher:Destroy()
	meter:Destroy()
	stepClock(1)
end)

--[[ Search ---------------------------------------------------------------------------- ]]

runSpec("search filtering hides every readout row and restores it", function()
	local slice = newGroup("Slice")
	local sBox = Checkbox.new(slice, { Name = "Autofire mark" })
	local sLabel = Label.new(slice, { Name = "Server zone 2" })
	local sNote = Paragraph.new(slice, { Name = "Briefing", Text = "press K to kit up" })
	local sRule = Divider.new(slice, { Name = "Rule line", Text = "or pick" })
	local sBar = ProgressBar.new(slice, { Name = "Download meter" })

	checkEq(SearchManager.set("download"), 1, "the term matches exactly one registered row")
	checkEq(sBar.Instance.Visible, true, "the matching row stays visible")
	checkEq(sBox.Instance.Visible, false, "the others drop out")
	checkEq(sLabel.Instance.Visible, false, "including the readout")
	checkEq(sNote.Instance.Visible, false, "the paragraph")
	checkEq(sRule.Instance.Visible, false, "and the divider")

	checkEq(SearchManager.set("kitup"), 1, "a paragraph's body text is searchable")
	checkEq(sNote.Instance.Visible, true, "and it came back for the match")
	checkEq(sBar.Instance.Visible, false, "while the bar dropped out")

	SearchManager.set("")
	checkEq(sBox.Instance.Visible, true, "clearing the term restores every row")
	checkEq(sBar.Instance.Visible, true, "all five of them")

	sBox:Destroy()
	sLabel:Destroy()
	sNote:Destroy()
	sRule:Destroy()
	sBar:Destroy()
	slice:Destroy()
end)

--[[ Theme swap -------------------------------------------------------------------------- ]]

runSpec("a theme swap repaints every role binding without touching a value", function()
	local look = newGroup("Look")
	local glow = Checkbox.new(look, { Name = "Glow mark" })
	glow:Set(true)
	local box = findPath(glow.Instance, "Body", "Box")
	local stroke = box:FindFirstChildOfClass("UIStroke")
	local live = Label.new(look, { Name = "Live rate", Value = 128, State = "accent" })
	local prose = Paragraph.new(look, { Name = "Prose note", Text = "plain words" })
	local seam = Divider.new(look, { Name = "Hair seam", Text = "mid" })
	local meter = ProgressBar.new(look, { Name = "Load gauge", Default = 0.5 })
	local barFill = findPath(meter.Instance, "Body", "Gauge", "Track", "Fill")

	local darkAccent = ThemeManager.color("Accent")
	checkEq(barFill.BackgroundColor3, darkAccent, "the fill rides the accent at rest")
	checkEq(stroke.Color, darkAccent, "the checked box border too")

	ThemeManager.use("Blue")
	local blue = Theme.presets.Blue.colors
	checkNe(ThemeManager.color("Accent"), darkAccent, "the preset really moved the accent token")
	checkEq(stroke.Color, blue.Accent, "the box border repainted")
	checkEq(box.BackgroundColor3, blue.AccentSoft, "the soft fill repainted")
	checkEq(findPath(live.Instance, "Body", "Value").TextColor3, blue.Accent, "the accent readout repainted")
	checkEq(barFill.BackgroundColor3, blue.Accent, "the progress fill repainted without a rebuild")
	checkEq(meter:GetValue(), 0.5, "while every value survived")
	checkEq(live:GetValue(), 128, "all of them")

	ThemeManager.set({ StrokeThickness = 4, TextSecondary = Color3.fromRGB(1, 2, 3) })
	checkEq(findPath(seam.Instance, "Line").Size.Y.Offset, 4, "the divider hairline thickens with the metric")
	checkEq(seam.Instance.Size.Y.Offset, 4 + 12, "and its row grows with it")
	checkEq(findPath(prose.Instance, "Body").TextColor3, Color3.fromRGB(1, 2, 3), "paragraph text follows its role")

	ThemeManager.forgetOverrides()
	ThemeManager.use("Dark")
	checkEq(ThemeManager.name(), "Dark", "the theme state is left clean")
	checkEq(ThemeManager.metric("StrokeThickness"), 1, "the pinned metric is gone, not just hidden")
	checkEq(findPath(seam.Instance, "Line").Size.Y.Offset, 1, "the hairline snapped back")
	checkEq(barFill.BackgroundColor3, darkAccent, "the accent came home")

	glow:Destroy()
	live:Destroy()
	prose:Destroy()
	seam:Destroy()
	meter:Destroy()
	look:Destroy()
end)

--[[ Surface + layout ---------------------------------------------------------------------- ]]

runSpec("the five share the contract surface and the declaration order", function()
	local order = newGroup("Order")
	local modules = {
		{ name = "Checkbox", module = Checkbox, flag = "One box" },
		{ name = "Label", module = Label, flag = "Two readout" },
		{ name = "Paragraph", module = Paragraph, flag = "Three prose" },
		{ name = "Divider", module = Divider, flag = "Four rule" },
		{ name = "ProgressBar", module = ProgressBar, flag = "Five meter" },
	}
	local made = {}
	for index, entry in ipairs(modules) do
		local widget = entry.module.new(order, { Name = entry.flag })
		check(widget.Instance ~= nil, entry.name .. " exposes Instance")
		checkEq(widget.Instance.LayoutOrder, index,
			entry.name .. " lands at row " .. tostring(index) .. ", matching group:RowCount()")
		checkEq(type(widget.GetValue), "function", entry.name .. " exposes GetValue")
		checkEq(type(widget.Set), "function", entry.name .. " exposes Set")
		checkEq(type(widget.SetVisible), "function", entry.name .. " exposes SetVisible")
		checkEq(type(widget.OnFilter), "function", entry.name .. " exposes OnFilter")
		checkEq(type(widget.SetTitle), "function", entry.name .. " exposes SetTitle")
		checkEq(type(widget.Destroy), "function", entry.name .. " exposes Destroy")
		table.insert(made, { name = entry.name, widget = widget })
	end
	checkEq(order:RowCount(), 5, "five rows tracked")

	for _, item in ipairs(made) do
		if item.name ~= "Paragraph" and item.name ~= "Divider" then
			check(item.widget.Changed ~= nil and type(item.widget.Changed.Connect) == "function",
				item.name .. " exposes Changed as a signal")
			checkEq(type(item.widget.SetCallback), "function", item.name .. " exposes SetCallback")
		else
			checkEq(item.widget.Changed, nil, item.name .. " is inert: no signal, nothing to fire")
		end
	end

	made[3].widget:Destroy()
	local sixth = Checkbox.new(order, { Name = "Sixth" })
	checkEq(order:RowCount(), 6, "a destroyed row leaves its slot; counting is append-only")
	checkEq(sixth.Instance.LayoutOrder, order:RowCount(), "a later row still lands after everything")

	made[1].widget:Destroy()
	made[2].widget:Destroy()
	made[4].widget:Destroy()
	made[5].widget:Destroy()
	sixth:Destroy()
	order:Destroy()
end)

runSpec("every row releases its theme bindings when the group goes", function()
	check(ThemeManager.bindingCount() > 0, "there are live bindings to release",
		"count " .. tostring(ThemeManager.bindingCount()))
	cb:Destroy()
	latency:Destroy()
	zone:Destroy()
	fps:Destroy()
	note:Destroy()
	rule:Destroy()
	bar:Destroy()
	cb:Destroy()
	checkEq(cb.Destroyed, true, "double destroy stays safe on every family member")
	main:Destroy()
	checkEq(ThemeManager.bindingCount(), 0, "group destruction takes every widget binding with it")

	checkEq(SearchManager.size(), 0, "and no row stayed in the search index")
	SearchManager.set("")
	ConfigManager.reset({ DeleteFile = true })
	checkEq(ConfigManager.exists(), false, "the spec profile is deleted behind us")
	checkEq(ThemeManager.name(), "Dark", "the theme is left exactly as we found it")
end)
