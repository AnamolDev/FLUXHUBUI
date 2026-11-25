--[[
	Core/Lifecycle — the list of things a hub owns, and the one path that releases all of them.

	`Flux:Unload()` has to be callable from a keybind, from a menu button, and from a script that
	is being re-executed, and it has to leave the client exactly as it found it. That only works if
	every owner registers itself here instead of each widget guessing when it may be freed, and if
	teardown runs in one order: windows first (they hold the UI), then the systems they used.

	Close callbacks fire once. A hub that unloads twice must not run its save routine twice.
]]

local Maid = require("Flux/Utilities/Maid")

local Lifecycle = {}

--- A destroyed instance raises on any property read, which is the only reliable liveness test
--- that works without holding an event connection per window.
local function dead(instance: any): boolean
	if instance == nil then
		return true
	end
	return not pcall(function()
		return (instance :: any).Name
	end)
end

local windows = {}
local closing = {}
local closed = false
local shared = Maid.new()

function Lifecycle.maid(): any
	return shared
end

--- A window registers itself so `Unload` can destroy it without the caller keeping the handle.
function Lifecycle.register(window: any): any
	for index = #windows, 1, -1 do
		if dead(windows[index]) then
			table.remove(windows, index)
		end
	end

	table.insert(windows, window)
	return window
end

function Lifecycle.unregister(window: any): number
	local removed = 0
	for index = #windows, 1, -1 do
		if windows[index] == window then
			table.remove(windows, index)
			removed += 1
		end
	end
	return removed
end

function Lifecycle.windows(): {any}
	return windows
end

function Lifecycle.count(): number
	return #windows
end

--- Runs immediately if the hub is already closed, so a script that tears itself down and then
--- registers a cleanup still gets it.
function Lifecycle.onClose(fn: () -> ()): () -> ()
	if type(fn) ~= "function" then
		return function() end
	end

	if closed then
		local ok, err = pcall(fn)
		if not ok then
			warn("[Flux] close handler: " .. tostring(err))
		end
		return function() end
	end

	table.insert(closing, fn)

	return function()
		for index = #closing, 1, -1 do
			if closing[index] == fn then
				table.remove(closing, index)
				break
			end
		end
	end
end

function Lifecycle.isClosed(): boolean
	return closed
end

--- Destroy every window, release the shared maid, then run the close handlers. Returns how many
--- windows were torn down, which is what a host checks when it wants to know if its UI was live.
function Lifecycle.closeAll(): number
	local destroyed = 0

	-- Iterating a copy: a window's Destroy unregisters it from the live list.
	local snapshot = {}
	for index = 1, #windows do
		snapshot[index] = windows[index]
	end

	for _, window in ipairs(snapshot) do
		local ok, err = pcall(function()
			window:Destroy()
		end)
		if ok then
			destroyed += 1
		else
			warn("[Flux] window teardown: " .. tostring(err))
		end
	end

	table.clear(windows)
	shared:cleanup()

	-- Set before the handlers run: a handler that calls Unload must not recurse into itself.
	closed = true

	local handlers = closing
	closing = {}
	for _, fn in ipairs(handlers) do
		local ok, err = pcall(fn)
		if not ok then
			warn("[Flux] close handler: " .. tostring(err))
		end
	end

	return destroyed
end

--- Only a test or a host that intends to reopen the same library object can be un-closed.
function Lifecycle.reopen()
	closed = false
	shared = Maid.new()
end

function Lifecycle.reset()
	table.clear(windows)
	table.clear(closing)
	closed = false
	shared = Maid.new()
end

return Lifecycle
