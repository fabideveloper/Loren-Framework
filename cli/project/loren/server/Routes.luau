--!strict
--!optimize 2
--[[
	Routes (owner lane: server-net): route numbering, frozen route records, the manifest model and
	its bytes, and the per-service Signals / ClientEvents maps.
	Spec: design/loren-2.0/IMPLEMENTATION.md sections 3.16 (Routes.build), 4.3, 4.7, 6 (Members) and
	11 (#7, #27, #34).

	build(decls, cfg, report), at server boot step 5:
	- Effective options per member: defaults <- Spec <- cfg.Members["Svc.Member"] (Methods and
	  ClientEvents only; keys that do not apply to a kind are ignored). A Members key that names no
	  Method or ClientEvent is a warning.
	- Schema.check for every member (descriptor depth; unreliable or coalesced members must be typed
	  without T.Instance / T.any): a problem is an error "<S>.<M>: <text>".
	- Numbering: sort by (group, service, member, kind) with plain `<`, number 1..N (groups: 1
	  unreliable Events and Signals, 2 reliable Events, 3 reliable Signals, 4 Methods). N > 65535 is
	  an error.
	- Codecs (Schema.compile), objects (ServerSignal.new, Signal.ServerEvent.new), the manifest model
	  and `manifestMsg` (0xF1 len:u32 + Manifest.encode(model)), encoded once. Records and maps are
	  frozen; the Signals / ClientEvents maps raise on unknown keys.
	Returns nil when it added errors to the report.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Runtime = ReplicatedStorage.LorenRuntime

local C = require(Runtime.Constants)
local Types = require(Runtime.Types)
local Version = require(Runtime.Version)
local Schema = require(Runtime.Schema)
local Manifest = require(Runtime.Manifest)
local Signal = require(Runtime.Signal)
local ServerSignal = require(script.Parent.ServerSignal)

-- Route and RouteTable are defined in Outbox (the lowest server-net module) and re-exported.
export type Route = ServerSignal.Route
export type RouteTable = ServerSignal.RouteTable

type Descriptor = Types.Descriptor
type Config = Types.Config
type Report = Types.Report

-- One member while routes are being numbered.
type Pending = {
	group: number,
	service: string,
	name: string,
	kind: number,
	fullName: string,
	decl: Types.ServiceDecl,
	member: Types.MemberDecl,
	unreliable: boolean,
	ordered: boolean,
	coalesce: boolean,
	serial: boolean,
	cancelOnTimeout: boolean,
	allowNonFinite: boolean,
	timeout: number,
	rate: number,
	burst: number,
	backlog: number,
	args: { Descriptor }?,
	returns: { Descriptor }?,
}

local PREFIX = C.PREFIX
local L = C.Limit
local KIND_METHOD = C.Kind.Method
local KIND_EVENT = C.Kind.Event
local KIND_SIGNAL = C.Kind.Signal
local KIND_NAME = { [KIND_METHOD] = "Method", [KIND_EVENT] = "Event", [KIND_SIGNAL] = "Signal" }
local F = C.MemberFlag
-- Untyped alias: the new solver narrows a local to read-only after a table.freeze statement.
local freeze: (any) -> any = table.freeze

-- Module state (restored by _reset)
local current: any = nil -- RouteTable?

local Routes = {}

-- Helpers ------------------------------------------------------------------------------------------

local function addError(report: Report, text: string)
	table.insert(report.errors, text)
end

local function addWarning(report: Report, text: string)
	table.insert(report.warnings, text)
end

local function pick(a: any, b: any, c: any): any
	if a ~= nil then
		return a
	elseif b ~= nil then
		return b
	end
	return c
end

-- Levenshtein distance, bounded (boot-time suggestions only).
local function distance(a: string, b: string): number
	local la, lb = #a, #b
	if math.abs(la - lb) > 2 then
		return 3
	end
	local prev = table.create(lb + 1, 0)
	for j = 0, lb do
		prev[j + 1] = j
	end
	for i = 1, la do
		local cur = table.create(lb + 1, 0)
		cur[1] = i
		local ca = string.byte(a, i)
		for j = 1, lb do
			local cost = if ca == string.byte(b, j) then 0 else 1
			cur[j + 1] = math.min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost)
		end
		prev = cur
	end
	return prev[lb + 1]
end

local function suggest(name: string, candidates: { string }): string?
	local lower = string.lower(name)
	for _, c in candidates do
		if string.lower(c) == lower then
			return c
		end
	end
	local best, bestD = nil, 3
	for _, c in candidates do
		local d = distance(name, c)
		if d < bestD then
			best, bestD = c, d
		end
	end
	return best
end

local function before(a: Pending, b: Pending): boolean
	if a.group ~= b.group then
		return a.group < b.group
	end
	if a.service ~= b.service then
		return a.service < b.service
	end
	if a.name ~= b.name then
		return a.name < b.name
	end
	return a.kind < b.kind
end

local function memberBefore(a: Types.ManifestMember, b: Types.ManifestMember): boolean
	if a.name ~= b.name then
		return a.name < b.name
	end
	return a.kind < b.kind
end

local function indexKey(t: any, key: string): any
	return t[key]
end

-- module[key] without letting a strict __index fail the boot (raw first, then the metatable under
-- pcall), the way Registry reads module keys.
local function moduleKey(module: any, key: string): any
	local v = rawget(module, key)
	if v ~= nil or getmetatable(module) == nil then
		return v
	end
	local ok, r = pcall(indexKey, module, key)
	return if ok then r else nil
end

local function roundTimeout(t: number): number
	return math.round(t * 10) / 10
end

-- Resolves one member's effective options. `override` is cfg.Members[fullName] (Methods and
-- ClientEvents only).
local function resolve(decl: Types.ServiceDecl, m: Types.MemberDecl, cfg: Config, override: any): Pending
	local spec: any = m.spec
	local kind = m.kind
	local unreliable = false
	local ordered = false
	local coalesce = false
	local serial = false
	local cancelOnTimeout = false
	local allowNonFinite = false
	local timeout = 0
	local rate = 0
	local burst = 0
	local backlog = 0
	local rateLimit = if override then override.RateLimit else nil
	if kind == KIND_METHOD then
		timeout = roundTimeout(pick(override and override.Timeout, spec and spec.timeout, cfg.DefaultTimeout))
		rate = pick(rateLimit and rateLimit[1], spec and spec.rate, cfg.MethodRate)
		burst = pick(rateLimit and rateLimit[2], spec and spec.burst, cfg.MethodBurst)
		serial = pick(override and override.Serial, spec and spec.serial, false) == true
		cancelOnTimeout = pick(
			override and override.CancelOnTimeout,
			spec and spec.cancelOnTimeout,
			cfg.CancelOnTimeout
		) == true
		allowNonFinite = pick(override and override.AllowNonFinite, spec and spec.allowNonFinite, false) == true
	elseif kind == KIND_EVENT then
		unreliable = spec ~= nil and spec.unreliable == true
		ordered = spec ~= nil and spec.ordered == true
		coalesce = if spec ~= nil and spec.coalesce ~= nil then spec.coalesce == true else unreliable
		rate = pick(
			rateLimit and rateLimit[1],
			spec and spec.rate,
			if unreliable then cfg.UnreliableEventRate else cfg.EventRate
		)
		burst = pick(
			rateLimit and rateLimit[2],
			spec and spec.burst,
			if unreliable then cfg.UnreliableEventBurst else cfg.EventBurst
		)
		allowNonFinite = pick(override and override.AllowNonFinite, spec and spec.allowNonFinite, false) == true
	else -- Signal (Members never applies)
		unreliable = spec ~= nil and spec.unreliable == true
		ordered = spec ~= nil and spec.ordered == true
		backlog = pick(spec and spec.backlog, cfg.Backlog, 0)
		allowNonFinite = spec ~= nil and spec.allowNonFinite == true
	end
	local group
	if unreliable and kind ~= KIND_METHOD then
		group = 1
	elseif kind == KIND_EVENT then
		group = 2
	elseif kind == KIND_SIGNAL then
		group = 3
	else
		group = 4
	end
	return {
		group = group,
		service = decl.name,
		name = m.name,
		kind = kind,
		fullName = decl.name .. "." .. m.name,
		decl = decl,
		member = m,
		unreliable = unreliable,
		ordered = ordered,
		coalesce = coalesce,
		serial = serial,
		cancelOnTimeout = cancelOnTimeout,
		allowNonFinite = allowNonFinite,
		timeout = timeout,
		rate = rate,
		burst = burst,
		backlog = backlog,
		args = if spec then spec.args else nil,
		returns = if spec and kind == KIND_METHOD then spec.returns else nil,
	}
end

-- Schema.check for one member; errors go to the report. Returns true when fine.
local function checkMember(p: Pending, report: Report): boolean
	local refFree = p.unreliable or p.coalesce
	local ok, problem = pcall(Schema.check, p.args, refFree)
	if not ok then
		addError(report, p.fullName .. ": " .. tostring(problem))
		return false
	elseif problem ~= nil then
		addError(report, p.fullName .. ": " .. tostring(problem))
		return false
	end
	if p.kind == KIND_METHOD and p.returns ~= nil then
		ok, problem = pcall(Schema.check, p.returns, false)
		if not ok or problem ~= nil then
			addError(report, p.fullName .. " (Returns): " .. tostring(problem))
			return false
		end
	end
	if p.kind == KIND_METHOD and type(p.member.fn) ~= "function" then
		addError(report, p.fullName .. ": the Client method is not a function")
		return false
	end
	return true
end

local function compile(
	p: Pending,
	report: Report,
	descs: { Descriptor }?,
	maxArgs: number,
	unreliable: boolean,
	what: string
): Types.PayloadCodec?
	local ok, codec = pcall(Schema.compile, descs, p.allowNonFinite, maxArgs, unreliable)
	if not ok or type(codec) ~= "table" then
		addError(report, p.fullName .. " (" .. what .. "): " .. tostring(codec))
		return nil
	end
	return codec
end

-- A frozen map whose unknown keys raise (section 11 #27). `label` is "Signals" or "ClientEvents".
local function sealMap(map: { [string]: any }, service: string, label: string): any
	local names = {}
	for name in map do
		table.insert(names, name)
	end
	table.sort(names)
	local listText = if #names > 0 then table.concat(names, ", ") else "(none)"
	setmetatable(map, {
		__index = function(_: any, key: any): any
			error(
				string.format("%s%s.%s has no '%s'. %s: %s", PREFIX, service, label, tostring(key), label, listText),
				2
			)
		end,
		__newindex = function(_: any, key: any): ()
			error(string.format("%s%s.%s is read-only (key '%s')", PREFIX, service, label, tostring(key)), 2)
		end,
	})
	return table.freeze(map)
end

local function manifestMessage(bytes: buffer): buffer
	local len = buffer.len(bytes)
	local msg = buffer.create(5 + len)
	buffer.writeu8(msg, 0, C.Op.MANIFEST)
	buffer.writeu32(msg, 1, len)
	buffer.copy(msg, 5, bytes, 0, len)
	return msg
end

local function deepCopy(v: any, seen: { [any]: any }): any
	if type(v) ~= "table" then
		return v
	end
	local done = seen[v]
	if done ~= nil then
		return done
	end
	local t = {}
	seen[v] = t
	for k, x in next, v do
		t[deepCopy(k, seen)] = deepCopy(x, seen)
	end
	return t
end

-- Members keys that name no Method or ClientEvent: warnings (sorted, deterministic).
local function checkMembers(
	members: { [string]: any },
	known: { [string]: boolean },
	signals: { [string]: boolean },
	report: Report
)
	local keys = {}
	for key in members do
		if type(key) == "string" and not known[key] then
			table.insert(keys, key)
		end
	end
	if #keys == 0 then
		return
	end
	table.sort(keys)
	local candidates = {}
	for name in known do
		table.insert(candidates, name)
	end
	table.sort(candidates)
	for _, key in keys do
		local hint = ""
		if signals[key] then
			hint = " Members does not apply to Signals."
		else
			local s = suggest(key, candidates)
			if s then
				hint = " Did you mean '" .. s .. "'?"
			end
		end
		addWarning(
			report,
			string.format('Configure Members["%s"] matches no Client method or ClientEvent.%s', key, hint)
		)
	end
end

-- Build --------------------------------------------------------------------------------------------

function Routes.build(decls: { Types.ServiceDecl }, cfg: Config, report: Report): RouteTable?
	local errorsBefore = #report.errors
	local members: { [string]: any } = cfg.Members or {}
	local known: { [string]: boolean } = {}
	local signalNames: { [string]: boolean } = {}
	local pending: { Pending } = {}
	local valid = true

	-- 1. Effective options per member.
	for _, decl in decls do
		for _, m in decl.members do
			local full = decl.name .. "." .. m.name
			local override = nil
			if m.kind == KIND_METHOD or m.kind == KIND_EVENT then
				known[full] = true
				override = members[full]
			else
				signalNames[full] = true
			end
			local p = resolve(decl, m, cfg, override)
			if not checkMember(p, report) then
				valid = false
			end
			table.insert(pending, p)
		end
	end
	checkMembers(members, known, signalNames, report)

	local count = #pending
	if count > C.ROUTE_MAX then
		addError(
			report,
			string.format(
				"%d network members (Client methods, ClientEvents, Signals); at most %d are supported",
				count,
				C.ROUTE_MAX
			)
		)
		return nil
	end
	if not valid then
		return nil
	end

	-- 2. Numbering.
	table.sort(pending, before)

	-- 3. Signals / ClientEvents maps for every module that declares them (networked or not).
	local signals: { [string]: { [string]: any } } = {}
	local events: { [string]: { [string]: any } } = {}
	for _, decl in decls do
		local module = decl.module
		if type(module) == "table" then
			if type(moduleKey(module, "Signals")) == "table" then
				signals[decl.name] = {}
			end
			if type(moduleKey(module, "ClientEvents")) == "table" then
				events[decl.name] = {}
			end
		end
	end

	-- 4. Route records, objects and manifest members.
	local routes: { Route } = table.create(count) :: any
	local perService: { [string]: { Types.ManifestMember } } = {}
	for id, p in pending do
		local kind = p.kind
		local maxArgs = if kind == KIND_SIGNAL then L.MAX_ARGS_S2C else L.MAX_ARGS_C2S
		local args = compile(p, report, p.args, maxArgs, p.unreliable, "Args")
		local returns: Types.PayloadCodec | false = false
		if kind == KIND_METHOD then
			local r = compile(p, report, p.returns, L.MAX_ARGS_S2C, false, "Returns")
			if r then
				returns = r
			else
				valid = false
			end
		end
		if args == nil then
			valid = false
			continue
		end
		local m = p.member
		local info = { Service = p.service, Member = p.name, Kind = KIND_NAME[kind] }
		freeze(info)
		local route: Route = {
			id = id,
			kind = kind,
			service = p.service,
			member = p.name,
			fullName = p.fullName,
			unreliable = p.unreliable,
			ordered = p.ordered,
			coalesce = p.coalesce,
			serial = p.serial,
			cancelOnTimeout = p.cancelOnTimeout,
			allowNonFinite = p.allowNonFinite,
			timeout = p.timeout,
			rate = p.rate,
			burst = p.burst,
			fn = if kind == KIND_METHOD then m.fn else false,
			self = if kind == KIND_METHOD then p.decl.client else false,
			module = if kind ~= KIND_SIGNAL and p.decl.module ~= nil then p.decl.module else false,
			middleware = if m.middleware then m.middleware else false,
			colon = m.colon == true,
			args = args,
			returns = returns,
			event = false,
			signal = false,
			info = info,
		}
		if kind == KIND_EVENT then
			local ok, ev = pcall(Signal.ServerEvent.new, p.service, p.name)
			if not ok then
				addError(report, p.fullName .. ": " .. tostring(ev))
				valid = false
				continue
			end
			route.event = ev
			local map = events[p.service]
			if map then
				map[p.name] = ev
			end
		elseif kind == KIND_SIGNAL then
			local sig = ServerSignal.new(route)
			route.signal = sig
			local map = signals[p.service]
			if map then
				map[p.name] = sig
			end
		end
		freeze(route)
		routes[id] = route

		local flags = 0
		if p.unreliable then
			flags += F.Unreliable
		end
		if p.ordered then
			flags += F.Ordered
		end
		if p.coalesce and kind == KIND_EVENT then
			flags += F.Coalesce
		end
		if p.allowNonFinite then
			flags += F.AllowNonFinite
		end
		if p.args ~= nil then
			flags += F.HasArgs
		end
		if kind == KIND_METHOD and p.returns ~= nil then
			flags += F.HasReturns
		end
		if p.serial then
			flags += F.Serial
		end
		local mm: Types.ManifestMember = {
			name = p.name,
			kind = kind,
			route = id,
			flags = flags,
			timeout = if kind == KIND_METHOD then p.timeout else 0,
			rate = if kind == KIND_SIGNAL then 0 else p.rate,
			burst = if kind == KIND_SIGNAL then 0 else p.burst,
			backlog = if kind == KIND_SIGNAL then p.backlog else 0,
			args = p.args,
			returns = if kind == KIND_METHOD then p.returns else nil,
		}
		local list = perService[p.service]
		if list == nil then
			list = {}
			perService[p.service] = list
		end
		table.insert(list, mm)
	end
	if not valid or #report.errors > errorsBefore then
		return nil
	end

	-- 5. The model (networked services sorted by name; members by (name, kind)).
	local serviceNames = {}
	for name in perService do
		table.insert(serviceNames, name)
	end
	table.sort(serviceNames)
	local services: { Types.ManifestService } = table.create(#serviceNames) :: any
	for _, name in serviceNames do
		local list = perService[name]
		table.sort(list, memberBefore)
		for _, mm in list do
			freeze(mm)
		end
		freeze(list)
		local service: Types.ManifestService = { name = name, members = list }
		freeze(service)
		table.insert(services, service)
	end
	freeze(services)
	local limits: Types.ManifestLimits = {
		frameRate = cfg.FrameRate,
		frameBurst = cfg.FrameBurst,
		byteRate = cfg.ByteRate,
		byteBurst = cfg.ByteBurst,
		msgRate = cfg.MessageRate,
		msgBurst = cfg.MessageBurst,
		mirror = cfg.MirrorFraction,
		sealC2S = L.C2S_SEAL,
		maxMessageC2S = L.C2S_MAX_MESSAGE,
		unreliableMax = L.UNRELIABLE_SEAL,
		maxPending = cfg.MaxPending,
		maxNodes = L.MAX_NODES,
		maxArgs = L.MAX_ARGS_C2S,
		maxRefs = L.MAX_REFS,
		maxDepth = L.MAX_DEPTH,
		flushHz = L.FLUSH_HZ,
		backlogWindow = cfg.BacklogWindow,
	}
	freeze(limits)
	local model: Types.ManifestModel = {
		proto = C.PROTO,
		version = Version.Version,
		limits = limits,
		services = services,
	}
	freeze(model)
	local ok, bytes = pcall(Manifest.encode, model)
	if not ok or typeof(bytes) ~= "buffer" then
		addError(report, "the manifest could not be encoded: " .. tostring(bytes))
		return nil
	end

	-- 6. Seal the maps.
	local sealedSignals: { [string]: { [string]: Types.ServerSignal } } = {}
	for service, map in signals do
		sealedSignals[service] = sealMap(map, service, "Signals")
	end
	local sealedEvents: { [string]: { [string]: Types.ServerEvent } } = {}
	for service, map in events do
		sealedEvents[service] = sealMap(map, service, "ClientEvents")
	end

	local rt: RouteTable = {
		routes = table.freeze(routes),
		count = count,
		services = #services,
		manifestMsg = manifestMessage(bytes),
		model = model,
		signals = table.freeze(sealedSignals),
		events = table.freeze(sealedEvents),
	}
	current = table.freeze(rt)
	return current
end

-- The route table of the last successful build (nil before one, or after _reset).
function Routes.current(): RouteTable?
	return current
end

-- Loren.DumpManifest(): a deep, mutable copy of the manifest model.
function Routes.dump(): Types.ManifestModel
	local rt = current
	if rt == nil then
		error(PREFIX .. "DumpManifest() is available once SetOnFire has built the routes", 3)
	end
	return deepCopy(rt.model, {})
end

function Routes._reset(): ()
	current = nil
end

Routes._test = table.freeze({
	distance = distance,
	suggest = suggest,
})

return table.freeze(Routes)
