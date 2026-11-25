--[[
	Components/Label — a title/value readout row a script owns.

	The row shape of Toggle/Slider with no control on the right: just a value the host pushes
	with `SetValue`, right-aligned in the mono font the numeric readouts already use. It is the
	only member of the family with no user interaction — nothing to click, no callback — but it
	still persists, because a readout like "current profile" or "session FPS target" is config
	the user expects to survive a restart, and `Flag` is how the rest of the library says that.

	Values render through a documented format, never raw `tostring`: `tostring(0.1 + 0.2)` puts
	float dust on the screen, and a readout is the one place a user actually reads the digits.
	Numbers go through `Format` (a `string.format` pattern, `%g` by default) and every rendered
	value gets `Suffix` appended; `nil` clears the slot.
]]

local Element = require("Flux/Core/Element")
local Guard = require("Flux/Utilities/Guard")
local Signal = require("Flux/Utilities/Signal")

local Label = {}

--- Script-facing colour states. `accent` is the one that moves with a theme preset, which is
--- how a live readout stays the hub's colour instead of a frozen hex from build time.
local STATES = {
	normal = "TextSecondary",
	good = "Success",
	warn = "Warning",
	bad = "Error",
	info = "Info",
	accent = "Accent",
}

function Label.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "Label",
		Title = nil,
		Text = nil,
		Desc = nil,
		Value = nil,
		Flag = nil,
		Role = nil,
		State = nil,
		Format = "%g",
		Suffix = "",
		BodyWidth = nil,
	})

	local title = options.Title or options.Text or options.Name
	local maid = group.Maid
	local role = options.Role or STATES[options.State or "normal"] or "TextSecondary"

	local row = Element.row(maid, group.Content, "Label_" .. tostring(title), {
		Label = title,
		Desc = options.Desc,
		BodyWidth = options.BodyWidth or 110,
		Order = group:RowCount() + 1,
	})

	local readout = Element.label(maid, row.Body, "Value", {
		Text = "",
		Role = role,
		Font = "Mono",
		TextSize = 12,
		Alignment = Enum.TextXAlignment.Right,
		AutoWidth = true,
		ZIndex = 6,
	})

	local self = {
		Instance = row.Root,
		Title = title,
		Changed = Signal.new(),
		_value = nil,
		_role = role,
		_state = options.State or "normal",
		_maid = maid,
		_group = group,
		_flag = options.Flag,
		_row = row,
	}

	local function render(value: any)
		local text
		local num = tonumber(value)
		if num ~= nil and type(value) ~= "boolean" then
			text = string.format(options.Format or "%g", num)
		else
			text = tostring(value)
		end
		readout.Text = text .. (options.Suffix or "")
	end

	local function apply(value: any, push: boolean?)
		if self.Destroyed then
			return self
		end
		local changed = value ~= self._value
		self._value = value

		if value == nil then
			readout.Text = ""
		else
			render(value)
		end

		if changed then
			if push then
				Element.pushConfig(self._flag, value)
			end
			self.Changed:Dispatch(value)
		end
		return self
	end

	-- Staged without pushing (the Slider rule): a config restored later must not lose the
	-- file's value to the default this label was declared with.
	self._value = options.Value
	if options.Value ~= nil then
		render(options.Value)
	end

	self.SetValue = function(a: any, b: any)
		local value = a
		if a == self then
			value = b
		end
		return apply(value, true)
	end

	self.Set = self.SetValue

	self.GetValue = function()
		return self._value
	end

	self.SetState = function(a: any, b: any)
		local name = a
		if a == self then
			name = b
		end
		local nextRole = STATES[name]
		if nextRole == nil then
			warn("[Flux] label '" .. tostring(title) .. "': no state named " .. tostring(name))
			return self
		end
		self._state = name
		self._role = nextRole
		Element.tint(maid, readout, "TextColor3", nextRole)
		return self
	end

	self.GetState = function()
		return self._state
	end

	self.SetCallback = function()
		-- A label has no user interaction to report; the Changed signal is the hook.
		warn("[Flux] label '" .. tostring(title) .. "': a readout has no callback, use :Changed:Connect")
		return self
	end

	self.SetTitle = function(a: any, b: any)
		local text = a
		if a == self then
			text = b
		end
		self.Title = tostring(text)
		row.Title.Text = self.Title
		return self
	end

	self.SetVisible = function(a: any, b: any)
		local visible = a
		if a == self then
			visible = b
		end
		row.Root.Visible = visible == true
		return self
	end

	self.OnFilter = function(a: any, b: any)
		local matched = a
		if a == self then
			matched = b
		end
		row.Root.Visible = matched == true
	end

	self.Destroy = function()
		if self.Destroyed then
			return
		end
		self.Destroyed = true
		self.Changed:Destroy()
		Element.releaseSearch(group, self)
		row.Root:Destroy()
	end

	Element.bindConfig(maid, self._flag, function(value)
		apply(value)
	end, function()
		return self._value
	end)

	self.SearchId = Element.searchable(group, self, tostring(title), options.Desc)
	Guard.set(row.Root, "LayoutOrder", group:RowCount())
	return self
end

return Label
