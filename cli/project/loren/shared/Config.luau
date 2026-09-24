--!strict
--!optimize 2
--[[
	Config (owner lane: lifecycle): Loren.Configure validation, defaults and freeze.
	Spec: IMPLEMENTATION.md sections 3.4 and 6.

	- `set` validates every key of the call first and changes nothing if one is bad (an error at the
	  caller's line: unknown key, wrong type, out of range, NaN/inf, or a call after SetOnFire).
	- Keys for the other side (server-only keys on a client, client-only keys on the server) are
	  validated, then ignored with a one-time Studio warning.
	- `get` returns one resolved table (defaults + set values) whose identity is stable until
	  `_reset`; `freeze` (at SetOnFire) makes it and its Members read-only.
	No side effects on require.
]]

local RunService = game:GetService("RunService")

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)
local Log = require(script.Parent.Log)

type Report = Types.Report
type MemberOverride = Types.MemberOverride

local PREFIX = C.PREFIX
local F64_MAX = C.Limit.F64_MAX
local TIMEOUT_MIN = C.Limit.TIMEOUT_MIN
local TIMEOUT_MAX = C.Limit.TIMEOUT_MAX
local IS_SERVER = RunService:IsServer()

-- Cross-check floor: an honest client's heaviest frame costs at most ~69.6 KB at admission
-- (65 536 weight + 8 + 16 x 255 refs), so the client mirror of the byte burst must hold 128 KiB.
local MIN_MIRRORED_BYTE_BURST = 131072

type Rule = {
	side: string, -- "S" server-only, "C" client-only, "B" both
	check: (v: any) -> boolean,
	allowed: string, -- text for the error message
	normalize: ((v: any) -> any)?,
}

local function finite(v: any): boolean
	return type(v) == "number" and v >= -F64_MAX and v <= F64_MAX
end

local function positive(v: any): boolean
	return finite(v) and v > 0
end

local function atLeastOne(v: any): boolean
	return finite(v) and v >= 1
end

local function fraction(v: any): boolean
	return finite(v) and v > 0 and v <= 1
end

-- WatchdogGrace: the client quarantines a timed-out call id until send + timeout +
-- QUARANTINE_AFTER_DEADLINE, which must stay past the server's last reply (receipt + timeout + grace).
local function graceSeconds(v: any): boolean
	return finite(v) and v >= 0 and v <= C.Limit.WATCHDOG_GRACE_MAX
end

local function timeout(v: any): boolean
	return finite(v) and v >= TIMEOUT_MIN and v <= TIMEOUT_MAX
end

local function boolean(v: any): boolean
	return type(v) == "boolean"
end

local function falseOrPositive(v: any): boolean
	return v == false or positive(v)
end

local function integerIn(lo: number, hi: number): (v: any) -> boolean
	return function(v: any): boolean
		return finite(v) and v % 1 == 0 and math.floor(v) == v and v >= lo and v <= hi
	end
end

local function oneOf(a: string, b: string, c: string): (v: any) -> boolean
	return function(v: any): boolean
		return v == a or v == b or v == c
	end
end

-- Timeouts ship in deciseconds, so both sides use the same rounded value.
local function roundTenth(v: any): any
	return math.round(v * 10) / 10
end

local function rule(side: string, check: (any) -> boolean, allowed: string, normalize: ((any) -> any)?): Rule
	return { side = side, check = check, allowed = allowed, normalize = normalize }
end

local RATE = "a number > 0"
local BURST = "a number >= 1"
local BOOL = "a boolean"

