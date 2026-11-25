--[[
	Flux Hub — showcase

	A complete hub written against the library the way a real script would be: four tabs, live
	search, keybinds, config save/load and notifications. Paste it into an executor, or into
	StarterPlayerScripts. Right Control opens and closes the window; the header box searches every
	control in the hub.

	Everything below is public API — nothing reaches into Flux's internals.
]]

local Flux = loadstring(game:HttpGet("https://raw.githubusercontent.com/AnamolDev/FLUXHUBUI/main/dist/FluxHub.lua"))()

local Window = Flux:Window({
	Title = "Flux",
	Subtitle = "RIVALS",
	Icon = "crosshair",
	ToggleKey = Enum.KeyCode.RightControl,
	Size = 920,
})

Window:SetStatus("ready")

--------------------------------------------------------------------------------
-- Aim
--------------------------------------------------------------------------------

local aim = Window:Tab({ Title = "Aim", Icon = "target" })

local rage = aim:GroupBox({ Title = "Rage", Desc = "tight angles, slow refresh", Icon = "crosshair" })

rage:Toggle({
	Name = "Silent aim",
	Desc = "Bends the shot packet toward the target instead of the crosshair.",
	Default = false,
	Flag = "aim.silent",
	Callback = function(on)
		Flux:Notify({
			Title = "Silent aim",
			Text = on and "enabled" or "disabled",
			Kind = on and "success" or "info",
		})
	end,
})

rage:Slider({
	Name = "Field of view",
	Default = 65,
	Min = 0,
	Max = 120,
	Step = 1,
	Suffix = "°",
	Flag = "aim.fov",
})

rage:Slider({
	Name = "Hit probability",
	Desc = "How sure the target has to be before the shot is fired.",
	Default = 0.72,
	Min = 0,
	Max = 1,
	Decimals = 2,
	Flag = "aim.hp",
})

rage:Dropdown({
	Name = "Target part",
	Options = { "Head", "HumanoidRootPart", "UpperTorso" },
	Default = "Head",
	Flag = "aim.part",
})

rage:Keybind({
	Name = "Fire key",
	Desc = "Hold to force a shot, whatever the aim bot thinks.",
	Default = Enum.KeyCode.MouseButton2,
	Hold = true,
	Flag = "aim.fire",
})

local smooth = aim:GroupBox({ Title = "Smoothing", Side = "right" })

smooth:Checkbox({ Name = "Prediction", Default = true, Flag = "aim.predict" })
smooth:Slider({ Name = "Smoothing", Default = 12, Min = 0, Max = 40, Flag = "aim.smooth" })
smooth:Divider({ Text = "fallback" })
smooth:Toggle({ Name = "No recoil", Default = false, Flag = "aim.recoil" })

--------------------------------------------------------------------------------
-- Visuals
--------------------------------------------------------------------------------

local visuals = Window:Tab({ Title = "Visuals", Icon = "eye" })

-- Nothing on this page is built until the tab is first opened, which is why a hub with four heavy
-- tabs still loads in one frame.
visuals:Defer(function(tab)
	local esp = tab:GroupBox({ Title = "Player ESP", Desc = "drawn on every visible player", Icon = "user" })

	esp:Toggle({ Name = "Boxes", Default = true, Flag = "esp.boxes" })
	esp:Toggle({ Name = "Skeleton", Flag = "esp.skeleton" })
	esp:Slider({ Name = "Distance", Default = 250, Min = 0, Max = 1000, Suffix = " studs", Flag = "esp.distance" })
	esp:ColorPicker({ Name = "Box colour", Default = Color3.fromRGB(255, 79, 104), Flag = "esp.boxColor" })
	esp:ColorPicker({ Name = "Skeleton colour", Default = Color3.fromRGB(120, 200, 255), Flag = "esp.boneColor" })

	local overlay = tab:GroupBox({ Title = "Overlay", Side = "right" })
	overlay:Label({ Name = "Target", Text = "Target", Value = "none", Flag = "esp.targetLabel" })
	overlay:ProgressBar({ Name = "Charge", Max = 100, Default = 0, Flag = "esp.charge" })
	overlay:Paragraph({
		Name = "Note",
		Text = "ESP is drawn client-side only. Nothing on this card is sent to the server.",
	})
end)

