--[[
	spec 06 — AnimationManager.

	Two things make these assertions trustworthy:

	  * `advance` pumps RenderStepped in one-sixtieth slices, so progress is a function of frames
	    the test ran, not of how long the process took. Durations and step sizes are deliberately
	    not knife-edge equal — a real client's last frame always lands past the end and clamps, and
	    a test that hovers exactly on the boundary measures floating point instead of behaviour.
	  * `active` is one queue shared by the whole module, so every block drains what it queues.
	    Otherwise an "activeCount() == 0" later in the file only proves the previous block finished.
]]

local Animation = assert(fluxRequire("Flux/Systems/AnimationManager"))
local Instance = assert(fluxRequire("Flux/Utilities/Instance"))
local String = assert(fluxRequire("Flux/Utilities/String"))

local function hex(value: any): string
	return String.colorToHex(value)
end

local function frame(): any
	return Instance.new("Frame", Instance.new("ScreenGui"), {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(200, 40),
	})
end

local function advance(seconds: number)
	local frames = math.max(1, math.floor(seconds * 60 + 0.5))
	pumpFrames(frames, seconds / frames)
end

local function drain()
	Animation.stopAll()
end

runSpec("the loop only exists while something is animating", function()
	checkEq(Animation.activeCount(), 0, "an idle menu has nothing ticking")

	local host = frame()
	Animation.to(host, { BackgroundTransparency = 0 }, { Duration = 0.5, Easing = "linear" })
	checkEq(Animation.activeCount(), 1, "one tween is queued")

	advance(0.25)
	checkNear(host.BackgroundTransparency, 0.5, 0.02, "and it interpolates over the frames the host actually ran")

	advance(0.4)
	checkEq(host.BackgroundTransparency, 0, "landing exactly on the goal, not near it")
	checkEq(Animation.activeCount(), 0, "a finished tween is removed from the queue, not flagged")
	drain()
end)

runSpec("one loop drives every element at once", function()
	local fast = frame()
	local slow = frame()

	Animation.to(fast, { BackgroundTransparency = 0 }, { Duration = 0.2, Easing = "linear" })
	Animation.to(slow, { BackgroundTransparency = 0 }, { Duration = 0.6, Easing = "linear" })
	checkEq(Animation.activeCount(), 2, "two tweens, one loop")

	advance(0.25)
	checkEq(fast.BackgroundTransparency, 0, "the shorter tween finished")
	check(slow.BackgroundTransparency > 0.3 and slow.BackgroundTransparency < 0.7, "the longer one is mid-flight", tostring(slow.BackgroundTransparency))
	checkEq(Animation.activeCount(), 1, "and the loop keeps running for the element still moving")

	advance(0.5)
	checkEq(slow.BackgroundTransparency, 0, "the last element lands")
	checkEq(Animation.activeCount(), 0, "the loop empties, which disconnects RenderStepped")
	drain()
end)

runSpec("OnEnd", function()
	checkNoError(function()
		local host = frame()
		local done = "never"
		Animation.to(host, { BackgroundTransparency = 0 }, {
			Duration = 0.1,
			OnEnd = function(completed)
				done = completed
			end,
		})
		advance(0.2)
		checkEq(done, true, "completion is reported to the callback")
		drain()
	end, "on natural completion")

	checkNoError(function()
		local host = frame()
		local order = {}
		local function note(tag)
			return function(completed)
				table.insert(order, tag .. ":" .. tostring(completed))
			end
		end

		Animation.to(host, { BackgroundTransparency = 0 }, { Duration = 0.3, OnEnd = note("first") })
		Animation.to(host, { BackgroundTransparency = 0.5 }, { Duration = 0.3, OnEnd = note("second") })
		checkEq(Animation.activeCount(), 1, "hover spam cannot stack two interpolations of one property")
		stepClock(0)
		checkEq(order[1], "first:false", "the superseded tween is told it did not complete")

		advance(0.4)
		checkEq(order[2], "second:true", "and the surviving one reports its own completion")
		drain()
	end, "a new tween replaces the running one for the same property")

	checkNoError(function()
		local fired = "not called"
		local host = frame()
		Animation.to(host, { BackgroundTransparency = 0 }, { Duration = 0.3, OnEnd = function(completed) fired = completed end })
		Animation.to(host, { Size = UDim2.fromOffset(40, 40) }, { Duration = 0.3 })
		checkEq(Animation.activeCount(), 2, "a different property on the same object runs alongside it")

		Animation.cancel(host)
		stepClock(0)
		checkEq(fired, "not called", "cancel drops the tweens without running their callbacks — a torn-down row must not fire follow-up state")
		checkEq(Animation.activeCount(), 0, "and the destroyed row stops ticking")
		checkEq(host.BackgroundTransparency, 1, "leaving each property wherever it stood")
		drain()
	end, "cancel")
end)

