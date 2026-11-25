--[[
	spec 14 — the Keybind row.

	Everything the component claims, this file counts: the row owns no input hooks (all triggers
	run through one InputManager binding), capture is the manager's own session (Escape cancels,
	Delete clears under the session's ClearOnDelete rule, Home stays refused by the manager's
	forbidden list), hold rows are pulled by ONE shared frame pass for the whole module — never
	one coroutine per row — and a rebind, a capture, a Destroy or a config load can each only be
	observed through the row's own state, never through a UserInput object.

	The row is built on an *unmounted* groupbox the whole time: the tab never opens, so every
	assertion here also proves the "state lives in the component, not in the UI" contract.

	Each block cleans up after itself: every row is destroyed, InputManager.clear() runs, and any
	key left down is released, because the module singletons carry across blocks in one process.
]]

local Keybind = assert(fluxRequire("Flux/Components/Keybind"))
local InputManager = assert(fluxRequire("Flux/Systems/InputManager"))
local Maid = assert(fluxRequire("Flux/Utilities/Maid"))
local Groupbox = assert(fluxRequire("Flux/Core/Groupbox"))
local InstUtil = assert(fluxRequire("Flux/Utilities/Instance"))
local ThemeManager = assert(fluxRequire("Flux/Systems/ThemeManager"))
local ConfigManager = assert(fluxRequire("Flux/Systems/ConfigManager"))
local SearchManager = assert(fluxRequire("Flux/Systems/SearchManager"))

ConfigManager.configure({ AutoSave = false, SaveTheme = false })

local UIS = game:GetService("UserInputService")

--- A UserInput object shaped the way the engine builds one: KeyCode for keys, Unknown plus
--- UserInputType for mouse buttons (the same shape spec 09 presses through).
local function inputObject(keyName: string?, inputTypeName: string): any
	return {
		KeyCode = keyName ~= nil and Enum.KeyCode[keyName] or Enum.KeyCode.Unknown,
		UserInputType = Enum.UserInputType[inputTypeName],
		Position = Vector2.new(100, 100),
	}
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

local function chipOf(w: any): any
	return findPath(w.Instance, "Body", "Chip")
end

local function chipLabel(w: any): any
	return findPath(w.Instance, "Body", "Chip", "Text")
end

local function newGroup(title: string): any
	local tab = { Title = "Page14", Maid = Maid.new() }
	return Groupbox.new(tab, { Title = title, Collapsible = false })
end

local group = newGroup("Binds")

--- Each block owns its bindings and rows: the manager registry and the shared hold loop are
--- module state, and a leaked bind or poller fires in the next block and fails it there.
local function isolated(fn: () -> ())
	local ok, err = pcall(fn)
	InputManager.clear()
	pressKey("Escape")
	releaseKey("Escape")
	assert(ok, err)
end

