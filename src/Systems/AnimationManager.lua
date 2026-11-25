--[[
	Systems/AnimationManager — hand-interpolated motion on one shared RenderStepped loop.

	Why not TweenService: several of the clients this library runs on either lack it or
	leave a created tween that never completes, and a stalled tween is worse than no
	motion — the element stays half-faded forever. Interpolating here means the resting
	state is always correct, motion is layered on top, and a missing engine feature can
	never decide whether something is visible.

	Two rules the rest of the library depends on:
	  * the loop exists only while something is animating, so an idle menu costs nothing;
	  * a new tween for the same (instance, property) replaces the running one, so hover
	    spam cannot stack into a fight between two interpolations.
]]

local Guard = require("Flux/Utilities/Guard")
local Math = require("Flux/Utilities/Math")

local RunService = Guard.service("RunService")

local AnimationManager = {}

local active = {}
local running = false
local connection: RBXScriptConnection? = nil
local speed = 1
local reducedMotion = false

AnimationManager.easing = {
	linear = function(t: number): number
		return t
	end,
	outQuad = function(t)
		return 1 - (1 - t) * (1 - t)
	end,
	outQuint = function(t)
		return 1 - (1 - t) ^ 5
	end,
	outExpo = function(t)
		if t >= 1 then
			return 1
		end
		return 1 - 2 ^ (-10 * t)
	end,
	inOutQuad = function(t)
		if t < 0.5 then
			return 2 * t * t
		end
		return 1 - (-2 * t + 2) ^ 2 / 2
	end,
	outBack = function(t)
		local c1 = 1.70158
		local c3 = c1 + 1
		return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
	end,
	outElastic = function(t)
		if t == 0 or t == 1 then
			return t
		end
		local c4 = (2 * math.pi) / 3
		return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * c4) + 1
	end,
}

--- Motion presets. Duration is in seconds; `style` names an easing above.
---
--- Fade targets both transparency properties a GuiObject can carry. `Transparency` is a part
--- member and does not exist on a Frame, so writing it would silently create an expando that
--- renders as nothing — which is exactly the kind of motion that "works" on screen and does not.
AnimationManager.presets = {
	FadeIn = { duration = 0.16, easing = "outQuad", goals = { BackgroundTransparency = 0, ImageTransparency = 0 } },
	FadeOut = { duration = 0.12, easing = "outQuad", goals = { BackgroundTransparency = 1, ImageTransparency = 1 } },
	SlideIn = { duration = 0.2, easing = "outQuint" },
	PopIn = { duration = 0.22, easing = "outBack", scaleFrom = 0.92 },
	PopOut = { duration = 0.14, easing = "outQuad", scaleTo = 0.94 },
	Hover = { duration = 0.12, easing = "outQuad" },
	Press = { duration = 0.08, easing = "outQuad", scaleTo = 0.975 },
	Release = { duration = 0.14, easing = "outBack" },
	Collapse = { duration = 0.18, easing = "inOutQuad" },
	Expand = { duration = 0.2, easing = "outQuint" },
}

local function kindsFor(property: string): string
	if property == "Size" or property == "Position" then
		return "udim2"
	elseif property == "AnchorPoint" then
		return "vector2"
	elseif property == "BackgroundColor3"
		or property == "TextColor3"
		or property == "ImageColor3"
		or property == "BorderColor3"
		or property == "StrokeColor" then
		return "color"
	end
	return "number"
end

local function interpolate(kind: string, from: any, to: any, alpha: number): any
	if kind == "color" then
		return from:Lerp(to, alpha)
	elseif kind == "udim2" then
		return UDim2.new(
			Math.lerp(from.X.Scale, to.X.Scale, alpha),
			Math.lerp(from.X.Offset, to.X.Offset, alpha),
			Math.lerp(from.Y.Scale, to.Y.Scale, alpha),
			Math.lerp(from.Y.Offset, to.Y.Offset, alpha)
		)
	elseif kind == "vector2" then
		return Vector2.new(Math.lerp(from.X, to.X, alpha), Math.lerp(from.Y, to.Y, alpha))
	end
	return Math.lerp(from, to, alpha)
end

