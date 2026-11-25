--[[
	Assets/Theme — the token tables. Pure data: no instances, no game services.

	Two things are separated deliberately:
	  * `colors` are named semantic roles, not hexes scattered through components;
	  * `metrics` and `fonts` travel with them so a theme change can restyle spacing too.

	The default preset is measured against the reference screenshot: near-black backdrop,
	panel fills one step lighter, hairline borders, low-contrast secondary text, and the
	coral accent reserved for active state rather than decoration.
]]

local Color3 = Color3

local Theme = {}

Theme.presets = {
	Dark = {
		colors = {
			Background = Color3.fromRGB(16, 16, 20),
			WindowBackground = Color3.fromRGB(18, 18, 24),
			Panel = Color3.fromRGB(24, 24, 30),
			PanelSecondary = Color3.fromRGB(29, 29, 38),
			Field = Color3.fromRGB(31, 31, 38),
			Chip = Color3.fromRGB(33, 33, 40),
			Hover = Color3.fromRGB(36, 36, 46),
			Selection = Color3.fromRGB(40, 40, 52),
			Scrim = Color3.fromRGB(8, 8, 12),

			BorderPrimary = Color3.fromRGB(37, 37, 48),
			BorderSecondary = Color3.fromRGB(48, 48, 59),

			TextPrimary = Color3.fromRGB(231, 231, 237),
			TextSecondary = Color3.fromRGB(153, 153, 168),
			TextMuted = Color3.fromRGB(104, 104, 120),

			BrandPrimary = Color3.fromRGB(183, 106, 255),
			BrandSecondary = Color3.fromRGB(140, 82, 255),

			Accent = Color3.fromRGB(255, 79, 104),
			AccentHover = Color3.fromRGB(255, 102, 122),
			AccentSoft = Color3.fromRGB(72, 30, 40),

			Success = Color3.fromRGB(72, 199, 116),
			Warning = Color3.fromRGB(240, 173, 78),
			Error = Color3.fromRGB(255, 92, 92),
			Info = Color3.fromRGB(96, 165, 250),
		},
		metrics = {
			RadiusWindow = 12,
			RadiusPanel = 10,
			RadiusField = 8,
			RadiusChip = 6,
			RadiusPill = 24,
			HeaderHeight = 72,
			NavHeight = 52,
			FooterHeight = 40,
			RowHeight = 30,
			GroupPadding = 16,
			GroupGap = 14,
			ContentPadding = 18,
			ColumnGap = 16,
			StrokeThickness = 1,
		},
		fonts = {
			Title = Enum.Font.GothamMedium,
			Body = Enum.Font.Gotham,
			Subtitle = Enum.Font.GothamMedium,
			Mono = Enum.Font.Code,
		},
	},
}

--- A preset is the Dark table with one role group recoloured, so switching to Purple does
--- not silently reset spacing or fonts as a side effect.
local function tinted(name: string, overrides: {[string]: Color3}): {[string]: any}
	local base = Theme.presets.Dark
	local colors = {}
	for key, value in pairs(base.colors) do
		colors[key] = value
	end
	for key, value in pairs(overrides) do
		colors[key] = value
	end

	return {
		colors = colors,
		metrics = base.metrics,
		fonts = base.fonts,
		name = name,
	}
end

Theme.presets.Purple = tinted("Purple", {
	Accent = Color3.fromRGB(150, 96, 255),
	AccentHover = Color3.fromRGB(170, 120, 255),
	AccentSoft = Color3.fromRGB(46, 32, 74),
	BrandPrimary = Color3.fromRGB(183, 106, 255),
	Selection = Color3.fromRGB(44, 36, 62),
})

Theme.presets.Red = tinted("Red", {
	Accent = Color3.fromRGB(232, 62, 74),
	AccentHover = Color3.fromRGB(246, 92, 102),
	AccentSoft = Color3.fromRGB(62, 26, 32),
	BrandPrimary = Color3.fromRGB(232, 62, 74),
	Selection = Color3.fromRGB(56, 32, 38),
})

Theme.presets.Blue = tinted("Blue", {
	Accent = Color3.fromRGB(74, 138, 255),
	AccentHover = Color3.fromRGB(104, 160, 255),
	AccentSoft = Color3.fromRGB(30, 44, 74),
	BrandPrimary = Color3.fromRGB(96, 165, 250),
	Selection = Color3.fromRGB(34, 46, 70),
})

Theme.presets.Custom = tinted("Custom", {})

Theme.defaultPreset = "Dark"

--- Roles a component may bind to. Listed so ThemeManager can validate a typo at the call
--- site instead of painting black and leaving the author to guess which token missed.
Theme.colorRoles = {
	"Background",
	"WindowBackground",
	"Panel",
	"PanelSecondary",
	"Field",
	"Chip",
	"Hover",
	"Selection",
	"Scrim",
	"BorderPrimary",
	"BorderSecondary",
	"TextPrimary",
	"TextSecondary",
	"TextMuted",
	"BrandPrimary",
	"BrandSecondary",
	"Accent",
	"AccentHover",
	"AccentSoft",
	"Success",
	"Warning",
	"Error",
	"Info",
}

Theme.metricRoles = {
	"RadiusWindow",
	"RadiusPanel",
	"RadiusField",
	"RadiusChip",
	"RadiusPill",
	"HeaderHeight",
	"NavHeight",
	"FooterHeight",
	"RowHeight",
	"GroupPadding",
	"GroupGap",
	"ContentPadding",
	"ColumnGap",
	"StrokeThickness",
}

return Theme
