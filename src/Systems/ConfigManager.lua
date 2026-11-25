--[[
	Systems/ConfigManager — save, restore, and the ordering problem in between.

	The hard part is not JSON, it is that this library builds rows lazily while a config is loaded
	once at startup. A value read before its row exists would be dropped, and a row built after a
	load would show the default. So the store and the bindings are separate: values live in `data`
	first, bindings only observe them, and a row that registers late is handed the stored value
	immediately.

	The file api is optional. A client without writefile keeps everything in memory for the session
	and reports why through `Config.reason()` — the UI says "saving is unavailable here" instead of
	failing on a save button.
]]

local Signal = require("Flux/Utilities/Signal")
local Guard = require("Flux/Utilities/Guard")
local Table = require("Flux/Utilities/Table")
local ThemeManager = require("Flux/Systems/ThemeManager")

local HttpService = Guard.service("HttpService")

local ConfigManager = {}

--- Fired (key, value) after a load or a reset changes something a bound row is showing.
ConfigManager.Changed = Signal.new()
--- Fired (path, ok, reason) whenever a write is attempted.
ConfigManager.Saved = Signal.new()

local settings = {
	Name = "default",
	Folder = "FluxHub/Configs",
	Version = 1,
	Debounce = 0.5,
	AutoSave = true,
	SaveTheme = true,
}

--- Values by key. Lives here rather than in the widgets so a value exists before its row does.
local data: {[string]: any} = {}
local bindings: {[string]: {any}} = {}

local loaded = false
local dirty = false
local saveThread: thread? = nil
local lastReason: string? = nil
local lastError: string? = nil

--- Whether this client can actually be asked for a file. Some executors define the names and then
--- raise on every call, so a type check alone would promise a disk that is not there; the probe is
--- the same question `save` would ask.
local function hasFileApi(): boolean
	if type(isfile) ~= "function" or type(writefile) ~= "function" or type(readfile) ~= "function" then
		return false
	end
	return pcall(isfile, ConfigManager.path(".probe")) == true
end

function ConfigManager.available(): boolean
	return hasFileApi()
end

function ConfigManager.configure(options: { Name: string?, Folder: string?, Debounce: number?, AutoSave: boolean?, SaveTheme: boolean? })
	options = options or {}
	if type(options.Name) == "string" and options.Name:match("%S") ~= nil then
		-- A name of only spaces would produce a path the file api cannot be trusted with.
		settings.Name = options.Name
	end
	if type(options.Folder) == "string" then
		settings.Folder = options.Folder
	end
	if type(options.Debounce) == "number" then
		settings.Debounce = math.max(0, options.Debounce)
	end
	if options.AutoSave ~= nil then
		settings.AutoSave = options.AutoSave == true
	end
	if options.SaveTheme ~= nil then
		settings.SaveTheme = options.SaveTheme == true
	end
	return settings
end

function ConfigManager.name(): string
	return settings.Name
end

function ConfigManager.path(name: string?): string
	return settings.Folder .. "/" .. (name or settings.Name) .. ".json"
end

--- Why the last save or load did not happen. nil means nothing went wrong.
function ConfigManager.reason(): string?
	return lastReason
end

function ConfigManager.error(): string?
	return lastError
end

--- A value must be JSON-representable or a config written today will not read back tomorrow.
local function encodable(value: any): boolean
	local kind = type(value)
	return kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" or kind == "table"
end

--- Stage a value. Rows call this on every interaction; the disk sees one write per burst.
function ConfigManager.set(key: string, value: any, options: { Immediate: boolean? }): boolean
	if type(key) ~= "string" or key == "" then
		warn("[Flux] config: a key must be a non-empty string")
		return false
	end
	if not encodable(value) then
		warn(("[Flux] config: '%s' holds a %s, which cannot be stored"):format(tostring(key), type(value)))
		return false
	end

	data[key] = value

	dirty = true
	if settings.AutoSave then
		ConfigManager.scheduleSave(options)
	end
	return true
end

function ConfigManager.get(key: string, fallback: any): any
	local value = data[key]
	if value == nil then
		return fallback
	end
	return value
end

function ConfigManager.has(key: string): boolean
	return data[key] ~= nil
end

function ConfigManager.keys(): {string}
	local out = {}
	for key in pairs(data) do
		table.insert(out, key)
	end
	table.sort(out)
	return out
end

function ConfigManager.data(): {[string]: any}
	return Table.deepCopy(data)
end

