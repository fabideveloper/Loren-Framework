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
local LT = ReplicatedStorage:WaitForChild("LorenTest")
local Harness = LT:WaitForChild("Harness")
local Env = require(Harness:WaitForChild("Env"))
local Metrics = require(Harness:WaitForChild("Metrics"))
local LorenTest = require(LT:WaitForChild("LorenTest"))
local Bots = LT:WaitForChild("Bots")
local CallSpammer = require(Bots:WaitForChild("CallSpammer"))
local SignalWatcher = require(Bots:WaitForChild("SignalWatcher"))
local Burst = require(Bots:WaitForChild("Burst"))
local Exploiter = require(Bots:WaitForChild("Exploiter"))
local Soak = require(Bots:WaitForChild("Soak"))

local control = LT:WaitForChild("TestControl") :: RemoteEvent
local report = LT:WaitForChild("TestReport") :: RemoteEvent

local function say(text: string)
	print("(LORENঌ - TEST) " .. text)
end

-- [[ Boot ]]

local bootStarted = os.clock()
if Env.isRaw then
	local ok, result = pcall(function()
		return require(LT:WaitForChild("RawClient")).connect()
	end)
	Env.boot.ok = ok
	if ok then
		Env.proxies = result
	else
		Env.boot.error = tostring(result)
	end
else
	local ok, err = pcall(function()
		local Loren: any = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loren")) :: any
		Env.adopt(Loren)
		local controllers = LT:WaitForChild("Controllers")
		Loren.AddControllers(controllers)
		-- 2.0-only fixtures (fixtures/v2, written by the integration phase), registered only on 2.x.
		local v2 = LT:FindFirstChild("V2Controllers")
		if v2 and Env.is20 then
			Loren.AddControllers(v2)
		end
		local resolved, value = Loren:SetOnFire():await()
		Env.boot.value = value
		if not resolved then
			error("SetOnFire rejected: " .. Env.reason(value), 0)
		end
		local controller = require(controllers:WaitForChild("TestController"))
		Env.controller = controller
		local deps: any = controller.Dependencies -- a name -> proxy map after boot
		for _, name in Env.SERVICE_NAMES do
			Env.proxies[name] = deps[name]
		end
	end)
	Env.boot.ok = ok
	if not ok then
		Env.boot.error = tostring(err)
	end
end
Env.boot.ms = (os.clock() - bootStarted) * 1000
say(
	string.format(
		"client %s booted %s: %s in %.0f ms",
		player.Name,
		Env.runtimeLabel(),
		if Env.boot.ok then "ok" else "FAILED (" .. tostring(Env.boot.error) .. ")",
		Env.boot.ms
	)
)
if Env.note then
	say("note: " .. Env.note)
end

-- [[ check ]]

local function runCheck(message: any)
	local specsFolder = LT:WaitForChild("Specs")
	local specs = LorenTest.collect(specsFolder:WaitForChild("StudioClient"), "studio/client")
	local v2 = specsFolder:FindFirstChild("V2Client")
	if Env.is20 and v2 then
		for _, spec in LorenTest.collect(v2, "v2/client") do
			table.insert(specs, spec)
		end
	end
	local results = LorenTest.run(specs, { label = "client " .. player.Name .. " (" .. Env.runtimeLabel() .. ")" })
	say(LorenTest.report(results))
	for _, failure in results.failures do
		if #failure.message > 1000 then
			failure.message = string.sub(failure.message, 1, 1000) .. " ..."
		end
	end
	report:FireServer({ kind = "check", runId = message.runId, results = results })
end

-- [[ load phases ]]

type Active = {
	runId: number,
	role: string,
	calls: any,
	ticks: any,
	changed: any,
	exploit: any,
	frames: Metrics.Reservoir,
	send: { number },
	recv: { number },
	connections: { RBXScriptConnection },
	stopped: boolean,
}

local active: Active? = nil

local function startSampling(a: Active)
	table.insert(
		a.connections,
		RunService.Heartbeat:Connect(function(dt: number)
			a.frames:add(dt * 1000)
		end)
	)
	task.spawn(function()
		while not a.stopped do
			task.wait(0.5)
			table.insert(a.send, Stats.DataSendKbps)
			table.insert(a.recv, Stats.DataReceiveKbps)
		end
	end)
end

