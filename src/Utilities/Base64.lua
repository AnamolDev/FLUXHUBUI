--[[
	Base64 — decode for the embedded icon atlas.

	Roblox exposes no base64 helper, so the atlas bytes are decoded here with bit32, which
	is part of the engine rather than an executor addition.
]]

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local lookup = {}
for index = 1, 64 do
	lookup[string.byte(ALPHABET, index)] = index - 1
end

local Base64 = {}

--- Returns the raw byte string. Padding and whitespace are ignored; an unknown byte stops
--- the decode at that point rather than producing garbage.
function Base64.decode(encoded: string): string?
	local length = #encoded
	local out = table.create(length)
	local count = 0

	local buffer = 0
	local bits = 0

	for index = 1, length do
		local byte = string.byte(encoded, index)
		if byte == 61 then -- '='
			break
		end

		local value = lookup[byte]
		if value == nil then
			if byte == 10 or byte == 13 or byte == 32 or byte == 9 then
				continue
			end
			return nil
		end

		buffer = bit32.lshift(buffer, 6) + value
		bits += 6

		if bits >= 8 then
			bits -= 8
			count += 1
			out[count] = string.char(bit32.band(bit32.rshift(buffer, bits), 0xFF))
			buffer = bit32.band(buffer, bit32.lshift(1, bits) - 1)
		end
	end

	return table.concat(out, "", 1, count)
end

--- Encode is needed only by the config export path, which writes a portable text blob.
local function slotAt(triplet: number, shift: number): string
	local slot = bit32.rshift(triplet, shift) % 64 + 1
	return string.sub(ALPHABET, slot, slot)
end

function Base64.encode(raw: string): string
	local out = {}
	local length = #raw

	local index = 1
	while index <= length do
		local a = string.byte(raw, index)

		local b: number? = nil
		if index + 1 <= length then
			b = string.byte(raw, index + 1)
		end

		local c: number? = nil
		if index + 2 <= length then
			c = string.byte(raw, index + 2)
		end

		local triplet = bit32.lshift(a, 16) + bit32.lshift(b or 0, 8) + (c or 0)

		out[#out + 1] = slotAt(triplet, 18)
		out[#out + 1] = slotAt(triplet, 12)
		if b ~= nil then
			out[#out + 1] = slotAt(triplet, 6)
		else
			out[#out + 1] = "="
		end
		if c ~= nil then
			out[#out + 1] = slotAt(triplet, 0)
		else
			out[#out + 1] = "="
		end

		index += 3
	end

	return table.concat(out)
end

return Base64