--- Re-arm the debounce timer. A slider dragged across two hundred values produces one write.
function ConfigManager.scheduleSave(options: { Immediate: boolean? })
	if options ~= nil and options.Immediate then
		ConfigManager.save()
		return
	end

	if not hasFileApi() then
		-- A timer that would only fail to write is worse than no timer: the store stays dirty and
		-- an explicit save carries the reason.
		return
	end

	if saveThread ~= nil then
		task.cancel(saveThread)
	end

	if settings.Debounce <= 0 then
		saveThread = task.defer(function()
			saveThread = nil
			ConfigManager.save()
		end)
		return
	end

	saveThread = task.delay(settings.Debounce, function()
		saveThread = nil
		ConfigManager.save()
	end)
end

function ConfigManager.pendingSave(): boolean
	return saveThread ~= nil
end

local function encode(payload: {[string]: any}): string?
	if HttpService == nil then
		return nil
	end
	local ok, json = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if ok and type(json) == "string" then
		return json
	end
	lastError = "the client could not encode JSON"
	return nil
end

local function decode(json: string): {[string]: any}?
	if HttpService == nil then
		return nil
	end
	local ok, payload = pcall(function()
		return HttpService:JSONDecode(json)
	end)
	if ok and type(payload) == "table" then
		return payload
	end
	lastError = "the file is not valid JSON"
	return nil
end

--- Write the staged values. Returns whether a file changed.
function ConfigManager.save(name: string?): (boolean, string?)
	if not hasFileApi() then
		lastReason = "this client has no file api, so the config lives in memory for the session"
		ConfigManager.Saved:Dispatch(ConfigManager.path(name), false, lastReason)
		return false, lastReason
	end

	if name ~= nil then
		settings.Name = name
	end

	if settings.SaveTheme then
		data["__theme"] = ThemeManager.snapshot()
	end

	local payload = {
		__flux = true,
		__version = settings.Version,
		__saved = os.time(),
		values = data,
	}

	local json = encode(payload)
	if json == nil then
		lastReason = "the client could not encode the config"
		return false, lastReason
	end

	local path = ConfigManager.path()
	local ok, err = pcall(function()
		if not isfile(settings.Folder) and not isfolder(settings.Folder) then
			makefolder(settings.Folder)
		end
		writefile(path, json)
	end)

	if not ok then
		lastReason = "the write was refused"
		lastError = tostring(err)
		ConfigManager.Saved:Dispatch(path, false, lastReason)
		return false, lastReason
	end

	dirty = false
	lastReason = nil
	ConfigManager.Saved:Dispatch(path, true, nil)
	return true, path
end

--- Read a file into the store and push every value its rows care about.
--- Returns (ok, reason).
function ConfigManager.load(name: string?): (boolean, string?)
	if name ~= nil and type(name) == "string" and name:match("%S") ~= nil then
		settings.Name = name
	end

	if not hasFileApi() then
		lastReason = "this client has no file api"
		return false, lastReason
	end

	local path = ConfigManager.path()
	local ok, contents = pcall(function()
		if not isfile(path) then
			return nil
		end
		return readfile(path)
	end)

	if not ok then
		lastReason = "the read was refused"
		lastError = tostring(contents)
		return false, lastReason
	end

	if contents == nil or contents == "" then
		lastReason = "no config saved under that name yet"
		return false, lastReason
	end

	local payload = decode(tostring(contents))
	if payload == nil then
		lastReason = "the config could not be parsed"
		return false, lastReason
	end

	if payload.__flux ~= true then
		lastReason = "the file is not a Flux config"
		return false, lastReason
	end

	if payload.__version ~= nil and payload.__version ~= settings.Version then
		-- Reported, not fatal: a config from an older build should still restore what it can.
		lastReason = "saved by version " .. tostring(payload.__version)
	end

	local values = type(payload.values) == "table" and payload.values or {}
	table.clear(data)
	for key, value in pairs(values) do
		data[key] = value
	end

	if type(data.__theme) == "table" then
		ThemeManager.restore(data.__theme)
	end

	loaded = true
	dirty = false
	ConfigManager.push()
	return true, path
end

