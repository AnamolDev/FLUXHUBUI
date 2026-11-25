--[[
	Core/Container — gives a container its component constructors.

	A groupbox, a modal body and a list row all take the same widgets, and each of them used to
	re-declare twenty forwarding methods. This attaches them once from the component index, so a
	new component exists on every container the moment it is listed there.

	Every constructor receives the container itself, which is what carries the Maid, the row
	parent and the search tracker. A component never reaches for a window directly.
]]

local Index = require("Flux/Components/Index")

local Container = {}
local loaded = nil

local function modules(): {[string]: any}
	if loaded == nil then
		loaded = {}
		for name, path in pairs(Index) do
			local ok, module = pcall(require, path)
			if ok and type(module) == "table" and type(module.new) == "function" then
				loaded[name] = module
			else
				warn(("[Flux] component '%s' (%s) failed to load: %s"):format(name, tostring(path), tostring(module)))
			end
		end
	end
	return loaded
end

--- Attach `Toggle`, `Slider`, … to `object`. `object` must expose Maid, Content and track().
function Container.decorate(object: any, context: {[string]: any}?)
	local available = modules()

	for name, module in pairs(available) do
		if object[name] == nil then
			object[name] = function(self: any, options: any)
				if self.Destroyed then
					warn(("[Flux] %s added to a destroyed container"):format(name))
					return nil
				end
				return module.new(self, options, context)
			end
		end
	end

	return object
end

function Container.names(): {string}
	local out = {}
	for name in pairs(modules()) do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function Container.has(name: string): boolean
	return modules()[name] ~= nil
end

--- Components register themselves at runtime too, which is how an optional widget in a host
--- script becomes available on every container without editing the index.
function Container.register(name: string, module: any): boolean
	if type(name) ~= "string" or type(module) ~= "table" or type(module.new) ~= "function" then
		warn("[Flux] component registration needs a name and a module with .new")
		return false
	end

	loaded = loaded or modules()
	loaded[name] = module
	Index[name] = Index[name] or ("custom/" .. name)
	return true
end

return Container
