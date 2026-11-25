--[[
	spec 11 — ConfigManager.

	Two promises hold this system together. A widget's value survives a restart, which means every
	staged value has to be JSON-representable and a burst of writes has to become one file write;
	and a client with no file api has to keep working, because that is the majority of the
	executors this library runs on.

	Both halves are tested: the file-backed path round-trips through the virtual filesystem, and
	the same calls are made again with the api switched off to prove nothing hangs or throws.
]]

local ConfigManager = assert(fluxRequire("Flux/Systems/ConfigManager"))
local ThemeManager = assert(fluxRequire("Flux/Systems/ThemeManager"))

local FOLDER = "FluxHub/SpecConfigs"

--- Each block starts from an empty store, the spec folder, and no bound rows.
local function fresh(body: () -> ())
	ConfigManager.configure({
		Name = "spec",
		Folder = FOLDER,
		Debounce = 0.5,
		AutoSave = true,
		SaveTheme = false,
	})
	ConfigManager.reset({ DeleteFile = false })

	local ok, err = pcall(body)

	-- A block that staged a value without stepping the clock leaves a debounce armed; flushing it
	-- here keeps the next block's pendingSave assertion about its own work.
	stepClock(1)
	ConfigManager.reset({ DeleteFile = false })
	fileApiOn = true
	assert(ok, err)
end

runSpec("configure, and where a name points", function()
	fresh(function()
		local settings = ConfigManager.configure({ Name = "aim", Debounce = 0.25 })
		checkEq(settings.Debounce, 0.25, "the debounce is settable")
		checkEq(ConfigManager.name(), "aim", "and so is the active config name")
		checkEq(ConfigManager.path(), FOLDER .. "/aim.json", "which decides the path")
		checkEq(ConfigManager.path("other"), FOLDER .. "/other.json", "until a call names another")

		ConfigManager.configure({ Name = " " })
		checkEq(ConfigManager.name(), "aim", "a blank name does not replace the working one")

		ConfigManager.configure({ Debounce = -5 })
		checkEq(ConfigManager.name(), "aim", "a negative debounce floors at zero")
		checkEq(ConfigManager.available(), true, "this client has the file api")
	end)
end)

