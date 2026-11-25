--[[
	spec 16 — the two floating surfaces: notifications and tooltips.

	Neither belongs to a window, which is the whole reason they are separate systems: a hub that
	shows a toast while two windows are open has to paint one stack, and a row that is destroyed
	under the pointer has to take its tooltip with it. Both are single-instance owners, so the
	interesting assertions are about handoffs and lifetimes rather than layout.
]]

local Library = assert(fluxRequire("Flux/Core/Library"))
local Notifications = assert(fluxRequire("Flux/Systems/NotificationManager"))
local Tooltips = assert(fluxRequire("Flux/Systems/TooltipManager"))
local AnimationManager = assert(fluxRequire("Flux/Systems/AnimationManager"))
local ThemeManager = assert(fluxRequire("Flux/Systems/ThemeManager"))
local IconManager = assert(fluxRequire("Flux/Systems/IconManager"))
local ConfigManager = assert(fluxRequire("Flux/Systems/ConfigManager"))
local InstUtil = assert(fluxRequire("Flux/Utilities/Instance"))
local Guard = assert(fluxRequire("Flux/Utilities/Guard"))

ConfigManager.configure({ AutoSave = false })
Notifications.configure({ Max = 4, Duration = 5, Width = 288, Anchor = "TopRight" })

local function reset()
	Notifications.destroy()
	Tooltips.destroy()
	Notifications.configure({ Max = 4, Duration = 5, Width = 288, Anchor = "TopRight" })
	Tooltips.configure({ Delay = 0.35, Offset = 12, MaxWidth = 240 })
	AnimationManager.stopAll()
	AnimationManager.setReducedMotion(false)
	setViewport(1280, 720)
end

--- On this client the hub's floating surfaces live under CoreGui, because the library only reaches
--- for `Player.PlayerGui` when the player already has it as a child. Search both.
local function roots(): {any}
	local out = {}
	local core = Guard.service("CoreGui")
	if core ~= nil then
		table.insert(out, core)
	end
	local player = game:GetService("Players").LocalPlayer
	local own = Guard.get(player, "PlayerGui")
	if own ~= nil then
		table.insert(out, own)
	end
	return out
end

local function findAll(name: string): {any}
	local out = {}
	for _, root in ipairs(roots()) do
		for _, child in ipairs(root:GetDescendants()) do
			if tostring(child.Name) == name then
				table.insert(out, child)
			end
		end
	end
	return out
end

--- Count the toast cards actually in the tree, so an assertion about `count()` cannot pass on a
--- list that was emptied while its instances leaked.
local function stackChildren(): number
	local total = 0
	for _, root in ipairs(roots()) do
		for _, child in ipairs(root:GetDescendants()) do
			if tostring(child.Name):sub(1, 13) == "Notification_" then
				total += 1
			end
		end
	end
	return total
end

--- First instance with this exact name anywhere under `parent`.
local function findIn(parent: any, name: string): any
	for _, child in ipairs(parent:GetDescendants()) do
		if tostring(child.Name) == name then
			return child
		end
	end
	return nil
end

--- The text column of a card, which is what the glyph displaces.
local function bodyOffset(note: any): number
	local body = findIn(note.instance, "Body")
	return body ~= nil and body.Position.X.Offset or -1
end

--- Where the single tooltip surface currently sits, in screen pixels.
local function tooltipPosition(): any
	local found = findAll("Tooltip")
	local surface = found[1]
	if surface == nil then
		return Vector2.new(-1, -1)
	end
	return Vector2.new(surface.Position.X.Offset, surface.Position.Y.Offset)
end

local function stackFrames(): number
	return #findAll("NotificationStack")
end

