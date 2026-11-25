--[[
	Systems/Renderer — build what is visible now, spread the rest over frames.

	Why this exists: a hub that constructs its whole UI on execute pays for every row the user
	has not looked at. On a real device a page of ~30 rows built in one synchronous pass is where
	"executes and freezes" comes from — the cost is instances, not code. So a page asks to be
	built, and the build is sliced across RenderStepped frames with a cost ceiling.

	Two rules the rest of the library relies on:
	  * the loop runs only while work is queued, same contract as AnimationManager;
	  * a job is a closure that creates a bounded number of instances and declares its cost, so
	    the ceiling is in units the device actually feels rather than in milliseconds the test
	    harness cannot measure.

	Jobs run in enqueue order. A job that enqueues more work while the queue is draining is
	appended to the same pass it is running in, which is what lets a groupbox build its rows and
	then have those rows register themselves.
]]

local Signal = require("Flux/Utilities/Signal")
local Guard = require("Flux/Utilities/Guard")

local RunService = Guard.service("RunService")

local Renderer = {}

--- Fires when the queue empties, with the number of jobs that ran. Callers use it to reveal a
--- page only once its rows exist, instead of showing an empty panel for a few frames.
Renderer.Idle = Signal.new()

local budget = {
	-- Instances a single frame may create. Measured on the reference device: a row is roughly
	-- six instances, so this is about twenty rows a frame, which stays inside 16 ms.
	CostPerFrame = 120,
	-- A second ceiling so a queue of cost-1 jobs cannot occupy a frame forever.
	JobsPerFrame = 32,
}

local queue = {}
local connection: RBXScriptConnection? = nil
local draining = false
local stats = {
	passes = 0,
	ran = 0,
	lastPassJobs = 0,
	lastPassCost = 0,
	peakPassCost = 0,
}

local function stopLoop()
	if connection ~= nil then
		connection:Disconnect()
		connection = nil
	end
end

function Renderer.configure(options: { CostPerFrame: number?, JobsPerFrame: number? })
	options = options or {}
	if type(options.CostPerFrame) == "number" then
		budget.CostPerFrame = math.max(1, options.CostPerFrame)
	end
	if type(options.JobsPerFrame) == "number" then
		budget.JobsPerFrame = math.max(1, options.JobsPerFrame)
	end
	return budget
end

function Renderer.budget(): { CostPerFrame: number, JobsPerFrame: number }
	return budget
end

--- Queue a unit of work.
---   Name  — optional; a later enqueue with the same name replaces this one, which is how a
---           filter that runs on every keystroke does not rebuild a list four times.
---   Cost  — instances it will create (default 1).
---   Run   — the build itself.
---   OnDone— called with (ok, err) after Run. A job that throws is reported and dropped: one
---           broken row must not stop the rest of the page from appearing.
function Renderer.enqueue(job: { Name: string?, Cost: number?, Run: () -> (), OnDone: ((boolean, any) -> ())? }): any
	local entry = {
		name = job.Name,
		cost = math.max(1, job.Cost or 1),
		run = job.Run,
		onDone = job.OnDone,
	}

	if entry.name ~= nil then
		for index = #queue, 1, -1 do
			if queue[index].name == entry.name then
				table.remove(queue, index)
			end
		end
	end

	table.insert(queue, entry)

	if connection == nil and RunService ~= nil then
		connection = RunService.RenderStepped:Connect(Renderer.step)
	end

	return entry
end

--- A list of items built one job per item, so a long table arrives in frames rather than a freeze.
function Renderer.batch(items: {any}, make: (any, number) -> (), options: { Prefix: string?, Cost: number? })
	options = options or {}
	local prefix = options.Prefix or "batch"
	local cost = options.Cost or 6

	for index, item in ipairs(items) do
		Renderer.enqueue({
			Name = prefix .. "/" .. tostring(index),
			Cost = cost,
			Run = function()
				make(item, index)
			end,
		})
	end

	return prefix
end

function Renderer.cancel(name: string?): number
	if name == nil then
		local count = #queue
		table.clear(queue)
		stopLoop()
		return count
	end

	local removed = 0
	for index = #queue, 1, -1 do
		if queue[index].name == name then
			table.remove(queue, index)
			removed += 1
		end
	end

	if #queue == 0 then
		stopLoop()
	end
	return removed
end

function Renderer.pending(): number
	return #queue
end

function Renderer.isDraining(): boolean
	return draining
end

--- Drain one frame's worth of work. Called by RenderStepped; a spec (or a host that wants the
--- page complete before it fades in) can call it directly.
function Renderer.step(_delta: number?)
	if draining or #queue == 0 then
		return 0
	end

	draining = true
	local ran = 0
	local spent = 0

	while #queue > 0 and ran < budget.JobsPerFrame do
		local entry = queue[1]

		-- The queue is a priority order, so the head is not skipped over to find something that
		-- fits: a pass ends at the ceiling and the blocked job leads the next one. A job larger
		-- than a whole pass still runs on a fresh frame, because refusing it would stall the
		-- queue forever.
		if spent > 0 and entry.cost > budget.CostPerFrame - spent then
			break
		end

		table.remove(queue, 1)
		spent += entry.cost
		ran += 1

		local ok, err = pcall(entry.run)
		if entry.onDone ~= nil then
			local reportedOk, reportedErr = pcall(entry.onDone, ok, err)
			if not reportedOk then
				warn("[Flux] renderer: onDone threw: " .. tostring(reportedErr))
			end
		elseif not ok then
			warn("[Flux] renderer: job threw: " .. tostring(err))
		end
	end

	draining = false

	stats.passes += 1
	stats.ran += ran
	stats.lastPassJobs = ran
	stats.lastPassCost = spent
	stats.peakPassCost = math.max(stats.peakPassCost, spent)

	if #queue == 0 then
		stopLoop()
		Renderer.Idle:Dispatch(stats.ran)
	end

	return ran
end

--- Run everything now, ignoring the ceiling. Used when the window is opening and the alternative
--- is a visible half-built page — and by tests that want the end state without pumping frames.
function Renderer.flush(): number
	local total = 0
	local guard = 0
	while #queue > 0 do
		total += Renderer.step(0)
		guard += 1
		-- A job that re-enqueues itself would otherwise spin here forever; the queue is at worst
		-- one pass per item the library knows about, so this only trips on a caller bug.
		if guard > 100000 then
			warn("[Flux] renderer: flush did not converge; a job re-enqueues itself")
			break
		end
	end
	return total
end

function Renderer.stats(): {[string]: number}
	local out = {}
	for key, value in pairs(stats) do
		out[key] = value
	end
	out.queued = #queue
	return out
end

function Renderer.reset()
	table.clear(queue)
	stopLoop()
	for key in pairs(stats) do
		stats[key] = 0
	end
end

return Renderer
