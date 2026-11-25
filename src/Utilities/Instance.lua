--[[
	Instance — element factory.

	Every GUI object in the library is built through this module so that:
	  * optional properties route through Guard instead of raising;
	  * layout helpers (corner/stroke/pad/list) are applied in one call;
	  * a rounded panel actually clips its children, which is what makes the corner visible;
	  * the harness can count objects, because the execute-time instance budget decides
	    whether a large menu freezes a low-end device.
]]

-- Captured before the module table below shadows the global class name.
local RBXInstance = Instance

local Guard = require("Flux/Utilities/Guard")

local TweenService = Guard.service("TweenService")
local Instance = {}

local created = 0

--- Properties that only exist on recent engines; assigned through pcall.
local OPTIONAL_PROPERTIES = {
	DisplayOrderOnTop = true,
	ResetOnDestroyed = true,
	LetterSpacing = true,
	GroupTransparency = true,
	AutoLocalize = true,
	SelectionImageObject = true,
	BorderMode = true,
	TextTruncated = true,
	-- CaretColor and CursorPosition are textbox members that older executors do not carry;
	-- writing them unguarded aborts the widget build over a cosmetic detail.
	CaretColor = true,
	CaretTransparency = true,
	CursorPosition = true,
	CanvasPosition = true,
}

local function applyProperty(instance: any, key: string, value: any)
	if OPTIONAL_PROPERTIES[key] then
		Guard.set(instance, key, value)
	else
		instance[key] = value
	end
end

--- Create, then apply a property table, then parent. Parenting last means the object is
--- fully configured before the engine lays it out, which avoids a visible reflow frame.
function Instance.new(className: string, parent: any?, properties: {[string]: any}?)
	local instance = RBXInstance.new(className)
	created += 1

	if properties ~= nil then
		for key, value in pairs(properties) do
			applyProperty(instance, key, value)
		end
	end

	if parent ~= nil then
		instance.Parent = parent
	end

	return instance
end

function Instance.count(): number
	return created
end

function Instance.resetCount()
	created = 0
end

local function helper(className: string, parent: any, properties: {[string]: any})
	return Instance.new(className, parent, properties)
end

function Instance.corner(parent: any, radius: UDim)
	return helper("UICorner", parent, { CornerRadius = radius })
end

function Instance.stroke(parent: any, color: Color3, thickness: number, transparency: number?)
	return helper("UIStroke", parent, {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function Instance.pad(parent: any, spec: { Top: UDim?, Bottom: UDim?, Left: UDim?, Right: UDim? })
	return helper("UIPadding", parent, {
		PaddingTop = spec.Top or UDim.new(0, 0),
		PaddingBottom = spec.Bottom or UDim.new(0, 0),
		PaddingLeft = spec.Left or UDim.new(0, 0),
		PaddingRight = spec.Right or UDim.new(0, 0),
	})
end

function Instance.list(parent: any, spec: {
	FillDirection: Enum.FillDirection?,
	SortOrder: Enum.SortOrder?,
	Padding: UDim?,
	Wrap: boolean?,
	VerticalAlignment: Enum.VerticalAlignment?,
	HorizontalAlignment: Enum.HorizontalAlignment?,
})
	return helper("UIListLayout", parent, {
		FillDirection = spec.FillDirection or Enum.FillDirection.Vertical,
		SortOrder = spec.SortOrder or Enum.SortOrder.LayoutOrder,
		Padding = spec.Padding or UDim.new(0, 0),
		Wrap = spec.Wrap == true,
		VerticalAlignment = spec.VerticalAlignment or Enum.VerticalAlignment.Top,
		HorizontalAlignment = spec.HorizontalAlignment or Enum.HorizontalAlignment.Left,
	})
end

function Instance.grid(parent: any, spec: { CellSize: UDim?, Padding: UDim?, FillDirection: Enum.FillDirection? })
	return helper("UIGridLayout", parent, {
		CellSize = spec.CellSize or UDim.new(0, 100),
		CellPadding = spec.Padding or UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = spec.FillDirection or Enum.FillDirection.Horizontal,
	})
end

--- A rounded, clipped container. `ClipsDescendants` is applied here rather than at every
--- call site: without it a child painted to the edge covers the rounded corner.
function Instance.panel(parent: any, name: string, properties: {[string]: any}?)
	local spec = {}
	for key, value in pairs(properties or {}) do
		spec[key] = value
	end

	spec.Name = name
	if spec.BackgroundColor3 == nil then
		spec.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
	end
	spec.BorderSizePixel = 0

	local radius = spec.CornerRadius or UDim.new(0, 8)
	spec.CornerRadius = nil

	local frame = Instance.new("Frame", parent, spec)
	frame.ClipsDescendants = true
	Instance.corner(frame, radius)
	return frame
end

--- Remove content children but keep the layout helpers already parented to this container.
function Instance.clear(parent: any)
	for _, child in ipairs(parent:GetChildren()) do
		if not child:IsA("UIComponent") then
			child:Destroy()
		end
	end
end

function Instance.tween(instance: any, info: TweenInfo, goals: {[string]: any})
	if TweenService == nil then
		return nil
	end

	local ok, track = pcall(function()
		return TweenService:Create(instance, info, goals)
	end)

	if ok then
		return track
	end
	return nil
end

return Instance
