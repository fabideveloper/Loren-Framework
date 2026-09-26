--!strict
--!optimize 2

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)
local Log = require(script.Parent.Log)
local ClientNet = require(script.Parent.ClientNet)

type ClientRoute = ClientNet.ClientRoute

local PREFIX = C.PREFIX
local KIND_METHOD = C.Kind.Method
local KIND_EVENT = C.Kind.Event
local KIND_SIGNAL = C.Kind.Signal
local RESERVED: { [string]: boolean } = C.ReservedClientNames :: any

local Proxy = {}

local builtFrom: Types.ManifestModel? = nil
local NO_PROXIES: { [string]: Types.ServiceProxy } = {}
table.freeze(NO_PROXIES :: any)
local proxies: { [string]: Types.ServiceProxy } = NO_PROXIES
local serviceNames: { string } = {}

-- Suggestions -------------------------------------------------------------------------------------

-- Levenshtein distance, or `cap` as soon as it is certain to be >= cap.
local function distance(a: string, b: string, cap: number): number
	local la, lb = #a, #b
	if math.abs(la - lb) >= cap then
		return cap
	end
	local prev = table.create(lb + 1, 0)
	local cur = table.create(lb + 1, 0)
	for j = 0, lb do
		prev[j + 1] = j
	end
	for i = 1, la do
		cur[1] = i
		local rowMin = i
		local ca = string.byte(a, i)
		for j = 1, lb do
			local cost = if ca == string.byte(b, j) then 0 else 1
			local v = math.min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost)
			cur[j + 1] = v
			if v < rowMin then
				rowMin = v
			end
		end
		if rowMin >= cap then
			return cap
		end
		prev, cur = cur, prev
	end
	return math.min(prev[lb + 1], cap)
end

-- A case-insensitive match, else the closest name within edit distance 2.
local function suggest(name: string, candidates: { string }): string?
	local lower = string.lower(name)
	for _, c in candidates do
		if string.lower(c) == lower then
			return c
		end
	end
	local best: string? = nil
	local bestD = 3
	for _, c in candidates do
		local d = distance(name, c, bestD)
		if d < bestD then
			best, bestD = c, d
		end
	end
	return best
end

