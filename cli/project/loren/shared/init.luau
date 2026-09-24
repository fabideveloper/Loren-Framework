--!strict
--!optimize 2
--[[
	Loren facade (owner lane: lifecycle): ReplicatedStorage.LorenRuntime, the table that
	ReplicatedStorage.Shared.Loren (the shim) returns.
	Spec: IMPLEMENTATION.md sections 3.13, 7 and 9.

	- Every function works with `.` and `:` (a leading Loren argument is dropped; Loren.Testing
	  functions drop a leading Loren.Testing). Each one calls its lane function directly, so a lane
	  error raised at level 3 points at the caller's line.
	- IsServer = RunService:IsServer(); IsClient = not IsServer (Studio Run mode and Edit mode boot
	  as a server).
	- ServerScriptService.LorenServer is required lazily, on the first server-only call (never on a
	  client), so shared code has no require edge to server code.
	- IsOnFire, IsReady and State are written only by Lifecycle.
	No side effects on require.
]]

local RunService = game:GetService("RunService")

local C = require(script.Constants)
local Types = require(script.Types)
local Version = require(script.Version)
local Errors = require(script.Errors)
local Config = require(script.Config)
local Registry = require(script.Registry)
local Schema = require(script.Schema)
local ClientNet = require(script.ClientNet)
local Lifecycle = require(script.Lifecycle)
local Testing = require(script.Testing)

local PREFIX = C.PREFIX
local IS_SERVER = RunService:IsServer()

local Loren = {}
local LorenTesting = {}

-- Drops a leading Loren argument (colon calls), keeping the argument count (nil holes survive).
local function strip(...: any): ...any
	if select("#", ...) > 0 and rawequal((...), Loren) then
		return select(2, ...)
	end
	return ...
end

local function stripTesting(...: any): ...any
	if select("#", ...) > 0 and rawequal((...), LorenTesting) then
		return select(2, ...)
	end
	return ...
end

-- Lazy ServerScriptService.LorenServer (server only). peek = return the cached index or nil.
-- A require the type checker does not trace: shared code has no type-level edge to server code.
local dynamicRequire: (any) -> any = require :: any
local serverIndex: any = nil
local function getServer(peek: boolean?): any
	if serverIndex ~= nil or peek then
		return serverIndex
	end
	local inst = Lifecycle.findServerFolder(true)
	if inst == nil then
		error(PREFIX .. "ServerScriptService.LorenServer missing: run loren update", 2)
	end
	serverIndex = dynamicRequire(inst)
	return serverIndex
end

local function serverOnly(api: string)
	if not IS_SERVER then
		error(PREFIX .. api .. " is server-only", 3)
	end
end

local function needFunction(api: string, fn: any)
	if type(fn) ~= "function" then
		error(PREFIX .. api .. " expects a function, got " .. typeof(fn), 3)
	end
end

local function zeroStats(side: string): Types.Stats
	return {
		Side = side,
		FramesIn = 0,
		FramesOut = 0,
		BytesIn = 0,
		BytesOut = 0,
		MessagesIn = 0,
		MessagesOut = 0,
		FramesDropped = 0,
		EventsLost = 0,
		CallsRateLimited = 0,
		BadRequests = 0,
		Busy = 0,
		Violations = 0,
		LateReplies = 0,
		OutboxDropped = 0,
		SignalsDropped = 0,
		RunningCalls = 0,
		ZombieCalls = 0,
		PendingCalls = 0,
		Players = 0,
		Routes = 0,
	}
end

-- Fields ----------------------------------------------------------------------------------------------

Loren.IsServer = IS_SERVER
Loren.IsClient = not IS_SERVER
Loren.IsOnFire = false
Loren.IsReady = false
Loren.State = C.State.Idle
Loren.Version = Version.Version
Loren.Errors = Errors.Public
Loren.T = Schema.T

-- Registration and boot -------------------------------------------------------------------------------

function Loren.AddServices(...: any): ()
	Registry.add("Service", strip(...))
end

function Loren.AddControllers(...: any): ()
	Registry.add("Controller", strip(...))
end

function Loren.SetOnFire(_self: any?): Types.Promise
	local promise = Lifecycle.setOnFire()
	return promise
end

function Loren.OnReady(_self: any?): Types.Promise
	local promise = Lifecycle.onReady()
	return promise
end

function Loren.GetService(...: any): any
	local service = Lifecycle.getService(strip(...))
	return service
end

function Loren.GetController(...: any): any
	local controller = Lifecycle.getController(strip(...))
	return controller
end

local function get(...: any): any
	local module = Lifecycle.get(strip(...))
	return module
end
Loren.Get = get

function Loren.Configure(...: any): ()
	Config.set(strip(...))
end

-- Server hooks ----------------------------------------------------------------------------------------

function Loren.AddMiddleware(...: any): ()
	serverOnly("AddMiddleware")
	local fn = strip(...)
	needFunction("AddMiddleware", fn)
	if Config.isFrozen() then
		error(PREFIX .. "AddMiddleware must be called before SetOnFire", 2)
	end
	Lifecycle.server().Dispatch.addMiddleware(fn)
end

function Loren.OnViolation(...: any): ()
	serverOnly("OnViolation")
	local fn = strip(...)
	needFunction("OnViolation", fn)
	Lifecycle.server().Violations.onViolation(fn)
end

function Loren.OnError(...: any): ()
	serverOnly("OnError")
	local fn = strip(...)
	needFunction("OnError", fn)
	Lifecycle.server().Dispatch.onError(fn)
end

-- Network ---------------------------------------------------------------------------------------------

function Loren.Flush(_self: any?): ()
	if not Lifecycle.netUp() then
		return -- before networking exists
	end
	if IS_SERVER then
		local S = Lifecycle.server(true)
		if S ~= nil then
			S.Transport.flushNow()
		end
	else
		ClientNet.flush()
	end
end

function Loren.GetStats(_self: any?): Types.Stats
	if IS_SERVER then
		local S = Lifecycle.server(true)
		if S ~= nil then
			return S.Transport.getStats()
		end
		return zeroStats("Server")
	end
	return ClientNet.getStats()
end

function Loren.DumpManifest(_self: any?): Types.ManifestModel
	if not IS_SERVER then
		error(PREFIX .. "DumpManifest is server-only", 2)
	end
	local S = Lifecycle.server(true)
	if S == nil or S.Routes.current() == nil then
		error(PREFIX .. "DumpManifest needs the routes: call it after SetOnFire built them (Loren.OnReady())", 2)
	end
	return S.Routes.dump()
end

-- Values and specs ------------------------------------------------------------------------------------

function Loren.Reject(...: any): Types.RejectSentinel
	return Errors.reject(strip(...))
end

function Loren.Method(...: any): any
	local spec = Schema.method(strip(...))
	return spec
end

function Loren.Event(...: any): any
	local spec = Schema.event(strip(...))
	return spec
end

function Loren.Signal(...: any): any
	local spec = Schema.signal(strip(...))
	return spec
end

-- Testing ---------------------------------------------------------------------------------------------

function LorenTesting.Mount(...: any): any
	local module = Testing.Mount(stripTesting(...))
	return module
end

function LorenTesting.Fired(...: any): { any }
	local list = Testing.Fired(stripTesting(...))
	return list
end

function LorenTesting.Emit(...: any): ()
	Testing.Emit(stripTesting(...))
end

function LorenTesting.Reset(...: any): ()
	Testing.Reset(stripTesting(...))
end

Loren.Testing = table.freeze(LorenTesting)

Lifecycle.bind(Loren, getServer)

return (Loren :: any) :: Types.Loren
