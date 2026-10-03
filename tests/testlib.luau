--!strict
-- Tiny assertion helper for the offline unit tests.
local T = {}

local failures = 0
local passes = 0
local current = ""

function T.describe(name: string, fn: () -> ())
	current = name
	local ok, err = pcall(fn)
	if not ok then
		failures += 1
		print(`  FAIL [{current}] threw: {err}`)
	end
end

function T.ok(cond: any, msg: string)
	if cond then
		passes += 1
	else
		failures += 1
		print(`  FAIL [{current}] {msg}`)
	end
end

function T.eq(a: any, b: any, msg: string)
	T.ok(a == b, `{msg}: expected {tostring(b)}, got {tostring(a)}`)
end

function T.near(a: number?, b: number, tol: number, msg: string)
	T.ok(a ~= nil and math.abs((a :: number) - b) <= tol, `{msg}: expected {b}, got {tostring(a)}`)
end

function T.finish(suite: string): number
	print(`{suite}: {passes} passed, {failures} failed`)
	local f = failures
	failures, passes = 0, 0
	return f
end

return T
