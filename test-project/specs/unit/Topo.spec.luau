--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runtime = ReplicatedStorage:WaitForChild("LorenRuntime")
local Topo = require(Runtime:WaitForChild("Topo")) :: any

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	-- order(graph): graph = { Name = { deps... } }; names come from the graph keys (or `names`).
	local function order(graph: { [string]: { string } }, names: { string }?): ({ string }, { string })
		local list: { string } = names or {}
		if names == nil then
			for name in graph do
				table.insert(list, name)
			end
		end
		return Topo.order(list, function(name: string): { string }
			return graph[name] or {}
		end)
	end

	describe("order", function()
		it("puts dependencies first (post-order)", function()
			local o, cycles = order({ A = { "B" }, B = { "C" }, C = {} })
			expect(o).toEqual({ "C", "B", "A" })
			expect(cycles).toEqual({})
		end)

		it("sorts independent names", function()
			local o = order({ Zeta = {}, Alpha = {}, Mid = {} })
			expect(o).toEqual({ "Alpha", "Mid", "Zeta" })
		end)

		it("visits dependencies in name order", function()
			local o = order({ A = { "D", "C", "B" }, B = {}, C = {}, D = {} })
			expect(o).toEqual({ "B", "C", "D", "A" })
		end)

		it("handles a diamond once per node", function()
			local o = order({ Top = { "Left", "Right" }, Left = { "Base" }, Right = { "Base" }, Base = {} })
			expect(o).toEqual({ "Base", "Left", "Right", "Top" })
		end)

		it("skips dependencies that are not in names", function()
			local o, cycles = order({ A = { "Proxy", "B" }, B = { "Missing" } }, { "A", "B" })
			expect(o).toEqual({ "B", "A" })
			expect(cycles).toEqual({})
		end)

		it("ignores duplicate names and duplicate dependencies", function()
			local o, cycles = order({ A = { "B", "B" }, B = {} }, { "B", "A", "B", "A" })
			expect(o).toEqual({ "B", "A" })
			expect(cycles).toEqual({})
		end)

		it("does not modify the dependency lists it is given", function()
			local deps = { "C", "B" }
			order({ A = deps, B = {}, C = {} })
			expect(deps).toEqual({ "C", "B" })
		end)

		it("returns empty lists for no names", function()
			local o, cycles = Topo.order({}, function(): { string }
				return {}
			end)
			expect(o).toEqual({})
			expect(cycles).toEqual({})
		end)

		it("is deterministic for equal inputs in any order", function()
			local graph = {
				Data = {},
				Shop = { "Data", "Inventory" },
				Inventory = { "Data" },
				Chat = {},
				Admin = { "Shop", "Chat" },
			}
			local expected = { "Chat", "Data", "Inventory", "Shop", "Admin" }
			expect((order(graph, { "Admin", "Chat", "Data", "Inventory", "Shop" }))).toEqual(expected)
			expect((order(graph, { "Shop", "Inventory", "Data", "Chat", "Admin" }))).toEqual(expected)
			expect((order(graph, { "Data", "Admin", "Shop", "Chat", "Inventory" }))).toEqual(expected)
		end)
	end)

	describe("cycles", function()
		it("reports a two-node cycle as a path and orders it by name", function()
			local o, cycles = order({ A = { "B" }, B = { "A" } })
			expect(cycles).toEqual({ "A -> B -> A" })
			expect(o).toEqual({ "A", "B" })
		end)

		it("reports a self-dependency", function()
			local o, cycles = order({ A = { "A" } })
			expect(cycles).toEqual({ "A -> A" })
			expect(o).toEqual({ "A" })
		end)

		it("reports a longer cycle once, from the first name reached", function()
			local o, cycles = order({ C = { "A" }, A = { "B" }, B = { "C" } })
			expect(cycles).toEqual({ "A -> B -> C -> A" })
			expect(o).toEqual({ "A", "B", "C" })
		end)

		it("keeps dependencies outside the cycle before it and dependents after it", function()
			local o, cycles = order({
				Base = {},
				A = { "B", "Base" },
				B = { "A" },
				Top = { "A" },
			})
			expect(cycles).toEqual({ "A -> B -> A" })
			expect(o).toEqual({ "Base", "A", "B", "Top" })
		end)

		it("reports the cycle path from the node that closes it", function()
			local _, cycles = order({ Entry = { "X" }, X = { "Y" }, Y = { "X" } })
			expect(cycles).toEqual({ "X -> Y -> X" })
		end)

		it("reports separate cycles separately", function()
			local o, cycles = order({ A = { "B" }, B = { "A" }, C = { "D" }, D = { "C" } })
			expect(cycles).toEqual({ "A -> B -> A", "C -> D -> C" })
			expect(o).toEqual({ "A", "B", "C", "D" })
		end)

		it("gives every name exactly once even with cycles", function()
			local o = order({ A = { "B", "C" }, B = { "C", "A" }, C = { "A", "B" }, D = { "A" } })
			expect(#o).toBe(4)
			expect(o[4]).toBe("D")
			expect({ o[1], o[2], o[3] }).toEqual({ "A", "B", "C" })
		end)
	end)
end
