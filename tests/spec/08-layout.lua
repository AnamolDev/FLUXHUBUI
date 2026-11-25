--[[
	spec 08 — LayoutManager.

	The responsive story here is one number: a UIScale on the window. So the assertions are about
	that number (capped at 1, floored above nothing, recomputed only when the viewport moved) and
	about the geometry that has to survive it — a window centred before a resize is centred after,
	not shifted by half its own scaled width.
]]

local LayoutManager = assert(fluxRequire("Flux/Systems/LayoutManager"))
local Instance = assert(fluxRequire("Flux/Utilities/Instance"))

runSpec("the authored size and the first answer", function()
	setViewport(1280, 720)
	LayoutManager.refresh()

	local base = LayoutManager.base()
	checkEq(base.X, 900, "the UI is authored at 900 wide")
	checkEq(base.Y, 560, "and 560 tall")

	checkEq(LayoutManager.viewport().X, 1280, "the viewport is read from the camera")
	checkEq(LayoutManager.scale(), 1, "a 1280x720 window fits at full size, and scale never exceeds 1")
	checkEq(LayoutManager.mode(), "desktop", "so it is the desktop layout")
	checkEq(LayoutManager.isMobile(), false, "with a keyboard assumed")
end)

runSpec("scaling down instead of overflowing", function()
	setViewport(900, 560)
	LayoutManager.refresh()

	local scale = LayoutManager.scale()
	check(scale < 1 and scale > 0.9, "the margin keeps it inside a window exactly the base size", tostring(scale))

	setViewport(540, 960)
	LayoutManager.refresh()
	checkEq(LayoutManager.mode(), "phone", "a portrait phone width gets the phone layout")
	checkEq(LayoutManager.isMobile(), true, "and reports mobile")
	check(LayoutManager.scale() < 0.6, "scaled well down from full size", tostring(LayoutManager.scale()))

	-- A floor exists so an absurd viewport shrinks the UI rather than deleting it; the number
	-- itself is a deliberate choice, not a measured one.
	setViewport(400, 300)
	LayoutManager.refresh()
	checkEq(LayoutManager.scale(), 0.55, "never below the floor")
end)

runSpec("Changed only when the answer moved", function()
	setViewport(1280, 720)
	LayoutManager.refresh()

	local fired = 0
	local lastMode = nil
	local connection = LayoutManager.Changed:Connect(function(scale, viewport, mode)
		fired += 1
		lastMode = mode
		check(type(scale) == "number", "the signal hands over the scale")
		check(viewport.X > 0, "and the viewport")
	end)

	checkEq(LayoutManager.refresh(), false, "a refresh with nothing changed reports no change")
	checkEq(fired, 0, "and does not wake every window")

	-- Wide enough to stay the desktop layout but short enough that the height term moves the
	-- scale: a resize that changes neither number must not wake anything, which is what keeps a
	-- window drag from re-clamping every window each frame.
	setViewport(900, 600)
	checkEq(LayoutManager.refresh(), true, "a resize that changes the scale reports it")
	checkEq(fired, 1, "exactly once")
	check(lastMode == "desktop", "the mode rides along with the signal", tostring(lastMode))

	setViewport(900, 600)
	checkEq(LayoutManager.refresh(), false, "and the same size again is not a change")
	checkEq(fired, 1, "still one")

	connection:Disconnect()
end)

runSpec("applying the scale", function()
	setViewport(1280, 720)
	LayoutManager.refresh()

	local gui = Instance.new("ScreenGui")
	LayoutManager.apply(gui)
	checkEq(gui.UIScale, 1, "a top-level gui carries the scale")

	setViewport(700, 400)
	LayoutManager.refresh()
	LayoutManager.apply(gui)
	check(gui.UIScale < 1, "and re-applying after a resize moves it", tostring(gui.UIScale))
end)

runSpec("local coordinates are in the authored space", function()
	LayoutManager.setMode("desktop")
	setViewport(1280, 720)
	LayoutManager.refresh()

	local localPoint = LayoutManager.toLocal(Vector2.new(640, 360))
	checkEq(localPoint.X, 640, "at scale 1 a screen point is already local")

	LayoutManager.setMode("phone")
	LayoutManager.refresh()
	local scaled = LayoutManager.toLocal(Vector2.new(100, 100))
	check(math.abs(scaled.X - (100 / LayoutManager.scale())) < 0.001, "below 1 it divides back out", tostring(scaled.X))

	LayoutManager.setMode("auto")
end)

