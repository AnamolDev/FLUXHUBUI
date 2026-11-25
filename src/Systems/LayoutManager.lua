--[[
	Systems/LayoutManager — one place decides how big the UI is and where it may sit.

	The problem this solves: a menu authored at 900x560 fills a phone screen and a 1080p window
	looks tiny, and both are the same client. Rather than size every widget against the viewport
	(the usual way a UI ends up unreadable on one of the two), the library is authored once at a
	base size and the whole window carries a single UIScale.

	Scale is capped at 1. Letting it grow past one is how a library "supports" ultrawide monitors
	by rendering blurry text at 1.4x; a large viewport should show more content, which is the
	column-count job, not the font-size job.
]]

local Signal = require("Flux/Utilities/Signal")
local Guard = require("Flux/Utilities/Guard")
local Math = require("Flux/Utilities/Math")

local RunService = Guard.service("RunService")
local UserInputService = Guard.service("UserInputService")
local GuiService = Guard.service("GuiService")
local Workspace = Guard.service("Workspace")

local LayoutManager = {}

--- The size the UI is authored at. Components use offsets against this, never the viewport.
local base = Vector2.new(900, 560)

local state = {
	scale = 1,
	viewport = Vector2.new(1280, 720),
	mode = "desktop",
	mobile = false,
	inset = Vector2.new(0, 0),
}

local forcedMode: string? = nil
local watched = false

--- Fires (scale, viewport, mode) whenever the answer changes. Windows re-clamp their position on
--- this; nothing else needs to react, which is the point of scaling one instance.
LayoutManager.Changed = Signal.new()

--- A viewport this small, or a touch device, gets the compact layout: nav becomes a top strip and
--- the content column stops trying to be two columns wide.
LayoutManager.breakpoints = {
	compact = 760,
	phone = 560,
}

local function readViewport(): Vector2
	local camera = Workspace and Workspace.CurrentCamera
	local size = camera and Guard.get(camera, "ViewportSize")
	if type(size) == "userdata" or type(size) == "table" then
		if type(size.X) == "number" and type(size.Y) == "number" then
			return size
		end
	end
	return state.viewport
end

local function readInset(): Vector2
	-- Safe-area insets only exist on a touch device; the two APIs are alternatives, not both.
	if GuiService ~= nil then
		local safe = Guard.get(GuiService, "SafeAreaInsets")
		if safe ~= nil then
			return Vector2.new(math.max(safe.Left, safe.Right), math.max(safe.Top, safe.Bottom))
		end

		local ok, x, y = pcall(function()
			return GuiService:GetGuiInsets()
		end)
		if ok then
			return Vector2.new(math.max(x or 0, 0), math.max(y or 0, 0))
		end
	end

	return state.inset
end

local function touchOnly(): boolean
	if UserInputService == nil then
		return false
	end
	local touch = Guard.get(UserInputService, "TouchEnabled")
	local keyboard = Guard.get(UserInputService, "KeyboardEnabled")
	if touch == true and keyboard == false then
		return true
	end
	return false
end

local function modeFor(width: number): string
	if forcedMode ~= nil then
		return forcedMode
	end
	if width <= LayoutManager.breakpoints.phone then
		return "phone"
	end
	if width <= LayoutManager.breakpoints.compact then
		return "compact"
	end
	return "desktop"
end

--- A window that fills the screen edge to edge is what makes a hub look amateur on a laptop, so
--- the fit is measured against a viewport with breathing room removed.
local margin = 24

local function recompute(): boolean
	local viewport = readViewport()
	local mode = modeFor(viewport.X)
	local mobile = forcedMode ~= nil and (forcedMode ~= "desktop") or (mode == "phone") or touchOnly()
	local scale = Math.fitScale(base, Vector2.new(math.max(160, viewport.X - margin), math.max(120, viewport.Y - margin)), 0.55)
	local inset = readInset()

	if viewport.X == state.viewport.X and viewport.Y == state.viewport.Y and mode == state.mode and scale == state.scale and inset.X == state.inset.X and inset.Y == state.inset.Y then
		return false
	end

	state.viewport = viewport
	state.mode = mode
	state.mobile = mobile
	state.scale = scale
	state.inset = inset
	return true
end

--- Call once per resize, or on demand. Dispatches Changed only when the answer moved, so a
--- window does not re-clamp itself on every frame.
function LayoutManager.refresh(): boolean
	local changed = recompute()
	if changed then
		LayoutManager.Changed:Dispatch(state.scale, state.viewport, state.mode)
	end
	return changed
end

