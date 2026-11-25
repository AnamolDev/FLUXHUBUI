--[[
	Assets/GlyphFallback — primitive shapes for clients with no file API.

	The atlas path needs `writefile` + `getcustomasset`. When either is missing an icon
	cannot be painted at all, so this module composes the glyphs that are expressible as
	axis-aligned frames and circles inside a 24-unit container.

	Two limits are real, not laziness: a GUI frame cannot rotate, and there is no vector
	surface outside `Drawing`. So diagonal glyphs (chevron, check, close, moon) have no
	primitive form and resolve to `dot`; `IconManager.mode()` reports the reduced set
	instead of pretending the menu is fully iconned.
]]

local Instance = require("Flux/Utilities/Instance")

local GlyphFallback = {}

local GRID = 24

--- Everything is placed in the container's own 24-unit space, so a primitive never has to
--- convert between a nested frame's size and the icon's size.
local function bar(parent: any, color: Color3, x: number, y: number, w: number, h: number, round: number?)
	local frame = Instance.new("Frame", parent, {
		Name = "Bar",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Position = UDim2.fromScale(x / GRID, y / GRID),
		Size = UDim2.fromScale(w / GRID, h / GRID),
	})

	if round ~= nil and round > 0 then
		Instance.corner(frame, UDim.new(0, round))
	end

	return frame
end

local function disc(parent: any, color: Color3, cx: number, cy: number, d: number)
	local frame = Instance.new("Frame", parent, {
		Name = "Disc",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Position = UDim2.fromScale((cx - d / 2) / GRID, (cy - d / 2) / GRID),
		Size = UDim2.fromScale(d / GRID, d / GRID),
	})

	-- A half-size corner radius is the only way to get a circle out of a frame.
	Instance.corner(frame, UDim.new(0.5, 0))
	return frame
end

--- A ring is four bars spanning the disc's bounding box; without rotation there is no
--- cheaper way to suggest a circle outline.
local function ring(parent: any, color: Color3, cx: number, cy: number, d: number, thickness: number?)
	local t = thickness or math.max(2, d * 0.16)
	local left = cx - d / 2
	local top = cy - d / 2

	bar(parent, color, left, top, d, t, t / 2)
	bar(parent, color, left, top + d - t, d, t, t / 2)
	bar(parent, color, left, top, t, d, t / 2)
	bar(parent, color, left + d - t, top, t, d, t / 2)
end

local function outlineBox(parent: any, color: Color3, x: number, y: number, w: number, h: number, t: number?)
	local thickness = t or 2.2
	bar(parent, color, x, y, w, thickness, thickness / 2)
	bar(parent, color, x, y + h - thickness, w, thickness, thickness / 2)
	bar(parent, color, x, y, thickness, h, thickness / 2)
	bar(parent, color, x + w - thickness, y, thickness, h, thickness / 2)
end

GlyphFallback.shapes = {
	dot = function(parent, color)
		disc(parent, color, 12, 12, 9)
	end,

	ring = function(parent, color)
		ring(parent, color, 12, 12, 17)
	end,

	plus = function(parent, color)
		bar(parent, color, 10.8, 4, 2.4, 16, 1.2)
		bar(parent, color, 4, 10.8, 16, 2.4, 1.2)
	end,

	minus = function(parent, color)
		bar(parent, color, 4, 10.8, 16, 2.4, 1.2)
	end,

	square = function(parent, color)
		outlineBox(parent, color, 4, 4, 16, 16)
	end,

	grid = function(parent, color)
		bar(parent, color, 4, 4, 7, 7, 2)
		bar(parent, color, 13, 4, 7, 7, 2)
		bar(parent, color, 4, 13, 7, 7, 2)
		bar(parent, color, 13, 13, 7, 7, 2)
	end,

	list = function(parent, color)
		for _, y in ipairs({ 6, 11.5, 17 }) do
			bar(parent, color, 4, y, 2.4, 2.4, 1.2)
			bar(parent, color, 8.5, y, 11.5, 2.4, 1.2)
		end
	end,

	layers = function(parent, color)
		bar(parent, color, 7, 5, 10, 2.6, 1.3)
		bar(parent, color, 5.5, 10.5, 13, 2.6, 1.3)
		bar(parent, color, 4, 16, 16, 2.6, 1.3)
	end,

	sliders = function(parent, color)
		bar(parent, color, 3, 8, 18, 2, 1)
		bar(parent, color, 3, 15, 18, 2, 1)
		disc(parent, color, 9, 9, 5.5)
		disc(parent, color, 16, 16, 5.5)
	end,

	target = function(parent, color)
		ring(parent, color, 12, 12, 17)
		disc(parent, color, 12, 12, 5)
	end,

	eye = function(parent, color)
		outlineBox(parent, color, 2, 6, 20, 12, 2.2)
		disc(parent, color, 12, 12, 6)
	end,
}

--- Names whose real glyph is diagonal. Exposed so a caller can warn about the reduced set
--- rather than treating a plain dot as a broken icon.
GlyphFallback.diagonalOnly = {
	chevronDown = true,
	chevronUp = true,
	chevronRight = true,
	check = true,
	close = true,
	moon = true,
	bell = true,
	warning = true,
	chat = true,
	power = true,
	hold = true,
	refresh = true,
	play = true,
	star = true,
	cursor = true,
	code = true,
	filter = true,
	download = true,
	upload = true,
	folder = true,
	palette = true,
	copy = true,
	gear = true,
}

--- True only when the glyph has a primitive form of its own. Anything else draws the neutral
--- dot, which is a placeholder and must not be reported as expressible — that distinction is
--- what lets a caller say "this client gets a reduced icon set" honestly.
function GlyphFallback.isExpressible(name: string): boolean
	return GlyphFallback.shapes[name] ~= nil
end

--- Draw `name` as primitives, or the neutral dot when there is no primitive form.
function GlyphFallback.draw(parent: any, name: string, color: Color3): any
	local container = Instance.new("Frame", parent, {
		Name = "Glyph_" .. tostring(name),
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	})

	local shape = GlyphFallback.shapes[name]
	if shape == nil then
		shape = GlyphFallback.shapes.dot
	end

	shape(container, color)
	return container
end

return GlyphFallback