runSpec("the properties a GUI actually owns", function()
	checkNoError(function()
		-- `Transparency` is a BasePart member and does not exist on a Frame, so a preset that
		-- targeted it would animate an expando and leave the widget untouched.
		checkEq(Animation.presets.FadeIn.goals.BackgroundTransparency, 0, "FadeIn moves the gui property")
		checkEq(Animation.presets.FadeIn.goals.Transparency, nil, "and never the part property")

		local host = frame()
		checkEq(Animation.play(host, "FadeIn"), true, "the preset plays")
		advance(0.3)
		checkEq(host.BackgroundTransparency, 0, "to fully opaque")
		drain()
	end, "FadeIn")

	checkNoError(function()
		local host = Instance.new("Frame", Instance.new("ScreenGui"), { BackgroundTransparency = 0 })
		checkEq(Animation.play(host, "FadeOut"), true, "FadeOut plays")
		advance(0.3)
		checkEq(host.BackgroundTransparency, 1, "to fully transparent")
		drain()
	end, "FadeOut")

	checkNoError(function()
		local host = frame()
		checkEq(Animation.play(host, "Hover"), false, "Hover names timing, not a destination, so with no Goals it reports it did not play")
		checkEq(Animation.activeCount(), 0, "and queues nothing rather than claiming motion")

		checkEq(Animation.play(host, "Hover", { Goals = { BackgroundTransparency = 0.2 } }), true, "but plays when given a destination")
		advance(0.3)
		checkEq(host.BackgroundTransparency, 0.2, "landing on the caller's goal")
		drain()
	end, "a preset with no destination says so")

	checkNoError(function()
		checkEq(Animation.play(frame(), "NoSuchPreset"), false, "an unknown preset is rejected")
		drain()
	end, "unknown presets")

	checkNoError(function()
		local host = Instance.new("Frame", Instance.new("ScreenGui"), {
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundTransparency = 1,
		})
		checkEq(Animation.play(host, "SlideIn"), false, "SlideIn cannot run without a target")

		local target = UDim2.fromScale(0.5, 0.4)
		checkEq(Animation.play(host, "SlideIn", { TargetPosition = target }), true, "and plays with one")
		checkEq(host.Position.Y.Offset, 10, "parking the element below its target first")
		advance(0.3)
		checkEq(host.Position.Y.Scale, 0.4, "settling onto the target")
		checkEq(host.BackgroundTransparency, 0, "while fading in")
		drain()
	end, "SlideIn")

	checkNoError(function()
		local host = Instance.new("Frame", Instance.new("ScreenGui"), {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
		})
		checkEq(Animation.play(host, "PopIn"), true, "PopIn scales a size that has a scale term")
		check(host.Size.X.Scale < 1, "it starts shrunken", tostring(host.Size.X.Scale))
		advance(0.3)
		checkEq(host.Size.X.Scale, 1, "and lands at full size")
		drain()
	end, "PopIn")

	checkNoError(function()
		-- A pure-offset size has no scale term to multiply, so PopIn would do nothing visible.
		local host = Instance.new("Frame", Instance.new("ScreenGui"), {
			Size = UDim2.fromOffset(120, 30),
			BackgroundTransparency = 1,
		})
		checkEq(Animation.play(host, "PopIn"), true, "it reports it played")
		pumpFrames(1, 1 / 60)
		check(host.BackgroundTransparency < 1, "because it fell back to a fade instead of snapping", tostring(host.BackgroundTransparency))
		advance(0.3)
		checkEq(host.BackgroundTransparency, 0, "which completes")
		checkEq(host.Size.X.Offset, 120, "leaving the width the caller set")
		drain()
	end, "PopIn on an offset-only size")
end)

