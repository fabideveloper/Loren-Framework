--!strict
--!optimize 2

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Stats = game:GetService("Stats")

local LT = ReplicatedStorage:WaitForChild("LorenTest")
local Harness = LT:WaitForChild("Harness")
local Env = require(Harness:WaitForChild("Env"))
local Metrics = require(Harness:WaitForChild("Metrics"))
local LorenTest = require(LT:WaitForChild("LorenTest"))
local Backend = require(script.Parent:WaitForChild("Backend"))
local Coordinator = require(script.Parent:WaitForChild("Coordinator"))
local Report = require(script.Parent:WaitForChild("Report"))
local Sampler = require(script.Parent:WaitForChild("Sampler"))

local isTable = Metrics.isTable
local asNumber = Metrics.asNumber

local Scenarios = {}

export type PhaseResult = { name: string, verdict: string, reasons: { string } }
type Config = Env.Config

Scenarios.PLANS = {
	check = { "check" },
	stress = { "stress" },
	burst = { "burst" },
	security = { "security" },
	soak = { "soak" },
	compare = { "compare" },
	all = { "check", "stress", "security" },
} :: { [string]: { string } }

local VERDICT_RANK = { PASS = 0, SKIP = 1, WARN = 2, FAIL = 3, ERROR = 4 }

local function worst(a: string, b: string): string
	return if (VERDICT_RANK[b] or 4) > (VERDICT_RANK[a] or 4) then b else a
end

local function modeLabel(): string
	if Env.isRunMode then
		return "Studio Run mode (server only)"
	end
	return "Play, " .. #Players:GetPlayers() .. " player(s) in game"
end

local function splitLines(text: string, into: { string }, indent: string?)
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		table.insert(into, (indent or "") .. line)
	end
end

local function silentPlayers(): string?
	local names = {}
	for _, player in Players:GetPlayers() do
		if not Coordinator.info(player) then
			table.insert(names, player.Name)
		end
	end
	if #names == 0 then
		return nil
	end
	table.sort(names)
	return "client(s) in the game never reported (boot hung or failed before hello): " .. table.concat(names, ", ")
end

-- [[ check ]]

local function specsRoot(): Instance?
	return ServerStorage:WaitForChild("LorenTest"):FindFirstChild("Specs")
end

-- Appends the specs of one folder (or a note saying why there are none).
local function addSpecs(
	specs: { LorenTest.Spec },
	notes: { string },
	folderName: string,
	prefix: string,
	enabled: boolean,
	why: string?
)
	local root = specsRoot()
	local folder = root and root:FindFirstChild(folderName)
	if not folder then
		table.insert(notes, prefix .. ": no specs in this project (folder missing)")
		return
	end
	if not enabled then
		table.insert(notes, prefix .. ": skipped (" .. (why or "disabled") .. ")")
		return
	end
	local found = LorenTest.collect(folder, prefix)
	if #found == 0 then
		table.insert(notes, prefix .. ": folder is empty")
	end
	for _, spec in found do
		table.insert(specs, spec)
	end
end

local function serverSpecs(): ({ LorenTest.Spec }, { string })
	local specs: { LorenTest.Spec } = {}
	local notes: { string } = {}
	addSpecs(specs, notes, "Runner", "runner", true)
	addSpecs(specs, notes, "StudioServer", "studio/server", true)
	addSpecs(specs, notes, "V2Server", "v2/server", Env.is20, "2.0-only specs; runtime is " .. Env.runtime)
	return specs, notes
end

-- Unit specs ran by Scenarios.beforeBoot (results nil when they did not run; crash set if it threw).
local unitRun: { results: LorenTest.Results?, notes: { string }, crash: string? } =
	{ results = nil, notes = {}, crash = nil }

-- Printed before the unit specs: the Output shows errors the specs trigger on purpose.
local EXPECTED_ERRORS_NOTE = "note: tests trigger errors on purpose during check; red lines in the Output are expected. "
	.. "Only the CHECK REPORT / RESULT at the end decides pass or fail."

local MAX_SHOWN_LOG_LINES = 40
local MAX_LOG_LINE_LENGTH = 300

type Sink = (string) -> ()
type SetSinks = (Sink?, Sink?) -> ...any

