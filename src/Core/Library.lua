--[[
	Core/Library — the object a hub receives from the loader.

	Everything below is a façade over the systems, which are singletons: two windows share one
	theme, one renderer and one notification stack, because that is what makes a menu that is open
	in two places repaint as one thing. The façade exists so host code reads as

		local Flux = loadstring(game:HttpGet(url))()
		local Window = Flux:Window({ Title = "Flux", ToggleKey = Enum.KeyCode.RightControl })
		local Tab = Window:Tab({ Title = "Aim", Icon = "crosshair" })
		Tab:GroupBox({ Title = "Legit" }):Toggle({ Name = "Silent aim", Default = false })

	rather than as a tour of the module graph.
]]

local Element = require("Flux/Core/Element")
local Guard = require("Flux/Utilities/Guard")
local Signal = require("Flux/Utilities/Signal")
local Lifecycle = require("Flux/Core/Lifecycle")
local Container = require("Flux/Core/Container")
local WindowModule = require("Flux/Core/Window")

local ThemeManager = require("Flux/Systems/ThemeManager")
local NotificationManager = require("Flux/Systems/NotificationManager")
local ConfigManager = require("Flux/Systems/ConfigManager")
local InputManager = require("Flux/Systems/InputManager")
local TooltipManager = require("Flux/Systems/TooltipManager")
local AnimationManager = require("Flux/Systems/AnimationManager")
local LayoutManager = require("Flux/Systems/LayoutManager")
local Renderer = require("Flux/Systems/Renderer")
local IconManager = require("Flux/Systems/IconManager")
local SearchManager = require("Flux/Systems/SearchManager")

local Library = {}
Library.__index = Library

function Library.new(options: {[string]: any}?)
	options = options or {}

	local self = setmetatable({
		Version = "0.0.0-dev",
		Windows = {},
		Closed = Signal.new(),
		Options = options,
	}, Library)

	if type(options.Theme) == "string" then
		ThemeManager.use(options.Theme)
	elseif type(options.Theme) == "table" then
		ThemeManager.set(options.Theme)
	end

	if type(options.Notifications) == "table" then
		NotificationManager.configure(options.Notifications)
	end

	if type(options.Tooltips) == "table" then
		TooltipManager.configure(options.Tooltips)
	end

	if type(options.Renderer) == "table" then
		Renderer.configure(options.Renderer)
	end

	if type(options.Icons) == "table" then
		IconManager.configure(options.Icons)
	end

	if options.Config ~= false then
		ConfigManager.configure(type(options.Config) == "table" and options.Config or nil)
	end

	if type(options.BaseSize) == "number" then
		LayoutManager.setBase(options.BaseSize, options.BaseSize * 0.62)
	end

	AnimationManager.setReducedMotion(options.ReducedMotion == true)
	return self
end

--- Create a window. The first one is what `Flux:Notify`, `Flux:Search` and the toggle key act on.
function Library:Window(options: any)
	if type(options) == "string" then
		options = { Title = options }
	end

	local window = WindowModule.new(self, options or {})
	table.insert(self.Windows, window)
	self.Primary = self.Primary or window

	local onClosed = options and options.OnClose
	if type(onClosed) == "function" then
		Lifecycle.onClose(function()
			onClosed(window)
		end)
	end
	return window
end

Library.CreateWindow = Library.Window
Library.NewWindow = Library.Window

function Library:GetWindow(title: string): any
	for _, window in ipairs(self.Windows) do
		if window.Title == title then
			return window
		end
	end
	return nil
end

--- A second window in the same hub. The reference design shows one, but a script that separates
--- config from gameplay controls asks for this constantly.
function Library:WindowList(): {any}
	return self.Windows
end

function Library:Notify(options: any)
	return NotificationManager.notify(options)
end