runSpec("a window stays on screen through a resize", function()
	setViewport(1280, 720)
	LayoutManager.refresh()

	local size = UDim2.fromOffset(900, 560)

	-- Pushed far right and down: clamped to the largest position that keeps the whole window
	-- inside the margin.
	local clamped = LayoutManager.clamp(UDim2.fromOffset(5000, 5000), size)
	checkEq(clamped.X.Offset, 372, "1280 - 900 - 8 of left room")
	checkEq(clamped.Y.Offset, 152, "720 - 560 - 8 of top room")

	local offTop = LayoutManager.clamp(UDim2.fromOffset(-200, -100), size)
	checkEq(offTop.X.Offset, 8, "the margin is the floor")
	checkEq(offTop.Y.Offset, 8, "on both axes")

	-- An anchored window must come back anchored: dropping the anchor term is how a centred menu
	-- jumps to the top-left on a resize.
	local centred = LayoutManager.clamp(UDim2.fromOffset(640, 360), size, Vector2.new(0.5, 0.5))
	checkEq(centred.X.Offset, 640, "the centre is preserved")
	checkEq(centred.Y.Offset, 360, "on both axes")
end)

runSpec("column count follows the space that is actually there", function()
	setViewport(1280, 720)
	LayoutManager.refresh()

	local wide = LayoutManager.columns()
	checkEq(wide, 3, "a 1280 window supports three columns")
	checkEq(LayoutManager.columns(500), 1, "and a narrow one a single column")
	checkEq(LayoutManager.columns(760), 2, "with two in between")
end)

runSpec("content height leaves room for the chrome", function()
	setViewport(1280, 720)
	LayoutManager.refresh()
	checkEq(LayoutManager.contentHeight(120), 600, "viewport less the header and footer")
	checkEq(LayoutManager.contentHeight(700), 120, "never collapsing below a usable height")
end)

runSpec("watching the camera", function()
	setViewport(1280, 720)
	LayoutManager.refresh()

	local Workspace = game:GetService("Workspace")
	local camera = Workspace.CurrentCamera
	local function liveResizeHandlers(): number
		local signals = rawget(camera, "_propSignals")
		local signal = signals and signals.ViewportSize
		if signal == nil then
			return 0
		end
		local count = 0
		for _, entry in ipairs(signal.handlers) do
			if entry.alive then
				count += 1
			end
		end
		return count
	end

	local before = liveResizeHandlers()
	checkEq(LayoutManager.watch(), true, "a resize signal is available in this client")
	checkEq(liveResizeHandlers(), before + 1, "and exactly one connection was made")
	checkEq(LayoutManager.watch(), false, "watching twice does not add a second listener")
	checkEq(liveResizeHandlers(), before + 1, "still one")

	setViewport(500, 800)
	pumpFrames(2)
	checkEq(LayoutManager.mode(), "phone", "the resize reached the manager without an explicit refresh")
	checkEq(LayoutManager.viewport().X, 500, "and the viewport moved with it")

	LayoutManager.unwatch()
	checkEq(liveResizeHandlers(), before, "unwatch releases the connection, it does not leave it firing into a closed menu")
	setViewport(1280, 720)
	pumpFrames(2)
	checkEq(LayoutManager.viewport().X, 500, "after unwatching, the world moves and the manager does not")

	checkEq(LayoutManager.watch(), true, "and watching again attaches")
	-- The manager went deaf between unwatch and here, so a bare watch() must not leave it holding
	-- the size it froze at: a hub that reopens its window on a resized screen has to fit it.
	checkEq(LayoutManager.refresh(), true, "the first refresh after re-attaching sees the move")
	checkEq(LayoutManager.viewport().X, 1280, "the viewport the camera has now")
	checkEq(LayoutManager.mode(), "desktop", "and the layout that goes with it")

	setViewport(700, 500)
	pumpFrames(1)
	checkEq(LayoutManager.mode(), "compact", "the re-attached listener is live, not just stored")
	LayoutManager.unwatch()
end)

runSpec("the host can override the guess", function()
	setViewport(1280, 720)
	LayoutManager.refresh()

	LayoutManager.setMode("phone")
	checkEq(LayoutManager.mode(), "phone", "forced, even on a wide viewport")
	checkEq(LayoutManager.isMobile(), true, "and mobile follows the forced layout")

	LayoutManager.setMode("desktop")
	checkEq(LayoutManager.mode(), "desktop", "forced back the other way")
	checkEq(LayoutManager.isMobile(), false, "not mobile again")

	LayoutManager.setMode("auto")
	checkEq(LayoutManager.mode(), "desktop", "auto returns to the breakpoints")
end)

runSpec("a different authored size changes the fit", function()
	setViewport(1280, 720)
	LayoutManager.refresh()

	LayoutManager.setBase(1200, 700)
	checkEq(LayoutManager.base().X, 1200, "the base moved")
	check(LayoutManager.scale() < 1, "so the fit has to shrink below full size", tostring(LayoutManager.scale()))

	LayoutManager.setBase(900, 560)
	checkEq(LayoutManager.scale(), 1, "and restoring it restores the scale")
end)
