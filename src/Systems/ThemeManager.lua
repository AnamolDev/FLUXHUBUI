--[[
	Systems/ThemeManager — the live token table and the rebind list that makes a theme swap
	restyle the UI without rebuilding it.

	Components never store a Color3; they bind an instance property to a role name. A theme
	change walks the bindings and writes. That is what lets `Flux:SetTheme` repaint a menu
	that is already open, and it is why no component hardcodes a hex anywhere.
]]

local Signal = require("Flux/Utilities/Signal")
local Guard = require("Flux/Utilities/Guard")
local String = require("Flux/Utilities/String")
local Theme = require("Flux/Assets/Theme")

local ThemeManager = {}

local current = {
	colors = {},
	metrics = {},
	fonts = {},
	name = Theme.defaultPreset,
}

local bindings = {}
local callbacks = {}
local validRoles = {}

--- Values the host pinned on top of a preset, kept so a preset switch can re-apply them.
--- Only spacing and fonts belong here: a colour preset owns its palette, so `SetTheme("Purple")`
--- must be able to move the accent the host previously tuned. Assets/Theme builds every colour
--- preset from Dark's metric table, so without this layer a colour change would silently undo
--- `SetTheme{RadiusPanel=4}`.
local pinned = {
	metrics = {},
	fonts = {},
}

for _, role in ipairs(Theme.colorRoles) do
	validRoles[role] = "color"
end
for _, role in ipairs(Theme.metricRoles) do
	validRoles[role] = "metric"
end

ThemeManager.Changed = Signal.new()
ThemeManager.presets = Theme.presets

local function cloneInto(target: {[string]: any}, source: {[string]: any})
	for key, value in pairs(source) do
		target[key] = value
	end
end

local function loadPreset(name: string): boolean
	local preset = Theme.presets[name]
	if preset == nil then
		return false
	end

	table.clear(current.colors)
	table.clear(current.metrics)
	table.clear(current.fonts)
	cloneInto(current.colors, preset.colors)
	cloneInto(current.metrics, preset.metrics)
	cloneInto(current.fonts, preset.fonts)

	-- The host's spacing and fonts win over the preset's; its colours do not, because the palette
	-- is exactly what a preset is for.
	cloneInto(current.metrics, pinned.metrics)
	cloneInto(current.fonts, pinned.fonts)

	current.name = name
	return true
end

--- Bind an instance property to a colour/metric role. Returns an unbind function, which
--- every component hands to its Maid so a destroyed row cannot linger in the list.
function ThemeManager.bind(instance: any, property: string, role: string): () -> ()
	if validRoles[role] == nil then
		warn(("[Flux] theme: unknown role '%s' (check Theme.colorRoles / Theme.metricRoles)"):format(tostring(role)))
		return function() end
	end

	local entry = { instance = instance, property = property, role = role }
	table.insert(bindings, entry)

	-- Paint immediately as well as registering: a component binds while it is being built, and
	-- without this the widget shows the engine default until the next theme change repaints it.
	local kind = validRoles[role]
	local value = nil
	if kind == "color" then
		value = current.colors[role]
	else
		value = current.metrics[role]
	end

	if value ~= nil then
		Guard.set(instance, property, value)
	end

	return function()
		for index = #bindings, 1, -1 do
			if bindings[index] == entry then
				table.remove(bindings, index)
				break
			end
		end
	end
end

--- For anything a single property write cannot express: gradients, stroke colour paired
--- with transparency, a size that depends on two roles.
---
--- `roles` is an optimisation hint, not a subscription filter that can silence the callback: a
--- function bound to { "Accent" } still runs whenever Accent moves, and one bound to nothing runs
--- on every repaint.
function ThemeManager.bindFn(fn: (current: {[string]: any}) -> (), roles: {string}?): () -> ()
	local entry = { fn = fn, roles = roles, seen = nil }

	if roles ~= nil then
		entry.seen = {}
		for _, role in ipairs(roles) do
			entry.seen[role] = ThemeManager.valueOf(role)
		end
	end

	table.insert(callbacks, entry)
	fn(current)

	return function()
		for index = #callbacks, 1, -1 do
			if callbacks[index] == entry then
				table.remove(callbacks, index)
				break
			end
		end
	end
end

