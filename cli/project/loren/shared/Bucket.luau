--!strict
--!optimize 2
--[[
	Bucket: time-based token bucket (owner lane: limiter). Spec: IMPLEMENTATION.md section 3.2.

	Used by the server limits (server/Limits.luau) and by the client mirror (ClientNet), so both
	sides run the same refill math. A bucket is a plain record; the caller passes `now`
	(os.clock()) so nothing here reads a clock, allocates or yields.

	Refill: tokens = min(burst, tokens + (now - stamp) * rate); stamp = now.
	A `now` older than the stamp refills nothing and keeps the stamp (os.clock() is monotonic, but
	callers may pass a `now` captured a moment earlier; this keeps the math exact for them).
	Costs may exceed 1 (bytes, message counts). A failed take still stores the refilled tokens.
]]

export type Bucket = { tokens: number, stamp: number, rate: number, burst: number }

local Bucket = {}

-- Starts full (tokens = burst).
function Bucket.new(rate: number, burst: number, now: number): Bucket
	return { tokens = burst, stamp = now, rate = rate, burst = burst }
end

-- Refill, then take `cost` tokens if there are at least that many. Returns whether it took them.
@native
local function take(b: Bucket, cost: number, now: number): boolean
	local tokens = b.tokens
	local dt = now - b.stamp
	if dt > 0 then
		tokens = math.min(b.burst, tokens + dt * b.rate)
		b.stamp = now
	end
	if tokens >= cost then
		b.tokens = tokens - cost
		return true
	end
	b.tokens = tokens
	return false
end
Bucket.take = take

-- Refill, then report whether `cost` tokens are available. Takes nothing.
function Bucket.can(b: Bucket, cost: number, now: number): boolean
	local tokens = b.tokens
	local dt = now - b.stamp
	if dt > 0 then
		tokens = math.min(b.burst, tokens + dt * b.rate)
		b.tokens = tokens
		b.stamp = now
	end
	return tokens >= cost
end

-- Refund `cost` tokens, capped at burst.
function Bucket.put(b: Bucket, cost: number): ()
	b.tokens = math.min(b.burst, b.tokens + cost)
end

return table.freeze(Bucket)
