--[[
	Guard — the single place optional engine members are touched.

	The clients this library targets are older than the engine: `ScreenGui.ResetOnDestroyed`,
	`DisplayOrderOnTop`, `CanvasGroup`, `GroupTransparency`, `TextLabel.LetterSpacing` and
	`Frame.AbsoluteCenter` all raise instead of being absent. An unguarded write on the boot
	path aborts the whole library, so nothing outside this module assigns a recent member
	directly, and every cosmetic-only construction block goes through `Guard.try`.
]]

local Guard = {}

local warned = {}

--- Assign a property that may not exist on this client. Returns whether it took.
function Guard.set(instance: any, property: string, value: any): boolean
	if instance == nil then
		return false
	end

	local ok = pcall(function()
		instance[property] = value
	end)

	if not ok and not warned[property] then
		warned[property] = true
	end

	return ok
end

--- Read a property that may not exist. Returns nil instead of raising.
function Guard.get(instance: any, property: string): any
	if instance == nil then
		return nil
	end

	local ok, value = pcall(function()
		return instance[property]
	end)

	if ok then
		return value
	end
	return nil
end

--- Does this client actually have the member? Used to pick a code path, never to skip work silently.
function Guard.has(instance: any, property: string): boolean
	return Guard.get(instance, property) ~= nil
end

--- Run a cosmetic construction step; a failure degrades to "not shown" instead of aborting.
function Guard.try(fn: () -> ...any): (boolean, ...any)
	local ok, first, rest = pcall(fn)
	if ok then
		return true, first, rest
	end
	return false, first
end

--- Drawn centre of an instance. `AbsoluteCenter` raises on this client, so derive it.
function Guard.absoluteCenter(instance: any): Vector2
	local position = instance.AbsolutePosition
	local size = instance.AbsoluteSize
	return Vector2.new(position.X + size.X * 0.5, position.Y + size.Y * 0.5)
end

--- Global service lookup that tolerates a service missing from an older client.
function Guard.service(className: string): any
	local ok, found = pcall(function()
		return game:GetService(className)
	end)
	if ok then
		return found
	end
	return nil
end

function Guard.wasWarned(property: string): boolean
	return warned[property] == true
end

return Guard
