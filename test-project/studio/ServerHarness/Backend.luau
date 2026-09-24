--!strict
--!optimize 2
--[[
	Backend: one server-side interface over the three runtimes (2.0, 1.5.1, raw).
		Backend.boot(instrument)      boots Loren with the fixtures (+ fixtures/v2 on 2.x), or starts RawServer
		Backend.resetRuntime()        2.0: Loren.Testing.Reset() through the LorenRuntime facade
		Backend.startTicking(rate)    -> first Tick index;  Backend.stopTicking() -> last index
		Backend.fireBurst(n)          -> (first, last)
		Backend.countFor(player)      CounterService count (security integrity check)
		Backend.handlerStats()        per-method handler calls/errors/denials/time
		Backend.lorenStats()          2.0 Loren.GetStats() flattened to "key=value" lines, or nil
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Harness = ReplicatedStorage:WaitForChild("LorenTest"):WaitForChild("Harness")
local Env = require(Harness:WaitForChild("Env"))
local Instrument = require(script.Parent:WaitForChild("Instrument"))

local Backend = {}

local raw: any = nil

local function testFolder(): Instance
	return ServerStorage:WaitForChild("LorenTest")
end

function Backend.boot(instrument: boolean)
	local started = os.clock()
	if Env.isRaw then
		raw = require(ServerStorage:WaitForChild("LorenTest"):WaitForChild("RawServer"))
		local ok, err = pcall(raw.start)
		Env.boot.ok = ok
		Env.boot.error = if ok then nil else tostring(err)
		Env.boot.ms = (os.clock() - started) * 1000
		return
	end

	local servicesFolder = testFolder():WaitForChild("Services")
	-- Require the fixtures first: Loren gets the same tables from the require cache.
	for _, module in servicesFolder:GetChildren() do
		if module:IsA("ModuleScript") then
			local ok, service = pcall(require, module)
			if ok then
				Env.services[module.Name] = service
				if instrument then
					Instrument.wrapService(module.Name, service)
				end
			else
				warn("[LorenTest] fixture " .. module.Name .. " failed to load: " .. tostring(service))
			end
		end
	end

	local loaded, Loren = pcall(require, ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loren"))
	if not loaded then
		Env.boot.ok = false
		Env.boot.error = "require(Shared.Loren) failed: " .. tostring(Loren)
		return
	end
	Env.adopt(Loren)

	-- 2.0-only fixtures (fixtures/v2, written by the integration phase): registered only when the
	-- loaded Loren is 2.x (IMPLEMENTATION section 10), never instrumented (the v2 middleware specs
	-- depend on the real parameter counts).
	local v2Folder = testFolder():FindFirstChild("V2Services")
	if v2Folder and not Env.is20 then
		v2Folder = nil
	end
	if v2Folder then
		for _, module in v2Folder:GetChildren() do
			if module:IsA("ModuleScript") then
				local ok, service = pcall(require, module)
				if ok then
					Env.services[module.Name] = service
				end
			end
		end
	end

	local added, addError = pcall(function()
		Loren.AddServices(servicesFolder)
		if v2Folder then
			Loren.AddServices(v2Folder)
		end
	end)
	local awaited, resolved, value = pcall(function()
		return Loren:SetOnFire():await()
	end)
	Env.boot.ms = (os.clock() - started) * 1000
	Env.boot.ok = added and awaited and resolved == true
	Env.boot.value = value
	if not added then
		Env.boot.error = "AddServices threw: " .. tostring(addError)
	elseif not awaited then
		Env.boot.error = "SetOnFire threw: " .. tostring(resolved)
	elseif resolved ~= true then
		Env.boot.error = "SetOnFire rejected: " .. Env.reason(value)
	end
end

-- Loren.Testing.Reset() through ReplicatedStorage.LorenRuntime (the 2.0 facade), so state left by
-- the unit specs never reaches the fixture boot. Returns an error text, or nil when it ran.
function Backend.resetRuntime(): string?
	local runtime = ReplicatedStorage:FindFirstChild("LorenRuntime")
	if not (runtime and runtime:IsA("ModuleScript")) then
		return "ReplicatedStorage.LorenRuntime is not a module yet (no init.luau)"
	end
	local ok, err = pcall(function()
		local facade = require(runtime) :: any
		facade.Testing.Reset()
	end)
	return if ok then nil else tostring(err)
end

local function broadcast(): any
	return Env.services.BroadcastService
end

function Backend.startTicking(rate: number): number
	if raw then
		return raw.startTicking(rate)
	end
	local service = broadcast()
	return if service then service:StartTicking(rate) else 0
end

function Backend.stopTicking(): number
	if raw then
		return raw.stopTicking()
	end
	local service = broadcast()
	return if service then service:StopTicking() else 0
end

function Backend.fireBurst(n: number): (number, number)
	if raw then
		return raw.fireBurst(n)
	end
	local service = broadcast()
	if not service then
		return 1, 0
	end
	return service:FireBurst(n)
end

function Backend.countFor(player: Player): number?
	if raw then
		return raw.getCount(player)
	end
	local counter: any = Env.services.CounterService
	local getCount: any = counter and counter.GetCount
	if typeof(getCount) == "function" then
		return (getCount :: any)(counter, player)
	end
	return nil
end

function Backend.handlerStats(): { [string]: Instrument.MethodStats }
	if raw then
		local copy = {}
		for name, s in raw.getStats() do
			copy[name] = table.clone(s)
		end
		return copy
	end
	return Instrument.snapshot()
end

function Backend.resetHandlerStats()
	if raw then
		raw.resetStats()
	else
		Instrument.reset()
	end
end

-- 2.0 only: Loren.GetStats() flattened to sorted "path=value" strings (numbers, strings, booleans).
function Backend.lorenStats(): { string }?
	local Loren = Env.Loren
	if not Env.is20 or typeof(Loren) ~= "table" then
		return nil
	end
	local ok, result = pcall(function()
		local getStats: any = Loren.GetStats
		return if typeof(getStats) == "function" then (getStats :: any)() else nil
	end)
	if not ok or typeof(result) ~= "table" then
		return nil
	end
	local lines = {}
	local function walk(value: any, path: string, depth: number)
		if #lines >= 60 then
			return
		end
		local kind = typeof(value)
		if kind == "number" or kind == "string" or kind == "boolean" then
			table.insert(lines, path .. "=" .. tostring(value))
		elseif kind == "table" and depth < 3 then
			for key, child in value do
				walk(child, if path == "" then tostring(key) else path .. "." .. tostring(key), depth + 1)
			end
		end
	end
	walk(result, "", 0)
	table.sort(lines)
	return lines
end

return Backend
