--[[
	spec 07 — Renderer.

	The promise this file tests is a cost ceiling: a page of rows must arrive over several frames,
	capped per frame, with the RenderStepped connection existing only while there is work. Both
	half of that matter — an uncapped builder is the "executes and freezes" bug, and a permanent
	connection is a hub that taxes every frame forever while sitting idle.

	Connection counts are read off the stub's signal handlers because "no work queued means no
	listener" is not observable any other way.
]]

local Renderer = assert(fluxRequire("Flux/Systems/Renderer"))
local RunService = game:GetService("RunService")

local function liveFrameHandlers(): number
	local count = 0
	for _, entry in ipairs(RunService.RenderStepped.handlers) do
		if entry.alive then
			count += 1
		end
	end
	return count
end

runSpec("configure", function()
	local budget = Renderer.configure({ CostPerFrame = 30, JobsPerFrame = 4 })
	checkEq(budget.CostPerFrame, 30, "the instance ceiling is settable")
	checkEq(budget.JobsPerFrame, 4, "and the job ceiling")
	checkEq(Renderer.pending(), 0, "nothing queued to start with")
	checkEq(Renderer.isDraining(), false, "and nothing running")
end)

runSpec("a frame runs a bounded slice", function()
	local built = 0
	local baseline = liveFrameHandlers()

	-- Six instances per row is what the real rows cost, so thirty is five rows' worth of work.
	for index = 1, 12 do
		Renderer.enqueue({
			Name = "rows/" .. index,
			Cost = 6,
			Run = function()
				built += 1
			end,
		})
	end

	checkEq(Renderer.pending(), 12, "twelve jobs queued")
	checkEq(liveFrameHandlers(), baseline + 1, "the loop connected while work exists")

	local first = Renderer.step(1 / 60)
	checkEq(first, 4, "the job ceiling limits one pass to four jobs")
	checkEq(built, 4, "and that many rows exist")
	checkEq(Renderer.stats().lastPassCost, 24, "24 instances of the 30 ceiling, since a job is not split")
	checkEq(Renderer.pending(), 8, "the rest are still queued")

	Renderer.step(1 / 60)
	Renderer.step(1 / 60)
	checkEq(built, 12, "and they arrive over the next two frames")
	checkEq(Renderer.pending(), 0, "queue empty")
	checkEq(liveFrameHandlers(), baseline, "the loop disconnected itself once the queue emptied")
end)

runSpec("the instance ceiling is respected too", function()
	Renderer.reset()
	Renderer.configure({ CostPerFrame = 100, JobsPerFrame = 64 })

	local built = 0
	for index = 1, 10 do
		Renderer.enqueue({
			Name = "heavy/" .. index,
			Cost = 25,
			Run = function()
				built += 1
			end,
		})
	end

	local ran = Renderer.step(1 / 60)
	checkEq(ran, 4, "four heavy jobs fit under 100 instances")
	checkEq(built, 4, "and no more")
	checkEq(Renderer.stats().lastPassCost, 100, "the pass spent exactly the ceiling")
	check(Renderer.stats().peakPassCost >= 100, "and remembers its worst frame")
	Renderer.flush()
	checkEq(built, 10, "flush finishes the rest")
	checkEq(Renderer.pending(), 0, "and leaves nothing")
end)