local function stopLoop()
	if connection ~= nil then
		connection:Disconnect()
		connection = nil
	end
	running = false
end

local function step(delta: number)
	local multiplier = speed
	if reducedMotion then
		multiplier = 8
	end

	local index = 1
	while index <= #active do
		local entry = active[index]
		entry.elapsed += delta * multiplier

		local progress = Math.clamp(entry.elapsed / entry.duration, 0, 1)
		local alpha = entry.easing(progress)

		-- The last frame writes the goal itself rather than the maths: `from + (to - from) * 1` is
		-- not `to` in floating point (0.2 lands as 0.19999999999999996), and a resting value a hair
		-- off the caller's request is exactly the half-faded element this module exists to avoid.
		-- The branch is on progress, not alpha, so an overshooting curve still peaks mid-flight.
		local value = entry.to
		if progress < 1 then
			value = interpolate(entry.kind, entry.from, entry.to, alpha)
		end

		if not Guard.set(entry.instance, entry.property, value) then
			-- The property does not exist on this client; drop the entry rather than
			-- re-attempting it every frame for the rest of the animation.
			table.remove(active, index)
			if entry.onEnd ~= nil then
				entry.onEnd(false)
			end
			continue
		end

		if progress >= 1 then
			table.remove(active, index)
			if entry.onEnd ~= nil then
				entry.onEnd(true)
			end
		else
			index += 1
		end
	end

	if #active == 0 then
		stopLoop()
	end
end

local function ensureLoop()
	if running or RunService == nil then
		return
	end

	running = true
	connection = RunService.RenderStepped:Connect(step)
end

