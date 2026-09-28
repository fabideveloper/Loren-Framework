--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Env = require(ReplicatedStorage.LorenTest.Harness.Env)
local C = require(ReplicatedStorage.LorenRuntime.Constants)
local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local noPlayers = not V2.hasPlayers()
	local evidence = { skip = noPlayers, timeout = V2.TEST_TIMEOUT }

	local function probe(): any
		return Env.service("OrderService").Probe
	end

	-- The pre-HELLO fires run only when LorenBurn saw Scenario check/all (see OrderService).
	local loaded, early = pcall(probe)
	local earlyEvidence = {
		skip = noPlayers or not loaded or early.earlyArmed ~= true,
		timeout = V2.TEST_TIMEOUT,
	}

	describe("v2 pre-HELLO outbox (OrderService, before each HELLO)", function()
		it("a reliable Fire is queued; an unreliable one is dropped and counted (SignalsDropped +1)", function()
			local early = probe().early
			for _, player in Players:GetPlayers() do
				local record = early[player]
				expect(record).never.toBeNil()
				expect(record.error).toBeNil()
				expect(record.helloed).toBe(false) -- fired before the HELLO: the pre-HELLO path ran
				expect(record.dropDelta).toBe(1)
			end
		end, earlyEvidence)
	end)

	describe("v2 order round (driven by specs/v2/client/Order)", function()
		it("ran every step for every player, with every Hold call in place and no failed Fire", function()
			local p = probe()
			V2.await("the order round (every client's Order spec sent ready and armed)", function()
				return p.done
			end)
			expect(p.errors).toEqual({})
			expect(p.guiMissing).toEqual({})
			local roles = 0
			for _ in p.players do
				roles += 1
			end
			expect(roles).toBe(#Players:GetPlayers())
		end, evidence)

		it("unreliable size limit: exactly 900 B goes out; 901 B raises, queues nothing, counts nothing", function()
			local p = probe()
			V2.await("the order round", function()
				return p.done
			end)
			local blob = p.blob
			expect(blob).never.toBeNil()
			expect(typeof(blob.exact)).toBe("number")
			expect(blob.exactErrors).toEqual({})
			expect(blob.sent).toBe(Env.service("OrderService").BlobSends)
			expect(blob.controlErrors).toEqual({}) -- the 800 B control messages
			expect(blob.controlSent).toBe(Env.service("OrderService").BlobSends)
			local limit = C.Limit.UNRELIABLE_SEAL
			for _, text in { blob.overAllError, blob.overOneError } do
				expect(text).toContain(string.format("the message is %d bytes", limit + 1))
				expect(text).toContain(string.format("limited to %d bytes", limit))
			end
			expect(blob.overAllRaised).toBe(true)
			expect(blob.overOneRaised).toBe(true)
			expect(blob.messagesDelta).toBe(0)
			expect(blob.droppedDelta).toBe(0)
		end, evidence)
	end)
end
