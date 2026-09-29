--!strict
--!optimize 2

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local player = Players.LocalPlayer
local BenchFolder = ReplicatedStorage:WaitForChild("Bench")
local Shared = BenchFolder:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Payloads = require(Shared:WaitForChild("Payloads"))
local Plan = require(Shared:WaitForChild("Plan"))
local Probe = require(Shared:WaitForChild("Probe"))
local Recv = require(Shared:WaitForChild("Recv"))
local Adapters = Shared:WaitForChild("Adapters")

local MODULES: { [string]: string } = {
	loren = "Loren",
	blinkblox = "BlinkBlox",
	blink = "Blink",
	bytenet = "ByteNet",
	bridgenet2 = "BridgeNet2",
}
local S2C_EVENTS = { "SBool", "SEntity", "SEntities", "SBoolArray", "SPose", "SEntityUnreliable" }
local DRAIN_QUIET = 2
local DRAIN_CAP = 30
local SETTLE_CAP = 120
local TICK = 1 / 60

local function say(text: string)
	print("(LORENঌ - TEST) " .. text)
end

local function num(v: any): number
	return if type(v) == "number" and v == v then v else 0
end

local function mean(list: { number }): number
	if #list == 0 then
		return 0
	end
	local total = 0
	for _, v in list do
		total += v
	end
	return total / #list
end

local settings = Config.read()
if settings.Scenario ~= "bench" or settings.problem then
	say("bench client stays idle: " .. (settings.problem or "TestConfig.Scenario is not bench"))
	return
end

while BenchFolder:GetAttribute("Ready") ~= true do
	BenchFolder:GetAttributeChangedSignal("Ready"):Wait()
end
local LT = ReplicatedStorage:WaitForChild("LorenTest")
local control = LT:WaitForChild("TestControl") :: RemoteEvent
local report = LT:WaitForChild("TestReport") :: RemoteEvent
local order = Probe.connectOrder()

type ClientRuntime = {
	key: string,
	runtime: Plan.Runtime,
	window: Probe.Window,
	counter: Probe.Counter,
	remote: { Probe.Bracket },
	Heartbeat: Probe.Bracket,
	PostSimulation: Probe.Bracket,
	HeartbeatDeferred: Probe.Bracket,
	PostSimulationDeferred: Probe.Bracket,
}

local runtimes: { [string]: ClientRuntime } = {}
local adapters: { [string]: Plan.Adapter } = {}
local boot: { [string]: any } = {}
local bootStarted = os.clock()
for _, key in settings.runtimes do
	local serverBoot = BenchFolder:GetAttribute("Boot_" .. key)
	if serverBoot ~= true then
		boot[key] = "server: " .. tostring(serverBoot)
		continue
	end
	local runtime: Plan.Runtime = require(Adapters:WaitForChild(MODULES[key])) :: any
	local window = Probe.window()
	local cr: ClientRuntime = {
		key = key,
		runtime = runtime,
		window = window,
		counter = Probe.counter(nil),
		remote = {},
		Heartbeat = Probe.bracket(window),
		PostSimulation = Probe.bracket(window),
		HeartbeatDeferred = Probe.bracket(window),
		PostSimulationDeferred = Probe.bracket(window),
	}
	local remotes: { Instance } = {}
	Probe.openDeferredA(cr.HeartbeatDeferred, RunService.Heartbeat)
	Probe.openDeferredA(cr.PostSimulationDeferred, RunService.PostSimulation)
	Probe.openA(cr.Heartbeat, RunService.Heartbeat)
	Probe.openA(cr.PostSimulation, RunService.PostSimulation)
	local ok, err = pcall(function()
		remotes = runtime.waitRemotes()
		for _, remote in remotes do
			local br = Probe.bracket(window)
			Probe.openA(br, (remote :: any).OnClientEvent, cr.counter)
			table.insert(cr.remote, br)
		end
		local made = runtime.setup()
		for lib, adapter in made do
			adapters[lib] = adapter
			for _, event in S2C_EVENTS do
				if adapter.has(event) then
					adapter.connect(event, Recv.listener(lib, event))
				end
			end
		end
		runtime.ready()
	end)
	for i, br in cr.remote do
		Probe.closeB(br, (remotes[i] :: any).OnClientEvent)
	end
	Probe.closeB(cr.Heartbeat, RunService.Heartbeat)
	Probe.closeB(cr.PostSimulation, RunService.PostSimulation)
	Probe.closeDeferredB(cr.HeartbeatDeferred, RunService.Heartbeat)
	Probe.closeDeferredB(cr.PostSimulationDeferred, RunService.PostSimulation)
	cr.counter.sizeOf = runtime.sizeOf
	if ok then
		runtimes[key] = cr
		boot[key] = true
	else
		boot[key] = tostring(err)
		say(string.format("client %s: %s failed to boot: %s", player.Name, key, tostring(err)))
	end
