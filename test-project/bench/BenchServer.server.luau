--!strict
--!optimize 2

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Stats = game:GetService("Stats")

local BenchFolder = ReplicatedStorage:WaitForChild("Bench")
local Shared = BenchFolder:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Plan = require(Shared:WaitForChild("Plan"))
local Probe = require(Shared:WaitForChild("Probe"))
local Recv = require(Shared:WaitForChild("Recv"))
local Adapters = Shared:WaitForChild("Adapters")
local ServerBench = ServerStorage:WaitForChild("Bench")
local ServerHarness = ServerBench:WaitForChild("ServerHarness")
local Coordinator = require(ServerHarness:WaitForChild("Coordinator"))
local Report = require(ServerHarness:WaitForChild("Report"))
local Runner = require(ServerBench:WaitForChild("Server"):WaitForChild("Runner"))
local Env = require(ReplicatedStorage:WaitForChild("LorenTest"):WaitForChild("Harness"):WaitForChild("Env"))

local MODULES: { [string]: string } = {
	loren = "Loren",
	blinkblox = "BlinkBlox",
	blink = "Blink",
	bytenet = "ByteNet",
	bridgenet2 = "BridgeNet2",
}
local C2S_EVENTS = { "CInput", "CInputUnreliable" }

local settings = Config.read()
local testConfig = ReplicatedStorage:FindFirstChild("TestConfig")

if settings.Scenario ~= "bench" then
	Report.say("this place only runs Scenario=bench (TestConfig.Scenario is '" .. settings.Scenario .. "')")
	return
end
if settings.problem then
	Report.say("RESULT: INVALID (" .. tostring(settings.problem) .. ")")
	if testConfig then
		testConfig:SetAttribute("LastResult", "INVALID")
	end
	return
end

Coordinator.init()

local runtimes: { [string]: Plan.Runtime } = {}
local adapters: { [string]: Plan.Adapter } = {}
local brackets: { [string]: Runner.Brackets } = {}
local bootErrors: { [string]: string } = {}
local bootMs: { [string]: number } = {}
for _, key in settings.runtimes do
	local runtime: Plan.Runtime = require(Adapters:WaitForChild(MODULES[key])) :: any
	runtimes[key] = runtime
	if key == "bridgenet2" and #Players:GetPlayers() > 0 then
		local why = "players joined before BridgeNet2 loaded (use Test > Clients and Servers)"
		bootErrors[key] = why
		BenchFolder:SetAttribute("Boot_" .. key, why)
		continue
	end
	local window = Probe.window()
	local hb, ps = Probe.bracket(window), Probe.bracket(window)
	local hbd, psd = Probe.bracket(window), Probe.bracket(window)
	Probe.openDeferredA(hbd, RunService.Heartbeat)
	Probe.openDeferredA(psd, RunService.PostSimulation)
	Probe.openA(hb, RunService.Heartbeat)
	Probe.openA(ps, RunService.PostSimulation)
	local started = os.clock()
	local ok, made = pcall(function(): { [string]: Plan.Adapter }
		local list = runtime.setup()
		runtime.ready()
		return list
	end)
	Probe.closeB(hb, RunService.Heartbeat)
	Probe.closeB(ps, RunService.PostSimulation)
	Probe.closeDeferredB(hbd, RunService.Heartbeat)
	Probe.closeDeferredB(psd, RunService.PostSimulation)
	bootMs[key] = (os.clock() - started) * 1000
	brackets[key] = { Heartbeat = hb, PostSimulation = ps, HeartbeatDeferred = hbd, PostSimulationDeferred = psd }
	if ok then
		for lib, adapter in made do
			adapters[lib] = adapter
		end
		BenchFolder:SetAttribute("Boot_" .. key, true)
	else
		bootErrors[key] = tostring(made)
		BenchFolder:SetAttribute("Boot_" .. key, tostring(made))
	end
end

for lib, adapter in adapters do
	for _, event in C2S_EVENTS do
		if adapter.has(event) then
			adapter.connect(event, Recv.listener(lib, event, adapter.swapServerArgs))
		end
	end
end
for key, runtime in runtimes do
	if bootErrors[key] == nil then
		local sizeOf = runtime.sizeOf
		for _, remote in runtime.remotes() do
			Probe.passive((remote :: any).OnServerEvent, function(player: Player, a1: any, a2: any)
				Recv.serverProbe(key, sizeOf, player, a1, a2)
			end)
		end
	end
end
RunService.Heartbeat:Connect(Recv.serverFrame)

local hbStat: string? = nil
for _, name in { "HeartbeatTimeMs", "HeartbeatTime" } do
	local ok, value = pcall(function(): any
		return (Stats :: any)[name]
	end)
	if ok and type(value) == "number" then
		hbStat = name
		break
	end
end

local order = Probe.connectOrder()
local bootParts = {}
for _, key in settings.runtimes do
	table.insert(
		bootParts,
		string.format(
			"%s %s (%.0f ms)",
			key,
			if bootErrors[key] then "FAILED: " .. bootErrors[key] else "ok",
			bootMs[key] or 0
		)
	)
end
Report.say("bench server booted: " .. table.concat(bootParts, ", ") .. " | connect order " .. order)
if order == "mixed" then
	Report.say("connect order is mixed: bracket metrics (recv, flush) are INVALID in this session")
end

BenchFolder:SetAttribute("Ready", true)

if Env.isRunMode then
	Report.say("the bench needs clients: use Test > Clients and Servers (or Play)")
	return
end
local clients = Env.config().Clients
local players
if clients > 0 then
	Report.say(string.format("waiting for %d client(s) (TestConfig.Clients)", clients))
	players = Coordinator.waitForClients(clients, 180, 15)
else
	Report.say("waiting for clients (auto: starts 3 s after the last one joins)")
	players = Coordinator.waitForClients(math.huge, 180, 3)
end
if #players == 0 then
	Report.say("RESULT: INVALID (no client said hello)")
	if testConfig then
		testConfig:SetAttribute("LastResult", "INVALID")
	end
	return
end
Report.say(string.format("%d client(s) ready, starting the bench", #players))

Runner.run({
	settings = settings,
	players = players,
	clientsChanged = nil,
	runtimes = runtimes,
	adapters = adapters,
	brackets = brackets,
	bootErrors = bootErrors,
	serverOrder = order,
	hbStat = hbStat,
	loren = if runtimes.loren and bootErrors.loren == nil then (runtimes.loren :: any).loren() else nil,
})