runSpec("a job that throws does not take the page with it", function()
	Renderer.reset()

	local built = 0
	local reports = {}

	Renderer.enqueue({
		Name = "bad",
		Cost = 1,
		Run = function()
			error("row builder raised")
		end,
		OnDone = function(ok, err)
			table.insert(reports, { ok = ok, err = tostring(err) })
		end,
	})

	for index = 1, 3 do
		Renderer.enqueue({
			Name = "good/" .. index,
			Cost = 1,
			Run = function()
				built += 1
			end,
			OnDone = function(ok)
				table.insert(reports, { ok = ok })
			end,
		})
	end

	Renderer.flush()
	checkEq(built, 3, "the healthy rows still built")
	checkEq(#reports, 4, "every job reported")
	checkEq(reports[1].ok, false, "the failing one reported failure")
	check(reports[1].err:find("row builder raised") ~= nil, "with its error preserved", reports[1].err)
	checkEq(reports[4].ok, true, "and the rest reported success")
end)

runSpec("a named job replaces the queued one", function()
	Renderer.reset()

	local runs = {}
	for _, value in ipairs({ "first", "second", "third" }) do
		Renderer.enqueue({
			Name = "filter",
			Cost = 1,
			Run = function()
				table.insert(runs, value)
			end,
		})
	end

	checkEq(Renderer.pending(), 1, "three enqueues under one name left one job")
	Renderer.flush()
	checkEq(#runs, 1, "and it ran once")
	checkEq(runs[1], "third", "with the newest work")
end)

runSpec("batching a list", function()
	Renderer.reset()

	local items = {}
	for index = 1, 20 do
		table.insert(items, index)
	end

	local seen = {}
	Renderer.batch(items, function(item, index)
		table.insert(seen, { item, index })
	end, { Prefix = "list", Cost = 4 })

	checkEq(Renderer.pending(), 20, "one job per item")

	Renderer.configure({ CostPerFrame = 12, JobsPerFrame = 8 })
	Renderer.step(1 / 60)
	checkEq(#seen, 3, "so a frame builds three rows at four instances each")

	-- Rows 1-3 already built, so the cancel has to name one of the seventeen still queued.
	Renderer.cancel("list/10")
	checkEq(Renderer.pending(), 16, "a single queued row can be cancelled by name")

	local removed = Renderer.cancel()
	checkEq(removed, 16, "and the whole queue with no name")
	checkEq(Renderer.pending(), 0, "empty")
end)

runSpec("Idle fires when the queue drains", function()
	Renderer.reset()

	local idleCount = 0
	local seenTotal = nil
	local unbind = Renderer.Idle:Connect(function(ran)
		idleCount += 1
		seenTotal = ran
	end)

	Renderer.enqueue({ Cost = 1, Run = function() end })
	checkEq(idleCount, 0, "not while work remains")

	Renderer.step(1 / 60)
	checkEq(idleCount, 1, "once at the moment the queue empties")
	checkEq(type(seenTotal) == "number", true, "reporting how much ran")

	Renderer.step(1 / 60)
	checkEq(idleCount, 1, "and not again on an empty queue")

	unbind:Disconnect()
	Renderer.reset()
end)

runSpec("a job may enqueue work that runs in a later pass", function()
	Renderer.reset()
	Renderer.configure({ CostPerFrame = 100, JobsPerFrame = 1 })

	local depth = {}
	Renderer.enqueue({
		Name = "parent",
		Cost = 1,
		Run = function()
			table.insert(depth, "parent")
			Renderer.enqueue({
				Name = "child",
				Cost = 1,
				Run = function()
					table.insert(depth, "child")
				end,
			})
		end,
	})

	checkEq(Renderer.step(1 / 60), 1, "one job per pass, so the child waits")
	checkEq(Renderer.pending(), 1, "and queued itself without recursing into this pass")
	Renderer.step(1 / 60)
	checkEq(depth[1], "parent", "parent first")
	checkEq(depth[2], "child", "child second")
	checkEq(Renderer.pending(), 0, "settled")
end)

runSpec("flush drains work a job adds while it is draining", function()
	Renderer.reset()
	Renderer.configure({ CostPerFrame = 100, JobsPerFrame = 2 })

	local order = {}
	Renderer.batch({ 1, 2, 3, 4 }, function(item, _position)
		table.insert(order, "row" .. item)
		if item >= 3 then
			Renderer.enqueue({
				Name = "rows/" .. item .. "/child",
				Cost = 5,
				Run = function()
					table.insert(order, "child" .. item)
				end,
			})
		end
	end, { Prefix = "rows", Cost = 5 })

	local queued = Renderer.pending()
	local ran = Renderer.flush()
	checkEq(queued, 4, "one job per item")
	checkEq(ran, 6, "flush counts the children those rows queued, not only what was queued when it started")
	checkEq(Renderer.pending(), 0, "and it does not stop while work remains")
	checkEq(order[4], "row4", "rows keep their order")
	checkEq(order[5], "child3", "and work added mid-drain lands after them")
	checkEq(#order, 6, "every builder ran exactly once")
	Renderer.reset()
end)

runSpec("a job too large for one frame is not starved", function()
	checkNoError(function()
		Renderer.reset()
		Renderer.configure({ CostPerFrame = 10, JobsPerFrame = 32 })

		local ran = 0
		for index = 1, 3 do
			Renderer.enqueue({
				Name = "big/" .. index,
				Cost = 40,
				Run = function()
					ran += 1
				end,
			})
		end

		checkEq(Renderer.step(1 / 60), 1, "an oversized job still runs on a fresh pass")
		checkEq(Renderer.pending(), 2, "and the pass stops after it instead of overshooting the ceiling")
		Renderer.flush()
		checkEq(ran, 3, "nothing sits in the queue forever")
		Renderer.reset()
	end, "oversized jobs")
end)

runSpec("stats and reset", function()
	Renderer.reset()
	Renderer.configure({ CostPerFrame = 120, JobsPerFrame = 32 })

	Renderer.enqueue({ Cost = 3, Run = function() end })
	Renderer.step(1 / 60)

	local stats = Renderer.stats()
	checkEq(stats.ran, 1, "lifetime job count")
	checkEq(stats.passes, 1, "passes run")
	checkEq(stats.lastPassCost, 3, "instances in the last pass")
	checkEq(stats.queued, 0, "nothing left")

	Renderer.enqueue({ Cost = 3, Run = function() end })
	Renderer.reset()
	checkEq(Renderer.pending(), 0, "reset drops queued work")
	checkEq(Renderer.stats().ran, 0, "and zeroes the counters")
end)