runSpec("a notification is a card with the text it was given", function()
	reset()
	local before = InstUtil.count()
	local note = Notifications.notify({ Title = "Loaded", Text = "32 features ready", Kind = "success" })
	local cost = InstUtil.count() - before

	checkNe(note, nil, "notify hands back a handle")
	checkEq(Notifications.count(), 1, "and one toast is showing")
	checkEq(note:GetText(), "32 features ready", "the handle remembers its body text")
	checkEq(note.kind, "success", "the kind is the one asked for")
	checkEq(note.instance.Name, "Notification_1", "the card is numbered in arrival order")
	checkEq(note.instance.Parent.Name, "NotificationStack", "inside the shared stack")
	check(note.title.Text == "Loaded", "the title label carries the title: " .. tostring(note.title.Text))
	checkEq(note.barHost.Visible, false, "no progress was asked for, so no track is shown")
	check(cost > 8, "a card is a real subtree (" .. cost .. ")", tostring(cost))

	-- An unknown kind is info, not a failure: a host typo must not swallow the message.
	local odd = Notifications.notify({ Kind = "celebration", Text = "still shown" })
	checkEq(odd.kind, "info", "an unlisted kind falls back to info")
	checkEq(Notifications.count(), 2, "and the toast still appears")

	-- Markup in a host's message is escaped, because the labels render with RichText on.
	local risky = Notifications.notify({ Text = "<b>bold</b> & <i>italics</i>" })
	check(risky.textLabel.Text ~= "<b>bold</b> & <i>italics</i>", "raw markup is not passed through")
	check(risky.textLabel.Text:find("&lt;") ~= nil, "angle brackets arrive escaped: " .. tostring(risky.textLabel.Text))

	Notifications.clear()
	checkEq(Notifications.count(), 0, "clear takes them all")
	checkEq(stackChildren(), 0, "and destroys the cards, not just the list")

	reset()
end)

runSpec("a toast carries the glyph of its kind", function()
	reset()

	-- Every documented kind has to name a glyph the atlas actually holds, or the card shows a hole.
	for kind, glyph in pairs(Notifications.icons) do
		checkEq(IconManager.has(glyph), true, "the " .. kind .. " icon exists: " .. tostring(glyph))
		local note = Notifications.notify({ Text = "a " .. kind .. " toast", Kind = kind, Duration = 60 })
		checkNe(findIn(note.instance, "Icon_" .. glyph), nil, kind .. " paints its glyph")
		checkEq(bodyOffset(note), 42, kind .. " steps the text past it")
		note:Dismiss(true)
	end

	checkEq(Notifications.kinds.info, "Info", "the kind table names theme roles")
	for _, role in pairs(Notifications.kinds) do
		checkNe(ThemeManager.color(role), nil, "and every role paints: " .. role)
	end

	-- An explicit icon wins over the kind's default, because a host that asks for a target glyph
	-- means that glyph.
	local asked = Notifications.notify({ Text = "custom", Kind = "info", Icon = "target", Duration = 60 })
	checkNe(findIn(asked.instance, "Icon_target"), nil, "the requested glyph is the one built")
	checkEq(findIn(asked.instance, "Icon_info"), nil, "and the kind's default is not also drawn")
	asked:Dismiss(true)

	-- A name the atlas does not hold degrades to the accent strip rather than an empty box.
	local bogus = Notifications.notify({ Text = "unknown", Icon = "not-a-real-icon", Duration = 60 })
	checkEq(findIn(bogus.instance, "Icon_not-a-real-icon"), nil, "an unknown icon builds nothing")
	checkEq(bodyOffset(bogus), 26, "so the text keeps the full width")

	Notifications.clear()
	reset()
end)

runSpec("a toast lives for its duration and then goes", function()
	reset()
	local note = Notifications.notify({ Title = "Saved", Text = "config saved", Duration = 2 })
	checkEq(Notifications.count(), 1, "showing")

	stepClock(1)
	checkEq(Notifications.count(), 1, "still there at half its life")

	stepClock(1.2)
	checkEq(Notifications.count(), 0, "gone after its own duration")
	-- The card leaves with a fade, so it is still in the tree for the few frames that take.
	pumpFrames(20)
	checkEq(stackChildren(), 0, "and the card was destroyed with it")

	-- Persistent is the documented way to keep one until it is dismissed.
	local kept = Notifications.notify({ Title = "Working", Text = "do not go", Persistent = true })
	checkEq(kept.duration, 0, "a persistent toast has no timer")
	stepClock(60)
	checkEq(Notifications.count(), 1, "still up after a minute")
	kept:Dismiss(true)
	checkEq(Notifications.count(), 0, "and only the caller ends it")

	-- The configured default applies to a toast that says nothing about duration.
	Notifications.configure({ Duration = 1 })
	local quick = Notifications.notify({ Text = "default timing" })
	checkEq(quick.duration, 1, "it took the configured default")
	stepClock(1.4)
	checkEq(Notifications.count(), 0, "and expired with it")

	-- configure clamps rather than accepting nonsense.
	local settings = Notifications.configure({ Max = 0, Duration = -5, Width = 10 })
	checkEq(settings.Max, 1, "the cap never drops below one")
	checkEq(settings.Duration, 0.5, "and a duration has a floor")
	checkEq(settings.Width, 160, "the width keeps a readable minimum")

	reset()
end)

