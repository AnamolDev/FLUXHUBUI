--[[
	Table — small functional helpers. Deliberately no generalized iteration here: the
	clients this library targets do not always accept `for k, v in tbl do`.
]]

local Table = {}

function Table.size(source: {[any]: any}): number
	local count = 0
	for _ in pairs(source) do
		count += 1
	end
	return count
end

function Table.keys(source: {[any]: any}): {any}
	local out = {}
	for key in pairs(source) do
		table.insert(out, key)
	end
	return out
end

function Table.values(source: {[any]: any}): {any}
	local out = {}
	for _, value in pairs(source) do
		table.insert(out, value)
	end
	return out
end

function Table.copy(source: {[any]: any}): {[any]: any}
	local out = {}
	for key, value in pairs(source) do
		out[key] = value
	end
	return out
end

function Table.deepCopy(source: any): any
	if type(source) ~= "table" then
		return source
	end

	local out = {}
	for key, value in pairs(source) do
		out[key] = Table.deepCopy(value)
	end
	return out
end

--- Fields from `defaults` that the caller omitted. Nil-on-purpose is preserved because a
--- component distinguishes "not supplied" from "supplied as false".
function Table.withDefaults(source: {[any]: any}?, defaults: {[any]: any}): {[any]: any}
	local out = Table.copy(defaults)
	for key, value in pairs(source or {}) do
		out[key] = value
	end
	return out
end

function Table.merge(...: {[any]: any}): {[any]: any}
	local out = {}
	for _, source in ipairs({ ... }) do
		for key, value in pairs(source) do
			out[key] = value
		end
	end
	return out
end

function Table.includes(list: {any}, value: any): boolean
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

function Table.indexOf(list: {any}, predicate: (any) -> boolean): number?
	for index, item in ipairs(list) do
		if predicate(item) then
			return index
		end
	end
	return nil
end

function Table.find(list: {any}, predicate: (any) -> boolean): any?
	for _, item in ipairs(list) do
		if predicate(item) then
			return item
		end
	end
	return nil
end

function Table.filter(list: {any}, predicate: (any) -> boolean): {any}
	local out = {}
	for _, item in ipairs(list) do
		if predicate(item) then
			table.insert(out, item)
		end
	end
	return out
end

function Table.map(list: {any}, fn: (any, number) -> any): {any}
	local out = {}
	for index, item in ipairs(list) do
		out[index] = fn(item, index)
	end
	return out
end

--- Insert keeping ascending order by a numeric key, without re-sorting the whole list.
function Table.insertSorted(list: {any}, item: any, compare: (any, any) -> boolean)
	local position = #list + 1
	for index = #list, 1, -1 do
		if compare(list[index], item) then
			position = index + 1
			break
		end
		position = index
	end
	table.insert(list, position, item)
end

function Table.reverse(list: {any}): {any}
	local out = {}
	for index = #list, 1, -1 do
		table.insert(out, list[index])
	end
	return out
end

return Table
