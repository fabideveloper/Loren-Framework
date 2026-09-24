--!strict
--[[
	Helpers for specs/v2/server (not a spec: the runner only collects "*.spec" modules).

	Server specs test through the public API: the Loren facade and the V2Service module. Most network
	behavior is driven by the clients' v2 specs, which run at the same time as these; the server side
	then waits for the evidence V2Service.Probe records. Every evidence wait of the run shares one
	budget, so a client that never runs its v2 specs costs EVIDENCE_BUDGET seconds once, not per test.
]]

local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Env = require(ReplicatedStorage.LorenTest.Harness.Env)

local V2 = {}

V2.EVIDENCE_BUDGET = 240 -- seconds, shared by every evidence wait of this run
V2.TEST_TIMEOUT = V2.EVIDENCE_BUDGET + 30 -- runner timeout for a test that waits for evidence
V2.HEX8 = "^%x%x%x%x%x%x%x%x$"

local deadline: number? = nil

function V2.loren(): any
	return Env.Loren
end

function V2.service(): any
	return Env.service("V2Service")
end

function V2.probe(): any
	return V2.service().Probe
end

-- Clients that could produce evidence (Run mode and "Clients = 0" have none: evidence tests skip).
function V2.hasPlayers(): boolean
	return #Players:GetPlayers() > 0
end

-- Yields until predicate() is truthy; raises `what` when the shared budget runs out.
function V2.await(what: string, predicate: () -> any, maxSeconds: number?)
	local now = os.clock()
	if deadline == nil then
		deadline = now + V2.EVIDENCE_BUDGET
	end
	local limit = math.min(deadline :: number, now + (maxSeconds or V2.EVIDENCE_BUDGET))
	while not predicate() do
		if os.clock() >= limit then
			error("no evidence in time: " .. what .. " (did the clients run specs/v2/client?)", 0)
		end
		task.wait(0.1)
	end
end

-- The first Output line (server log history) that contains every needle (plain find), or nil.
function V2.logLine(...: string): string?
	local needles = { ... }
	for _, entry in LogService:GetLogHistory() do
		local message = entry.message
		local all = true
		for _, needle in needles do
			if not string.find(message, needle, 1, true) then
				all = false
				break
			end
		end
		if all then
			return message
		end
	end
	return nil
end

function V2.count(map: { [string]: number }, key: string): number
	return map[key] or 0
end

-- The ManifestMember named `name` of `kind` (Constants.Kind) in V2Service, or nil.
function V2.member(model: any, name: string, kind: number): any
	for _, service in model.services do
		if service.name == "V2Service" then
			for _, member in service.members do
				if member.name == name and member.kind == kind then
					return member
				end
			end
		end
	end
	return nil
end

return V2
