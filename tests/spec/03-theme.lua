--[[
	spec 03 — ThemeManager.

	A theme swap is the one operation that touches every widget at once, so this file cares as
	much about the binding list's bookkeeping as about the colours that land on screen: a bind
	that cannot be removed is a repaint that walks destroyed instances forever.
]]

local ThemeManager = assert(fluxRequire("Flux/Systems/ThemeManager"))
local Instance = assert(fluxRequire("Flux/Utilities/Instance"))
local String = assert(fluxRequire("Flux/Utilities/String"))

local function hex(value: any): string
	return String.colorToHex(value)
end

runSpec("tokens", function()
	checkEq(ThemeManager.name() ~= nil, true, "a preset is loaded at require time")
	checkEq(hex(ThemeManager.color("Accent")), "FF4F68", "the coral accent matches the design")
	checkEq(ThemeManager.metric("HeaderHeight"), 72, "header height is a token, not a literal")
	checkEq(ThemeManager.metric("NavHeight"), 52, "nav height too")
	checkEq(ThemeManager.color("NoSuchRole"), nil, "an unknown role returns nil rather than a placeholder colour")
	checkEq(ThemeManager.font("Body") ~= nil, true, "every documented font role resolves")
end)

runSpec("binding and repaint", function()
	checkNoError(function()
		local host = Instance.new("ScreenGui")
		local row = Instance.new("Frame", host)
		local before = ThemeManager.bindingCount()

		local unbind = ThemeManager.bind(row, "BackgroundColor3", "Accent")
		checkEq(ThemeManager.bindingCount(), before + 1, "bind registers one entry")
		checkEq(hex(row.BackgroundColor3), "FF4F68", "bind paints immediately, not on the next theme change")

		ThemeManager.set({ Accent = Color3.fromRGB(0, 200, 90) })
		checkEq(hex(row.BackgroundColor3), "00C85A", "a live swap restyles an already-built widget")

		unbind()
		checkEq(ThemeManager.bindingCount(), before, "unbind removes the entry")

		ThemeManager.set({ Accent = "FF4F68" })
		checkEq(hex(row.BackgroundColor3), "00C85A", "after unbind the widget stops following the theme")
	end, "bind, repaint, unbind")

	checkNoError(function()
		local host = Instance.new("ScreenGui")
		local orphan = Instance.new("Frame", host)
		local before = ThemeManager.bindingCount()

		ThemeManager.bind(orphan, "BackgroundColor3", "Accent")
		checkEq(ThemeManager.bindingCount(), before + 1, "bound while parented")

		orphan:Destroy()
		ThemeManager.set({ Accent = Color3.fromRGB(10, 20, 30) })
		checkEq(ThemeManager.bindingCount(), before, "repaint prunes a binding whose instance is gone")
	end, "the binding list cannot grow without bound")

	checkNoError(function()
		local host = Instance.new("ScreenGui")
		local frame = Instance.new("Frame", host)
		local calls = 0

		local unbind = ThemeManager.bindFn(function(tokens)
			calls += 1
			frame.Position = UDim2.fromOffset(tokens.metrics.GroupPadding, 0)
		end)

		checkEq(calls, 1, "bindFn runs once immediately")
		ThemeManager.set({ GroupPadding = 24 })
		checkEq(calls, 2, "and again on a theme change")
		checkEq(frame.Position.X.Offset, 24, "the callback can read the live metrics table")

		unbind()
		ThemeManager.set({ GroupPadding = 8 })
		checkEq(calls, 2, "unbind stops it")
	end, "bindFn")

	checkNoError(function()
		local warned = 0
		local originalWarn = warn
		warn = function()
			warned += 1
		end

		local unbind = ThemeManager.bind(Instance.new("Frame", Instance.new("ScreenGui")), "BackgroundColor3", "NotAColor")
		checkEq(warned, 1, "a typo'd role is a loud caller error, not a silent no-op")
		unbind()

		warn = originalWarn
	end, "unknown role names warn")

	checkNoError(function()
		checkEq(ThemeManager.use("Dark"), true, "the base preset switches")
		checkEq(ThemeManager.use("NotARealPreset"), false, "an unknown preset reports failure")
	end, "presets")

	checkNoError(function()
		-- Assets/Theme builds every colour preset from Dark's metric table, so a preset carries
		-- spacing the host may have customised away. The override layer is what makes a colour
		-- change a colour change, which is the promise the preset docs make.
		ThemeManager.use("Dark")
		ThemeManager.set({ GroupPadding = 33, RadiusPanel = 4 })
		checkEq(ThemeManager.metric("GroupPadding"), 33, "a customised metric applies")

		ThemeManager.use("Purple")
		checkEq(ThemeManager.metric("GroupPadding"), 33, "and survives a preset switch")
		checkEq(ThemeManager.metric("RadiusPanel"), 4, "for every pinned metric")
		checkEq(hex(ThemeManager.color("Accent")), "9660FF", "while the preset's own colours do move")

		-- A snapshot is the whole look, so restoring one drops the pins along with it.
		ThemeManager.forgetOverrides()
		ThemeManager.use("Dark")
		checkEq(ThemeManager.metric("GroupPadding"), 16, "forgetOverrides returns to the preset")
	end, "pinned overrides survive a preset switch")

	checkNoError(function()
		ThemeManager.forgetOverrides()
		ThemeManager.use("Dark")
	end, "leave the default preset loaded")
end)