local RULES: { [string]: Rule } = {
	FrameRate = rule("S", positive, RATE),
	FrameBurst = rule("S", atLeastOne, BURST),
	ByteRate = rule("S", positive, RATE),
	ByteBurst = rule("S", atLeastOne, BURST),
	MessageRate = rule("S", positive, RATE),
	MessageBurst = rule("S", atLeastOne, BURST),
	MethodRate = rule("S", positive, RATE),
	MethodBurst = rule("S", atLeastOne, BURST),
	EventRate = rule("S", positive, RATE),
	EventBurst = rule("S", atLeastOne, BURST),
	UnreliableEventRate = rule("S", positive, RATE),
	UnreliableEventBurst = rule("S", atLeastOne, BURST),
	MirrorFraction = rule("S", fraction, "a number in (0, 1]"),
	MaxRunningCalls = rule("S", integerIn(1, math.huge), "an integer >= 1"),
	MaxQueuedCalls = rule("S", integerIn(0, C.Limit.QUEUE_MAX), "an integer from 0 to 1024"),
	MaxZombies = rule("S", integerIn(1, math.huge), "an integer >= 1"),
	MaxZombiesPerRoute = rule("S", integerIn(1, math.huge), "an integer >= 1"),
	SerialQueue = rule("S", integerIn(0, C.Limit.QUEUE_MAX), "an integer from 0 to 1024"),
	MaxPending = rule("S", integerIn(1, 4096), "an integer from 1 to 4096"),
	DefaultTimeout = rule("S", timeout, "a number of seconds from 1 to 120", roundTenth),
	WatchdogGrace = rule("S", graceSeconds, "a number of seconds from 0 to 30"),
	CancelOnTimeout = rule("S", boolean, BOOL),
	Backlog = rule("S", integerIn(0, C.Limit.BACKLOG_MAX), "an integer from 0 to 1024"),
	BacklogWindow = rule("S", integerIn(0, 255), "an integer number of seconds from 0 to 255"),
	ForwardErrors = rule("S", oneOf("Studio", "Never", "Always"), '"Studio", "Never" or "Always"'),
	StrictCycles = rule("B", boolean, BOOL),
	InlineTables = rule("B", boolean, BOOL),
	MiddlewareArityCheck = rule("S", boolean, BOOL),
	KickScore = rule("S", falseOrPositive, "false or a number > 0"),
	IgniteTimeout = rule("B", falseOrPositive, "false or a number of seconds > 0"),
	PromiseTraces = rule("C", oneOf("Studio", "Always", "Never"), '"Studio", "Always" or "Never"'),
	-- Members is validated by checkMembers (server-only)
}

local OVERRIDE_KEYS = "RateLimit, Timeout, Serial, CancelOnTimeout, AllowNonFinite"

