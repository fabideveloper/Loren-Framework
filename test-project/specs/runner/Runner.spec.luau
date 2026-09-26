--!strict
-- Self-tests for LorenTest.run / collect / report (nested runs of small inline specs).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LorenTest = require(ReplicatedStorage.LorenTest.LorenTest)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	local function runOne(fn: (any) -> (), opts: LorenTest.RunOptions?): LorenTest.Results
		return LorenTest.run({ { name = "inner", fn = fn } }, opts)
	end

	describe("run", function()
		it("counts passed, failed and skipped tests and names failures by path", function()
			local results = runOne(function(tt)
				tt.it("passes", function() end)
				tt.it("fails", function()
					tt.expect(1).toBe(2)
				end)
				tt.it("skipped", function() end, { skip = true })
			end)
			expect(results.passed).toBe(1)
			expect(results.failed).toBe(1)
			expect(results.skipped).toBe(1)
			expect(results.failures[1].path).toBe("inner > fails")
			expect(results.failures[1].message).toContain("expected 1 to be 2")
			expect(results.files[1].name).toBe("inner")
		end)

		it("builds paths from nested describes", function()
			local results = runOne(function(tt)
				tt.describe("outer", function()
					tt.describe("block", function()
						tt.it("test", function()
							error("nope")
						end)
					end)
				end)
			end)
			expect(results.failures[1].path).toBe("inner > outer > block > test")
			expect(results.failures[1].message).toContain("nope")
		end)

		it("runs hooks in order around every test", function()
			local log = {}
			local results = runOne(function(tt)
				tt.beforeAll(function()
					table.insert(log, "beforeAll")
				end)
				tt.afterAll(function()
					table.insert(log, "afterAll")
				end)
				tt.beforeEach(function()
					table.insert(log, "beforeEach")
				end)
				tt.afterEach(function()
					table.insert(log, "afterEach")
				end)
				tt.describe("group", function()
					tt.beforeEach(function()
						table.insert(log, "inner beforeEach")
					end)
					tt.afterEach(function()
						table.insert(log, "inner afterEach")
					end)
					tt.it("a", function()
						table.insert(log, "a")
					end)
				end)
				tt.it("b", function()
					table.insert(log, "b")
				end)
			end)
			expect(results.passed).toBe(2)
			expect(log).toEqual({
				"beforeAll",
				"beforeEach",
				"inner beforeEach",
				"a",
				"inner afterEach",
				"afterEach",
				"beforeEach",
				"b",
				"afterEach",
				"afterAll",
			})
		end)

		it("a failing beforeEach fails the test, skips its body and still runs afterEach", function()
			local ranBody, ranAfter = false, false
			local results = runOne(function(tt)
				tt.beforeEach(function()
					error("setup broke")
				end)
				tt.afterEach(function()
					ranAfter = true
				end)
				tt.it("x", function()
					ranBody = true
				end)
			end)
			expect(results.failed).toBe(1)
			expect(results.failures[1].message).toContain("beforeEach failed")
			expect(results.failures[1].message).toContain("setup broke")
			expect(ranBody).toBe(false)
			expect(ranAfter).toBe(true)
		end)

		it("a failing beforeAll fails every test of its block, and afterAll still runs", function()
			local ranAfterAll = false
			local results = runOne(function(tt)
				tt.describe("block", function()
					tt.beforeAll(function()
						error("no database")
					end)
					tt.afterAll(function()
						ranAfterAll = true
					end)
					tt.it("one", function() end)
					tt.it("two", function() end)
					tt.it("skipped", function() end, { skip = true })
				end)
				tt.it("outside", function() end)
			end)
			expect(results.failed).toBe(2)
			expect(results.passed).toBe(1)
			expect(results.skipped).toBe(1)
			expect(results.failures[1].message).toContain("beforeAll failed")
			expect(ranAfterAll).toBe(true)
		end)

		it("reports a failing afterAll and an error inside describe", function()
			local results = runOne(function(tt)
				tt.describe("broken", function()
					tt.it("registered before the error", function() end)
					error("describe blew up")
				end)
				tt.afterAll(function()
					error("teardown broke")
				end)
			end)
			expect(results.passed).toBe(1)
			expect(results.failed).toBe(2)
			local messages = results.failures[1].message .. "\n" .. results.failures[2].message
			expect(messages).toContain("describe blew up")
			expect(messages).toContain("teardown broke")
		end)

		it("lets tests yield", function()
			local results = runOne(function(tt)
				tt.it("yields", function()
					task.wait(0.05)
					tt.expect(true).toBe(true)
				end)
			end)
			expect(results.passed).toBe(1)
		end)

		it("fails a test that errors after yielding", function()
			local results = runOne(function(tt)
				tt.it("late error", function()
					task.wait(0.05)
					error("after the wait")
				end)
			end)
			expect(results.failed).toBe(1)
			expect(results.failures[1].message).toContain("after the wait")
		end)

		it("times out a test that takes too long and moves on", function()
			local started = os.clock()
			local results = runOne(function(tt)
				tt.it("slow", function()
					task.wait(3)
				end, { timeout = 0.2 })
				tt.it("next", function() end)
			end)
			expect(os.clock() - started).toBeLessThan(2)
			expect(results.failed).toBe(1)
			expect(results.passed).toBe(1)
			expect(results.failures[1].message).toContain("timed out")
		end)

		it("rejects it() called inside a running test", function()
			local results = runOne(function(tt)
				tt.it("outer", function()
					tt.it("inner", function() end)
				end)
			end)
			expect(results.failed).toBe(1)
			expect(results.failures[1].message).toContain("collected")
		end)

		it("applies the filter to test paths", function()
			local results = runOne(function(tt)
				tt.it("alpha", function() end)
				tt.it("beta", function()
					error("should not run")
				end)
			end, { filter = "alpha" })
			expect(results.passed).toBe(1)
			expect(results.failed).toBe(0)
		end)

		it("accepts a name -> function map", function()
			local results = LorenTest.run({
				b = function(tt)
					tt.it("x", function() end)
				end,
				a = function(tt)
					tt.it("y", function() end)
				end,
			})
			expect(results.passed).toBe(2)
			expect(results.files[1].name).toBe("a")
		end)
	end)

	describe("collect", function()
		it("requires *.spec modules recursively, reports load errors and skips '_' names", function()
			local fixtures = (script.Parent :: Instance):FindFirstChild("_fixtures")
			expect(fixtures).never.toBeNil()
			local specs = LorenTest.collect(fixtures :: Instance, "fx")
			local names = {}
			for _, spec in specs do
				table.insert(names, spec.name)
			end
			expect(names).toEqual({ "fx/Good.spec", "fx/LoadError.spec", "fx/NotAFunction.spec", "fx/nested/Deep.spec" })
			expect(specs[1].fn).never.toBeNil()
			expect(specs[2].loadError).toContain("failed to load")
			expect(specs[3].loadError).toContain("must return function")

			local results = LorenTest.run(specs)
			expect(results.passed).toBe(2)
			expect(results.failed).toBe(2)
		end)
	end)

	describe("report", function()
		it("prints PASS/FAIL per file, each failure with its path, and a total", function()
			local results = LorenTest.run({
				{
					name = "good",
					fn = function(tt)
						tt.it("ok", function() end)
					end,
				},
				{
					name = "bad",
					fn = function(tt)
						tt.it("broken", function()
							error("kaput")
						end)
					end,
				},
			}, { label = "demo" })
			local text = LorenTest.report(results)
			expect(text).toContain("demo")
			expect(text).toContain("PASS  good")
			expect(text).toContain("FAIL  bad")
			expect(text).toContain("x bad > broken")
			expect(text).toContain("kaput")
			expect(text).toContain("1 passed, 1 failed, 0 skipped")
		end)
	end)
end