runSpec("the cap dismisses the oldest and counts what it dropped", function()
	reset()
	Notifications.configure({ Max = 3, Duration = 30 })

	local first = Notifications.notify({ Title = "one", Text = "1" })
	Notifications.notify({ Title = "two", Text = "2" })
	Notifications.notify({ Title = "three", Text = "3" })
	checkEq(Notifications.count(), 3, "the cap holds")
	checkEq(Notifications.dropped(), 0, "nothing dropped yet")

	Notifications.notify({ Title = "four", Text = "4" })
	checkEq(Notifications.count(), 3, "still at the cap")
	checkEq(Notifications.dropped(), 1, "the oldest was pushed out")
	checkEq(first.destroyed, true, "and its handle knows")
	checkEq(stackChildren(), 4, "the pushed-out card is mid-fade, not yanked")
	pumpFrames(20)
	checkEq(stackChildren(), 3, "and it is gone from the screen once the fade completes")

	for _ = 1, 5 do
		Notifications.notify({ Title = "spam", Text = "x", Duration = 30 })
	end
	checkEq(Notifications.count(), 3, "a flood cannot grow the stack")
	checkEq(Notifications.dropped(), 6, "and every push is counted", tostring(Notifications.dropped()))

	-- A cap of one is a legal configuration, not a division by zero.
	Notifications.configure({ Max = 1, Duration = 30 })
	Notifications.notify({ Text = "only" })
	checkEq(Notifications.count(), 1, "one at a time")

	-- clear() resets the ledger so the next session's numbers mean something.
	Notifications.clear()
	checkEq(Notifications.dropped(), 0, "clearing empties the counter too")

	reset()
end)

runSpec("a toast updates in place and re-times itself", function()
	reset()
	local note = Notifications.notify({ Title = "Download", Text = "0%", Progress = 0, Duration = 2 })
	checkEq(note.barHost.Visible, true, "a progress toast shows its track")
	checkEq(note.bar.Size.X.Scale, 0, "starting empty")

	checkEq(note:Update({ Text = "50%", Progress = 0.5 }), true, "the update landed")
	checkEq(note:GetText(), "50%", "the handle reports the new text")
	checkEq(note.textLabel.Text, "50%", "and the label was rewritten")
	checkEq(note.bar.Size.X.Scale, 0.5, "the bar moved")
	checkEq(note.progress, 0.5, "and the model agrees")

	-- Out-of-range progress is clamped rather than drawn off the card.
	note:Update({ Progress = 4 })
	checkEq(note.bar.Size.X.Scale, 1, "clamped to full")
	note:Update({ Progress = -1 })
	checkEq(note.bar.Size.X.Scale, 0, "and to empty")

	-- Updating restarts the countdown, which is what a long download needs.
	stepClock(1.5)
	note:Update({ Text = "99%" })
	stepClock(1.5)
	checkEq(Notifications.count(), 1, "the re-timed toast outlived its original duration")

	-- Unless the caller says not to.
	note:Update({ Text = "still", Retime = false })
	stepClock(1.5)
	checkEq(Notifications.count(), 0, "Retime=false keeps the original deadline")

	-- Updating a dismissed toast is a no-op, not an error: a host's async work finishes after the
	-- user closed the card.
	local gone = Notifications.notify({ Text = "ephemeral", Duration = 1 })
	gone:Dismiss(true)
	checkEq(gone:Update({ Text = "too late" }), false, "an update to a dead toast says no")
	checkEq(gone:GetText(), "ephemeral", "and changes nothing")


	reset()
end)