end
local bootMs = (os.clock() - bootStarted) * 1000

local lorenRuntime = runtimes.loren
local Loren: any = if lorenRuntime then (lorenRuntime.runtime :: any).loren() else nil

local function lorenStats(): any
	if Loren == nil then
		return nil
	end
	local ok, stats = pcall(Loren.GetStats)
	return if ok then stats else nil
end

local function delta(after: any, before: any, key: string): number
	if type(after) ~= "table" or type(before) ~= "table" then
		return 0
	end
	return num(after[key]) - num(before[key])
end

type Sample = { t: number, send: number }

type Active = {
	runId: number,
	lib: string,
	def: Payloads.Def,
	cr: ClientRuntime,
	stream: Recv.Stream?,
	step: Plan.ClientStep?,
	seenN: number,
	lastAt: number?,
	frames: { number },
	samples: { Sample },
	lorenBefore: any,
}

local active: Active? = nil
local idleSend = 0
local idleFrameWork: { [string]: number } = {}

RunService.Heartbeat:Connect(function()
	local a = active
	if a == nil then
		return
	end
	local now = workspace:GetServerTimeNow()
	table.insert(a.frames, now)
	local st = a.stream
	if st and st.n ~= a.seenN then
		a.seenN = st.n
		a.lastAt = now
	end
end)

task.spawn(function()
	while true do
		task.wait(0.5)
		local a = active
		if a then
			table.insert(a.samples, { t = workspace:GetServerTimeNow(), send = Stats.DataSendKbps })
		end
	end
end)

local function framesPerSecond(a: Active, from: number, to: number): number
	if to <= from then
		return 0
	end
	local n = 0
	for _, t in a.frames do
		if t >= from and t <= to then
			n += 1
		end
	end
	return n / (to - from)
end

local function sendRate(a: Active, from: number, to: number): number
	local list = {}
	for _, s in a.samples do
		if s.t >= from and s.t <= to then
			table.insert(list, s.send)
		end
	end
	return mean(list)
end

local function frameWork(cr: ClientRuntime): number
	return cr.Heartbeat.total + cr.PostSimulation.total + cr.HeartbeatDeferred.total + cr.PostSimulationDeferred.total
end

local function remoteWork(cr: ClientRuntime): number
	local total = 0
	for _, br in cr.remote do
		total += br.total
	end
	return total
end

local function resetBrackets(cr: ClientRuntime)
	for _, br in cr.remote do
		Probe.reset(br)
	end
	Probe.reset(cr.Heartbeat)
	Probe.reset(cr.PostSimulation)
	Probe.reset(cr.HeartbeatDeferred)
	Probe.reset(cr.PostSimulationDeferred)
end

local function onIdle(message: any)
	local seconds = num(message.seconds)
	for _, cr in runtimes do
		resetBrackets(cr)
	end
	local frames = 0
	local connection = RunService.Heartbeat:Connect(function()
		frames += 1
	end)
	local send = {}
	local started = os.clock()
	while os.clock() - started < seconds do
		task.wait(0.5)
		table.insert(send, Stats.DataSendKbps)
	end
	connection:Disconnect()
	local libs = {}
	for key, cr in runtimes do
		libs[key] = (frameWork(cr) + remoteWork(cr)) * 1000 / math.max(frames, 1)
		idleFrameWork[key] = frameWork(cr) / math.max(frames, 1)
	end
	idleSend = mean(send)
	report:FireServer({
		kind = "idled",
		runId = message.runId,
		fps = frames / math.max(os.clock() - started, 0.001),
		sendKbps = idleSend,
		libs = libs,
	})
