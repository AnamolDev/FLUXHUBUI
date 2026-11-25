--[[
	spec 01 — the harness itself.

	These checks exist so that a later green run means something. If the stand-in gets
	geometry, parenting, or the unknown-member rule wrong, every spec after this one is
	measuring a machine that does not exist.
]]

runSpec("stub: instances, geometry, and the unknown-member rule", function()
	checkNoError(function()
		local frame = Instance.new("Frame")
		frame.Name = "Subject"
		frame.Position = UDim2.fromOffset(100, 200)
		frame.Size = UDim2.fromOffset(200, 100)

		checkEq(frame.Name, "Subject", "Name round-trips")
		checkEq(frame.AbsolutePosition.X, 100, "top-level absolute X equals the offset")
		checkEq(frame.AbsolutePosition.Y, 200, "top-level absolute Y equals the offset")
		checkEq(frame.AbsoluteSize.X, 200, "absolute width")
		checkEq(frame.AbsoluteSize.Y, 100, "absolute height")
	end, "basic frame geometry")

	checkNoError(function()
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(400, 200)
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromOffset(100, 100)

		checkEq(frame.AbsolutePosition.X, -100, "anchor point shifts the drawn origin left")
		checkEq(frame.AbsolutePosition.Y, 0, "anchor point shifts the drawn origin up")
	end, "anchor point")

	checkNoError(function()
		local screen = Instance.new("ScreenGui")
		local parent = Instance.new("Frame", screen)
		parent.Size = UDim2.fromScale(0.5, 0.25)
		parent.Position = UDim2.fromOffset(40, 60)

		local child = Instance.new("Frame", parent)
		child.Size = UDim2.fromOffset(10, 10)
		child.Position = UDim2.fromOffset(10, 10)

		checkEq(parent.AbsoluteSize.X, 640, "scale resolves against the viewport width")
		checkEq(parent.AbsoluteSize.Y, 180, "scale resolves against the viewport height")
		checkEq(child.AbsolutePosition.X, 50, "child absolute nests the parent offset")
		checkEq(child.AbsolutePosition.Y, 70, "child absolute nests the parent offset")

		checkEq(#screen:GetChildren(), 1, "GetChildren reports the parented frame")
		checkEq(parent.Parent, screen, "Parent is readable")
	end, "nested geometry and parenting")

	checkNoError(function()
		local parent = Instance.new("Frame")
		local child = Instance.new("Frame", parent)
		checkEq(#parent:GetChildren(), 1, "one child before destroy")
		child:Destroy()
		checkEq(#parent:GetChildren(), 0, "destroy unparents")
		checkEq(child.Parent, nil, "destroyed child has no parent")
	end, "destroy detaches")

	checkError(function()
		local frame = Instance.new("Frame")
		local _ = frame.AbsoluteCenter
	end, "is not a valid member", "reading a property the engine does not have raises")

	checkNoError(function()
		local frame = Instance.new("Frame")
		checkEq(frame.Parent, nil, "nil-valued real properties do not raise")
		checkEq(frame.LayoutOrder, 1, "declared defaults are present")
	end, "nil properties are distinguishable from unknown properties")

	checkNoError(function()
		local fired = 0
		local frame = Instance.new("Frame")
		local connection = frame:GetPropertyChangedSignal("BackgroundTransparency"):Connect(function(value)
			fired += 1
			checkEq(value, 0.5, "the signal carries the new value")
		end)

		frame.BackgroundTransparency = 0.5
		frame.BackgroundTransparency = 0.5
		connection:Disconnect()
		frame.BackgroundTransparency = 0.9

		checkEq(fired, 1, "fires once per changed value and stops after Disconnect")
	end, "GetPropertyChangedSignal")

	checkNoError(function()
		checkEq(Enum.KeyCode.E, Enum.KeyCode.E, "enum members are interned, so == works")
		checkNe(Enum.KeyCode.E, Enum.KeyCode.Q, "distinct members are distinct")
	end, "enum identity")

	checkNoError(function()
		setViewport(800, 600)
		local screen = Instance.new("ScreenGui")
		local frame = Instance.new("Frame", screen)
		frame.Size = UDim2.fromScale(1, 1)
		checkEq(frame.AbsoluteSize.X, 800, "viewport resize is observable")
		checkEq(frame.AbsoluteSize.Y, 600, "viewport resize is observable")
		setViewport(1280, 720)
	end, "responsive viewport")

	checkNoError(function()
		local before = instanceCount()
		Instance.new("Frame")
		checkEq(instanceCount() - before, 1, "the instance counter moves with Instance.new")
	end, "instance budget counter")
end)

runSpec("stub: time, input, and the file api switch", function()
	checkNoError(function()
		local base = harnessClock()
		stepClock(0.25)
		checkNear(harnessClock() - base, 0.25, 1e-9, "stepClock advances the fake clock")
	end, "fake clock")

	checkNoError(function()
		local received = 0
		local service = game:GetService("RunService")
		service.RenderStepped:Connect(function(delta)
			received += 1
			checkNear(delta, 1 / 60, 1e-9, "RenderStepped hands over the delta")
		end)
		stepClock(1 / 60)
		checkEq(received, 1, "RenderStepped fires once per stepped frame")
	end, "RenderStepped")

	checkNoError(function()
		local input = game:GetService("UserInputService")
		local seen = nil
		input.InputBegan:Connect(function(object)
			seen = object
		end)

		pressKey("LeftShift")
		checkEq(seen ~= nil and seen.KeyCode, Enum.KeyCode.LeftShift, "InputBegan carries the keycode")
		checkEq(input:IsKeyDown(Enum.KeyCode.LeftShift), true, "IsKeyDown follows pressKey")
		releaseKey("LeftShift")
		checkEq(input:IsKeyDown(Enum.KeyCode.LeftShift), false, "IsKeyDown follows releaseKey")
	end, "keyboard input")

	checkNoError(function()
		checkEq(isfile("flux-icon.png"), false, "nothing written yet")
		writefile("flux-icon.png", "abcdef")
		checkEq(isfile("flux-icon.png"), true, "writefile records the file")
		checkEq(readfile("flux-icon.png"), "abcdef", "readfile hands back the bytes")
		checkEq(getcustomasset("flux-icon.png"):find("flux-icon.png", 1, true) ~= nil, true, "asset id references the path")
	end, "file api")

	checkError(function()
		fileApiOn = false
		isfile("anything")
	end, "isfile is not available", "the file api can be switched off to model a client without it")

	checkNoError(function()
		fileApiOn = true
	end, "file api restored")

	checkNoError(function()
		local json = game:GetService("HttpService")
		local text = json:JSONEncode({ a = 1, b = { "x", "y" }, c = true, d = "two\"words" })
		local back = json:JSONDecode(text)
		checkEq(back.a, 1, "JSON numbers survive a round trip")
		checkEq(back.c, true, "JSON booleans survive a round trip")
		checkEq(back.b[1], "x", "JSON arrays survive a round trip")
		checkEq(back.d, 'two"words', "an escaped quote survives a round trip")
		checkEq(text, json:JSONEncode({ d = "two\"words", c = true, b = { "x", "y" }, a = 1 }), "encoding does not depend on insertion order")
	end, "JSON")
end)
