--!strict

local LorenTest = {}

export type Failure = { path: string, message: string }
export type FileResult = { name: string, passed: number, failed: number, skipped: number, durationMs: number }
export type Results = {
	label: string?,
	passed: number,
	failed: number,
	skipped: number,
	durationMs: number,
	failures: { Failure },
	files: { FileResult },
}
export type Spec = { name: string, fn: ((any) -> ())?, loadError: string? }
export type RunOptions = { label: string?, timeout: number?, hookTimeout: number?, filter: string? }
export type Spy = { calls: { { n: number, [number]: any } }, count: number, fn: (...any) -> ...any }

type Hook = () -> ()
type TestNode = { kind: "test", name: string, fn: (() -> ())?, timeout: number?, skip: boolean }
type SuiteNode = {
	kind: "suite",
	name: string,
	children: { any },
	beforeAll: { Hook },
	afterAll: { Hook },
	beforeEach: { Hook },
	afterEach: { Hook },
	errors: { string },
}

local DEFAULT_TIMEOUT = 10

-- [[ Formatting ]]

local function fmt(value: any, depth: number?): string
	local kind = typeof(value)
	if kind == "string" then
		local s = value :: string
		if #s > 80 then
			s = string.sub(s, 1, 77) .. "..."
		end
		return string.format("%q", s)
	elseif kind == "number" then
		return tostring(value)
	elseif kind == "Instance" then
		return "Instance(" .. (value :: Instance):GetFullName() .. ")"
	elseif kind == "buffer" then
		return "buffer(" .. buffer.len(value) .. ")"
	elseif kind == "table" then
		local mt = getmetatable(value)
		if typeof(mt) == "table" and rawget(mt, "__tostring") then
			local ok, s = pcall(tostring, value)
			if ok then
				return s
			end
		end
		local d = depth or 0
		if d >= 2 then
			return "{...}"
		end
		local parts = {}
		local count = 0
		for k, v in value do
			count += 1
			if count > 6 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, "[" .. fmt(k, 2) .. "] = " .. fmt(v, d + 1))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	elseif kind == "nil" or kind == "boolean" then
		return tostring(value)
	end
	return kind .. "(" .. tostring(value) .. ")"
end
LorenTest.format = fmt

local function errorToString(err: any): string
	if typeof(err) == "string" then
		return err
	end
	local ok, s = pcall(tostring, err)
	return if ok then s else "<unprintable error>"
end

-- [[ Deep equality ]]

local function keyString(k: any): string
	if typeof(k) == "string" and string.match(k, "^[%a_][%w_]*$") then
		return "." .. k
	end
	return "[" .. fmt(k, 2) .. "]"
end

local function deepEqual(a: any, b: any, path: string, seen: { [any]: any }): (boolean, string?)
	if rawequal(a, b) then
		return true, nil
	end
	local ta, tb = typeof(a), typeof(b)
	if ta ~= tb then
		return false, string.format("%s: expected %s (%s), got %s (%s)", path, fmt(b), tb, fmt(a), ta)
	end
	if ta == "number" then
		if a == b or (a ~= a and b ~= b) then
			return true, nil
		end
		return false, string.format("%s: expected %s, got %s", path, fmt(b), fmt(a))
	elseif ta == "buffer" then
		if buffer.tostring(a) == buffer.tostring(b) then
			return true, nil
		end
		return false, string.format("%s: buffers differ (%d vs %d bytes)", path, buffer.len(a), buffer.len(b))
	elseif ta ~= "table" then
		if a == b then
			return true, nil
		end
		return false, string.format("%s: expected %s, got %s", path, fmt(b), fmt(a))
	end
	if seen[a] == b then
		return true, nil
	end
	seen[a] = b
	for k, va in a do
		local ok, why = deepEqual(va, rawget(b, k), path .. keyString(k), seen)
		if not ok then
			return false, why
		end
	end
	for k, vb in b do
		if rawget(a, k) == nil then
			return false, string.format("%s%s: missing (expected %s)", path, keyString(k), fmt(vb))
		end
	end
	return true, nil
