--[[
	Systems/IconManager — name -> paintable glyph, with the fallback chain made explicit.

	Routes, tried in this order:
	  1. an asset id the host registered with Icons.configure{ Assets = … } (the path for a
	     client that uploaded assets/icons/*.png to Roblox);
	  2. the embedded atlas: base64 -> writefile -> getcustomasset. This is the route that
	     works in a client with a file API and no network, and it is decoded per glyph on
	     first use, so a menu that shows nine icons never decodes forty-nine;
	  3. Assets/GlyphFallback primitives;
	  4. nothing (the icon slot collapses and the label shifts left).

	`rbxthumb://` is deliberately absent: it only resolves in Studio, so a library consumed
	from a client would paint blank squares.
]]

local Instance = require("Flux/Utilities/Instance")
local Base64 = require("Flux/Utilities/Base64")
local IconAtlas = require("Flux/Assets/IconAtlas")
local GlyphFallback = require("Flux/Assets/GlyphFallback")

local Icons = {}

local resolved: {[string]: string} = {}
local routes: {[string]: string} = {}
local uploaded: {[string]: string} = {}
local aliases: {[string]: string} = {}
local failures: {[string]: string} = {}

local folder = "FluxHub/Icons"

-- Set by Icons.configure{ Mode = "fallback" } to keep a client off the file api even when it
-- has one. It is a switch, not a report; what is actually happening is `Icons.route`.
local forced: string? = nil

--- The glyph mode() reports on. One stable name answers "is this client painting real PNGs or
--- primitive dots?" without having to aggregate every glyph that happens to be on screen.
local MODE_PROBE = "search"

-- Atlas keys are camelCase. Callers type "gear", "Gear" or "chevrondown" in a config, so a
-- lowercased index is built once at load rather than every lookup scanning forty-nine names.
local byLower: {[string]: string} = {}
for glyph in pairs(IconAtlas.glyphs) do
	byLower[tostring(glyph):lower()] = glyph
end

--- Map whatever the caller wrote to a key the registry actually holds, or nil.
--- Aliases resolve first, because an alias may point at a glyph this name is not.
--- Declared before every user below: a `local function` is invisible to code above it.
local function canonical(name: string?): string?
	if name == nil or name == "" then
		return nil
	end

	local aliased = aliases[name]
	if aliased ~= nil then
		name = aliased
	end

	if IconAtlas.glyphs[name] ~= nil or uploaded[name] ~= nil then
		return name
	end

	-- A raw id passes straight through, so Icons.attach(parent, "rbxassetid://123") works.
	if name:find("^rbxassetid://") or name:find("^rbxasset://") or name:find("^http") then
		return name
	end

	return byLower[name:lower()]
end

function Icons.names(): {string}
	local out = {}
	for name in pairs(IconAtlas.glyphs) do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function Icons.has(name: string): boolean
	if name == nil then
		return false
	end
	return canonical(name) ~= nil
end

function Icons.alias(pairs_: {[string]: string})
	for from, to in pairs(pairs_) do
		aliases[from] = to
	end
end

--- Register real uploaded asset ids, or change the cache folder / force a route.
function Icons.configure(options: { Folder: string?, Assets: {[string]: string}?, Mode: string? })
	options = options or {}

	if type(options.Folder) == "string" then
		folder = options.Folder
	end

	if type(options.Assets) == "table" then
		for name, asset in pairs(options.Assets) do
			local key = tostring(name)
			uploaded[key] = tostring(asset)
			resolved[key] = uploaded[key]
			routes[key] = "uploaded"
			byLower[key:lower()] = key
		end
	end

	if options.Mode ~= nil then
		if options.Mode == "fallback" then
			forced = "fallback"
		else
			forced = nil
		end
	end
end

--- Decode and one-time cache a glyph. Returns the content string, or nil plus the reason.
local function materialise(name: string): (string?, string?)
	local encoded = IconAtlas.glyphs[name]
	if encoded == nil then
		return nil, "no such glyph"
	end

	local bytes = Base64.decode(encoded)
	if bytes == nil or #bytes == 0 then
		return nil, "atlas decode failed"
	end

	local path = folder .. "/" .. name .. ".png"

	local ok, content = pcall(function()
		if not isfile(path) then
			makefolder(folder)
			writefile(path, bytes)
		end
		return getcustomasset(path)
	end)

	if not ok then
		return nil, "client has no file api"
	end

	if type(content) ~= "string" or content == "" then
		return nil, "getcustomasset returned nothing"
	end

	return content, nil
end

--- Resolve a name to something an ImageLabel can display, or nil to mean "use primitives".
function Icons.content(name: string): string?
	local key = canonical(name)
	if key == nil then
		return nil
	end

	local cached = resolved[key]
	if cached ~= nil then
		return cached
	end

	-- An id that was cached as unresolvable must not be re-decoded on every frame the widget
	-- is visible, so failures are remembered in `routes`/`failures` rather than retried.
	if routes[key] == "fallback" then
		return nil
	end

	local direct = uploaded[key]
	if direct ~= nil then
		resolved[key] = direct
		routes[key] = "uploaded"
		return direct
	end

	if IconAtlas.glyphs[key] == nil then
		-- A raw id is its own content, so attach(parent, "rbxassetid://123") paints the caller's
		-- image instead of falling through to the primitive dot.
		if key:find("^rbxassetid://") or key:find("^rbxasset://") or key:find("^http") then
			resolved[key] = key
			routes[key] = "uploaded"
			return key
		end
		return nil
	end

	if forced == "fallback" then
		routes[key] = "fallback"
		failures[key] = "the file api was turned off by configuration"
		return nil
	end

	local content, reason = materialise(key)
	if content ~= nil then
		resolved[key] = content
		routes[key] = "file"
		return content
	end

	failures[key] = reason
	routes[key] = "fallback"
	return nil
end

--- Which route served this glyph: "uploaded", "file", "fallback", or nil for a name the
--- registry does not hold. Resolving is lazy, so asking costs one decode the first time.
function Icons.route(name: string): string?
	local key = canonical(name)
	if key == nil then
		return nil
	end

	if routes[key] == nil then
		Icons.content(name)
	end

	return routes[key]
end

--- Which route is serving the menu overall. Reported so a reduced icon set is visible in
--- diagnostics instead of being mistaken for a broken atlas.
function Icons.mode(): string
	return Icons.route(MODE_PROBE) or "probe"
end

function Icons.failureReason(name: string): string?
	local key = canonical(name)
	if key == nil then
		return nil
	end
	return failures[key]
end

local handle = {}
handle.__index = handle

function handle.setColor(self: any, color: Color3)
	if self.kind == "image" then
		self.instance.ImageColor3 = color
	else
		-- Primitive children carry the colour directly; there is no tint to apply.
		for _, child in ipairs(self.instance:GetChildren()) do
			if child:IsA("Frame") then
				child.BackgroundColor3 = color
			end
		end
	end
end

--- Multiplies the size the icon was created at. Scaling against the parent instead would make
--- a 16 px glyph in a 30 px row jump to 15 px the first time anything called this.
function handle.setScale(self: any, factor: number)
	local base = self.baseSize
	self.instance.Size = UDim2.new(
		base.X.Scale * factor,
		base.X.Offset * factor,
		base.Y.Scale * factor,
		base.Y.Offset * factor
	)
end

--- Attach a glyph. Returns a handle with `instance`, `kind`, `setColor`, `setScale`.
function Icons.attach(parent: any, name: string, options: {
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Color: Color3?,
	LayoutOrder: number?,
	Name: string?,
	Transparency: number?,
}): any
	options = options or {}
	local color = options.Color or Color3.fromRGB(231, 231, 237)

	local key = canonical(name)
	local content = Icons.content(name)

	if content ~= nil then
		local image = Instance.new("ImageLabel", parent, {
			Name = options.Name or ("Icon_" .. tostring(name)),
			Image = content,
			BackgroundTransparency = 1,
			ImageColor3 = color,
			ImageTransparency = options.Transparency or 0,
			Size = options.Size or UDim2.fromOffset(16, 16),
			Position = options.Position or UDim2.new(),
			AnchorPoint = options.AnchorPoint or Vector2.new(0, 0),
			LayoutOrder = options.LayoutOrder or 0,
		})

		return setmetatable({
			instance = image,
			kind = "image",
			name = name,
			baseSize = image.Size,
		}, handle)
	end

	local container = GlyphFallback.draw(parent, key or "dot", color)
	container.Name = options.Name or ("Icon_" .. tostring(name))
	if options.Size ~= nil then
		container.Size = options.Size
	end
	if options.Position ~= nil then
		container.Position = options.Position
	end
	if options.AnchorPoint ~= nil then
		container.AnchorPoint = options.AnchorPoint
	end
	container.LayoutOrder = options.LayoutOrder or 0

	return setmetatable({
		instance = container,
		kind = "fallback",
		name = name,
		baseSize = container.Size,
	}, handle)
end

return Icons
