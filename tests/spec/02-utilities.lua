--[[
	spec 02 — the utilities layer.

	Everything the shell and the components are built on. These are the modules where a wrong
	return type would propagate silently through twenty files, so each one is exercised against
	the behaviour the callers actually depend on.
]]

local Signal = assert(fluxRequire("Flux/Utilities/Signal"))
local Maid = assert(fluxRequire("Flux/Utilities/Maid"))
local Math = assert(fluxRequire("Flux/Utilities/Math"))
local Table = assert(fluxRequire("Flux/Utilities/Table"))
local String = assert(fluxRequire("Flux/Utilities/String"))
local Base64 = assert(fluxRequire("Flux/Utilities/Base64"))
local Guard = assert(fluxRequire("Flux/Utilities/Guard"))
local Instance = assert(fluxRequire("Flux/Utilities/Instance"))

runSpec("Signal", function()
	checkNoError(function()
		local received = {}
		local signal = Signal.new()
		signal:Connect(function(value)
			table.insert(received, "a" .. tostring(value))
		end)
		signal:Connect(function(value)
			table.insert(received, "b" .. tostring(value))
		end)

		checkEq(signal:GetConnectionCount(), 2, "two handlers attached")
		signal:Dispatch(1)
		checkEq(#received, 2, "every handler runs")
		checkEq(received[1], "a1", "handlers run in connection order")
	end, "dispatch reaches every handler")

	checkNoError(function()
		local calls = 0
		local signal = Signal.new()
		signal:Once(function()
			calls += 1
		end)
		signal:Dispatch()
		signal:Dispatch()
		checkEq(calls, 1, "Once runs a single time")
		checkEq(signal:GetConnectionCount(), 0, "Once cleans itself up")
	end, "Once")

	checkNoError(function()
		local seen = {}
		local signal = Signal.new()
		local first
		first = signal:Connect(function()
			table.insert(seen, "first")
			first:Disconnect()
		end)
		signal:Connect(function()
			table.insert(seen, "second")
		end)

		signal:Dispatch()
		signal:Dispatch()

		checkEq(table.concat(seen, ","), "first,second,second", "disconnecting mid-dispatch does not skip the next handler")
	end, "disconnect during dispatch")

	checkNoError(function()
		local signal = Signal.new()
		signal:Connect(function()
			error("handler blew up")
		end)
		local reached = false
		signal:Connect(function()
			reached = true
		end)

		signal:Dispatch()
		checkEq(reached, true, "a throwing handler does not stop the dispatch")
	end, "handler isolation")

	checkNoError(function()
		local signal = Signal.new()
		local connection = signal:Connect(function() end)
		connection:Disconnect()
		connection:Disconnect()
		checkEq(signal:GetConnectionCount(), 0, "double Disconnect is harmless")
		signal:Destroy()
		checkEq(signal:GetConnectionCount(), 0, "Destroy empties the signal")
	end, "teardown")
end)

runSpec("Maid", function()
	checkNoError(function()
		local order = {}
		local maid = Maid.new()
		maid:giveFunction(function()
			table.insert(order, "one")
		end)
		maid:giveFunction(function()
			table.insert(order, "two")
		end)
		maid:cleanup()

		checkEq(table.concat(order, ","), "two,one", "tasks release in reverse order")
		checkEq(#order, 2, "both ran")
	end, "LIFO cleanup")

	checkNoError(function()
		local maid = Maid.new()
		local frame = Instance.new("Frame")
		maid:giveInstance(frame)
		checkEq(#frame:GetChildren(), 0, "nothing yet")

		local screen = Instance.new("ScreenGui")
		frame.Parent = screen
		checkEq(#screen:GetChildren(), 1, "frame parented")

		maid:cleanup()
		checkEq(frame.Parent, nil, "given instance destroyed")
		checkEq(#screen:GetChildren(), 0, "screen emptied")
	end, "giveInstance destroys")

	checkNoError(function()
		local maid = Maid.new()
		local thread = coroutine.create(function()
			coroutine.yield()
		end)
		coroutine.resume(thread)
		checkEq(coroutine.status(thread), "suspended", "thread parked at a yield")

		maid:giveThread(thread)
		maid:cleanup()
		checkEq(coroutine.status(thread), "dead", "cleanup cancels a live thread")
	end, "giveThread cancels")

	checkNoError(function()
		local parent = Maid.new()
		local child = Maid.new()
		local childRan = false
		local parentRan = false

		parent:giveFunction(function()
			parentRan = true
		end)
		parent:chain(child)
		child:giveFunction(function()
			childRan = true
		end)

		parent:cleanup()
		checkEq(childRan, true, "chained maid cleans up with its parent")
		checkEq(parentRan, true, "parent still runs its own tasks")
	end, "chain")

	checkNoError(function()
		local maid = Maid.new()
		maid:giveTask(nil)
		maid:cleanup()
		maid:cleanup()
		checkEq(true, true, "cleanup is idempotent and tolerates a nil task")
	end, "idempotent cleanup")

	checkNoError(function()
		local maid = Maid.new()
		local ran = false
		maid:giveFunction(function()
			error("exploding task")
		end)
		maid:giveFunction(function()
			ran = true
		end)
		maid:cleanup()
		checkEq(ran, true, "a failing task does not abandon the rest of the maid")
	end, "failure isolation")
end)

runSpec("Math", function()
	checkNoError(function()
		checkEq(Math.clamp(5, 0, 10), 5, "inside range is untouched")
		checkEq(Math.clamp(-5, 0, 10), 0, "clamps low")
		checkEq(Math.clamp(50, 0, 10), 10, "clamps high")
		checkEq(Math.lerp(0, 100, 0.25), 25, "lerp")
		checkEq(Math.inverseLerp(50, 0, 100), 0.5, "inverseLerp")
		checkEq(Math.inverseLerp(50, 10, 10), 0, "inverseLerp cannot divide by a zero span")
		checkEq(Math.sign(-3), -1, "sign")
	end, "primitives")

	checkNoError(function()
		checkEq(Math.snap(0.33, 0, 0.25, 2), 0.25, "snaps down to the nearest step")
		checkEq(Math.snap(0.4, 0, 0.25, 2), 0.5, "snaps up past the midpoint")
		checkEq(Math.snap(-4, 0, 1, 0), 0, "clamps below the minimum")
		checkEq(Math.decimalsForStep(0.25), 2, "a quarter step needs two decimals")
		checkEq(Math.decimalsForStep(1), 0, "an integer step needs none")
		checkEq(Math.decimalsForStep(0.001), 3, "a thousandth needs three")
	end, "slider stepping")

	checkNoError(function()
		checkEq(Math.deltaAngle(350, 10), 20, "wraps across the seam the short way")
		checkEq(Math.deltaAngle(10, 350), -20, "and back again")
	end, "angle delta")

	checkNoError(function()
		checkEq(Math.fitScale(Vector2.new(900, 600), Vector2.new(1280, 720), 0.6), 1, "a small window is never enlarged")
		checkNear(Math.fitScale(Vector2.new(1600, 900), Vector2.new(1280, 720), 0.6), 0.8, 1e-9, "a large window shrinks to fit")
		checkEq(Math.fitScale(Vector2.new(4000, 4000), Vector2.new(1280, 720), 0.7), 0.7, "the minimum keeps it readable")
	end, "fitScale")
end)

runSpec("Table", function()
	checkNoError(function()
		local defaults = { Title = "Flux", Scale = 1 }
		local options = { Scale = 1.4 }
		local merged = Table.withDefaults(options, defaults)

		checkEq(merged.Title, "Flux", "default fills the gap")
		checkEq(merged.Scale, 1.4, "caller value wins")
		checkEq(defaults.Scale, 1, "defaults are not mutated")
		checkEq(options.Title, nil, "caller options are not mutated")
	end, "withDefaults is non-destructive")

	checkNoError(function()
		local source = { a = { b = { c = 1 } } }
		local copy = Table.deepCopy(source)
		copy.a.b.c = 99
		checkEq(source.a.b.c, 1, "deep copy is independent")
		checkEq(Table.copy(source).a == source.a, true, "shallow copy shares inner tables")
	end, "copy versus deepCopy")

	checkNoError(function()
		local list = {}
		Table.insertSorted(list, 5, function(a, b)
			return a < b
		end)
		Table.insertSorted(list, 1, function(a, b)
			return a < b
		end)
		Table.insertSorted(list, 3, function(a, b)
			return a < b
		end)
		checkEq(table.concat(list, ","), "1,3,5", "insertSorted keeps order")
		checkEq(Table.includes(list, 3), true, "includes finds a value")
		checkEq(Table.includes(list, 9), false, "includes rejects a missing value")
		checkEq(Table.indexOf({ "a", "b" }, function(v)
			return v == "b"
		end), 2, "indexOf returns the position")
		checkEq(Table.size({ x = 1, y = 2 }), 2, "size counts hash keys")
		checkEq(Table.reverse({ 1, 2, 3 })[1], 3, "reverse copies backwards")
	end, "list helpers")
end)

runSpec("String", function()
	checkNoError(function()
		checkEq(
			String.escape('<font color="red">x</font>'),
			'&lt;font color=&quot;red&quot;&gt;x&lt;/font&gt;',
			"markup is neutralised before it reaches RichText"
		)
		checkEq(String.escape("a & b"), "a &amp; b", "the ampersand goes first or the rest double-escapes")
		checkEq(String.highlight(String.escape("Zz Target"), "aim", "FF4F68"), "Zz Target", "a query that does not match leaves the text alone")
	end, "escape and highlight")

	checkNoError(function()
		-- Search is case-insensitive: typing "aim" into the search field must find "Aim Bot".
		local marked = String.highlight(String.escape("Target Player"), "target", "FF4F68")
		check(marked:find("<font color=", 1, true) ~= nil, "matching text is wrapped in a colour tag")
		check(marked:find("Player", 1, true) ~= nil, "the unmatched remainder survives")

		local lowered = String.highlight(String.escape("Target Player"), "PLAYER", "FF4F68")
		check(lowered:find("Target", 1, true) ~= nil, "the unqueried part survives")
		check(lowered ~= "Target Player", "a case-different query still marks")
	end, "highlight marks the match")

	checkNoError(function()
		checkEq(String.keyName(nil), "None", "an unbound keybind prints None")
		checkEq(String.keyName(Enum.KeyCode.RightControl), "R-Ctrl", "modifier names are shortened")
		checkEq(String.keyName(Enum.KeyCode.MouseButton2), "MB2", "mouse buttons are labelled")
		checkEq(String.keyName({ Name = "Q" }), "Q", "a keybind restored from a config table still labels")
	end, "keyName")

	checkNoError(function()
		local hex = String.colorToHex(Color3.fromRGB(255, 79, 104))
		checkEq(hex, "FF4F68", "colour formats as hex")
		local back = String.hexToColor("#" .. hex)
		check(back ~= nil, "hex parses back")
		checkEq(String.colorToHex(back), hex, "round trip is stable")
		checkEq(String.hexToColor("255,79,104") ~= nil, true, "component triples parse")
		checkEq(String.hexToColor("not-a-color"), nil, "garbage returns nil rather than a wrong colour")
	end, "hex colours")

	checkNoError(function()
		checkEq(String.truncate("abcdefghij", 7), "abcd...", "truncate adds an ellipsis")
		checkEq(String.truncate("abc", 7), "abc", "short text is untouched")
		checkEq(String.padStart("7", 3, "0"), "007", "padStart")
		checkEq(String.trim("  hi  "), "hi", "trim")
		checkEq(table.concat(String.split("a,b,,c", ","), "|"), "a|b||c", "split keeps empty fields")
	end, "formatting")

	checkNoError(function()
		local emoji = "Ready " .. string.char(240, 159, 166, 141) .. " now"
		local clean = String.stripUnsupported(emoji)
		check(clean:find("Ready", 1, true) ~= nil, "the text survives")
		checkEq(clean:find(string.char(240), 1, true), nil, "the astral character is dropped")
		checkEq(String.stripUnsupported("plain text"), "plain text", "plain text is returned unchanged")
	end, "stripUnsupported")
end)

runSpec("Base64", function()
	checkNoError(function()
		local samples = { "", "f", "fo", "foo", "foob", "Roblox Luau UI", string.char(0, 1, 2, 253, 254, 255) }
		for _, raw in ipairs(samples) do
			local encoded = Base64.encode(raw)
			local decoded = Base64.decode(encoded)
			checkEq(decoded, raw, "round trip survives " .. #raw .. " bytes")
		end
	end, "round trip")

	checkNoError(function()
		checkEq(Base64.decode("Zm9vYmFy"), "foobar", "decodes a known vector")
		checkEq(Base64.decode("Zm9vYmFy"), "foobar", "padding-less input still decodes")
		checkEq(Base64.decode("!!!!"), nil, "unknown bytes return nil instead of garbage")
	end, "known vectors")

	checkNoError(function()
		local wrapped = Base64.encode("foobar"):sub(1, 4) .. "\n" .. Base64.encode("foobar"):sub(5)
		checkEq(Base64.decode(wrapped), "foobar", "a newline inside the payload is skipped")
	end, "whitespace tolerance")
end)

runSpec("Guard", function()
	checkNoError(function()
		local frame = Instance.new("Frame")
		checkEq(Guard.set(frame, "BackgroundTransparency", 0.5), true, "a real property writes")
		checkEq(frame.BackgroundTransparency, 0.5, "and the value lands")
	end, "real properties")

	checkNoError(function()
		local frame = Instance.new("Frame")
		-- On an ordinary client an unknown write becomes a harmless expando, so the only
		-- reliable probe before writing is the read.
		checkEq(Guard.has(frame, "LetterSpacing"), false, "a property nobody wrote is reported absent")
		checkEq(Guard.set(frame, "LetterSpacing", 1.2), true, "an expando write does not raise")

		strictPropertyWrites = true
		local strict = Instance.new("Frame")
		checkEq(Guard.set(strict, "LetterSpacing", 1.2), false, "on a client that refuses it, set reports failure")
		checkEq(Guard.has(strict, "LetterSpacing"), false, "and the widget is left unmarked rather than half-configured")
		checkEq(Guard.set(strict, "BackgroundTransparency", 0.25), true, "real properties still write")
		strictPropertyWrites = false
	end, "optional properties degrade")

	checkNoError(function()
		local ok, value = Guard.try(function()
			error("construction failed")
		end)
		checkEq(ok, false, "try reports failure")
		local ok2, text = Guard.try(function()
			return "fine"
		end)
		checkEq(ok2, true, "try passes success through")
		checkEq(text, "fine", "try passes the value through")
	end, "try")

	checkNoError(function()
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(200, 100)
		frame.Position = UDim2.fromOffset(50, 50)
		local centre = Guard.absoluteCenter(frame)
		checkEq(centre.X, 150, "centre X derives without AbsoluteCenter")
		checkEq(centre.Y, 100, "centre Y derives without AbsoluteCenter")
	end, "absoluteCenter")

	checkNoError(function()
		local a = Guard.service("RunService")
		local b = Guard.service("RunService")
		checkEq(a == b, true, "services are interned")
	end, "service")
end)

runSpec("Instance factory", function()
	checkNoError(function()
		Instance.resetCount()
		local frame = Instance.new("Frame", nil, { Name = "Canvas", BackgroundTransparency = 1 })
		checkEq(frame.Name, "Canvas", "properties apply")
		checkEq(frame.BackgroundTransparency, 1, "including numeric ones")
		checkEq(Instance.count(), 1, "the counter tracks exactly one instance")

		Instance.corner(frame, UDim.new(0, 8))
		checkEq(frame.Name, "Canvas", "adding a UI component does not clobber the parent name")
		checkEq(#frame:GetChildren(), 1, "corner parented")
		checkEq(frame:GetChildren()[1].ClassName, "UICorner", "correct class")
		checkEq(Instance.count(), 2, "the helper counts too")
	end, "new plus helpers")

	checkNoError(function()
		local parent = Instance.new("Frame")
		Instance.corner(parent, UDim.new(0, 4))
		local label = Instance.new("TextLabel", parent)
		label.Name = "Title"

		Instance.clear(parent)
		local survivors = {}
		for _, child in ipairs(parent:GetChildren()) do
			table.insert(survivors, child.ClassName)
		end

		checkEq(#survivors, 1, "clear leaves exactly one child")
		checkEq(survivors[1], "UICorner", "layout helpers survive a clear, so the panel keeps its shape")
	end, "clear spares UI components")

	checkNoError(function()
		local panel = Instance.panel(nil, "Section", { Size = UDim2.fromOffset(300, 200) })
		checkEq(panel.ClassName, "Frame", "panel is a frame")
		checkEq(panel.Name, "Section", "named")
		checkEq(panel.ClipsDescendants, true, "clipping is on, otherwise a corner would not round anything")

		local cornerFound = nil
		for _, child in ipairs(panel:GetChildren()) do
			if child.ClassName == "UICorner" then
				cornerFound = child
			end
		end
		check(cornerFound ~= nil, "panel carries its own corner")
	end, "panel clips and rounds")

	checkNoError(function()
		local host = Instance.new("Frame")
		local list = Instance.list(host, { Sort = "Layout", Padding = UDim.new(0, 6) })
		checkEq(list.ClassName, "UIListLayout", "list helper builds the right class")

		local grid = Instance.grid(Instance.new("Frame"), { CellSize = UDim2.new(0, 100, 0, 40) })
		checkEq(grid.ClassName, "UIGridLayout", "grid helper builds the right class")

		local pad = Instance.pad(Instance.new("Frame"), { Top = UDim.new(0, 8) })
		checkEq(pad.ClassName, "UIPadding", "pad helper builds the right class")
	end, "layout helpers")
end)
