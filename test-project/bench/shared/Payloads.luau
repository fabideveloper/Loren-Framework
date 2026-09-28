--!strict
--!optimize 2

-- Payload pools shared by every library: 64 pre-built frames per pool, fixed seeds, f32-exact values.
local Payloads = {}

export type Entity = {
	id: number,
	position: Vector3,
	orientation: Vector3,
	health: number,
	alive: boolean,
	moving: boolean,
	crouched: boolean,
}

export type Input = {
	seq: number,
	moveX: number,
	moveZ: number,
	yaw: number,
	jump: boolean,
	sprint: boolean,
}

export type Kind = "bool" | "id" | "array" | "boolarray" | "pose" | "seq"

export type Def = {
	name: string,
	dir: "s2c" | "c2s",
	event: string,
	mode: "all" | "mixed" | "client",
	perFrame: number,
	kind: Kind,
	reliable: boolean,
	extra: boolean,
	pool: string,
	field: string,
}

export type Pool = {
	frames: { { any } },
	trues: { number },
}

local SEED = 20260928
local FRAMES = 64
local U16 = 65536
local MIXED_PRE = 5
local MIXED_ALL = 100

Payloads.SEED = SEED
Payloads.FRAMES = FRAMES
Payloads.MIXED_PRE = MIXED_PRE
Payloads.MIXED_ALL = MIXED_ALL
Payloads.POSE_STUDS = 0.01
Payloads.POSE_DEGREES = 0.01

local f32buf = buffer.create(4)

local function f32(x: number): number
	buffer.writef32(f32buf, 0, x)
	return buffer.readf32(f32buf, 0)
end
Payloads.f32 = f32

local function vec(rng: Random, range: number): Vector3
	return Vector3.new(
		f32(rng:NextNumber(-range, range)),
		f32(rng:NextNumber(-range, range)),
		f32(rng:NextNumber(-range, range))
	)
end

local function bool(rng: Random): boolean
	return rng:NextInteger(0, 1) == 1
end

local function entity(rng: Random): Entity
	return {
		id = 0,
		position = vec(rng, 1024),
		orientation = vec(rng, math.pi),
		health = rng:NextInteger(0, 255),
		alive = bool(rng),
		moving = bool(rng),
		crouched = bool(rng),
	}
end

local function input(rng: Random): Input
	return {
		seq = 0,
		moveX = rng:NextInteger(-127, 127),
		moveZ = rng:NextInteger(-127, 127),
		yaw = f32(rng:NextNumber(-math.pi, math.pi)),
		jump = bool(rng),
		sprint = bool(rng),
	}
end

local function frames(n: number, make: (i: number) -> any): { { any } }
	local out = table.create(FRAMES) :: { { any } }
	for f = 1, FRAMES do
		local values = table.create(n) :: { any }
		for i = 1, n do
			values[i] = make(i)
		end
		out[f] = values
	end
	return out
end

-- Each pool has its own seed (SEED + index), so it is built on demand yet identical on every machine.
local BUILDERS: { [string]: { index: number, build: (rng: Random) -> { { any } } } } = {
	trues = {
		index = 1,
		build = function(_rng: Random)
			return frames(1000, function()
				return true
			end)
		end,
	},
	randBools = {
		index = 2,
		build = function(rng: Random)
			return frames(1000, function()
				return bool(rng)
			end)
		end,
	},
	fixedEntities = {
		index = 3,
		build = function(rng: Random)
			local fixed = entity(rng)
			return frames(100, function()
				return table.clone(fixed)
			end)
		end,
	},
	randEntities = {
		index = 4,
		build = function(rng: Random)
			return frames(100, function()
				return entity(rng)
			end)
		end,
	},
	entityArrays = {
		index = 5,
		build = function(rng: Random)
			return frames(1, function()
				local list = table.create(100)
				for i = 1, 100 do
					local e = entity(rng)
					e.id = i - 1
					list[i] = e
				end
				return list
			end)
		end,
	},
	inputs = {
		index = 6,
		build = function(rng: Random)
			return frames(1000, function()
				return input(rng)
			end)
		end,
	},
	mixedEntities = {
		index = 7,
		build = function(rng: Random)
			return frames(MIXED_PRE * 2 + MIXED_ALL, function()
				return entity(rng)
			end)
		end,
	},
	boolArrays = {
		index = 8,
		build = function(rng: Random)
			return frames(1, function()
				local list = table.create(1000)
				for i = 1, 1000 do
					list[i] = bool(rng)
				end
				return list
			end)
		end,
	},
	poses = {
		index = 9,
		build = function(rng: Random)
			return frames(100, function()
				local p = vec(rng, 1024)
				local rx, ry, rz = rng:NextNumber(-3, 3), rng:NextNumber(-3, 3), rng:NextNumber(-3, 3)
				return CFrame.new(p) * CFrame.fromOrientation(rx, ry, rz)
			end)
		end,
	},
}

