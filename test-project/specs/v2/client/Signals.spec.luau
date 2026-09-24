--!strict
-- 2.0 Signals on the client: ClientSignal objects (Connect side only), Wait / Once / DisconnectAll,
-- Disconnect in both forms, FireFor and FireExcept deliveries, the unreliable typed Stream.
-- Other clients' "hitExcept" requests reach this client too, so deliveries are filtered by tag.
local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	local function ping(...: any)
		V2.proxy().ClientEvents.Ping:Fire(...)
		V2.loren().Flush()
	end

	local function byTag(tag: string): (...any) -> boolean
		return function(first: any, ...: any): boolean
			return first == tag
		end
	end

	describe("v2 ClientSignal objects", function()
		it("Fire / FireAll / FireFor / FireExcept raise: Signals go from server to client", function()
			local hit = V2.proxy().Signals.Hit
			expect(function()
				hit:Fire("x", 1)
			end).toThrow()
			expect(function()
				hit:FireAll("x", 1)
			end).toThrow()
			expect(function()
				hit:FireFor({}, "x", 1)
			end).toThrow()
			expect(function()
				hit:FireExcept({}, "x", 1)
			end).toThrow()
		end)

		it("Disconnect works with '.' and ':' and is idempotent", function()
			local hit = V2.proxy().Signals.Hit
			local connection = hit:Connect(function() end)
			expect(connection.Connected).toBe(true)
			connection:Disconnect()
			expect(connection.Connected).toBe(false)
			connection.Disconnect()
			connection:Destroy()
			expect(connection.Connected).toBe(false)
		end)
	end)

	describe("v2 Signal deliveries", function()
		it("Fire reaches the requesting player with the typed values", function()
			local P = V2.proxy()
			local tag = V2.tag("hit")
			local got = V2.collect(P.Signals.Hit, byTag(tag))
			ping("hit", tag, 7)
			local arrived = V2.waitUntil(function()
				return #got.list > 0
			end)
			got.stop()
			expect(arrived).toBe(true)
			expect(got.list[1].n).toBe(2)
			expect(got.list[1][2]).toBe(7)
		end)

		it("Wait returns the next delivery", function()
			local P = V2.proxy()
			local tag = V2.tag("wait")
			local result: { n: number, [number]: any }? = nil
			local done = false
			task.spawn(function()
				while not done do
					local values = table.pack(P.Signals.Hit:Wait())
					if values[1] == tag then
						result = values
						done = true
					end
				end
			end)
			ping("hit", tag, 8)
			local arrived = V2.waitUntil(function()
				return result ~= nil
			end)
			done = true -- a waiting thread left behind exits on the next delivery
			expect(arrived).toBe(true)
			expect((result :: any)[2]).toBe(8)
		end)

		it("Once runs exactly once", function()
			local P = V2.proxy()
			local tagA, tagB = V2.tag("onceA"), V2.tag("onceB")
			local once = 0
			P.Signals.Hit:Once(function()
				once += 1
			end)
			local got = V2.collect(P.Signals.Hit, function(first: any): boolean
				return first == tagA or first == tagB
			end)
			ping("hit", tagA, 1)
			ping("hit", tagB, 2)
			local arrived = V2.waitUntil(function()
				return #got.list >= 2
			end)
			got.stop()
			expect(arrived).toBe(true)
			expect(once).toBe(1)
		end)

		it("DisconnectAll disconnects every listener", function()
			local P = V2.proxy()
			local hit = P.Signals.Hit
			local calls = 0
			local first = hit:Connect(function()
				calls += 1
			end)
			hit:Connect(function()
				calls += 1
			end)
			hit:DisconnectAll()
			expect(first.Connected).toBe(false)
			local tag = V2.tag("all")
			local got = V2.collect(hit, byTag(tag)) -- connected after DisconnectAll: still receives
			ping("hit", tag, 3)
			local arrived = V2.waitUntil(function()
				return #got.list > 0
			end)
			got.stop()
			expect(arrived).toBe(true)
			expect(calls).toBe(0)
		end)

		it("FireFor reaches the listed player", function()
			local P = V2.proxy()
			local tag = V2.tag("for")
			local got = V2.collect(P.Signals.Hit, byTag(tag))
			ping("hitFor", tag, 4)
			local arrived = V2.waitUntil(function()
				return #got.list > 0
			end)
			got.stop()
			expect(arrived).toBe(true)
			expect(got.list[1][2]).toBe(4)
		end)

		it("FireExcept skips the excepted player", function()
			local P = V2.proxy()
			local skipped, marker = V2.tag("except"), V2.tag("marker")
			local gotSkipped = V2.collect(P.Signals.Hit, byTag(skipped))
			local gotMarker = V2.collect(P.Signals.Hit, byTag(marker))
			ping("hitExcept", skipped, 5)
			ping("hit", marker, 6) -- same reliable order: arrives after anything the first one sent
			local arrived = V2.waitUntil(function()
				return #gotMarker.list > 0
			end)
			task.wait(0.2)
			gotSkipped.stop()
			gotMarker.stop()
			expect(arrived).toBe(true)
			expect(#gotSkipped.list).toBe(0)
		end)

		it("the unreliable typed Stream delivers exact values", function()
			local P = V2.proxy()
			local nonce = V2.nonce()
			local got = V2.collect(P.Signals.Stream, function(n: any): boolean
				return n == nonce
			end)
			ping("stream", nonce, 20)
			V2.waitUntil(function()
				return #got.list >= 20
			end, 2)
			got.stop()
			expect(#got.list).toBeGreaterThan(0)
			local seen: { [number]: boolean } = {}
			for _, values in got.list do
				local index, value = values[2], values[3]
				expect(index >= 1 and index <= 20).toBe(true)
				expect(seen[index]).toBeNil()
				seen[index] = true
				expect(value).toBe(index * 0.25)
			end
		end)
	end)
end
