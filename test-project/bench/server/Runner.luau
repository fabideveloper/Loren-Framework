--!strict
--!optimize 2

-- Server orchestration: idle baselines, warmup, rotated passes, per-run metrics, medians and the report.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Stats = game:GetService("Stats")

local Shared = ReplicatedStorage:WaitForChild("Bench"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Payloads = require(Shared:WaitForChild("Payloads"))
local Plan = require(Shared:WaitForChild("Plan"))
local Probe = require(Shared:WaitForChild("Probe"))
local Recv = require(Shared:WaitForChild("Recv"))
local ServerHarness = ServerStorage:WaitForChild("Bench"):WaitForChild("ServerHarness")
local Coordinator = require(ServerHarness:WaitForChild("Coordinator"))
local Report = require(ServerHarness:WaitForChild("Report"))
local Sampler = require(ServerHarness:WaitForChild("Sampler"))
local Table = require(script.Parent:WaitForChild("Table"))

local Runner = {}

export type Brackets = { Heartbeat: Probe.Bracket, PostSimulation: Probe.Bracket }

export type Context = {
	settings: Config.Settings,
	-- The clients the bench started with; every run uses exactly these.
	players: { Player },
	clientsChanged: string?,
	runtimes: { [string]: Plan.Runtime },
	adapters: { [string]: Plan.Adapter },
	brackets: { [string]: Brackets },
	bootErrors: { [string]: string },
	serverOrder: string,
	hbStat: string?,
	loren: any,
}

type Idle = {
	sendKbps: number,
	recvKbps: number,
	p50: number,
	p95: number,
	libs: { [string]: number },
	clients: { [Player]: any },
}

local DRAIN_QUIET = 2
local DRAIN_CAP = 30
local SETTLE_CAP = 120
-- Clients fire C->S on a 60 Hz tick; above this FPS the run is INVALID anyway.
local MAX_CLIENT_FPS = 62

local function broadcast(players: { Player }, message: { [string]: any })
	for _, player in players do
		Coordinator.send(player, message)
	end
end

local function num(v: any): number
	return if type(v) == "number" and v == v then v else 0
end

-- A number field of a client report table (0 when missing).
local function field(t: any, key: string): number
	if type(t) ~= "table" then
		return 0
	end
	local value: any = (t :: any)[key]
	return num(value)
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

local function median(list: { number }): number?
	if #list == 0 then
		return nil
	end
	local sorted = table.clone(list)
	table.sort(sorted)
	local n = #sorted
	if n % 2 == 1 then
		return sorted[(n + 1) // 2]
	end
	return (sorted[n // 2] + sorted[n // 2 + 1]) / 2
end

local function lorenStats(ctx: Context): any
	local loren = ctx.loren
	if loren == nil then
		return nil
	end
	local ok, stats = pcall(loren.GetStats)
	return if ok then stats else nil
end

local function statDelta(after: any, before: any, key: string): number
	if type(after) ~= "table" or type(before) ~= "table" then
		return 0
	end
	return num(after[key]) - num(before[key])
end

local function isLoren(lib: string): boolean
	return Config.RUNTIME_OF[lib] == "loren"
end

-- Loren's per-run counters that must stay at 0; returns a description or nil.
local function lorenIssues(server: { [string]: number }, clients: { [string]: number }): string?
	local parts = {}
	for key, value in server do
		if value ~= 0 then
			table.insert(parts, string.format("server %s %+d", key, value))
		end
	end
	for key, value in clients do
		if value ~= 0 then
			table.insert(parts, string.format("clients %s %+d", key, value))
		end
	end
	table.sort(parts)
	return if #parts > 0 then table.concat(parts, ", ") else nil
end

local function readHbStat(name: string?): number?
	if name == nil then
		return nil
	end
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	return if ok and type(value) == "number" then value else nil
end

-- Server Heartbeat dt p50/p95 in ms from a Sampler summary.
local function heartbeat(summary: Sampler.Summary): (number, number)
	return summary.frameMs.p50, summary.frameMs.p95
end

-- A library's own per-frame work: everything it connected to Heartbeat and PostSimulation (bracketed).
local function frameWork(br: Brackets?): number
	if br == nil then
		return 0
	end
	return br.Heartbeat.total + br.PostSimulation.total
end

local function resetWork(br: Brackets?)
	if br then
		Probe.reset(br.Heartbeat)
		Probe.reset(br.PostSimulation)
	end
end

-- Nil while the game holds exactly the clients the bench started with, otherwise what changed.
local function clientSetChanged(ctx: Context): string?
	for _, player in ctx.players do
		if player.Parent ~= Players then
			return player.Name .. " left"
		end
	end
	local count = #Players:GetPlayers()
	if count ~= #ctx.players then
		return string.format("%d players in the game, the bench started with %d", count, #ctx.players)
	end
	return nil
end

local function checkClients(ctx: Context): string?
	local changed = clientSetChanged(ctx)
	if changed then
		ctx.clientsChanged = ctx.clientsChanged or changed
		return "client set changed: " .. changed
	end
	return nil
end

-- Idle baseline; also each library's idle per-frame work in ms (server here, clients in their replies).
local function idlePhase(ctx: Context, seconds: number): Idle
	local players = ctx.players
	local runId = Coordinator.nextRunId()
	broadcast(players, { cmd = "idle", runId = runId, seconds = seconds })
	for _, br in ctx.brackets do
		resetWork(br)
	end
	local frames = 0
	local counter = RunService.Heartbeat:Connect(function()
		frames += 1
	end)
	local sampler = Sampler.start()
	task.wait(seconds)
	local summary = sampler:stop()
	counter:Disconnect()
	local libs: { [string]: number } = {}
	for key, br in ctx.brackets do
		if ctx.bootErrors[key] == nil then
			libs[key] = frameWork(br) * 1000 / math.max(frames, 1)
		end
	end
	local replies = Coordinator.collect("idled", runId, players, seconds + 10)
	local p50, p95 = heartbeat(summary)
	return {
		sendKbps = summary.sendKbps.mean,
		recvKbps = summary.recvKbps.mean,
		p50 = p50,
		p95 = p95,
		libs = libs,
		clients = replies,
	}
end

local function emptyRun(): Table.Run
	return {
		frames = 0,
		sendMs = 0,
		flushMs = 0,
		totalMs = 0,
		recvMs = nil,
		recvApprox = false,
		recvCoverage = nil,
		txCalls = nil,
		txDerived = false,
		rxCalls = 0,
		bytes = 0,
		bytesApprox = false,
		kbps = 0,
		sendKbps = 0,
		cfps = 0,
		cfpsMax = 0,
		shbP50 = 0,
		shbP95 = 0,
		hbStat = nil,
		delivered = 0,
		expected = 0,
		lost = 0,
		reord = 0,
		bad = 0,
		drainS = nil,
		capped = false,
		ok = true,
		why = nil,
		bracket = nil,
		lorenIssues = nil,
		warnings = 0,
		errors = 0,
	}
end

-- Arms every client; on any failure the others are disarmed again, so none keeps a stale run.
local function armAll(players: { Player }, message: { [string]: any }): string?
	broadcast(players, message)
	local replies = Coordinator.collect("armed", message.runId, players, 30)
	local problem: string? = nil
	for _, player in players do
		local reply = replies[player]
		if reply == nil then
			problem = player.Name .. " did not arm"
		elseif reply.ok ~= true then
			problem = player.Name .. ": " .. tostring(reply.error)
		end
		if problem then
			break
		end
	end
	if problem then
		broadcast(players, { cmd = "disarm", runId = message.runId })
	end
	return problem
end

-- One S->C run: the server fires from PreSimulation, each client counts, times and checks what it got.
local function runS2C(ctx: Context, lib: string, def: Payloads.Def, seconds: number, idle: Idle): (Table.Run?, string?)
	local changed = checkClients(ctx)
	if changed then
		return nil, changed
	end
	local players = ctx.players
	local runtime = ctx.runtimes[Config.RUNTIME_OF[lib]]
	local step = Plan.serverStep(ctx.adapters[lib], def)
	if step == nil then
		return nil, "no such event"
	end
	local fireStep: Plan.ServerStep = step
	local runId = Coordinator.nextRunId()
	local problem = armAll(players, { cmd = "arm", runId = runId, lib = lib, payload = def.name, dir = "s2c" })
	if problem then
		return nil, problem
	end

	-- flush = the explicit flush call plus the library's own Heartbeat/PostSimulation work.
	local brackets = ctx.brackets[runtime.key]
	resetWork(brackets)
	local flush = runtime.flush
	local before = lorenStats(ctx)
	local sampler = Sampler.start()
	local frames, sendS, flushS, hbTotal, hbN = 0, 0, 0, 0, 0
	local finished = false
	local failure: string? = nil
	local startServer = workspace:GetServerTimeNow()
	local started = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.PreSimulation:Connect(function()
		if finished then
			return
		end
		if os.clock() - started >= seconds then
			finished = true
			connection:Disconnect()
			flushS += frameWork(brackets)
			return
		end
		local ok, result, s = pcall(fireStep, players, frames)
		local flushed, err = true, nil
		if ok and flush then
			local t0 = os.clock()
			flushed, err = pcall(flush)
			flushS += os.clock() - t0
		end
		if not ok or not flushed then
			failure = "fire failed: " .. tostring(if ok then err else result)
			finished = true
			connection:Disconnect()
			return
		end
		sendS += s
		frames += 1
		local hb = readHbStat(ctx.hbStat)
		if hb then
			hbTotal += hb
			hbN += 1
		end
	end)
	while not finished do
		task.wait()
	end
	local stopServer = workspace:GetServerTimeNow()
	local summary = sampler:stop()
	local after = lorenStats(ctx)

	local perPlayer = def.perFrame * frames
	local trues = Payloads.expectedTrues(def, frames)
	broadcast(players, {
		cmd = "drain",
		runId = runId,
		expected = perPlayer,
		startServer = startServer,
		stopServer = stopServer,
	})
	local results = Coordinator.collect("result", runId, players, DRAIN_CAP + SETTLE_CAP + 30)
	if failure then
		return nil, failure
	end

	local run = emptyRun()
	run.frames = frames
	local f = math.max(frames, 1)
	run.sendMs = sendS * 1000 / f
	run.flushMs = flushS * 1000 / f
	run.totalMs = run.sendMs + run.flushMs
	run.shbP50, run.shbP95 = heartbeat(summary)
	run.hbStat = if hbN > 0 then hbTotal / hbN else nil
	run.sendKbps = summary.sendKbps.mean - idle.sendKbps
	run.warnings, run.errors = summary.logs.warnings, summary.logs.errors

	local recv, calls, bytes, kbps, fps = {}, {}, {}, {}, {}
	local brOk, brN = 0, 0
	local clientLoren = { EventsLost = 0, SignalsDropped = 0 }
	for _, player in players do
		local r = results[player]
		run.expected += perPlayer
		if r == nil or r.ok ~= true then
			run.ok = false
			run.why = run.why or (player.Name .. ": " .. (if r then tostring(r.error) else "no result"))
			run.lost += perPlayer
			continue
		end
		local n = num(r.n)
		run.delivered += n
		run.lost += math.max(0, perPlayer - n)
		run.reord += num(r.reord)
		run.bad += num(r.bad)
		brOk += num(r.brOk)
		brN += n
		table.insert(recv, num(r.recvS) * 1000 / f)
		table.insert(calls, num(r.calls) / f)
		table.insert(bytes, num(r.bytes) / f)
		table.insert(kbps, num(r.recvKbps))
		table.insert(fps, num(r.fps))
		run.bytesApprox = run.bytesApprox or r.bytesApprox == true
		if type(r.drainS) == "number" then
			run.drainS = math.max(run.drainS or 0, r.drainS)
		end
		run.capped = run.capped or r.capped == true
		if r.check ~= true then
			run.ok = false
			run.why = run.why or (player.Name .. ": " .. tostring(r.why))
		elseif def.kind == "bool" and n == perPlayer and num(r.trues) ~= trues then
			run.ok = false
			run.why = run.why or string.format("%s: %d trues, expected %d", player.Name, num(r.trues), trues)
		end
		if r.loren ~= nil then
			clientLoren.EventsLost += field(r.loren, "EventsLost")
			clientLoren.SignalsDropped += field(r.loren, "SignalsDropped")
		end
	end
	run.recvMs = if #recv > 0 then mean(recv) else nil
	run.rxCalls = mean(calls)
	run.bytes = mean(bytes)
	run.kbps = mean(kbps)
	run.cfps = mean(fps)
	run.bracket = if brN > 0 then brOk / brN else nil
	-- Server remote calls: Loren's are counted (FramesOut); the others follow from their send model.
	local model: Plan.TxModel = runtime.txModel(def)
	if model == "measured" then
		run.txCalls = statDelta(after, before, "FramesOut") / f
	else
		run.txCalls = Plan.txCalls(model, calls)
		run.txDerived = true
	end
	if isLoren(lib) then
		run.lorenIssues = lorenIssues({
			FramesDropped = statDelta(after, before, "FramesDropped"),
			SignalsDropped = statDelta(after, before, "SignalsDropped"),
			OutboxDropped = statDelta(after, before, "OutboxDropped"),
		}, clientLoren)
	end
	return run, nil
end

-- One C->S run: every client fires from PreSimulation; the server counts, checks and times its listeners.
local function runC2S(ctx: Context, lib: string, def: Payloads.Def, seconds: number, idle: Idle): (Table.Run?, string?)
	local changed = checkClients(ctx)
	if changed then
		return nil, changed
	end
	local players = ctx.players
	local runtimeKey = Config.RUNTIME_OF[lib]
	local runId = Coordinator.nextRunId()
	local recvRun = Recv.armServer(lib, runtimeKey, def)
	local problem = armAll(players, { cmd = "arm", runId = runId, lib = lib, payload = def.name, dir = "c2s" })
	if problem then
		Recv.finishServer(lib, recvRun)
		return nil, problem
	end

	local function delivered(): number
		local total = 0
		for _, st in recvRun.streams do
			total += st.n
		end
		return total
	end
	local lastAt: number? = nil
	local seen = 0
	local monitor = RunService.Heartbeat:Connect(function()
		local total = delivered()
		if total ~= seen then
			seen = total
			lastAt = workspace:GetServerTimeNow()
		end
	end)

	local before = lorenStats(ctx)
	local sampler = Sampler.start()
	local hbTotal, hbN = 0, 0
	local hbLoop = RunService.PreSimulation:Connect(function()
		local hb = readHbStat(ctx.hbStat)
		if hb then
			hbTotal += hb
			hbN += 1
		end
	end)
	broadcast(players, { cmd = "fire", runId = runId, seconds = seconds })
	task.wait(seconds)
	hbLoop:Disconnect()
	local summary = sampler:stop()
	local sent = Coordinator.collect("sent", runId, players, seconds + 30)

	-- Drain: everything each client fired, or 2 s without progress (cap 30 s).
	local function missing(): boolean
		for _, player in players do
			local s = sent[player]
			local st = recvRun.streams[player]
			if s and num(s.fired) > (if st then st.n else 0) then
				return true
			end
		end
		return false
	end
	local capped = false
	local deadline = os.clock() + DRAIN_CAP
	local lastCount, lastChange = delivered(), os.clock()
	while missing() do
		local now = os.clock()
		if now - lastChange >= DRAIN_QUIET then
			break
		elseif now >= deadline then
			capped = true
			break
		end
		task.wait()
		local count = delivered()
		if count ~= lastCount then
			lastCount, lastChange = count, os.clock()
		end
	end
	local after = lorenStats(ctx)
	local frozen = Recv.snapshot(recvRun)
	local snapshot = frozen.streams
	local drainAt = lastAt
	if capped then
		-- Let the backlog land before the next run, so it does not share the network with it.
		local quietSince, settleEnd = os.clock(), os.clock() + SETTLE_CAP
		local last = delivered()
		while os.clock() - quietSince < DRAIN_QUIET and os.clock() < settleEnd do
			task.wait(0.1)
			local count = delivered()
			if count ~= last then
				last, quietSince = count, os.clock()
			end
		end
	end
	Recv.finishServer(lib, recvRun)
	monitor:Disconnect()

	local run = emptyRun()
	run.recvApprox = true
	run.capped = capped
	run.shbP50, run.shbP95 = heartbeat(summary)
	run.hbStat = if hbN > 0 then hbTotal / hbN else nil
	run.warnings, run.errors = summary.logs.warnings, summary.logs.errors
	local sendMs, flushMs, calls, bytes, fps, sendKbps, frameList, senderCalls = {}, {}, {}, {}, {}, {}, {}, {}
	local totalFrames, totalN = 0, 0
	local stopServer = 0
	local clientLoren = { EventsLost = 0, SignalsDropped = 0 }
	for _, player in players do
		local s = sent[player]
		if s == nil or s.ok ~= true then
			run.ok = false
			run.why = run.why or (player.Name .. ": " .. (if s then tostring(s.error) else "no report"))
			continue
		end
		local frames = math.max(num(s.frames), 1)
		local fired = num(s.fired)
		local st = snapshot[player]
		local n = if st then st.n else 0
		totalFrames += frames
		totalN += n
		table.insert(frameList, frames)
		run.expected += fired
		run.delivered += n
		run.lost += math.max(0, fired - n)
		if st then
			run.reord += st.reord
			run.bad += st.bad
			local ok, why = Payloads.check(def, st.cap)
			if not ok then
				run.ok = false
				run.why = run.why or (player.Name .. ": " .. tostring(why))
			end
		else
			run.ok = false
			run.why = run.why or (player.Name .. ": nothing received")
		end
		table.insert(sendMs, num(s.sendS) * 1000 / frames)
		table.insert(flushMs, num(s.flushS) * 1000 / frames)
		table.insert(fps, num(s.fps))
		table.insert(sendKbps, num(s.sendKbps))
		table.insert(calls, (frozen.calls[player] or 0) / frames)
		local b, approx = Recv.serverBytes(frozen, player)
		table.insert(bytes, b / frames)
		run.bytesApprox = run.bytesApprox or approx
		stopServer = math.max(stopServer, num(s.stopServer))
		if s.loren ~= nil then
			table.insert(senderCalls, field(s.loren, "FramesOut") / frames)
			clientLoren.EventsLost += field(s.loren, "EventsLost")
			clientLoren.SignalsDropped += field(s.loren, "SignalsDropped")
		end
	end
	run.frames = if #frameList > 0 then mean(frameList) else 0
	run.sendMs = mean(sendMs)
	run.flushMs = mean(flushMs)
	run.totalMs = run.sendMs + run.flushMs
	run.rxCalls = mean(calls)
	run.bytes = mean(bytes)
	run.cfps = mean(fps)
	for _, v in fps do
		run.cfpsMax = math.max(run.cfpsMax, v)
	end
	run.sendKbps = mean(sendKbps)
	-- Client remote calls: Loren's are counted (FramesOut); for the others every FireServer arrives once.
	if runtimeKey == "loren" then
		run.txCalls = if #senderCalls > 0 then mean(senderCalls) else nil
	else
		run.txCalls = run.rxCalls
		run.txDerived = true
	end
	run.kbps = (summary.recvKbps.mean - idle.recvKbps) / math.max(#players, 1)
	local span = frozen.span
	run.recvCoverage = if totalN > 0 then span.msgs / totalN else nil
	if totalFrames > 0 and run.recvCoverage ~= nil and run.recvCoverage >= 0.5 then
		run.recvMs = span.total * 1000 / totalFrames
	end
	if drainAt ~= nil and stopServer > 0 then
		run.drainS = math.max(0, drainAt - stopServer)
	end
	if isLoren(lib) then
		run.lorenIssues = lorenIssues({
			FramesDropped = statDelta(after, before, "FramesDropped"),
			SignalsDropped = statDelta(after, before, "SignalsDropped"),
			OutboxDropped = statDelta(after, before, "OutboxDropped"),
		}, clientLoren)
	end
	return run, nil
end

local function runOne(ctx: Context, lib: string, def: Payloads.Def, seconds: number, idle: Idle): (Table.Run?, string?)
	local ok, run, problem = pcall(function(): (Table.Run?, string?)
		if def.dir == "s2c" then
			return runS2C(ctx, lib, def, seconds, idle)
		end
		return runC2S(ctx, lib, def, seconds, idle)
	end)
	task.wait(Plan.GAP_SECONDS)
	if not ok then
		return nil, "bench error: " .. tostring(run)
	end
	return run, problem
end

-- Medians across runs (clients were already averaged within each run).
local function medianRun(runs: { Table.Run }): Table.Run?
	if #runs == 0 then
		return nil
	end
	local m = emptyRun()
	local function med(get: (Table.Run) -> number?): number?
		local list = {}
		for _, r in runs do
			local v = get(r)
			if v ~= nil then
				table.insert(list, v)
			end
		end
		return median(list)
	end
	local anyRun = runs[1]
	m.frames = med(function(r)
		return r.frames
	end) or 0
	m.sendMs = med(function(r)
		return r.sendMs
	end) or 0
	m.flushMs = med(function(r)
		return r.flushMs
	end) or 0
	m.totalMs = med(function(r)
		return r.totalMs
	end) or 0
	m.recvMs = med(function(r)
		return r.recvMs
	end)
	m.recvApprox = anyRun.recvApprox
	m.recvCoverage = med(function(r)
		return r.recvCoverage
	end)
	m.txCalls = med(function(r)
		return r.txCalls
	end)
	m.txDerived = anyRun.txDerived
	m.rxCalls = med(function(r)
		return r.rxCalls
	end) or 0
	m.bytes = med(function(r)
		return r.bytes
	end) or 0
	m.kbps = med(function(r)
		return r.kbps
	end) or 0
	m.sendKbps = med(function(r)
		return r.sendKbps
	end) or 0
	m.cfps = med(function(r)
		return r.cfps
	end) or 0
	m.shbP50 = med(function(r)
		return r.shbP50
	end) or 0
	m.shbP95 = med(function(r)
		return r.shbP95
	end) or 0
	m.hbStat = med(function(r)
		return r.hbStat
	end)
	m.delivered = med(function(r)
		return r.delivered
	end) or 0
	m.expected = med(function(r)
		return r.expected
	end) or 0
	m.lost = med(function(r)
		return r.lost
	end) or 0
	m.reord = med(function(r)
		return r.reord
	end) or 0
	m.bad = med(function(r)
		return r.bad
	end) or 0
	m.drainS = med(function(r)
		return r.drainS
	end)
	m.warnings = med(function(r)
		return r.warnings
	end) or 0
	m.errors = med(function(r)
		return r.errors
	end) or 0
	local lowest: number? = nil
	for _, r in runs do
		m.bytesApprox = m.bytesApprox or r.bytesApprox
		m.capped = m.capped or r.capped
		if not r.ok then
			m.ok = false
			m.why = m.why or r.why
		end
		m.lorenIssues = m.lorenIssues or r.lorenIssues
		if r.bracket ~= nil then
			lowest = math.min(lowest or 1, r.bracket)
		end
		-- Loss, reordering or a too-fast client in any run shows, even when the median run was clean.
		m.lost = math.max(m.lost, r.lost)
		m.reord = math.max(m.reord, r.reord)
		m.cfpsMax = math.max(m.cfpsMax, r.cfpsMax)
	end
	m.bracket = lowest
	return m
end

local function fmtTime(seconds: number): string
	return string.format("%dm%02ds", seconds // 60, math.floor(seconds % 60))
end

function Runner.run(ctx: Context)
	local settings = ctx.settings
	local players = ctx.players
	local benchStarted = os.clock()

	-- Which rows can run each payload: server adapter has the event and every client booted the runtime.
	local support: { [string]: { [string]: string? } } = {}
	local clientBoot = Coordinator.collect("benchinfo", 0, players, 1)
	for _, name in settings.payloads do
		local def = Payloads.def(name)
		local row: { [string]: string? } = {}
		for _, lib in settings.libs do
			local runtimeKey = Config.RUNTIME_OF[lib]
			local adapter = ctx.adapters[lib]
			local reason: string? = nil
			if ctx.bootErrors[runtimeKey] then
				reason = "server boot failed: " .. ctx.bootErrors[runtimeKey]
			elseif adapter == nil then
				reason = "not booted"
			elseif not Plan.supported(adapter, def) then
				reason = "no " .. def.event .. " in this library"
			else
				for _, player in players do
					local info = clientBoot[player]
					local bootMap: any = if info then info.boot else nil
					local boot: any = if type(bootMap) == "table" then (bootMap :: any)[runtimeKey] else nil
					if boot ~= true then
						reason = player.Name .. " boot failed: " .. tostring(boot)
						break
					end
				end
			end
			row[lib] = reason
		end
		support[name] = row
	end
	local function runnable(name: string): { string }
		local out = {}
		for _, lib in settings.libs do
			if support[name][lib] == nil then
				table.insert(out, lib)
			end
		end
		return out
	end
	local eta = Plan.eta(settings.payloads, function(name: string): number
		return #runnable(name)
	end, settings.Seconds, settings.Runs, settings.Warmup)

	local clientOrders = {}
	for _, player in players do
		local info = clientBoot[player]
		table.insert(clientOrders, player.Name .. " " .. (if info then tostring(info.order) else "?"))
	end
	local header = {
		Report.rule("LorenBench"),
		string.format(
			"Library %s | Payload %s | Seconds %d | Runs %d | Warmup %d s | clients %d",
			settings.Library,
			settings.Payload,
			settings.Seconds,
			settings.Runs,
			settings.Warmup,
			#players
		),
		"connect order: server " .. ctx.serverOrder .. " | clients " .. table.concat(clientOrders, ", "),
		string.format("ETA about %s", fmtTime(eta)),
	}
	for _, key in settings.runtimes do
		local runtime = ctx.runtimes[key]
		local failed = ctx.bootErrors[key]
		table.insert(
			header,
			string.format(
				"  %s: %s | sends: %s",
				key,
				if failed then "FAILED " .. failed elseif runtime then runtime.name else "?",
				if runtime then runtime.sender else "-"
			)
		)
	end
	table.insert(header, "server HeartbeatTime stat: " .. (ctx.hbStat or "not readable"))
	for _, line in Table.CAVEATS do
		table.insert(header, line)
	end
	Report.print(header)

	local idle = idlePhase(ctx, Plan.IDLE_SECONDS)
	local idleFps, idleRecv = {}, {}
	for _, player in players do
		local r = idle.clients[player]
		if r then
			table.insert(idleFps, num(r.fps))
			table.insert(idleRecv, num(r.recvKbps))
		end
	end
	-- Each library's own Heartbeat/PostSimulation work with nothing to send, which every run also pays.
	local libParts = {}
	for _, key in settings.runtimes do
		local server = idle.libs[key]
		if server ~= nil then
			local client = {}
			for _, player in players do
				local r = idle.clients[player]
				local libs: any = if r then r.libs else nil
				if type(libs) == "table" and type(libs[key]) == "number" then
					table.insert(client, libs[key])
				end
			end
			table.insert(
				libParts,
				string.format(
					"%s %.4f/%s",
					key,
					server,
					if #client > 0 then string.format("%.4f", mean(client)) else "-"
				)
			)
		end
	end
	local idleLine = string.format(
		"idle | server HB p50/p95 %.1f/%.1f ms | server KB/s send %.1f recv %.1f | clients cFPS %.0f, recv %.1f KB/s",
		idle.p50,
		idle.p95,
		idle.sendKbps,
		idle.recvKbps,
		mean(idleFps),
		mean(idleRecv)
	)
	local idleLibs = "idle library work, ms/frame server/client: " .. table.concat(libParts, " | ")
	Report.say(idleLine)
	Report.say(idleLibs)

	local rows: { Table.Row } = {}
	local rowsByPayload: { [string]: { Table.Row } } = {}
	for index, name in settings.payloads do
		local def = Payloads.def(name)
		Payloads.pool(def)
		local libs = runnable(name)
		local results: { [string]: { Table.Run } } = {}
		local failures: { [string]: string } = {}
		for _, lib in libs do
			results[lib] = {}
		end
		local baseline = idlePhase(ctx, Plan.IDLE_SECONDS)
		if settings.Warmup > 0 then
			for _, lib in libs do
				runOne(ctx, lib, def, settings.Warmup, baseline)
			end
		end
		for r = 1, settings.Runs do
			for _, lib in Plan.rotate(libs, r) do
				local run, problem = runOne(ctx, lib, def, settings.Seconds, baseline)
				if run then
					table.insert(results[lib], run)
				elseif problem then
					failures[lib] = problem
				end
			end
		end
		local payloadRows: { Table.Row } = {}
		for _, lib in settings.libs do
			local runs = results[lib] or {}
			local row: Table.Row = {
				payload = name,
				lib = lib,
				dir = def.dir,
				reliable = def.reliable,
				na = support[name][lib] or (if #runs == 0 then failures[lib] or "no runs" else nil),
				runs = runs,
				median = medianRun(runs),
			}
			table.insert(payloadRows, row)
			table.insert(rows, row)
		end
		rowsByPayload[name] = payloadRows
		local lines = {
			string.format(
				"[%d/%d] %s (%s) done, %s elapsed",
				index,
				#settings.payloads,
				name,
				def.dir,
				fmtTime(os.clock() - benchStarted)
			),
			Table.header(),
		}
		for _, row in payloadRows do
			table.insert(lines, Table.row(row))
		end
		Report.print(lines)
	end

	-- Final report: the whole table, one BENCH_JSON line per row, the SUMMARY and the result.
	local invalid: { string } = {}
	local mixed = ctx.serverOrder == "mixed"
	for _, player in players do
		local info = clientBoot[player]
		if info and info.order == "mixed" then
			mixed = true
		end
	end
	if mixed then
		table.insert(invalid, "connect order mixed: recv and flush brackets are not valid")
	end
	if ctx.clientsChanged then
		table.insert(invalid, "client set changed during the bench (" .. ctx.clientsChanged .. ")")
	end
	for _, row in rows do
		local m = row.median
		if row.na == nil and m ~= nil then
			local where = row.payload .. "/" .. row.lib
			if m.bracket ~= nil and m.bracket < 0.95 then
				table.insert(invalid, where .. " bracket " .. string.format("%.0f%%", m.bracket * 100))
			end
			if row.dir == "c2s" and m.cfpsMax > MAX_CLIENT_FPS then
				table.insert(invalid, string.format("%s client at %.0f FPS (cap it at 60)", where, m.cfpsMax))
			end
			if row.reliable then
				if m.lost > 0 then
					table.insert(invalid, where .. " lost " .. tostring(m.lost))
				end
				if not m.ok then
					table.insert(invalid, where .. " check failed")
				end
				if m.capped then
					table.insert(invalid, where .. " drain capped")
				end
				if m.lorenIssues then
					table.insert(invalid, where .. " Loren stats")
				end
			end
		end
	end
	local report = {
		Report.rule("LorenBench REPORT"),
		string.format(
			"clients %d | Seconds %d | Runs %d | Warmup %d s | connect order %s | %s total",
			#players,
			settings.Seconds,
			settings.Runs,
			settings.Warmup,
			ctx.serverOrder,
			fmtTime(os.clock() - benchStarted)
		),
		idleLine,
		idleLibs,
		Table.header(),
		Table.rule(),
	}
	for _, row in rows do
		table.insert(report, Table.row(row))
	end
	Report.print(report)
	local meta = { clients = #players, seconds = settings.Seconds, order = ctx.serverOrder }
	for _, row in rows do
		Report.say(Table.json(row, meta))
	end
	local summary = { "SUMMARY" }
	for _, name in settings.payloads do
		local payloadRows: { Table.Row } = rowsByPayload[name] or {}
		for _, line in Table.summary(name, payloadRows) do
			table.insert(summary, line)
		end
	end
	table.insert(summary, Table.LEGEND)
	local result = if #invalid == 0 then "DONE" else "INVALID"
	table.insert(
		summary,
		"RESULT: " .. result .. (if #invalid > 0 then " (" .. table.concat(invalid, "; ") .. ")" else "")
	)
	Report.print(summary)
	local config = ReplicatedStorage:FindFirstChild("TestConfig")
	if config then
		config:SetAttribute("LastResult", result)
	end
	broadcast(Coordinator.active(), { cmd = "done", result = result })
end

return Runner
