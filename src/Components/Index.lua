--[[
	Components/Index — the widget list, in one place.

	Core/Container builds every constructor from this table, so adding a component means writing
	the module and naming it here: nothing in the window, tab or groupbox code changes. Paths are
	module ids the bundler resolves, not filesystem paths.
]]

return {
	-- Controls the user acts on
	Button = "Flux/Components/Button",
	Toggle = "Flux/Components/Toggle",
	Checkbox = "Flux/Components/Checkbox",
	Slider = "Flux/Components/Slider",
	Dropdown = "Flux/Components/Dropdown",
	Input = "Flux/Components/Input",
	Keybind = "Flux/Components/Keybind",
	ColorPicker = "Flux/Components/ColorPicker",

	-- Read-only surfaces
	Label = "Flux/Components/Label",
	Paragraph = "Flux/Components/Paragraph",
	Divider = "Flux/Components/Divider",
	ProgressBar = "Flux/Components/ProgressBar",
}