end
LorenTest.deepEqual = function(a: any, b: any): (boolean, string?)
	return deepEqual(a, b, "value", {})
end

local function patternMatches(message: string, pattern: string): boolean
	if string.find(message, pattern, 1, true) then
		return true
	end
	local ok, found = pcall(function()
		return string.find(message, pattern)
	end)
	return ok and found ~= nil
end

-- [[ expect ]]

-- Each matcher returns (pass: boolean, failMessage: string, negatedFailMessage: string, usageError: string?).
type Matcher = (actual: any, ...any) -> ...any

local matchers: { [string]: Matcher } = {}

matchers.toBe = function(actual: any, expected: any): ...any
	local pass = rawequal(actual, expected)
		or actual == expected
		or (typeof(actual) == "number" and typeof(expected) == "number" and actual ~= actual and expected ~= expected)
	return pass,
		string.format("expected %s to be %s", fmt(actual), fmt(expected)),
		string.format("expected %s not to be %s", fmt(actual), fmt(expected))
end

matchers.toEqual = function(actual: any, expected: any): ...any
	local pass, why = deepEqual(actual, expected, "value", {})
	return pass,
		string.format("expected deep equality: %s", why or "?"),
		string.format("expected %s not to deep-equal %s", fmt(actual), fmt(expected))
end

matchers.toBeNil = function(actual: any): ...any
	return actual == nil, string.format("expected %s to be nil", fmt(actual)), "expected a non-nil value, got nil"
end

matchers.toBeTruthy = function(actual: any): ...any
	return actual ~= nil and actual ~= false,
		string.format("expected %s to be truthy", fmt(actual)),
		string.format("expected %s to be falsy", fmt(actual))
end

matchers.toBeFalsy = function(actual: any): ...any
	return actual == nil or actual == false,
		string.format("expected %s to be falsy", fmt(actual)),
		string.format("expected %s to be truthy", fmt(actual))
end

matchers.toThrow = function(actual: any, pattern: any): ...any
	if typeof(actual) ~= "function" then
		return false, "", "", "expect(fn).toThrow(): the value is " .. typeof(actual) .. ", not a function"
	end
	if pattern ~= nil and typeof(pattern) ~= "string" then
		return false, "", "", "toThrow(pattern): pattern must be a string"
	end
	local ok, err = pcall(actual)
	if ok then
		return false,
			if pattern
				then string.format("expected the function to throw %s, but it returned", fmt(pattern))
				else "expected the function to throw, but it returned",
			""
	end
	local message = errorToString(err)
	if pattern == nil or patternMatches(message, pattern) then
		return true, "", "expected the function not to throw, but it threw: " .. message
	end
	return false,
		string.format("expected an error matching %s, got: %s", fmt(pattern), message),
		string.format("expected an error not matching %s", fmt(pattern))
end

matchers.toBeCloseTo = function(actual: any, expected: any, digits: any): ...any
	if typeof(actual) ~= "number" or typeof(expected) ~= "number" then
		return false,
			"",
			"",
			string.format("toBeCloseTo needs numbers, got %s and %s", typeof(actual), typeof(expected))
	end
	local d = if typeof(digits) == "number" then digits else 2
	local tolerance = (10 ^ -d) / 2
	local pass = actual == expected or math.abs(actual - expected) < tolerance
	return pass,
		string.format("expected %s to be close to %s (tolerance %s)", fmt(actual), fmt(expected), tostring(tolerance)),
		string.format("expected %s not to be close to %s", fmt(actual), fmt(expected))
end

local function comparison(name: string, symbol: string, compare: (number, number) -> boolean): Matcher
	return function(actual: any, expected: any): ...any
		if typeof(actual) ~= "number" or typeof(expected) ~= "number" then
			return false,
				"",
				"",
				string.format("%s needs numbers, got %s and %s", name, typeof(actual), typeof(expected))
		end
		return compare(actual, expected),
			string.format("expected %s %s %s", fmt(actual), symbol, fmt(expected)),
			string.format("expected not %s %s %s", fmt(actual), symbol, fmt(expected))
	end