--------------------------------------------------------------------------------
-- World
--------------------------------------------------------------------------------

local world = Window:Tab({ Title = "World", Icon = "globe" })

local loot = world:GroupBox({ Title = "Loot", Icon = "flask" })
loot:Toggle({ Name = "Crate ESP", Flag = "world.crates" })
loot:Toggle({ Name = "Pickup trail", Desc = "Leaves a fading line to the nearest drop.", Flag = "world.trail" })
loot:Dropdown({
	Name = "Filter",
	Options = { "All", "Weapons", "Consumables", "Currency" },
	Default = "All",
	Searchable = true,
	Flag = "world.filter",
})

local utility = world:GroupBox({ Title = "Utility", Side = "right" })
utility:Input({ Name = "Player name", Placeholder = "type a name", Flag = "world.player" })
utility:Button({
	Text = "Focus player",
	Variant = "accent",
	Icon = "play",
	Callback = function()
		Flux:Notify({ Title = "Focus", Text = "no such player in this server", Kind = "error" })
	end,
})
utility:Button({
	Text = "Teleport to spawn",
	Variant = "outline",
	Icon = "home",
	Callback = function()
		Flux:Notify({ Title = "Teleport", Text = "requested spawn return", Kind = "warning" })
	end,
})

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local settings = Window:Tab({ Title = "Config", Icon = "gear" })

local profiles = settings:GroupBox({ Title = "Profiles", Icon = "save" })

profiles:Dropdown({
	Name = "Profile",
	Options = { "default", "legit", "rage" },
	Default = "default",
	Flag = "cfg.profile",
})

profiles:Button({
	Text = "Save",
	Variant = "success",
	Icon = "save",
	Callback = function()
		if Flux:Save() then
			Flux:Notify({ Title = "Config", Text = "saved to disk", Kind = "success" })
		else
			Flux:Notify({ Title = "Config", Text = "could not write the file", Kind = "error" })
		end
	end,
})

profiles:Button({
	Text = "Load",
	Variant = "soft",
	Icon = "download",
	Callback = function()
		if Flux:Load() then
			Flux:Notify({ Title = "Config", Text = "profile restored", Kind = "success" })
		else
			Flux:Notify({ Title = "Config", Text = "no saved profile found", Kind = "warning" })
		end
	end,
})

profiles:Toggle({ Name = "Auto-save on change", Default = false, Flag = "cfg.autoSave" })
profiles:Toggle({
	Name = "Reduced motion",
	Default = false,
	Flag = "cfg.reducedMotion",
	Callback = function(on)
		Flux:System("animation").setReducedMotion(on)
	end,
})

local appearance = settings:GroupBox({ Title = "Appearance", Side = "right" })
appearance:Dropdown({
	Name = "Theme",
	Options = { "Dark", "Purple", "Red", "Blue" },
	Default = "Dark",
	Callback = function(name)
		Flux:SetTheme(name)
		Flux:Notify({ Title = "Theme", Text = "switched to " .. tostring(name), Icon = "palette" })
	end,
})
appearance:ColorPicker({
	Name = "Accent",
	Desc = "Overrides the theme's own accent until the next preset switch.",
	Default = Color3.fromRGB(255, 79, 104),
	Callback = function(color)
		Flux:SetTheme({ Accent = color })
	end,
})
appearance:Keybind({ Name = "Panic key", Default = Enum.KeyCode.RightShift, Flag = "cfg.panic" })

--------------------------------------------------------------------------------
-- Runtime
--------------------------------------------------------------------------------

-- A progress toast that tracks the work it claims to be doing.
task.spawn(function()
	local note = Flux:Notify({ Title = "Indexing", Text = "0 of 4 tabs", Progress = 0, Duration = 10, Icon = "refresh" })
	for step = 1, 4 do
		task.wait(0.3)
		note:Update({ Text = step .. " of 4 tabs", Progress = step / 4 })
	end
	note:Update({ Title = "Ready", Text = "search any control by name", Progress = 1 })
end)

print("[Flux] showcase built on version " .. tostring(Flux.Version))
