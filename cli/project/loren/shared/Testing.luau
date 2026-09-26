--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local Log = require(script.Parent.Log)
local Registry = require(script.Parent.Registry)
local Signal = require(script.Parent.Signal)
local Calls = require(script.Parent.Calls)
local ClientNet = require(script.Parent.ClientNet)
local Proxy = require(script.Parent.Proxy)
local Lifecycle = require(script.Parent.Lifecycle)

type Fired = { Method: string, Target: any, Args: { any } }

local PREFIX = C.PREFIX
local IS_SERVER = RunService:IsServer()

-- Recording object -> its fires (weak keys: dropped with the object).
local firedOf: { [any]: { Fired } } = setmetatable({}, { __mode = "k" }) :: any

local Testing = {}

local function wrongSide()
	error(PREFIX .. "Service Signals are server-to-client; Connect on the client proxy", 2)
end

-- A Service.Signals.X stand-in that records Fire/FireAll/FireFor/FireExcept.
local function recorder(service: string, name: string): any
	local fired: { Fired } = {}
	local obj: any = {}
	local function check(self: any, method: string)
		if not rawequal(self, obj) then
			error(string.format("%s%s.Signals.%s:%s(...) must be called with ':'", PREFIX, service, name, method), 3)
		end
	end
	function obj.Fire(self: any, player: any, ...: any)
		check(self, "Fire")
		table.insert(fired, { Method = "Fire", Target = player, Args = table.pack(...) :: any })
	end
	function obj.FireAll(self: any, ...: any)
		check(self, "FireAll")
		table.insert(fired, { Method = "FireAll", Target = nil, Args = table.pack(...) :: any })
	end
	function obj.FireFor(self: any, players: any, ...: any)
		check(self, "FireFor")
		table.insert(fired, { Method = "FireFor", Target = players, Args = table.pack(...) :: any })
	end
	function obj.FireExcept(self: any, except: any, ...: any)
		check(self, "FireExcept")
		table.insert(fired, { Method = "FireExcept", Target = except, Args = table.pack(...) :: any })
	end
	obj.Connect = wrongSide
	obj.Once = wrongSide
	obj.Wait = wrongSide
	firedOf[obj] = fired
	return table.freeze(obj)
end

