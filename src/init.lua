--!strict
--[[
	init — the entry point of the bundle.

	tools/build.mjs finishes dist/FluxHub.lua by requiring this module, so whatever it returns
	is what a hub receives from

		local Flux = loadstring(game:HttpGet(url))()

	The version token below is replaced with the contents of VERSION at build time, so the
	published number cannot drift from the file that tags it.
]]

local Library = require("Flux/Core/Library")

local Flux = Library.new()

Flux.Version = __FLUX_VERSION__

return Flux