runSpec("dismissal is animated unless the caller is in a hurry", function()
	reset()
	local note = Notifications.notify({ Title = "Fade", Text = "out", Duration = 30 })
	local card = note.instance

	Notifications.Added:Connect(function() end)
	local removedIds = {}
	local connection = Notifications.Removed:Connect(function(id)
		table.insert(removedIds, id)
	end)

	note:Dismiss()
	checkEq(Notifications.count(), 0, "it leaves the visible list immediately")
	checkNe(card.Parent, nil, "but the card is still on screen while it fades")
	pumpFrames(30)
	checkEq(card.Parent, nil, "and is destroyed when the fade ends")
	checkEq(#removedIds, 1, "Removed reported it once")
	checkEq(removedIds[1], note.id, "with the id of the toast that went")

	-- Instant is what a teardown path wants.
	local now = Notifications.notify({ Text = "gone now" })
	now:Dismiss(true)
	checkEq(now.instance.Parent, nil, "instant removes the card without a fade")

	-- Reduced motion collapses the fade instead of leaving a card that never disappears.
	AnimationManager.setReducedMotion(true)
	local flat = Notifications.notify({ Text = "no motion" })
	flat:Dismiss()
	checkEq(flat.instance.Parent, nil, "with motion off the card goes at once")
	AnimationManager.setReducedMotion(false)

	connection:Disconnect()
	Notifications.clear()
	reset()
end)

runSpec("the stack follows the window it was attached to", function()
	reset()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Host", ToggleKey = false })

	checkEq(stackFrames(), 1, "building a window attached exactly one stack")
	local stack = findAll("NotificationStack")[1]
	checkEq(stack.Parent, window.Gui, "inside that window's ScreenGui, not a new one")

	Notifications.notify({ Text = "in the window", Duration = 30 })
	checkEq(Notifications.count(), 1, "and the toast landed there")
	checkEq(stackChildren(), 1, "as one card in that stack")

	-- A second window takes ownership. The first host's frame has to go with the handoff, or a hub
	-- opened in two places keeps an empty stack nobody can reach.
	local second = Flux:Window({ Title = "Second", ToggleKey = false })
	checkEq(stackFrames(), 1, "still one stack frame in the whole tree")
	checkEq(findAll("NotificationStack")[1].Parent, second.Gui, "and it belongs to the newest window")

	Notifications.notify({ Text = "still one stack", Duration = 30 })
	checkEq(Notifications.count(), 2, "both toasts are in the current stack")
	checkEq(stackChildren(), 2, "as two cards")

	-- Destroying the host releases the surface instead of leaving the manager pointing at a dead gui.
	checkEq(Notifications.detach(second.Gui), true, "the host gave the stack back")
	checkEq(Notifications.count(), 0, "its toasts went with it")
	checkEq(stackFrames(), 0, "and the stack frame is gone")
	checkEq(Notifications.detach(second.Gui), false, "detaching twice is quiet")

	Notifications.notify({ Text = "no window left", Duration = 30 })
	checkEq(Notifications.count(), 1, "a detached manager builds its own collector rather than failing")
	checkEq(stackFrames(), 1, "in a ScreenGui of its own")

	Flux:Unload()
	checkEq(Notifications.count(), 0, "unloading the hub clears the toasts")
	checkEq(stackFrames(), 0, "and takes the collector down with it")
	reset()
end)

runSpec("tooltips attach, wait, appear and let go", function()
	reset()
	local Flux = Library.new({ Config = false })
	local window = Flux:Window({ Title = "Tips", ToggleKey = false })
	local group = window:Tab({ Title = "Aim" }):GroupBox({ Title = "Legit" })
	local row = group:Toggle({ Name = "Silent aim", Desc = "Bends shots to the crosshair", Flag = "tip.a" })

	-- The tooltip lives on the row's hit area, which is the full-width button laid over it, not the
	-- card row itself — hovering the row's root would fire nothing on a real client too.
	local button = row.Instance:FindFirstChild("HitArea")
	check(button ~= nil, "the toggle built its hit area")
	checkEq(Tooltips.isShown(), false, "nothing is on screen at rest")
	local before = Tooltips.attached()
	check(before >= 1, "a row with a description attached a tooltip (" .. before .. ")", tostring(before))

	hoverInstance(button)
	checkEq(Tooltips.isShown(), false, "hover alone does not show it — the delay is the point")
	stepClock(0.2)
	checkEq(Tooltips.isShown(), false, "still hidden before the delay is up")
	stepClock(0.3)
	checkEq(Tooltips.isShown(), true, "and shown once the pointer has rested")

	unhoverInstance(button)
	checkEq(Tooltips.isShown(), false, "leaving hides it immediately")

	-- Moving on to a second row re-arms the delay rather than flashing the first message.
	local other = group:Toggle({ Name = "Prediction", Desc = "Leads the target", Flag = "tip.b" })
	local otherButton = other.Instance:FindFirstChild("HitArea")
	hoverInstance(button)
	stepClock(0.5)
	checkEq(Tooltips.isShown(), true, "first row is open")
	hoverInstance(otherButton)
	checkEq(Tooltips.isShown(), false, "crossing to the next row hides rather than swaps instantly")
	stepClock(0.5)
	checkEq(Tooltips.isShown(), true, "the new message arrives after its own delay")

	-- A zero delay is a legal configuration for a host that wants instant hints.
	Tooltips.configure({ Delay = 0 })
	checkEq(Tooltips.configure({ Delay = 0 }).Delay, 0, "the setting took")
	Tooltips.request("immediate", 0)
	checkEq(Tooltips.isShown(), true, "requesting with no delay shows at once")
	Tooltips.hide()
	checkEq(Tooltips.isShown(), false, "and hide is unconditional")

	-- Unbinding releases the count and closes the surface; the maid path is what a component uses.
	-- The baseline is read here rather than at the top of the block, because the second toggle built
	-- a tooltip of its own in between.
	local baseline = Tooltips.attached()
	local unbind = Tooltips.attach(button, "an extra hint")
	checkEq(Tooltips.attached(), baseline + 1, "one more attached")
	unbind()
	checkEq(Tooltips.attached(), baseline, "the unbind gave it back")
	unbind()
	checkEq(Tooltips.attached(), baseline, "and a second call changes nothing")

	-- Attaching to nothing is a silent no-op, because a component may build a row without a label.
	checkEq(type(Tooltips.attach(nil, "text")), "function", "a nil instance returns a do-nothing unbind")
	checkEq(type(Tooltips.attach(button, "")), "function", "and so does empty text")
	checkEq(Tooltips.attached(), baseline, "neither of them counted")

	Flux:Unload()
	reset()
end)

runSpec("a tooltip stays inside the viewport", function()
	reset()
	Tooltips.configure({ Offset = 12 })

	-- The harness reports the pointer at the centre of the viewport, so the placement math is
	-- exercised by moving the screen rather than the mouse.
	setViewport(1280, 720)
	Tooltips.request("a hint", 0)
	local pos = tooltipPosition()
	check(pos.X > 12, "placed to the right of the pointer", tostring(pos.X))
	check(pos.Y > 12, "and below it", tostring(pos.Y))
	checkEq(Tooltips.isShown(), true, "showing")

	-- A screen so narrow that the offset side would fall off the edge clamps back inside it.
	setViewport(60, 60)
	Tooltips.request("tight", 0)
	local tight = tooltipPosition()
	check(tight.X >= 8, "never closer to the left edge than the margin", tostring(tight.X))
	check(tight.Y >= 8, "or to the top", tostring(tight.Y))

	Tooltips.tick()
	checkEq(Tooltips.isShown(), true, "ticking while hidden is safe")
	Tooltips.hide()
	Tooltips.tick()
	checkEq(Tooltips.isShown(), false, "and while closed it does not reappear")

	-- destroy() drops the surface entirely; the next request rebuilds it.
	local before = InstUtil.count()
	Tooltips.destroy()
	check(InstUtil.count() == before, "destroy created nothing, it only removed")
	Tooltips.request("again", 0)
	checkEq(Tooltips.isShown(), true, "and a request after destroy builds a fresh surface")
	Tooltips.destroy()

	setViewport(1280, 720)
	reset()
end)

runSpec("the hub owns both surfaces and releases both", function()
	reset()
	local Flux = Library.new({
		Config = false,
		Notifications = { Max = 2, Duration = 3 },
		Tooltips = { Delay = 0.1 },
	})
	local window = Flux:Window({ Title = "Owned", ToggleKey = false })
	local group = window:Tab({ Title = "Aim" }):GroupBox({ Title = "Legit" })
	local row = group:Toggle({ Name = "Silent aim", Desc = "hint text", Flag = "own.a" })

	Flux:Notify({ Title = "from the façade", Text = "body", Duration = 30 })
	checkEq(Notifications.count(), 1, "Flux:Notify reached the manager")

	hoverInstance(row.Instance:FindFirstChild("HitArea"))
	stepClock(0.2)
	checkEq(Tooltips.isShown(), true, "the configured tooltip delay applied")

	-- A hub that is torn down has to leave no floating surface behind, or re-running it stacks a
	-- second copy of everything.
	Flux:Unload()
	checkEq(Notifications.count(), 0, "no toasts survived")
	checkEq(Tooltips.isShown(), false, "no tooltip survived")
	checkEq(Tooltips.attached(), 0, "and no hover connection is still registered")

	local attachedAfter = Tooltips.attached()
	checkEq(attachedAfter, 0, "the count really is zero", tostring(attachedAfter))

	reset()
end)
