--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage:WaitForChild("LorenTest"):WaitForChild("Harness")
local Metrics = require(Harness:WaitForChild("Metrics"))

local Report = {}

local PREFIX = "(LORENঌ - TEST) "
local num = Metrics.num
local isTable = Metrics.isTable
local asNumber = Metrics.asNumber

-- Prints lines as a few Output entries (one entry per 40 lines).
function Report.print(lines: { string })
	local chunk: { string } = {}
	for _, line in lines do
		table.insert(chunk, line)
		if #chunk >= 40 then
			print(PREFIX .. table.concat(chunk, "\n"))
			table.clear(chunk)
		end
	end
	if #chunk > 0 then
		print(PREFIX .. table.concat(chunk, "\n"))
	end
end

function Report.say(text: string)
	print(PREFIX .. text)
end

function Report.rule(title: string): string
	return "===== " .. title .. " " .. string.rep("=", math.max(3, 60 - #title))
end

local function summaryField(value: any): Metrics.Summary
	if isTable(value) and Metrics.isNumber(value.n) then
		return value :: any
	end
	return { n = 0, mean = 0, min = 0, p50 = 0, p95 = 0, p99 = 0, max = 0 }
end

function Report.calls(c: any): string
	if not isTable(c) then
		return "calls: none"
	end
	local sent = asNumber(c.sent)
	local line = string.format(
		"calls %d ok %d (%s) timeout %d error %d wrong %d unsettled %d",
		sent,
		asNumber(c.ok),
		Metrics.pct(asNumber(c.ok), sent),
		asNumber(c.timeouts),
		asNumber(c.errors),
		asNumber(c.wrong),
		asNumber(c.unsettled)
	)
	if Metrics.isNumber(c.skipped) and c.skipped > 0 then
		line ..= string.format(" skipped(in-flight cap) %d", c.skipped)
	end
	if typeof(c.achievedRate) == "number" then
		line ..= string.format(" | %s/s", num(c.achievedRate))
	end
	line ..= " | rtt " .. Metrics.msLineRaw(summaryField(c.rttMs))
	return line
end

function Report.reasons(c: any): string?
	if not isTable(c) or not isTable(c.reasons) or next(c.reasons) == nil then
		return nil
	end
	return "rejections: " .. Metrics.topCounts(c.reasons, 4)
end

function Report.ticks(s: any, label: string?): string
	if not isTable(s) then
		return (label or "ticks") .. ": none"
	end
	local head: string
	if Metrics.isNumber(s.expected) then
		head = string.format(
			"%s %d/%d lost %d reordered %d dup %d",
			label or "ticks",
			asNumber(s.received),
			s.expected,
			asNumber(s.lost),
			asNumber(s.reordered),
			asNumber(s.duplicates)
		)
	else
		head = string.format(
			"%s received %d gaps %d reordered %d dup %d",
			label or "signal",
			asNumber(s.received),
			asNumber(s.gaps),
			asNumber(s.reordered),
			asNumber(s.duplicates)
		)
	end
	if asNumber(s.malformed) > 0 then
		head ..= string.format(" malformed %d", s.malformed)
	end
	local oneWay = summaryField(s.oneWayMs)
	if oneWay.n > 0 then
		head ..= string.format(" | one-way p50 %s p99 %s ms", num(oneWay.p50), num(oneWay.p99))
	end
	return head
end

function Report.exploit(e: any): { string }
	local lines = {}
	if not isTable(e) then
		return { "exploiter: no summary" }
	end
	local fired = {}
	if isTable(e.fired) then
		for category, count in e.fired do
			table.insert(fired, category .. " " .. tostring(count))
		end
	end
	table.sort(fired)
	table.insert(
		lines,
		string.format("fired %d (%s/s): %s", asNumber(e.totalFired), num(e.firesPerSecond), table.concat(fired, ", "))
	)
	table.insert(lines, "targets: " .. (if isTable(e.targets) then table.concat(e.targets, ", ") else "?"))
	table.insert(
		lines,
		string.format(
			"client-side send errors %d%s | invokes %d (errors %d) | ids learned from handshake: %s",
			asNumber(e.sendErrors),
			if e.firstSendError then " (first: " .. string.sub(tostring(e.firstSendError), 1, 80) .. ")" else "",
			asNumber(e.invokes),
			asNumber(e.invokeErrors),
			tostring(e.learnedIds)
		)
	)
	local probes: any = e.probes or {}
	table.insert(
		lines,
		string.format(
			"proxy probes with bad input: sent %d rejected %d refused-locally %d ACCEPTED %d%s",
			asNumber(probes.sent),
			asNumber(probes.rejected),
			asNumber(probes.threw),
			asNumber(probes.acceptedBad),
			if isTable(probes.labels) and #probes.labels > 0 then " " .. table.concat(probes.labels, ", ") else ""
		)
	)
	local crafted: any = e.crafted or {}
	table.insert(
		lines,
		string.format(
			"crafted packets: sent %d replies %d ACCEPTED-BAD %d%s",
			asNumber(crafted.sent),
			asNumber(crafted.replies),
			asNumber(crafted.acceptedBad),
			if isTable(crafted.labels) and #crafted.labels > 0 then " " .. table.concat(crafted.labels, ", ") else ""
		)
	)
	if asNumber(e.internalErrors) > 0 then
		table.insert(
			lines,
			string.format("bot internal errors %d (first: %s)", e.internalErrors, tostring(e.firstInternalError))
		)
	end
	return lines
end

function Report.clientSide(s: any): string?
	local c: any = s and s.client
	if not isTable(c) then
		return nil
	end
	return string.format(
		"client frame %s | client KB/s send %s recv %s | gcinfo %s KB",
		Metrics.msLineRaw(summaryField(c.frameMs)),
		num(c.sendKbps),
		num(c.recvKbps),
		num(c.gcKb, 0)
	)
end

function Report.memory(m: any): string
	return string.format(
		"memory total %s -> %s MB (max %s) | Lua heap %s -> %s MB (max %s, trend %s MB/min) | gcinfo %s -> %s KB",
		num(m.startTotalMb),
		num(m.endTotalMb),
		num(m.maxTotalMb),
		num(m.startHeapMb),
		num(m.endHeapMb),
		num(m.maxHeapMb),
		num(m.heapTrendMbPerMin, 2),
		num(m.startGcKb, 0),
		num(m.endGcKb, 0)
	)
end

function Report.handlers(stats: { [string]: any }): { string }
	local names = {}
	local total = { calls = 0, errors = 0, denied = 0, time = 0, maxTime = 0 }
	for name, s in stats do
		table.insert(names, name)
		total.calls += s.calls
		total.errors += s.errors
		total.denied += s.denied
		total.time += s.time
		total.maxTime = math.max(total.maxTime, s.maxTime)
	end
	table.sort(names)
	local lines = {
		string.format(
			"handlers %d calls, %d errors, %d middleware denials | time total %s ms, mean %s us, max %s us",
			total.calls,
			total.errors,
			total.denied,
			num(total.time * 1000, 2),
			num(if total.calls > 0 then total.time / total.calls * 1e6 else 0),
			num(total.maxTime * 1e6)
		),
	}
	local parts = {}
	for _, name in names do
		local s = stats[name]
		if s.calls > 0 or s.denied > 0 then
			table.insert(
				parts,
				string.format(
					"%s %d%s%s",
					name,
					s.calls,
					if s.denied > 0 then " (denied " .. s.denied .. ")" else "",
					if s.errors > 0 then " (errors " .. s.errors .. ")" else ""
				)
			)
		end
	end
	if #parts > 0 then
		table.insert(lines, "  per method: " .. table.concat(parts, ", "))
	end
	return lines
end

function Report.logs(logs: any, durationS: number): string
	local line = string.format(
		"server Output during load: %d warnings, %d errors, %d other (%s warnings/min)",
		logs.warnings,
		logs.errors,
		logs.other,
		num(logs.warnings / math.max(durationS, 1) * 60)
	)
	if next(logs.top) ~= nil then
		line ..= "\n  top: " .. Metrics.topCounts(logs.top, 3)
	end
	return line
end

return Report