runSpec("the store only holds what JSON can carry", function()
	fresh(function()
		checkEq(ConfigManager.set("fov", 90), true, "a number stages")
		checkEq(ConfigManager.set("name", "trinity"), true, "a string stages")
		checkEq(ConfigManager.set("lock", true), true, "a boolean stages")
		checkEq(ConfigManager.set("parts", { "Head", "Torso" }), true, "and a list stages")

		checkEq(ConfigManager.set("fn", function() end), false, "a function cannot be saved")
		checkEq(ConfigManager.set("thread", coroutine.create(function() end)), false, "nor a live thread")
		checkEq(ConfigManager.set("", 1), false, "and a key has to be a real string")
		checkEq(ConfigManager.get("", nil), nil, "nothing was stored under it")

		checkEq(ConfigManager.get("fov"), 90, "the value reads back")
		checkEq(ConfigManager.get("missing", "fallback"), "fallback", "and a miss takes the fallback")
		checkEq(ConfigManager.has("name"), true, "has reports presence")
		checkEq(ConfigManager.has("fn"), false, "including for the value that was refused")

		local snapshot = ConfigManager.data()
		snapshot.fov = 10
		checkEq(ConfigManager.get("fov"), 90, "data() is a copy, not the live table")

		local keys = ConfigManager.keys()
		checkEq(keys[1], "fov", "keys come back sorted")
		checkEq(#keys, 4, "and only the four that were accepted")
	end)
end)

runSpec("a drag writes once", function()
	fresh(function()
		for value = 1, 50 do
			ConfigManager.set("fov", value)
		end
		checkEq(ConfigManager.pendingSave(), true, "the save is waiting on the debounce")
		checkEq(ConfigManager.dirty(), true, "and the store says so")

		stepClock(0.4)
		checkEq(ConfigManager.pendingSave(), true, "0.4s in, nothing has been written yet")

		stepClock(0.2)
		checkEq(ConfigManager.pendingSave(), false, "the timer fired")
		checkEq(ConfigManager.dirty(), false, "and the store is clean")
		checkEq(ConfigManager.exists(), true, "one file exists")

		ConfigManager.reset({})
		local ok = ConfigManager.load()
		checkEq(ok, true, "the file loads")
		checkEq(ConfigManager.get("fov"), 50, "holding the last value of the drag, not the first")
	end)
end)

runSpec("immediate, autosave off, and the Saved signal", function()
	fresh(function()
		local saved = {}
		ConfigManager.Saved:Connect(function(path, wrote, reason)
			saved[#saved + 1] = { path = path, wrote = wrote, reason = reason }
		end)

		ConfigManager.set("now", 1, { Immediate = true })
		checkEq(ConfigManager.pendingSave(), false, "Immediate skipped the timer")
		checkEq(#saved, 1, "and reported the write")
		checkEq(saved[1].wrote, true, "which succeeded")
		checkEq(saved[1].path, FOLDER .. "/spec.json", "naming the file it wrote")

		ConfigManager.configure({ AutoSave = false })
		ConfigManager.set("later", 2)
		checkEq(ConfigManager.pendingSave(), false, "with AutoSave off nothing is scheduled")
		checkEq(ConfigManager.dirty(), true, "but the store knows it is unsaved")

		local ok, path = ConfigManager.save()
		checkEq(ok, true, "an explicit save writes it")
		checkEq(type(path), "string", "and returns the path")

		ConfigManager.configure({ AutoSave = true })
	end)
end)

runSpec("a theme travels with the config when asked", function()
	fresh(function()
		ThemeManager.set({ Accent = Color3.fromRGB(10, 200, 90), RowHeight = 41 })
		ConfigManager.configure({ SaveTheme = true })
		ConfigManager.set("fov", 90, { Immediate = true })

		ThemeManager.use("Blue")
		ConfigManager.reset({})
		checkEq(ConfigManager.load(), true, "the profile loads back")
		checkEq(ConfigManager.get("fov"), 90, "with its value")
		checkEq(ThemeManager.name(), "Dark", "the preset it was saved on top of comes back too")
		local accent = ThemeManager.color("Accent")
		checkEq(accent.R * 255 // 1, 10, "and the pinned accent came back, not Blue's")
		checkEq(ThemeManager.metric("RowHeight"), 41, "with the spacing the host had tuned")

		ConfigManager.configure({ SaveTheme = false })
	end)
end)

runSpec("bind, push and collect", function()
	fresh(function()
		ConfigManager.set("fov", 75)

		local applied = {}
		local unbind = ConfigManager.bind("fov", {
			Apply = function(value)
				applied[#applied + 1] = value
			end,
			Read = function()
				return 88
			end,
		})

		checkEq(#applied, 1, "binding a row to a stored value applies it immediately")
		checkEq(applied[1], 75, "with the value that was stored")

		ConfigManager.set("fov", 60)
		checkEq(ConfigManager.push("fov"), 1, "push reports how many rows it reached")
		checkEq(applied[2], 60, "and the row was told")

		ConfigManager.push()
		checkEq(#applied, 3, "a keyless push walks every bound row")

		unbind()
		ConfigManager.push("fov")
		checkEq(#applied, 3, "an unbound row is not woken again")
		unbind()

		local second = 0
		ConfigManager.bind("fov", {
			Apply = function()
				second += 1
			end,
			Read = function()
				return 88
			end,
		})
		checkEq(second, 1, "a row bound after the value exists still gets it")

		checkEq(ConfigManager.collect(), 1, "collect pulls from the rows that can report")
		checkEq(ConfigManager.get("fov"), 88, "the last binding's Read wins")

		ConfigManager.bind("boom", { Apply = function()
			error("row is broken")
		end })
		ConfigManager.set("boom", 2)
		checkEq(ConfigManager.push("boom"), 0, "a row whose Apply throws applies nothing")
		checkNoError(function()
			ConfigManager.push()
		end, "and the error never reaches the keystroke that triggered it")
	end)
end)

runSpec("a row built after the load still shows the saved state", function()
	fresh(function()
		ConfigManager.set("chams", true, { Immediate = true })
		ConfigManager.reset({})

		local shown = nil
		ConfigManager.bind("chams", { Apply = function(value)
			shown = value
		end })
		checkEq(shown, nil, "an empty store has nothing to hand a fresh row")

		checkEq(ConfigManager.load(), true, "the file loads")
		checkEq(shown, true, "and the row built before the load was pushed the value")
	end)
end)

runSpec("reset, delete and the file list", function()
	fresh(function()
		ConfigManager.set("fov", 90, { Immediate = true })
		checkEq(ConfigManager.exists(), true, "saved")

		ConfigManager.reset({ Defaults = { fov = 30 } })
		checkEq(ConfigManager.get("fov"), 30, "a default replaces what the file said")
		checkEq(ConfigManager.dirty(), false, "and resetting is not itself a change")

		ConfigManager.reset({ DeleteFile = true })
		checkEq(ConfigManager.exists(), false, "DeleteFile takes the file with it")
		checkEq(ConfigManager.load(), false, "so loading it now reports")
		checkEq(ConfigManager.reason(), "no config saved under that name yet", "with the reason")

		ConfigManager.configure({ Folder = FOLDER .. "/profiles" })
		ConfigManager.set("fov", 1, { Immediate = true })
		ConfigManager.configure({ Name = "second" })
		ConfigManager.set("fov", 2, { Immediate = true })

		local names = ConfigManager.names()
		checkEq(#names, 2, "two profiles in that folder")
		checkEq(names[1], "second", "listed in order, without the extension")
		checkEq(names[2], "spec", "both of them")

		checkEq(ConfigManager.exists("second"), true, "exists answers for a named profile")
		checkEq(ConfigManager.exists("nobody"), false, "and no for one never written")
		ConfigManager.configure({ Name = "spec", Folder = FOLDER })
	end)
end)

runSpec("a client with no file api keeps working", function()
	fresh(function()
		fileApiOn = false

		checkEq(ConfigManager.available(), false, "the api is missing")
		checkEq(ConfigManager.set("fov", 90), true, "staging still works")
		checkEq(ConfigManager.pendingSave(), false, "with no timer to arm")

		local ok, reason = ConfigManager.save()
		checkEq(ok, false, "saving says no")
		check(tostring(reason):find("file api", 1, true) ~= nil, "and explains why", tostring(reason))
		checkEq(ConfigManager.exists(), false, "nothing exists to find")
		checkEq(ConfigManager.load(), false, "and nothing to load")
		checkEq(#ConfigManager.names(), 0, "with no profiles listed")

		checkEq(ConfigManager.get("fov"), 90, "the value still lives for the session")
		fileApiOn = true
	end)
end)

runSpec("a file that is not a Flux config is refused", function()
	fresh(function()
		writefile(FOLDER .. "/spec.json", '{"values":{"fov":90}}')
		local ok, reason = ConfigManager.load()
		checkEq(ok, false, "a JSON file without the marker is not loaded")
		checkEq(reason, "the file is not a Flux config", "saying so")

		writefile(FOLDER .. "/spec.json", "this is not json at all")
		checkEq(ConfigManager.load(), false, "and garbage fails too")
		checkEq(ConfigManager.reason(), "the config could not be parsed", "with the parse reason")

		writefile(FOLDER .. "/spec.json", '{"__flux":true,"__version":99,"values":{"fov":12}}')
		ok = ConfigManager.load()
		checkEq(ok, true, "a config from another version still restores what it can")
		checkEq(ConfigManager.get("fov"), 12, "the value came through")
		check(tostring(ConfigManager.reason()):find("version", 1, true) ~= nil, "and the mismatch is reported", tostring(ConfigManager.reason()))
	end)
end)

runSpec("export and import move a config without the disk", function()
	fresh(function()
		ConfigManager.set("fov", 90)
		ConfigManager.set("lock", true)
		local json = ConfigManager.export()
		checkEq(type(json), "string", "export produces the JSON the file would hold")

		ConfigManager.reset({})
		checkEq(ConfigManager.get("fov"), nil, "the store is empty")

		local ok = ConfigManager.import(json)
		checkEq(ok, true, "pasting it back restores everything")
		checkEq(ConfigManager.get("fov"), 90, "the number")
		checkEq(ConfigManager.get("lock"), true, "and the boolean")

		local refused, why = ConfigManager.import("nonsense")
		checkEq(refused, false, "garbage is refused")
		checkEq(why, "not a Flux config", "with a reason")
		checkEq(ConfigManager.import(""), false, "and so is an empty string")
		checkEq(ConfigManager.get("fov"), 90, "the store survived both")
	end)
end)
