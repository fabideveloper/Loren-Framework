--!strict
-- 2.0 middleware on the server: README dot style allows (and gets no self), colon style is flagged
-- at boot and denies every call, a throw is an InternalError, a truthy non-true value denies, a
-- returned Promise is awaited, `false, msg` denies with msg; AddMiddleware is boot-time only.
local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local noPlayers = not V2.hasPlayers()
	local evidence = { skip = noPlayers, timeout = V2.TEST_TIMEOUT }

	describe("v2 AddMiddleware", function()
		it("errors after SetOnFire, in both call forms", function()
			local Loren = V2.loren()
			local function allow(): boolean
				return true
			end
			expect(function()
				Loren.AddMiddleware(allow)
			end).toThrow("before SetOnFire")
			expect(function()
				Loren:AddMiddleware(allow)
			end).toThrow("before SetOnFire")
		end)

		it("rejects a non-function", function()
			local Loren = V2.loren()
			expect(function()
				Loren.AddMiddleware("nope")
			end).toThrow("function")
		end)
	end)

	describe("v2 member middleware", function()
		it("the boot warned that Middleware.MwColon looks colon-defined", function()
			expect(V2.logLine("Middleware.MwColon", "colon")).never.toBeNil()
		end)

		it("dot style runs as (player, ...args) and gates the handler", function()
			local probe = V2.probe()
			V2.await("an allowed MwDot call", function()
				return V2.count(probe.handler, "MwDot") > 0
			end)
			V2.await("a denied MwDot call", function()
				return V2.count(probe.mw, "MwDot") > V2.count(probe.handler, "MwDot")
			end)
			expect(probe.mwBadPlayer).toBe(0)
		end, evidence)

		it("a returned Promise is awaited: its verdict gates the handler", function()
			local probe = V2.probe()
			V2.await("allowed and denied MwPromise calls", function()
				return V2.count(probe.handler, "MwPromise") > 0
					and V2.count(probe.mw, "MwPromise") > V2.count(probe.handler, "MwPromise")
			end)
		end, evidence)

		it("a truthy value that is not true denies", function()
			local probe = V2.probe()
			V2.await("a MwTruthy call", function()
				return V2.count(probe.mw, "MwTruthy") > 0
			end)
			expect(V2.count(probe.handler, "MwTruthy")).toBe(0)
		end, evidence)

		it("a throwing middleware is an InternalError reported to OnError; the handler never runs", function()
			local probe = V2.probe()
			local reported = false
			V2.await("a MwThrow failure reported to OnError", function()
				for _, info in probe.errors do
					if info.Service == "V2Service" and info.Member == "MwThrow" then
						reported = string.find(info.Message, V2.service().Texts.MwThrow, 1, true) ~= nil
						return true
					end
				end
				return false
			end)
			expect(reported).toBe(true)
			expect(V2.count(probe.mw, "MwThrow")).toBeGreaterThan(0)
			expect(V2.count(probe.handler, "MwThrow")).toBe(0)
		end, evidence)

		it("a colon-flagged middleware denies without running it or the handler", function()
			local probe = V2.probe()
			-- The clients' Errors spec calls MwColon right after MwDot and MwTruthy.
			V2.await("the clients' middleware calls", function()
				return V2.count(probe.mw, "MwTruthy") > 0
			end)
			expect(V2.count(probe.mw, "MwColon")).toBe(0)
			expect(V2.count(probe.handler, "MwColon")).toBe(0)
		end, evidence)

		it("no handler ever ran for a call its middleware denied", function()
			local probe = V2.probe()
			V2.await("the clients' middleware calls", function()
				return V2.count(probe.mw, "MwPromise") > 0 and V2.count(probe.mw, "MwThrow") > 0
			end)
			expect(probe.leaks).toBe(0)
		end, evidence)
	end)
end