end

matchers.toBeGreaterThan = comparison("toBeGreaterThan", ">", function(a, b)
	return a > b
end)
matchers.toBeGreaterThanOrEqual = comparison("toBeGreaterThanOrEqual", ">=", function(a, b)
	return a >= b
end)
matchers.toBeLessThan = comparison("toBeLessThan", "<", function(a, b)
	return a < b
end)
matchers.toBeLessThanOrEqual = comparison("toBeLessThanOrEqual", "<=", function(a, b)
	return a <= b
end)

matchers.toContain = function(actual: any, item: any): ...any
	local pass = false
	if typeof(actual) == "string" then
		if typeof(item) ~= "string" then
			return false, "", "", "toContain on a string needs a string, got " .. typeof(item)
		end
		pass = string.find(actual, item, 1, true) ~= nil
	elseif typeof(actual) == "table" then
		for _, v in actual do
			if v == item or (typeof(v) == "number" and typeof(item) == "number" and v ~= v and item ~= item) then
				pass = true
				break
			end
		end
	else
		return false, "", "", "toContain needs a string or a table, got " .. typeof(actual)
	end
	return pass,
		string.format("expected %s to contain %s", fmt(actual), fmt(item)),
		string.format("expected %s not to contain %s", fmt(actual), fmt(item))
end

matchers.toHaveLength = function(actual: any, expected: any): ...any
	local length: number
	if typeof(actual) == "string" or typeof(actual) == "table" then
		length = #actual
	elseif typeof(actual) == "buffer" then
		length = buffer.len(actual)
	else
		return false, "", "", "toHaveLength needs a string, table or buffer, got " .. typeof(actual)
	end
	return length == expected,
		string.format("expected length %s, got %d (%s)", fmt(expected), length, fmt(actual)),
		string.format("expected length other than %s", fmt(expected))
end

local MATCHER_NAMES = {}
for name in matchers do
	table.insert(MATCHER_NAMES, name)
end
table.sort(MATCHER_NAMES)

local function buildExpectation(actual: any, negate: boolean): { [string]: any }
	local expectation: { [string]: any } = {}
	for _, name in MATCHER_NAMES do
		local impl = matchers[name]
		expectation[name] = function(...: any)
			-- Accept both expect(v).toBe(x) and expect(v):toBe(x).
			local pass, message, negatedMessage, usage
			if select("#", ...) > 0 and rawequal((...), expectation) then
				pass, message, negatedMessage, usage = impl(actual, select(2, ...))
			else
				pass, message, negatedMessage, usage = impl(actual, ...)
			end
			if usage then
				error(usage, 2)
			elseif negate then
				if pass then
					error(negatedMessage, 2)
				end
			elseif not pass then
				error(message, 2)
			end
		end
	end
	return expectation
end

function LorenTest.expect(actual: any): any
	local expectation = buildExpectation(actual, false)
	expectation.never = buildExpectation(actual, true)
	return expectation
end

function LorenTest.spy(fn: ((...any) -> ...any)?): Spy
	local spy = { calls = {}, count = 0 } :: any
	local function record(...: any): ...any
		spy.count += 1
		table.insert(spy.calls, table.pack(...))
		if fn then
			return fn(...)
		end
		return
	end
	spy.fn = record
	return setmetatable(spy, {
		__call = function(_, ...)
			return record(...)
		end,
	}) :: any
end

-- [[ Running one function with a timeout ]]

local function captureError(err: any): string
	local message = errorToString(err)
	-- Point at the spec line when the error came from library code.
	local trace = debug.traceback(nil, 2)
	local where = string.match(trace, "([^\n]-%.spec:%d+)")
	if where then
		where = string.gsub(where, "^%s+", "")
		if not string.find(message, where, 1, true) then
			message ..= "\n    at " .. where
		end
	end
	return message
end

