--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Runtime = ReplicatedStorage.LorenRuntime

local C = require(Runtime.Constants)
local Types = require(Runtime.Types)
local Codec = require(Runtime.Codec)
local Schema = require(Runtime.Schema)
local Log = require(Runtime.Log)
local Outbox = require(script.Parent.Outbox)

export type Route = Outbox.Route
export type RouteTable = Outbox.RouteTable
type PlayerState = Outbox.PlayerState
type Writer = Types.Writer
type Senders = {
	Fire: (self: any, player: any, ...any) -> (),
	FireAll: (self: any, ...any) -> (),
	FireFor: (self: any, players: any, ...any) -> (),
	FireExcept: (self: any, except: any, ...any) -> (),
}

local PREFIX = C.PREFIX
local isStudio = RunService:IsStudio()
local UNRELIABLE_SEAL = C.Limit.UNRELIABLE_SEAL
local ENCODE_NAME: { [number]: string } = C.EncodeName :: any
local TOO_BIG = -1 -- local status: an unreliable message over UNRELIABLE_SEAL
local E_TOO_MANY_VALUES = C.Encode.TOO_MANY_VALUES
local FIXED_MAX = 1024

local MSG_WRONG_SIDE = PREFIX .. "Service Signals are server-to-client; Connect on the client proxy"
local MSG_SELF = PREFIX .. "Call Signals.X:Fire(...) with ':'"

local grow = Codec.grow
local headSize = Codec.headSize
local resetWriter = Codec.resetWriter
local writeArgs = Codec.writeArgs
local encodeFields = Schema.encodeFields
local abort = Outbox.abort
local tidy = Outbox.tidy
local send = Outbox.send
local sendUnreliable = Outbox.sendUnreliable
local commit = Outbox.commit
local broadcast = Outbox.broadcast
local broadcastUnreliable = Outbox.broadcastUnreliable
local broadcastBut = Outbox.broadcastBut
local broadcastExcept = Outbox.broadcastExcept
local placed = Outbox.placed
local placedUnreliable = Outbox.placedUnreliable
local departed = Outbox.departed
local adopt = Outbox.adopt
local states = Outbox.states
local list = Outbox.players()
local scratch = Outbox.scratch
local SCRATCH_KEEP = Outbox.SCRATCH_KEEP

-- Module state (restored by _reset)
local seqs: { [number]: number } = {} -- route id -> last Ordered seq sent
local exceptSet: { [any]: boolean } = {} -- FireExcept scratch (cleared after every use)
local hintedLossy: { [number]: boolean } = {} -- route id -> lossy Fire hint shown (Studio)
local playerCheck: ((any) -> boolean)? = nil -- specs: treats test doubles as Players (Player is not creatable)
local fixed: Writer = Codec.newWriter(FIXED_MAX, false)
local others: { [any]: Senders } = {}

local Methods = {}
local Meta = {
	__index = Methods,
	__tostring = function(self: any): string
		return "Signal " .. (rawget(self, "_route") :: Route).fullName
	end,
}

local function routeOf(self: any): Route?
	if type(self) == "table" and getmetatable(self) == Meta then
		return rawget(self, "_route") :: any
	end
	return nil
end

local function isPlayer(p: any): boolean
	local check = playerCheck
	if check ~= nil then
		return check(p)
	end
	return typeof(p) == "Instance" and (p :: Instance):IsA("Player")
end

-- A Player, or a test double that has a player state.
local function isTarget(p: any): boolean
	return states[p] ~= nil or isPlayer(p)
end

local function lossyHint(route: Route, w: Writer)
	if w.lossy > 0 and isStudio and not hintedLossy[route.id] then
		-- once per route, and no string is built outside Studio
		hintedLossy[route.id] = true
		Log.studioOnce(
			"lossy-fire:" .. route.fullName,
			route.fullName
				.. ":Fire got functions, threads or tables with metatables; they were sent as nil or plain tables"
		)
	end
end

-- The error text for a failed encode (raised by the caller at level 2).
local function encodeError(route: Route, st: number, detail: number): string
	if st == TOO_BIG then
		return string.format(
			"%s%s:Fire: the message is %d bytes; unreliable Signals are limited to %d bytes",
			PREFIX,
			route.fullName,
			detail,
			UNRELIABLE_SEAL
		)
	end
	return string.format("%s%s:Fire: arg %d %s", PREFIX, route.fullName, detail, ENCODE_NAME[st] or tostring(st))
end

