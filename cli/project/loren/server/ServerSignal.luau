--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Runtime = ReplicatedStorage.LorenRuntime

local C = require(Runtime.Constants)
local Types = require(Runtime.Types)
local Codec = require(Runtime.Codec)
local Log = require(Runtime.Log)
local Outbox = require(script.Parent.Outbox)

export type Route = Outbox.Route
export type RouteTable = Outbox.RouteTable
type PlayerState = Outbox.PlayerState
type Writer = Types.Writer

local PREFIX = C.PREFIX
local isStudio = RunService:IsStudio()
local UNRELIABLE_SEAL = C.Limit.UNRELIABLE_SEAL
local ENCODE_NAME: { [number]: string } = C.EncodeName :: any
local TOO_BIG = -1 -- local status: an unreliable message over UNRELIABLE_SEAL

local MSG_WRONG_SIDE = PREFIX .. "Service Signals are server-to-client; Connect on the client proxy"
local MSG_SELF = PREFIX .. "Call Signals.X:Fire(...) with ':'"

local writeHead = Codec.writeHead
local writeU16 = Codec.writeU16
local begin = Outbox.begin
local getState = Outbox.get
local send = Outbox.send
local sendUnreliable = Outbox.sendUnreliable

-- Module state (restored by _reset)
local seqs: { [number]: number } = {} -- route id -> last Ordered seq sent
local exceptSet: { [any]: boolean } = {} -- FireExcept scratch (cleared after every use)
local hintedLossy: { [number]: boolean } = {} -- route id -> lossy Fire hint shown (Studio)
local playerCheck: ((any) -> boolean)? = nil -- specs: treats test doubles as Players (Player is not creatable)

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
	return getState(p) ~= nil or isPlayer(p)
end

local function stateOf(player: any): PlayerState?
	local ps = getState(player)
	if ps == nil and isPlayer(player) then
		return Outbox.adopt(player)
	end
	return ps
end

local function encode(route: Route, n: number, ...: any): (Writer, number, number)
	local w = begin(route.unreliable)
	writeHead(w, route.id)
	if route.ordered then
		local s = ((seqs[route.id] or 0) + 1) % 65536
		seqs[route.id] = s
		writeU16(w, s)
	end
	local st = route.args.encode(w, n, ...)
	if st ~= 0 then
		local arg = w.errArg
		Outbox.abort()
		return w, st, arg
	end
	if route.unreliable and w.n > UNRELIABLE_SEAL then
		local size = w.n
		Outbox.abort()
		return w, TOO_BIG, size
	end
	if w.lossy > 0 and isStudio and not hintedLossy[route.id] then
		-- once per route, and no string is built outside Studio
		hintedLossy[route.id] = true
		Log.studioOnce(
			"lossy-fire:" .. route.fullName,
			route.fullName
				.. ":Fire got functions, threads or tables with metatables; they were sent as nil or plain tables"
		)
	end
	return w, 0, 0
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

function Methods.Fire(self: any, player: any, ...: any)
	local route = routeOf(self)
	if route == nil then
		error(MSG_SELF, 2)
	end
	if getState(player) == nil and not isPlayer(player) then
		error(badTarget(route, "Fire", "argument 1 must be a Player", player), 2)
	end
	local w, st, detail = encode(route, select("#", ...), ...)
	if st ~= 0 then
		error(encodeError(route, st, detail), 2)
	end
	local ps = stateOf(player)
	if ps == nil or ps.gone then
		Outbox.departed()
	elseif route.unreliable then
		sendUnreliable(ps, w)
	else
		send(ps, w)
	end
end

function Methods.FireAll(self: any, ...: any)
	local route = routeOf(self)
	if route == nil then
		error(MSG_SELF, 2)
	end
	local w, st, detail = encode(route, select("#", ...), ...)
	if st ~= 0 then
		error(encodeError(route, st, detail), 2)
	end
	local list = Outbox.players()
	if route.unreliable then
		for i = 1, #list do
			sendUnreliable(list[i], w)
		end
	else
		for i = 1, #list do
			send(list[i], w)
		end
	end
end

function Methods.FireFor(self: any, players: any, ...: any)
	local route = routeOf(self)
	if route == nil then
		error(MSG_SELF, 2)
	end
	if type(players) ~= "table" or isTarget(players) then
		error(badTarget(route, "FireFor", "argument 1 must be an array of Players", players), 2)
	end
	local count = rawlen(players)
	for i = 1, count do
		local p = rawget(players, i)
		if not isTarget(p) then
			error(badTarget(route, "FireFor", "entry " .. i .. " is not a Player", p), 2)
		end
	end
	local w, st, detail = encode(route, select("#", ...), ...)
	if st ~= 0 then
		error(encodeError(route, st, detail), 2)
	end
	local unreliable = route.unreliable
	for i = 1, count do
		local ps = stateOf(rawget(players, i))
		if ps == nil or ps.gone then
			Outbox.departed()
		elseif unreliable then
			sendUnreliable(ps, w)
		else
			send(ps, w)
		end
	end
end

function Methods.FireExcept(self: any, except: any, ...: any)
	local route = routeOf(self)
	if route == nil then
		error(MSG_SELF, 2)
	end
	local single = isTarget(except)
	local count = 0
	if not single then
		if type(except) ~= "table" then
			error(badTarget(route, "FireExcept", "argument 1 must be a Player or an array of Players", except), 2)
		end
		count = rawlen(except)
		for i = 1, count do
			local p = rawget(except, i)
			if not isTarget(p) then
				error(badTarget(route, "FireExcept", "entry " .. i .. " is not a Player", p), 2)
			end
		end
	end
	local w, st, detail = encode(route, select("#", ...), ...)
	if st ~= 0 then
		error(encodeError(route, st, detail), 2)
	end
	local list = Outbox.players()
	local unreliable = route.unreliable
	if single then
		for i = 1, #list do
			local ps = list[i]
			if ps.player ~= except then
				if unreliable then
					sendUnreliable(ps, w)
				else
					send(ps, w)
				end
			end
		end
		return
	end
	for i = 1, count do
		exceptSet[rawget(except, i)] = true
	end
	for i = 1, #list do
		local ps = list[i]
		if not exceptSet[ps.player] then
			if unreliable then
				sendUnreliable(ps, w)
			else
				send(ps, w)
			end
		end
	end
	table.clear(exceptSet)
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
	local object = setmetatable({ _route = route }, Meta)
	return table.freeze(object) :: any
end

function ServerSignal._reset(): ()
	table.clear(seqs)
	table.clear(hintedLossy)
	table.clear(exceptSet)
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
})

return table.freeze(ServerSignal)