-- "<Svc> has no <kind> '<key>'.<suggestion> Members: <list>"
local function unknownMessage(
	owner: string,
	kind: string,
	key: any,
	list: { string },
	elsewhere: { [string]: string }?
): string
	local k = if type(key) == "string" then key else tostring(key)
	local hint = ""
	local other = if elsewhere and type(key) == "string" then elsewhere[key] else nil
	if other then
		hint = " " .. other
	else
		local s = if type(key) == "string" then suggest(key, list) else nil
		if s then
			hint = " Did you mean '" .. s .. "'?"
		end
	end
	return PREFIX
		.. owner
		.. " has no "
		.. kind
		.. " '"
		.. k
		.. "'."
		.. hint
		.. " Members: "
		.. (if #list > 0 then table.concat(list, ", ") else "(none)")
end

-- Unknown keys raise at the indexing line; then the table is frozen.
local function lock(t: any, owner: string, kind: string, list: { string }, elsewhere: { [string]: string }?)
	setmetatable(t, {
		__index = function(_: any, key: any)
			error(unknownMessage(owner, kind, key, list, elsewhere), 2)
		end,
	})
	table.freeze(t :: any)
end

-- Builders -----------------------------------------------------------------------------------------

-- One stub per method, created once. `owner` is the table it must be called on with ':'.
local function makeStub(owner: any, route: ClientRoute, try: boolean, form: string): (...any) -> ...any
	local call = ClientNet.call
	return function(self: any, ...: any): ...any
		if self == owner then
			return call(route, try, select("#", ...), ...)
		elseif self == nil and select("#", ...) == 0 then
			return call(route, try, 0) -- 1.5.1: Svc.M() with no arguments
		end
		error(
			PREFIX .. "Call " .. form .. ":" .. route.member .. "(...) with ':' (a '.' call shifts every argument)",
			2
		)
	end
end

local function wrongSide()
	error(PREFIX .. "ClientEvents are client-to-server; Connect on the server", 2)
end

local function makeEvent(route: ClientRoute): Types.ClientEvent
	local ev: any = {}
	local fire = ClientNet.fire
	local path = route.service .. ".ClientEvents." .. route.member
	ev.Fire = function(self: any, ...: any)
		if self == ev then
			fire(route, select("#", ...), ...)
		elseif self == nil and select("#", ...) == 0 then
			fire(route, 0)
		else
			error(PREFIX .. "Call " .. path .. ":Fire(...) with ':' (a '.' call shifts every argument)", 2)
		end
	end
	ev.Connect = wrongSide
	ev.Once = wrongSide
	ev.Wait = wrongSide
	lock(ev, path, "member", { "Fire" }, nil)
	return ev
end

local function buildService(svc: Types.ManifestService, routes: { ClientRoute }): Types.ServiceProxy
	local name = svc.name
	local proxy: any = {}
	local tryT: any = {}
	local signals: any = {}
	local events: any = {}
	local methodNames: { string } = {}
	local signalNames: { string } = {}
	local eventNames: { string } = {}
	for _, m in svc.members do
		local route = routes[m.route]
		if route == nil or route.member ~= m.name or route.kind ~= m.kind then
			continue -- ClientNet built routes from this model; never happens
		end
		if m.kind == KIND_METHOD then
			if RESERVED[m.name] then
				-- The server never networks these (boot warning there); they would replace a proxy field.
				Log.once(
					"px:reserved:" .. name .. "." .. m.name,
					name .. "." .. m.name .. " is a reserved name; skipped"
				)
				continue
			end
			proxy[m.name] = makeStub(proxy, route, false, name)
			tryT[m.name] = makeStub(tryT, route, true, name .. ".Try")
			table.insert(methodNames, m.name)
		elseif m.kind == KIND_EVENT then
			events[m.name] = makeEvent(route)
			table.insert(eventNames, m.name)
		elseif m.kind == KIND_SIGNAL then
			signals[m.name] = route.signal
			table.insert(signalNames, m.name)
		end
	end
	table.sort(methodNames)
	table.sort(signalNames)
	table.sort(eventNames)

	-- proxy.X for a name that is a Signal or ClientEvent points at the right table.
	local elsewhere: { [string]: string } = {}
	for _, s in signalNames do
		elsewhere[s] = "It is a Signal: use " .. name .. ".Signals." .. s .. "."
	end
	for _, e in eventNames do
		elsewhere[e] = "It is a ClientEvent: use " .. name .. ".ClientEvents." .. e .. ":Fire(...)."
	end

	lock(signals, name, "Signal", signalNames, nil)
	lock(events, name, "ClientEvent", eventNames, nil)
	lock(tryT, name .. ".Try", "method", methodNames, nil)
	proxy.Signals = signals
	proxy.ClientEvents = events
	proxy.Try = tryT
	lock(proxy, name, "method", methodNames, elsewhere)
	return proxy
end

-- API -----------------------------------------------------------------------------------------------

-- One proxy per manifest service (sorted by name in the manifest). Cached per model.
function Proxy.build(model: Types.ManifestModel): { [string]: Types.ServiceProxy }
	if builtFrom == model then
		return proxies
	end
	local routes = ClientNet.routes()
	local out: { [string]: Types.ServiceProxy } = {}
	local list: { string } = {}
	for _, svc in model.services do
		out[svc.name] = buildService(svc, routes)
		table.insert(list, svc.name)
	end
	table.sort(list)
	table.freeze(out :: any)
	proxies = out
	serviceNames = list
	builtFrom = model
	return proxies
end

function Proxy.get(name: string): Types.ServiceProxy?
	return proxies[name]
end

-- Sorted service names (a fresh copy; used for suggestions).
function Proxy.names(): { string }
	return table.clone(serviceNames)
end

function Proxy._reset(): ()
	builtFrom = nil
	proxies = NO_PROXIES
	serviceNames = {}
end

return table.freeze(Proxy)
