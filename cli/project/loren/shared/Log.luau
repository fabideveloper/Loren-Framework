--!strict
--!optimize 2
--[[
	Log: every Loren output line goes through here (owner lane: limiter).
	Spec: IMPLEMENTATION.md sections 0 (Logging rules) and 3.1.

	- `info` prints unthrottled (boot lines only).
	- `warn`/`warnf`/`once` share one global budget: a token bucket of C.Limit.LOG_LINES_PER_MIN
	  lines per minute (burst the same). A suppressed line is only counted; the next printed line
	  ends with " (+N suppressed)".
	- `warnf` formats only when the budget allows; `warnWith` calls a builder only when it allows,
	  so a caller never builds a string that would be thrown away.
	- `studioOnce` prints once per key, only in Studio, outside the budget (developer hints).
	- Formatting never throws: a bad format string (or argument) prints the raw format instead, and a
	  failing builder prints a placeholder. `msg` arguments must be strings (typed API).

	No side effects on require. `_reset` restores the require-time state (budget, keys, counters,
	clock) and the default output sinks (print/warn unless `_test.setDefaultSinks` replaced them).
	`_test` holds hooks for specs (fake clock, captured output, Studio flag).
]]

local C = require(script.Parent.Constants)

local RunService = game:GetService("RunService")

local PREFIX = C.PREFIX
local BURST = C.Limit.LOG_LINES_PER_MIN
local RATE = C.Limit.LOG_LINES_PER_MIN / 60 -- lines per second

local REAL_STUDIO = RunService:IsStudio()
local realClock = os.clock
local realPrint: (string) -> () = print
local realWarn: (string) -> () = warn

-- The sinks _reset restores: the real print/warn unless _test.setDefaultSinks replaced them (a test
-- harness capturing Loren's output for a whole phase). Not touched by _reset.
local defaultPrint: (string) -> () = realPrint
local defaultWarn: (string) -> () = realWarn

-- Hooks (replaced only by _test; restored by _reset)
local clock: () -> number = realClock
local printSink: (string) -> () = realPrint
local warnSink: (string) -> () = realWarn
local isStudio = REAL_STUDIO

-- Budget and counters
local tokens = BURST
local stamp = 0
local pendingSuppressed = 0 -- suppressed since the last printed budgeted line
local totalSuppressed = 0 -- suppressed since require / _reset
local spentKeys: { [string]: true } = {} -- once / studioOnce keys (one set)

local Log = {}

-- Refills the budget to the current time. Returns true if one line may be printed now.
local function refill(): boolean
	local now = clock()
	local dt = now - stamp
	if dt > 0 then
		tokens = math.min(BURST, tokens + dt * RATE)
		stamp = now
	end
	return tokens >= 1
end

-- Refills, then takes one line from the budget if it has one. The token is taken before any string
-- is built, so a builder or __tostring that logs again cannot overdraw the budget.
local function take(): boolean
	if refill() then
		tokens -= 1
		return true
	end
	pendingSuppressed += 1
	totalSuppressed += 1
	return false
end

-- Prints one budgeted line (its token was already taken).
local function emit(msg: string)
	local line = PREFIX .. msg
	if pendingSuppressed > 0 then
		line ..= " (+" .. pendingSuppressed .. " suppressed)"
		pendingSuppressed = 0
	end
	warnSink(line)
end

-- print(PREFIX .. msg), unthrottled. Boot lines only.
function Log.info(msg: string): ()
	printSink(PREFIX .. msg)
end

-- warn(PREFIX .. msg) if the global budget allows. Returns false if the line was suppressed.
function Log.warn(msg: string): boolean
	if take() then
		emit(msg)
		return true
	end
	return false
end

-- Like warn, but string.format(fmt, ...) runs only when the budget allows.
function Log.warnf(fmt: string, ...: any): boolean
	if not take() then
		return false
	end
	local ok, text = pcall(string.format, fmt, ...)
	emit(if ok then text else fmt .. " [bad log format: " .. tostring(text) .. "]")
	return true
end

-- Like warn, but the line is `build(...)`, called only when the budget allows.
-- `build` should be a module-level function (no closure per call).
function Log.warnWith(build: (...any) -> string, ...: any): boolean
	if not take() then
		return false
	end
	local ok, text = pcall(build, ...)
	emit(if ok and type(text) == "string" then text else "[log builder failed: " .. tostring(text) .. "]")
	return true
end

-- At most once per key per session. Uses the budget; the key is spent only when the line prints.
function Log.once(key: string, msg: string): ()
	if spentKeys[key] then
		return
	end
	if Log.warn(msg) then
		spentKeys[key] = true
	end
end

-- Once per key, only in Studio. Not budgeted.
function Log.studioOnce(key: string, msg: string): ()
	if not isStudio or spentKeys[key] then
		return
	end
	spentKeys[key] = true
	warnSink(PREFIX .. msg)
end

-- Would the next warn print? Refills, consumes nothing.
function Log.allowed(): boolean
	return refill()
end

-- Budgeted lines suppressed since require / _reset.
function Log.suppressed(): number
	return totalSuppressed
end

function Log._reset(): ()
	clock = realClock
	printSink = defaultPrint
	warnSink = defaultWarn
	isStudio = REAL_STUDIO
	tokens = BURST
	stamp = 0
	pendingSuppressed = 0
	totalSuppressed = 0
	table.clear(spentKeys)
end

Log._test = table.freeze({
	-- Replaces os.clock for the budget (nil restores it). Call right after _reset.
	setClock = function(fn: (() -> number)?)
		clock = fn or realClock
		stamp = clock()
	end,
	-- Captures output until the next _reset: print lines go to printFn, warn lines to warnFn (nil
	-- restores the default sink: the real print/warn unless setDefaultSinks replaced it).
	setSink = function(printFn: ((string) -> ())?, warnFn: ((string) -> ())?)
		printSink = printFn or defaultPrint
		warnSink = warnFn or defaultWarn
	end,
	-- Replaces the sinks _reset restores AND the current sinks; survives _reset (a harness captures
	-- Loren's expected warnings for a whole phase although specs call _reset). nil restores the real
	-- print/warn.
	setDefaultSinks = function(printFn: ((string) -> ())?, warnFn: ((string) -> ())?)
		defaultPrint = printFn or realPrint
		defaultWarn = warnFn or realWarn
		printSink = defaultPrint
		warnSink = defaultWarn
	end,
	-- The sinks in use now and the ones _reset restores (a spec saves and restores the defaults).
	sinks = function(): {
		print: (string) -> (),
		warn: (string) -> (),
		defaultPrint: (string) -> (),
		defaultWarn: (string) -> (),
	}
		return { print = printSink, warn = warnSink, defaultPrint = defaultPrint, defaultWarn = defaultWarn }
	end,
	-- Overrides RunService:IsStudio() for studioOnce (nil restores it).
	setStudio = function(value: boolean?)
		isStudio = if value == nil then REAL_STUDIO else value
	end,
	-- Current budget tokens (after a refill).
	tokens = function(): number
		refill()
		return tokens
	end,
	pending = function(): number
		return pendingSuppressed
	end,
})

return table.freeze(Log)