runSpec("snapshot round trip", function()
	checkNoError(function()
		ThemeManager.use("Dark")
		ThemeManager.set({ Accent = Color3.fromRGB(255, 79, 104) })

		local snapshot = ThemeManager.snapshot()
		checkEq(type(snapshot.colors) == "table", true, "a snapshot carries colours")
		checkEq(type(snapshot.metrics) == "table", true, "and metrics")

		-- A config written by a person, then read back: the stored triple must be 0-255, since
		-- exporting Color3.R and restoring it through fromRGB turns every accent near-black.
		checkEq(snapshot.colors.Accent[1], 255, "exported as 0-255")
		checkEq(snapshot.colors.Accent[2], 79, "exported as 0-255")
		checkEq(snapshot.colors.Accent[3], 104, "exported as 0-255")

		ThemeManager.set({ Accent = Color3.fromRGB(1, 2, 3) })
		checkEq(hex(ThemeManager.color("Accent")), "010203", "clobbered for the test")

		checkEq(ThemeManager.restore(snapshot), true, "restore accepts the snapshot")
		checkEq(hex(ThemeManager.color("Accent")), "FF4F68", "and the accent survives the round trip")
	end, "snapshot / restore")

	checkNoError(function()
		local unbind = ThemeManager.bind(Instance.new("Frame", Instance.new("ScreenGui")), "BackgroundColor3", "Background")
		checkEq(ThemeManager.restore(nil), false, "restore rejects a missing snapshot")
		unbind()
	end, "restore guards its input")

	checkNoError(function()
		local live = Color3.fromRGB(12, 240, 48)
		checkEq(hex(ThemeManager.coerceColor(live)), "0CF030", "a live Color3 passes through")
		checkEq(hex(ThemeManager.coerceColor("#0CF030")), "0CF030", "a hex string with a hash parses")
		checkEq(hex(ThemeManager.coerceColor("0CF030")), "0CF030", "and without the hash")
		checkEq(hex(ThemeManager.coerceColor({ 12, 240, 48 })), "0CF030", "a triple parses")
		checkEq(ThemeManager.coerceColor("nonsense"), nil, "garbage is rejected")
		checkEq(ThemeManager.coerceColor(nil), nil, "nil is rejected")

		local font = ThemeManager.coerceFont("GothamMedium")
		check(font ~= nil, "a font name resolves")
		checkEq(font.Name, "GothamMedium", "to the right member")
		checkEq(ThemeManager.coerceFont({ Name = "Gotham" }).Name, "Gotham", "and a stored enum table resolves too")
	end, "value coercion")

	checkNoError(function()
		-- set() must not quietly drop a colour just because type(Color3) is "userdata" on the
		-- engine: that is the difference between a theme command working and doing nothing.
		local host = Instance.new("ScreenGui")
		local frame = Instance.new("Frame", host)
		ThemeManager.bind(frame, "BackgroundColor3", "BrandPrimary")
		ThemeManager.set({ BrandPrimary = Color3.fromRGB(183, 106, 255) })
		checkEq(hex(frame.BackgroundColor3), "B76AFF", "a Color3 argument lands on the widget")
	end, "Color3 arguments are honoured")
end)

runSpec("change signal", function()
	checkNoError(function()
		local fired = 0
		local connection = ThemeManager.Changed:Connect(function(tokens)
			checkEq(tokens.colors ~= nil, true, "the signal hands over the live table")
			fired += 1
		end)

		ThemeManager.set({ Accent = Color3.fromRGB(255, 79, 104) })
		ThemeManager.use("Dark")
		connection:Disconnect()
		ThemeManager.set({ Accent = Color3.fromRGB(1, 1, 1) })

		checkEq(fired, 2, "Changed fires once per repaint, not per token")
	end, "Changed")
end)

runSpec("the module registry interns what it loads", function()
	checkEq(fluxRequire("Flux/Systems/ThemeManager") == ThemeManager, true, "requiring twice hands back the same table")
	checkEq(fluxRequire("Flux/Utilities/Instance") == Instance, true, "across modules too")
	checkEq(type(ThemeManager.Changed.Dispatch), "function", "Changed is a library Signal, not an engine event")

	checkError(function()
		fluxRequire("Flux/Systems/NoSuchThing")
	end, "unknown module", "a mistyped path fails loudly instead of returning nil")
end)
