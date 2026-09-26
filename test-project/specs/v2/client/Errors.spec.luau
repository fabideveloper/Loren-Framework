--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local C = V2.C
	local Msg = C.Msg

	-- "(LORENঌ) <Name> [xxxxxxxx]" (+ ": text" when forwarded): returns the incident id or nil.
	local function incidentOf(message: string, fixed: string): string?
		local head = fixed .. " ["
		if string.sub(message, 1, #head) ~= head then
			return nil
		end
		local id = string.sub(message, #head + 1, #head + 8)
		if string.match(id, V2.HEX8) == nil or string.sub(message, #head + 9, #head + 9) ~= "]" then
			return nil
		end
		return id
	end

	describe("v2 public error names", function()
		it("Loren.Errors names every code", function()
			local Errors = V2.loren().Errors
			for _, name in C.ErrName do
				expect(Errors[name]).toBe(name)
			end
		end)
	end)

	describe("v2 server-side codes", function()
		it("Rejected: Loren.Reject returned by the handler, message verbatim and Data", function()
			local P = V2.proxy()
			local data = { reason = "nope", list = { 1, 2 } }
			local message, info =
				V2.rejection(expect, V2.settle(P:RejectMe("not allowed", data)), "Rejected", "RejectMe")
			expect(message).toBe("not allowed")
			expect(info.Data).toEqual(data)
			expect(info.Incident).toBeNil()
		end)

		it("Rejected: Loren.Reject thrown by the handler", function()
			local P = V2.proxy()
			local message, info =
				V2.rejection(expect, V2.settle(P:RejectMe("thrown", 42, true)), "Rejected", "RejectMe")
			expect(message).toBe("thrown")
			expect(info.Data).toBe(42)
		end)

		it("Rejected: a long message is truncated to 256 bytes", function()
			local P = V2.proxy()
			local long = string.rep("r", 300)
			local message = V2.rejection(expect, V2.settle(P:RejectMe(long)), "Rejected", "RejectMe")
			expect(#message).toBeLessThanOrEqual(C.Limit.ERR_MSG_MAX)
			expect(string.sub(long, 1, #message)).toBe(message)
		end)

		it("Denied: dot-style middleware returning (false, msg) denies with msg; true allows", function()
			local P = V2.proxy()
			local allowed = V2.settle(P:MwDot("allow"))
			expect(allowed[1]).toBe(true)
			expect(allowed[2]).toBe("MwDot ran")
			local message = V2.rejection(expect, V2.settle(P:MwDot("deny")), "Denied", "MwDot")
			expect(message).toBe(V2.Texts.MwDotDenied)
		end)

		it("Denied: a middleware Promise is awaited", function()
			local P = V2.proxy()
			local allowed = V2.settle(P:MwPromise(true))
			expect(allowed[1]).toBe(true)
			expect(allowed[2]).toBe("MwPromise ran")
			local message = V2.rejection(expect, V2.settle(P:MwPromise(false)), "Denied", "MwPromise")
			expect(message).toBe(V2.Texts.MwPromiseDenied)
		end)

		it("Denied: a truthy value that is not true denies with the 1.5.1 string", function()
			local P = V2.proxy()
			local message = V2.rejection(expect, V2.settle(P:MwTruthy()), "Denied", "MwTruthy")
			expect(message).toBe("Denied")
		end)

		it("Denied: colon-defined middleware denies every call", function()
			local P = V2.proxy()
			local message = V2.rejection(expect, V2.settle(P:MwColon("allow")), "Denied", "MwColon")
			expect(message).toBe(Msg.Denied)
		end)

		it("BadRequest: an Instance the server does not have arrives nil (MissingInstance)", function()
			local P = V2.proxy()
			local localPart = Instance.new("Part") -- exists on this client only
			local message, info =
				V2.rejection(expect, V2.settle(P:NeedsPart(localPart, false)), "BadRequest", "NeedsPart")
			localPart:Destroy()
			expect(message).toBe(Msg.BadRequest .. ": arg 1 (MissingInstance)")
			expect(info.Arg).toBe(1)
		end)

		it("BadRequest or BadArgument: an Instance of the wrong class", function()
			local P = V2.proxy()
			local folder = ReplicatedStorage:WaitForChild("V2Fixture", 10)
			local r = V2.settle(P:NeedsPart(folder, false))
			expect(r[1]).toBe(false)
			local info = r[3]
			expect(info.Code == "BadRequest" or info.Code == "BadArgument").toBe(true)
			expect(info.Arg).toBe(1)
		end)

		it("RateLimited: past the route's RateLimit (Limited: 2 per s, burst 2)", function()
			local P = V2.proxy()
			local promises = {}
			for i = 1, 4 do
				promises[i] = V2.hold(P:Limited())
			end
			local limited = 0
			for i = 1, 4 do
				local r = V2.settle(promises[i])
				if not r[1] then
					local message = V2.rejection(expect, r, "RateLimited", "Limited")
					expect(message).toBe(Msg.RateLimited)
					limited += 1
				end
			end
			expect(limited).toBeGreaterThanOrEqual(1)
			expect(V2.settle(promises[1])[1]).toBe(true)
		end)

		it("Busy: calls past MaxRunningCalls + MaxQueuedCalls (32 + 64)", function()
			local P = V2.proxy()
			local promises = {}
			for i = 1, 100 do
				promises[i] = V2.hold(P:Slow(0.5))
			end
			local ok, busy = 0, 0
			for i = 1, 100 do
				local r = V2.settle(promises[i])
				if r[1] then
					ok += 1
				else
					local message = V2.rejection(expect, r, "Busy", "Slow")
					expect(message).toBe(Msg.Busy)
					busy += 1
				end
			end
			expect(busy).toBeGreaterThanOrEqual(1)
			expect(ok).toBeGreaterThanOrEqual(32)
		end, { timeout = 20 })

		it("InternalError: a handler error, with an incident id (text forwarded in Studio)", function()
			local P = V2.proxy()
			local message, info = V2.rejection(expect, V2.settle(P:Boom()), "InternalError", "Boom")
			local incident = incidentOf(message, Msg.InternalError)
			expect(incident).never.toBeNil()
			expect(info.Incident).toBe(incident)
			if game:GetService("RunService"):IsStudio() then
				expect(message).toContain(V2.Texts.Boom)
			end
		end)

		it("InternalError: a middleware error", function()
			local P = V2.proxy()
			local message, info = V2.rejection(expect, V2.settle(P:MwThrow()), "InternalError", "MwThrow")
			expect(incidentOf(message, Msg.InternalError)).toBe(info.Incident)
		end)

		it("BadResult: a return value the typed Returns refuse (TypedEcho returns n as T.u8)", function()
			local P = V2.proxy()
			local message, info =
				V2.rejection(expect, V2.settle(P:TypedEcho("x", 300, Vector3.zero)), "BadResult", "TypedEcho")
			local incident = incidentOf(message, Msg.BadResult)
			expect(incident).never.toBeNil()
			expect(info.Incident).toBe(incident)
		end)

		it("ShuttingDown (only after BindToClose)", function() end, { skip = true })
	end)

	describe("v2 client-local codes", function()
		it("Timeout: the exact 1.5.1 string", function()
			local P = V2.proxy()
			local message = V2.rejection(expect, V2.settle(P:Hang()), "Timeout", "Hang")
			expect(message).toBe("(LORENঌ) Timeout")
			expect(C.Err.Timeout).toBe(16)
		end)

		it("TooManyInFlight: a call past MaxPending pending calls rejects at once", function()
			task.wait(2) -- let the route buckets refill after the tests above
			local P = V2.proxy()
			local lanes = {
				function(): any
					return P:Echo(1)
				end,
				function(): any
					return P:TypedEcho("x", 1, Vector3.zero)
				end,
				function(): any
					return P:Slow(0)
				end,
				function(): any
					return P:Big(1)
				end,
				function(): any
					return P:MwDot("allow")
				end,
			}
			local open = { true, true, true, true, true }
			local pending = {}
			local hit: { n: number, [number]: any }? = nil
			local fired = 0
			while hit == nil and fired < 1000 do
				local anyOpen = false
				for lane, call in lanes do
					if open[lane] and hit == nil then
						anyOpen = true
						fired += 1
						local promise = call()
						if V2.rejectedNow(promise) then
							local r = V2.settle(promise)
							local code = r[3] and r[3].Code
							if code == "TooManyInFlight" then
								hit = r
							elseif code == "RateLimited" then
								open[lane] = false -- this route's mirror bucket is empty
							else
								error("unexpected local rejection: " .. tostring(r[2]), 0)
							end
						else
							table.insert(pending, V2.hold(promise))
						end
					end
				end
				if not anyOpen then
					break
				end
			end
			for _, promise in pending do
				promise:await()
			end
			expect(hit).never.toBeNil()
			local message = V2.rejection(expect, hit :: any, "TooManyInFlight")
			expect(message).toBe(Msg.TooManyInFlight)
			expect(#pending).toBeLessThanOrEqual(C.Default.MaxPending)
			task.wait(2) -- give the buckets back to the specs that follow
		end, { timeout = 30 })

		it("PayloadTooLarge: a message over 64 KiB", function()
			local P = V2.proxy()
			local message = V2.rejection(expect, V2.settle(P:Echo(string.rep("x", 70000))), "PayloadTooLarge", "Echo")
			expect(message).toBe(Msg.PayloadTooLarge)
		end)

		it("BadArgument: a typed argument of the wrong type names the argument", function()
			local P = V2.proxy()
			local message, info =
				V2.rejection(expect, V2.settle(P:TypedEcho(5, 1, Vector3.zero)), "BadArgument", "TypedEcho")
			expect(message).toBe(Msg.BadArgument .. ": arg 1 (BadType)")
			expect(info.Arg).toBe(1)
		end)

		it("MissingInstance: a typed Instance return the client cannot see", function()
			local P = V2.proxy()
			local folder = ReplicatedStorage:WaitForChild("V2Fixture", 10) :: Instance
			local part = folder:WaitForChild("Part", 10)
			local message = V2.rejection(expect, V2.settle(P:NeedsPart(part, true)), "MissingInstance", "NeedsPart")
			expect(message).toBe(Msg.MissingInstance)
		end)

		it("NotReady (only before the manifest; proxies do not exist then)", function() end, { skip = true })
		it("BootFailed (only when the client boot failed)", function() end, { skip = true })
	end)
end