runSpec("geometry and colour interpolation", function()
	checkNoError(function()
		local host = frame()
		Animation.to(host, { Size = UDim2.fromOffset(400, 80) }, { Duration = 0.2, Easing = "linear" })
		advance(0.1)
		checkNear(host.Size.X.Offset, 300, 2, "UDim2 offsets interpolate component-wise")
		advance(0.2)
		checkEq(host.Size.X.Offset, 400, "and land exactly on the goal")
		drain()
	end, "Size")

	checkNoError(function()
		local host = Instance.new("Frame", Instance.new("ScreenGui"), { BackgroundColor3 = Color3.fromRGB(0, 0, 0) })
		Animation.to(host, { BackgroundColor3 = Color3.fromRGB(255, 255, 255) }, { Duration = 0.2, Easing = "linear" })
		advance(0.1)
		checkNear(host.BackgroundColor3.R, 0.5, 0.03, "Color3 lerps channel-wise")
		advance(0.2)
		checkEq(hex(host.BackgroundColor3), "FFFFFF", "to the exact end colour")
		drain()
	end, "BackgroundColor3")

	checkNoError(function()
		local host = frame()
		Animation.to(host, { AnchorPoint = Vector2.new(1, 1) }, { Duration = 0.2, Easing = "linear" })
		advance(0.1)
		checkNear(host.AnchorPoint.X, 0.5, 0.03, "Vector2 interpolates too")
		drain()
	end, "AnchorPoint")
end)

runSpec("a client that cannot complete a write must not hang its caller", function()
	checkNoError(function()
		local host = frame()
		local calls = 0

		-- Some members read back a real value and refuse every write: AbsolutePosition on the
		-- engine, or a newer property whose setter an older client never implemented. The tween
		-- can only be discovered frame by frame, so the loop has to drop the entry (rather than
		-- retry it 60 times a second) and still tell the caller the motion did not complete.
		readonlyWrites.BackgroundTransparency = true
		local queued = Animation.to(host, { BackgroundTransparency = 0 }, {
			Duration = 0.2,
			OnEnd = function()
				calls += 1
			end,
		})
		advance(0.5)
		readonlyWrites.BackgroundTransparency = nil

		checkEq(queued, 1, "the read succeeded, so a tween was queued in good faith")
		checkEq(Animation.activeCount(), 0, "the frame whose write was refused dropped it")
		checkEq(calls, 1, "reported exactly once, not on every dropped retry")
		checkEq(host.BackgroundTransparency, 1, "the element keeps the value the client allows")
		drain()
	end, "a write the client refuses releases its caller")

	checkNoError(function()
		-- On an ordinary client the engine never raises on an unknown WRITE — it creates an expando
		-- that renders as nothing — so the guard is the read that precedes it.
		local host = Instance.new("Frame", Instance.new("ScreenGui"), { BackgroundTransparency = 0 })
		local reported = "never"
		local queued = Animation.to(host, { NotARealProperty = 5 }, {
			Duration = 0.2,
			OnEnd = function(completed)
				reported = completed
			end,
		})
		checkEq(queued, 0, "a property with no current value is skipped")
		checkEq(Animation.activeCount(), 0, "and never queued")
		stepClock(0)
		checkEq(reported, false, "yet the caller is still told, so nothing that waits on OnEnd hangs")
		drain()
	end, "unknown properties are skipped, not animated as expandos")

	checkNoError(function()
		local host = frame()
		local calls = 0
		local queued = Animation.to(host, {
			BackgroundTransparency = 0,
			NotARealProperty = 5,
		}, {
			Duration = 0.2,
			OnEnd = function()
				calls += 1
			end,
		})

		checkEq(queued, 1, "only the property this client has is queued")
		advance(0.3)
		checkEq(host.BackgroundTransparency, 0, "and it animates normally")
		checkEq(calls, 1, "the shared callback fires once, from the tween that ran")
		drain()
	end, "a mixed goals table degrades per property")
end)