--- Push every stored value into the rows bound to it. Called after a load and after a bind, so a
--- row built after the file was read still shows the saved state.
function ConfigManager.push(key: string?): number
	local applied = 0
	local targets = key ~= nil and { [key] = bindings[key] } or bindings

	for boundKey, list in pairs(targets) do
		local value = data[boundKey]
		if list ~= nil then
			for _, binding in ipairs(list) do
				if value ~= nil then
					local ok, err = pcall(binding.apply, value)
					if ok then
						applied += 1
					else
						warn(("[Flux] config: '%s' could not apply to a row: %s"):format(boundKey, tostring(err)))
					end
				end
			end
		end
	end

	return applied
end

--- Bind a row to a key. Returns an unbind, and applies the stored value now if there is one.
---   Apply — set the widget from the restored value.
---   Read  — report the widget's current value for saving.
function ConfigManager.bind(key: string, handlers: { Apply: (any) -> (), Read: (() -> any)? }): () -> ()
	local binding = { key = key, apply = handlers.Apply, read = handlers.Read }
	local list = bindings[key]
	if list == nil then
		list = {}
		bindings[key] = list
	end
	table.insert(list, binding)

	if data[key] ~= nil then
		local ok, err = pcall(handlers.Apply, data[key])
		if not ok then
			warn(("[Flux] config: bind '%s' threw: %s"):format(key, tostring(err)))
		end
	end

	local unbound = false
	return function()
		if unbound then
			return
		end
		unbound = true
		for index = #list, 1, -1 do
			if list[index] == binding then
				table.remove(list, index)
			end
		end
	end
end

--- Pull every row's live value into the store. Called before an explicit save so a save button
--- writes what the user sees, not what they saw when the page was built.
function ConfigManager.collect(): number
	local collected = 0
	for key, list in pairs(bindings) do
		local binding = list[#list]
		if binding ~= nil and binding.read ~= nil then
			local ok, value = pcall(binding.read)
			if ok then
				data[key] = value
				collected += 1
			end
		end
	end
	return collected
end

--- Forget everything: the store, the file, and what the rows are showing.
function ConfigManager.reset(options: { DeleteFile: boolean?, Defaults: {[string]: any}? })
	options = options or {}
	table.clear(data)

	if type(options.Defaults) == "table" then
		for key, value in pairs(options.Defaults) do
			data[key] = value
		end
	end

	if options.DeleteFile and hasFileApi() then
		pcall(function()
			local path = ConfigManager.path()
			if isfile(path) then
				delfile(path)
			end
		end)
	end

	dirty = false
	ConfigManager.push()
	return true
end

function ConfigManager.loaded(): boolean
	return loaded
end

function ConfigManager.dirty(): boolean
	return dirty
end

--- Names of the configs saved on this machine, for a "load profile" dropdown.
function ConfigManager.names(): {string}
	local out = {}
	if not hasFileApi() or type(listfiles) ~= "function" then
		return out
	end

	-- Executors disagree about the shape of listfiles: some return an array of paths, some take a
	-- callback and return nothing, and generalized iteration is newer Luau than several of these
	-- clients run. Both callable shapes are tried; neither is required.
	local function collect(entry: any)
		local name = tostring(entry)
		if name:sub(-5) == ".json" then
			table.insert(out, name:match("([^/\\]+)%.json$") or name)
		end
	end

	local ok, result = pcall(listfiles, settings.Folder)
	if ok and type(result) == "table" then
		for _, entry in ipairs(result) do
			collect(entry)
		end
	else
		local called = pcall(function()
			listfiles(settings.Folder, collect)
		end)
		if not called then
			lastError = "listfiles is not usable on this client"
		end
	end

	table.sort(out)
	return out
end

function ConfigManager.exists(name: string?): boolean
	if not hasFileApi() then
		return false
	end
	local ok, found = pcall(isfile, ConfigManager.path(name))
	return ok and found == true
end

--- The JSON the config file would hold right now, for a clipboard export on a client without one.
function ConfigManager.export(): string?
	local payload = {
		__flux = true,
		__version = settings.Version,
		values = data,
	}
	return encode(payload)
end

--- Restore from a JSON string the user pasted, which is how a config moves between machines.
function ConfigManager.import(json: string): (boolean, string?)
	if type(json) ~= "string" or json == "" then
		return false, "nothing to import"
	end
	local payload = decode(json)
	if payload == nil or payload.__flux ~= true then
		return false, "not a Flux config"
	end

	table.clear(data)
	for key, value in pairs(type(payload.values) == "table" and payload.values or {}) do
		data[key] = value
	end
	if type(data.__theme) == "table" then
		ThemeManager.restore(data.__theme)
	end
	ConfigManager.push()
	return true, "imported"
end

return ConfigManager
