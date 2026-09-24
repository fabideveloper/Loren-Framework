--!strict
--!optimize 2
--[[
	Topo (owner lane: lifecycle): the Ignite/Burn order.
	Spec: IMPLEMENTATION.md section 3.10; robust.md section 5.5.

	A depth-first post-order over the declared dependencies with names sorted at every level, so the
	order is deterministic and every dependency outside a cycle comes before its dependents.
	Dependencies that are not in `names` are skipped (client proxies, unknown names). A back edge adds
	one cycle string "A -> B -> A". The members of a cycle (a strongly connected component, found with
	Tarjan's lowlinks during the same walk) are emitted together, in name order, after everything they
	depend on outside the cycle. Pure: no state, no side effects.
]]

local Topo = {}

function Topo.order(names: { string }, depsOf: (name: string) -> { string }): ({ string }, { string })
	local sorted: { string } = {}
	local known: { [string]: boolean } = {}
	for _, name in names do
		if not known[name] then
			known[name] = true
			table.insert(sorted, name)
		end
	end
	table.sort(sorted)

	local index: { [string]: number } = {} -- visit number (Tarjan)
	local low: { [string]: number } = {} -- lowlink (Tarjan)
	local onStack: { [string]: boolean } = {}
	local sccStack: { string } = {}
	local path: { string } = {} -- the current DFS path (back edges point into it)
	local counter = 0
	local order: { string } = {}
	local cycles: { string } = {}

	local function visit(name: string)
		counter += 1
		index[name] = counter
		low[name] = counter
		table.insert(sccStack, name)
		onStack[name] = true
		table.insert(path, name)

		-- A sorted copy without duplicates (depsOf may return a table we must not touch).
		local declared = depsOf(name)
		local deps: { string } = {}
		local seen: { [string]: boolean } = {}
		for _, dep in declared do
			if known[dep] and not seen[dep] then
				seen[dep] = true
				table.insert(deps, dep)
			end
		end
		table.sort(deps)

		for _, dep in deps do
			local di = index[dep]
			if di == nil then
				visit(dep)
				if low[dep] < low[name] then
					low[name] = low[dep]
				end
			elseif onStack[dep] then
				if di < low[name] then
					low[name] = di
				end
				local from = table.find(path, dep)
				if from then
					table.insert(cycles, table.concat(path, " -> ", from) .. " -> " .. dep)
				end
			end
		end
		table.remove(path)

		if low[name] == index[name] then
			local members: { string } = {}
			repeat
				local top = table.remove(sccStack) :: string
				onStack[top] = false
				table.insert(members, top)
			until top == name
			if #members > 1 then
				table.sort(members)
			end
			table.move(members, 1, #members, #order + 1, order)
		end
	end

	for _, name in sorted do
		if index[name] == nil then
			visit(name)
		end
	end
	return order, cycles
end

return table.freeze(Topo)
