--[[
	Components/Paragraph — a wrapping text block inside a group.

	A settings page needs prose: a disclaimer, a key hint, a short explanation under a section
	title. Paragraph is the row shape with the interactivity removed — no body control, no
	callback, nothing to click — and an explicit height, because the row auto-sizing a hub
	trusts (AutomaticSize) is exactly the mechanism a weak executor resolves last: a paragraph
	that grows a frame late overlaps whatever sits under it, and a clipped one silently loses
	sentences. So the block measures its own text and writes its own height.

	The measurement is a character-count estimate — none of the target clients answer a text
	metrics query off-screen reliably — with `Width` as the assumed wrap column. It errs wide:
	one extra line of breathing room costs a few pixels, a clipped word costs the message.
	Nothing in this row sets `ClipsDescendants`, so a bad estimate loses whitespace, never text.
]]

local Element = require("Flux/Core/Element")
local Guard = require("Flux/Utilities/Guard")

local Paragraph = {}

local PAD = 8
local TITLE_H = 18

--- Wrapped line count for one segment against an assumed character column.
local function measureLines(text: string, maxChars: number): number
	local total = 0
	local rest = text
	while true do
		local nl = rest:find("\n", 1, true)
		local segment = rest
		if nl ~= nil then
			segment = rest:sub(1, nl - 1)
			rest = rest:sub(nl + 1)
		else
			rest = ""
		end

		local lines = 1
		local used = 0
		for word in segment:gmatch("%S+") do
			local width = #word + (used > 0 and 1 or 0)
			if used + width > maxChars then
				lines += 1
				used = #word
			else
				used += width
			end
		end
		total += lines

		if nl == nil then
			break
		end
	end
	return math.max(total, 1)
end

function Paragraph.new(group: any, options: {[string]: any}?)
	options = Element.options(options, {
		Name = "Paragraph",
		Title = nil,
		Text = "",
		Role = "TextSecondary",
		Size = 12,
		Width = 320,
	})

	local maid = group.Maid
	local lineH = options.Size + 4
	local hasTitle = type(options.Title) == "string" and options.Title ~= ""
	local maxChars = math.max(12, math.floor((tonumber(options.Width) or 320) / (options.Size * 0.55)))

	local root = Element.panel(maid, group.Content, "Paragraph_" .. tostring(options.Name), {
		Transparency = 1,
		Size = UDim2.new(1, 0, 0, PAD * 2),
		LayoutOrder = group:RowCount() + 1,
		ZIndex = 5,
	})

	local titleNode = nil
	if hasTitle then
		titleNode = Element.label(maid, root, "Title", {
			Text = options.Title,
			Role = "TextPrimary",
			Font = "Title",
			TextSize = 13,
			Size = UDim2.new(1, 0, 0, TITLE_H),
			Position = UDim2.new(0, 0, 0, PAD - 4),
			ZIndex = 6,
		})
	end

	local body = Element.label(maid, root, "Body", {
		Text = "",
		Role = options.Role,
		TextSize = options.Size,
		Wrap = true,
		Vertical = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, lineH),
		Position = UDim2.new(0, 0, 0, PAD + (hasTitle and TITLE_H or 0)),
		ZIndex = 6,
	})

	local self = {
		Instance = root,
		Title = hasTitle and options.Title or tostring(options.Name),
		_maid = maid,
		_group = group,
		_text = "",
		_lines = 1,
	}

	local function relayout(text: string): number
		local lines = measureLines(text, maxChars)
		body.Text = text
		self._lines = lines
		root.Size = UDim2.new(1, 0, 0, PAD * 2 + (hasTitle and TITLE_H or 0) + lines * lineH)
		return lines
	end

	self.SetText = function(a: any, b: any)
		local value = a
		if a == self then
			value = b
		end
		if self.Destroyed then
			return self
		end
		self._text = tostring(value)
		relayout(self._text)
		return self
	end

	self.Set = self.SetText

	self.GetText = function()
		return self._text
	end

	self.GetValue = self.GetText

	--- How many wrapped lines the current text occupies — the number the height was built from,
	--- exposed so a host (and a spec) can prove the block tracks its content.
	self.LineCount = function()
		return self._lines
	end

	self.SetTitle = function(a: any, b: any)
		local value = a
		if a == self then
			value = b
		end
		self.Title = tostring(value)
		if titleNode ~= nil then
			titleNode.Text = self.Title
		end
		return self
	end

	self.SetVisible = function(a: any, b: any)
		local visible = a
		if a == self then
			visible = b
		end
		root.Visible = visible == true
		return self
	end

	-- Groupbox fires this plain (`row.OnFilter(isMatch)`) and a host with a colon, so the flag
	-- arrives in either position; the shim reads whichever one carries it.
	self.OnFilter = function(a: any, b: any)
		local matched = a
		if a == self then
			matched = b
		end
		root.Visible = matched == true
	end

	self.Destroy = function()
		if self.Destroyed then
			return
		end
		self.Destroyed = true
		Element.releaseSearch(group, self)
		root:Destroy()
	end

	self.SetText(options.Text)
	self.SearchId = Element.searchable(group, self, tostring(self.Title), options.Text)
	Guard.set(root, "LayoutOrder", group:RowCount())
	return self
end

return Paragraph
