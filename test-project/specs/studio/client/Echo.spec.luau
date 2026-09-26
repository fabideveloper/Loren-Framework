--!strict
-- EchoService round trips: values come back unchanged, in order, per request.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage.LorenTest.Harness
local Env = require(Harness.Env)
local Budget = require(Harness.Budget)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local Echo = Env.proxy("EchoService")

	local function echo(...: any): { n: number, [number]: any }
		Budget.take(1)
		return table.pack(Echo:Echo(...):await())
	end

	describe("EchoService.Echo", function()
		it("resolves with no values for no arguments", function()
			local r = echo()
			expect(r[1]).toBe(true)
			expect(r[2]).toBeNil()
		end)

		it("returns several values in order", function()
			local r = echo(1, "two", true, 4.5)
			expect(r[1]).toBe(true)
			expect(r[2]).toBe(1)
			expect(r[3]).toBe("two")
			expect(r[4]).toBe(true)
			expect(r[5]).toBe(4.5)
		end)

		it("resolves (does not reject) when the returned value is false", function()
			local r = echo(false)
			expect(r[1]).toBe(true)
			expect(r[2]).toBe(false)
		end)

		it("round-trips numbers exactly", function()
			local values = { 0, -1, 2 ^ 31, 2 ^ 53, 0.1, -123.456, 1e300, -1e-300 }
			local r = echo(table.unpack(values))
			expect(r[1]).toBe(true)
			for i, v in values do
				expect(r[i + 1]).toBe(v)
			end
		end)

		it("round-trips strings, including unicode and 10 KB", function()
			local long = string.rep("abc", 3400)
			local r = echo("", "hello", "héllo wörld 🔥", long)
			expect(r[2]).toBe("")
			expect(r[3]).toBe("hello")
			expect(r[4]).toBe("héllo wörld 🔥")
			expect(r[5]).toBe(long)
		end)

		it("round-trips arrays and nested dictionaries", function()
			local r = echo({ 1, 2, 3 }, { a = 1, b = { c = "d", e = { true, false } } })
			expect(r[2]).toEqual({ 1, 2, 3 })
			expect(r[3]).toEqual({ a = 1, b = { c = "d", e = { true, false } } })
		end)

		it("round-trips Roblox datatypes", function()
			local values: { any } = {
				Vector3.new(1, 2, 3),
				CFrame.new(1, 2, 3),
				Color3.new(0.5, 0.25, 1),
				UDim2.new(0.5, 10, 0.25, 20),
				Enum.KeyCode.E,
				Vector2.new(4, 5),
			}
			local r = echo(table.unpack(values))
			for i, v in values do
				expect(r[i + 1]).toBe(v)
			end
		end)

		it("carries 20 arguments", function()
			local args = {}
			for i = 1, 20 do
				args[i] = i
			end
			local r = echo(table.unpack(args))
			for i = 1, 20 do
				expect(r[i + 1]).toBe(i)
			end
		end)

		it("keeps arguments after a nil hole", function()
			local r = echo(1, nil, 3, nil)
			expect(r[1]).toBe(true)
			expect(r[2]).toBe(1)
			expect(r[3]).toBeNil()
			expect(r[4]).toBe(3)
		end, { skip = Env.is151 })

		it("keeps each concurrent call's own result", function()
			Budget.take(20)
			local promises = {}
			for i = 1, 20 do
				promises[i] = Echo:Echo(i, "call" .. i)
			end
			for i, promise in promises do
				local ok, number, label = promise:await()
				expect(ok).toBe(true)
				expect(number).toBe(i)
				expect(label).toBe("call" .. i)
			end
		end)

		it("returns a Promise that chains with andThen", function()
			Budget.take(1)
			local ok, doubled = Echo:Echo(21)
				:andThen(function(value: number)
					return value * 2
				end)
				:await()
			expect(ok).toBe(true)
			expect(doubled).toBe(42)
		end)
	end)

	describe("EchoService.Size", function()
		it("returns the length of the string", function()
			Budget.take(3)
			local ok1, a = Echo:Size("hello"):await()
			local ok2, b = Echo:Size(""):await()
			local ok3, c = Echo:Size(string.rep("x", 1000)):await()
			expect(ok1 and ok2 and ok3).toBe(true)
			expect(a).toBe(5)
			expect(b).toBe(0)
			expect(c).toBe(1000)
		end)
	end)
end
