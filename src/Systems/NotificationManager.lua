--[[
	Systems/NotificationManager — the toast stack.

	One instance per notification (about six), a shared UIListLayout for ordering, and a
	dismissal timer driven by task.delay so the stack costs nothing between events. The queue
	cap exists because an unbounded stack on a phone viewport pushes its own top item off
	screen, which is the opposite of a notification.

	A notification whose text is updated re-times itself: a progress toast that finishes at 80 %
	because nobody refreshed the timer is a lie the UI tells about the work.
]]

local Signal = require("Flux/Utilities/Signal")
local Instance = require("Flux/Utilities/Instance")
local Maid = require("Flux/Utilities/Maid")
local Guard = require("Flux/Utilities/Guard")
local ThemeManager = require("Flux/Systems/ThemeManager")
local AnimationManager = require("Flux/Systems/AnimationManager")
local IconManager = require("Flux/Systems/IconManager")
local Element = require("Flux/Core/Element")
local String = require("Flux/Utilities/String")
local Math = require("Flux/Utilities/Math")

local Notifications = {}

local settings = {
	Max = 4,
	Duration = 5,
	Width = 288,
	Anchor = "TopRight",
	Padding = 10,
}

local stack: any = nil
local owner: Maid? = nil
local visible = {}
local dropped = 0

Notifications.Added = Signal.new()
Notifications.Removed = Signal.new()

--- Which role paints the accent strip for a kind. Unknown kinds read as info rather than failing.
Notifications.kinds = {
	info = "Info",
	success = "Success",
	warning = "Warning",
	error = "Error",
}

Notifications.icons = {
	info = "info",
	success = "check",
	warning = "warning",
	error = "error",
}

function Notifications.configure(options: { Max: number?, Duration: number?, Width: number?, Anchor: string? })
	options = options or {}
	if type(options.Max) == "number" then
		settings.Max = math.max(1, math.floor(options.Max))
	end
	if type(options.Duration) == "number" then
		settings.Duration = math.max(0.5, options.Duration)
	end
	if type(options.Width) == "number" then
		settings.Width = math.max(160, options.Width)
	end
	if type(options.Anchor) == "string" then
		settings.Anchor = options.Anchor
	end
	return settings
end