local function badTarget(route: Route, method: string, what: string, got: any): string
	return string.format("%s%s:%s: %s (got %s)", PREFIX, route.fullName, method, what, typeof(got))
end

-- Methods ------------------------------------------------------------------------------------------

local other: (self: any) -> Senders

local function senders(route: Route, object: any, lvl: number): Senders
	local id = route.id
	local unreliable = route.unreliable
	local ordered = route.ordered
	local codec = route.args
	local maxArgs = codec.maxArgs
	local plan = Schema.plan(codec)
	local typed = plan ~= nil
	local arity = if plan then plan.count else 0
	local prog: any = if plan then plan.prog else nil
	local put: any = if plan then plan.put else nil
	local putN: any = if plan then plan.putN else nil
	local one = arity == 1
	local hs = headSize(id)
	local head2 = if hs == 2 then (0xE0 + bit32.rshift(id - 224, 8)) + bit32.band(id - 224, 0xFF) * 256 else 0
	local pre = hs + (if ordered then 2 else 0)
	local size = if plan and plan.size > 0 then pre + plan.size else 0
	if size > FIXED_MAX or (unreliable and size > UNRELIABLE_SEAL) then
		size = 0
	end

	local function longHead(b: buffer, o: number)
		if hs == 2 then
			buffer.writeu16(b, o, head2)
		else
			buffer.writeu8(b, o, 0xEF)
			buffer.writeu16(b, o + 1, id)
		end
	end

	local function failText(w: Writer, st: number): string
		local detail = if st ~= 0 then w.errArg else w.n
		abort()
		return encodeError(route, if st ~= 0 then st else TOO_BIG, detail)
	end

	local function encode(...: any): Writer
		local n = select("#", ...)
		if size > 0 then
			if scratch.nrefs > 0 or scratch.cap > SCRATCH_KEEP then
				tidy()
			end
			local s = 0
			if ordered then
				s = ((seqs[id] or 0) + 1) % 65536
				seqs[id] = s
			end
			if n > arity then
				error(encodeError(route, E_TOO_MANY_VALUES, arity + 1), lvl + 1)
			end
			local b = fixed.buf
			if hs == 1 then
				buffer.writeu8(b, 0, id)
			else
				longHead(b, 0)
			end
			if ordered then
				buffer.writeu16(b, hs, s)
			end
			local st, arg = 0, 1
			if one then
				st = put(b, pre, (...))
			else
				st, arg = putN(b, pre, ...)
			end
			if st ~= 0 then
				error(encodeError(route, st, arg), lvl + 1)
			end
			fixed.n = size
			return fixed
		end
		local w = scratch
		if w.cap > SCRATCH_KEEP then
			tidy()
		else
			resetWriter(w)
		end
		w.unreliable = unreliable
		local b = w.buf
		if hs == 1 then
			buffer.writeu8(b, 0, id)
		else
			longHead(b, 0)
		end
		if ordered then
			local s = ((seqs[id] or 0) + 1) % 65536
			seqs[id] = s
			buffer.writeu16(b, hs, s)
		end
		w.n = pre
		local st = 0
		if not typed then
			st = writeArgs(w, maxArgs, n, ...)
		elseif n > arity then
			w.errArg = arity + 1
			st = E_TOO_MANY_VALUES
		else
			st = encodeFields(w, prog, nil, ...)
		end
		if st ~= 0 or (unreliable and w.n > UNRELIABLE_SEAL) then
			error(failText(w, st), lvl + 1)
		end
		if w.lossy > 0 then
			lossyHint(route, w)
		end
		return w
	end

	@native
	local function Fire(self: any, player: any, ...: any)
		if self ~= object then
			other(self).Fire(self, player, ...)
			return
		end
		local ps: PlayerState? = states[player]
		if ps == nil and not isPlayer(player) then
			error(badTarget(route, "Fire", "argument 1 must be a Player", player), lvl)
		end
		if size > 0 and ps ~= nil and ps.helloed and not ps.gone then
			if scratch.nrefs > 0 or scratch.cap > SCRATCH_KEEP then
				tidy()
			end
			local n = select("#", ...)
			local s = 0
			if ordered then
				s = ((seqs[id] or 0) + 1) % 65536
				seqs[id] = s
			end
			if n > arity then
				error(encodeError(route, E_TOO_MANY_VALUES, arity + 1), lvl)
			end
			local cw = if unreliable then ps.uout.w else ps.out.w
			local o = cw.n
			local need = o + size
			if need > cw.cap then
				grow(cw, need)
			end
			local b = cw.buf
			if hs == 1 then
				buffer.writeu8(b, o, id)
			else
				longHead(b, o)
			end
			if ordered then
				buffer.writeu16(b, o + hs, s)
			end
			local st, arg = 0, 1
			if one then
				st = put(b, o + pre, (...))
			else
				st, arg = putN(b, o + pre, ...)
			end
			if st ~= 0 then
				error(encodeError(route, st, arg), lvl)
			end
			if unreliable then
				placedUnreliable(ps, o, need)
			else
				placed(ps, o, need)
			end
			return
		end
		local w: Writer
		if size > 0 then
			w = encode(...)
		else
			local n = select("#", ...)
			w = scratch
			if w.cap > SCRATCH_KEEP then
				tidy()
			else
				resetWriter(w)
			end
			w.unreliable = unreliable
			local b = w.buf
			if hs == 1 then
				buffer.writeu8(b, 0, id)
			else
				longHead(b, 0)
			end
			if ordered then
				local s = ((seqs[id] or 0) + 1) % 65536
				seqs[id] = s
				buffer.writeu16(b, hs, s)
			end
			w.n = pre
			local st = 0
			if not typed then
				st = writeArgs(w, maxArgs, n, ...)
			elseif n > arity then
				w.errArg = arity + 1
				st = E_TOO_MANY_VALUES
			else
				st = encodeFields(w, prog, nil, ...)
			end
			if st ~= 0 or (unreliable and w.n > UNRELIABLE_SEAL) then
				error(failText(w, st), lvl)
			end
			if w.lossy > 0 then
				lossyHint(route, w)
			end
		end
		if ps == nil then
			ps = adopt(player)
		end
		if ps == nil or ps.gone then
			departed()
		elseif unreliable then
			sendUnreliable(ps, w)
		else
			send(ps, w)
		end
	end

	@native
	local function FireAll(self: any, ...: any)
		if self ~= object then
			other(self).FireAll(self, ...)
			return
		end
		local n = select("#", ...)
		if size > 0 then
			if scratch.nrefs > 0 or scratch.cap > SCRATCH_KEEP then
				tidy()
			end
			local s = 0
			if ordered then
				s = ((seqs[id] or 0) + 1) % 65536
				seqs[id] = s
			end
			if n > arity then
				error(encodeError(route, E_TOO_MANY_VALUES, arity + 1), lvl)
			end
			local only: PlayerState? = if #list == 1 then list[1] else nil
			if only ~= nil and only.helloed and not only.gone then
				local cw = if unreliable then only.uout.w else only.out.w
				local o = cw.n
				local need = o + size
				if need > cw.cap then
					grow(cw, need)
				end
				local b = cw.buf
				if hs == 1 then
					buffer.writeu8(b, o, id)
				else
					longHead(b, o)
				end
				if ordered then
					buffer.writeu16(b, o + hs, s)
				end
				local st, arg = 0, 1
				if one then
					st = put(b, o + pre, (...))
				else
					st, arg = putN(b, o + pre, ...)
				end
				if st ~= 0 then
					error(encodeError(route, st, arg), lvl)
				end
				if unreliable then
					placedUnreliable(only, o, need)
				else
					placed(only, o, need)
				end
				return
			end
			local b = fixed.buf
			if hs == 1 then
				buffer.writeu8(b, 0, id)
			else
				longHead(b, 0)
			end
			if ordered then
				buffer.writeu16(b, hs, s)
			end
			local st, arg = 0, 1
			if one then
				st = put(b, pre, (...))
			else
				st, arg = putN(b, pre, ...)
			end
			if st ~= 0 then
				error(encodeError(route, st, arg), lvl)
			end
			fixed.n = size
			if unreliable then
				broadcastUnreliable(fixed)
			else
				broadcast(fixed)
			end
			return
		end
		local w = scratch
		if w.cap > SCRATCH_KEEP then
			tidy()
		else
			resetWriter(w)
		end
		w.unreliable = unreliable
		local b = w.buf
		if hs == 1 then
			buffer.writeu8(b, 0, id)
		else
			longHead(b, 0)
		end
		if ordered then
			local s = ((seqs[id] or 0) + 1) % 65536
			seqs[id] = s
			buffer.writeu16(b, hs, s)
		end
		w.n = pre
		local st = 0
		if not typed then
			st = writeArgs(w, maxArgs, n, ...)
		elseif n > arity then
			w.errArg = arity + 1
			st = E_TOO_MANY_VALUES
		else
			st = encodeFields(w, prog, nil, ...)
		end
		if st ~= 0 or (unreliable and w.n > UNRELIABLE_SEAL) then
			error(failText(w, st), lvl)
		end
		if w.lossy > 0 then
			lossyHint(route, w)
		end
		if unreliable then
			broadcastUnreliable(w)
		else
			broadcast(w)
		end
	end

	local function FireFor(self: any, players: any, ...: any)
		if self ~= object then
			other(self).FireFor(self, players, ...)
			return
		end
		if type(players) ~= "table" or isTarget(players) then
			error(badTarget(route, "FireFor", "argument 1 must be an array of Players", players), lvl)
		end
		local count = rawlen(players)
		for i = 1, count do
			local p = rawget(players, i)
			if not isTarget(p) then
				error(badTarget(route, "FireFor", "entry " .. i .. " is not a Player", p), lvl)
			end
		end
		local w = encode(...)
		for i = 1, count do
			local p: any = rawget(players, i)
			local ps: PlayerState? = states[p]
			if ps == nil and isPlayer(p) then
				ps = adopt(p)
			end
			if ps == nil or ps.gone then
				departed()
			elseif unreliable then
				sendUnreliable(ps, w)
			elseif ps.helloed then
				commit(ps, w, 0)
			else
				send(ps, w)
			end
		end
	end

	local function FireExcept(self: any, except: any, ...: any)
		if self ~= object then
			other(self).FireExcept(self, except, ...)
			return
		end
		local single = isTarget(except)
		local count = 0
		if not single then
			if type(except) ~= "table" then
				error(badTarget(route, "FireExcept", "argument 1 must be a Player or an array of Players", except), lvl)
			end
			count = rawlen(except)
			for i = 1, count do
				local p = rawget(except, i)
				if not isTarget(p) then
					error(badTarget(route, "FireExcept", "entry " .. i .. " is not a Player", p), lvl)
				end
			end
		end
		local w = encode(...)
		if single then
			broadcastBut(w, except, unreliable)
			return
		end
		for i = 1, count do
			exceptSet[rawget(except, i)] = true
		end
		broadcastExcept(w, exceptSet, unreliable)
		table.clear(exceptSet)
	end

	return { Fire = Fire, FireAll = FireAll, FireFor = FireFor, FireExcept = FireExcept }
