--!strict
-- 2.0 Signals on the server: ServerSignal objects (Fire side only), target and argument checks at
-- the caller's line, FireFor / FireExcept, BootSignal to every player, and departed players.
local Players = game:GetService("Players")

local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local noPlayers = not V2.hasPlayers()
	local evidence = { skip = noPlayers, timeout = V2.TEST_TIMEOUT }
	local loaded, probe = pcall(V2.probe)
	local noDeparted = not loaded or probe.departed == nil

	local function hit(): any
		return V2.service().Signals.Hit
	end

	describe("v2 ServerSignal objects", function()
		it("Signals is a frozen map whose unknown keys raise", function()
			local signals = V2.service().Signals
			expect(table.isfrozen(signals)).toBe(true)
			expect(function()
				return signals.NoSuchSignal
			end).toThrow()
		end)

		it("Connect / Once / Wait raise: Signals go from server to client", function()
			local signal = hit()
			expect(function()
				signal:Connect(function() end)
			end).toThrow()
			expect(function()
				signal:Once(function() end)
			end).toThrow()
			expect(function()
				signal:Wait()
			end).toThrow()
		end)

		it("a dot call raises (Fire needs ':')", function()
			local signal = hit()
			expect(function()
				signal.FireAll("x", 1)
			end).toThrow()
		end)
	end)

	describe("v2 Fire targets", function()
		it("Fire needs a Player", function()
			local signal = hit()
			expect(function()
				signal:Fire(nil, "x", 1)
			end).toThrow("Player")
			expect(function()
				signal:Fire(workspace, "x", 1)
			end).toThrow("Player")
		end)

		it("FireFor takes an array of Players; an empty array sends nothing", function()
			local signal = hit()
			signal:FireFor({}, "srv:none", 1)
			expect(function()
				signal:FireFor("x", "srv", 1)
			end).toThrow("FireFor")
			expect(function()
				signal:FireFor({ workspace }, "srv", 1)
			end).toThrow("entry 1")
		end)

		it("FireExcept takes a Player or an array of Players", function()
			local signal = hit()
			signal:FireExcept(Players:GetPlayers(), "srv:nobody", 2)
			expect(function()
				signal:FireExcept(nil, "srv", 1)
			end).toThrow("FireExcept")
			expect(function()
				signal:FireExcept({ workspace }, "srv", 1)
			end).toThrow("entry 1")
		end)

		it("FireFor and FireExcept accept the players in the game", function()
			local signal = hit()
			local players = Players:GetPlayers()
			signal:FireFor(players, "srv:for", 3)
			if #players > 0 then
				signal:FireExcept(players[1], "srv:except", 4)
			end
		end, { skip = noPlayers })
	end)

	describe("v2 typed Fire arguments", function()
		it("a wrong type, a value out of range or too long raises at the caller", function()
			local signal = hit()
			expect(function()
				signal:FireAll(5, 1)
			end).toThrow("arg 1")
			expect(function()
				signal:FireAll("x", 70000)
			end).toThrow("arg 2")
			expect(function()
				signal:FireAll(string.rep("x", 65), 1)
			end).toThrow("arg 1")
		end)

		it("a non-finite f64 raises (AllowNonFinite is off)", function()
			local stream = V2.service().Signals.Stream
			expect(function()
				stream:FireAll(1, 1, 0 / 0)
			end).toThrow("arg 3")
			expect(function()
				stream:FireAll(1, 1, math.huge)
			end).toThrow("arg 3")
		end)
	end)

	describe("v2 Signal deliveries (driven by specs/v2/client)", function()
		it("BootSignal went to every player (FireAll in LorenBurn, Fire on join)", function()
			local probe = V2.probe()
			expect(probe.burnFireError).toBeNil()
			for _, player in Players:GetPlayers() do
				expect(probe.bootSent[player]).toBe(true)
			end
			expect(probe.bootFired.burn + probe.bootFired.join).toBeGreaterThanOrEqual(#Players:GetPlayers())
		end, { skip = noPlayers })

		it("FireFor and FireExcept requested by clients ran without errors", function()
			local probe = V2.probe()
			V2.await("hitFor and hitExcept commands", function()
				return V2.count(probe.hits, "hitFor") > 0 and V2.count(probe.hits, "hitExcept") > 0
			end)
			expect(probe.fireErrors).toBe(0)
		end, evidence)

		it("an unreliable typed Stream was fired", function()
			local probe = V2.probe()
			V2.await("a stream command", function()
				return probe.streams > 0
			end)
			expect(probe.fireErrors).toBe(0)
		end, evidence)

		it("firing at a player who left is a counted no-op (needs a player who left)", function()
			local departed = V2.probe().departed
			local Loren = V2.loren()
			local before = Loren.GetStats().SignalsDropped
			hit():Fire(departed, "srv:gone", 5)
			hit():FireFor({ departed }, "srv:gone", 6)
			expect(Loren.GetStats().SignalsDropped).toBeGreaterThan(before)
		end, { skip = noDeparted })
	end)
end
