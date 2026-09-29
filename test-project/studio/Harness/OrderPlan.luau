--!strict

local OrderPlan = {}

export type Step = {
	op: string,
	sig: string?,
	to: string?,
	set: { string }?,
	tag: string?,
	ref: string?,
	after: string?,
	key: string?,
	count: number?,
}

OrderPlan.ROLES = { "A", "B", "C", "D", "E", "F", "G", "H" }

local STEPS: { Step } = {
	{ op = "fire", to = "A", tag = "1.01" },
	{ op = "all", tag = "1.02" },
	{ op = "all", sig = "Pos", tag = "116" },
	{ op = "all", tag = "1.03" },
	{ op = "fire", to = "A", tag = "1.04" },
	{ op = "fire", sig = "Pos", to = "A", tag = "117" },
	{ op = "fire", to = "B", tag = "1.05" },
	{ op = "for", set = { "A", "B" }, tag = "1.06" },
	{ op = "for", sig = "Pos", set = { "B", "C" }, tag = "118" },
	{ op = "except", to = "A", tag = "1.07" },
	{ op = "ok", to = "A", key = "a1", tag = "1.08" },
	{ op = "all", tag = "1.09" },
	{ op = "err", to = "B", key = "b1", tag = "1.10" },
	{ op = "except", set = { "B", "C" }, tag = "1.11" },
	{ op = "notice", to = "C", count = 5 },
	{ op = "fire", to = "C", tag = "1.12" },
	{ op = "for", set = { "C" }, tag = "1.13" },
	{ op = "all", tag = "1.14" },
	{ op = "drop", to = "A", count = 3 },
	{ op = "fire", to = "A", tag = "1.15" },
	{ op = "flush" },
	{ op = "all", tag = "2.01" },
	{ op = "fire", to = "B", tag = "2.02" },
	{ op = "okFire", to = "A", key = "a2", tag = "2.03" },
	{ op = "fire", to = "A", tag = "2.04" },
	{ op = "err", to = "C", key = "c1", tag = "2.05" },
	{ op = "all", tag = "2.06" },
	{ op = "except", sig = "Pos", to = "B", tag = "208" },
	{ op = "notice", to = "B", count = 2 },
	{ op = "except", to = "C", tag = "2.07" },
	{ op = "fire", sig = "Pos", to = "C", tag = "209" },
	{ op = "flush" },
	{ op = "wait" },
	{ op = "fire", to = "A", tag = "3.01", ref = "R1", after = "x1" },
	{ op = "all", tag = "3.02", ref = "R2", after = "x2" },
	{ op = "fire", to = "A", tag = "3.03", ref = "R3", after = "x3" },
	{ op = "all", tag = "3.04", ref = "gui:A", after = "x4" },
	{ op = "fire", to = "B", tag = "3.05", ref = "hidden", after = "x5" },
	{ op = "all", sig = "Obj", tag = "3.06", ref = "gui:B", after = "x6" },
	{ op = "all", sig = "Req", tag = "3.07", ref = "gui:A", after = "x7" },
	{ op = "all", tag = "3.08", ref = "orphan", after = "x8" },
	{ op = "for", set = { "A", "C" }, tag = "3.09", ref = "R1", after = "x9" },
	{ op = "ok", to = "B", key = "b2", tag = "3.10" },
	{ op = "flush" },
	{ op = "all", tag = "4.01", ref = "R1", after = "y1" },
	{ op = "all", tag = "4.02", ref = "gui:B", after = "y2" },
	{ op = "all", sig = "Req", tag = "4.03", ref = "gui:A", after = "y3" },
	{ op = "all", tag = "4.04", ref = "hidden", after = "y4" },
	{ op = "all", sig = "Pos", tag = "405" },
	{ op = "flush" },
	{ op = "all", tag = "5.01" },
	{ op = "fire", to = "A", tag = "5.02" },
	{ op = "all", tag = "5.03" },
	{ op = "all", sig = "Pos", tag = "504" },
	{ op = "flush" },
}

local function has(list: { string }, role: string): boolean
	return table.find(list, role) ~= nil
end

local function refRole(ref: string?): string?
	return if ref ~= nil and string.sub(ref, 1, 4) == "gui:" then string.sub(ref, 5) else nil
end

function OrderPlan.steps(roles: { string }): { Step }
	local out: { Step } = {}
	for _, step in STEPS do
		local owner = refRole(step.ref)
		if (step.to ~= nil and not has(roles, step.to)) or (owner ~= nil and not has(roles, owner)) then
			continue
		end
		local copy = table.clone(step)
		if step.set then
			local kept: { string } = {}
			for _, role in step.set do
				if has(roles, role) then
					table.insert(kept, role)
				end
			end
			copy.set = kept
		end
		table.insert(out, copy)
	end
	return out
end

function OrderPlan.keys(role: string, roles: { string }): { string }
	local out: { string } = {}
	for _, step in OrderPlan.steps(roles) do
		if step.key ~= nil and step.to == role then
			table.insert(out, step.key)
		end
	end
	return out
end

function OrderPlan.refName(ref: string, role: string): string
	local owner = refRole(ref)
	if owner ~= nil then
		return if owner == role then "gui" else "nil"
	elseif ref == "R1" or ref == "R2" or ref == "R3" then
		return ref
	end
	return "nil"
end

function OrderPlan.entry(kind: string, tag: string, ref: string?, after: string?, drops: number, lost: number): string
	local text = kind .. " " .. tag
	if ref ~= nil then
		text ..= " ref=" .. ref .. " after=" .. tostring(after)
	end
	return string.format("%s d%d l%d", text, drops, lost)
end

local function receives(step: Step, role: string): boolean
	local op = step.op
	if op == "all" then
		return true
	elseif op == "fire" then
		return step.to == role
	elseif op == "for" then
		return has(step.set or {}, role)
	elseif op == "except" then
		if step.to ~= nil then
			return step.to ~= role
		end
		return not has(step.set or {}, role)
	end
	return false
end

function OrderPlan.expected(role: string, roles: { string }): { string }
	local out: { string } = {}
	local drops, lost, pending = 0, 0, 0
	for _, step in OrderPlan.steps(roles) do
		local op = step.op
		local tag = step.tag or ""
		if op == "flush" then
			drops += pending
			pending = 0
		elseif op == "notice" then
			if step.to == role then
				drops += step.count or 0
			end
		elseif op == "drop" then
			if step.to == role then
				pending += step.count or 0
			end
		elseif op == "ok" or op == "err" or op == "okFire" then
			if step.to == role then
				if op == "okFire" then
					table.insert(out, OrderPlan.entry("Seq", tag .. "s", nil, nil, drops, lost))
				end
				local kind = if op == "err" then "err" else "ok"
				local text = if op == "err" then "Rejected:" .. tag else tag
				table.insert(out, OrderPlan.entry(kind, text, nil, nil, drops, lost))
			end
		elseif receives(step, role) then
			local sig = step.sig or "Seq"
			local ref = step.ref
			if ref == nil then
				table.insert(out, OrderPlan.entry(sig, tag, nil, nil, drops, lost))
			else
				local name = OrderPlan.refName(ref, role)
				if sig == "Req" and name == "nil" then
					lost += 1
				else
					table.insert(out, OrderPlan.entry(sig, tag, name, step.after, drops, lost))
				end
			end
		end
	end
	return out
end

return table.freeze(OrderPlan)
