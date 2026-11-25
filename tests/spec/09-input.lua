--[[
	spec 09 — InputManager.

	The engine does not hand a keybind listener the Enum member it registered: it hands over a
	UserInput object whose KeyCode member *is* that item. Comparing the two with `==` is the oldest
	input bug in this kind of library, and it is invisible in a stub that fires plain tables, so
	every block below presses keys through the same object shape the real service fires.

	Hold bindings are polled (`GetState`) rather than trusted to InputEnded, chords must not
	over-match, and a capture session has to hand back something a config file can restore.
]]

local InputManager = assert(fluxRequire("Flux/Systems/InputManager"))

local UIS = game:GetService("UserInputService")

--- A UserInput object, the way the engine builds one: KeyCode for a key, Unknown plus
--- UserInputType for a mouse button.
local function inputObject(keyName: string?, inputTypeName: string): any
	return {
		KeyCode = keyName ~= nil and Enum.KeyCode[keyName] or Enum.KeyCode.Unknown,
		UserInputType = Enum.UserInputType[inputTypeName],
		Position = Vector2.new(100, 100),
	}
end

local function fireBegan(input: any, processed: boolean?)
	UIS.InputBegan:Fire(input, processed == true)
end

local function fireEnded(input: any)
	UIS.InputEnded:Fire(input)
end

--- Each block owns its bindings: the registry is module state, and a leaked bind fires in the
--- next block and shows up as a failure there. Escape closes whatever session is still listening.
local function isolated(fn: () -> ())
	local ok, err = pcall(fn)
	InputManager.clear()
	pressKey("Escape")
	releaseKey("Escape")
	assert(ok, err)
end