local DEFS: { Def } = {
	{
		name = "bool1000",
		dir = "s2c",
		event = "SBool",
		mode = "all",
		perFrame = 1000,
		kind = "bool",
		reliable = true,
		extra = false,
		pool = "trues",
		field = "",
	},
	{
		name = "randbool1000",
		dir = "s2c",
		event = "SBool",
		mode = "all",
		perFrame = 1000,
		kind = "bool",
		reliable = true,
		extra = false,
		pool = "randBools",
		field = "",
	},
	{
		name = "entity100",
		dir = "s2c",
		event = "SEntity",
		mode = "all",
		perFrame = 100,
		kind = "id",
		reliable = true,
		extra = false,
		pool = "fixedEntities",
		field = "id",
	},
	{
		name = "randentity100",
		dir = "s2c",
		event = "SEntity",
		mode = "all",
		perFrame = 100,
		kind = "id",
		reliable = true,
		extra = false,
		pool = "randEntities",
		field = "id",
	},
	{
		name = "fireall100",
		dir = "s2c",
		event = "SEntities",
		mode = "all",
		perFrame = 1,
		kind = "array",
		reliable = true,
		extra = false,
		pool = "entityArrays",
		field = "id",
	},
	{
		name = "c2s1000",
		dir = "c2s",
		event = "CInput",
		mode = "client",
		perFrame = 1000,
		kind = "seq",
		reliable = true,
		extra = false,
		pool = "inputs",
		field = "seq",
	},
	{
		name = "mixed",
		dir = "s2c",
		event = "SEntity",
		mode = "mixed",
		perFrame = MIXED_PRE * 2 + MIXED_ALL,
		kind = "id",
		reliable = true,
		extra = true,
		pool = "mixedEntities",
		field = "id",
	},
	{
		name = "boolarray",
		dir = "s2c",
		event = "SBoolArray",
		mode = "all",
		perFrame = 1,
		kind = "boolarray",
		reliable = true,
		extra = true,
		pool = "boolArrays",
		field = "",
	},
	{
		name = "pose100",
		dir = "s2c",
		event = "SPose",
		mode = "all",
		perFrame = 100,
		kind = "pose",
		reliable = true,
		extra = true,
		pool = "poses",
		field = "",
	},
	{
		name = "entity100u",
		dir = "s2c",
		event = "SEntityUnreliable",
		mode = "all",
		perFrame = 100,
		kind = "id",
		reliable = false,
		extra = true,
		pool = "randEntities",
		field = "id",
	},
	{
		name = "c2s1000u",
		dir = "c2s",
		event = "CInputUnreliable",
		mode = "client",
		perFrame = 1000,
		kind = "seq",
		reliable = false,
		extra = true,
		pool = "inputs",
		field = "seq",
	},
}

local byName: { [string]: Def } = {}
for _, def in DEFS do
	byName[def.name] = def
end

Payloads.DEFS = DEFS

function Payloads.def(name: string): Def
	local def = byName[name]
	if def == nil then
		error("(LORENঌ - TEST) unknown payload " .. name, 2)
	end
	return def
end

local pools: { [string]: Pool } = {}

local function countTrues(frame: { any }): number
	local n = 0
	for _, v in frame do
		if v == true then
			n += 1
		end
	end
	return n
end

-- The 64-frame pool of a payload, built on first use (never inside a timed loop).
function Payloads.pool(def: Def): Pool
	local cached = pools[def.pool]
	if cached then
		return cached
	end
	local builder = BUILDERS[def.pool]
	local built = builder.build(Random.new(SEED + builder.index))
	local trues = table.create(FRAMES, 0)
	if def.kind == "bool" then
		for f = 1, FRAMES do
			trues[f] = countTrues(built[f])
		end
	end
	local pool: Pool = { frames = built, trues = trues }
	pools[def.pool] = pool
	return pool
