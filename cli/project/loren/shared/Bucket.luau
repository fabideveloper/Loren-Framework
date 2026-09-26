--!strict
--!optimize 2

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