-- Returns nil on success, or an error message. Never throws; never resumes an abandoned thread.
local function runWithTimeout(fn: () -> (), timeout: number): string?
	local caller = coroutine.running()
	local finished = false
	local waiting = false
	local failure: string? = nil
	local timer: thread? = nil

	local worker = coroutine.create(function()
		local ok, err = xpcall(fn :: any, captureError)
		if finished then
			return -- timed out earlier; the result no longer matters
		end
		finished = true
		if not ok then
			failure = if typeof(err) == "string" then err else errorToString(err)
		end
		if timer then
			pcall(task.cancel, timer)
		end
		if waiting then
			task.defer(caller)
		end
	end)
	task.spawn(worker)
	if finished then
		return failure
	end

	timer = task.delay(timeout, function()
		if finished then
			return
		end
		finished = true
		failure = string.format("timed out after %s s", tostring(timeout))
		if waiting then
			task.defer(caller)
		end
	end)
	waiting = true
	while not finished do
		coroutine.yield()
	end
	waiting = false
	return failure
end

-- [[ Collection ]]

local function newSuite(name: string): SuiteNode
	return {
		kind = "suite",
		name = name,
		children = {},
		beforeAll = {},
		afterAll = {},
		beforeEach = {},
		afterEach = {},
		errors = {},
	}
end

