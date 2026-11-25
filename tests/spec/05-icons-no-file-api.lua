--[[
	spec 05 — IconManager on a client with NO file api.

	`fileApiOn = false` must be the first statement of this file: IconManager caches the route
	it took per glyph, so any earlier lookup would hand it a resolved PNG from the stub. This is
	also why each spec file gets its own process — a client either has writefile or it does not,
	and a test that mixed both would describe a machine that cannot exist.

	The contract here is that the menu still appears. Missing executor functions must degrade
	the icon set, never the product.
]]

fileApiOn = false

local IconManager = assert(fluxRequire("Flux/Systems/IconManager"))
local Instance = assert(fluxRequire("Flux/Utilities/Instance"))
local String = assert(fluxRequire("Flux/Utilities/String"))

local function hex(value: any): string
	return String.colorToHex(value)
end

runSpec("the file api really is absent", function()
	local ok = pcall(isfile, "anything")
	checkEq(ok, false, "isfile raises, as it does on a client without the extension")
end)

runSpec("resolution falls back without raising", function()
	checkNoError(function()
		checkEq(IconManager.content("target"), nil, "a glyph cannot be materialised")
		checkEq(IconManager.route("target"), "fallback", "and the route reports the fallback honestly")
		checkEq(IconManager.mode(), "fallback", "so diagnostics can say 'this client gets primitive icons'")
		check(type(IconManager.failureReason("target")) == "string", "the reason is recorded for diagnostics")
	end, "content on a client without writefile")

	checkNoError(function()
		checkEq(IconManager.content("gear"), nil, "a diagonal glyph falls back too")
		checkEq(IconManager.has("gear"), true, "but the name is still registered — fallback is not 'missing'")
	end, "no name becomes unknown just because the client is poor")

	checkNoError(function()
		-- A failed glyph must be remembered, not retried: an icon row re-rendered every frame
		-- would otherwise re-attempt the write and spam the client's pcall path.
		local first = IconManager.content("sliders")
		local second = IconManager.content("sliders")
		checkEq(first, nil, "still nothing")
		checkEq(second, nil, "and asking twice does not raise")
	end, "failures are cached")
end)

runSpec("attach still paints something", function()
	local parent = Instance.new("Frame")
	local handle = IconManager.attach(parent, "target", {
		Size = UDim2.fromOffset(20, 20),
		Color = Color3.fromRGB(255, 79, 104),
	})

	checkEq(handle.kind, "fallback", "the handle says which route built it")
	checkEq(handle.instance.ClassName, "Frame", "a container frame, not an ImageLabel")
	checkEq(handle.instance.Size.X.Offset, 20, "options.Size is honoured on the fallback too")
	check(#handle.instance:GetChildren() > 0, "primitive shapes are drawn inside it")

	checkNoError(function()
		handle:setColor(Color3.fromRGB(0, 200, 90))
		local child = handle.instance:GetChildren()[1]
		checkEq(hex(child.BackgroundColor3), "00C85A", "setColor tints the primitive children")
	end, "the fallback handle is re-colourable")

	checkNoError(function()
		handle:setScale(2)
		checkEq(handle.instance.Size.X.Offset, 40, "and scalable")
	end, "the fallback handle is scalable")
end)

runSpec("a diagonal glyph gets the neutral shape, not nothing", function()
	local parent = Instance.new("Frame")
	local handle = IconManager.attach(parent, "close", { Size = UDim2.fromOffset(16, 16) })

	checkEq(handle.kind, "fallback", "close has no primitive form")
	check(#handle.instance:GetChildren() > 0, "so the neutral dot is drawn instead of an empty slot")
	checkEq(handle.instance:GetChildren()[1].Name, "Disc", "the dot is the primitive disc")
end)

runSpec("uploaded ids still work with no file api", function()
	-- A host that uploaded real assets needs neither writefile nor getcustomasset; the ids are
	-- content on their own. Forgetting this would deny PNG icons to exactly the clients that
	-- bothered to prepare them.
	IconManager.configure({ Assets = { gear = "rbxassetid://5555" } })

	local parent = Instance.new("Frame")
	local handle = IconManager.attach(parent, "gear")
	checkEq(handle.kind, "image", "the uploaded route survives the missing file api")
	checkEq(handle.instance.Image, "rbxassetid://5555", "and paints the caller's asset")
end)
