--!strict
--[[
	V2Service: the 2.0 integration fixture (IMPLEMENTATION.md section 10). The Studio harness registers
	it only when Loren.Version starts with "2." (fixtures/v2), so 1.5.1 never sees the 2.0-only keys.
	Unreliable and coalesced members are typed without T.Instance/T.any (section 3.6).

	Methods  Echo(...) untyped, returns its arguments (nil holes kept)
	         TypedEcho(s: string(64), n: u16, v: Vector3) returns (s, n, v); the second return is T.u8,
	           so n > 255 is a BadResult on purpose
	         Slow(seconds) waits (Timeout 3, CancelOnTimeout, RateLimit { 100, 200 })
	         Hang() waits HANG_SECONDS (Timeout 2): abandoned by the watchdog, a zombie until it ends
	         Boom() throws; RejectMe(msg, data, thrown?) returns (or throws) Loren.Reject(msg, data)
	         ReturnPromise(v, reject?) returns a Promise resolving v (or rejecting with Loren.Reject)
	         SerialAdd(n) (Serial) adds n to a per-player total with a yield between read and write
	         MwDot / MwColon / MwThrow / MwTruthy / MwPromise: one middleware style each
	         Limited() (RateLimit { 2, 2 }); Big(n) returns n bytes
	         NeedsPart(part: T.Instance("BasePart"), hidden?) returns part, or a server-only part
	Events   Ping(command, ...) reliable and untyped: the client specs' command channel (below)
	         Aim(T.Vector3) unreliable, coalesced; Seq(T.u32) unreliable, Ordered
	Signals  BootSignal (LorenBurn: FireAll to the players present; each later joiner gets one Fire)
	         Hit(T.string(64), T.u16); Stream(nonce: T.u32, index: T.u32, value: T.f64) unreliable
	         Echo untyped: shares the Method's name, as 1.5.1 allowed

	Ping commands (client data is validated; anything else is ignored):
		"echo", ...              Signals.Echo:Fire(player, "Ping", ...)
		"throw", tag             a listener connected before the main one throws; the main one
		                         still echoes ("Throw", tag)
		"hit" | "hitFor" | "hitExcept", tag, n
		                         Signals.Hit:Fire(player, ...) / :FireFor({ player }, ...) / :FireExcept(player, ...)
		"stream", nonce, count   Signals.Stream:Fire(player, nonce, i, i * 0.25) for i = 1..count (count <= 64)
	Aim and Seq arrivals are echoed on Signals.Echo as ("Aim", v) and ("Seq", n).

	V2Service.Probe is server-side evidence for specs/v2/server (never networked: it is not under Client).
	The texts below are mirrored by specs/v2/client/_V2.luau.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Loren: any = require(ReplicatedStorage.Shared.Loren)
local Promise: any = require(ReplicatedStorage.LorenPackages.Promise)
local T = Loren.T

local BOOM_TEXT = "V2 Boom: the handler failed on purpose"
local MW_THROW_TEXT = "V2 MwThrow: the middleware failed on purpose"
local MW_DOT_DENIED = "V2 MwDot: denied"
local MW_PROMISE_DENIED = "V2 MwPromise: denied"
local PROMISE_REJECTED = "V2 ReturnPromise: rejected on purpose"
local LISTENER_TEXT = "V2 Ping: a listener failed on purpose (the other listeners still run)"

local HANG_SECONDS = 12 -- outlives Timeout 2 + WatchdogGrace 5: the watchdog abandons Hang calls first
local SLOW_MAX = 30
local SLOW_SHORT = 2 -- shorter Slow calls are tracked for the per-player running cap
local SLOW_LONG = 8 -- Slow calls this long outlive Timeout 3 + WatchdogGrace 5: CancelOnTimeout ends them
local BIG_MAX = 1000000
local TAG_MAX = 64
local STREAM_MAX = 64
local U32_MAX = 4294967295
local LIST_MAX = 64 -- every Probe list keeps at most this many entries

local FIXTURE_FOLDER = "V2Fixture" -- ReplicatedStorage.V2Fixture (Folder) with a replicated Part
local HIDDEN_PART = "V2FixtureHidden" -- ServerStorage.V2FixtureHidden: never replicated

local KNOWN_COMMANDS = { echo = true, throw = true, hit = true, hitFor = true, hitExcept = true, stream = true }

local function weakKeys(): any
	return setmetatable({}, { __mode = "k" })
end

local Probe = {
	ignite = nil :: any, -- facade and LorenNet as LorenIgnite saw them
	burn = nil :: any, -- facade as LorenBurn saw it before yielding
	burnReady = nil :: any, -- Loren.OnReady() awaited inside LorenBurn
	burnFireError = nil :: string?,
	bootFired = { burn = 0, join = 0 },
	bootSent = weakKeys() :: { [Player]: boolean },
	handler = {} :: { [string]: number }, -- handler runs per member
	mw = {} :: { [string]: number }, -- member middleware runs
	mwBadPlayer = 0, -- middleware calls whose first argument was not a Player (a self slipped in)
	leaks = 0, -- handler runs for calls their middleware must have denied
	errors = {} :: { any }, -- Loren.OnError infos
	promiseSettled = 0,
	serialCalls = 0,
	serialOverlap = 0, -- a SerialAdd started while another one of the same player was running
	slowActiveMax = 0, -- most short Slow calls of one player running at once
	slowRunningSeen = 0, -- GetStats().RunningCalls seen by a short Slow call before it returned
	longSlow = {} :: { { at: number, seconds: number, finished: boolean } },
	hangEnded = 0,
	hangZombiesSeen = 0, -- GetStats().ZombieCalls seen by a Hang call before it returned
	pings = 0,
	pingBadPlayer = 0,
	commands = {} :: { [string]: number },
	thrown = 0, -- the throwing Ping listener ran
	hits = {} :: { [string]: number },
	streams = 0,
	aims = 0,
	aimBad = 0,
	seqs = 0,
	seqBad = 0,
	seqRegressions = 0, -- an Ordered Seq value not above the last one of the same player
	fireErrors = 0,
	fireErrorTexts = {} :: { string },
	needsPart = 0,
	departed = nil :: Player?, -- the last player who left (Signals spec)
}

local serialTotal: { [Player]: number } = weakKeys()
local serialBusy: { [Player]: boolean } = weakKeys()
local slowActive: { [Player]: number } = weakKeys()
local lastSeq: { [Player]: number } = weakKeys()
local joinSeq = 0
local hiddenPart: BasePart? = nil

local V2Service: any = {
	Dependencies = {},
	Client = {},
	Signals = { "BootSignal", "Echo", "Hit", "Stream" },
	ClientEvents = { "Aim", "Ping", "Seq" },
	Middleware = {},
	Spec = {
		TypedEcho = Loren.Method(T.string(TAG_MAX), T.u16, T.Vector3, {
			Returns = { T.string(TAG_MAX), T.u8, T.Vector3 },
		}),
		Slow = Loren.Method({ Timeout = 3, CancelOnTimeout = true, RateLimit = { 100, 200 } }),
		Hang = Loren.Method({ Timeout = 2 }),
		SerialAdd = Loren.Method({ Serial = true }),
		Limited = Loren.Method({ RateLimit = { 2, 2 } }),
		NeedsPart = Loren.Method(T.Instance("BasePart"), T.optional(T.boolean), {
			Returns = { T.Instance("BasePart") },
		}),
		Aim = Loren.Event(T.Vector3, { Unreliable = true }),
		Seq = Loren.Event(T.u32, { Unreliable = true, Ordered = true }),
		Hit = Loren.Signal(T.string(TAG_MAX), T.u16),
		Stream = Loren.Signal(T.u32, T.u32, T.f64, { Unreliable = true }),
	},
	Probe = Probe,
	Texts = table.freeze({
		Boom = BOOM_TEXT,
		MwThrow = MW_THROW_TEXT,
		MwDotDenied = MW_DOT_DENIED,
		MwPromiseDenied = MW_PROMISE_DENIED,
		PromiseRejected = PROMISE_REJECTED,
		Listener = LISTENER_TEXT,
	}),
	HangSeconds = HANG_SECONDS,
	SlowLong = SLOW_LONG,
}

-- [[ Helpers ]]

local function bump(map: { [string]: number }, key: string)
	map[key] = (map[key] or 0) + 1
end

local function push(list: { any }, item: any)
	if #list < LIST_MAX then
		table.insert(list, item)
	end
end

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and (value :: Instance):IsA("Player")
end

-- NaN fails `v == floor(v)`; +-inf fails the bounds.
local function isInteger(value: any, lo: number, hi: number): boolean
	return type(value) == "number" and value == math.floor(value) and value >= lo and value <= hi
end

local function isTag(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= TAG_MAX and utf8.len(value) ~= nil
end

local function isFiniteVector(v: Vector3): boolean
	local x, y, z = v.X, v.Y, v.Z
	return x == x
		and y == y
		and z == z
		and math.abs(x) < math.huge
		and math.abs(y) < math.huge
		and math.abs(z) < math.huge
end

-- Signals.<signal>:<method>(...), protected: a failing Fire is evidence, never a listener error.
local function fire(signal: string, method: string, ...: any)
	local ok, err = pcall(function(...: any)
		local sig = V2Service.Signals[signal]
		sig[method](sig, ...)
	end, ...)
	if not ok then
		Probe.fireErrors += 1
		push(Probe.fireErrorTexts, tostring(err))
	end
end

local function mwRan(name: string, player: any)
	bump(Probe.mw, name)
	if not isPlayer(player) then
		Probe.mwBadPlayer += 1
	end
end

-- [[ Middleware: one style each ]]

-- README style (dot, no self): runs as (player, ...args).
function V2Service.Middleware.MwDot(player: Player, verdict: any): (boolean, string?)
	mwRan("MwDot", player)
	if verdict == "allow" then
		return true, nil
	end
	return false, MW_DOT_DENIED
end

-- Colon-defined on purpose (same parameter count as Client:MwColon): flagged at boot with a warning,
-- and every call is denied without running it.
function V2Service.Middleware:MwColon(player: Player, _verdict: any): boolean
	mwRan("MwColon", player)
	return true
end

function V2Service.Middleware.MwThrow(player: Player): boolean
	mwRan("MwThrow", player)
	error(MW_THROW_TEXT, 0)
end

-- Truthy but not `true`: denied (only an exact true allows).
function V2Service.Middleware.MwTruthy(player: Player): any
	mwRan("MwTruthy", player)
	return "yes"
end

-- Returns a Promise; Loren awaits it: (true) allows, (false, msg) denies with msg.
function V2Service.Middleware.MwPromise(player: Player, allow: any): any
	mwRan("MwPromise", player)
	return Promise.delay(0.05):andThen(function(): (boolean, string?)
		if allow == true then
			return true, nil
		end
		return false, MW_PROMISE_DENIED
	end)
end

-- [[ Methods ]]

function V2Service.Client:Echo(_player: Player, ...: any): ...any
	return ...
end

function V2Service.Client:TypedEcho(_player: Player, s: string, n: number, v: Vector3): (string, number, Vector3)
	return s, n, v
end

function V2Service.Client:Slow(player: Player, seconds: any): any
	if type(seconds) ~= "number" or seconds ~= seconds then
		return Loren.Reject("V2 Slow: seconds must be a number")
	end
	local wait = math.clamp(seconds, 0, SLOW_MAX)
	bump(Probe.handler, "Slow")
	if wait <= 0 then
		return 0
	end
	local record = nil
	if wait >= SLOW_LONG then
		record = { at = os.clock(), seconds = wait, finished = false }
		push(Probe.longSlow, record)
	end
	local short = wait < SLOW_SHORT
	if short then
		local active = (slowActive[player] or 0) + 1
		slowActive[player] = active
		if active > Probe.slowActiveMax then
			Probe.slowActiveMax = active
		end
	end
	task.wait(wait)
	if short then
		slowActive[player] = math.max((slowActive[player] or 1) - 1, 0)
		local running = Loren.GetStats().RunningCalls
		if running > Probe.slowRunningSeen then
			Probe.slowRunningSeen = running
		end
	end
	if record then
		-- Never reached for a call CancelOnTimeout cancelled.
		record.finished = true
	end
	return wait
end

function V2Service.Client:Hang(_player: Player): boolean
	bump(Probe.handler, "Hang")
	task.wait(HANG_SECONDS)
	-- By now the watchdog abandoned this call: it counts itself as a zombie until it returns.
	local zombies = Loren.GetStats().ZombieCalls
	if zombies > Probe.hangZombiesSeen then
		Probe.hangZombiesSeen = zombies
	end
	Probe.hangEnded += 1
	return true
end

function V2Service.Client:Boom(_player: Player): ()
	bump(Probe.handler, "Boom")
	error(BOOM_TEXT, 0)
end

function V2Service.Client:RejectMe(_player: Player, msg: any, data: any, thrown: any): any
	bump(Probe.handler, "RejectMe")
	local rejection = Loren.Reject(if type(msg) == "string" then msg else "V2 RejectMe", data)
	if thrown == true then
		error(rejection)
	end
	return rejection
end

function V2Service.Client:ReturnPromise(_player: Player, value: any, reject: any): any
	bump(Probe.handler, "ReturnPromise")
	return Promise.delay(0.05):andThen(function()
		Probe.promiseSettled += 1
		if reject == true then
			return Promise.reject(Loren.Reject(PROMISE_REJECTED, value))
		end
		return value
	end)
end

function V2Service.Client:SerialAdd(player: Player, n: any): any
	if type(n) ~= "number" or n ~= n or math.abs(n) > 1e6 then
		return Loren.Reject("V2 SerialAdd: n must be a finite number")
	end
	Probe.serialCalls += 1
	if serialBusy[player] then
		Probe.serialOverlap += 1
	end
	serialBusy[player] = true
	local before = serialTotal[player] or 0
	task.wait(0.03) -- yields between the read and the write: without Serial, concurrent calls lose updates
	local total = before + n
	serialTotal[player] = total
	serialBusy[player] = nil
	return total
end

-- Every member middleware above runs first; the handlers only count (and flag calls that should
-- never have reached them).
function V2Service.Client:MwDot(_player: Player, verdict: any): string
	bump(Probe.handler, "MwDot")
	if verdict ~= "allow" then
		Probe.leaks += 1
	end
	return "MwDot ran"
end

function V2Service.Client:MwColon(_player: Player, _verdict: any): string
	bump(Probe.handler, "MwColon")
	Probe.leaks += 1
	return "MwColon ran"
end

function V2Service.Client:MwThrow(_player: Player): string
	bump(Probe.handler, "MwThrow")
	Probe.leaks += 1
	return "MwThrow ran"
end

function V2Service.Client:MwTruthy(_player: Player): string
	bump(Probe.handler, "MwTruthy")
	Probe.leaks += 1
	return "MwTruthy ran"
end

function V2Service.Client:MwPromise(_player: Player, allow: any): string
	bump(Probe.handler, "MwPromise")
	if allow ~= true then
		Probe.leaks += 1
	end
	return "MwPromise ran"
end

function V2Service.Client:Limited(_player: Player): boolean
	bump(Probe.handler, "Limited")
	return true
end

function V2Service.Client:Big(_player: Player, n: any): any
	if not isInteger(n, 0, BIG_MAX) then
		return Loren.Reject("V2 Big: n must be an integer in 0..1000000")
	end
	return string.rep("b", n)
end

function V2Service.Client:NeedsPart(_player: Player, part: BasePart, hidden: boolean?): BasePart?
	Probe.needsPart += 1
	if hidden == true then
		return hiddenPart -- never replicated: the client gets MissingInstance
	end
	return part
end

-- [[ ClientEvents ]]

-- Connected before onPing: the other listeners must still run (ServerEvent isolation).
local function throwingListener(_player: any, command: any)
	if command == "throw" then
		Probe.thrown += 1
		error(LISTENER_TEXT, 0)
	end
end

local function onPing(player: any, command: any, ...: any)
	Probe.pings += 1
	if not isPlayer(player) then
		Probe.pingBadPlayer += 1
		return
	end
	if type(command) ~= "string" or not KNOWN_COMMANDS[command] then
		return
	end
	bump(Probe.commands, command)
	if command == "echo" then
		fire("Echo", "Fire", player, "Ping", ...)
	elseif command == "throw" then
		local tag = ...
		if isTag(tag) then
			fire("Echo", "Fire", player, "Throw", tag)
		end
	elseif command == "stream" then
		local nonce, count = ...
		if isInteger(nonce, 0, U32_MAX) and isInteger(count, 1, STREAM_MAX) then
			Probe.streams += 1
			for i = 1, count do
				fire("Stream", "Fire", player, nonce, i, i * 0.25)
			end
		end
	else
		local tag, n = ...
		if isTag(tag) and isInteger(n, 0, 65535) then
			bump(Probe.hits, command)
			if command == "hit" then
				fire("Hit", "Fire", player, tag, n)
			elseif command == "hitFor" then
				fire("Hit", "FireFor", { player }, tag, n)
			else
				fire("Hit", "FireExcept", player, tag, n)
			end
		end
	end
end

local function onAim(player: any, v: any)
	Probe.aims += 1
	if not isPlayer(player) or typeof(v) ~= "Vector3" or not isFiniteVector(v) then
		Probe.aimBad += 1
		return
	end
	fire("Echo", "Fire", player, "Aim", v)
end

local function onSeq(player: any, n: any)
	Probe.seqs += 1
	if not isPlayer(player) or not isInteger(n, 0, U32_MAX) then
		Probe.seqBad += 1
		return
	end
	local last = lastSeq[player]
	if last ~= nil and n <= last then
		Probe.seqRegressions += 1
	end
	lastSeq[player] = n
	fire("Echo", "Fire", player, "Seq", n)
end

local function onError(info: any)
	push(Probe.errors, info)
end

-- [[ Lifecycle ]]

local function ensureInstances()
	local folder = ReplicatedStorage:FindFirstChild(FIXTURE_FOLDER)
	if folder == nil then
		local created = Instance.new("Folder")
		created.Name = FIXTURE_FOLDER
		local part = Instance.new("Part")
		part.Name = "Part"
		part.Anchored = true
		part.CanCollide = false
		part.Transparency = 1
		part.Parent = created
		created.Parent = ReplicatedStorage
	end
	local hidden = ServerStorage:FindFirstChild(HIDDEN_PART)
	if hidden == nil then
		local part = Instance.new("Part")
		part.Name = HIDDEN_PART
		part.Anchored = true
		part.Parent = ServerStorage
		hidden = part
	end
	hiddenPart = hidden :: BasePart
end

function V2Service:LorenIgnite()
	local net = ReplicatedStorage:FindFirstChild("LorenNet")
	local found, service = pcall(Loren.GetService, "V2Service")
	Probe.ignite = {
		State = Loren.State,
		IsReady = Loren.IsReady,
		IsOnFire = Loren.IsOnFire,
		GetService = found and rawequal(service, V2Service),
		NetState = if net then net:GetAttribute("State") else nil,
		RemotesVisible = net ~= nil
			and (net:FindFirstChild("Reliable") ~= nil or net:FindFirstChild("Unreliable") ~= nil),
	}
	ensureInstances()
	Loren.OnError(onError)
	local events = self.ClientEvents
	events.Ping:Connect(throwingListener)
	events.Ping:Connect(onPing)
	events.Aim:Connect(onAim)
	events.Seq:Connect(onSeq)
end

function V2Service:LorenBurn()
	Probe.burn = { State = Loren.State, IsReady = Loren.IsReady }

	-- BootSignal: every player gets exactly one (the clients' Backlog spec connects late).
	local present = Players:GetPlayers()
	for _, player in present do
		Probe.bootSent[player] = true
	end
	local fired, err = pcall(function()
		self.Signals.BootSignal:FireAll("burn", 0)
	end)
	if fired then
		Probe.bootFired.burn += #present
	else
		Probe.burnFireError = tostring(err)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		if Probe.bootSent[player] then
			return
		end
		Probe.bootSent[player] = true
		joinSeq += 1
		Probe.bootFired.join += 1
		fire("BootSignal", "Fire", player, "join", joinSeq)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		Probe.departed = player
	end)

	local resolved, value = Loren.OnReady():await()
	Probe.burnReady = {
		ok = resolved,
		SameLoren = rawequal(value, Loren),
		State = Loren.State,
		IsReady = Loren.IsReady,
	}
end

return V2Service
