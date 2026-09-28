--!strict
--!optimize 2

-- Report formatting: result rows, BENCH_JSON lines, the SUMMARY and the caveats.
local HttpService = game:GetService("HttpService")

local Table = {}

export type Run = {
	frames: number,
	-- Sender frames per second (S->C: server frames; C->S: client 60 Hz ticks, mean over clients).
	rate: number,
	sendMs: number,
	flushMs: number,
	-- C->S: idle library frame work taken out of flush per tick (frames beyond one per tick, above 60 FPS).
	flushAdjMs: number?,
	totalMs: number,
	recvMs: number?,
	recvApprox: boolean,
	recvCoverage: number?,
	-- Remote calls the sender makes per frame; derived = from the library's send model, not counted.
	txCalls: number?,
	txDerived: boolean,
	-- Remote invocations each receiver gets per frame (a FireAllClients counts once per client).
	rxCalls: number,
	bytes: number,
	bytesApprox: boolean,
	-- Computed: bytes x rate / 1000 (per receiver for S->C, per client for C->S). Stats kbps reads 0 on loopback.
	kbps: number,
	-- The sender's Stats.DataSendKbps minus idle (after Roblox's compression); JSON only.
	sendKbps: number,
	cfps: number,
	cfpsMax: number,
	-- C->S: the lowest client tick rate (60 wanted); under 57 the run is INVALID.
	tickHz: number?,
	shbP50: number,
	shbP95: number,
	hbStat: number?,
	delivered: number,
	expected: number,
	lost: number,
	reord: number,
	bad: number,
	drainS: number?,
	capped: boolean,
	ok: boolean,
	why: string?,
	bracket: number?,
	lorenIssues: string?,
	warnings: number,
	errors: number,
}

export type Row = {
	payload: string,
	lib: string,
	dir: string,
	reliable: boolean,
	na: string?,
	runs: { Run },
	median: Run?,
}

type Column = { name: string, width: number, left: boolean }

local function column(name: string, width: number, left: boolean): Column
	return { name = name, width = width, left = left }
end

local COLUMNS: { Column } = {
	column("payload", 13, true),
	column("lib", 13, true),
	column("send", 7, false),
	column("flush", 7, false),
	column("recv", 8, false),
	column("tx/f", 7, false),
	column("rx/f", 6, false),
	column("B/f", 9, false),
	column("KB/s", 8, false),
	column("cFPS", 5, false),
	column("sHB p50/p95", 11, false),
	column("sHBwork", 7, false),
	column("deliv/exp", 17, false),
	column("lost", 6, false),
	column("reord", 5, false),
	column("drain", 6, false),
	column("ok", 4, true),
}

local function pad(text: string, width: number, left: boolean): string
	local n = utf8.len(text) or #text
	if n >= width then
		return text
	end
	local fill = string.rep(" ", width - n)
	return if left then text .. fill else fill .. text
end

