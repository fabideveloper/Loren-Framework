--!strict
--!optimize 2

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
