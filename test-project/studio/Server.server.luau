--!strict
--!optimize 2
--[[
	LorenTest server. For plans with "check" on 2.0 it first runs specs/unit (offline) and resets
	the runtime; then it boots Loren (2.0 or 1.5.1, auto-detected) with the fixture Services, or the
	raw RemoteEvent baseline, waits for the clients, runs ReplicatedStorage.TestConfig.Scenario and
	prints the REPORT to this (server) Output window.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Harness = ReplicatedStorage:WaitForChild("LorenTest"):WaitForChild("Harness")
local Env = require(Harness:WaitForChild("Env"))
local Metrics = require(Harness:WaitForChild("Metrics"))
local ServerHarness = ServerStorage:WaitForChild("LorenTest"):WaitForChild("ServerHarness")
local Backend = require(ServerHarness:WaitForChild("Backend"))
local Coordinator = require(ServerHarness:WaitForChild("Coordinator"))
local Report = require(ServerHarness:WaitForChild("Report"))
local Scenarios = require(ServerHarness:WaitForChild("Scenarios"))

local config = Env.config()

Report.print({
	Report.rule("LorenTest"),
	string.format(
		"runtime %s | Scenario %s | Duration %s s | Rate %s/s | PayloadSize %d B | Clients %d",
		Env.runtime,
		config.Scenario,
		tostring(config.Duration),
		Metrics.num(config.Rate, 0),
		config.PayloadSize,
		config.Clients
	),
	"Set the attributes on ReplicatedStorage.TestConfig before pressing Play. Scenarios: "
		.. table.concat(Env.SCENARIOS, ", "),
})

Coordinator.init()

-- 2.0 unit specs run before the fixtures boot, then Loren.Testing.Reset() (IMPLEMENTATION section 10).
Scenarios.beforeBoot(config)

-- Handler instrumentation only for load scenarios: "check" runs the fixtures untouched.
Backend.boot(config.Scenario ~= "check")
if Env.boot.ok then
	Report.say(string.format("server booted %s in %.0f ms", Env.runtimeLabel(), Env.boot.ms))
else
	Report.say("server boot FAILED: " .. tostring(Env.boot.error))
end
if Env.note then
	Report.say("note: " .. Env.note)
end

if not Env.isRunMode then
	local players
	if config.Clients > 0 then
		Report.say(string.format("waiting for %d client(s) (TestConfig.Clients)", config.Clients))
		players = Coordinator.waitForClients(config.Clients, 120, 15)
	else
		-- Clients = 0 (auto): start 3 s after the last client joined, whatever the count.
		Report.say("waiting for clients (auto: starts 3 s after the last one joins)")
		players = Coordinator.waitForClients(math.huge, 120, 3)
	end
	Report.say(string.format("%d client(s) ready, starting %s", #players, config.Scenario))
end

Scenarios.run(config)