local unitLog: {
	hook: SetSinks?, -- set while the capture is installed
	started: boolean,
	count: number,
	lines: { string }, -- the first MAX_SHOWN_LOG_LINES
	note: string?, -- why nothing was captured, or why the restore failed
} =
	{ hook = nil, started = false, count = 0, lines = {}, note = nil }

-- The runtime's Log._test.setDefaultSinks, or nil (an older runtime without the hook: no capture).
local function defaultSinksHook(): SetSinks?
	local runtime = ReplicatedStorage:FindFirstChild("LorenRuntime")
	local module = runtime and runtime:FindFirstChild("Log")
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, Log: any = pcall(require, module)
	local hooks: any = if ok and type(Log) == "table" then Log._test else nil
	local hook: any = if type(hooks) == "table" then hooks.setDefaultSinks else nil
	return if type(hook) == "function" then hook else nil
end

local function captureSink(kind: string, real: Sink): Sink
	return function(line: string)
		if not unitLog.hook then
			real(line)
			return
		end
		unitLog.count += 1
		if #unitLog.lines < MAX_SHOWN_LOG_LINES then
			table.insert(unitLog.lines, kind .. " " .. string.sub(tostring(line), 1, MAX_LOG_LINE_LENGTH))
		end
	end
end

local function startLogCapture()
	local hook = defaultSinksHook()
	if not hook then
		unitLog.note = "Loren log capture off (this runtime's Log has no _test.setDefaultSinks); "
			.. "unit log lines went to the Output"
		return
	end
	local ok, err = pcall(hook, captureSink("print", print), captureSink("warn", warn))
	if not ok then
		unitLog.note = "Loren log capture off (setDefaultSinks failed: " .. tostring(err) .. ")"
		pcall(hook, nil, nil)
		return
	end
	unitLog.hook = hook
	unitLog.started = true
end

-- Restores the real sinks. Safe to call more than once and when the capture never started.
local function stopLogCapture()
	local hook = unitLog.hook
	if not hook then
		return
	end
	unitLog.hook = nil
	local ok, err = pcall(hook, nil, nil)
	if not ok then
		unitLog.note = "restoring Loren's log sinks failed (" .. tostring(err) .. "); later lines pass through"
		Report.say(unitLog.note :: string)
	end
end

-- The unit log lines of the CHECK REPORT (after the unit results).
local function unitLogLines(into: { string })
	if unitLog.note then
		table.insert(into, "note: " .. unitLog.note)
	end
	if not unitLog.started then
		return
	end
	table.insert(into, string.format("%d expected Loren log lines captured during unit specs", unitLog.count))
	local results = unitRun.results
	local failed = unitRun.crash ~= nil or results == nil or results.failed > 0
	if failed and unitLog.count > 0 then
		table.insert(
			into,
			string.format(
				"captured Loren log lines (unit phase failed; first %d of %d):",
				#unitLog.lines,
				unitLog.count
			)
		)
		for _, line in unitLog.lines do
			splitLines(line, into, "    ")
		end
	end
end

