--[[
	Math — numeric helpers shared by sliders, the colour picker, easing and layout fitting.
]]

local Math = {}

function Math.clamp(value: number, minimum: number, maximum: number): number
	if value < minimum then
		return minimum
	end
	if value > maximum then
		return maximum
	end
	return value
end

function Math.lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

--- Snap to a step, then to the decimal places the step implies. Used so a slider never
--- reports 0.30000000000000004.
function Math.snap(value: number, minimum: number, step: number, decimals: number?): number
	if step <= 0 then
		return value
	end

	local snapped = minimum + math.floor((value - minimum) / step + 0.5) * step
	local scale = 10 ^ (decimals or Math.decimalsForStep(step))
	-- A value below the minimum snaps to one step below it, never to itself, so the floor has
	-- to be applied after rounding. Callers clamp the ceiling, which snap cannot know.
	return math.max(math.floor(snapped * scale + 0.5) / scale, minimum)
end

--- How many decimal places a step size implies (0.1 -> 1, 0.25 -> 2, 5 -> 0).
function Math.decimalsForStep(step: number): number
	for decimals = 0, 6 do
		local scale = 10 ^ decimals
		if math.abs(step * scale - math.floor(step * scale + 0.5)) < 1e-6 then
			return decimals
		end
	end
	return 6
end

function Math.round(value: number, decimals: number?): number
	local scale = 10 ^ (decimals or 0)
	return math.floor(value * scale + 0.5) / scale
end

function Math.mapRange(value: number, fromMin: number, fromMax: number, toMin: number, toMax: number): number
	if fromMax == fromMin then
		return toMin
	end
	return toMin + (toMax - toMin) * ((value - fromMin) / (fromMax - fromMin))
end

function Math.inverseLerp(value: number, a: number, b: number): number
	if b == a then
		return 0
	end
	return Math.clamp((value - a) / (b - a), 0, 1)
end

function Math.sign(value: number): number
	if value > 0 then
		return 1
	end
	if value < 0 then
		return -1
	end
	return 0
end

--- Shortest signed angular difference in degrees, for rotation tweens.
function Math.deltaAngle(from: number, to: number): number
	local delta = (to - from) % 360
	if delta > 180 then
		delta -= 360
	end
	return delta
end

--- Largest scale no greater than 1 that keeps a window of `baseSize` inside `viewport`,
--- floored at `minimum` so a tiny window stays legible rather than vanishing.
function Math.fitScale(baseSize: Vector2, viewport: Vector2, minimum: number): number
	local byWidth = 1
	local byHeight = 1

	if baseSize.X > 0 then
		byWidth = viewport.X / baseSize.X
	end
	if baseSize.Y > 0 then
		byHeight = viewport.Y / baseSize.Y
	end

	return Math.clamp(math.min(byWidth, byHeight, 1), minimum, 1)
end

return Math
