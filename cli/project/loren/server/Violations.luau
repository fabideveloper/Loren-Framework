--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Runtime = ReplicatedStorage.LorenRuntime

local C = require(Runtime.Constants)
local Types = require(Runtime.Types)
local Log = require(Runtime.Log)

type Config = Types.Config

export type PlayerViolations = {
	score: number, -- decayed lazily: value at `stamp`
	stamp: number,
	total: number, -- violations recorded for this player
	kicked: boolean, -- KickScore reached (Kick called once)
	pending: { number }, -- per C.Violation kind, since the last OnViolation call
	npending: number, -- sum of pending
	lastKind: number, -- last recorded C.Violation kind (0 = none)
	nextNotify: number, -- earliest time of the next OnViolation call
	winViol: { number }, -- per C.Violation kind, current summary window
	winDrop: { number }, -- per C.Drop kind, current summary window
	dirty: boolean, -- a window counter changed since the last summary
	nextSummary: number, -- earliest time of the next summary line
}

export type Handler = (player: Player, kind: string, score: number, counts: { [string]: number }) -> ()

local L = C.Limit
local VIOLATION_NAME = C.ViolationName
local VIOLATION_WEIGHT = C.ViolationWeight
local DROP_NAME = C.DropName
local NUM_VIOLATIONS = #C.ViolationName
local NUM_DROPS = C.DROP_KINDS
local SCORE_DECAY = L.SCORE_DECAY
local NOTIFY_INTERVAL = L.ON_VIOLATION_INTERVAL
local SUMMARY_INTERVAL = L.SUMMARY_INTERVAL
local KICK_MESSAGE = C.PREFIX .. "Disconnected: invalid network traffic"

-- Module state (restored by _reset)
local kickScore: number | false = false
local handlers: { Handler } = {}
local totalViolations = 0
local totalDrops: { number } = table.create(NUM_DROPS, 0)

local Violations = {}

local function decayed(pv: PlayerViolations, now: number): number
	local dt = now - pv.stamp
	if dt <= 0 then
		return pv.score
	end
	local score = pv.score - dt * SCORE_DECAY
	return if score > 0 then score else 0
end

local function runHandler(fn: Handler, player: Player, kind: string, score: number, counts: { [string]: number })
	debug.resetmemorycategory()
	local ok, err = pcall(fn :: any, player, kind, score, counts)
	if not ok then
		Log.warnf("OnViolation handler failed: %s", tostring(err))
	end
end

-- Calls every handler (each on its own thread, under pcall) with the pending counts.
local function notify(player: Player, pv: PlayerViolations, kind: number, score: number, now: number)
	local counts: { [string]: number } = {}
	local pending = pv.pending
	for k = 1, NUM_VIOLATIONS do
		local n = pending[k]
		if n > 0 then
			counts[VIOLATION_NAME[k]] = n
			pending[k] = 0
		end
	end
	pv.npending = 0
	pv.nextNotify = now + NOTIFY_INTERVAL
	table.freeze(counts)
	local kindName = VIOLATION_NAME[kind] or "Unknown"
	for i = 1, #handlers do
		task.spawn(runHandler, handlers[i], player, kindName, score, counts)
	end
end

local function kick(player: Player)
	player:Kick(KICK_MESSAGE)
end

function Violations.configure(cfg: Config): ()
	local k = cfg.KickScore
	kickScore = if type(k) == "number" and k > 0 then k else false
end

function Violations.newPlayer(now: number): PlayerViolations
	return {
		score = 0,
		stamp = now,
		total = 0,
		kicked = false,
		pending = table.create(NUM_VIOLATIONS, 0),
		npending = 0,
		lastKind = 0,
		nextNotify = now,
		winViol = table.create(NUM_VIOLATIONS, 0),
		winDrop = table.create(NUM_DROPS, 0),
		dirty = false,
		nextSummary = now + SUMMARY_INTERVAL,
	}
end