local function runUnitSpecs()
	local notes = unitRun.notes
	if not ReplicatedStorage:FindFirstChild("LorenRuntime") then
		table.insert(notes, "unit: skipped (no ReplicatedStorage.LorenRuntime; runtime " .. Env.runtime .. ")")
		return
	end
	local specs: { LorenTest.Spec } = {}
	addSpecs(specs, notes, "Unit", "unit", true)
	if #specs == 0 then
		return
	end
	Report.say(string.format("check: running %d unit spec file(s) before the fixture boot", #specs))
	startLogCapture()
	local runOptions: LorenTest.RunOptions = { label = "server unit specs (before the fixture boot)" }
	local ok, results = pcall(LorenTest.run, specs, runOptions)
	stopLogCapture()
	if not ok then
		error(results, 0)
	end
	unitRun.results = results
	local resetError = Backend.resetRuntime()
	if resetError then
		-- The fixture boot would inherit whatever the unit specs left behind: a check failure.
		unitRun.crash = "Loren.Testing.Reset() after the unit specs failed: " .. resetError
	end
end

function Scenarios.beforeBoot(config: Config)
	local plan = Scenarios.PLANS[config.Scenario]
	if not plan or not table.find(plan, "check") then
		return
	end
	Report.say(EXPECTED_ERRORS_NOTE)
	local ok, err = pcall(function()
		runUnitSpecs()
	end)
	stopLogCapture() -- already done unless something between start and stop threw
	if not ok then
		unitRun.crash = "unit phase crashed: " .. tostring(err)
	end
	if unitRun.crash then
		Report.say(unitRun.crash :: string)
	end
end

function Scenarios.check(_config: Config): PhaseResult
	local players = Coordinator.active()
	local runId = Coordinator.nextRunId()
	local reasons = {}
	Report.say(
		string.format(
			"check: running specs on the server%s",
			if #players > 0 then " and " .. #players .. " client(s)" else " (no clients)"
		)
	)
	local ticking = Env.boot.ok
	if ticking then
		Backend.startTicking(10) -- the client Broadcast spec checks Tick order
	end
	for _, player in players do
		Coordinator.send(player, { cmd = "check", runId = runId })
	end

	local specs, notes = serverSpecs()
	local serverResults = LorenTest.run(specs, { label = "server (" .. Env.runtimeLabel() .. ")" })
	local clientResults = if #players > 0 then Coordinator.collect("check", runId, players, 240) else {}
	if ticking then
		Backend.stopTicking()
	end

	local lines = { Report.rule("CHECK REPORT"), "runtime " .. Env.runtimeLabel() .. " | " .. modeLabel() }
	local passed, failed, skipped = serverResults.passed, serverResults.failed, serverResults.skipped
	if Env.boot.ok then
		table.insert(lines, string.format("server boot ok in %.0f ms", Env.boot.ms))
	else
		table.insert(lines, "server boot FAILED: " .. tostring(Env.boot.error))
		table.insert(reasons, "server boot failed")
	end
	local silent = silentPlayers()
	if silent then
		table.insert(lines, silent)
		table.insert(reasons, silent)
	end
	if unitRun.crash then
		table.insert(lines, unitRun.crash)
		table.insert(reasons, unitRun.crash)
	end
	if Env.note then
		table.insert(lines, "note: " .. Env.note)
	end
	for _, note in unitRun.notes do
		table.insert(lines, "note: " .. note)
	end
	for _, note in notes do
		table.insert(lines, "note: " .. note)
	end
	local unitResults = unitRun.results
	if unitResults then
		passed += unitResults.passed
		failed += unitResults.failed
		skipped += unitResults.skipped
		splitLines(LorenTest.report(unitResults), lines)
	end
	unitLogLines(lines)
	splitLines(LorenTest.report(serverResults), lines)

	for _, player in players do
		local info = Coordinator.info(player)
		local message: any = clientResults[player]
		table.insert(lines, "")
		if info then
			table.insert(
				lines,
				string.format(
					"client %s: %s, boot %s in %.0f ms%s",
					player.Name,
					info.label,
					if info.bootOk then "ok" else "FAILED",
					info.bootMs,
					if info.bootError then " (" .. info.bootError .. ")" else ""
				)
			)
			if not info.bootOk then
				table.insert(reasons, player.Name .. " boot failed")
			end
		end
		local results: any = message and message.results
		if isTable(results) and Metrics.isNumber(results.passed) then
			passed += results.passed
			failed += results.failed
			skipped += results.skipped
			splitLines(LorenTest.report(results), lines)
		else
			failed += 1
			table.insert(lines, "  no check result from " .. player.Name .. " (timed out or left)")
			table.insert(reasons, player.Name .. " sent no result")
		end
	end
	if failed > 0 then
		table.insert(reasons, failed .. " spec failure(s)")
	end
	local verdict = if #reasons > 0 then "FAIL" else "PASS"
	table.insert(lines, "")
	table.insert(
		lines,
		string.format("CHECK TOTAL: %d passed, %d failed, %d skipped => %s", passed, failed, skipped, verdict)
	)
	Report.print(lines)
	return { name = "check", verdict = verdict, reasons = reasons }
end

-- [[ load phases ]]

type Params = {
	duration: number,
	rate: number,
	payloadSize: number,
	tickRate: number,
	burstSize: number?,
	interval: number?,
}

local function paramsFor(name: string, config: Config): Params
	if name == "compare" then
		return { duration = 20, rate = 20, payloadSize = 64, tickRate = 20 }
	elseif name == "burst" then
		return {
			duration = config.Duration,
			rate = config.Rate,
			payloadSize = config.PayloadSize,
			tickRate = 0,
			burstSize = math.max(1, math.floor(config.Rate * 2)),
			interval = 2,
		}
	end
	return {
		duration = config.Duration,
		rate = config.Rate,
		payloadSize = config.PayloadSize,
		tickRate = config.Rate,
	}
end

local function roleFor(name: string, index: number): string
	if name == "security" then
		return if index == 1 then "exploit" else "stress"
	end
	return name -- stress, burst, soak, compare
end

local function evaluate(
	name: string,
	players: { Player },
	roles: { [Player]: string },
	results: { [Player]: any },
	server: Sampler.Summary,
	integrity: { string }
): (string, { string })
	local fails, warns = {}, {}
	for _, player in players do
		local message: any = results[player]
		local stats: any = message and message.stats
		if not isTable(stats) then
			table.insert(fails, player.Name .. ": no result")
			continue
		end
		if stats.error then
			table.insert(fails, player.Name .. ": bots did not start: " .. tostring(stats.error))
			continue
		end
		if roles[player] == "exploit" then
			local e: any = stats.exploit or {}
			local probes: any, crafted: any = e.probes or {}, e.crafted or {}
			if asNumber(probes.acceptedBad) > 0 then
				table.insert(fails, "bad input ACCEPTED through the proxy: " .. table.concat(probes.labels or {}, ", "))
			end
			if asNumber(crafted.acceptedBad) > 0 then
				table.insert(fails, "crafted bad input ACCEPTED: " .. table.concat(crafted.labels or {}, ", "))
			end
			if asNumber(e.internalErrors) > 0 then
				table.insert(warns, "exploiter bot hit internal errors")
			end
			continue
		end
		local c: any = stats.calls
		if isTable(c) then
			if asNumber(c.timeouts) > 0 then
				table.insert(fails, string.format("%s: %d timeouts", player.Name, c.timeouts))
			end
			if asNumber(c.wrong) > 0 then
				table.insert(fails, string.format("%s: %d wrong results", player.Name, c.wrong))
			end
			if asNumber(c.unsettled) > 0 then
				table.insert(fails, string.format("%s: %d calls never settled", player.Name, c.unsettled))
			end
			if asNumber(c.errors) > 0 then
				local line = string.format("%s: %d rejected calls", player.Name, c.errors)
				if name == "burst" then
					table.insert(warns, line .. " (fast rejections)")
				else
					table.insert(fails, line)
				end
			end
		end
		local t: any = stats.ticks
		if isTable(t) then
			if asNumber(t.lost) > 0 or asNumber(t.reordered) > 0 or asNumber(t.duplicates) > 0 then
				table.insert(
					fails,
					string.format(
						"%s: Tick lost %d reordered %d dup %d",
						player.Name,
						asNumber(t.lost),
						asNumber(t.reordered),
						asNumber(t.duplicates)
					)
				)
			end
		end
		local ch: any = stats.changed
		if isTable(ch) and (asNumber(ch.gaps) > 0 or asNumber(ch.reordered) > 0 or asNumber(ch.duplicates) > 0) then
			table.insert(
				fails,
				string.format(
					"%s: Changed gaps %d reordered %d dup %d",
					player.Name,
					asNumber(ch.gaps),
					asNumber(ch.reordered),
					asNumber(ch.duplicates)
				)
			)
		end
	end
	for _, problem in integrity do
		table.insert(fails, problem)
	end
	local silent = silentPlayers()
	if silent then
		table.insert(fails, silent)
	end
	if name == "security" and #players < 2 then
		table.insert(warns, "only one client: no honest client to show whether service survives (use Clients >= 2)")
	end
	if server.logs.errors > 0 then
		table.insert(fails, server.logs.errors .. " server error line(s) during load")
	end
	local warningsPerMinute = server.logs.warnings / math.max(server.durationS, 1) * 60
	if warningsPerMinute > 10 then
		table.insert(warns, string.format("server log spam: %s warnings/min", Metrics.num(warningsPerMinute)))
	end
	local verdict = if #fails > 0 then "FAIL" elseif #warns > 0 then "WARN" else "PASS"
	local reasons = fails
	for _, w in warns do
		table.insert(reasons, w)
	end
	return verdict, reasons
end

local function compareRecord(
	params: Params,
	players: { Player },
	results: { [Player]: any },
	server: Sampler.Summary,
	idle: { sendKbps: number, recvKbps: number },
	handler: { [string]: any }
): { [string]: any }
	local p50, p95, p99, maxP99, ok, sent, timeouts, errors, lost, expected, oneWay = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
	local counted = 0
	for _, player in players do
		local stats: any = results[player] and results[player].stats
		local c: any = stats and stats.calls
		if isTable(c) and isTable(c.rttMs) then
			counted += 1
			p50 += c.rttMs.p50
			p95 += c.rttMs.p95
			p99 += c.rttMs.p99
			maxP99 = math.max(maxP99, c.rttMs.p99)
			ok += c.ok
			sent += c.sent
			timeouts += c.timeouts
			errors += c.errors
		end
		local t: any = stats and stats.ticks
		if isTable(t) then
			lost += asNumber(t.lost)
			expected += asNumber(t.expected)
			if isTable(t.oneWayMs) then
				oneWay = math.max(oneWay, asNumber(t.oneWayMs.p50))
			end
		end
	end
	local calls, time = 0, 0
	for _, s in handler do
		calls += s.calls
		time += s.time
	end
	local n = math.max(counted, 1)
	return {
		runtime = Env.runtime,
		label = Env.runtimeLabel(),
		clients = #players,
		durationS = params.duration,
		callsPerSecondPerClient = params.rate,
		payloadBytes = params.payloadSize,
		tickRate = params.tickRate,
		rttP50Ms = p50 / n,
		rttP95Ms = p95 / n,
		rttP99Ms = p99 / n,
		rttWorstP99Ms = maxP99,
		okPercent = if sent > 0 then ok / sent * 100 else 0,
		timeouts = timeouts,
		errors = errors,
		tickLost = lost,
		tickExpected = expected,
		tickOneWayP50Ms = oneWay,
		serverSendKBps = server.sendKbps.mean - idle.sendKbps,
		serverRecvKBps = server.recvKbps.mean - idle.recvKbps,
		serverFrameP99Ms = server.frameMs.p99,
		serverHeapDeltaMb = server.memory.endHeapMb - server.memory.startHeapMb,
		handlerMeanUs = if calls > 0 then time / calls * 1e6 else 0,
	}
end

function Scenarios.load(name: string, config: Config): PhaseResult
	local players = Coordinator.active()
	local silent = silentPlayers()
	if #players == 0 and silent then
		Report.say(name .. ": FAIL (" .. silent .. ")")
		return { name = name, verdict = "FAIL", reasons = { silent } }
	end
	if #players == 0 then
		local why = if Env.isRunMode then "Run mode has no clients" else "no clients connected"
		Report.say(name .. ": SKIP (" .. why .. "; Play with Server + N clients)")
		return { name = name, verdict = "SKIP", reasons = { why } }
	end
	if not Env.boot.ok then
		Report.say(name .. ": FAIL (server boot failed: " .. tostring(Env.boot.error) .. ")")
		return { name = name, verdict = "FAIL", reasons = { "server boot failed" } }
	end

	local params = paramsFor(name, config)
	local header = string.format(
		"%s: %d client(s), %s s, %s calls/s per client, payload %d B%s",
		name,
		#players,
		tostring(params.duration),
		Metrics.num(params.rate, 0),
		params.payloadSize,
		if params.burstSize
			then string.format(
				", bursts of %d calls + %d Ticks every %d s",
				params.burstSize,
				params.burstSize,
				params.interval or 2
			)
			else string.format(", Tick %s/s", Metrics.num(params.tickRate, 0))
	)
	Report.say(header .. " -- measuring idle baseline")
	local idle = Sampler.idle(2)

	Backend.resetHandlerStats()
	local runId = Coordinator.nextRunId()
	local roles: { [Player]: string } = {}
	local countsBefore: { [Player]: number? } = {}
	for index, player in players do
		roles[player] = roleFor(name, index)
		countsBefore[player] = Backend.countFor(player)
		Coordinator.send(player, { cmd = "start", runId = runId, phase = name, role = roles[player], params = params })
	end
	Coordinator.collect("started", runId, players, 15)

	local sampler = Sampler.start()
	local first, last = 1, 0
	local deadline = os.clock() + params.duration
	if params.burstSize then
		local firstBurst = true
		while os.clock() < deadline do
			local a, b = Backend.fireBurst(params.burstSize)
			if firstBurst then
				first, firstBurst = a, false
			end
			last = b
			task.wait(params.interval or 2)
		end
	else
		first = Backend.startTicking(params.tickRate)
		local progressEvery = math.max(10, params.duration / 10)
		local nextProgress = os.clock() + progressEvery
		while os.clock() < deadline do
			task.wait(math.min(0.5, math.max(0, deadline - os.clock())))
			if name == "soak" and os.clock() >= nextProgress then
				nextProgress += progressEvery
				local m = sampler:peek()
				Report.say(
					string.format(
						"soak t=%ds  Lua heap %s MB  total %s MB  gcinfo %s KB  KB/s send %s recv %s",
						math.floor(m.t),
						Metrics.num(m.heapMb),
						Metrics.num(m.totalMb),
						Metrics.num(m.gcKb, 0),
						Metrics.num(Stats.DataSendKbps),
						Metrics.num(Stats.DataReceiveKbps)
					)
				)
			end
		end
		last = Backend.stopTicking()
	end
	local server = sampler:stop()
	local handler = Backend.handlerStats()

	for _, player in players do
		Coordinator.send(player, { cmd = "stop", runId = runId, ticks = { first = first, last = last } })
	end
	local resultWait = if name == "security" then 60 + math.ceil(params.duration) else 45
	Report.say(string.format("%s: load done, waiting up to %d s for client results", name, resultWait))
	local results = Coordinator.collect("result", runId, players, resultWait)

	local integrity: { string } = {}
	for _, player in players do
		if roles[player] == "exploit" and player.Parent == Players then
			local before, after = countsBefore[player], Backend.countFor(player)
			if before ~= nil and after ~= nil and after ~= before then
				table.insert(
					integrity,
					string.format(
						"exploiter's CounterService count changed %s -> %s (invalid input got through)",
						tostring(before),
						tostring(after)
					)
				)
			end
		end
	end

	local verdict, reasons = evaluate(name, players, roles, results, server, integrity)

	local lines = {
		Report.rule(string.upper(name) .. " REPORT"),
		"runtime " .. Env.runtimeLabel() .. " | " .. modeLabel(),
		header,
		"Studio numbers are relative only (server and clients share one machine)",
		"server",
		"  frame (Heartbeat dt) " .. Metrics.msLineRaw(server.frameMs),
		string.format(
			"  network KB/s (approx.) send %s (max %s) recv %s (max %s); idle baseline send %s recv %s",
			Metrics.num(server.sendKbps.mean),
			Metrics.num(server.sendKbps.max),
			Metrics.num(server.recvKbps.mean),
			Metrics.num(server.recvKbps.max),
			Metrics.num(idle.sendKbps),
			Metrics.num(idle.recvKbps)
		),
		"  " .. Report.memory(server.memory),
	}
	for _, line in Report.handlers(handler) do
		table.insert(lines, "  " .. line)
	end
	splitLines(Report.logs(server.logs, server.durationS), lines, "  ")
	table.insert(lines, string.format("  Tick range %d..%d (%d fired)", first, last, math.max(0, last - first + 1)))
	local lorenStats = Backend.lorenStats()
	if lorenStats and #lorenStats > 0 then
		table.insert(lines, "  Loren.GetStats(): " .. table.concat(lorenStats, "  "))
	end

	table.insert(lines, "clients")
	for _, player in players do
		local message: any = results[player]
		local stats: any = message and message.stats
		table.insert(lines, string.format("  %s [%s]", player.Name, roles[player]))
		if not isTable(stats) then
			table.insert(lines, "    no result (timed out or left)")
			continue
		end
		if roles[player] == "exploit" then
			for _, line in Report.exploit(stats.exploit) do
				table.insert(lines, "    " .. line)
			end
			if countsBefore[player] ~= nil then
				table.insert(
					lines,
					string.format(
						"    CounterService count before/after: %s -> %s",
						tostring(countsBefore[player]),
						tostring(Backend.countFor(player))
					)
				)
			end
		else
			table.insert(lines, "    " .. Report.calls(stats.calls))
			local why = Report.reasons(stats.calls)
			if why then
				table.insert(lines, "    " .. why)
			end
			if stats.calls and isTable(stats.calls.settleMs) then
				table.insert(
					lines,
					string.format(
						"    bursts %d x %d calls, settle %s",
						asNumber(stats.calls.bursts),
						asNumber(stats.calls.burstSize),
						Metrics.msLineRaw(stats.calls.settleMs)
					)
				)
			end
			if stats.ticks then
				table.insert(lines, "    " .. Report.ticks(stats.ticks, "Tick"))
			end
			if stats.changed then
				table.insert(lines, "    " .. Report.ticks(stats.changed, "Changed"))
			end
			local memory: any = stats.calls and stats.calls.memory
			if isTable(memory) then
				table.insert(
					lines,
					string.format(
						"    client gcinfo %s -> %s KB (max %s, trend %s KB/min, %d samples) | churned %s connections, cancelled %s calls",
						Metrics.num(memory.startKb, 0),
						Metrics.num(memory.endKb, 0),
						Metrics.num(memory.maxKb, 0),
						Metrics.num(memory.trendKbPerMin),
						asNumber(memory.samples),
						tostring(stats.calls.churned),
						tostring(stats.calls.cancelled)
					)
				)
			end
		end
		local clientLine = Report.clientSide(stats)
		if clientLine then
			table.insert(lines, "    " .. clientLine)
		end
	end

	table.insert(lines, string.format("VERDICT %s: %s", string.upper(name), verdict))
	for _, reason in reasons do
		table.insert(lines, "  - " .. reason)
	end
	if name == "compare" then
		local record = compareRecord(params, players, results, server, idle, handler)
		table.insert(
			lines,
			string.format(
				"COMPARE runtime=%s clients=%d rtt_p50=%.1fms rtt_p99=%.1fms ok=%.1f%% tick_lost=%d server_KBps_send=%.1f recv=%.1f frame_p99=%.1fms heap_delta=%.2fMB handler_mean=%.1fus",
				record.runtime,
				record.clients,
				record.rttP50Ms,
				record.rttP99Ms,
				record.okPercent,
				record.tickLost,
				record.serverSendKBps,
				record.serverRecvKBps,
				record.serverFrameP99Ms,
				record.serverHeapDeltaMb,
				record.handlerMeanUs
			)
		)
		table.insert(lines, "COMPARE_JSON " .. HttpService:JSONEncode(record))
	end
	Report.print(lines)
	return { name = name, verdict = verdict, reasons = reasons }
end

-- [[ entry ]]

function Scenarios.run(config: Config)
	local plan = Scenarios.PLANS[config.Scenario]
	if not plan then
		Report.say(
			string.format(
				"unknown TestConfig.Scenario %q; use one of: %s",
				config.Scenario,
				table.concat(Env.SCENARIOS, ", ")
			)
		)
		return
	end
	local results: { PhaseResult } = {}
	for _, phase in plan do
		local ok, result = pcall(function(): PhaseResult
			if phase == "check" then
				return Scenarios.check(config)
			end
			return Scenarios.load(phase, config)
		end)
		if not ok then
			Report.say("phase " .. phase .. " crashed: " .. tostring(result))
			table.insert(results, { name = phase, verdict = "ERROR", reasons = { tostring(result) } })
		else
			table.insert(results, result)
		end
		task.wait(1)
	end

	local overall = "PASS"
	local parts = {}
	for _, result in results do
		overall = worst(overall, result.verdict)
		table.insert(parts, result.name .. " " .. result.verdict)
	end
	Report.print({
		Report.rule("SUMMARY"),
		string.format("scenario %s on %s: %s", config.Scenario, Env.runtimeLabel(), table.concat(parts, " | ")),
		"RESULT: " .. overall,
	})
	local testConfig = ReplicatedStorage:FindFirstChild("TestConfig")
	if testConfig then
		testConfig:SetAttribute("LastScenario", config.Scenario)
		testConfig:SetAttribute("LastResult", overall)
	end
	for _, player in Coordinator.active() do
		Coordinator.send(player, { cmd = "done", result = overall })
	end
end

return Scenarios
