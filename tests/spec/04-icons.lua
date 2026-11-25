--[[
	spec 04 — IconManager on a client that HAS the file api.

	The embedded atlas is what makes the library work offline: base64 -> writefile ->
	getcustomasset. `rbxthumb://` is deliberately absent from every route because it only
	resolves in Studio, so a spec asserting it here would be asserting a broken product.

	This file must run in its own process. IconManager's caches are module singletons, and the
	next spec models a client with no file api at all — a scenario no real machine is ever in
	if the two share a table.
]]

local IconManager = assert(fluxRequire("Flux/Systems/IconManager"))
local GlyphFallback = assert(fluxRequire("Flux/Assets/GlyphFallback"))
local IconAtlas = assert(fluxRequire("Flux/Assets/IconAtlas"))
local Instance = assert(fluxRequire("Flux/Utilities/Instance"))
local String = assert(fluxRequire("Flux/Utilities/String"))

local function hex(value: any): string
	return String.colorToHex(value)
end

runSpec("the atlas is embedded and indexable", function()
	local names = IconManager.names()
	check(#names > 40, "the atlas carries a usable set", "got " .. tostring(#names))
	checkEq(table.find(names, "gear") ~= nil, true, "gear is registered")
	checkEq(table.find(names, "search") ~= nil, true, "and search")

	local sorted = true
	for index = 2, #names do
		if names[index - 1] > names[index] then
			sorted = false
		end
	end
	check(sorted, "names come back sorted for docs and diagnostics")

	check(type(IconAtlas.glyphs) == "table", "the glyph table ships inside the bundle")
	check(type(IconAtlas.glyphs.gear) == "string" and #IconAtlas.glyphs.gear > 100, "each entry is an embedded payload", "gear is " .. tostring(#tostring(IconAtlas.glyphs.gear)) .. " chars")
end)

runSpec("name resolution", function()
	checkEq(IconManager.has("gear"), true, "an exact key resolves")
	checkEq(IconManager.has("Gear"), true, "a capitalised config value resolves to the same glyph")
	checkEq(IconManager.has("GEAR"), true, "case is ignored entirely")
	checkEq(IconManager.has(nil), false, "a missing icon is answered honestly")
	checkEq(IconManager.has("definitely_not_real"), false, "and so is a typo")
end)

runSpec("the file-api route", function()
	checkNoError(function()
		local content = IconManager.content("gear")
		checkEq(type(content) == "string", true, "the glyph materialises")
		check(content:find("gear%.png") ~= nil, "through a custom asset path", tostring(content))
		checkEq(isfile("FluxHub/Icons/gear.png"), true, "the PNG is written to the cache folder once")
		checkEq(IconManager.route("gear"), "file", "and the route is reported as the file api")
		checkEq(IconManager.mode(), "file", "so mode() can answer 'real PNGs or primitive dots?'")
	end, "materialise + cache")

	checkNoError(function()
		-- Lazy decoding is a load-time promise: a menu that shows nine icons must not pay for
		-- forty-nine base64 blobs while the host is still starting. An untouched glyph has no
		-- file on disk, which is what `already decoded` looks like from outside.
		checkEq(isfile("FluxHub/Icons/bell.png"), false, "a glyph nobody asked for is never decoded")
		checkEq(IconManager.route("dot"), "file", "asking for one glyph resolves only that glyph")
		checkEq(isfile("FluxHub/Icons/dot.png"), true, "and writes only that one")
	end, "resolve is lazy")

	checkNoError(function()
		checkEq(IconManager.content("definitely_not_real"), nil, "an unknown name yields nothing rather than a blank square")
	end, "unknown names")
end)

runSpec("uploaded ids win over the atlas", function()
	IconManager.configure({ Assets = { gear = "rbxassetid://9999" } })
	checkEq(IconManager.content("gear"), "rbxassetid://9999", "a registered asset id is used verbatim")
	checkEq(IconManager.route("gear"), "uploaded", "and the route says so")

	-- mode() probes a fixed glyph, so an override that does not touch it must not change it.
	checkEq(IconManager.mode(), "file", "the overall mode is stable unless the probe glyph moves")

	IconManager.alias({ settings = "gear" })
	checkEq(IconManager.has("settings"), true, "an alias resolves through to the registry")
	checkEq(IconManager.content("settings"), "rbxassetid://9999", "and inherits the aliased glyph's asset")
end)

runSpec("raw ids pass through", function()
	checkEq(IconManager.content("rbxassetid://123"), "rbxassetid://123", "so a caller can hand attach() an id directly")
	checkEq(IconManager.content("rbxasset://textures/ui/Loader/Loading.gif"), "rbxasset://textures/ui/Loader/Loading.gif", "rbxasset works too")
	checkEq(IconManager.route("rbxassetid://123"), "uploaded", "reported as given, not as a fallback")
end)

runSpec("attach builds a real image", function()
	local parent = Instance.new("Frame")
	local handle = IconManager.attach(parent, "gear", { Color = Color3.fromRGB(255, 0, 0) })

	checkEq(handle.kind, "image", "the atlas route paints an image, not primitives")
	checkEq(handle.instance.ClassName, "ImageLabel", "as an ImageLabel")
	checkEq(handle.instance.BackgroundTransparency, 1, "with no plate behind the glyph")
	checkEq(hex(handle.instance.ImageColor3), "FF0000", "honouring the requested colour")

	handle:setColor(Color3.fromRGB(0, 0, 255))
	checkEq(hex(handle.instance.ImageColor3), "0000FF", "setColor re-tints the image")

	checkEq(handle.instance.Size.X.Offset, 16, "created at the requested size")
	handle:setScale(2)
	checkEq(handle.instance.Size.X.Offset, 32, "setScale multiplies the size it was built at")
	handle:setScale(0.5)
	checkEq(handle.instance.Size.X.Offset, 8, "and a fraction shrinks — scaling against the parent would clamp at 1")

	checkEq(IconManager.failureReason("gear"), nil, "a glyph that resolved reports no failure")
end)

runSpec("configuration", function()
	checkNoError(function()
		IconManager.configure({ Folder = "FluxHub/Custom" })
		local content = IconManager.content("plus")
		-- The exact scheme an executor hands back for a custom asset is its own business
		-- (rbxasset://, rbxcustom://, a raw path); what the library owes the caller is that the
		-- path it wrote is the one it returned.
		checkEq(type(content) == "string", true, "the custom folder resolves")
		check(content:find("FluxHub/Custom/plus.png", 1, true) ~= nil, "and names the configured folder", tostring(content))
		checkEq(isfile("FluxHub/Custom/plus.png"), true, "with the PNG landing there")
	end, "a custom folder")

	checkNoError(function()
		IconManager.configure({ Mode = "fallback" })
		checkEq(IconManager.content("close"), nil, "forcing fallback skips the file api even though it exists")
		checkEq(IconManager.failureReason("close"), "the file api was turned off by configuration", "with the reason stated")
		checkEq(IconManager.route("close"), "fallback", "and the route reported")
	end, "the fallback switch is available for hosts that want primitives")
end)

runSpec("the primitive library is honest about its limits", function()
	checkEq(GlyphFallback.isExpressible("target"), true, "a grid-composable glyph has a primitive form")
	checkEq(GlyphFallback.isExpressible("gear"), false, "a diagonal glyph does not")
	checkEq(GlyphFallback.isExpressible("notReal"), false, "and an unknown name is not 'expressible' either")

	local parent = Instance.new("Frame")
	local container = GlyphFallback.draw(parent, "target", Color3.fromRGB(255, 255, 255))
	checkEq(container.ClassName, "Frame", "primitives draw into a container frame")
	check(#container:GetChildren() > 0, "and compose from child shapes")
end)
