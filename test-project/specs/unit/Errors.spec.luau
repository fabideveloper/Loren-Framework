--!strict
-- Errors (lifecycle): rejection strings for every code, frozen ErrorInfo, Loren.Reject detection,
-- 256-byte truncation and incident ids. IMPLEMENTATION.md sections 3.3 and 5. Runs on the server.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runtime = ReplicatedStorage:WaitForChild("LorenRuntime")
local Loren = require(Runtime) :: any
local C = require(Runtime:WaitForChild("Constants")) :: any
local Errors = require(Runtime:WaitForChild("Errors")) :: any

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	local E = C.Err

	describe("message", function()
		it("keeps the exact 1.5.1 strings", function()
			expect(Errors.message(E.Timeout)).toBe("(LORENঌ) Timeout")
			expect(Errors.message(E.Denied)).toBe("Denied")
		end)

		it("Rejected is the message verbatim, or empty", function()
			expect(Errors.message(E.Rejected, "Not enough gold")).toBe("Not enough gold")
			expect(Errors.message(E.Rejected)).toBe("")
		end)

		it("Denied is the middleware reason when given", function()
			expect(Errors.message(E.Denied, "Banned")).toBe("Banned")
		end)

		it("BadRequest and BadArgument name the argument and reason", function()
			expect(Errors.message(E.BadRequest, "NonFinite", nil, 2)).toBe("(LORENঌ) BadRequest: arg 2 (NonFinite)")
			expect(Errors.message(E.BadRequest)).toBe("(LORENঌ) BadRequest")
			expect(Errors.message(E.BadRequest, nil, nil, 3)).toBe("(LORENঌ) BadRequest: arg 3")
			expect(Errors.message(E.BadRequest, "Overrun", nil, 0)).toBe("(LORENঌ) BadRequest (Overrun)")
			expect(Errors.message(E.BadArgument, "Cycle", nil, 1)).toBe("(LORENঌ) BadArgument: arg 1 (Cycle)")
			expect(Errors.message(E.BadArgument)).toBe("(LORENঌ) BadArgument")
		end)

		it("InternalError and BadResult carry the incident and the forwarded text", function()
			expect(Errors.message(E.InternalError, nil, 0xA1B2C3D4)).toBe("(LORENঌ) InternalError [a1b2c3d4]")
			expect(Errors.message(E.InternalError, "boom", 42)).toBe("(LORENঌ) InternalError [0000002a]: boom")
			expect(Errors.message(E.BadResult, nil, 0xFFFFFFFF)).toBe("(LORENঌ) BadResult [ffffffff]")
			expect(Errors.message(E.BadResult, "cannot encode", 1)).toBe(
				"(LORENঌ) BadResult [00000001]: cannot encode"
			)
		end)

		it("every other code maps to its fixed string", function()
			expect(Errors.message(E.RateLimited)).toBe("(LORENঌ) RateLimited")
			expect(Errors.message(E.Busy)).toBe("(LORENঌ) Busy")
			expect(Errors.message(E.ShuttingDown)).toBe("(LORENঌ) ShuttingDown")
			expect(Errors.message(E.TooManyInFlight)).toBe("(LORENঌ) TooManyInFlight")
			expect(Errors.message(E.PayloadTooLarge)).toBe("(LORENঌ) PayloadTooLarge")
			expect(Errors.message(E.NotReady)).toBe("(LORENঌ) NotReady")
			expect(Errors.message(E.BootFailed)).toBe("(LORENঌ) BootFailed")
			expect(Errors.message(E.MissingInstance)).toBe("(LORENঌ) MissingInstance")
		end)

		it("fixed strings ignore a msg argument", function()
			expect(Errors.message(E.Timeout, "ignored")).toBe("(LORENঌ) Timeout")
			expect(Errors.message(E.Busy, "ignored")).toBe("(LORENঌ) Busy")
		end)

		it("an unknown code reads as InternalError", function()
			expect(Errors.message(99)).toBe("(LORENঌ) InternalError")
			expect(Errors.message(0)).toBe("(LORENঌ) InternalError")
		end)

		it("every code string (except Rejected and Denied) starts with the prefix", function()
			for code, name in C.ErrName do
				if name ~= "Rejected" and name ~= "Denied" then
					local text = Errors.message(code)
					expect(string.sub(text, 1, #C.PREFIX)).toBe(C.PREFIX)
				end
			end
		end)
	end)

	describe("info", function()
		it("is frozen and has every field", function()
			local info = Errors.info(E.BadRequest, "Shop", "Buy", "msg", nil, nil, 2)
			expect(table.isfrozen(info)).toBe(true)
			expect(info.Code).toBe("BadRequest")
			expect(info.CodeId).toBe(3)
			expect(info.Message).toBe("msg")
			expect(info.Service).toBe("Shop")
			expect(info.Member).toBe("Buy")
			expect(info.Arg).toBe(2)
			expect(info.Incident).toBeNil()
			expect(info.Data).toBeNil()
			expect(function()
				(info :: any).Code = "x"
			end).toThrow()
		end)

		it("formats the incident as 8 hex digits and keeps Data", function()
			local data = { reason = "x" }
			local info = Errors.info(E.InternalError, "S", "M", "m", data, 0xBEEF)
			expect(info.Incident).toBe("0000beef")
			expect(info.Data).toBe(data)
		end)

		it("maps every code to its name", function()
			for code, name in C.ErrName do
				local info = Errors.info(code, "S", "M", "m", nil)
				expect(info.Code).toBe(name)
				expect(info.CodeId).toBe(code)
			end
		end)

		it("reports an unknown code as InternalError", function()
			local info = Errors.info(77, "S", "M", "m", nil)
			expect(info.Code).toBe("InternalError")
			expect(info.CodeId).toBe(E.InternalError)
		end)
	end)

	describe("rejection", function()
		it("returns the message and an info with the same message", function()
			local msg, info = Errors.rejection(E.Timeout, "Svc", "Slow", nil, nil)
			expect(msg).toBe("(LORENঌ) Timeout")
			expect(info.Message).toBe(msg)
			expect(info.Code).toBe("Timeout")
			expect(info.Service).toBe("Svc")
			expect(info.Member).toBe("Slow")
		end)

		it("carries Reject data and the verbatim message", function()
			local msg, info = Errors.rejection(E.Rejected, "Svc", "Buy", "Not enough gold", { need = 5 })
			expect(msg).toBe("Not enough gold")
			expect(info.Data.need).toBe(5)
		end)

		it("carries the incident and argument", function()
			local msg, info = Errors.rejection(E.InternalError, "S", "M", nil, nil, 0x10)
			expect(msg).toBe("(LORENঌ) InternalError [00000010]")
			expect(info.Incident).toBe("00000010")
			local msg2, info2 = Errors.rejection(E.BadArgument, "S", "M", "TooDeep", nil, nil, 4)
			expect(msg2).toBe("(LORENঌ) BadArgument: arg 4 (TooDeep)")
			expect(info2.Arg).toBe(4)
		end)
	end)

	describe("Reject", function()
		it("is detected when returned", function()
			local r = Errors.reject("nope", { a = 1 })
			expect(Errors.isReject(r)).toBe(true)
			expect(r.Message).toBe("nope")
			expect(r.Data.a).toBe(1)
			expect(table.isfrozen(r)).toBe(true)
		end)

		it("is detected when thrown (the table stays the error value)", function()
			local ok: boolean, err: any = pcall(function()
				error(Loren.Reject("thrown", 7))
			end)
			expect(ok).toBe(false)
			expect(Errors.isReject(err)).toBe(true)
			expect(err.Message).toBe("thrown")
			expect(err.Data).toBe(7)
		end)

		it("does not match look-alikes", function()
			expect(Errors.isReject({ Message = "x", Data = nil })).toBe(false)
			expect(Errors.isReject("x")).toBe(false)
			expect(Errors.isReject(nil)).toBe(false)
			expect(Errors.isReject(setmetatable({}, {}))).toBe(false)
		end)

		it("stringifies non-string messages", function()
			expect(Errors.reject(42).Message).toBe("42")
			expect(Errors.reject(true).Message).toBe("true")
			expect(Errors.reject(nil).Message).toBe("")
			expect(tostring(Errors.reject("shown"))).toBe("shown")
		end)

		it("Loren.Reject is Errors.reject (dot and colon)", function()
			expect(Errors.isReject(Loren.Reject("a"))).toBe(true)
			expect(Loren:Reject("b").Message).toBe("b")
		end)

		it("truncates the message to 256 bytes", function()
			local r = Errors.reject(string.rep("x", 300))
			expect(#r.Message).toBe(256)
		end)
	end)

	describe("truncate", function()
		it("keeps strings up to 256 bytes", function()
			local s = string.rep("a", 256)
			expect(Errors.truncate(s)).toBe(s)
			expect(Errors.truncate("")).toBe("")
		end)

		it("cuts longer strings to 256 bytes", function()
			expect(#Errors.truncate(string.rep("a", 257))).toBe(256)
			expect(#Errors.truncate(string.rep("a", 5000))).toBe(256)
		end)

		it("never splits a UTF-8 character", function()
			-- 255 ASCII bytes + a 3-byte character: the character would straddle the cut.
			local s = string.rep("a", 255) .. "ঌ" .. "tail"
			local out = Errors.truncate(s)
			expect(#out).toBe(255)
			expect(utf8.len(out)).toBe(255)
			-- 254 ASCII + the 3-byte character ends at 257: cut before it.
			local s2 = string.rep("a", 254) .. "ঌ" .. "tail"
			expect(#Errors.truncate(s2)).toBe(254)
			-- 253 ASCII + the 3-byte character ends exactly at 256: kept.
			local s3 = string.rep("a", 253) .. "ঌ" .. "tail"
			local out3 = Errors.truncate(s3)
			expect(#out3).toBe(256)
			expect(utf8.len(out3)).toBeTruthy()
		end)

		it("cuts invalid UTF-8 at exactly 256 bytes", function()
			local s = string.rep("\x80", 400)
			expect(#Errors.truncate(s)).toBe(256)
		end)

		it("always returns at most 256 bytes", function()
			local rng = Random.new(7)
			for _ = 1, 500 do
				local parts = {}
				for i = 1, rng:NextInteger(200, 320) do
					parts[i] = string.char(rng:NextInteger(0, 255))
				end
				local out = Errors.truncate(table.concat(parts))
				expect(#out <= 256).toBe(true)
			end
		end)
	end)

	describe("incidents", function()
		it("hex is 8 lowercase hex digits", function()
			expect(Errors.hex(0)).toBe("00000000")
			expect(Errors.hex(0xA1B2C3D4)).toBe("a1b2c3d4")
			expect(Errors.hex(0xFFFFFFFF)).toBe("ffffffff")
		end)

		it("newIncident is a uniform u32", function()
			local distinct = {}
			local count = 0
			for _ = 1, 200 do
				local id = Errors.newIncident()
				expect(id % 1).toBe(0)
				expect(id >= 0 and id <= 0xFFFFFFFF).toBe(true)
				expect(string.match(Errors.hex(id), "^%x%x%x%x%x%x%x%x$")).toBeTruthy()
				if not distinct[id] then
					distinct[id] = true
					count += 1
				end
			end
			expect(count).toBeGreaterThan(190)
		end)
	end)

	describe("Public (Loren.Errors)", function()
		it("maps every code name to itself and is frozen", function()
			local n = 0
			for _, name in C.ErrName do
				expect(Errors.Public[name]).toBe(name)
				n += 1
			end
			local m = 0
			for _ in Errors.Public do
				m += 1
			end
			expect(m).toBe(n)
			expect(table.isfrozen(Errors.Public)).toBe(true)
			expect(Loren.Errors).toBe(Errors.Public)
			expect(Loren.Errors.Timeout).toBe("Timeout")
		end)
	end)
end