runSpec("reduced motion and speed", function()
	checkNoError(function()
		local host = frame()
		Animation.setReducedMotion(true)
		checkEq(Animation.isReducedMotion(), true, "the switch is readable")

		local done = "never"
		Animation.to(host, { BackgroundTransparency = 0 }, { Duration = 0.3, OnEnd = function(completed) done = completed end })
		checkEq(host.BackgroundTransparency, 0, "the goal is applied on the spot, no frames needed")
		checkEq(Animation.activeCount(), 0, "nothing is left running")
		stepClock(0)
		checkEq(done, true, "and completion is still reported")

		Animation.setReducedMotion(false)
		drain()
	end, "reduced motion lands on the resting state instantly")

	checkNoError(function()
		Animation.setSpeed(2)
		checkEq(Animation.getSpeed(), 2, "speed is readable")

		local host = frame()
		Animation.to(host, { BackgroundTransparency = 0 }, { Duration = 0.4, Easing = "linear" })
		advance(0.21)
		checkEq(host.BackgroundTransparency, 0, "so a 0.4 s tween finishes in 0.2 s of clock")

		Animation.setSpeed(1)
		checkEq(Animation.getSpeed(), 1, "and the default restores")
		drain()
	end, "setSpeed")

	checkNoError(function()
		local host = frame()
		Animation.to(host, { BackgroundTransparency = 0 }, { Duration = 0.5 })
		checkEq(Animation.activeCount(), 1, "something is running before stopAll")
		Animation.stopAll()
		checkEq(Animation.activeCount(), 0, "stopAll clears the queue")
		checkEq(host.BackgroundTransparency, 1, "leaving the element wherever the motion was interrupted")
	end, "stopAll")
end)

runSpec("easing", function()
	checkEq(Animation.easing.linear(0), 0, "linear starts at zero")
	checkEq(Animation.easing.linear(1), 1, "and ends at one")
	checkEq(Animation.easing.outQuad(1), 1, "outQuad lands on one")
	checkEq(Animation.easing.outQuint(1), 1, "outQuint lands on one")
	checkEq(Animation.easing.inOutQuad(0), 0, "inOutQuad starts at zero")
	checkEq(Animation.easing.inOutQuad(1), 1, "and ends at one")
	checkNear(Animation.easing.outQuad(0.5), 0.75, 0.001, "outQuad front-loads motion")
	check(Animation.easing.outBack(0.6) > 1, "outBack overshoots, which is what makes a pop feel springy")
	checkEq(Animation.easing.outExpo(1), 1, "outExpo states its endpoint instead of settling for 0.999")
	checkEq(Animation.easing.outElastic(0), 0, "outElastic is defined at both ends")
	checkEq(Animation.easing.outElastic(1), 1, "and lands")
end)

runSpec("a duration of zero is a direct set, not a tween", function()
	checkNoError(function()
		local host = frame()
		local done = "never"
		Animation.to(host, { BackgroundTransparency = 0 }, { Duration = 0, OnEnd = function(completed) done = completed end })
		checkEq(host.BackgroundTransparency, 0, "applied immediately")
		checkEq(Animation.activeCount(), 0, "nothing queued")
		stepClock(0)
		checkEq(done, true, "callback still fires")
		drain()
	end, "zero duration")
end)
