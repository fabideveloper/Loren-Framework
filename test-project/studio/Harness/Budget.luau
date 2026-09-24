--!strict
--!optimize 2
--[[
	Budget: paces the check specs' calls so no client exceeds 1.5.1's fixed 50 calls/s window.

	1.5.1 silently drops call 51+ inside a 1 s window (the client then waits 10 s for a Timeout),
	which would turn honest check specs into false failures. Specs call Budget.take(n) before
	firing n calls; it yields until n more calls fit in LIMIT per WINDOW seconds (sliding window,
	with margin for arrival jitter). Harmless on 2.0 and raw.
]]

local Budget = {}

local LIMIT = 35
local WINDOW = 1.25

local stamps: { number } = {}

local function prune(now: number)
	local keep = 0
	for i = 1, #stamps do
		if now - stamps[i] < WINDOW then
			keep += 1
			stamps[keep] = stamps[i]
		end
	end
	for i = #stamps, keep + 1, -1 do
		stamps[i] = nil
	end
end

function Budget.take(count: number?)
	local n = math.clamp(math.floor(count or 1), 1, LIMIT)
	while true do
		local now = os.clock()
		prune(now)
		if #stamps + n <= LIMIT then
			for _ = 1, n do
				table.insert(stamps, now)
			end
			return
		end
		-- Wait until enough of the oldest stamps leave the window.
		local oldest = stamps[#stamps + n - LIMIT] or stamps[1]
		task.wait(math.max(0.03, oldest + WINDOW - now + 0.01))
	end
end

Budget.LIMIT = LIMIT

return Budget
