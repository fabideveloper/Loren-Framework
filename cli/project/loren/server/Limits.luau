--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Runtime = ReplicatedStorage.LorenRuntime

local C = require(Runtime.Constants)
local Types = require(Runtime.Types)
local Bucket = require(Runtime.Bucket)

type Config = Types.Config
type Bucket = Bucket.Bucket

export type PlayerLimits = {
	frame: Bucket, -- reliable channel frames
	uframe: Bucket, -- unreliable channel frames
	bytes: Bucket, -- admission cost, both channels, plus sidecar cost
	msgs: Bucket, -- messages (nmsg per admitted frame)
	badReq: Bucket, -- BadRequest replies
	rtok: { [number]: number }, -- route -> tokens (sparse; nil = never used = full)
	rstamp: { [number]: number }, -- route -> last refill time
	rlNext: { [number]: number }, -- route -> earliest time of the next RateLimited reply
}

local D = C.Default
local RL_REPLY_INTERVAL = C.Limit.RL_REPLY_INTERVAL
local BR_REPLY_RATE = C.Limit.BR_REPLY_RATE
local BR_REPLY_BURST = 16

local bucketNew = Bucket.new
local bucketTake = Bucket.take
local bucketCan = Bucket.can

-- Configured rates (require-time values = C.Default; restored by _reset)
local frameRate: number = D.FrameRate
local frameBurst: number = D.FrameBurst
local byteRate: number = D.ByteRate
local byteBurst: number = D.ByteBurst
local msgRate: number = D.MessageRate
local msgBurst: number = D.MessageBurst

local Limits = {}

-- Reads the admission rates from the resolved config (server boot step 5, before any player).
function Limits.configure(cfg: Config): ()
	frameRate = cfg.FrameRate
	frameBurst = cfg.FrameBurst
	byteRate = cfg.ByteRate
	byteBurst = cfg.ByteBurst
	msgRate = cfg.MessageRate
	msgBurst = cfg.MessageBurst
end

-- One record per player (Outbox.addPlayer). Every bucket starts full.
function Limits.newPlayer(now: number): PlayerLimits
	return {
		frame = bucketNew(frameRate, frameBurst, now),
		uframe = bucketNew(frameRate, frameBurst, now),
		bytes = bucketNew(byteRate, byteBurst, now),
		msgs = bucketNew(msgRate, msgBurst, now),
		badReq = bucketNew(BR_REPLY_RATE, BR_REPLY_BURST, now),
		rtok = {},
		rstamp = {},
		rlNext = {},
	}
end

@native
local function admitFrame(pl: PlayerLimits, unreliable: boolean, cost: number, nmsg: number, now: number): boolean
	local fb = if unreliable then pl.uframe else pl.frame
	local bb = pl.bytes
	local mb = pl.msgs
	local okFrame = bucketCan(fb, 1, now)
	local okBytes = bucketCan(bb, cost, now)
	local okMsgs = bucketCan(mb, nmsg, now)
	if okFrame and okBytes and okMsgs then
		fb.tokens -= 1
		bb.tokens -= cost
		mb.tokens -= nmsg
		return true
	end
	return false
end
Limits.admitFrame = admitFrame

-- Byte bucket only: the sidecar cost after walkSidecar (section 4.10 step a).
function Limits.chargeBytes(pl: PlayerLimits, cost: number, now: number): boolean
	return bucketTake(pl.bytes, cost, now)
end

-- Per-route bucket (section 4.10 steps b.6/b.7). First use starts at `burst`.
@native
local function takeRoute(pl: PlayerLimits, route: number, rate: number, burst: number, now: number): boolean
	local rtok = pl.rtok
	local rstamp = pl.rstamp
	local tokens = rtok[route]
	if tokens == nil then
		tokens = burst
		rstamp[route] = now
	else
		local dt = now - rstamp[route]
		if dt > 0 then
			tokens = math.min(burst, tokens + dt * rate)
			rstamp[route] = now
		end
	end
	if tokens >= 1 then
		rtok[route] = tokens - 1
		return true
	end
	rtok[route] = tokens
	return false
end
Limits.takeRoute = takeRoute

-- At most one RateLimited reply per route per player per RL_REPLY_INTERVAL seconds.
function Limits.allowRateLimitedReply(pl: PlayerLimits, route: number, now: number): boolean
	local rlNext = pl.rlNext
	local nextAt = rlNext[route]
	if nextAt ~= nil and now < nextAt then
		return false
	end
	rlNext[route] = now + RL_REPLY_INTERVAL
	return true
end

-- BadRequest replies: BR_REPLY_RATE per second per player, burst BR_REPLY_BURST.
function Limits.allowBadRequestReply(pl: PlayerLimits, now: number): boolean
	return bucketTake(pl.badReq, 1, now)
end

function Limits._reset(): ()
	frameRate = D.FrameRate
	frameBurst = D.FrameBurst
	byteRate = D.ByteRate
	byteBurst = D.ByteBurst
	msgRate = D.MessageRate
	msgBurst = D.MessageBurst
end

Limits._test = table.freeze({
	-- The admission settings newPlayer uses now.
	settings = function(): { [string]: number }
		return {
			FrameRate = frameRate,
			FrameBurst = frameBurst,
			ByteRate = byteRate,
			ByteBurst = byteBurst,
			MessageRate = msgRate,
			MessageBurst = msgBurst,
		}
	end,
	BR_REPLY_BURST = BR_REPLY_BURST,
})

return table.freeze(Limits)