local function join(cells: { string }): string
	local parts = table.create(#cells) :: { string }
	for i, cell in cells do
		local c = COLUMNS[i]
		parts[i] = pad(cell, c.width, c.left)
	end
	return table.concat(parts, " | ")
end

local function fmt(value: number?, decimals: number): string
	if value == nil or value ~= value then
		return "-"
	end
	return string.format("%." .. decimals .. "f", value)
end

local function count(value: number): string
	if value >= 1e6 then
		return string.format("%.2fM", value / 1e6)
	end
	return string.format("%d", math.floor(value + 0.5))
end

function Table.header(): string
	local cells = {}
	for i, c in COLUMNS do
		cells[i] = c.name
	end
	return join(cells)
end

function Table.rule(): string
	return string.rep("-", #Table.header())
end

function Table.row(row: Row): string
	local m = row.median
	if row.na or m == nil then
		return pad(row.payload, 13, true) .. " | " .. pad(row.lib, 13, true) .. " | n/a: " .. (row.na or "no runs")
	end
	local recv: string
	if m.recvMs == nil then
		recv = "n/a"
	else
		recv = (if m.recvApprox then "~" else "") .. fmt(m.recvMs, 3)
	end
	local ok = if m.ok then "ok" else "FAIL"
	if m.bracket ~= nil and m.bracket < 0.95 then
		ok ..= "!br"
	end
	return join({
		row.payload,
		row.lib,
		fmt(m.sendMs, 3),
		fmt(m.flushMs, 3),
		recv,
		(if m.txDerived and m.txCalls ~= nil then "*" else "") .. fmt(m.txCalls, 2),
		fmt(m.rxCalls, 2),
		(if m.bytesApprox then "~" else "") .. count(m.bytes),
		fmt(m.kbps, 1),
		fmt(m.cfps, 0),
		fmt(m.shbP50, 1) .. "/" .. fmt(m.shbP95, 1),
		fmt(m.hbStat, 2),
		count(m.delivered) .. "/" .. count(m.expected),
		count(m.lost),
		count(m.reord),
		if m.capped then ">cap" else fmt(m.drainS, 2),
		ok,
	})
end

-- JSON-safe copy: NaN and inf become nil.
local function clean(value: any): any
	if type(value) == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		return value
	elseif type(value) == "table" then
		local out = {}
		for k, v in value do
			out[k] = clean(v)
		end
		return out
	end
	return value
end

function Table.json(row: Row, meta: { [string]: any }): string
	local body = {
		v = 2,
		payload = row.payload,
		lib = row.lib,
		dir = row.dir,
		na = row.na,
		median = row.median,
		runs = row.runs,
	}
	for k, v in meta do
		(body :: any)[k] = v
	end
	local ok, text = pcall(HttpService.JSONEncode, HttpService, clean(body))
	return "BENCH_JSON " .. (if ok then text else '{"error":"encode failed"}')
end

local function ratio(a: number?, b: number?): string
	if a == nil or b == nil or b <= 0 then
		return "-"
	end
	return string.format("x%.2f", a / b)
end

type Metric = { label: string, get: (Run) -> number?, higher: boolean }

local METRICS: { Metric } = {
	{
		label = "send",
		get = function(m: Run): number?
			return m.totalMs
		end,
		higher = false,
	},
	{
		label = "recv",
		get = function(m: Run): number?
			return m.recvMs
		end,
		higher = false,
	},
	{
		label = "tx/f",
		get = function(m: Run): number?
			return m.txCalls
		end,
		higher = false,
	},
	{
		label = "rx/f",
		get = function(m: Run): number?
			return m.rxCalls
		end,
		higher = false,
	},
	{
		label = "B/f",
		get = function(m: Run): number?
			return m.bytes
		end,
		higher = false,
	},
	-- Not ranked: KB/s (B/f times each run's frame rate) and sHBwork (engine-wide; whose work it counts is unproven).
	{
		label = "cFPS",
		get = function(m: Run): number?
			return m.cfps
		end,
		higher = true,
	},
	{
		label = "sHB p50",
		get = function(m: Run): number?
			return m.shbP50
		end,
		higher = false,
	},
}

-- SUMMARY lines for the rows of one payload.
function Table.summary(payload: string, rows: { Row }): { string }
	local lines = {}
	local best: { [string]: { lib: string, value: number } } = {}
	local byLib: { [string]: Run } = {}
	for _, row in rows do
		local m = row.median
		if row.na == nil and m ~= nil then
			byLib[row.lib] = m
			for _, metric in METRICS do
				local v = metric.get(m)
				if v ~= nil and v == v then
					local current = best[metric.label]
					local better = current == nil or (if metric.higher then v > current.value else v < current.value)
					if better then
						best[metric.label] = { lib = row.lib, value = v }
					end
				end
			end
		end
	end
	local parts = {}
	for _, metric in METRICS do
		local b = best[metric.label]
		if b then
			table.insert(parts, string.format("%s %s %s", metric.label, b.lib, fmt(b.value, 3)))
		end
	end
	table.insert(lines, payload .. " best: " .. (if #parts > 0 then table.concat(parts, " | ") else "-"))
	local loren = byLib["loren"]
	if loren then
		local vsBB, vsBest = {}, {}
		local bb = byLib["blinkblox"]
		for _, metric in METRICS do
			local mine = metric.get(loren)
			if bb then
				table.insert(vsBB, metric.label .. " " .. ratio(mine, metric.get(bb)))
			end
			local b = best[metric.label]
			if b then
				table.insert(vsBest, string.format("%s %s (%s)", metric.label, ratio(mine, b.value), b.lib))
			end
		end
		if #vsBB > 0 then
			table.insert(lines, "  Loren / BlinkBlox: " .. table.concat(vsBB, ", "))
		end
		table.insert(lines, "  Loren / best: " .. table.concat(vsBest, ", "))
	end
	for _, row in rows do
		local m = row.median
		if row.na == nil and m ~= nil then
			local issues = {}
			if m.lost > 0 then
				table.insert(
					issues,
					string.format("lost %s%s", count(m.lost), if row.reliable then "" else " (unreliable)")
				)
			end
			if m.reord > 0 then
				table.insert(issues, "reordered " .. count(m.reord))
			end
			if m.bad > 0 then
				table.insert(issues, "malformed " .. count(m.bad))
			end
			if not m.ok then
				table.insert(issues, "check failed: " .. tostring(m.why))
			end
			if m.capped then
				table.insert(issues, "drain hit its cap")
			end
			if m.bracket ~= nil and m.bracket < 0.95 then
				table.insert(issues, string.format("bracket ok %.0f%%", m.bracket * 100))
			end
			if m.lorenIssues then
				table.insert(issues, "Loren stats: " .. m.lorenIssues)
			end
			if row.dir == "c2s" and m.tickHz ~= nil and m.tickHz < 57 then
				table.insert(issues, string.format("a client held only %.1f of 60 ticks/s", m.tickHz))
			end
			if #issues > 0 then
				table.insert(lines, string.format("  %s: %s", row.lib, table.concat(issues, "; ")))
			end
		end
	end
	return lines
end

Table.LEGEND = "legend: Loren and BlinkBlox pay for validation, size and rate checks; Blink, ByteNet and BridgeNet2 pay for none. "
	.. "send/flush/recv are ms per sender frame; flush and recv include the library's own Heartbeat/PostSimulation work and what it defers. "
	.. "recv '~' = server handler span (a lower bound). tx/f = remote calls the sender makes per frame ('*' = from the library's send code, not counted); "
	.. "rx/f = remote invocations per receiver per frame. B/f '~' = RemotePacketSizeCounter estimate. "
	.. "KB/s = B/f x sender frames/s (per receiver for S->C, per client for C->S; 1 KB = 1000 B), computed because Stats kbps reads 0 on loopback. "
	.. "sHBwork = Stats.HeartbeatTimeMs, a smoothed engine-wide stat (context only, not ranked; see the caveats). "
	.. "Columns are medians across runs, except lost and reord (worst run)."

Table.CAVEATS = {
	"caveats:",
	"- Clients fire C->S on a fixed 60 Hz tick at any FPS, so frame rate never changes the load; above 60 FPS, C->S flush drops the idle library work of the extra frames (a few us per tick too much for Loren, whose idle work includes empty credit flushes). A client under 57 ticks/s makes the run INVALID.",
	"- One machine runs the server and every client: run Clients = 1, then 3, and compare numbers within one session only.",
	"- Studio likely compiles at -O1 unless a file says --!optimize 2 (live games use -O2): BridgeNet2 and most of ByteNet lack it, so they may be slower here than live.",
	"- Studio compiles --!native code natively, which live clients mostly do not: client numbers for Blink, BlinkBlox and ByteNet are optimistic.",
	"- recv times Lua only: the engine's own decoding of remote arguments (large for BridgeNet2's tables, tiny for buffers) is outside it; cFPS shows the full client cost.",
	"- Deferred probes bracket what a library task.defers from Heartbeat/PostSimulation (Loren's server flush thread), so flush and idle work include it.",
	"- sHBwork (Stats.HeartbeatTimeMs) is engine-wide and smoothed, and may count deferred resumes: a higher value is not proven to be that library's work. Compare it with the idle library work line (deferred work included). Context only.",
	"- Constant payloads compress well, rand* ones do not; 1000 a frame is over real per-player budgets, so read KB/s and drain, not peaks.",
	"- GC cannot be forced; warmup and rotation spread it out. SignalBehavior stays Deferred. Loopback network: no latency or loss.",
	"- All five libraries stay loaded whatever Library says, so every run also pays the others' idle per-frame work (see the idle library work line).",
	"- The listener does almost no work, so real games see dispatch overhead as a smaller share of the cost.",
}

return Table