local function finishPhase(a: Active, ticks: any)
	if a.stopped then
		return
	end
	a.stopped = true
	if a.calls then
		a.calls:stop()
	end
	if a.exploit then
		a.exploit:stop()
	end
	-- Drain: 1.5.1 silently dropped calls only settle at their 10 s Timeout.
	if a.calls then
		a.calls:waitIdle(12)
	end
	if a.exploit then
		a.exploit:waitIdle(3)
	end
	local first = if typeof(ticks) == "table" and typeof(ticks.first) == "number" then ticks.first else nil
	local last = if typeof(ticks) == "table" and typeof(ticks.last) == "number" then ticks.last else nil
	if a.ticks and first and last and last >= first then
		Env.waitUntil(function()
			return a.ticks.maxSeen >= last
		end, 3)
	end
	task.wait(0.25) -- trailing Changed signals
	for _, connection in a.connections do
		connection:Disconnect()
	end
	if a.ticks then
		a.ticks:stop()
	end
	if a.changed then
		a.changed:stop()
	end

	local stats: { [string]: any } = { role = a.role }
	if a.calls then
		stats.calls = a.calls:summary()
	end
	if a.ticks then
		stats.ticks = a.ticks:summarize(first, last)
	end
	if a.changed then
		stats.changed = a.changed:summarize()
	end
	if a.exploit then
		stats.exploit = a.exploit:summary()
	end
	stats.client = {
		frameMs = Metrics.summarize(a.frames.values),
		sendKbps = Metrics.summarize(a.send).mean,
		recvKbps = Metrics.summarize(a.recv).mean,
		gcKb = gcinfo(),
	}
	report:FireServer({ kind = "result", runId = a.runId, stats = stats })
	if stats.calls then
		local c = stats.calls
		say(
			string.format(
				"%s done: %d calls, %d ok, %d timeouts, %d errors, rtt p50 %s ms p99 %s ms",
				a.role,
				c.sent,
				c.ok,
				c.timeouts,
				c.errors,
				Metrics.num(c.rttMs.p50),
				Metrics.num(c.rttMs.p99)
			)
		)
	elseif stats.exploit then
		say(string.format("exploit done: %d fires, %d send errors", stats.exploit.totalFired, stats.exploit.sendErrors))
	end
end

local function startPhase(message: any)
	if active and not active.stopped then
		task.spawn(finishPhase, active, nil)
	end
	local params = message.params or {}
	local role = tostring(message.role)
	local proxies = Env.proxies
	local a: Active = {
		runId = message.runId,
		role = role,
		calls = nil,
		ticks = nil,
		changed = nil,
		exploit = nil,
		frames = Metrics.Reservoir.new(50000),
		send = {},
		recv = {},
		connections = {},
		stopped = false,
	}
	active = a
	local ok, err = pcall(function()
		if not Env.boot.ok then
			error("client boot failed: " .. tostring(Env.boot.error), 0)
		end
		local rate = params.rate or 30
		local payloadSize = params.payloadSize or 64
		if role == "stress" or role == "soak" or role == "compare" or role == "burst" then
			a.ticks = SignalWatcher.new(proxies.BroadcastService.Signals.Tick, "Tick")
		end
		if role == "stress" or role == "soak" then
			a.changed = SignalWatcher.new(proxies.CounterService.Signals.Changed, "Changed")
		end
		if role == "stress" then
			a.calls = CallSpammer.new(proxies, { rate = rate, payloadSize = payloadSize, mix = "mixed" })
		elseif role == "compare" then
			a.calls = CallSpammer.new(proxies, { rate = rate, payloadSize = payloadSize, mix = "echo" })
		elseif role == "soak" then
			a.calls = Soak.new(proxies, { rate = rate, payloadSize = payloadSize })
		elseif role == "burst" then
			a.calls = Burst.new(
				proxies,
				{ size = params.burstSize or rate * 2, interval = params.interval or 2, payloadSize = payloadSize }
			)
		elseif role == "exploit" then
			a.exploit = Exploiter.new({ proxies = proxies })
		else
			error("unknown role " .. role, 0)
		end
		-- Watchers first, so the first Tick of the phase is not missed.
		if a.ticks then
			a.ticks:start()
		end
		if a.changed then
			a.changed:start()
		end
		startSampling(a)
		if a.calls then
			a.calls:start()
		end
		if a.exploit then
			a.exploit:start()
		end
	end)
	if not ok then
		a.stopped = true
		for _, connection in a.connections do
			connection:Disconnect()
		end
		say("could not start " .. role .. ": " .. tostring(err))
		report:FireServer({ kind = "started", runId = message.runId })
		report:FireServer({ kind = "result", runId = message.runId, stats = { role = role, error = tostring(err) } })
		return
	end
	report:FireServer({ kind = "started", runId = message.runId })
	say(string.format("%s started (%s)", role, message.phase))
	-- Safety net: stop by itself if the server never sends "stop".
	task.delay((params.duration or 20) + 120, function()
		if active == a and not a.stopped then
			finishPhase(a, nil)
		end
	end)
end

local function handle(message: any)
	local cmd = message.cmd
	if cmd == "check" then
		runCheck(message)
	elseif cmd == "start" then
		startPhase(message)
	elseif cmd == "stop" then
		local a = active
		if a and a.runId == message.runId then
			finishPhase(a, message.ticks)
		end
	elseif cmd == "done" then
		say("all scenarios done: " .. tostring(message.result) .. " (the REPORT is in the server Output)")
	end
end

control.OnClientEvent:Connect(function(message)
	if typeof(message) ~= "table" then
		return
	end
	task.spawn(function()
		local ok, err = pcall(handle :: any, message)
		if not ok then
			say("error handling " .. tostring(message.cmd) .. ": " .. tostring(err))
			report:FireServer({
				kind = "log",
				text = "error handling " .. tostring(message.cmd) .. ": " .. tostring(err),
			})
		end
	end)
end)

report:FireServer({
	kind = "hello",
	runtime = Env.runtime,
	label = Env.runtimeLabel(),
	bootOk = Env.boot.ok,
	bootError = Env.boot.error,
	bootMs = Env.boot.ms,
})