-- A frozen name map whose unknown keys raise (like the server's Signals/ClientEvents maps).
local function strictMap(service: string, what: string, map: { [string]: any }): any
	local names: { string } = {}
	for k in map do
		table.insert(names, k)
	end
	return table.freeze(setmetatable(map, {
		__index = function(_: any, key: any): any
			local text = tostring(key)
			error(
				string.format("%s%s has no %s '%s'.", PREFIX, service, what, text)
					.. Registry.suggestion(text, names, what .. "s"),
				2
			)
		end,
	}))
end

function Testing.Mount(module: any, opts: any?): any
	if type(module) ~= "table" then
		error(PREFIX .. "Testing.Mount expects a module table, got " .. typeof(module), 3)
	end
	local kind = "Service"
	local deps: any = nil
	local name = "Mounted"
	if opts ~= nil then
		if type(opts) ~= "table" then
			error(PREFIX .. "Testing.Mount options must be a table (Dependencies, Kind, Name)", 3)
		end
		for k, v in next, opts do
			if k == "Dependencies" then
				if type(v) ~= "table" then
					error(PREFIX .. "Testing.Mount: Dependencies must be a table of name -> module", 3)
				end
				deps = v
			elseif k == "Kind" then
				if v ~= "Service" and v ~= "Controller" then
					error(PREFIX .. 'Testing.Mount: Kind must be "Service" or "Controller"', 3)
				end
				kind = v
			elseif k == "Name" then
				if type(v) ~= "string" then
					error(PREFIX .. "Testing.Mount: Name must be a string", 3)
				end
				name = v
			else
				error(PREFIX .. "Testing.Mount: unknown option '" .. tostring(k) .. "' (Dependencies, Kind, Name)", 3)
			end
		end
	end

	local rec: Types.ModuleRecord = {
		name = name,
		kind = kind,
		module = module,
		instance = nil :: any,
		path = "Testing.Mount(" .. name .. ")",
		deps = {},
	}
	local report = Registry.newReport(if IS_SERVER then "Server" else "Client")
	Registry.checkRecord(report, rec)
	if kind == "Service" then
		Registry.buildDecl(report, rec, Config.get())
	end
	if table.isfrozen(module) and deps ~= nil then
		table.insert(report.errors, name .. " is frozen, so Testing.Mount cannot set its Dependencies")
	end
	if #report.errors > 0 then
		error(PREFIX .. "Testing.Mount(" .. name .. ") failed:\n  " .. table.concat(report.errors, "\n  "), 3)
	end

	if kind == "Service" then
		local client = Registry.field(module, "Client")
		if type(client) == "table" then
			Registry.inject(client, "Server", module)
		end
		local declaredSignals = Registry.declared(module, "Signals")
		if declaredSignals ~= nil then
			local map: { [string]: any } = {}
			for _, s in Registry.nameList(nil, name .. ".Signals", declaredSignals) or ({} :: { string }) do
				map[s] = recorder(name, s)
			end
			Registry.inject(module, "Signals", strictMap(name, "Signal", map))
		end
		local declaredEvents = Registry.declared(module, "ClientEvents")
		if declaredEvents ~= nil then
			local map: { [string]: any } = {}
			for _, e in Registry.nameList(nil, name .. ".ClientEvents", declaredEvents) or ({} :: { string }) do
				map[e] = Signal.ServerEvent.new(name, e)
			end
			Registry.inject(module, "ClientEvents", strictMap(name, "ClientEvent", map))
		end
	else
		local signalNames = Registry.controllerSignals(module)
		if signalNames ~= nil then
			local map: { [string]: any } = {}
			for _, s in signalNames do
				map[s] = Signal.LocalSignal.new()
			end
			Registry.inject(module, "Signals", map)
		end
	end
	if not table.isfrozen(module) then
		Registry.inject(module, "Dependencies", deps or {})
	end
	return module
end

-- The fires recorded by a Signals object of a mounted Service (the live list; clear it freely).
function Testing.Fired(signal: any): { Fired }
	local list = if type(signal) == "table" then firedOf[signal] else nil
	if list == nil then
		error(PREFIX .. "Testing.Fired expects a Signals object of a module mounted with Testing.Mount", 3)
	end
	return list
end

local eventMeta: any = nil
local function isServerEvent(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	if eventMeta == nil then
		eventMeta = getmetatable(Signal.ServerEvent.new("Testing", "Probe") :: any)
	end
	return eventMeta ~= nil and getmetatable(v) == eventMeta
end

function Testing.Emit(event: any, player: any, ...: any): ()
	if not isServerEvent(event) then
		error(PREFIX .. "Testing.Emit expects a ClientEvents object of a module mounted with Testing.Mount", 3)
	end
	Signal.ServerEvent.deliver(event, player, ...)
end

local function callReset(mod: any)
	mod._reset()
end

local function resetModule(errors: { string }, label: string, mod: any)
	local ok, e = pcall(callReset :: any, mod)
	if not ok then
		table.insert(errors, label .. ": " .. tostring(e))
	end
end

function Testing.Reset(opts: any?): ()
	local offline = false
	if opts ~= nil then
		if type(opts) ~= "table" then
			error(PREFIX .. "Testing.Reset options must be a table like { Offline = true }", 3)
		end
		for k, v in next, opts do
			if k ~= "Offline" then
				error(PREFIX .. "Testing.Reset: unknown option '" .. tostring(k) .. "' (Offline)", 3)
			elseif type(v) ~= "boolean" then
				error(PREFIX .. "Testing.Reset: Offline must be a boolean", 3)
			end
			offline = v
		end
	end
	local errors: { string } = {}
	local S = Lifecycle.loadedServer(true)
	if S ~= nil then
		resetModule(errors, "Transport", S.Transport)
		resetModule(errors, "Routes", S.Routes)
		resetModule(errors, "Dispatch", S.Dispatch)
		resetModule(errors, "Outbox", S.Outbox)
		resetModule(errors, "ServerSignal", S.ServerSignal)
		resetModule(errors, "Limits", S.Limits)
		resetModule(errors, "Violations", S.Violations)
	end
	resetModule(errors, "ClientNet", ClientNet)
	resetModule(errors, "Calls", Calls)
	resetModule(errors, "Proxy", Proxy)
	resetModule(errors, "Signal", Signal)
	resetModule(errors, "Registry", Registry)
	resetModule(errors, "Config", Config)
	resetModule(errors, "Log", Log)
	resetModule(errors, "Lifecycle", Lifecycle)
	if IS_SERVER then
		local net = ReplicatedStorage:FindFirstChild(C.Names.NetFolder)
		if net then
			pcall(net.Destroy, net)
		end
	end
	Lifecycle.setOffline(offline)
	if #errors > 0 then
		error(PREFIX .. "Testing.Reset: some modules failed to reset:\n  " .. table.concat(errors, "\n  "), 3)
	end
end

return table.freeze(Testing)