end

other = function(self: any): Senders
	local cached = others[self]
	if cached ~= nil then
		return cached
	end
	local route = routeOf(self)
	if route == nil then
		error(MSG_SELF, 3)
	end
	local built = senders(route, self, 3)
	others[self] = built
	return built
end

function Methods.Fire(self: any, ...: any)
	other(self).Fire(self, ...)
end

function Methods.FireAll(self: any, ...: any)
	other(self).FireAll(self, ...)
end

function Methods.FireFor(self: any, ...: any)
	other(self).FireFor(self, ...)
end

function Methods.FireExcept(self: any, ...: any)
	other(self).FireExcept(self, ...)
end

function Methods.Connect(_: any, ...: any)
	error(MSG_WRONG_SIDE, 2)
end

function Methods.Once(_: any, ...: any)
	error(MSG_WRONG_SIDE, 2)
end

function Methods.Wait(_: any, ...: any)
	error(MSG_WRONG_SIDE, 2)
end

function Methods.DisconnectAll(_: any, ...: any)
	error(MSG_WRONG_SIDE, 2)
end

table.freeze(Methods)
table.freeze(Meta)

-- Module -------------------------------------------------------------------------------------------

local ServerSignal = {}

-- The frozen Signals.X object for a Signal route (Routes.build).
function ServerSignal.new(route: Route): Types.ServerSignal
	local object: any = { _route = route }
	local own = senders(route, object, 2)
	object.Fire = own.Fire
	object.FireAll = own.FireAll
	object.FireFor = own.FireFor
	object.FireExcept = own.FireExcept
	local sealed: any = setmetatable(object, Meta)
	return table.freeze(sealed)
end

function ServerSignal._reset(): ()
	table.clear(seqs)
	table.clear(hintedLossy)
	table.clear(exceptSet)
	table.clear(others)
	playerCheck = nil
end

ServerSignal._test = table.freeze({
	-- The last Ordered seq sent on a route (0 = none yet).
	lastSeq = function(routeId: number): number
		return seqs[routeId] or 0
	end,
	routeOf = routeOf,
	setPlayerCheck = function(fn: ((any) -> boolean)?)
		playerCheck = fn
	end,
	fixed = function(): Writer
		return fixed
	end,
	senders = function(object: any): Senders?
		return others[object]
	end,
})

return table.freeze(ServerSignal)
