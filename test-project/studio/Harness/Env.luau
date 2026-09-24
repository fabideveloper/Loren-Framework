--!strict
--!optimize 2
--[[
	Env: shared state for the Studio test harness (one copy per VM: the server has one, each client has one).

	The harness scripts fill it after boot; specs and bots read it.
		Env.runtime        "2.0" | "1.5.1" | "raw"   (auto-detected, see detectRuntime; confirmed by adopt)
		Env.Loren          the Loren module (nil on raw)
		Env.boot           { ok, error, ms } of Loren:SetOnFire() on this side
		Env.proxies        client: service name -> proxy (from TestController.Dependencies, or RawClient)
		Env.services       server: service name -> service module (fixtures, or nil on raw)
		Env.controller     client: the TestController module
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Env = {}

export type Config = {
	Scenario: string,
	Duration: number,
	Rate: number,
	PayloadSize: number,
	Clients: number,
}

Env.SERVICE_NAMES = {
	"EchoService",
	"CounterService",
	"InventoryService",
	"InstanceService",
	"BroadcastService",
	"DependentService",
}

Env.DEFAULTS = {
	Scenario = "check",
	Duration = 20,
	Rate = 30,
	PayloadSize = 64,
	Clients = 0, -- 0 = auto: start once the clients that joined are ready
} :: Config

Env.SCENARIOS = { "check", "stress", "burst", "security", "soak", "compare", "all" }

Env.isStudio = RunService:IsStudio()
Env.isRunMode = RunService:IsRunMode()
Env.isServer = RunService:IsServer()
-- In Studio Run mode IsClient() is also true on the server; the harness only means a real client.
Env.isClient = RunService:IsClient() and not RunService:IsServer()

-- 2.0 if ReplicatedStorage has LorenRuntime, 1.5.1 if LorenBridge exists (or, before the 1.5.1 server
-- has booted, if ReplicatedStorage.Shared.Loren exists), otherwise raw.
function Env.detectRuntime(): string
	if ReplicatedStorage:FindFirstChild("LorenRuntime") then
		return "2.0"
	end
	if ReplicatedStorage:FindFirstChild("LorenBridge") then
		return "1.5.1"
	end
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	if shared and shared:FindFirstChild("Loren") then
		return "1.5.1"
	end
	return "raw"
end

function Env.setRuntime(runtime: string)
	Env.runtime = runtime
	Env.is20 = runtime == "2.0"
	Env.is151 = runtime == "1.5.1"
	Env.isRaw = runtime == "raw"
end

Env.runtime = "raw"
Env.is20, Env.is151, Env.isRaw = false, false, true
Env.setRuntime(Env.detectRuntime())
Env.note = nil :: string?

-- The Version string of a loaded Loren module (nil for 1.5.1, which has no Version field).
function Env.versionOf(loren: any): string?
	if typeof(loren) ~= "table" then
		return nil
	end
	local ok, version = pcall(function()
		return loren.Version
	end)
	return if ok and typeof(version) == "string" then version else nil
end

-- Called once Shared.Loren has loaded. The folder check above only proves that LorenRuntime is
-- mapped; until the 3-line shim replaces Shared.Loren, the module actually running is 1.5.1, and
-- the specs must treat it as such.
function Env.adopt(loren: any)
	Env.Loren = loren
	if not Env.is20 then
		return
	end
	local version = Env.versionOf(loren)
	if version == nil or string.sub(version, 1, 2) ~= "2." then
		Env.setRuntime("1.5.1")
		Env.note = "ReplicatedStorage.LorenRuntime exists, but Shared.Loren has no 2.x Version "
			.. "(shim not installed yet?): treating the runtime as 1.5.1"
	end
end

Env.Loren = nil :: any
Env.boot = { ok = false, error = nil :: string?, ms = 0, value = nil :: any }
Env.proxies = {} :: { [string]: any }
Env.services = {} :: { [string]: any }
Env.controller = nil :: any

function Env.runtimeLabel(): string
	if Env.runtime == "2.0" then
		local loren = Env.Loren
		local ok, version = pcall(function()
			return if typeof(loren) == "table" then loren.Version else nil
		end)
		if ok and typeof(version) == "string" then
			return "2.0 (" .. version .. ")"
		end
		return "2.0"
	elseif Env.runtime == "1.5.1" then
		return "1.5.1 (baseline)"
	end
	return "raw RemoteEvents"
end

local function readNumber(config: Instance, name: string, fallback: number, min: number, max: number): number
	local value = config:GetAttribute(name)
	if typeof(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.clamp(value, min, max)
end

function Env.config(): Config
	local config = ReplicatedStorage:FindFirstChild("TestConfig")
	local defaults = Env.DEFAULTS
	if not config then
		return table.clone(defaults)
	end
	local scenario = config:GetAttribute("Scenario")
	return {
		Scenario = if typeof(scenario) == "string" then string.lower(scenario) else defaults.Scenario,
		Duration = readNumber(config, "Duration", defaults.Duration, 1, 86400),
		Rate = readNumber(config, "Rate", defaults.Rate, 1, 2000),
		PayloadSize = math.floor(readNumber(config, "PayloadSize", defaults.PayloadSize, 0, 1000000)),
		Clients = math.floor(readNumber(config, "Clients", defaults.Clients, 0, 8)),
	}
end

-- Yields until predicate() is truthy or timeout seconds pass. Returns whether it became truthy.
function Env.waitUntil(predicate: () -> any, timeout: number?, step: number?): boolean
	local deadline = os.clock() + (timeout or 5)
	while not predicate() do
		if os.clock() >= deadline then
			return false
		end
		task.wait(step or 0.03)
	end
	return true
end

function Env.proxy(name: string): any
	local proxy = Env.proxies[name]
	if proxy == nil then
		error("(LORENঌ - TEST) no proxy for " .. name .. " (client not booted?)", 2)
	end
	return proxy
end

function Env.service(name: string): any
	local service = Env.services[name]
	if service == nil then
		error("(LORENঌ - TEST) no service module " .. name .. " (server not booted, or raw runtime)", 2)
	end
	return service
end

-- First value of a rejection as a string (2.0 rejects with (message, info); 1.5.1 with a string).
function Env.reason(value: any): string
	if typeof(value) == "string" then
		return value
	end
	local ok, s = pcall(tostring, value)
	return if ok then s else "<unprintable>"
end

return Env
