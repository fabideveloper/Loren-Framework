local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Loren = require(ReplicatedStorage.Shared.Loren)

local BroadcastService = {
	Dependencies = {},
	Client = {},
	Signals = { "Tick" },
	Middleware = {},
	IgniteCount = 0,
	BurnCount = 0,
}

local index = 0
local ticking = nil

function BroadcastService.Client:Ping(player)
	return true
end

-- Fires one Tick(i, os.clock(), serverTime) to every client and returns i.
function BroadcastService:FireTick()
	index += 1
	self.Signals.Tick:FireAll(index, os.clock(), workspace:GetServerTimeNow())
	return index
end

function BroadcastService:GetIndex()
	return index
end

-- Fires Tick at `rate` per second (Heartbeat accumulator). Returns the first index it will use.
function BroadcastService:StartTicking(rate)
	self:StopTicking()
	local first = index + 1
	local carry = 0
	local maxPerFrame = math.max(2, rate * 0.25) -- a server hitch must not turn into one giant burst
	ticking = RunService.Heartbeat:Connect(function(dt)
		carry = math.min(carry + dt * rate, maxPerFrame)
		while carry >= 1 do
			carry -= 1
			self:FireTick()
		end
	end)
	return first
end

-- Stops ticking and returns the last index fired.
function BroadcastService:StopTicking()
	if ticking then
		ticking:Disconnect()
		ticking = nil
	end
	return index
end

-- Fires n Ticks in the same frame. Returns (first, last).
function BroadcastService:FireBurst(n)
	local first = index + 1
	for _ = 1, n do
		self:FireTick()
	end
	return first, index
end

function BroadcastService:LorenIgnite()
	self.IgniteCount += 1
	self.IgnitedOnServer = Loren.IsServer
end

function BroadcastService:LorenBurn()
	self.BurnCount += 1
end

return BroadcastService