--- Attach the stack to an existing ScreenGui. Called by the library when a window is built; if it
--- is never called, the first notification creates its own collector so a hub that only notifies
--- still works.
function Notifications.attach(gui: any)
	if gui == nil or stack == gui then
		return
	end

	if stack ~= nil then
		-- Re-attaching is a second window opening. The frame moves to the new host instead of being
		-- rebuilt in it: the toasts already on screen belong to the hub, not to whichever window was
		-- open when they fired, and a card the user can see but no longer reach is worse than one
		-- that jumped sides.
		if stack.Parent ~= gui then
			stack.Parent = gui
		end
		return
	end

	if owner ~= nil then
		owner:cleanup()
	end

	owner = Maid.new()
	stack = Instance.new("Frame", gui, {
		Name = "NotificationStack",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(settings.Width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.new(1, -settings.Width - settings.Padding, 0, settings.Padding),
		AnchorPoint = Vector2.new(1, 0),
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})

	Element.stack(owner, stack, { Gap = "GroupGap" })
end

--- Let go of a stack whose host is going away. A window that is destroyed with the stack still
--- attached would otherwise hand the next notification to a ScreenGui no longer in the tree, which
--- shows nothing and warns about nothing.
function Notifications.detach(gui: any): boolean
	if gui == nil or stack == nil or stack.Parent ~= gui then
		return false
	end

	Notifications.clear()
	if owner ~= nil then
		owner:cleanup()
		owner = nil
	end
	stack:Destroy()
	stack = nil
	return true
end

local function ensureStack()
	if stack ~= nil then
		return
	end
	local maid = Maid.new()
	Notifications.attach(Element.root(maid, { Name = "FluxHub/Notifications", Order = 1001 }))
	-- attach() replaces the maid it was given with its own, so the collector's owner is the one
	-- that outlives the notification it was created for.
	Notifications._collectorMaid = maid
end

local handle = {}
handle.__index = handle

function handle.GetText(self: any): string
	return self.text
end

--- Replace text and/or progress. Re-times the dismissal unless the caller says otherwise.
function handle.Update(self: any, options: { Title: string?, Text: string?, Progress: number?, Retime: boolean? })
	if self.destroyed then
		return false
	end

	options = options or {}

	if type(options.Text) == "string" then
		self.text = options.Text
		Guard.set(self.textLabel, "Text", String.escape(options.Text))
	end

	if type(options.Title) == "string" then
		Guard.set(self.title, "Text", String.escape(options.Title))
	end

	if type(options.Progress) == "number" then
		local amount = Math.clamp(options.Progress, 0, 1)
		self.bar.Size = UDim2.fromScale(amount, 1)
		self.progress = amount
	end

	if options.Retime ~= false then
		self:retime()
	end

	return true
end

function handle.Dismiss(self: any, instant: boolean?)
	if self.destroyed then
		return
	end
	self.destroyed = true

	for index = #visible, 1, -1 do
		if visible[index] == self then
			table.remove(visible, index)
		end
	end

	if self.timer ~= nil then
		task.cancel(self.timer)
		self.timer = nil
	end

	local function remove()
		if self.instance ~= nil then
			self.instance:Destroy()
		end
		if self.maid ~= nil then
			self.maid:cleanup()
		end
		Notifications.Removed:Dispatch(self.id)
		Notifications.pump()
	end

	if instant or AnimationManager.isReducedMotion() then
		remove()
	else
		-- GroupTransparency fades the whole card including its text; on a client without the
		-- member AnimationManager skips it and only the fill fades, which is why it is listed
		-- alongside rather than instead of BackgroundTransparency.
		AnimationManager.to(self.instance, {
			BackgroundTransparency = 1,
			GroupTransparency = 1,
		}, { Duration = 0.12, Easing = "outQuad", OnEnd = remove })
	end
end

--- Restart the countdown.
function handle.retime(self: any)
	if self.timer ~= nil then
		task.cancel(self.timer)
	end
	if self.duration <= 0 then
		return
	end
	self.timer = task.delay(self.duration, function()
		self:Dismiss()
	end)
end

local nextId = 0

--- Show a notification. Returns a handle with Update/Dismiss/GetText.
function Notifications.notify(options: {
	Title: string?,
	Text: string?,
	Duration: number?,
	Kind: string?,
	Icon: string?,
	Progress: number?,
	Persistent: boolean?,
}): any
	ensureStack()

	options = options or {}
	local kind = Notifications.kinds[options.Kind] and options.Kind or "info"
	local role = Notifications.kinds[kind]
	local duration = options.Duration or settings.Duration
	if options.Persistent then
		duration = 0
	end

	nextId += 1
	local maid = Maid.new()

	local card = Element.panel(maid, stack, "Notification_" .. nextId, {
		Color = "Panel",
		Radius = "RadiusPanel",
		Stroke = "BorderPrimary",
		Size = UDim2.fromOffset(settings.Width, 0),
		Clips = true,
	})
	card.AutomaticSize = Enum.AutomaticSize.Y

	local accent = Instance.new("Frame", card, {
		Name = "Accent",
		BackgroundColor3 = ThemeManager.color(role),
		BorderSizePixel = 0,
		Size = UDim2.new(0, 3, 1, -16),
		Position = UDim2.fromOffset(8, 8),
	})
	maid:give(ThemeManager.bind(accent, "BackgroundColor3", role))
	Element.round(maid, accent, "RadiusChip")

	-- The glyph is what makes a kind readable without reading the sentence. A host that names one
	-- overrides the kind's default, and a name the atlas does not hold leaves the accent strip to
	-- carry the meaning on its own rather than showing a box.
	local glyph = options.Icon or Notifications.icons[kind]
	local inset = 26
	if glyph ~= nil and IconManager.has(glyph) then
		Element.icon(maid, card, glyph, {
			Role = role,
			Size = UDim2.fromOffset(14, 14),
			Position = UDim2.fromOffset(20, 10),
			ZIndex = 6,
		})
		inset = 42
	end

	local body = Instance.new("Frame", card, {
		Name = "Body",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -(inset + 8), 1, 0),
		Position = UDim2.fromOffset(inset, 0),
	})

	local title = Element.label(maid, body, "Title", {
		Text = String.escape(options.Title or "Flux"),
		Role = "TextPrimary",
		Font = "Subtitle",
		TextSize = 14,
		Size = UDim2.new(1, 0, 0, 18),
	})

	local textLabel = Element.label(maid, body, "Text", {
		Text = String.escape(options.Text or ""),
		Role = "TextSecondary",
		TextSize = 13,
		Wrap = true,
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.fromOffset(0, 20),
	})

	local barHost = Instance.new("Frame", card, {
		Name = "ProgressTrack",
		BackgroundColor3 = ThemeManager.color("Field"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, -(inset + 8), 0, 3),
		Position = UDim2.fromOffset(inset, 44),
		Visible = type(options.Progress) == "number",
	})
	maid:give(ThemeManager.bind(barHost, "BackgroundColor3", "Field"))
	Element.round(maid, barHost, "RadiusChip")

	local bar = Instance.new("Frame", barHost, {
		Name = "Progress",
		BackgroundColor3 = ThemeManager.color(role),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(type(options.Progress) == "number" and math.max(0, math.min(1, options.Progress)) or 0, 1),
	})
	maid:give(ThemeManager.bind(bar, "BackgroundColor3", role))
	Element.round(maid, bar, "RadiusChip")

	local self = setmetatable({
		id = nextId,
		instance = card,
		title = title,
		textLabel = textLabel,
		bar = bar,
		barHost = barHost,
		kind = kind,
		text = options.Text or "",
		duration = duration,
		progress = options.Progress,
		maid = maid,
		destroyed = false,
	}, handle)

	table.insert(visible, self)
	Notifications.Added:Dispatch(self.id)

	if duration > 0 then
		self:retime()
	end

	-- Entrance motion after the card exists, so the first frame renders at its resting state if
	-- the client cannot animate.
	card.BackgroundTransparency = 1
	AnimationManager.to(card, { BackgroundTransparency = 0 }, { Duration = 0.16, Easing = "outQuad" })

	Notifications.pump()
	return self
end

--- Trim the stack to the cap, oldest first. The pushed-out toast is gone rather than queued: its
--- card is destroyed with it, so a list of what the cap dropped is the only honest bookkeeping.
function Notifications.pump()
	while #visible > settings.Max do
		local oldest = table.remove(visible, 1)
		if oldest ~= nil then
			dropped += 1
			oldest:Dismiss()
		end
	end
end

function Notifications.count(): number
	return #visible
end

--- How many toasts this session the cap dismissed before their own duration was up.
function Notifications.dropped(): number
	return dropped
end

function Notifications.clear()
	for index = #visible, 1, -1 do
		visible[index]:Dismiss(true)
	end
	table.clear(visible)
	dropped = 0
end

--- Tear the stack down with the hub.
function Notifications.destroy()
	Notifications.clear()
	if stack ~= nil then
		stack:Destroy()
		stack = nil
	end
	if owner ~= nil then
		owner:cleanup()
		owner = nil
	end
	if Notifications._collectorMaid ~= nil then
		Notifications._collectorMaid:cleanup()
		Notifications._collectorMaid = nil
	end
end

return Notifications