--- `Flux:SetTheme("Purple")` or `Flux:SetTheme{ Accent = Color3.fromRGB(...) }`.
function Library:SetTheme(value: any): {[string]: any}
	if type(value) == "string" then
		ThemeManager.use(value)
	elseif type(value) == "table" then
		-- A restored snapshot carries name/colors/metrics/fonts; anything else is a flat override
		-- table, and the two shapes must not be confused for each other.
		if value.colors ~= nil or value.metrics ~= nil or value.name ~= nil then
			ThemeManager.restore(value)
		else
			ThemeManager.set(value)
		end
	end
	return ThemeManager.snapshot()
end

function Library:GetTheme(): {[string]: any}
	return ThemeManager.snapshot()
end

function Library:OnThemeChanged(fn: () -> ()): () -> ()
	local connection = ThemeManager.Changed:Connect(fn)
	return function()
		connection:Disconnect()
	end
end

--- Search across every window's registered controls.
function Library:Search(term: string): number
	local matched = SearchManager.set(term)
	for _, window in ipairs(self.Windows) do
		for _, tab in ipairs(window.TabOrder) do
			tab:RefreshSearch()
		end
	end
	return matched
end

function Library:Save(name: string?): boolean
	return ConfigManager.save(name)
end

function Library:Load(name: string?): boolean
	local ok = ConfigManager.load(name)
	if ok then
		self:_applyConfiguredState()
	end
	return ok
end

--- Push stored values into rows that exist and record what should be applied to rows that do not
--- exist yet, which is the whole reason bindings live in the config system and not in the widgets.
function Library:_applyConfiguredState(): number
	local applied = ConfigManager.push()
	for _, window in ipairs(self.Windows) do
		for _, tab in ipairs(window.TabOrder) do
			if tab.Page ~= nil then
				for _, group in ipairs(tab.Groups) do
					group:_applyFilter()
				end
			end
		end
	end
	return applied
end

function Library:Config(): any
	return ConfigManager
end

function Library:Input(): any
	return InputManager
end

function Library:AddComponent(name: string, module: any): boolean
	return Container.register(name, module)
end

--- The system handles, for a host that wants to reach past the façade.
function Library:System(name: string): any
	local systems = {
		theme = ThemeManager,
		icons = IconManager,
		animation = AnimationManager,
		config = ConfigManager,
		input = InputManager,
		layout = LayoutManager,
		notifications = NotificationManager,
		renderer = Renderer,
		search = SearchManager,
		tooltip = TooltipManager,
		element = Element,
		guard = Guard,
	}
	return systems[string.lower(tostring(name))]
end

function Library:OnClose(fn: () -> ())
	return Lifecycle.onClose(fn)
end

--- Every keybind the hub owns, so a script can list them in its own UI.
function Library:Binds(): {any}
	return InputManager.list()
end

function Library:WindowCount(): number
	return Lifecycle.count()
end

--- The full teardown. Closes windows, releases every bind and listener, and drops the floating
--- surfaces. Re-running the same loader afterwards builds a fresh hub.
function Library:Unload()
	if self._unloaded then
		return false
	end
	self._unloaded = true

	local destroyed = Lifecycle.closeAll()

	Renderer.cancel()
	Renderer.reset()
	AnimationManager.stopAll()
	NotificationManager.destroy()
	TooltipManager.destroy()
	InputManager.unload()
	SearchManager.clear()
	LayoutManager.unwatch()

	self.Closed:Dispatch(destroyed)
	self.Closed:Destroy()
	self.Windows = {}
	self.Primary = nil
	return true
end

Library.Destroy = Library.Unload
Library.Close = Library.Unload

function Library:IsUnloaded(): boolean
	return self._unloaded == true
end

--- Toggle every window open or closed with one call — the behaviour a single hotkey is expected
--- to have.
function Library:Toggle(force: boolean?)
	local primary = self.Primary
	if primary == nil then
		return false
	end

	if force == nil then
		primary:Toggle()
	elseif force then
		primary:Show()
	else
		primary:Hide()
	end
	return primary.Open
end

return Library