runSpec("a key press fires the binding it matches", function()
	isolated(function()
		local down = 0
		local up = 0
		local edges = {}

		local bind = InputManager.bind({
			Name = "test.g",
			Key = Enum.KeyCode.G,
			Callback = function(state)
				edges[#edges + 1] = state
			end,
			OnDown = function()
				down += 1
			end,
			OnUp = function()
				up += 1
			end,
		})

		checkEq(bind:GetInput(), Enum.KeyCode.G, "the trigger is stored as the Enum member")

		-- The press arrives as a UserInput object, not as Enum.KeyCode.G.
		pressKey("G")
		checkEq(down, 1, "the press fired")
		checkEq(edges[1], true, "and the callback saw the rising edge")

		pressKey("G")
		checkEq(down, 1, "an auto-repeat does not fire it twice while it is held")

		releaseKey("G")
		checkEq(up, 0, "a toggle bind has no falling edge to report")

		pressKey("G")
		checkEq(down, 2, "and pressing again after releasing fires it once more")
		checkEq(#edges, 2, "two rising edges, no falling ones")

		releaseKey("G")
	end)
end)

runSpec("an unrelated key does not fire it", function()
	isolated(function()
		local fired = 0
		InputManager.bind({ Key = Enum.KeyCode.G, Callback = function()
			fired += 1
		end })

		pressKey("H")
		checkEq(fired, 0, "H is not G")

		releaseKey("H")
		checkEq(fired, 0, "and releasing it is not a falling edge either")
	end)
end)

runSpec("a mouse button is a binding too", function()
	isolated(function()
		local fired = 0
		local bind = InputManager.bind({ Key = Enum.UserInputType.MouseButton2, Callback = function()
			fired += 1
		end })

		-- A mouse press carries KeyCode.Unknown, so matching has to go through UserInputType.
		fireBegan(inputObject(nil, "MouseButton2"))
		checkEq(fired, 1, "the side button fired it")
		checkEq(bind:GetLabel(), "MB2", "and the row reads MB2")

		fireBegan(inputObject(nil, "MouseButton1"))
		checkEq(fired, 1, "the primary button is a different trigger")
	end)
end)

runSpec("a chord matches the modifier set", function()
	isolated(function()
		local fired = 0
		local bind = InputManager.bind({
			Key = Enum.KeyCode.G,
			Mods = { Ctrl = true },
			Callback = function()
				fired += 1
			end,
		})

		pressKey("G")
		checkEq(fired, 0, "a bare G does not fire a Ctrl+G bind")

		pressKey("LeftControl")
		pressKey("G")
		checkEq(fired, 1, "Ctrl+G does")
		checkEq(bind:GetLabel(), "Ctrl + G", "and the label carries the modifier")

		releaseKey("G")

		local bare = 0
		InputManager.bind({ Key = Enum.KeyCode.H, Callback = function()
			bare += 1
		end })
		pressKey("H")
		checkEq(bare, 0, "and while Ctrl is still down, a bare bind stays silent")

		releaseKey("LeftControl")
		pressKey("H")
		checkEq(bare, 1, "released, the bare bind works again")

		releaseKey("H")
	end)
end)

runSpec("mods the caller did not list are not checked", function()
	isolated(function()
		local fired = 0
		InputManager.bind({ Key = Enum.KeyCode.K, Mods = { Shift = true }, Callback = function()
			fired += 1
		end })

		pressKey("LeftControl")
		pressKey("LeftShift")
		pressKey("K")
		checkEq(fired, 1, "Ctrl+Shift+K fires a Shift+K bind, since the bind never mentioned Ctrl")

		releaseKey("K")
		releaseKey("LeftShift")
		releaseKey("LeftControl")
	end)
end)

runSpec("a hold binding is pulled, not pushed", function()
	isolated(function()
		local events = {}
		local bind = InputManager.bind({
			Key = Enum.KeyCode.X,
			Mode = "hold",
			Callback = function(state)
				events[#events + 1] = state
			end,
			OnDown = function()
				events[#events + 1] = "down"
			end,
			OnUp = function()
				events[#events + 1] = "up"
			end,
		})

		pressKey("X")
		checkEq(events[1], "down", "onDown first, so a caller can gate work on it")
		checkEq(events[2], true, "and the callback reports the rising edge")
		checkEq(bind:IsHeld(), true, "the binding knows it is held")
		checkEq(bind:GetState(), true, "and polling agrees")

		releaseKey("X")
		checkEq(#events, 4, "release produced the falling edge too")
		checkEq(events[3], "up", "onUp ran")
		checkEq(events[4], false, "and the callback said false")
		checkEq(bind:GetState(), false, "polling agrees once more")

		pressKey("X")
		checkEq(bind:GetState(), true, "held again")
		InputManager.releaseAll("focus")
		checkEq(bind:IsHeld(), false, "losing focus releases it without waiting for InputEnded")
		releaseKey("X")
		checkEq(bind:IsHeld(), false, "and the release that arrives late is not an error")
	end)
end)

runSpec("GetState respects the chord", function()
	isolated(function()
		local bind = InputManager.bind({ Key = Enum.KeyCode.V, Mods = { Alt = true }, Mode = "hold" })

		pressKey("V")
		checkEq(bind:GetState(), false, "the key is down but Alt is not, so it is not the bind")
		pressKey("LeftAlt")
		checkEq(bind:GetState(), true, "both down, it is")
		releaseKey("LeftAlt")
		checkEq(bind:GetState(), false, "letting go of the modifier drops it even with the key held")
		releaseKey("V")
	end)
end)

runSpec("a trigger can be a name or a restored config entry", function()
	isolated(function()
		local byName = 0
		local byConfig = 0
		InputManager.bind({ Key = "T", Callback = function()
			byName += 1
		end })
		InputManager.bind({ Key = { Name = "Y", Enum = "KeyCode" }, Callback = function()
			byConfig += 1
		end })

		pressKey("T")
		pressKey("Y")
		checkEq(byName, 1, "a string key resolves through Enum.KeyCode")
		checkEq(byConfig, 1, "and a config table carries both the name and its enum")

		releaseKey("T")
		releaseKey("Y")

		local mouse = InputManager.bind({ Key = { Name = "MouseButton1", Enum = "UserInputType" } })
		checkEq(mouse:GetInput(), Enum.UserInputType.MouseButton1, "the Enum field picks UserInputType")

		local empty = InputManager.bind({})
		checkEq(empty:GetInput(), nil, "a bind with no key listens for nothing")
		checkEq(empty:GetLabel(), "Unbound", "and the row says so instead of guessing")
		checkEq(empty:Set(nil), false, "and Set refuses a trigger it cannot resolve")
		checkEq(empty:GetInput(), nil, "leaving the bind unbound rather than half-set")
	end)
end)

runSpec("typing in a TextBox silences ordinary binds only", function()
	isolated(function()
		local plain = 0
		local whileTyping = 0
		InputManager.bind({ Key = Enum.KeyCode.J, Callback = function()
			plain += 1
		end })
		InputManager.bind({
			Key = Enum.KeyCode.Q,
			AllowWhileTyping = true,
			Callback = function()
				whileTyping += 1
			end,
		})

		setFocusedTextBox(Instance.new("TextBox"))
		pressKey("J")
		checkEq(plain, 0, "a bind does not fire while the user is typing")

		pressKey("Q")
		checkEq(whileTyping, 1, "one that asked to allow it still fires")

		setFocusedTextBox(nil)
		pressKey("J")
		checkEq(plain, 1, "and the ordinary bind works again once focus leaves")

		releaseKey("J")
		releaseKey("Q")
	end)
end)

runSpec("input the game already consumed is not a bind", function()
	isolated(function()
		local key = 0
		local click = 0
		InputManager.bind({ Key = Enum.KeyCode.F, AllowWhileTyping = true, Callback = function()
			key += 1
		end })
		InputManager.bind({ Key = Enum.UserInputType.MouseButton1, Callback = function()
			click += 1
		end })

		fireBegan(inputObject("F", "Keyboard"), true)
		checkEq(key, 0, "processed=true means the engine used the press")

		fireBegan(inputObject(nil, "MouseButton1"), true)
		checkEq(click, 0, "and a click that landed on game UI is not a bind either")

		fireBegan(inputObject("F", "Keyboard"))
		fireBegan(inputObject(nil, "MouseButton1"))
		checkEq(key, 1, "unprocessed, both fire")
		checkEq(click, 1, "including the mouse bind")
	end)
end)

runSpec("conflicts, destroy and release", function()
	isolated(function()
		local bind = 0
		local first = InputManager.bind({ Key = Enum.KeyCode.B, Name = "one", Callback = function()
			bind += 1
		end })
		local other = InputManager.bind({ Key = Enum.KeyCode.B, Name = "two" })

		checkEq(#InputManager.conflictsFor(Enum.KeyCode.B), 2, "two binds point at B")
		checkEq(#InputManager.conflictsFor("B"), 2, "and a name finds the same pair")

		other:Destroy()
		checkEq(#InputManager.conflictsFor(Enum.KeyCode.B), 1, "destroying one leaves one")

		pressKey("B")
		checkEq(bind, 1, "the survivor still fires")
		releaseKey("B")

		first:Destroy()
		first:Destroy()
		checkNoError(function()
			first:Release()
		end, "a released handle is safe to poke twice")

		pressKey("B")
		checkEq(bind, 1, "and a destroyed bind is deaf")
		releaseKey("B")

		local heldBy = InputManager.bind({ Key = Enum.KeyCode.L, Mode = "hold" })
		pressKey("L")
		checkEq(heldBy:IsHeld(), true, "held, so a Release has something to do")
		heldBy:Release()
		checkEq(heldBy:IsHeld(), false, "released on demand")
		heldBy:Release()
		checkEq(InputManager.releaseAll("test") ~= nil, true, "releaseAll reports its reason")
		releaseKey("L")
	end)
end)

runSpec("a capture session returns a trigger, not a UserInput object", function()
	isolated(function()
		local payload = nil
		local session = InputManager.capture({})
		session.Done:Connect(function(result)
			payload = result
		end)

		checkEq(InputManager.capturing(), 1, "one session is live")

		pressKey("M")
		checkNe(payload, nil, "the press ended the session")
		checkEq(payload.input, Enum.KeyCode.M, "and hands back the Enum member")
		checkEq(payload.mods.Ctrl, false, "with the modifier set at the moment of the press")
		checkEq(InputManager.capturing(), 0, "the session is gone")

		-- The whole point: the picker writes this straight onto a live binding.
		local fired = 0
		local bind = InputManager.bind({ Key = Enum.KeyCode.N, Callback = function()
			fired += 1
		end })
		checkEq(bind:Set(payload.input, payload.mods), true, "the payload is settable")
		checkEq(bind:GetInput(), Enum.KeyCode.M, "and the bind now listens for M")
		checkEq(bind:GetLabel(), "M", "with no modifiers listed")
		pressKey("M")
		checkEq(fired, 1, "rebinding took effect immediately")
		releaseKey("M")
	end)
end)

runSpec("capture: Escape, delete, forbidden keys and a mouse button", function()
	isolated(function()
		local cancelled = false
		local first = InputManager.capture({ OnCancel = function()
			cancelled = true
		end })
		first.Done:Connect(function() end)
		pressKey("Escape")
		checkEq(cancelled, true, "Escape cancels rather than binding Escape")
		checkEq(InputManager.capturing(), 0, "and closes the session")

		local cleared = nil
		local second = InputManager.capture({})
		second.Done:Connect(function(result)
			cleared = result
		end)
		pressKey("Backspace")
		checkEq(cleared.cleared, true, "Backspace clears the bind")

		local kept = nil
		local third = InputManager.capture({ ClearOnDelete = false })
		third.Done:Connect(function(result)
			kept = result
		end)
		pressKey("Delete")
		checkEq(kept, nil, "a picker that keeps Delete on Delete does not finish")
		checkEq(InputManager.capturing(), 1, "it is still waiting")

		-- A click on the picker's own row arrives processed; a mouse bind must still be capturable.
		fireBegan(inputObject(nil, "MouseButton1"), true)
		checkEq(kept.input, Enum.UserInputType.MouseButton1, "the mouse button was captured")
		checkEq(InputManager.capturing(), 0, "and the session closed behind it")

		local fifth = InputManager.capture({})
		local done = false
		fifth.Done:Connect(function()
			done = true
		end)
		pressKey("Home")
		checkEq(done, false, "a key the UI needs to stay reachable is refused")
		checkEq(InputManager.capturing(), 1, "the session stays open waiting for a real key")
		fifth.Cancel()
		checkEq(done, true, "Cancel closes it")
		checkEq(InputManager.capturing(), 0, "and only one session is ever live")
	end)
end)

runSpec("a capture session that times out finishes on the clock", function()
	isolated(function()
		local result = nil
		local session = InputManager.capture({ Timeout = 2 })
		session.Done:Connect(function(payload)
			result = payload
		end)

		stepClock(1)
		checkEq(result, nil, "one second in, it is still listening")
		checkEq(InputManager.capturing(), 1, "and still registered")

		stepClock(1.5)
		checkNe(result, nil, "the timeout ended it")
		checkEq(result.timedOut, true, "reporting which")
		checkEq(result.cancelled, true, "a timeout is a cancel")
		checkEq(InputManager.capturing(), 0, "and the session left the list")
	end)
end)

runSpec("a second picker cannot steal the keyboard", function()
	isolated(function()
		local a = InputManager.capture({})
		local bDone = nil
		local b = InputManager.capture({})
		b.Done:Connect(function(payload)
			bDone = payload
		end)

		checkEq(InputManager.capturing(), 2, "both are registered")
		-- The first session is the live one; the second must fail rather than hang its picker.
		stepClock(0.05)
		checkNe(bDone, nil, "the second session finishes on its own, cancelled")
		checkEq(bDone.cancelled, true, "with the cancel payload")
		checkEq(bDone.blocked, "another-session", "and says why, so a picker can show a message")
		checkEq(InputManager.capturing(), 1, "leaving exactly the session that is listening")

		a.Cancel()
		checkEq(InputManager.capturing(), 0, "cancelling the first leaves none")
	end)
end)

runSpec("unload lets go of the engine", function()
	isolated(function()
		InputManager.bind({ Key = Enum.KeyCode.G, Callback = function()
			error("a bind fired after unload")
		end })
	end)

	checkEq(InputManager.connections() > 0, true, "the service listeners exist")
	InputManager.unload()
	checkEq(InputManager.connections(), 0, "unload disconnects them")
	checkEq(#InputManager.list(), 0, "and clears the registry")

	pressKey("G")
	releaseKey("G")
	checkNoError(function()
		InputManager.releaseAll("test")
	end, "releasing after unload is not an error")
end)
