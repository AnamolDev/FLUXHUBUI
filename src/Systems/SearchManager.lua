--[[
	Systems/SearchManager — the index the search box queries.

	Rows register themselves when they are built and unregister when they are destroyed, so the
	index cannot drift away from what is on screen — a stale entry is the usual reason a search
	highlights something the user can then not click.

	Scoring is tiered rather than fuzzy-weighted: the order people expect out of a hub search is
	"exact name, then names starting with it, then anything containing it", and a scored edit
	distance reliably produces something else. Subsequence matching is kept at the bottom because
	it is what makes `hnds` find `Headless`, and it should never outrank a real prefix.

	Hiding is the caller's job: the manager says which entries matched, and the row decides whether
	that means Visible=false or being removed from its layout, because only the row knows.
]]

local Signal = require("Flux/Utilities/Signal")
local String = require("Flux/Utilities/String")

local SearchManager = {}

--- Fired (term, matches) whenever the term changes. Tabs listen so a re-typed query re-slices the
--- rows they own rather than leaving a filtered page showing everything.
SearchManager.Changed = Signal.new()

local entries = {}
local order = {}
local term = ""

--- A row's searchable text is its label plus whatever the author adds: a description, the tab name,
--- and the words a user might type instead ("esp" for "Chams").
function SearchManager.register(entry: {
	Id: any,
	Label: string,
	Text: string?,
	Keywords: {string}?,
	Tab: string?,
	OnMatch: ((any, boolean) -> ())?,
}): boolean
	if entry == nil or entry.Id == nil or type(entry.Label) ~= "string" then
		warn("[Flux] search: an entry needs an Id and a Label")
		return false
	end

	local haystack = string.lower(entry.Label)
	if type(entry.Text) == "string" then
		haystack = haystack .. " " .. string.lower(entry.Text)
	end
	if type(entry.Tab) == "string" then
		haystack = haystack .. " " .. string.lower(entry.Tab)
	end
	if type(entry.Keywords) == "table" then
		for _, keyword in ipairs(entry.Keywords) do
			haystack = haystack .. " " .. string.lower(tostring(keyword))
		end
	end

	if entries[entry.Id] ~= nil then
		-- Re-registering under a live term must re-apply the filter, or a renamed row would show
		-- while the search says it does not match.
		SearchManager.unregister(entry.Id)
	end

	entries[entry.Id] = {
		id = entry.Id,
		label = entry.Label,
		haystack = haystack,
		onMatch = entry.OnMatch,
		tab = entry.Tab,
		score = 0,
		matched = false,
	}
	table.insert(order, entry.Id)

	-- Registration position is the tie-break, recorded once instead of searched for on every
	-- comparison.
	entries[entry.Id].slot = #order

	if term ~= "" then
		SearchManager.apply()
	end

	return true
end

function SearchManager.unregister(id: any): boolean
	if entries[id] == nil then
		return false
	end
	entries[id] = nil
	for index = #order, 1, -1 do
		if order[index] == id then
			table.remove(order, index)
		end
	end
	return true
end

function SearchManager.clear()
	table.clear(entries)
	table.clear(order)
	-- The term goes with the index: a hub rebuilt after unload starts with nothing filtered, and a
	-- stale term would silently hide the rows the next window registers.
	term = ""
end

function SearchManager.size(): number
	return #order
end

--- Tiered score for one entry, 0 meaning no match.
local function scoreFor(haystack: string, label: string, query: string): number
	if query == "" then
		return 1
	end

	if label == query then
		return 100
	end

	if String.startsWith(label, query) then
		return 80
	end

	-- A word boundary inside a multi-word label ("chams esp" matching "esp") is as good as a
	-- prefix on the whole label.
	if haystack:find("%f[%w]" .. String.escapePattern(query), 1, false) ~= nil then
		return 70
	end

	if haystack:find(String.escapePattern(query), 1, false) ~= nil then
		return 50
	end

	-- Subsequence, cheapest useful fallback: every character appears in order.
	local cursor = 1
	for index = 1, #query do
		local char = query:sub(index, index)
		local found = haystack:find(char, cursor, true)
		if found == nil then
			return 0
		end
		cursor = found + 1
	end

	return 20
end

--- Rank the index against `query` without touching state. Returns entries with score > 0.
function SearchManager.rank(query: string?): {{entry: any, score: number}}
	local needle = string.lower(String.trim(query or term))
	local out = {}

	for _, id in ipairs(order) do
		local entry = entries[id]
		if entry ~= nil then
			local score = scoreFor(entry.haystack, string.lower(entry.label), needle)
			if score > 0 then
				table.insert(out, { entry = entry, score = score })
			end
		end
	end

	-- Best first, then registration order, so two equally good rows keep the order the author put
	-- them in instead of shuffling by table iteration.
	table.sort(out, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.entry.slot < b.entry.slot
	end)

	return out
end

--- Apply the current term to every row and report what matched.
function SearchManager.apply(): number
	local needle = string.lower(String.trim(term))
	local matched = 0

	for _, id in ipairs(order) do
		local entry = entries[id]
		if entry ~= nil then
			local score = needle == "" and 1 or scoreFor(entry.haystack, string.lower(entry.label), needle)
			local isMatch = score > 0
			entry.score = score
			entry.matched = isMatch

			if isMatch then
				matched += 1
			end

			if entry.onMatch ~= nil then
				local ok, err = pcall(entry.onMatch, entry, isMatch)
				if not ok then
					warn("[Flux] search: row callback threw: " .. tostring(err))
				end
			end
		end
	end

	return matched
end

--- The entry point a search box calls on every keystroke.
function SearchManager.set(nextTerm: string?): number
	term = type(nextTerm) == "string" and nextTerm or ""
	local matched = SearchManager.apply()
	SearchManager.Changed:Dispatch(term, SearchManager.results())
	return matched
end

function SearchManager.term(): string
	return term
end

--- Matches for the live term, in rank order.
function SearchManager.results(): {any}
	local out = SearchManager.rank(term)
	local entries_ = {}
	for _, hit in ipairs(out) do
		table.insert(entries_, hit.entry)
	end
	return entries_
end

function SearchManager.matched(): number
	local count = 0
	for _, id in ipairs(order) do
		local entry = entries[id]
		if entry ~= nil and entry.matched then
			count += 1
		end
	end
	return count
end

--- HTML-safe label with the matching run wrapped in the accent colour, for the row to render.
function SearchManager.highlight(id: any, colorHex: string?): string?
	local entry = entries[id]
	if entry == nil then
		return nil
	end

	local needle = String.trim(term)
	if needle == "" then
		return String.escape(entry.label)
	end

	return String.highlight(String.escape(entry.label), needle, colorHex or "#FF4F68")
end

--- Was this row filtered out by the live term? Rows ask this when they are built mid-search, so a
--- page sliced in later frames still respects the query.
function SearchManager.passes(id: any): boolean
	if String.trim(term) == "" then
		return true
	end
	local entry = entries[id]
	return entry ~= nil and entry.matched == true
end

return SearchManager
