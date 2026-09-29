--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OrderPlan = require(ReplicatedStorage.LorenTest.Harness.OrderPlan)
local ClientNet: any = require(ReplicatedStorage.LorenRuntime.ClientNet)
local V2 = require(script.Parent._V2)

local ARM_WAIT = 180
local DONE_WAIT = 30
local BLOB_SENDS = 3
local BLOB_CONTROL_ID = 8

type Round = {
	role: string?,
	roles: { string }?,
	log: { string },
	blobs: { { n: any, len: number } },
	done: boolean,
	exact: number?,
	control: number?,
	problem: string?,
}

local function sameList(got: { string }, want: { string })
	for i = 1, math.max(#got, #want) do
		if got[i] ~= want[i] then
			error(
				string.format(
					"entry %d: expected %s, got %s (%d entries received, %d expected)",
					i,
					if want[i] then string.format("%q", want[i]) else "nothing",
					if got[i] then string.format("%q", got[i]) else "nothing",
					#got,
					#want
				),
				2
			)
		end
	end
end

local function only(list: { string }, needle: string): { string }
	local out: { string } = {}
	for _, line in list do
		if string.find(line, needle, 1, true) then
			table.insert(out, line)
		end
	end
	return out
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local round: Round = { log = {}, blobs = {}, done = false }

	local function joined(): Round
		if round.problem then
			error("the order round did not complete: " .. round.problem, 2)
		end
		return round
	end

	describe("v2 order round (every client at once; OrderService, studio/Harness/OrderPlan)", function()
		it("takes part: collectors, ready, arm, Hold calls, armed, done", function()
			round.problem = "the round test did not finish"
			local Loren = V2.loren()
			local P = Loren.GetService("OrderService")
			local me = Players.LocalPlayer
			local folder = ReplicatedStorage:WaitForChild("OrderFixture", 10)
			expect(folder).never.toBeNil()
			local named: { [string]: Instance? } = {}
			for _, name in { "R1", "R2", "R3" } do
				named[name] = (folder :: Instance):WaitForChild(name, 10)
				expect(named[name]).never.toBeNil()
			end
			local playerGui = me:WaitForChild("PlayerGui", 10)
			local gui = playerGui and playerGui:WaitForChild("OrderFixture", 10)
			expect(gui).never.toBeNil()

			local function nameOf(value: any): string
				if value == nil then
					return "nil"
				end
				for name, inst in named do
					if rawequal(value, inst) then
						return name
					end
				end
				if rawequal(value, gui) then
					return "gui"
				end
				if typeof(value) == "Instance" then
					return "other:" .. (value :: Instance):GetFullName()
				end
				return "value:" .. tostring(value)
			end

			local base = Loren.GetStats()
			local function push(kind: string, tag: any, hasRef: boolean, inst: any, after: any)
				if round.done then
					return
				end
				local now = Loren.GetStats()
				table.insert(
					round.log,
					OrderPlan.entry(
						kind,
						tostring(tag),
						if hasRef then nameOf(inst) else nil,
						if hasRef then tostring(after) else nil,
						now.FramesDropped - base.FramesDropped,
						now.SignalsDropped - base.SignalsDropped
					)
				)
			end

			local signals = P.Signals
			local connections = {
				signals.Seq:Connect(function(...: any)
					local tag, inst, after = ...
					push("Seq", tag, select("#", ...) >= 3, inst, after)
				end),
				signals.Obj:Connect(function(tag: any, inst: any, after: any)
					push("Obj", tag, true, inst, after)
				end),
				signals.Req:Connect(function(tag: any, inst: any, after: any)
					push("Req", tag, true, inst, after)
				end),
				signals.Pos:Connect(function(value: any)
					push("Pos", value, false, nil, nil)
				end),
				signals.Blob:Connect(function(n: any, payload: any)
					table.insert(round.blobs, { n = n, len = if type(payload) == "string" then #payload else -1 })
				end),
				signals.Ctl:Connect(function(command: any, a: any, b: any)
					if command == "arm" then
						round.roles = b
						round.role = a
					elseif command == "done" then
						round.exact = a
						round.control = b
						round.done = true
					end
				end),
			}
			local function stop()
				for _, connection in connections do
					connection:Disconnect()
				end
			end

			P.ClientEvents.Order:Fire("ready", ClientNet._test.state().relSeq)
			Loren.Flush()
			if not V2.waitUntil(function()
				return round.role ~= nil
			end, ARM_WAIT) then
				stop()
				round.problem = "no arm from the server in " .. ARM_WAIT .. " s (did every client reach this spec?)"
				error(round.problem, 0)
			end
			local role, roles = round.role :: string, round.roles :: { string }
			for _, key in OrderPlan.keys(role, roles) do
				P:Hold(key):andThen(function(value: any)
					push("ok", value, false, nil, nil)
				end, function(message: any, info: any)
					local code = if type(info) == "table" then info.Code else "?"
					push("err", tostring(code) .. ":" .. tostring(message), false, nil, nil)
				end)
			end
			P.ClientEvents.Order:Fire("armed")
			Loren.Flush()
			local finished = V2.waitUntil(function()
				return round.done
			end, DONE_WAIT)
			if finished then
				V2.waitUntil(function()
					local exact, control = false, false
					for _, blob in round.blobs do
						exact = exact or blob.n ~= BLOB_CONTROL_ID
						control = control or blob.n == BLOB_CONTROL_ID
					end
					return exact and control
				end, 2)
			end
			stop()
			if not finished then
				round.problem = "no done from the server in " .. DONE_WAIT .. " s after armed"
				error(round.problem, 0)
			end
			round.problem = nil
		end, { timeout = ARM_WAIT + DONE_WAIT + 30 })

		it("got exactly its reliable sequence in order: Fire/FireAll/FireFor/FireExcept, OK/ERR, NOTICE", function()
			local r = joined()
			local want = OrderPlan.expected(r.role :: string, r.roles :: { string })
			expect(#want).toBeGreaterThan(10)
			sameList(r.log, want)
		end)

		it("excluded players got nothing: no entry outside the plan for this role", function()
			local r = joined()
			local want = OrderPlan.expected(r.role :: string, r.roles :: { string })
			local allowed: { [string]: boolean } = {}
			for _, line in want do
				allowed[string.match(line, "^(%S+ %S+)") :: string] = true
			end
			for _, line in r.log do
				local head = string.match(line, "^(%S+ %S+)") :: string
				if not allowed[head] then
					error("received " .. head .. ", which role " .. tostring(r.role) .. " must never get", 0)
				end
			end
		end)

		it("Instance sidecar: hidden and other players' Instances arrive nil without shifting later args", function()
			local r = joined()
			local want = OrderPlan.expected(r.role :: string, r.roles :: { string })
			sameList(only(r.log, " ref="), only(want, " ref="))
		end)

		it("unreliable size limit: the message of exactly 900 B arrived whole; 901 B never went out", function()
			local r = joined()
			expect(typeof(r.exact)).toBe("number")
			expect(typeof(r.control)).toBe("number")
			local exact, control = 0, 0
			for _, blob in r.blobs do
				if blob.n == BLOB_CONTROL_ID then
					control += 1
					expect(blob.len).toBe(r.control)
				else
					expect(type(blob.n) == "number" and blob.n >= 1 and blob.n <= BLOB_SENDS).toBe(true)
					expect(blob.len).toBe(r.exact)
					exact += 1
				end
			end
			if exact == 0 and control > 0 then
				error(
					"the 800 B control messages arrived but no 900 B one did: the engine's unreliable cap is below "
						.. "Loren's UNRELIABLE_SEAL (Constants.luau Limit.UNRELIABLE_SEAL = 900), not a spec problem",
					0
				)
			end
			expect(exact).toBeGreaterThanOrEqual(1)
			expect(exact).toBeLessThanOrEqual(BLOB_SENDS)
			expect(control).toBeLessThanOrEqual(BLOB_SENDS)
		end)
	end)

	describe("v2 pre-HELLO outbox (OrderController)", function()
		it("the reliable Fire before HELLO arrived once, after MANIFEST; the unreliable one never", function()
			local probe = V2.loren().GetController("OrderController").Probe
			expect(probe.connectError).toBeNil()
			expect(V2.waitUntil(function()
				return #probe.early > 0
			end, 5)).toBe(true)
			task.wait(0.2)
			expect(#probe.early).toBe(1)
			expect(probe.early[1].kind).toBe("early")
			expect(probe.early[1].uid).toBe(Players.LocalPlayer.UserId)
			expect(probe.uearly).toBe(0)
		end, { timeout = 10 })
	end)
end
