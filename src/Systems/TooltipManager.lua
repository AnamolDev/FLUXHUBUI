--[[
	Systems/TooltipManager — one hover surface for the whole UI.

	A tooltip per widget is the obvious design and the wrong one: a page with forty rows would
	carry forty frames and forty MouseEnter connections, and they would all still be there when
	the tab is swapped. This keeps a single instance, moves it, and changes its text.

	Two behaviours that are easy to get wrong and are the reason a tooltip feels broken rather
	than absent:

	  * It appears after a delay and disappears immediately. Appealing instantly makes the surface
	    flash across the screen while the pointer crosses a list; lingering after the pointer
	    leaves makes it outlive the thing it described.
	  * It is positioned against the pointer, not the widget, and clamped to the viewport — a
	    tooltip whose right edge is off-screen is unreadable, and on a phone the whole surface is
	    near an edge.
]]

local Instance = require("Flux/Utilities/Instance")
local Guard = require("Flux/Utilities/Guard")
local Maid = require("Flux/Utilities/Maid")
local ThemeManager = require("Flux/Systems/ThemeManager")
local LayoutManager = require("Flux/Systems/LayoutManager")
local Element = require("Flux/Core/Element")
local String = require("Flux/Utilities/String")

local Players = Guard.service("Players")

local TooltipManager = {}

local settings = {
	Delay = 0.35,
	Offset = 12,
	MaxWidth = 240,
}

local owner: Maid? = nil
local host: any = nil
local label: any = nil
local timer: thread? = nil
local shown = false
local attached = 0

--- Attach a tooltip to an instance. Returns an unbind function, which every component hands to
--- its maid — the count below is what proves a destroyed row released its tooltip.
function TooltipManager.attach(instance: any, text: string, options: { Delay: number?, MaxWidth: number? })
	if instance == nil or type(text) ~= "string" or text == "" then
		return function() end
	end

	options = options or {}
	local maid = Maid.new()
	attached += 1

	local enter = Guard.get(instance, "MouseEnter")
	local leave = Guard.get(instance, "MouseLeave")

	if enter ~= nil then
		maid:giveConnection(enter:Connect(function()
			TooltipManager.request(text, options.Delay or settings.Delay)
		end))
	end

	if leave ~= nil then
		maid:giveConnection(leave:Connect(function()
			TooltipManager.hide()
		end))
	end

	-- A row can be destroyed while hovered; without this the surface stays on screen with nobody
	-- left to move it.
	local destroyed = Guard.get(instance, "Destroyed")
	if destroyed ~= nil then
		maid:giveConnection(destroyed:Connect(function()
			TooltipManager.hide()
		end))
	end

	local unbound = false
	return function()
		if unbound then
			return
		end
		unbound = true
		attached -= 1
		maid:cleanup()
		TooltipManager.hide()
	end
end

function TooltipManager.attached(): number
	return attached
end

function TooltipManager.configure(options: { Delay: number?, Offset: number?, MaxWidth: number? })
	options = options or {}
	if type(options.Delay) == "number" then
		settings.Delay = math.max(0, options.Delay)
	end
	if type(options.Offset) == "number" then
		settings.Offset = options.Offset
	end
	if type(options.MaxWidth) == "number" then
		settings.MaxWidth = options.MaxWidth
	end
	return settings
end

local function ensureHost()
	if host ~= nil then
		return
	end

	owner = Maid.new()
	local root = Element.root(owner, { Name = "FluxHub/Tooltips", Order = 1003 })

	host = Instance.new("Frame", root, {
		Name = "Tooltip",
		BackgroundColor3 = ThemeManager.color("PanelSecondary"),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		Visible = false,
		ZIndex = 10,
	})

	Instance.corner(host, UDim.new(0, ThemeManager.metric("RadiusField") or 8))
	Instance.pad(host, {
		Top = UDim.new(0, 6),
		Bottom = UDim.new(0, 6),
		Left = UDim.new(0, 8),
		Right = UDim.new(0, 8),
	})

	label = Element.label(owner, host, "Text", {
		Text = "",
		Role = "TextSecondary",
		TextSize = 12,
		Size = UDim2.fromScale(0, 1),
	})
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.TextWrapped = false

	owner:give(ThemeManager.bind(host, "BackgroundColor3", "PanelSecondary"))
	owner:giveFunction(function()
		if host ~= nil then
			host:Destroy()
		end
		host = nil
		label = nil
	end)
end

local function mousePosition(): (number, number)
	if Players == nil then
		return 0, 0
	end
	local player = Players.LocalPlayer
	if player == nil then
		return 0, 0
	end
	local ok, mouse = pcall(function()
		return player:GetMouse()
	end)
	if not ok or mouse == nil then
		return 0, 0
	end
	return Guard.get(mouse, "X") or 0, Guard.get(mouse, "Y") or 0
end

--- Place the surface beside the pointer, flipping sides and clamping so it stays readable.
function TooltipManager.place()
	local x, y = mousePosition()
	local viewport = LayoutManager.viewport()
	-- AutomaticSize has not resolved for the frame we just changed the text of, so the width is
	-- read after a frame rather than guessed here.
	local size = Guard.get(host, "AbsoluteSize") or Vector2.new(0, 0)
	local width = size.X
	local height = size.Y

	local left = x + settings.Offset
	local top = y + settings.Offset

	if left + width > viewport.X - 8 then
		left = x - width - settings.Offset
	end
	if top + height > viewport.Y - 8 then
		top = math.max(8, viewport.Y - height - 8)
	end
	left = math.max(8, left)
	top = math.max(8, top)

	host.Position = UDim2.fromOffset(left, top)
end

--- Ask for the surface to appear after `delay` seconds of continued hover.
function TooltipManager.request(text: string, delay: number?)
	ensureHost()

	if timer ~= nil then
		task.cancel(timer)
	end

	local wait = delay or settings.Delay
	label.Text = String.escape(text)

	if wait <= 0 then
		TooltipManager.show()
		return
	end

	timer = task.delay(wait, function()
		timer = nil
		TooltipManager.show()
	end)
end

function TooltipManager.show()
	if host == nil then
		return
	end
	host.Visible = true
	shown = true
	TooltipManager.place()
end

function TooltipManager.hide()
	if timer ~= nil then
		task.cancel(timer)
		timer = nil
	end
	if host ~= nil then
		host.Visible = false
	end
	shown = false
end

function TooltipManager.isShown(): boolean
	return shown
end

--- Follow the pointer while open. Called by the hub's frame loop; a tooltip that does not move
--- after a scroll reads as a rendering bug.
function TooltipManager.tick()
	if shown and host ~= nil and host.Visible then
		TooltipManager.place()
	end
end

function TooltipManager.destroy()
	TooltipManager.hide()
	if owner ~= nil then
		owner:cleanup()
		owner = nil
	end
	host = nil
	label = nil
	shown = false
	attached = 0
end

return TooltipManager
