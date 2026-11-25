--[[
	harness/tap.lua — the assertion surface the specs use.

	Two rules matter more than convenience here:

	  * a failed check must not stop the run. One broken spec hiding the other nine is how a
	    suite turns green by accident;
	  * the verdict is a line on stdout, not the process exit code. luau.exe exits 0 after a
	    runtime error it prints, so "no FAIL lines" would be meaningless without the explicit
	    RESULT banner the runner looks for.
]]

local passed = 0
local failed = 0
local specName = "(no spec)"

local function report(kind: string, detail: string)
	print(kind .. " [" .. specName .. "] " .. detail)
end

function beginSpec(name: string)
	specName = name
	print("SPEC " .. name)
end

function endSpec()
	specName = "(between specs)"
end

function fail(detail: string)
	failed += 1
	report("FAIL", detail)
end

function pass(detail: string)
	passed += 1
end

function check(condition: any, detail: string): boolean
	if condition then
		pass()
		return true
	end
	fail(detail .. " (expected a truthy value, got " .. tostring(condition) .. ")")
	return false
end

function checkFalse(condition: any, detail: string): boolean
	if not condition then
		pass()
		return true
	end
	fail(detail .. " (expected falsy, got " .. tostring(condition) .. ")")
	return false
end

--- Exact equality. Numbers compare by value, so 3 == 3.0 passes; a table compares by
--- identity, which is what the instance-owning assertions rely on.
function checkEq(actual: any, expected: any, detail: string): boolean
	if actual == expected then
		pass()
		return true
	end
	fail(detail .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
	return false
end

function checkNe(actual: any, unexpected: any, detail: string): boolean
	if actual ~= unexpected then
		pass()
		return true
	end
	fail(detail .. " (expected something other than " .. tostring(unexpected) .. ")")
	return false
end

function checkNear(actual: number, expected: number, tolerance: number, detail: string): boolean
	if type(actual) == "number" and math.abs(actual - expected) <= tolerance then
		pass()
		return true
	end
	fail(
		detail .. " (expected " .. tostring(expected) .. " +/- " .. tostring(tolerance) .. ", got "
			.. tostring(actual) .. ")"
	)
	return false
end

function checkError(fn: () -> (), expectSubstring: string?, detail: string): boolean
	local ok, err = pcall(fn)

	if ok then
		fail(detail .. " (expected an error, call succeeded)")
		return false
	end

	local text = tostring(err)
	if expectSubstring ~= nil and not text:find(expectSubstring, 1, true) then
		fail(detail .. " (error was " .. text .. ", expected it to mention " .. expectSubstring .. ")")
		return false
	end

	pass()
	return true
end

--- Asserts the call raises nothing. The message is printed, because a spec that silently
--- swallows an exception is the one failure mode a hand-run test suite always hides.
function checkNoError(fn: () -> (), detail: string): boolean
	local ok, err = pcall(fn)

	if ok then
		pass()
		return true
	end

	fail(detail .. " (threw: " .. tostring(err) .. ")")
	return false
end

function requireModule(requireFn: (string) -> any, path: string): any
	local ok, result = pcall(requireFn, path)

	if not ok then
		fail("module " .. path .. " failed to load: " .. tostring(result))
		return nil
	end

	return result
end

function runSpec(name: string, fn: () -> ())
	beginSpec(name)
	local ok, err = pcall(fn)
	if not ok then
		fail("uncaught error: " .. tostring(err))
	end
	endSpec()
end

function finishTests(): number
	print(("RESULT checks=%d failures=%d"):format(passed, failed))
	if failed > 0 then
		print("VERDICT FAILED")
		return 1
	end
	print("VERDICT OK")
	return 0
end
