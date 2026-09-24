--!strict
-- 2.0 ClientEvents from the client: reliable Ping (ordered, nil holes kept), unreliable coalesced
-- Aim (only the latest value of a frame is sent), unreliable Ordered Seq (never older than the last),
-- typed Fire errors at the caller, listener isolation on the server. V2Service echoes every
-- arrival back on Signals.Echo, to this player only.
local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	local function flush()
		V2.loren().Flush()
	end

	describe("v2 ClientEvent objects", function()
		it("Connect raises: a ClientEvent goes from client to server", function()
			local ping = V2.proxy().ClientEvents.Ping
			expect(function()
				ping:Connect(function() end)
			end).toThrow()
		end)

		it("unknown ClientEvents raise", function()
			local events = V2.proxy().ClientEvents
			expect(function()
				return events.NoSuchEvent
			end).toThrow()
		end)

		it("a typed Fire with a bad value raises at the caller", function()
			local events = V2.proxy().ClientEvents
			expect(function()
				events.Aim:Fire("not a vector")
			end).toThrow("Aim:Fire")
			expect(function()
				events.Aim:Fire(Vector3.new(0 / 0, 0, 0))
			end).toThrow("Aim:Fire")
			expect(function()
				events.Seq:Fire(-1)
			end).toThrow("Seq:Fire")
		end)
	end)

	describe("v2 reliable ClientEvent", function()
		it("Ping reaches the server with nil holes kept", function()
			local P = V2.proxy()
			local tag = V2.tag("ping")
			local got = V2.collect(P.Signals.Echo, function(kind: any, tagged: any): boolean
				return kind == "Ping" and tagged == tag
			end)
			P.ClientEvents.Ping:Fire("echo", tag, 1, nil, 3)
			flush()
			local arrived = V2.waitUntil(function()
				return #got.list > 0
			end)
			got.stop()
			expect(arrived).toBe(true)
			local echo = got.list[1]
			expect(echo.n).toBe(5)
			expect(echo[3]).toBe(1)
			expect(echo[4]).toBeNil()
			expect(echo[5]).toBe(3)
		end)

		it("Pings arrive in the order they were fired", function()
			local P = V2.proxy()
			local tag = V2.tag("order")
			local got = V2.collect(P.Signals.Echo, function(kind: any, tagged: any): boolean
				return kind == "Ping" and tagged == tag
			end)
			for i = 1, 20 do
				P.ClientEvents.Ping:Fire("echo", tag, i)
			end
			flush()
			local arrived = V2.waitUntil(function()
				return #got.list >= 20
			end)
			got.stop()
			expect(arrived).toBe(true)
			for i = 1, 20 do
				expect(got.list[i][3]).toBe(i)
			end
		end)

		it("a server listener that throws does not stop the next one", function()
			local P = V2.proxy()
			local tag = V2.tag("throw")
			local got = V2.collect(P.Signals.Echo, function(kind: any, tagged: any): boolean
				return kind == "Throw" and tagged == tag
			end)
			P.ClientEvents.Ping:Fire("throw", tag)
			flush()
			local arrived = V2.waitUntil(function()
				return #got.list > 0
			end)
			got.stop()
			expect(arrived).toBe(true)
		end)
	end)

	describe("v2 unreliable ClientEvents", function()
		it("Aim is coalesced: only the last value fired in a frame is sent", function()
			local P = V2.proxy()
			local got = V2.collect(P.Signals.Echo, function(kind: any): boolean
				return kind == "Aim"
			end)
			-- Unreliable: retry a few batches until one arrives.
			for batch = 1, 5 do
				for i = 1, 20 do
					P.ClientEvents.Aim:Fire(Vector3.new(i, batch, 0))
				end
				flush()
				if V2.waitUntil(function()
					return #got.list > 0
				end, 1) then
					break
				end
			end
			task.wait(0.3)
			got.stop()
			expect(#got.list).toBeGreaterThan(0)
			for _, echo in got.list do
				local v = echo[2]
				expect(typeof(v)).toBe("Vector3")
				expect(v.X).toBe(20)
			end
		end)

		it("Seq is Ordered: values arrive increasing (older ones are dropped)", function()
			local P = V2.proxy()
			local base = V2.nonce() % 1000000000
			local got = V2.collect(P.Signals.Echo, function(kind: any, n: any): boolean
				return kind == "Seq" and type(n) == "number" and n > base
			end)
			for i = 1, 30 do
				P.ClientEvents.Seq:Fire(base + i)
				task.wait()
			end
			flush()
			V2.waitUntil(function()
				return #got.list > 0 and got.list[#got.list][2] == base + 30
			end, 2)
			got.stop()
			expect(#got.list).toBeGreaterThan(0)
			for i = 2, #got.list do
				expect(got.list[i][2] > got.list[i - 1][2]).toBe(true)
			end
		end)
	end)
end
