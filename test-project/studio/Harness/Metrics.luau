--!strict
--!optimize 2
--[[
	Metrics: small numeric helpers shared by bots and the server report.
		Metrics.summarize(samples) -> Summary { n, mean, min, p50, p95, p99, max }
		Metrics.Reservoir.new(capacity) -> bounded uniform sample of an unbounded stream
		Metrics.Series (time series) and trend (least-squares slope)
		Metrics.ms / num / pct / kb formatting
]]

local Metrics = {}

-- type(v) == "table" without narrowing v: a plain typeof() check turns an `any` value into an
-- opaque `table` for the new type solver, and every field read after it becomes `unknown`.
function Metrics.isTable(v: any): boolean
	return type(v) == "table"
end

-- Same for numbers.
function Metrics.isNumber(v: any): boolean
	return type(v) == "number"
end

-- v if it is a number, else 0 (for counters read from client reports).
function Metrics.asNumber(v: any): number
	return if type(v) == "number" then v else 0
end

export type Summary = { n: number, mean: number, min: number, p50: number, p95: number, p99: number, max: number }

local EMPTY: Summary = { n = 0, mean = 0, min = 0, p50 = 0, p95 = 0, p99 = 0, max = 0 }

local function percentile(sorted: { number }, p: number): number
	local n = #sorted
	if n == 0 then
		return 0
	end
	-- Nearest-rank percentile.
	local rank = math.clamp(math.ceil(p / 100 * n), 1, n)
	return sorted[rank]
end
Metrics.percentile = percentile

function Metrics.summarize(samples: { number }): Summary
	local n = #samples
	if n == 0 then
		return table.clone(EMPTY)
	end
	local sorted = table.clone(samples)
	table.sort(sorted)
	local total = 0
	for _, v in sorted do
		total += v
	end
	return {
		n = n,
		mean = total / n,
		min = sorted[1],
		p50 = percentile(sorted, 50),
		p95 = percentile(sorted, 95),
		p99 = percentile(sorted, 99),
		max = sorted[n],
	}
end

-- [[ Reservoir: uniform sample of at most `capacity` values (Algorithm R) ]]

export type Reservoir = {
	capacity: number,
	seen: number,
	values: { number },
	rng: Random,
	add: (self: Reservoir, value: number) -> (),
}

local Reservoir = {}
Reservoir.__index = Reservoir

function Reservoir.new(capacity: number?): Reservoir
	local self = setmetatable({
		capacity = capacity or 20000,
		seen = 0,
		values = {},
		rng = Random.new(12345),
	}, Reservoir)
	return self :: any
end

function Reservoir.add(self: Reservoir, value: number)
	self.seen += 1
	if #self.values < self.capacity then
		table.insert(self.values, value)
	else
		local slot = self.rng:NextInteger(1, self.seen)
		if slot <= self.capacity then
			self.values[slot] = value
		end
	end
end

Metrics.Reservoir = Reservoir

-- [[ Trend: least-squares slope of (t, v) points, in units per second ]]

function Metrics.slope(points: { { t: number, v: number } }): number
	local n = #points
	if n < 2 then
		return 0
	end
	local st, sv, stt, stv = 0, 0, 0, 0
	for _, p in points do
		st += p.t
		sv += p.v
		stt += p.t * p.t
		stv += p.t * p.v
	end
	local denom = n * stt - st * st
	if denom == 0 then
		return 0
	end
	return (n * stv - st * sv) / denom
end

-- [[ Formatting ]]

function Metrics.num(value: number?, decimals: number?): string
	if value == nil then
		return "-"
	end
	if value ~= value then
		return "nan"
	elseif value == math.huge or value == -math.huge then
		return if value > 0 then "inf" else "-inf"
	end
	local d = decimals or 1
	if d == 0 then
		return string.format("%d", math.floor(value + 0.5))
	end
	return string.format("%." .. d .. "f", value)
end

function Metrics.pct(part: number, whole: number): string
	if whole <= 0 then
		return "-"
	end
	return string.format("%.1f%%", part / whole * 100)
end

-- "p50 12.3  p95 20.1  p99 31.0  max 40.2 ms" from a Summary of seconds.
function Metrics.msLine(summary: Summary): string
	if summary.n == 0 then
		return "no samples"
	end
	return string.format(
		"p50 %.1f  p95 %.1f  p99 %.1f  max %.1f ms (n=%d)",
		summary.p50 * 1000,
		summary.p95 * 1000,
		summary.p99 * 1000,
		summary.max * 1000,
		summary.n
	)
end

-- Same, for a summary that is already in milliseconds.
function Metrics.msLineRaw(summary: Summary): string
	if summary.n == 0 then
		return "no samples"
	end
	return string.format(
		"p50 %.1f  p95 %.1f  p99 %.1f  max %.1f ms (n=%d)",
		summary.p50,
		summary.p95,
		summary.p99,
		summary.max,
		summary.n
	)
end

-- Top entries of a count map as "a x3, b x1".
function Metrics.topCounts(counts: { [string]: number }, limit: number?): string
	local list: { { key: string, count: number } } = {}
	for key, count in counts do
		table.insert(list, { key = key, count = count })
	end
	table.sort(list, function(a: { key: string, count: number }, b: { key: string, count: number })
		return a.count > b.count
	end)
	local parts = {}
	for i = 1, math.min(#list, limit or 4) do
		table.insert(parts, string.format("%q x%d", list[i].key, list[i].count))
	end
	return table.concat(parts, ", ")
end

-- Adds to a bounded count map (keys are truncated; at most maxKeys distinct keys, rest -> "(other)").
function Metrics.bump(counts: { [string]: number }, key: string, maxKeys: number?)
	local k = string.sub(key, 1, 90)
	if counts[k] == nil then
		local distinct = 0
		for _ in counts do
			distinct += 1
		end
		if distinct >= (maxKeys or 12) then
			k = "(other)"
		end
	end
	counts[k] = (counts[k] or 0) + 1
end

return Metrics