end

-- Writes the sequence field of frame `index` (0-based) into its pooled tables; call it outside the timed loop.
function Payloads.stamp(def: Def, frame: { any }, index: number)
	local kind = def.kind
	if kind == "id" or kind == "seq" then
		local field = def.field
		local base = index * def.perFrame
		for i = 1, #frame do
			frame[i][field] = (base + i - 1) % U16
		end
	elseif kind == "array" then
		frame[1][1].id = index % U16
	end
end

-- Expected `true` count after `count` sender frames (bool payloads only).
function Payloads.expectedTrues(def: Def, count: number): number
	if def.kind ~= "bool" then
		return 0
	end
	local trues = Payloads.pool(def).trues
	local full, rest = count // FRAMES, count % FRAMES
	local perCycle = 0
	for f = 1, FRAMES do
		perCycle += trues[f]
	end
	local total = full * perCycle
	for f = 1, rest do
		total += trues[f]
	end
	return total
end

local function sameEntity(a: any, b: Entity, id: number): boolean
	return type(a) == "table"
		and a.id == id
		and a.position == b.position
		and a.orientation == b.orientation
		and a.health == b.health
		and a.alive == b.alive
		and a.moving == b.moving
		and a.crouched == b.crouched
end

local function sameInput(a: any, b: Input, seq: number): boolean
	return type(a) == "table"
		and a.seq == seq
		and a.moveX == b.moveX
		and a.moveZ == b.moveZ
		and a.yaw == b.yaw
		and a.jump == b.jump
		and a.sprint == b.sprint
end

local function closePose(a: any, b: CFrame): boolean
	if typeof(a) ~= "CFrame" then
		return false
	end
	local cf = a :: CFrame
	if (cf.Position - b.Position).Magnitude > Payloads.POSE_STUDS then
		return false
	end
	-- Angle of the relative rotation as atan2(sin, cos): stays exact near 0, where ToAxisAngle can give NaN.
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = (b.Rotation:Inverse() * cf.Rotation):GetComponents()
	local sin = math.sqrt((r21 - r12) ^ 2 + (r02 - r20) ^ 2 + (r10 - r01) ^ 2) / 2
	local cos = (r00 + r11 + r22 - 1) / 2
	return math.atan2(sin, cos) <= math.rad(Payloads.POSE_DEGREES)
end

-- Checks the values captured from the first sender frame against the pool; returns (ok, reason).
function Payloads.check(def: Def, captured: { any }): (boolean, string?)
	local pool = Payloads.pool(def).frames
	local kind = def.kind
	if #captured == 0 then
		return false, "nothing captured"
	end
	if kind == "bool" then
		local frame = pool[1]
		for i, v in captured do
			if v ~= frame[i] then
				return false, string.format("bool %d is %s", i, tostring(v))
			end
		end
	elseif kind == "boolarray" then
		local expected = pool[1][1]
		local got = captured[1]
		if type(got) ~= "table" or #got ~= #expected then
			return false, "array length"
		end
		for i, v in expected do
			if got[i] ~= v then
				return false, string.format("element %d differs", i)
			end
		end
	elseif kind == "array" then
		local expected = pool[1][1]
		local got = captured[1]
		if type(got) ~= "table" or #got ~= #expected then
			return false, "array length"
		end
		for i, e in expected do
			if not sameEntity(got[i], e, if i == 1 then 0 else e.id) then
				return false, string.format("element %d differs", i)
			end
		end
	elseif kind == "pose" then
		local frame = pool[1]
		for i, v in captured do
			if not closePose(v, frame[i]) then
				return false, string.format("pose %d is off by more than %.2g stud / %.2g deg", i, 0.01, 0.01)
			end
		end
	else
		local per = def.perFrame
		local field = def.field
		for i, v in captured do
			local raw: any = if type(v) == "table" then v[field] else nil
			if type(raw) ~= "number" or raw % 1 ~= 0 or raw < 0 or raw >= U16 then
				return false, string.format("value %d has no valid %s", i, field)
			end
			local seq: number = raw
			local expected = pool[(seq // per) % FRAMES + 1][seq % per + 1]
			local same = if kind == "seq" then sameInput(v, expected, seq) else sameEntity(v, expected, seq)
			if not same then
				return false, string.format("%s %d differs", field, seq)
			end
		end
	end
	return true, nil
end

return Payloads