function ThemeManager.valueOf(role: string): any
	if validRoles[role] == "color" then
		return current.colors[role]
	end
	if validRoles[role] == "metric" then
		return current.metrics[role]
	end
	return current.fonts[role]
end

--- Write every binding now. Instances whose parent is gone are dropped instead of
--- accumulating, which is how a theme swap stays O(alive UI) rather than O(everything built).
local function repaint()
	local index = 1
	while index <= #bindings do
		local entry = bindings[index]
		local instance = entry.instance

		local alive = false
		if instance ~= nil then
			local ok, parent = pcall(function()
				return instance.Parent
			end)
			alive = ok and parent ~= nil
		end

		if not alive then
			table.remove(bindings, index)
		else
			local role = entry.role
			local kind = validRoles[role]
			local value = nil
			if kind == "color" then
				value = current.colors[role]
			else
				value = current.metrics[role]
			end

			if value ~= nil then
				if not Guard.set(instance, entry.property, value) then
					table.remove(bindings, index)
				else
					index += 1
				end
			else
				index += 1
			end
		end
	end

	for _, entry in ipairs(callbacks) do
		local run = entry.roles == nil
		if not run then
			-- A role list means "only wake me when one of these moves", which is why the previous
			-- values are remembered: without it, a hovered row re-paints on every unrelated token.
			for _, role in ipairs(entry.roles) do
				local now = ThemeManager.valueOf(role)
				if now ~= nil and entry.seen[role] ~= now then
					run = true
					entry.seen[role] = now
				end
			end
		end

		if run then
			entry.fn(current)
		end
	end

	ThemeManager.Changed:Dispatch(current)
end

--- `Flux:SetTheme({ Accent = Color3.fromRGB(...) })` — overrides on top of the live table.
---
--- Values are normalised rather than type-tested with `type()`: a Color3 is userdata, so
--- `type(value) == "Color3"` is never true on the engine. A theme payload can arrive from a
--- config file, where colours are hex strings or number triples, so all three are accepted.
function ThemeManager.coerceColor(value: any): Color3?
	if typeof(value) == "Color3" then
		return value
	end

	if type(value) == "string" then
		return String.hexToColor(value)
	end

	if type(value) == "table" then
		if type(value.R) == "number" then
			return Color3.fromRGB(math.floor(value.R * 255 + 0.5), math.floor(value.G * 255 + 0.5), math.floor(value.B * 255 + 0.5))
		end
		if type(value[1]) == "number" then
			return Color3.fromRGB(value[1], value[2] or 0, value[3] or 0)
		end
	end

	return nil
end

function ThemeManager.coerceFont(value: any): Enum.Font?
	if typeof(value) == "EnumItem" then
		return value :: any
	end

	local name = nil
	if type(value) == "table" and type(value.Name) == "string" then
		name = value.Name
	elseif type(value) == "string" then
		name = value
	end

	if name == nil then
		return nil
	end

	-- Enum.Font has no member for a name this client's font list does not carry, and indexing a
	-- missing one raises; Guard.get returns nil instead, which is what font() then floors to Gotham.
	local found = Guard.get(Enum.Font, name)
	if found == nil then
		return nil
	end
	return found :: any
end

function ThemeManager.set(overrides: {[string]: any})
	for key, value in pairs(overrides) do
		local color = ThemeManager.coerceColor(value)
		if color ~= nil then
			current.colors[key] = color
		elseif type(value) == "number" then
			current.metrics[key] = value
			pinned.metrics[key] = value
		elseif key == "colors" and type(value) == "table" then
			-- A restored palette arrives as hex strings and 0-255 triples, not live Color3s, so
			-- the group is coerced entry by entry: cloning it raw would leave a table sitting
			-- where every component expects a Color3.
			local missed = false
			for role, stored in pairs(value) do
				local coerced = ThemeManager.coerceColor(stored)
				if coerced ~= nil then
					current.colors[tostring(role)] = coerced
				else
					missed = true
				end
			end
			if missed then
				warn("[Flux] theme: some entries in the colors group were not colours")
			end
		elseif key == "metrics" and type(value) == "table" then
			for role, number in pairs(value) do
				if type(number) == "number" then
					current.metrics[tostring(role)] = number
					pinned.metrics[tostring(role)] = number
				else
					warn(("[Flux] theme: metric '%s' is not a number"):format(tostring(role)))
				end
			end
		elseif key == "fonts" and type(value) == "table" then
			for role, font in pairs(value) do
				local coerced = ThemeManager.coerceFont(font)
				if coerced ~= nil then
					current.fonts[role] = coerced
					pinned.fonts[role] = coerced
				end
			end
		else
			local font = ThemeManager.coerceFont(value)
			if font ~= nil then
				current.fonts[key] = font
				pinned.fonts[key] = font
			else
				warn(("[Flux] theme: '%s' is not a colour, a number, a font, or one of colors/metrics/fonts"):format(tostring(key)))
			end
		end
	end

	repaint()
	return current