runSpec("the default renders its label and works while the tab is unmounted", function()
	isolated(function()
		local fired = {}
		local before = InstUtil.count()
		local basic = Keybind.new(group, {
			Name = "Silent Aim",
			Default = "Q",
			Flag = "kb.basic",
			Callback = function(state)
				table.insert(fired, state)
			end,
		})
		local cost = InstUtil.count() - before
		check(cost <= 25, "a keybind row costs at most 25 instances at build", tostring(cost))

		-- The tab has never opened: the group panel has no parent, and nothing here cares.
		checkEq(group.Mounted, false, "the group is unmounted for this whole block")
		checkEq(group.Panel.Parent, nil, "its panel really has no parent")

		check(chipOf(basic) ~= nil, "the chip exists")
		checkEq(chipLabel(basic).Text, "Q", "the chip prints the bound key, not a placeholder")
		checkEq(basic:GetValue(), "Q", "GetValue is the stored trigger string")
		checkEq(basic:GetTrigger(), "Q", "GetTrigger agrees")
		checkEq(basic:GetLabel(), "Q", "the readable label")
		checkEq(basic:GetState(), false, "nobody is holding Q yet")
		checkEq(#fired, 0, "building never fires the callback")
		checkEq(ConfigManager.get("kb.basic", "unset"), "unset", "and stages nothing into the store")
		checkEq(chipLabel(basic).TextColor3, ThemeManager.color("TextSecondary"), "a bound chip rides the TextSecondary role")

		pressKey("Q")
		checkEq(#fired, 1, "the row fires even though its tab was never mounted")
		checkEq(fired[1], true, "press edge")
		checkEq(basic:GetState(), true, "and the live poll agrees while it is down")
		pressKey("Q")
		checkEq(#fired, 1, "auto-repeat does not re-fire (the manager's latch, not a row copy)")
		releaseKey("Q")
		checkEq(#fired, 1, "a toggle-mode row reports the press only, not the release")

		basic:Destroy()
	end)
end)

runSpec("clicking the row opens a capture and a real key press resolves it", function()
	isolated(function()
		local fired = 0
		local changed = 0
		local aim = Keybind.new(group, {
			Name = "Aim",
			Default = "Q",
			Flag = "kb.aim",
			Callback = function()
				fired += 1
			end,
		})
		local connection = aim.Changed:Connect(function()
			changed += 1
		end)

		clickInstance(chipOf(aim))
		checkEq(aim:IsCapturing(), true, "the chip click opened the capture")
		checkEq(InputManager.capturing(), 1, "through the manager's own session")
		check(chipLabel(aim).Text:find("Press a key", 1, true) ~= nil, "the chip visibly asks for a key")
		checkEq(findPath(aim.Instance, "Body", "Chip"):FindFirstChildOfClass("UIStroke").Color,
			ThemeManager.color("Accent"), "the chip border rides the Accent role while capturing")
		checkEq(findPath(aim.Instance, "Body", "Chip").BackgroundColor3, ThemeManager.color("Selection"),
			"and the chip fill rides Selection")

		-- A theme swap mid-capture repaints onto the capture roles, not the resting palette.
		ThemeManager.use(ThemeManager.name())
		checkEq(chipLabel(aim).TextColor3, ThemeManager.color("Accent"), "a repaint keeps the capture colour")

		clickInstance(chipOf(aim))
		checkEq(InputManager.capturing(), 1, "a second click cannot stack a second session")

		pressKey("M")
		checkEq(InputManager.capturing(), 0, "the press resolved the session")
		checkEq(aim:IsCapturing(), false, "and the row left the capture state")
		checkEq(aim:GetValue(), "M", "resolved through the manager payload, not a hand-rolled hook")
		checkEq(chipLabel(aim).Text, "M", "the chip shows the new key")
		checkEq(changed, 1, "Changed fires on a user rebind")
		checkEq(fired, 0, "rebinding itself never runs the host callback")
		checkEq(ConfigManager.get("kb.aim"), "M", "the config took the plain string")
		checkEq(type(ConfigManager.get("kb.aim")), "string", "not a table, not a UserInput")

		pressKey("M")
		checkEq(fired, 1, "the new key drives the callback immediately (push mode)")
		releaseKey("M")
		pressKey("Q")
		checkEq(fired, 1, "the replaced trigger is detached: Q is now inert")
		releaseKey("Q")

		connection:Disconnect()
		aim:Destroy()
	end)
end)

runSpec("Escape cancels and leaves the old bind; the manager keeps refusing Home", function()
	isolated(function()
		local fired = 0
		local row = Keybind.new(group, {
			Name = "Triggerbot",
			Default = "Q",
			Callback = function()
				fired += 1
			end,
		})

		-- The whole row is clickable, not just the chip: the hit layer covers the root.
		clickInstance(findPath(row.Instance, "HitArea"))
		checkEq(row:IsCapturing(), true, "a row click opened the capture")
		pressKey("Escape")
		checkEq(InputManager.capturing(), 0, "Escape closed the session")
		checkEq(row:IsCapturing(), false, "the row left the capture state on its own")
		checkEq(row:GetValue(), "Q", "the old bind stands")
		checkEq(chipLabel(row).Text, "Q", "and the chip stopped asking")
		pressKey("Q")
		checkEq(fired, 1, "the untouched binding still fires")
		releaseKey("Q")

		clickInstance(findPath(row.Instance, "HitArea"))
		pressKey("Home")
		checkEq(InputManager.capturing(), 1, "a forbidden key does not resolve the session")
		checkEq(row:IsCapturing(), true, "the row is still listening")
		checkEq(row:GetValue(), "Q", "and still bound to Q")
		pressKey("G")
		checkEq(InputManager.capturing(), 0, "a real key does")
		checkEq(row:GetValue(), "G", "captured through the manager's refusal list, not a row copy")
		releaseKey("G")

		-- CancelCapture closes the live session the row itself opened.
		clickInstance(chipOf(row))
		checkEq(InputManager.capturing(), 1, "capturing again")
		row:CancelCapture()
		checkEq(InputManager.capturing(), 0, "CancelCapture closed it")
		checkEq(row:IsCapturing(), false, "and the flag fell")

		row:Destroy()
	end)
end)

runSpec("Delete clears through the session; ClearOnDelete=false keeps the manager's rule", function()
	isolated(function()
		local fired = 0
		local row = Keybind.new(group, {
			Name = "Clearable",
			Default = "Q",
			Flag = "kb.del",
			Callback = function()
				fired += 1
			end,
		})
		clickInstance(chipOf(row))
		pressKey("Delete")
		checkEq(InputManager.capturing(), 0, "Delete finished the session")
		checkEq(row:GetValue(), nil, "the bind cleared")
		checkEq(chipLabel(row).Text, "Unbound", "the chip says so")
		pressKey("Q")
		releaseKey("Q")
		checkEq(fired, 0, "the cleared row's old key is detached, not merely hidden")
		checkEq(ConfigManager.get("kb.del", "gone"), "gone", "the cleared value left the store")

		local keep = Keybind.new(group, { Name = "KeepsDelete", Default = "Q", ClearOnDelete = false })
		clickInstance(chipOf(keep))
		pressKey("Delete")
		checkEq(InputManager.capturing(), 1, "with ClearOnDelete=false the manager stays listening (its rule, not the row's)")
		checkEq(keep:GetValue(), "Q", "the bind is untouched")
		pressKey("Z")
		checkEq(keep:GetValue(), "Z", "and a real key still resolves")
		releaseKey("Z")

		row:Destroy()
		keep:Destroy()
	end)
end)

runSpec("Set re-attaches: MB2, chords, bare modifier words and rejections", function()
	isolated(function()
		local fired = 0
		local row = Keybind.new(group, {
			Name = "Settable",
			Default = "Q",
			Flag = "kb.set",
			Callback = function()
				fired += 1
			end,
		})

		checkEq(row:Set("MB2"), row, "Set returns self")
		checkEq(row:GetValue(), "MouseButton2", "the short name is stored as the real enum name")
		checkEq(row:GetLabel(), "MB2", "and reads back as the short name")
		pressKey("Q")
		releaseKey("Q")
		checkEq(fired, 0, "the old trigger is detached the moment Set lands")
		UIS.InputBegan:Fire(inputObject(nil, "MouseButton2"), false)
		checkEq(fired, 1, "the mouse button drives it now")
		UIS.InputEnded:Fire(inputObject(nil, "MouseButton2"))

		row.Set(row, "LeftShift+K")
		checkEq(row:GetValue(), "Shift+K", "full Left/Right spellings collapse onto the manager's modifier tokens")
		checkEq(row:GetLabel(), "Shift + K", "the chord reads with its modifier")
		pressKey("K")
		checkEq(fired, 1, "a bare K does not fire a Shift+K bind")
		releaseKey("K")
		pressKey("LeftShift")
		pressKey("K")
		checkEq(fired, 2, "the chord does")
		releaseKey("K")
		releaseKey("LeftShift")
		checkEq(ConfigManager.get("kb.set"), "Shift+K", "the chord round-trips as one plain string")

		row:Set("Ctrl")
		checkEq(row:GetValue(), "LeftControl", "a lone modifier word binds the physical left key")
		checkEq(row:GetLabel(), "L-Ctrl", "and reads back through String.keyName")

		checkEq(row:Set(42), false, "a number is not a trigger")
		checkEq(row:GetValue(), "LeftControl", "the rejected Set changed nothing")
		checkEq(row:Set("+K"), false, "an empty chord slot is malformed, not a bare K")
		checkEq(row:Set(""), row, "an empty string clears instead of erroring")
		checkEq(row:GetValue(), nil, "and left the row unbound")
		local beforeClear = fired
		pressKey("LeftControl")
		releaseKey("LeftControl")
		checkEq(fired, beforeClear, "an unbound row fires nothing")

		row:Set(Enum.KeyCode.V)
		checkEq(row:GetValue(), "V", "an Enum member lands too (config entries and live items share the Name path)")
		local beforeV = fired
		pressKey("V")
		checkEq(fired, beforeV + 1, "and fires")
		releaseKey("V")

		row:Destroy()
	end)
end)

runSpec("a hold row is polled by ONE shared frame pass, never pushed", function()
	isolated(function()
		checkEq(Keybind.pollerCount(), 0, "no hold rows exist yet")
		checkEq(Keybind.loopRunning(), false, "and the shared loop is not connected")

		local boost = {}
		local jump = {}
		local h1 = Keybind.new(group, {
			Name = "Boost",
			Hold = true,
			Default = "K",
			Callback = function(state)
				table.insert(boost, state)
			end,
		})
		checkEq(Keybind.pollerCount(), 1, "the first hold row opened the loop")
		checkEq(Keybind.loopRunning(), true, "one RenderStepped connection")
		checkEq(h1:GetBinding().callback, nil, "the hold binding carries no pushed callback at all")

		pressKey("K")
		checkEq(h1:GetState(), true, "the live poll sees the key before any frame runs")
		checkEq(#boost, 0, "pressing alone fired nothing: the row is pulled, not pushed")
		local f0 = Keybind.pollFrames()
		stepClock(0.01)
		checkEq(Keybind.pollFrames(), f0 + 1, "one frame step is ONE loop pass")
		checkEq(#boost, 1, "the rising edge reached the host through that pass")
		checkEq(boost[1], true, "as a press")
		stepClock(0.01)
		checkEq(#boost, 1, "held steady across another frame: no re-fire")

		local h2 = Keybind.new(group, {
			Name = "Jump",
			Hold = true,
			Default = "J",
			Callback = function(state)
				table.insert(jump, state)
			end,
		})
		checkEq(Keybind.pollerCount(), 2, "two rows now share the loop")
		pressKey("J")
		local f1 = Keybind.pollFrames()
		stepClock(0.01)
		checkEq(Keybind.pollFrames(), f1 + 1, "still ONE pass per frame with two rows — not two loops")
		checkEq(#jump, 1, "the second row got its edge")
		checkEq(#boost, 1, "the first row did not double-fire")
		releaseKey("J")
		stepClock(0.01)
		checkEq(#jump, 2, "the release edge arrives on the next pass")
		checkEq(jump[2], false, "as a fall")
		releaseKey("K")
		stepClock(0.01)
		checkEq(#boost, 2, "and the same for the first row")

		-- Destroying one hold row must leave the other polled by the same loop.
		h1:Destroy()
		checkEq(Keybind.pollerCount(), 1, "the destroyed row left the poller list")
		checkEq(Keybind.loopRunning(), true, "the loop stays up for the survivor")
		pressKey("J")
		local f2 = Keybind.pollFrames()
		stepClock(0.01)
		checkEq(Keybind.pollFrames(), f2 + 1, "one pass serves the lone survivor")
		checkEq(#jump, 3, "the survivor still fires")
		releaseKey("J")
		stepClock(0.01)

		h2:Destroy()
		checkEq(Keybind.pollerCount(), 0, "no rows left")
		checkEq(Keybind.loopRunning(), false, "and the shared connection was closed")
		local f3 = Keybind.pollFrames()
		stepClock(0.01)
		checkEq(Keybind.pollFrames(), f3, "a stepped clock no longer runs any keybind loop")
	end)
end)

runSpec("a destroyed row can never fire again", function()
	isolated(function()
		local fired = 0
		local row = Keybind.new(group, {
			Name = "Doomed",
			Default = "Q",
			Flag = "kb.doom",
			Callback = function()
				fired += 1
			end,
		})
		local chip = chipOf(row)
		local hit = findPath(row.Instance, "HitArea")
		row:Destroy()
		checkEq(row.Destroyed, true, "Destroy marks the widget")

		pressKey("Q")
		releaseKey("Q")
		checkEq(fired, 0, "the unhooked binding is deaf: a destroyed row cannot fire")
		checkEq(#InputManager.conflictsFor(Enum.KeyCode.Q), 0, "and the manager no longer lists it")

		clickInstance(chip)
		clickInstance(hit)
		checkEq(row:IsCapturing(), false, "a stray click after teardown does not reopen a capture")
		checkEq(InputManager.capturing(), 0, "and opened no session")
		checkEq(row:Set("M"), false, "Set on a destroyed row is refused")
		checkEq(row:GetValue(), "Q", "with the state left alone")
		checkNoError(function()
			row:Clear()
			row:CancelCapture()
		end, "Clear and CancelCapture stay no-ops after teardown")
		row:Destroy()
		checkEq(row.Destroyed, true, "Destroy is idempotent")

		-- A hold row destroyed with its key physically down: the loop must drop it cleanly.
		local edges = 0
		local h = Keybind.new(group, {
			Name = "DoomedHold",
			Hold = true,
			Default = "T",
			Callback = function()
				edges += 1
			end,
		})
		pressKey("T")
		stepClock(0.01)
		checkEq(edges, 1, "the press edge landed while it lived")
		h:Destroy()
		releaseKey("T")
		checkNoError(function()
			stepClock(0.01)
			stepClock(0.01)
		end, "stepping after the destroy must not touch the gone row")
		checkEq(edges, 1, "and no falling edge haunts a destroyed hold row")
		checkEq(Keybind.pollerCount(), 0, "the poller list is empty again")
	end)
end)

runSpec("config round trip: write the store, reset, bind a fresh row, load", function()
	isolated(function()
		local fired = 0
		local first = Keybind.new(group, {
			Name = "Profile",
			Default = "Q",
			Flag = "kb.main",
			Callback = function()
				fired += 1
			end,
		})
		first:Set("LeftShift+P")
		checkEq(type(ConfigManager.get("kb.main")), "string", "the stored value is a plain JSON string")
		checkEq(ConfigManager.get("kb.main"), "Shift+P", "carrying the chord in canonical order")
		checkEq(ConfigManager.save(), true, "the store reached the file")
		first:Destroy()

		ConfigManager.reset({ DeleteFile = false })
		checkEq(ConfigManager.get("kb.main", "gone"), "gone", "the store is empty but the file stands")

		local second = Keybind.new(group, {
			Name = "Profile",
			Default = "Q",
			Flag = "kb.main",
			Callback = function()
				fired += 1
			end,
		})
		checkEq(second:GetValue(), "Q", "a fresh row starts from its declared default")
		local ok = ConfigManager.load()
		checkEq(ok, true, "the file read back")
		checkEq(second:GetValue(), "Shift+P", "the stored trigger re-attached to the new row")
		checkEq(second:GetLabel(), "Shift + P", "the chip shows it")
		pressKey("Q")
		releaseKey("Q")
		checkEq(fired, 0, "restoring re-attached, it did not merely paint: the default key stays inert")
		pressKey("LeftShift")
		pressKey("P")
		checkEq(fired, 1, "and the restored chord drives the host")
		releaseKey("P")
		releaseKey("LeftShift")
		second:Destroy()

		-- The manager's own config shape (a table with Name and Enum) is accepted too.
		ConfigManager.set("kb.table", { Name = "W", Enum = "KeyCode" })
		local tableFired = 0
		local tableRow = Keybind.new(group, {
			Name = "TableRestore",
			Flag = "kb.table",
			Callback = function()
				tableFired += 1
			end,
		})
		checkEq(tableRow:GetValue(), "W", "a restored { Name, Enum } entry lands as the plain name")
		checkEq(tableRow:GetLabel(), "W", "and the binding is live, not inert")
		pressKey("W")
		checkEq(tableFired, 1, "the restored table trigger actually drives the host")
		releaseKey("W")
		tableRow:Destroy()
	end)
end)

runSpec("the public surface matches Toggle's family, in both call styles", function()
	isolated(function()
		local old = 0
		local fresh = 0
		local row = Keybind.new(group, {
			Name = "Surface",
			Prompt = "Hit a key",
			Callback = function()
				old += 1
			end,
		})
		for _, name in ipairs({ "Set", "Clear", "GetValue", "GetTrigger", "GetLabel", "GetState", "IsCapturing", "SetCallback", "SetTitle", "SetText", "SetVisible", "OnFilter", "Destroy" }) do
			checkEq(type(row[name]), "function", name .. " exists")
		end
		check(row.Changed ~= nil and type(row.Changed.Connect) == "function", "Changed is a signal")
		checkEq(row.Instance, findPath(group.Content, "Keybind_Surface"), "Instance exposes the row root")
		checkEq(row.Title, "Surface", "Title is the row label")

		checkEq(row:SetVisible(false), row, "colon-call SetVisible returns self")
		checkEq(row.Instance.Visible, false, "and hid the row")
		row:SetVisible(true)
		checkEq(row.Instance.Visible, true, "and showed it again")

		checkEq(row:SetText("Renamed"), row, "SetText returns self")
		checkEq(findPath(row.Instance, "Text", "Title").Text, "Renamed", "and renames the row")
		checkEq(row:SetTitle("Renamed2"), row, "SetTitle is the same door")

		-- A custom prompt is what the chip shows while capturing.
		clickInstance(chipOf(row))
		checkEq(chipLabel(row).Text, "Hit a key", "the Prompt option replaced the default ask")
		row:OnFilter(false)
		checkEq(InputManager.capturing(), 0, "a filtered-out row closes its live capture")
		checkEq(row:IsCapturing(), false, "and left the state")
		checkEq(row.Instance.Visible, false, "while hiding itself")
		row.OnFilter(row, true)
		checkEq(row.Instance.Visible, true, "colon-call OnFilter reverses it")

		row:SetCallback(function()
			fresh += 1
		end)
		row:Set("B")
		pressKey("B")
		checkEq(fresh, 1, "SetCallback swapped the handler")
		checkEq(old, 0, "and the old one is gone")
		releaseKey("B")

		-- Search registration: the row reported itself through Element.searchable.
		local matched = SearchManager.set("surface")
		check(matched >= 1, "the row is registered with the search index", tostring(matched))
		checkEq(row.Instance.Visible, true, "and passes its own term")
		SearchManager.set("zzzznomatchzzzz")
		checkEq(row.Instance.Visible, false, "a dead term filters it out")
		pressKey("B")
		checkEq(fresh, 2, "a filtered-out row still obeys its bind (visibility is UI, state is the manager)")
		releaseKey("B")
		SearchManager.set("")
		checkEq(row.Instance.Visible, true, "clearing brings it back")

		row:Destroy()
	end)
end)

runSpec("a throwing host callback cannot take the hub down", function()
	isolated(function()
		local row = Keybind.new(group, {
			Name = "Explodes",
			Default = "Q",
			Callback = function()
				error("host bug")
			end,
		})
		checkNoError(function()
			pressKey("Q")
		end, "a pushed callback that throws is pcall'd")
		releaseKey("Q")

		local holdRow = Keybind.new(group, {
			Name = "ExplodesHold",
			Hold = true,
			Default = "U",
			Callback = function()
				error("host bug")
			end,
		})
		pressKey("U")
		checkNoError(function()
			stepClock(0.01)
		end, "a polled edge that throws is pcall'd too")
		releaseKey("U")
		checkNoError(function()
			stepClock(0.01)
		end, "and the falling edge survives as well")

		row:Destroy()
		holdRow:Destroy()
	end)
end)

runSpec("the whole group tears down cleanly", function()
	isolated(function()
		local a = Keybind.new(group, { Name = "Leak A", Default = "O", Hold = true })
		local b = Keybind.new(group, { Name = "Leak B", Default = "P" })
		check(ThemeManager.bindingCount() > 0, "there are live bindings to release", tostring(ThemeManager.bindingCount()))
		a:Destroy()
		b:Destroy()
		checkEq(Keybind.pollerCount(), 0, "the shared loop shut down with the last hold row")
		group:Destroy()
		checkEq(ThemeManager.bindingCount(), 0, "group destruction takes every widget binding with it")
		checkNoError(function()
			pressKey("O")
			releaseKey("O")
		end, "a stray press after teardown is inert, not fatal")
	end)
end)