local function describe(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	elseif type(v) == "number" or type(v) == "boolean" then
		return tostring(v)
	end
	return typeof(v)
end

-- Validates one Members override; returns (problem, frozenCopy).
local function checkOverride(name: string, ov: any): (string?, MemberOverride?)
	local label = 'Members["' .. name .. '"]'
	if type(ov) ~= "table" then
		return label .. " must be a table like { RateLimit = { 5, 10 }, Timeout = 30 }", nil
	end
	local copy: any = {}
	for k, value in next, ov do
		if k == "RateLimit" then
			local ok = false
			local rate, burst = nil, nil
			if type(value) == "table" then
				local list = value :: any
				local count = 0
				for _ in next, list do
					count += 1
				end
				rate, burst = rawget(list, 1), rawget(list, 2)
				ok = count == 2 and positive(rate) and atLeastOne(burst)
			end
			if not ok then
				return label .. ".RateLimit must be { rate > 0, burst >= 1 } (got " .. describe(value) .. ")", nil
			end
			copy.RateLimit = table.freeze({ rate, burst })
		elseif k == "Timeout" then
			if not timeout(value) then
				return label .. ".Timeout must be a number of seconds from 1 to 120 (got " .. describe(value) .. ")",
					nil
			end
			copy.Timeout = roundTenth(value)
		elseif k == "Serial" or k == "CancelOnTimeout" or k == "AllowNonFinite" then
			if type(value) ~= "boolean" then
				return label .. "." .. k .. " must be a boolean (got " .. describe(value) .. ")", nil
			end
			copy[k] = value
		else
			return label .. "." .. tostring(k) .. " is not an override key (" .. OVERRIDE_KEYS .. ")", nil
		end
	end
	return nil, table.freeze(copy)
end

-- Validates a Members table; returns (problem, map of frozen overrides).
local function checkMembers(v: any): (string?, { [string]: MemberOverride }?)
	if type(v) ~= "table" then
		return 'Members must be a table like { ["ShopService.Buy"] = { Timeout = 30 } } (got ' .. describe(v) .. ")",
			nil
	end
	local out: { [string]: MemberOverride } = {}
	for name, ov in next, v do
		if type(name) ~= "string" or not string.match(name, "^.+%..+$") then
			return 'Members keys must be "Service.Member" strings (got ' .. describe(name) .. ")", nil
		end
		local problem, copy = checkOverride(name, ov)
		if problem then
			return problem, nil
		end
		out[name] = copy :: MemberOverride
	end
	return nil, out
end

local function hint(key: string): string
	local lower = string.lower(key)
	for name in RULES do
		if string.lower(name) == lower then
			return " Did you mean '" .. name .. "'?"
		end
	end
	if lower == "members" then
		return " Did you mean 'Members'?"
	end
	return ""
end

local function fresh(): any
	local t: any = {}
	for k, v in C.Default :: any do
		t[k] = v
	end
	t.Members = {}
	return t
end

local current: any = fresh()
local frozen = false

local Config = {}

-- Loren.Configure. Errors point at the caller of Loren.Configure (level 3).
function Config.set(input: { [string]: any }): ()
	if frozen then
		error(PREFIX .. "Configure must be called before SetOnFire", 3)
	end
	if type(input) ~= "table" then
		error(PREFIX .. "Configure expects a table, got " .. typeof(input), 3)
	end
	local staged: { [string]: any } = {}
	for key, value in next, input do
		if type(key) ~= "string" then
			error(PREFIX .. "Configure keys must be strings (got " .. describe(key) .. ")", 3)
		end
		if key == "Members" then
			local problem, members = checkMembers(value)
			if problem then
				error(PREFIX .. "Configure: " .. problem, 3)
			end
			staged.Members = members
		else
			local r = RULES[key]
			if r == nil then
				error(PREFIX .. "Configure: unknown key '" .. key .. "'." .. hint(key), 3)
			end
			if not r.check(value) then
				error(
					PREFIX .. "Configure: " .. key .. " must be " .. r.allowed .. " (got " .. describe(value) .. ")",
					3
				)
			end
			staged[key] = if r.normalize then r.normalize(value) else value
		end
	end
	for key, value in staged do
		local side = if key == "Members" then "S" else RULES[key].side
		if (side == "S" and not IS_SERVER) or (side == "C" and IS_SERVER) then
			Log.studioOnce(
				"config-side:" .. key,
				string.format(
					"Configure: %s is a %s-only key; it is ignored on the %s",
					key,
					if side == "S" then "server" else "client",
					if IS_SERVER then "server" else "client"
				)
			)
		elseif key == "Members" then
			for name, ov in value :: { [string]: MemberOverride } do
				current.Members[name] = ov
			end
		else
			current[key] = value
		end
	end
end

function Config.get(): Types.Config
	return current
end

function Config.freeze(): ()
	if frozen then
		return
	end
	frozen = true
	table.freeze(current.Members)
	table.freeze(current)
end

function Config.isFrozen(): boolean
	return frozen
end

function Config.member(service: string, member: string): MemberOverride?
	return current.Members[service .. "." .. member]
end

-- Server SetOnFire: the section 6 cross-checks (errors) and policy warnings.
function Config.check(report: Report): ()
	local mirror = current.MirrorFraction
	local bytes = current.ByteBurst * mirror
	if bytes < MIN_MIRRORED_BYTE_BURST then
		table.insert(
			report.errors,
			string.format(
				"Configure: ByteBurst * MirrorFraction must be at least %d so an honest client's largest frame "
					.. "(~70 KB) can be admitted (now %g)",
				MIN_MIRRORED_BYTE_BURST,
				bytes
			)
		)
	end
	local frames = current.FrameBurst * mirror
	if frames < 1 then
		table.insert(
			report.errors,
			string.format("Configure: FrameBurst * MirrorFraction must be at least 1 (now %g)", frames)
		)
	end
	local messages = current.MessageBurst * mirror
	if messages < 1 then
		table.insert(
			report.errors,
			string.format("Configure: MessageBurst * MirrorFraction must be at least 1 (now %g)", messages)
		)
	end
	if current.ForwardErrors == "Always" then
		table.insert(
			report.warnings,
			'Configure: ForwardErrors = "Always" sends server error text to every client; use "Studio" in production'
		)
	end
end

function Config._reset(): ()
	current = fresh()
	frozen = false
end

return table.freeze(Config)