end

local function onArm(message: any)
	local lib = tostring(message.lib)
	local def = Payloads.def(tostring(message.payload))
	local cr = runtimes[Config.RUNTIME_OF[lib] or ""]
	local adapter = adapters[lib]
	if cr == nil or adapter == nil then
		report:FireServer({ kind = "armed", runId = message.runId, ok = false, error = lib .. " is not booted here" })
		return
	end
	Payloads.pool(def)
	resetBrackets(cr)
	Probe.resetCounter(cr.counter)
	local a: Active = {
		runId = message.runId,
		lib = lib,
		def = def,
		cr = cr,
		stream = nil,
		step = nil,
		seenN = 0,
		lastAt = nil,
		frames = {},
		samples = {},
		lorenBefore = if cr.key == "loren" then lorenStats() else nil,
	}
	if def.dir == "s2c" then
		a.stream = Recv.armClient(lib, def, cr.window)
	else
		a.step = Plan.clientStep(adapter, def)
		if a.step == nil then
			report:FireServer({ kind = "armed", runId = message.runId, ok = false, error = "no " .. def.event })
			return
		end
	end
	active = a
	report:FireServer({ kind = "armed", runId = message.runId, ok = true })
end

local function onDrain(message: any)
	local a = active
	if a == nil or a.runId ~= message.runId or a.stream == nil then
		report:FireServer({ kind = "result", runId = message.runId, ok = false, error = "not armed for this run" })
		return
	end
	local st = a.stream :: Recv.Stream
	local cr, def = a.cr, a.def
	local expected = num(message.expected)
	local capped = false
	local started = os.clock()
	local lastN, lastChange = st.n, os.clock()
	while st.n < expected do
		local now = os.clock()
		if now - lastChange >= DRAIN_QUIET then
			break
		elseif now - started >= DRAIN_CAP then
			capped = true
			break
		end
		task.wait()
		if st.n ~= lastN then
			lastN, lastChange = st.n, os.clock()
		end
	end

	local startServer, stopServer = num(message.startServer), num(message.stopServer)
	local recvS = remoteWork(cr) + frameWork(cr)
	local bytes, approx = Probe.bytes(cr.counter)
	local check, why = Payloads.check(def, st.cap)
	local after = if cr.key == "loren" then lorenStats() else nil
	local result = {
		kind = "result",
		runId = message.runId,
		ok = true,
		n = st.n,
		trues = st.trues,
		reord = st.reord,
		bad = st.bad,
		brOk = st.brOk,
		recvS = recvS,
		calls = cr.counter.calls,
		bytes = bytes,
		bytesApprox = approx,
		fps = framesPerSecond(a, startServer, stopServer),
		drainS = if a.lastAt then math.max(0, (a.lastAt :: number) - stopServer) else nil,
		capped = capped,
		check = check,
		why = why,
		loren = if after
			then {
				EventsLost = delta(after, a.lorenBefore, "EventsLost"),
				SignalsDropped = delta(after, a.lorenBefore, "SignalsDropped"),
			}
			else nil,
	}
	if capped then
		local quietSince, settleEnd = os.clock(), os.clock() + SETTLE_CAP
		local last = st.n
		while os.clock() - quietSince < DRAIN_QUIET and os.clock() < settleEnd do
			task.wait(0.1)
			if st.n ~= last then
				last, quietSince = st.n, os.clock()
			end
		end
	end
	Recv.disarm(a.lib, def.event)
	active = nil
	report:FireServer(result)
end

local function onDisarm(message: any)
	local a = active
	if a == nil or a.runId ~= message.runId then
		return
	end
	if a.stream ~= nil then
		Recv.disarm(a.lib, a.def.event)
	end
	active = nil
end

