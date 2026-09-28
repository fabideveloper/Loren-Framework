--!strict

-- The bench's Loren members: typed (Spec + T.*) and untyped reference members (*Any).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loren: any = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loren"))
local T = Loren.T
local FLOOD = { 1e7, 1e7 }

local Entity = T.struct({
	id = T.u16,
	position = T.Vector3,
	orientation = T.Vector3,
	health = T.u8,
	alive = T.bool,
	moving = T.bool,
	crouched = T.bool,
})

local Input = T.struct({
	seq = T.u16,
	moveX = T.i8,
	moveZ = T.i8,
	yaw = T.f32,
	jump = T.bool,
	sprint = T.bool,
})

local LorenBench = {
	Client = {},
	Signals = {
		"Bool",
		"Entity",
		"Entities",
		"BoolArray",
		"Pose",
		"EntityUnreliable",
		"BoolAny",
		"EntityAny",
		"EntitiesAny",
		"BoolArrayAny",
		"PoseAny",
	},
	ClientEvents = { "Input", "InputUnreliable", "InputAny" },
	Spec = {
		Bool = Loren.Signal(T.bool),
		Entity = Loren.Signal(Entity),
		Entities = Loren.Signal(T.array(Entity, 100)),
		BoolArray = Loren.Signal(T.array(T.bool, 1000)),
		Pose = Loren.Signal(T.CFrame),
		EntityUnreliable = Loren.Signal(Entity, { Unreliable = true }),
		Input = Loren.Event(Input, { RateLimit = FLOOD }),
		InputUnreliable = Loren.Event(Input, { Unreliable = true, Coalesce = false, RateLimit = FLOOD }),
		InputAny = Loren.Event({ RateLimit = FLOOD }), -- options only = untyped; *Any Signals have no Spec
	},
}

return LorenBench