end

--- Switch wholesale to a named preset. Unknown names are a caller error, not a silent no-op.
function ThemeManager.use(presetName: string): boolean
	if not loadPreset(presetName) then
		warn("[Flux] theme: no preset named " .. tostring(presetName))
		return false
	end
	repaint()
	return true
end

function ThemeManager.name(): string
	return current.name
end

function ThemeManager.color(role: string): Color3
	return current.colors[role]
end

function ThemeManager.metric(role: string): number
	return current.metrics[role]
end

function ThemeManager.font(role: string): Enum.Font
	local font = current.fonts[role]
	if font == nil then
		return Enum.Font.Gotham
	end

	-- A font enum member can be absent on an older client; Gotham is the floor.
	if not Guard.has(Enum.Font, font.Name) then
		return Enum.Font.Gotham
	end
	return font
end

function ThemeManager.snapshot(): {[string]: any}
	return {
		name = current.name,
		colors = ThemeManager.exportColors(),
		metrics = ThemeManager.exportMetrics(),
		fonts = ThemeManager.exportFonts(),
	}
end

--- Colours leave as 0-255 triples, not the engine's 0-1 floats, because that is the shape a
--- person writes by hand in a config file and the shape restore() and coerceColor() expect.
--- Feeding Color3.R straight into Color3.fromRGB is how a theme round-trips to black.
function ThemeManager.exportColors(): {[string]: {number}}
	local out = {}
	for role, color in pairs(current.colors) do
		local r, g, b = Guard.get(color, "R"), Guard.get(color, "G"), Guard.get(color, "B")
		if r ~= nil then
			out[role] = {
				math.floor(r * 255 + 0.5),
				math.floor((g or 0) * 255 + 0.5),
				math.floor((b or 0) * 255 + 0.5),
			}
		end
	end
	return out
end

function ThemeManager.exportMetrics(): {[string]: number}
	local out = {}
	for role, value in pairs(current.metrics) do
		out[role] = value
	end
	return out
end

function ThemeManager.exportFonts(): {[string]: string}
	local out = {}
	for role, font in pairs(current.fonts) do
		local name = Guard.get(font, "Name")
		if type(name) == "string" then
			out[role] = name
		end
	end
	return out
end

--- Restores a snapshot taken by exportColors/exportMetrics; used by the config system.
function ThemeManager.restore(snapshot: {[string]: any})
	if snapshot == nil then
		return false
	end

	-- A snapshot is the whole look, so the pins it was taken alongside are dropped first:
	-- otherwise a value the file no longer carries would survive the restore and re-appear on
	-- the next preset switch.
	ThemeManager.forgetOverrides()

	if type(snapshot.name) == "string" then
		loadPreset(snapshot.name)
	end

	-- Routed through set(), which coerces hex strings and 0-255 triples, validates the metric
	-- group, and pins spacing and fonts the way an in-session SetTheme call does.
	local payload: {[string]: any} = {}
	if type(snapshot.colors) == "table" then
		payload.colors = snapshot.colors
	end
	if type(snapshot.metrics) == "table" then
		payload.metrics = snapshot.metrics
	end
	if type(snapshot.fonts) == "table" then
		payload.fonts = snapshot.fonts
	end

	if next(payload) ~= nil then
		ThemeManager.set(payload)
	end

	repaint()
	return true
end

--- Forgets the spacing and fonts the host pinned over its presets.
function ThemeManager.forgetOverrides()
	table.clear(pinned.metrics)
	table.clear(pinned.fonts)
end

function ThemeManager.bindingCount(): number
	return #bindings
end

loadPreset(Theme.defaultPreset)

return ThemeManager