local function onFire(message: any)
	local a = active
	if a == nil or a.runId ~= message.runId or a.step == nil then
		report:FireServer({ kind = "sent", runId = message.runId, ok = false, error = "not armed for this run" })
		return
	end
	local step = a.step :: Plan.ClientStep
	local cr = a.cr
	local runtime = cr.runtime
	local flush = runtime.flush
	local seconds = num(message.seconds)
	resetBrackets(cr)
	table.clear(a.frames)
	table.clear(a.samples)
	local ticks, allFrames, fired, sendS, flushS, workS = 0, 0, 0, 0, 0, 0
	local acc = 0
	local finished = false
	local failure: string? = nil
	local startServer = workspace:GetServerTimeNow()
	local started = os.clock()
	local durS = 0
	local connection: RBXScriptConnection
	connection = RunService.PreSimulation:Connect(function(dt: number)
		if finished then
			return
		end
		if os.clock() - started >= seconds then
			finished = true
			durS = os.clock() - started
			workS = frameWork(cr)
			connection:Disconnect()
			return
		end
		allFrames += 1
		acc += dt
		if acc < TICK * 0.9 then
			return
		end
		acc = math.min(acc - TICK, TICK)
		local ok, n, s = pcall(step, ticks)
		local flushed, err = true, nil
		if ok and flush then
			local t0 = os.clock()
			flushed, err = pcall(flush)
			flushS += os.clock() - t0
		end
		if not ok or not flushed then
			failure = "fire failed: " .. tostring(if ok then err else n)
			finished = true
			durS = os.clock() - started
			workS = frameWork(cr)
			connection:Disconnect()
			return
		end
		fired += n
		sendS += s
		ticks += 1
	end)
	while not finished do
		task.wait()
	end
	local adjS = math.min(workS, math.max(0, allFrames - ticks) * (idleFrameWork[cr.key] or 0))
	flushS += workS - adjS
	local stopServer = workspace:GetServerTimeNow()
	local after = if cr.key == "loren" then lorenStats() else nil
	active = nil
	report:FireServer({
		kind = "sent",
		runId = message.runId,
		ok = failure == nil,
		error = failure,
		frames = ticks,
		allFrames = allFrames,
		durS = durS,
		fired = fired,
		sendS = sendS,
		flushS = flushS,
		adjS = adjS,
		fps = framesPerSecond(a, startServer, stopServer),
		sendKbps = sendRate(a, startServer, stopServer) - idleSend,
		stopServer = stopServer,
		loren = if after
			then {
				FramesOut = delta(after, a.lorenBefore, "FramesOut"),
				EventsLost = delta(after, a.lorenBefore, "EventsLost"),
				SignalsDropped = delta(after, a.lorenBefore, "SignalsDropped"),
			}
			else nil,
	})
end

local function handle(message: any)
	local cmd = message.cmd
	if cmd == "idle" then
		onIdle(message)
	elseif cmd == "arm" then
		onArm(message)
	elseif cmd == "drain" then
		onDrain(message)
	elseif cmd == "fire" then
		onFire(message)
	elseif cmd == "disarm" then
		onDisarm(message)
	elseif cmd == "done" then
		say("bench done: " .. tostring(message.result) .. " (the REPORT is in the server Output)")
	end
end

control.OnClientEvent:Connect(function(message: any)
	if typeof(message) ~= "table" then
		return
	end
	task.spawn(function()
		local ok, err = pcall(handle :: any, message)
		if not ok then
			local text = "error handling " .. tostring(message.cmd) .. ": " .. tostring(err)
			say(text)
			report:FireServer({ kind = "log", text = text })
		end
	end)
end)

local failed = {}
for key, value in boot do
	if value ~= true then
		table.insert(failed, key .. ": " .. tostring(value))
	end
end
report:FireServer({ kind = "benchinfo", runId = 0, boot = boot, order = order })
report:FireServer({
	kind = "hello",
	runtime = "bench",
	label = "LorenBench (" .. table.concat(settings.runtimes, ", ") .. "), connect order " .. order,
	bootOk = #failed == 0,
	bootError = if #failed > 0 then table.concat(failed, "; ") else nil,
	bootMs = bootMs,
})
say(string.format("client %s booted the bench in %.0f ms (connect order %s)", player.Name, bootMs, order))
