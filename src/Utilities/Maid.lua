--[[
	Maid — ownership list for everything a component must release.

	`Flux:Unload()` walks the maid tree, so a component that forgot to register a
	connection is the only way a leak can happen. Tasks are accepted in every shape the
	library produces: RBXScriptConnection, Signal connection, Instance, thread, function.
]]

type Maid = {
	giveTask: (Maid, any) -> any,
	giveFunction: (Maid, () -> ()) -> (),
	giveConnection: (Maid, any) -> any,
	giveInstance: (Maid, any) -> any,
	giveThread: (Maid, thread) -> any,
	chain: (Maid, Maid) -> Maid,
	cleanup: (Maid) -> (),
	Destroy: (Maid) -> (),
}

local Maid = {}
Maid.__index = Maid

function Maid.new(): Maid
	return setmetatable({ _tasks = {} }, Maid) :: any
end

function Maid.giveTask(self: Maid, item: any): any
	if item == nil then
		return nil
	end

	table.insert(self._tasks, item)
	return item
end

function Maid.giveFunction(self: Maid, fn: () -> ())
	return Maid.giveTask(self, { type = "function", fn = fn })
end

function Maid.giveConnection(self: Maid, connection: any)
	return Maid.giveTask(self, { type = "connection", instance = connection })
end

function Maid.giveInstance(self: Maid, instance: any)
	return Maid.giveTask(self, { type = "instance", instance = instance })
end

function Maid.giveThread(self: Maid, thread: thread)
	return Maid.giveTask(self, { type = "thread", instance = thread })
end

--- The short name component code uses; giveTask is the same thing under its explicit name.
Maid.give = Maid.giveTask

--- A child maid that is cleaned up with this one but can be cleaned up early on its own.
function Maid.chain(self: Maid, child: Maid): Maid
	Maid.giveTask(self, { type = "maid", instance = child })
	return child
end

-- The parameter is `item`, never `task`: a name collision with the global task library
-- would break thread cancellation.
local function runItem(item: any)
	if type(item) == "function" then
		local ok, err = pcall(item)
		if not ok then
			warn("[Flux] cleanup: " .. tostring(err))
		end
		return
	end

	if type(item) ~= "table" then
		return
	end

	local kind = item.type

	if kind == "maid" then
		item.instance:cleanup()
		return
	end

	if kind == "function" then
		local ok, err = pcall(item.fn)
		if not ok then
			warn("[Flux] cleanup: " .. tostring(err))
		end
		return
	end

	local instance = item.instance
	if instance == nil then
		return
	end

	if kind == "thread" then
		if coroutine.status(instance) ~= "dead" then
			task.cancel(instance)
		end
		return
	end

	-- Connections and Instances both expose Destroy.
	local ok, err = pcall(function()
		instance:Destroy()
	end)
	if not ok then
		warn("[Flux] cleanup (" .. typeof(instance) .. "): " .. tostring(err))
	end
end

function Maid.cleanup(self: Maid)
	local tasks = self._tasks
	self._tasks = {}

	for index = #tasks, 1, -1 do
		local ok, err = pcall(runItem, tasks[index])
		if not ok then
			warn("[Flux] cleanup: " .. tostring(err))
		end
	end
end

Maid.Destroy = Maid.cleanup

return Maid