--- Animate one or more properties. `goals` maps a property to its target value.
--- Returns how many properties are actually running, and how many in-flight tweens were
--- replaced. A caller that must know whether motion happened (a preset, an entrance) uses the
--- first value; nothing should treat a zero there as success.
function AnimationManager.to(instance: any, goals: {[string]: any}, options: {
	Duration: number?,
	Easing: string?,
	OnEnd: ((boolean) -> ())?,
	Restart: boolean?,
}): (number, number)
	options = options or {}
	local skipped = {}

	local function reportSkipped(ranAnything: boolean)
		-- A property this client cannot animate still owes the caller its completion callback:
		-- callers gate follow-up state on OnEnd, and staying silent would hang them forever.
		-- When at least one property did queue, that tween's own completion is the report.
		if ranAnything or #skipped == 0 or options.OnEnd == nil then
			return
		end
		task.defer(options.OnEnd, false)
	end

	local duration = options.Duration or 0.16
	local easing = AnimationManager.easing[options.Easing or "outQuint"] or AnimationManager.easing.outQuint

	if duration <= 0 or reducedMotion then
		for property, value in pairs(goals) do
			if not Guard.set(instance, property, value) then
				table.insert(skipped, property)
			end
		end
		if options.OnEnd ~= nil then
			task.defer(options.OnEnd, #skipped == 0)
		end
		return 0, 0
	end

	local queued = 0
	local replaced = 0

	for property, target in pairs(goals) do
		local kind = kindsFor(property)

		if kind == "number" and type(target) ~= "number" then
			table.insert(skipped, property)
			continue
		end

		-- Replace any running interpolation of the same property on the same object. The outgoing
		-- entry is told it was superseded: callers that chain state onto OnEnd must not be left
		-- waiting for a tween that no longer exists.
		for index = #active, 1, -1 do
			local entry = active[index]
			if entry.instance == instance and entry.property == property then
				table.remove(active, index)
				replaced += 1
				if entry.onEnd ~= nil then
					task.defer(entry.onEnd, false)
				end
			end
		end

		-- Reading first is what proves the client has the member: writing an unknown property to
		-- an Instance does not raise, it silently creates an expando that renders as nothing.
		local from = Guard.get(instance, property)
		if from == nil then
			table.insert(skipped, property)
			continue
		end

		table.insert(active, {
			instance = instance,
			property = property,
			kind = kind,
			from = from,
			to = target,
			elapsed = 0,
			duration = duration,
			easing = easing,
			onEnd = options.OnEnd,
		})
		queued += 1
	end

	ensureLoop()
	reportSkipped(queued > 0)
	return queued, replaced
end

--- Play a named preset against a known geometry. Returns whether it played.
function AnimationManager.play(instance: any, presetName: string, options: {[string]: any}?): boolean
	local preset = AnimationManager.presets[presetName]
	if preset == nil then
		warn("[Flux] animation: unknown preset " .. tostring(presetName))
		return false
	end

	options = options or {}
	local duration = options.Duration or preset.duration
	local easing = preset.easing

	-- Every branch reports what `to` actually queued. A preset that found no animatable property
	-- on this client has not played, and saying otherwise is how a menu ends up with transitions
	-- that are configured, reported as working, and never happen.
	if preset.goals ~= nil then
		local queued = AnimationManager.to(instance, preset.goals, {
			Duration = duration,
			Easing = easing,
			OnEnd = options.OnEnd,
		})
		return queued > 0
	end

	-- Hover, Collapse and Expand describe timing, not a destination: the caller owns what the
	-- element animates toward. Without Goals there is nothing to run.
	if options.Goals ~= nil then
		local queued = AnimationManager.to(instance, options.Goals, {
			Duration = duration,
			Easing = easing,
			OnEnd = options.OnEnd,
		})
		return queued > 0
	end

	if presetName == "SlideIn" then
		local target = options.TargetPosition
		if target == nil then
			warn("[Flux] animation: SlideIn needs options.TargetPosition")
			return false
		end

		local offset = options.Offset or 10
		instance.Position = UDim2.new(target.X.Scale, target.X.Offset, target.Y.Scale, target.Y.Offset + offset)

		local moved = AnimationManager.to(instance, { Position = target }, {
			Duration = duration,
			Easing = easing,
			OnEnd = options.OnEnd,
		})
		AnimationManager.to(instance, { BackgroundTransparency = 0 }, { Duration = duration, Easing = easing })
		return moved > 0
	end

	if preset.scaleFrom ~= nil or preset.scaleTo ~= nil then
		local size = instance.Size
		if size.X.Scale == 0 and size.Y.Scale == 0 then
			-- A pure-offset size has no scale term to interpolate; fall back to a fade so the
			-- element still arrives with motion instead of snapping.
			local faded = AnimationManager.to(instance, { BackgroundTransparency = 0 }, {
				Duration = duration,
				Easing = easing,
				OnEnd = options.OnEnd,
			})
			return faded > 0
		end

		local factor = preset.scaleFrom or preset.scaleTo or 1
		local goal

		if preset.scaleFrom ~= nil then
			instance.Size = UDim2.new(size.X.Scale * factor, size.X.Offset * factor, size.Y.Scale, size.Y.Offset)
			goal = UDim2.new(size.X.Scale, size.X.Offset, size.Y.Scale, size.Y.Offset)
		else
			goal = UDim2.new(size.X.Scale * factor, size.X.Offset * factor, size.Y.Scale, size.Y.Offset)
		end

		local grew = AnimationManager.to(instance, { Size = goal }, {
			Duration = duration,
			Easing = easing,
			OnEnd = options.OnEnd,
		})
		return grew > 0
	end

	warn("[Flux] animation: preset " .. presetName .. " has no goals; pass options.Goals")
	return false
end

--- Stop every interpolation owned by an instance (a destroyed row must not keep ticking).
function AnimationManager.cancel(instance: any)
	for index = #active, 1, -1 do
		if active[index].instance == instance then
			table.remove(active, index)
		end
	end

	if #active == 0 then
		stopLoop()
	end
end

function AnimationManager.activeCount(): number
	return #active
end

function AnimationManager.setSpeed(multiplier: number)
	speed = math.max(0.05, multiplier)
end

function AnimationManager.getSpeed(): number
	return speed
end

--- Global switch: with motion reduced every tween lands on its resting value immediately.
function AnimationManager.setReducedMotion(enabled: boolean)
	reducedMotion = enabled == true
end

function AnimationManager.isReducedMotion(): boolean
	return reducedMotion
end

function AnimationManager.stopAll()
	table.clear(active)
	stopLoop()
end

return AnimationManager
