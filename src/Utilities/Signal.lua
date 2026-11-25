--[[
	Signal — a minimal, allocation-light event.

	Used by every component for its public `Changed`/`Clicked` events and internally by
	the theme and lifecycle systems. Dispatch iterates a snapshot so a handler may
	connect or disconnect during the same dispatch without corrupting the loop.
]]

type Connection = {
	Disconnect: (Connection) -> (),
	Destroy: (Connection) -> (),
}

export type Signal = {
	Connect: (Signal, (...any) -> ()) -> Connection,
	Once: (Signal, (...any) -> ()) -> Connection,
	Dispatch: (Signal, ...any) -> (),
	Wait: (Signal) -> ...any,
	GetConnectionCount: (Signal) -> number,
	Destroy: (Signal) -> (),
}

local Signal = {}
Signal.__index = Signal

local function newConnection(fn: (...any) -> (), once: boolean, signal)
	local self: Connection
	local connected = true

	local function disconnect()
		if not connected then
			return
		end
		connected = false
		local list = signal._connections
		for index = #list, 1, -1 do
			if list[index] == self then
				table.remove(list, index)
				break
			end
		end
	end

	self = {
		_fn = fn,
		_once = once,
		_connected = function()
			return connected
		end,
		Disconnect = disconnect,
		-- Maid releases connections through Destroy, the same name an RBXScriptConnection
		-- answers with. Without it, a component torn down through its maid would keep firing.
		Destroy = disconnect,
	}

	table.insert(signal._connections, self)
	return self
end

function Signal.new(): Signal
	local self = setmetatable({ _connections = {} }, Signal) :: any
	return self
end

function Signal.Connect(self: Signal, fn: (...any) -> ()): Connection
	return newConnection(fn, false, self)
end

function Signal.Once(self: Signal, fn: (...any) -> ()): Connection
	return newConnection(fn, true, self)
end

function Signal.Dispatch(self: Signal, ...: any)
	local snapshot = {}
	local connections = self._connections
	for index = 1, #connections do
		snapshot[index] = connections[index]
	end

	for index = 1, #snapshot do
		local connection = snapshot[index]
		if connection._connected() then
			if connection._once then
				connection:Disconnect()
			end

			-- An RBXScriptSignal runs each handler protected, so one bad callback cannot stop
			-- the others. A theme repaint touches every bound widget at once: without this,
			-- one component with a nil reference would leave half the menu unstyled.
			local ok, err = pcall(connection._fn, ...)
			if not ok then
				warn("[Flux] signal handler: " .. tostring(err))
			end
		end
	end
end

function Signal.Wait(self: Signal): ...any
	local boundEvent = Instance.new("BindableEvent")
	local payload = nil
	local filled = false

	local connection = self:Connect(function(...)
		payload = table.pack(...)
		filled = true
		boundEvent:Fire()
	end)

	if not filled then
		boundEvent.Event:Wait()
	end

	connection:Disconnect()
	boundEvent:Destroy()

	if payload == nil then
		return nil
	end
	return table.unpack(payload, 1, payload.n)
end

function Signal.GetConnectionCount(self: Signal): number
	return #self._connections
end

function Signal.Destroy(self: Signal)
	local connections = self._connections
	for index = #connections, 1, -1 do
		connections[index]:Disconnect()
	end

	-- Emptied, not nilled: a widget that dispatches after teardown is a real race during a
	-- window close, and it must be a no-op rather than an error inside the handler loop.
	table.clear(connections)
end

return Signal