local function newContext(root: SuiteNode): (any, () -> ())
	local stack: { SuiteNode } = { root }
	local collecting = true
	local t = {}

	local function current(): SuiteNode
		return stack[#stack]
	end

	local function guard(what: string)
		if not collecting then
			error(what .. "() can only be called while the spec is being collected, not inside a test or hook", 3)
		end
	end

	function t.describe(name: string, body: () -> ())
		guard("describe")
		local suite = newSuite(tostring(name))
		table.insert(current().children, suite)
		table.insert(stack, suite)
		local ok, err = xpcall(body :: any, captureError)
		table.remove(stack)
		if not ok then
			table.insert(suite.errors, "describe body failed: " .. errorToString(err))
		end
	end

	function t.it(name: string, fn: () -> (), opts: { timeout: number?, skip: boolean? }?)
		guard("it")
		local test: TestNode = {
			kind = "test",
			name = tostring(name),
			fn = if typeof(fn) == "function" then fn else nil,
			timeout = if opts and typeof(opts.timeout) == "number" then opts.timeout else nil,
			skip = if opts and opts.skip then true else false,
		}
		table.insert(current().children, test)
	end

	function t.beforeAll(fn: Hook)
		guard("beforeAll")
		table.insert(current().beforeAll, fn)
	end
	function t.afterAll(fn: Hook)
		guard("afterAll")
		table.insert(current().afterAll, fn)
	end
	function t.beforeEach(fn: Hook)
		guard("beforeEach")
		table.insert(current().beforeEach, fn)
	end
	function t.afterEach(fn: Hook)
		guard("afterEach")
		table.insert(current().afterEach, fn)
	end

	t.expect = LorenTest.expect
	t.spy = LorenTest.spy

	return t, function()
		collecting = false
	end
end

function LorenTest.collect(container: Instance, prefix: string?): { Spec }
	local specs: { Spec } = {}
	local function visit(parent: Instance, path: string)
		for _, child in parent:GetChildren() do
			if string.sub(child.Name, 1, 1) == "_" then
				continue
			end
			local childPath = if path == "" then child.Name else path .. "/" .. child.Name
			local isSpec = child:IsA("ModuleScript") and string.match(child.Name, "%.spec$") ~= nil
			if isSpec then
				local ok, result = pcall(require, child :: ModuleScript)
				if not ok then
					table.insert(specs, { name = childPath, loadError = "failed to load: " .. errorToString(result) })
				elseif typeof(result) ~= "function" then
					table.insert(
						specs,
						{ name = childPath, loadError = "a spec must return function(t), got " .. typeof(result) }
					)
				else
					table.insert(specs, { name = childPath, fn = result :: any })
				end
			elseif child:IsA("Folder") or child:IsA("ModuleScript") or child:IsA("Configuration") then
				visit(child, childPath)
			end
		end
	end
	visit(container, prefix or "")
	table.sort(specs, function(a: Spec, b: Spec)
		return a.name < b.name
	end)
	return specs
end

-- [[ Execution ]]

type RunState = {
	results: Results,
	file: FileResult,
	timeout: number,
	hookTimeout: number,
	filter: string?,
}

local function fail(state: RunState, path: string, message: string)
	state.results.failed += 1
	state.file.failed += 1
	table.insert(state.results.failures, { path = path, message = message })
end

local function countTests(suite: SuiteNode, state: RunState, path: string): number
	local n = 0
	for _, child in suite.children do
		if child.kind == "test" then
			local testPath = path .. " > " .. child.name
			if
				not child.skip
				and child.fn
				and (state.filter == nil or string.find(testPath, state.filter, 1, true))
			then
				n += 1
			end
		else
			n += countTests(child, state, path .. " > " .. child.name)
		end
	end
	return n
end

local function settleSubtree(suite: SuiteNode, state: RunState, path: string, message: string?)
	for _, child in suite.children do
		local childPath = path .. " > " .. child.name
		if child.kind == "test" then
			if child.skip or not child.fn then
				state.results.skipped += 1
				state.file.skipped += 1
			elseif message and (state.filter == nil or string.find(childPath, state.filter, 1, true)) then
				fail(state, childPath, message)
			end
		else
			for _, err in child.errors do
				fail(state, childPath, err)
			end
			settleSubtree(child, state, childPath, message)
		end
	end
end

local function runSuite(suite: SuiteNode, path: string, eachChain: { SuiteNode }, state: RunState)
	for _, err in suite.errors do
		fail(state, path, err)
	end
	if countTests(suite, state, path) == 0 then
		settleSubtree(suite, state, path, nil)
		return
	end

	local chain = table.clone(eachChain)
	table.insert(chain, suite)

	for _, hook in suite.beforeAll do
		local err = runWithTimeout(hook, state.hookTimeout)
		if err then
			settleSubtree(suite, state, path, "beforeAll failed: " .. err)
			for _, after in suite.afterAll do
				local afterErr = runWithTimeout(after, state.hookTimeout)
				if afterErr then
					fail(state, path .. " > afterAll", afterErr)
				end
			end
			return
		end
	end

	for _, child in suite.children do
		local childPath = path .. " > " .. child.name
		if child.kind == "suite" then
			runSuite(child, childPath, chain, state)
			continue
		end
		if child.skip or not child.fn then
			state.results.skipped += 1
			state.file.skipped += 1
			continue
		end
		if state.filter and not string.find(childPath, state.filter, 1, true) then
			continue
		end

		local failure: string? = nil
		for _, level in chain do
			for _, hook in level.beforeEach do
				local err = runWithTimeout(hook, state.hookTimeout)
				if err then
					failure = "beforeEach failed: " .. err
					break
				end
			end
			if failure then
				break
			end
		end
		if not failure then
			failure = runWithTimeout(child.fn :: () -> (), child.timeout or state.timeout)
		end
		for i = #chain, 1, -1 do
			for _, hook in chain[i].afterEach do
				local err = runWithTimeout(hook, state.hookTimeout)
				if err and not failure then
					failure = "afterEach failed: " .. err
				end
			end
		end

		if failure then
			fail(state, childPath, failure)
		else
			state.results.passed += 1
			state.file.passed += 1
		end
	end

	for _, hook in suite.afterAll do
		local err = runWithTimeout(hook, state.hookTimeout)
		if err then
			fail(state, path .. " > afterAll", err)
		end
	end
end

local function normalize(specs: any): { Spec }
	if typeof(specs) == "Instance" then
		return LorenTest.collect(specs)
	end
	local list: { Spec } = {}
	if typeof(specs) ~= "table" then
		return list
	end
	if #specs > 0 then
		for _, entry in specs do
			if typeof(entry) == "table" and typeof(entry.name) == "string" then
				table.insert(list, entry)
			elseif typeof(entry) == "function" then
				table.insert(list, { name = "spec" .. (#list + 1), fn = entry })
			end
		end
	else
		for name, fn in specs do
			if typeof(fn) == "function" then
				table.insert(list, { name = tostring(name), fn = fn })
			end
		end
		table.sort(list, function(a: Spec, b: Spec)
			return a.name < b.name
		end)
	end
	return list
end

function LorenTest.run(specs: any, opts: RunOptions?): Results
	local options: RunOptions = opts or {}
	local results: Results = {
		label = options.label,
		passed = 0,
		failed = 0,
		skipped = 0,
		durationMs = 0,
		failures = {},
		files = {},
	}
	local started = os.clock()

	for _, spec in normalize(specs) do
		local file: FileResult = { name = spec.name, passed = 0, failed = 0, skipped = 0, durationMs = 0 }
		table.insert(results.files, file)
		local state: RunState = {
			results = results,
			file = file,
			timeout = options.timeout or DEFAULT_TIMEOUT,
			hookTimeout = options.hookTimeout or options.timeout or DEFAULT_TIMEOUT,
			filter = options.filter,
		}
		local fileStart = os.clock()
		if spec.loadError or not spec.fn then
			fail(state, spec.name, spec.loadError or "spec has no function")
		else
			local root = newSuite(spec.name)
			local t, endCollection = newContext(root)
			local ok, err = xpcall(spec.fn :: any, captureError, t)
			endCollection()
			if not ok then
				fail(state, spec.name, "spec function failed: " .. errorToString(err))
			end
			runSuite(root, spec.name, {}, state)
		end
		file.durationMs = math.floor((os.clock() - fileStart) * 1000 + 0.5)
	end

	results.durationMs = math.floor((os.clock() - started) * 1000 + 0.5)
	return results
end

local function indent(text: string, prefix: string): string
	return prefix .. string.gsub(text, "\n", "\n" .. prefix)
end

function LorenTest.report(results: Results): string
	local lines = {}
	table.insert(lines, "== LorenTest" .. (if results.label then ": " .. results.label else "") .. " ==")
	local failuresByFile: { [string]: { Failure } } = {}
	for _, failure in results.failures do
		local owner = "?"
		local best = 0
		for _, file in results.files do
			local name = file.name
			if #name > best and string.sub(failure.path, 1, #name) == name then
				owner, best = name, #name
			end
		end
		failuresByFile[owner] = failuresByFile[owner] or {}
		table.insert(failuresByFile[owner], failure)
	end
	for _, file in results.files do
		local status = if file.failed > 0
			then "FAIL"
			elseif file.passed == 0 and file.skipped > 0 then "SKIP"
			else "PASS"
		local parts = { string.format("%d passed", file.passed) }
		if file.failed > 0 then
			table.insert(parts, string.format("%d failed", file.failed))
		end
		if file.skipped > 0 then
			table.insert(parts, string.format("%d skipped", file.skipped))
		end
		table.insert(
			lines,
			string.format("%s  %s  (%s, %d ms)", status, file.name, table.concat(parts, ", "), file.durationMs)
		)
		local fileFailures = failuresByFile[file.name]
		if fileFailures then
			for _, failure in fileFailures do
				table.insert(lines, "    x " .. failure.path)
				table.insert(lines, indent(failure.message, "        "))
			end
		end
	end
	local orphans = failuresByFile["?"]
	if orphans then
		for _, failure in orphans do
			table.insert(lines, "    x " .. failure.path)
			table.insert(lines, indent(failure.message, "        "))
		end
	end
	table.insert(
		lines,
		string.format(
			"-- %d passed, %d failed, %d skipped (%d ms) => %s",
			results.passed,
			results.failed,
			results.skipped,
			results.durationMs,
			if results.failed == 0 then "PASS" else "FAIL"
		)
	)
	return table.concat(lines, "\n")
end

return LorenTest
