--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Harness = ReplicatedStorage:WaitForChild("LorenTest"):WaitForChild("Harness")
local Env = require(Harness:WaitForChild("Env"))
local CallKit = require(script.Parent:WaitForChild("CallKit"))

local CallSpammer = {}
CallSpammer.__index = CallSpammer

export type Options = { rate: number, payloadSize: number?, mix: string?, maxInFlight: number? }

export type CallSpammer = {
	kit: CallKit.CallKit,
	rate: number,
	maxInFlight: number,
	skipped: number,
	connection: RBXScriptConnection?,
	startedAt: number,
	stoppedAt: number?,
	start: (self: CallSpammer) -> (),
	stop: (self: CallSpammer) -> (),
	waitIdle: (self: CallSpammer, timeout: number) -> boolean,
	summary: (self: CallSpammer) -> { [string]: any },
}

function CallSpammer.new(proxies: { [string]: any }, options: Options): CallSpammer
	local self = setmetatable({
		kit = CallKit.new(proxies, options.payloadSize, options.mix),
		rate = math.max(0.1, options.rate),
		maxInFlight = options.maxInFlight or 1024,
		skipped = 0,
		connection = nil,
		startedAt = 0,
		stoppedAt = nil,
	}, CallSpammer)
	return self :: any
end

function CallSpammer.start(self: CallSpammer)
	if self.connection then
		return
	end
	self.startedAt = os.clock()
	self.stoppedAt = nil
	local carry = 0
	local maxPerFrame = math.max(2, self.rate * 0.25) -- a client hitch must not become one burst
	self.connection = RunService.Heartbeat:Connect(function(dt: number)
		carry = math.min(carry + dt * self.rate, maxPerFrame)
		while carry >= 1 do
			carry -= 1
			if self.kit.inFlight >= self.maxInFlight then
				self.skipped += 1
			else
				self.kit:fire(nil)
			end
		end
	end)
end

function CallSpammer.stop(self: CallSpammer)
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
		self.stoppedAt = os.clock()
	end
end

function CallSpammer.waitIdle(self: CallSpammer, timeout: number): boolean
	return Env.waitUntil(function()
		return self.kit.inFlight <= 0
	end, timeout, 0.1)
end

function CallSpammer.summary(self: CallSpammer): { [string]: any }
	local summary: { [string]: any } = self.kit:summary() :: any
	local duration = (self.stoppedAt or os.clock()) - self.startedAt
	summary.durationS = duration
	summary.achievedRate = if duration > 0 then summary.sent / duration else 0
	summary.skipped = self.skipped
	return summary
end

return CallSpammer