--- Start listening. Deliberately separate from require: a hub that never opens a window should
--- not hold a RenderStepped connection.
function LayoutManager.watch()
	if watched then
		return false
	end

	local camera = Workspace and Workspace.CurrentCamera
	local getter = camera and Guard.get(camera, "GetPropertyChangedSignal")
	if type(getter) == "function" then
		-- GetPropertyChangedSignal hands back a signal, not a connection; only what Connect
		-- returns can be disconnected, so the connection is what gets stored.
		local ok, signal = pcall(getter, camera, "ViewportSize")
		if ok and signal ~= nil then
			local connected, connection = pcall(function()
				-- Deferred rather than handled inline: during a device rotation ViewportSize moves
				-- several times and the window's absolute size is only settled on the next frame.
				return signal:Connect(function()
					task.defer(LayoutManager.refresh)
				end)
			end)
			if connected and connection ~= nil then
				watched = true
				LayoutManager._resizeConnection = connection
				return true
			end
		end
	end

	-- No camera signal available (no camera yet, or a client without the member): fall back to a
	-- cheap poll on RenderStepped. recompute() early-returns when nothing moved, so the idle cost
	-- is one userdata read.
	if RunService ~= nil then
		watched = true
		LayoutManager._frameConnection = RunService.RenderStepped:Connect(function()
			LayoutManager.refresh()
		end)
		return true
	end

	-- Left unset so a host that watches again after the camera appears actually attaches.
	return false
end

function LayoutManager.unwatch()
	for _, key in ipairs({ "_resizeConnection", "_frameConnection" }) do
		local connection = LayoutManager[key]
		if connection ~= nil then
			connection:Disconnect()
			LayoutManager[key] = nil
		end
	end
	watched = false
end

--- Apply the current scale to a top-level gui (each window carries its own UIScale).
function LayoutManager.apply(gui: any)
	if gui == nil then
		return
	end
	Guard.set(gui, "UIScale", state.scale)
end

function LayoutManager.scale(): number
	return state.scale
end

function LayoutManager.viewport(): Vector2
	return state.viewport
end

function LayoutManager.base(): Vector2
	return base
end

function LayoutManager.setBase(width: number, height: number)
	base = Vector2.new(width, height)
	LayoutManager.refresh()
end

function LayoutManager.mode(): string
	return state.mode
end

function LayoutManager.isMobile(): boolean
	return state.mobile
end

--- Force a layout for testing or for a host that knows better than the breakpoint guess.
function LayoutManager.setMode(mode: string?)
	if mode == nil or mode == "auto" then
		forcedMode = nil
	else
		forcedMode = mode
	end
	LayoutManager.refresh()
end

function LayoutManager.inset(): Vector2
	return state.inset
end

--- Convert a screen point (mouse position) into the window's own scaled coordinates. Dragging and
--- cursor-anchored tooltips both need this, and getting it wrong by the scale factor is the usual
--- reason a tooltip appears a finger-width away from the pointer on a phone.
function LayoutManager.toLocal(point: Vector2): Vector2
	return Vector2.new(point.X / state.scale, point.Y / state.scale)
end

--- Keep a window inside the viewport after a resize, preserving its size in offset terms.
function LayoutManager.clamp(position: UDim2, size: UDim2, anchor: Vector2?): UDim2
	local viewport = state.viewport
	local scale = state.scale
	local width = (size.X.Scale * viewport.X + size.X.Offset) * scale
	local height = (size.Y.Scale * viewport.Y + size.Y.Offset) * scale

	local anchorX = (anchor and anchor.X or 0) * width
	local anchorY = (anchor and anchor.Y or 0) * height

	local left = (position.X.Scale * viewport.X + position.X.Offset) * scale - anchorX
	local top = (position.Y.Scale * viewport.Y + position.Y.Offset) * scale - anchorY

	local margin = 8 * scale
	local maxLeft = math.max(margin, viewport.X - width - margin)
	local maxTop = math.max(margin, viewport.Y - height - margin)

	local clampedLeft = Math.clamp(left, margin, maxLeft)
	local clampedTop = Math.clamp(top, margin, maxTop)

	return UDim2.new(0, clampedLeft / scale + anchorX / scale, 0, clampedTop / scale + anchorY / scale)
end

--- Two-column content fits at this width; below it, a single column reads better than a squashed
--- pair. Components ask rather than measuring, so the rule lives once.
function LayoutManager.columns(available: number?, minimum: number?): (number, number)
	local width = available or (state.viewport.X * state.scale)
	local columnMinimum = minimum or 300
	local count = Math.clamp(math.floor((width - 48) / columnMinimum), 1, 3)
	return count, columnMinimum
end

--- A page taller than the viewport gets a scrolling canvas sized to what is left of the chrome.
function LayoutManager.contentHeight(chrome: number?): number
	local used = chrome or 0
	return math.max(120, (state.viewport.Y / state.scale) - used)
end

LayoutManager.refresh()

return LayoutManager
