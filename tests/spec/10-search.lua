--[[
	spec 10 — SearchManager.

	The index is the only part of the hub that answers a question the user typed, so the two
	contract points are rank order (what a person expects "search" to mean) and the row callback
	(hiding is the row's business, and a row that throws must not take the search down with it).

	Rank is asserted through `rank`, which is pure, and separately through `set`, which is what
	actually moves the UI. A tiered score is easy to write and easy to get backwards, so every
	tier gets its own pair of rows here.
]]

local SearchManager = assert(fluxRequire("Flux/Systems/SearchManager"))
local String = assert(fluxRequire("Flux/Utilities/String"))

local function ids(results: {any}): {any}
	local out = {}
	for _, entry in ipairs(results) do
		out[#out + 1] = entry.id
	end
	return out
end

local function rankIds(query: string): string
	local out = {}
	for _, hit in ipairs(SearchManager.rank(query)) do
		out[#out + 1] = hit.entry.id
	end
	return table.concat(out, ",")
end

local function withIndex(entries: {any}, body: () -> ())
	local ok, err = pcall(function()
		for _, entry in ipairs(entries) do
			assert(SearchManager.register(entry), "fixture " .. tostring(entry.Id) .. " refused")
		end
		body()
	end)
	SearchManager.clear()
	SearchManager.set("")
	assert(ok, err)
end

runSpec("registration is the index", function()
	withIndex({
		{ Id = "a", Label = "Chams" },
		{ Id = "b", Label = "Esp" },
	}, function()
		checkEq(SearchManager.size(), 2, "two rows indexed")
		checkEq(SearchManager.term(), "", "and no term typed yet")

		checkEq(SearchManager.unregister("a"), true, "unregistering a live id reports")
		checkEq(SearchManager.unregister("a"), false, "and a second time says there was nothing")
		checkEq(SearchManager.size(), 1, "the index shrank by one")

		SearchManager.clear()
		checkEq(SearchManager.size(), 0, "clear empties it")
	end)

	checkEq(SearchManager.register({ Label = "No id" }), false, "an entry without an Id is refused")
	checkEq(SearchManager.register({ Id = "x" }), false, "and one without a Label")
	checkEq(SearchManager.size(), 0, "neither reaches the index")
end)

runSpec("the tiers, in the order a person expects", function()
	local fixture = {
		{ Id = "exact", Label = "FOV" },
		{ Id = "prefix", Label = "FOV Circle" },
		{ Id = "word", Label = "Target FOV" },
		{ Id = "inside", Label = "Radarfove" },
		{ Id = "sub", Label = "Field Of View" },
		{ Id = "none", Label = "Silent Aim" },
	}

	withIndex(fixture, function()
		checkEq(rankIds("fov"), "exact,prefix,word,inside,sub", "exact, then prefix, then a word boundary, then a run inside a word, then the subsequence")
		checkEq(rankIds("silent aim"), "none", "a full label still matches")
		checkEq(rankIds("zzz"), "", "and nothing matches a term that is nowhere")

		local scores = SearchManager.rank("fov")
		checkEq(scores[1].score, 100, "an exact label is worth 100")
		checkEq(scores[2].score, 80, "a prefix 80")
		checkEq(scores[3].score, 70, "a word boundary 70")
		checkEq(scores[4].score, 50, "an inner run 50")
		checkEq(scores[5].score, 20, "and a subsequence 20")
	end)
end)

runSpec("a subsequence never outranks a prefix", function()
	withIndex({
		{ Id = "prefix", Label = "Saim Priority" },
		{ Id = "scattered", Label = "Silent Aim" },
		{ Id = "chams", Label = "Chams", Keywords = { "esp", "outline" } },
	}, function()
		checkEq(rankIds("saim"), "prefix,scattered", "a real prefix beats the letters-scattered match")
		checkEq(rankIds("esp"), "chams", "and a keyword is what makes the word the user typed find the row")
		checkEq(rankIds("outline"), "chams", "with any of them working")
	end)
end)

runSpec("ties keep the order the author wrote", function()
	withIndex({
		{ Id = "one", Label = "Aim" },
		{ Id = "two", Label = "Aim Bot" },
		{ Id = "three", Label = "Aim Speed" },
	}, function()
		checkEq(rankIds("aim"), "one,two,three", "three equally good rows stay in registration order")
	end)

	withIndex({
		{ Id = "late", Label = "Aim", Tab = "Camera" },
		{ Id = "early", Label = "Speed", Tab = "Aim" },
	}, function()
		checkEq(rankIds("aim"), "late,early", "a label match ranks above a tab-name match")
	end)
end)

runSpec("case and whitespace are not the user's problem", function()
	withIndex({
		{ Id = "esp", Label = "Esp", Text = "highlight enemies" },
		{ Id = "chams", Label = "Chams Esp" },
	}, function()
		checkEq(rankIds("ESP"), "esp,chams", "a shouted query still matches")
		checkEq(rankIds("  esp  "), "esp,chams", "and so does one padded by a paste")
		checkEq(rankIds("enemies"), "esp", "the description is searchable, the label is not required to contain it")
	end)
end)

runSpec("set moves the rows and reports", function()
	local seen = {}
	local dispatched = {}

	withIndex({
		{ Id = "show", Label = "Show FOV", OnMatch = function(_entry, isMatch)
			seen[#seen + 1] = isMatch
		end },
		{ Id = "hide", Label = "Silent Aim", OnMatch = function(_entry, isMatch)
			seen[#seen + 1] = isMatch
		end },
	}, function()
		SearchManager.Changed:Connect(function(nextTerm, results)
			dispatched[#dispatched + 1] = { term = nextTerm, count = #results }
		end)

		seen = {}
		local matched = SearchManager.set("fov")
		checkEq(matched, 1, "one row matched")
		checkEq(SearchManager.matched(), 1, "and the count agrees")
		checkEq(SearchManager.term(), "fov", "the live term is remembered")
		checkEq(#dispatched, 1, "the tabs were told once")
		checkEq(dispatched[1].count, 1, "with the matches in rank order")
		checkEq(#seen, 2, "every row was asked, not only the one that matched")

		seen = {}
		SearchManager.set("")
		checkEq(SearchManager.matched(), 2, "an empty term matches everything")
		checkEq(seen[1], true, "and the rows are told to come back")
	end)
end)

runSpec("a row that throws cannot take the search down", function()
	withIndex({
		{ Id = "boom", Label = "Explode", OnMatch = function()
			error("row blew up")
		end },
		{ Id = "fine", Label = "Explode Too", OnMatch = function(_entry, isMatch)
			checkEq(isMatch, true, "the next row still gets its report")
		end },
	}, function()
		checkNoError(function()
			SearchManager.set("explode")
		end, "the keystroke survives a broken row")
		checkEq(SearchManager.matched(), 2, "and both rows are counted")
	end)
end)

runSpec("a row built mid-search is filtered the moment it registers", function()
	withIndex({
		{ Id = "first", Label = "Aim Part" },
	}, function()
		SearchManager.set("aim")
		checkEq(SearchManager.passes("first"), true, "the existing row passes")

		SearchManager.register({ Id = "second", Label = "Silent Aim" })
		checkEq(SearchManager.passes("second"), true, "a row registered under the live term is ranked at once")

		SearchManager.register({ Id = "third", Label = "Watermark" })
		checkEq(SearchManager.passes("third"), false, "and one that does not match is filtered before it paints")

		SearchManager.unregister("first")
		checkEq(SearchManager.passes("first"), false, "an unknown id never passes a live term")
	end)

	checkEq(SearchManager.passes("anything"), true, "with no term, everything passes")
end)

runSpec("re-registering a renamed row re-applies the filter", function()
	withIndex({
		{ Id = "row", Label = "Aim Speed" },
	}, function()
		SearchManager.set("aim")
		checkEq(SearchManager.passes("row"), true, "it matched as Aim Speed")

		SearchManager.register({ Id = "row", Label = "Watermark" })
		checkEq(SearchManager.size(), 1, "the same id is still one entry, not two")
		checkEq(SearchManager.passes("row"), false, "and the new label is filtered against the live term")
	end)
end)

runSpec("rank is pure and apply is not", function()
	withIndex({
		{ Id = "a", Label = "Aim" },
		{ Id = "b", Label = "Frame" },
	}, function()
		SearchManager.set("aim")
		local before = SearchManager.matched()

		SearchManager.rank("frame")
		checkEq(SearchManager.matched(), before, "ranking against another query does not restyle the UI")
		checkEq(SearchManager.term(), "aim", "or replace the live term")

		checkEq(SearchManager.results()[1].id, "a", "the live term still ranks first")
	end)
end)

runSpec("highlight marks the run and escapes the rest", function()
	withIndex({
		{ Id = "aim", Label = "Aim <Part>" },
		{ Id = "fov", Label = "FOV Circle" },
	}, function()
		SearchManager.set("aim")
		local marked = SearchManager.highlight("aim")
		check(marked:find("&lt;Part&gt;") ~= nil, "the label is escaped before it reaches a RichText label", marked)
		check(marked:find('<font color="#') ~= nil, "and the match is wrapped in the accent colour", marked)

		SearchManager.set("circle")
		check(SearchManager.highlight("fov", "#00FF00"):find("#00FF00", 1, true) ~= nil, "a caller can pick the colour")

		SearchManager.set("")
		checkEq(SearchManager.highlight("fov"), "FOV Circle", "an empty term returns the plain label")

		checkEq(SearchManager.highlight("nobody"), nil, "and an unknown id has nothing to draw")

		SearchManager.register({ Id = "pct", Label = "100% Speed" })
		SearchManager.set("100%")
		checkEq(SearchManager.matched() >= 1, true, "a percent sign in a query is matched literally, not as a pattern")
		check(String.escapePattern("100%") == "100%%", "the pattern escape is what makes that true")
	end)
end)
