--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local C = require(ReplicatedStorage.LorenRuntime.Constants)
local Log = require(ReplicatedStorage.LorenRuntime.Log)

local PREFIX = C.PREFIX
local BUDGET = C.Limit.LOG_LINES_PER_MIN
local ONE_LINE = 60 / BUDGET + 0.01 -- seconds for one budget token to refill, plus a margin

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach, afterEach = t.beforeAll, t.afterAll, t.beforeEach, t.afterEach

	local printed: { string } = {}
	local warned: { string } = {}
	local now = 0

	local function exhaust()
		for i = 1, BUDGET do
			assert(Log.warn("fill " .. i), "budget exhausted too early")
		end
	end

	beforeAll(function()
		local Loren = require(ReplicatedStorage.LorenRuntime) :: any
		Loren.Testing.Reset({ Offline = true })
	end)

	afterAll(function()
		local Loren = require(ReplicatedStorage.LorenRuntime) :: any
		Loren.Testing.Reset()
	end)

	beforeEach(function()
		Log._reset()
		printed = {}
		warned = {}
		now = 0
		Log._test.setSink(function(line: string)
			table.insert(printed, line)
		end, function(line: string)
			table.insert(warned, line)
		end)
		Log._test.setClock(function()
			return now
		end)
		Log._test.setStudio(true)
	end)

	afterEach(function()
		Log._reset()
	end)

	describe("module", function()
		it("is frozen", function()
			expect(table.isfrozen(Log)).toBe(true)
		end)
	end)

	describe("info", function()
		it("prints with the prefix, unthrottled and outside the budget", function()
			for i = 1, 50 do
				Log.info("boot " .. i)
			end
			expect(#printed).toBe(50)
			expect(printed[1]).toBe(PREFIX .. "boot 1")
			expect(#warned).toBe(0)
			expect(Log._test.tokens()).toBe(BUDGET)
		end)
	end)

	describe("warn", function()
		it("warns with the prefix and returns true", function()
			expect(Log.warn("hello")).toBe(true)
			expect(warned).toEqual({ PREFIX .. "hello" })
			expect(#printed).toBe(0)
		end)

		it("allows LOG_LINES_PER_MIN lines at once, then suppresses", function()
			exhaust()
			expect(Log.warn("over")).toBe(false)
			expect(#warned).toBe(BUDGET)
			expect(Log.suppressed()).toBe(1)
		end)

		it("refills at LOG_LINES_PER_MIN per minute", function()
			exhaust()
			now = 60 / BUDGET - 0.1
			expect(Log.warn("early")).toBe(false)
			now = ONE_LINE
			expect(Log.warn("on time")).toBe(true)
			expect(Log.warn("again")).toBe(false)
		end)

		it("appends (+N suppressed) to the next printed line, once", function()
			exhaust()
			Log.warn("a")
			Log.warn("b")
			Log.warn("c")
			expect(Log._test.pending()).toBe(3)
			now = ONE_LINE
			expect(Log.warn("next")).toBe(true)
			expect(warned[#warned]).toBe(PREFIX .. "next (+3 suppressed)")
			expect(Log.warn("dropped")).toBe(false)
			now = 2 * ONE_LINE
			Log.warn("third")
			expect(warned[#warned]).toBe(PREFIX .. "third (+1 suppressed)")
			now = 3 * ONE_LINE
			Log.warn("clean")
			expect(warned[#warned]).toBe(PREFIX .. "clean")
			expect(Log.suppressed()).toBe(4)
		end)

		it("caps the budget at the burst after a long quiet time", function()
			now = 3600
			local printedLines = 0
			for _ = 1, 100 do
				if Log.warn("x") then
					printedLines += 1
				end
			end
			expect(printedLines).toBe(BUDGET)
		end)

		it("holds a warning flood to 10 lines per minute", function()
			local printedLines = 0
			for i = 0, 5999 do -- 100 warnings per second for 60 s
				now = i / 100
				if Log.warn("flood") then
					printedLines += 1
				end
			end
			expect(printedLines).toBeGreaterThanOrEqual(2 * BUDGET - 1)
			expect(printedLines).toBeLessThanOrEqual(2 * BUDGET)
			expect(Log.suppressed()).toBe(6000 - printedLines)
		end)
	end)

	describe("warnf", function()
		it("formats like string.format", function()
			expect(Log.warnf("uid=%d score %.1f %s", 42, 1.5, "ok")).toBe(true)
			expect(warned[1]).toBe(PREFIX .. "uid=42 score 1.5 ok")
		end)

		it("formats only when the budget allows", function()
			local conversions = 0
			local probe = setmetatable({}, {
				__tostring = function()
					conversions += 1
					return "probe"
				end,
			})
			exhaust()
			expect(Log.warnf("%*", probe)).toBe(false)
			expect(conversions).toBe(0)
			now = ONE_LINE
			expect(Log.warnf("%*", probe)).toBe(true)
			expect(conversions).toBe(1)
			expect(warned[#warned]).toBe(PREFIX .. "probe (+1 suppressed)")
		end)

		it("never throws on a bad format or bad arguments", function()
			expect(function()
				Log.warnf("%d", "not a number")
			end).never.toThrow()
			expect(warned[1]).toContain("%d")
			expect(warned[1]).toContain("bad log format")
		end)
	end)

	describe("warnWith", function()
		it("calls the builder only when the budget allows", function()
			local build = t.spy(function(a: number, b: number)
				return "built " .. a .. " " .. b
			end)
			exhaust()
			expect(Log.warnWith(build.fn, 1, 2)).toBe(false)
			expect(build.count).toBe(0)
			now = ONE_LINE
			expect(Log.warnWith(build.fn, 1, 2)).toBe(true)
			expect(build.count).toBe(1)
			expect(warned[#warned]).toBe(PREFIX .. "built 1 2 (+1 suppressed)")
		end)

		it("survives a failing builder", function()
			local broken = function()
				error("broken")
			end :: any
			expect(Log.warnWith(broken)).toBe(true)
			expect(warned[1]).toContain("log builder failed")
		end)
	end)

	describe("once", function()
		it("prints at most once per key", function()
			Log.once("k", "first")
			Log.once("k", "second")
			Log.once("k", "third")
			Log.once("k2", "other")
			expect(warned).toEqual({ PREFIX .. "first", PREFIX .. "other" })
		end)

		it("uses the budget and spends the key only when the line prints", function()
			exhaust()
			Log.once("k", "suppressed")
			expect(#warned).toBe(BUDGET)
			now = ONE_LINE
			Log.once("k", "printed")
			expect(warned[#warned]).toBe(PREFIX .. "printed (+1 suppressed)")
			now = 10 * ONE_LINE
			Log.once("k", "never")
			expect(warned[#warned]).toBe(PREFIX .. "printed (+1 suppressed)")
		end)
	end)

	describe("studioOnce", function()
		it("prints once per key in Studio, outside the budget", function()
			exhaust()
			Log.studioOnce("hint", "use dot style")
			Log.studioOnce("hint", "use dot style")
			expect(warned[#warned]).toBe(PREFIX .. "use dot style")
			expect(#warned).toBe(BUDGET + 1)
			expect(Log.allowed()).toBe(false)
			expect(Log.suppressed()).toBe(0)
		end)

		it("is silent outside Studio and does not spend the key there", function()
			Log._test.setStudio(false)
			Log.studioOnce("k", "hidden")
			expect(#warned).toBe(0)
			Log._test.setStudio(true)
			Log.studioOnce("k", "shown")
			expect(warned).toEqual({ PREFIX .. "shown" })
		end)

		it("shares one key set with once", function()
			Log.once("shared", "from once")
			Log.studioOnce("shared", "from studioOnce")
			expect(warned).toEqual({ PREFIX .. "from once" })
		end)
	end)

	describe("allowed / suppressed / _reset", function()
		it("allowed() refills but never consumes", function()
			for _ = 1, 100 do
				expect(Log.allowed()).toBe(true)
			end
			expect(Log._test.tokens()).toBe(BUDGET)
			exhaust()
			expect(Log.allowed()).toBe(false)
			now = ONE_LINE
			expect(Log.allowed()).toBe(true)
			expect(Log.allowed()).toBe(true)
		end)

		it("_reset restores the budget, the keys and the counters", function()
			exhaust()
			Log.warn("lost")
			Log._reset()
			Log._test.setSink(nil, function(line: string)
				table.insert(warned, line)
			end)
			Log._test.setClock(function()
				return now
			end)
			expect(Log.suppressed()).toBe(0)
			expect(Log._test.pending()).toBe(0)
			expect(Log.warn("fresh")).toBe(true)
			expect(warned[#warned]).toBe(PREFIX .. "fresh")
			Log.once("k", "again")
			expect(warned[#warned]).toBe(PREFIX .. "again")
		end)

		describe("setDefaultSinks", function()
			-- A test harness may have installed its own defaults for the unit phase: keep them.
			local saved: any = nil
			beforeEach(function()
				saved = Log._test.sinks()
			end)
			afterEach(function()
				Log._test.setDefaultSinks(saved.defaultPrint, saved.defaultWarn)
			end)

			it("replaces the current sinks and the ones _reset restores; nil restores print/warn", function()
				local dPrinted: { string } = {}
				local dWarned: { string } = {}
				local function dPrint(line: string)
					table.insert(dPrinted, line)
				end
				local function dWarn(line: string)
					table.insert(dWarned, line)
				end
				Log._test.setDefaultSinks(dPrint, dWarn)
				-- the current sinks change at once
				Log.info("now")
				expect(Log.warn("now")).toBe(true)
				expect(dPrinted).toEqual({ PREFIX .. "now" })
				expect(dWarned).toEqual({ PREFIX .. "now" })
				expect(#printed + #warned).toBe(0)
				-- and survive _reset
				Log._reset()
				Log.info("after reset")
				Log.warn("after reset")
				expect(dPrinted[2]).toBe(PREFIX .. "after reset")
				expect(dWarned[2]).toBe(PREFIX .. "after reset")
				-- setSink overrides them until the next _reset; its nil means the defaults
				Log._test.setSink(function(line: string)
					table.insert(printed, line)
				end, function(line: string)
					table.insert(warned, line)
				end)
				Log.warn("captured")
				expect(warned).toEqual({ PREFIX .. "captured" })
				expect(#dWarned).toBe(2)
				Log._test.setSink(nil, nil)
				Log.warn("default again")
				expect(dWarned[3]).toBe(PREFIX .. "default again")
				Log._reset()
				local s = Log._test.sinks()
				expect(s.print).toBe(dPrint)
				expect(s.warn).toBe(dWarn)
				-- nil restores the real print/warn, now and for _reset
				Log._test.setDefaultSinks(nil, nil)
				s = Log._test.sinks()
				expect(s.print).toBe(print)
				expect(s.warn).toBe(warn)
				expect(s.defaultPrint).toBe(print)
				expect(s.defaultWarn).toBe(warn)
				Log._reset()
				s = Log._test.sinks()
				expect(s.print).toBe(print)
				expect(s.warn).toBe(warn)
			end)
		end)

		it("starts every line with the Loren prefix", function()
			Log.info("i")
			Log.warn("w")
			Log.warnf("%s", "f")
			Log.once("o", "o")
			Log.studioOnce("s", "s")
			for _, line in printed do
				expect(string.sub(line, 1, #PREFIX)).toBe(PREFIX)
			end
			for _, line in warned do
				expect(string.sub(line, 1, #PREFIX)).toBe(PREFIX)
			end
			expect(#printed + #warned).toBe(5)
		end)
	end)
end
