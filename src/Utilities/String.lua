--[[
	String — display formatting, rich-text escaping, and the hex/colour conversions the
	colour picker and config export both need.
]]

local String = {}

function String.trim(value: string): string
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function String.lower(value: string): string
	return value:lower()
end

function String.startsWith(value: string, prefix: string): boolean
	return value:sub(1, #prefix) == prefix
end

function String.endsWith(value: string, suffix: string): boolean
	if suffix == "" then
		return true
	end
	return value:sub(-#suffix) == suffix
end

--- Splits on a literal separator and keeps empty fields, so "a,,b" yields three parts and a
--- config list with a blank entry round-trips instead of silently dropping it.
function String.split(value: string, separator: string): {string}
	local out = {}

	if separator == "" then
		table.insert(out, value)
		return out
	end

	local pattern = String.escapePattern(separator)
	local cursor = 1

	while true do
		local startAt, endAt = string.find(value, pattern, cursor, false)

		if startAt == nil then
			table.insert(out, string.sub(value, cursor))
			break
		end

		table.insert(out, string.sub(value, cursor, startAt - 1))
		cursor = endAt + 1
	end

	return out
end

--- Escape the five characters RichText treats as markup. Every string this library hands
--- to a RichText label goes through here first, so a config named `[100%] <b>fun</b>`
--- cannot inject markup into the menu.
function String.escape(value: string): string
	local result = tostring(value)
	result = result:gsub("&", "&amp;")
	result = result:gsub("<", "&lt;")
	result = result:gsub(">", "&gt;")
	result = result:gsub('"', "&quot;")
	result = result:gsub("'", "&apos;")
	return result
end

--- Escape Lua patterns so a user-typed search term is matched literally.
function String.escapePattern(value: string): string
	return value:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
end

--- Wrap the occurrences of `query` inside already-escaped `value` in a colour tag.
--- Returns the escaped text unchanged when the query does not match, so callers can show
--- a plain row without a second branch.
function String.highlight(escapedValue: string, query: string, colorHex: string): string
	if query == nil or query == "" then
		return escapedValue
	end

	local needle = query:lower()
	local haystack = escapedValue:lower()
	local out = {}
	local cursor = 1

	while true do
		local found = haystack:find(needle, cursor, true)
		if found == nil then
			table.insert(out, escapedValue:sub(cursor))
			break
		end

		table.insert(out, escapedValue:sub(cursor, found - 1))
		table.insert(
			out,
			"<font color=\"#" .. colorHex .. "\">" .. escapedValue:sub(found, found + #needle - 1) .. "</font>"
		)
		cursor = found + #needle
	end

	return table.concat(out)
end

function String.truncate(value: string, maximum: number, ellipsis: string?): string
	if #value <= maximum then
		return value
	end
	return value:sub(1, math.max(1, maximum - #(ellipsis or "..."))) .. (ellipsis or "...")
end

function String.padStart(value: string, width: number, char: string?): string
	local padChar = char or " "
	local out = value
	while #out < width do
		out = padChar .. out
	end
	return out
end

--- Colour3 -> "FF4F68".
function String.colorToHex(color: Color3): string
	local function component(value: number): string
		local scaled = math.floor(math.clamp(value, 0, 1) * 255 + 0.5)
		return String.padStart(("%02X"):format(scaled), 2, "0")
	end
	return component(color.R) .. component(color.G) .. component(color.B)
end

--- "FF4F68", "#FF4F68" or "255,79,104" -> Color3. Returns nil rather than a wrong colour.
function String.hexToColor(value: string): Color3?
	local text = String.trim(value):gsub("^#", "")

	local r, g, b = text:match("^(%x%x)(%x%x)(%x%x)$")
	if r ~= nil then
		return Color3.fromRGB(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
	end

	if #text == 6 then
		return nil
	end

	r, g, b = text:match("^(%d+),%s*(%d+),%s*(%d+)$")
	if r ~= nil then
		return Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b))
	end
	return nil
end

--- "LeftShift" -> "L-Shift", "MouseButton2" -> "MB2". Key labels are shown to players, so
--- the engine names are rewritten rather than printed raw.
local KEY_OVERRIDES = {
	Space = "Space",
	LeftControl = "L-Ctrl",
	RightControl = "R-Ctrl",
	LeftShift = "L-Shift",
	RightShift = "R-Shift",
	LeftAlt = "L-Alt",
	RightAlt = "R-Alt",
	MouseButton1 = "MB1",
	MouseButton2 = "MB2",
	MouseButton3 = "MB3",
}

function String.keyName(value: any): string
	if value == nil then
		return "None"
	end

	local name
	if typeof(value) == "EnumItem" then
		name = value.Name
	elseif type(value) == "table" and type(value.Name) == "string" then
		-- A keybind restored from a config file is a table, not a live EnumItem.
		name = value.Name
	else
		name = tostring(value)
	end

	local override = KEY_OVERRIDES[name]
	if override ~= nil then
		return override
	end

	name = name:gsub("^Left", "L-"):gsub("^Right", "R-"):gsub("^MouseButton", "MB")
	name = name:gsub("^Key", "")
	name = name:gsub("^Digit", "")
	return name
end

--- Strip characters a Roblox font cannot draw. Emoji render as hollow boxes, and universe
--- names contain them, so any fetched name is filtered before it reaches a label.
function String.stripUnsupported(value: string): string
	local out = tostring(value)
	out = out:gsub("[\240-\247][\128-\191][\128-\191][\128-\191]", "")
	out = out:gsub("\\u[Dd][89ABab]%x%x", "")
	out = out:gsub("[\128-\191]", "")
	out = out:gsub("%[%s*%]", "")
	return String.trim(out)
end

return String