-- One violation of `kind` (C.Violation). Called once per offending frame; the frame is dropped.
function Violations.record(player: Player, pv: PlayerViolations, kind: number, now: number): ()
	local weight = VIOLATION_WEIGHT[kind]
	if weight == nil then
		return -- not a C.Violation kind
	end
	local score = decayed(pv, now) + weight
	pv.score = score
	if now > pv.stamp then
		pv.stamp = now
	end
	pv.total += 1
	totalViolations += 1
	pv.winViol[kind] += 1
	pv.dirty = true
	pv.pending[kind] += 1
	pv.npending += 1
	pv.lastKind = kind

	if #handlers > 0 and now >= pv.nextNotify then
		notify(player, pv, kind, score, now)
	end
	if kickScore and not pv.kicked and score >= kickScore then
		pv.kicked = true
		pcall(kick, player)
	end
end

function Violations.drop(pv: PlayerViolations?, kind: number, n: number): ()
	if kind < 1 or kind > NUM_DROPS or kind % 1 ~= 0 or not (n > 0) then
		return -- not a C.Drop kind, or nothing to count
	end
	totalDrops[kind] += n
	if pv then
		pv.winDrop[kind] += n
		pv.dirty = true
	end
end

-- Builds the summary text (called by Log only when the budget allows).
local function buildSummary(userId: number, pv: PlayerViolations, score: number): string
	local parts = table.create(NUM_DROPS)
	local winDrop = pv.winDrop
	for k = 1, NUM_DROPS do
		local n = winDrop[k]
		if n > 0 then
			table.insert(parts, DROP_NAME[k] .. " " .. n)
		end
	end
	local drops = table.concat(parts, ", ")
	table.clear(parts)
	local winViol = pv.winViol
	for k = 1, NUM_VIOLATIONS do
		local n = winViol[k]
		if n > 0 then
			table.insert(parts, VIOLATION_NAME[k] .. " " .. n)
		end
	end
	local viol = table.concat(parts, ", ")
	local body
	if drops ~= "" and viol ~= "" then
		body = drops .. "; violations " .. viol
	elseif viol ~= "" then
		body = "violations " .. viol
	else
		body = drops
	end
	return string.format("uid=%d last %ds: %s (score %.1f)", userId, SUMMARY_INTERVAL, body, score)
end

-- Once per player per flush: the throttled summary line and any OnViolation counts still pending.
function Violations.tick(player: Player, pv: PlayerViolations, now: number): ()
	if pv.npending > 0 and now >= pv.nextNotify and #handlers > 0 then
		notify(player, pv, pv.lastKind, decayed(pv, now), now)
	end
	if now < pv.nextSummary then
		return
	end
	-- The window closes every SUMMARY_INTERVAL; a line is printed only if something was counted.
	pv.nextSummary = now + SUMMARY_INTERVAL
	if not pv.dirty then
		return
	end
	local uid = player.UserId
	Log.warnWith(buildSummary, if type(uid) == "number" then uid else 0, pv, decayed(pv, now))
	local winViol, winDrop = pv.winViol, pv.winDrop
	for k = 1, NUM_VIOLATIONS do
		winViol[k] = 0
	end
	for k = 1, NUM_DROPS do
		winDrop[k] = 0
	end
	pv.dirty = false
end

-- Loren.OnViolation (server, any time).
function Violations.onViolation(fn: Handler): ()
	if type(fn) ~= "function" then
		error(C.PREFIX .. "OnViolation expects a function, got " .. typeof(fn), 3)
	end
	table.insert(handlers, fn)
end

-- Server-wide totals for GetStats (fresh table).
function Violations.totals(): { violations: number, drops: { number } }
	return { violations = totalViolations, drops = table.clone(totalDrops) }
end

function Violations._reset(): ()
	kickScore = false
	table.clear(handlers)
	totalViolations = 0
	for k = 1, NUM_DROPS do
		totalDrops[k] = 0
	end
end

Violations._test = table.freeze({
	buildSummary = buildSummary,
	kickScore = function(): number | false
		return kickScore
	end,
	handlerCount = function(): number
		return #handlers
	end,
})

return table.freeze(Violations)
