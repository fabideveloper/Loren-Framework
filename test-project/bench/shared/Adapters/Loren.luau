--!strict
--!optimize 2

-- Loren (the real runtime) as two rows: typed (Spec + T.*) and untyped (*Any members, no Spec).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

local TYPED: { [string]: string } = {
	SBool = "Bool",
	SEntity = "Entity",
	SEntities = "Entities",
	SBoolArray = "BoolArray",
	SPose = "Pose",
	SEntityUnreliable = "EntityUnreliable",
	CInput = "Input",
	CInputUnreliable = "InputUnreliable",
}

-- Unreliable members need typed Args, so the untyped row has no unreliable payloads.
local UNTYPED: { [string]: string } = {
	SBool = "BoolAny",
	SEntity = "EntityAny",
	SEntities = "EntitiesAny",
	SBoolArray = "BoolArrayAny",
	SPose = "PoseAny",
	CInput = "InputAny",
}

-- Server limits raised so the bench measures work, not refusals (the checks still run).
local FLOOD_CONFIG = {
	FrameRate = 1e6,
	FrameBurst = 1e6,
	ByteRate = 1e9,
	ByteBurst = 1e9,
	MessageRate = 1e7,
	MessageBurst = 1e7,
	EventRate = 1e7,
	EventBurst = 1e7,
	UnreliableEventRate = 1e7,
	UnreliableEventBurst = 1e7,
}

local Loren: any = nil
local service: any = nil

local R: any = {
	key = "loren",
	name = "Loren",
	sender = "FireClient per player on one reliable remote",
	flush = nil,
	sizeOf = nil,
}

-- Loren's sender calls are measured (GetStats FramesOut).
function R.txModel(_def: any): string
	return "measured"
end

local function netRemotes(wait: boolean): { Instance }
	local net = if wait
		then ReplicatedStorage:WaitForChild("LorenNet")
		else ReplicatedStorage:FindFirstChild("LorenNet")
	if net == nil then
		return {}
	end
	local out = {}
	for _, name in { "Reliable", "Unreliable" } do
		local remote = if wait then net:WaitForChild(name) else net:FindFirstChild(name)
		if remote then
			table.insert(out, remote)
		end
	end
	return out
end

function R.waitRemotes(): { Instance }
	return netRemotes(true)
end

function R.remotes(): { Instance }
	return netRemotes(false)
end

local function adapter(lib: string, map: { [string]: string }): any
	local a: any = { lib = lib }

	function a.has(event: string): boolean
		return map[event] ~= nil
	end

	-- The method is looked up once, like the other adapters' cached library functions.
	function a.toPlayer(event: string): ((Player, any) -> ())?
		local name = map[event]
		if name == nil then
			return nil
		end
		local signal = service.Signals[name]
		local fire = signal.Fire
		return function(player: Player, value: any)
			fire(signal, player, value)
		end
	end

	function a.toAll(event: string): ((any) -> ())?
		local name = map[event]
		if name == nil then
			return nil
		end
		local signal = service.Signals[name]
		local fireAll = signal.FireAll
		return function(value: any)
			fireAll(signal, value)
		end
	end

	function a.toServer(event: string): ((any) -> ())?
		local name = map[event]
		if name == nil then
			return nil
		end
		local clientEvent = service.ClientEvents[name]
		local fire = clientEvent.Fire
		return function(value: any)
			fire(clientEvent, value)
		end
	end

	-- Server: ClientEvents (fn(player, value)). Client: Signals (fn(value)).
	function a.connect(event: string, fn: (any, any) -> ()): boolean
		local name = map[event]
		if name == nil then
			return false
		end
		if IS_SERVER then
			service.ClientEvents[name]:Connect(fn)
		else
			service.Signals[name]:Connect(fn)
		end
		return true
	end

	return a
end

function R.setup(): { [string]: any }
	Loren = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loren")) :: any
	if IS_SERVER then
		local ServerStorage = game:GetService("ServerStorage")
		Loren.Configure(FLOOD_CONFIG)
		Loren.AddServices(ServerStorage:WaitForChild("Bench"):WaitForChild("Services"))
	end
	local fired, value = Loren.SetOnFire():await()
	if not fired then
		error("SetOnFire rejected: " .. tostring(value), 0)
	end
	local ready, why = Loren.OnReady():await()
	if not ready then
		error("OnReady rejected: " .. tostring(why), 0)
	end
	service = Loren.GetService("LorenBench")
	R.name = "Loren " .. tostring(Loren.Version)
	R.flush = Loren.Flush
	return { loren = adapter("loren", TYPED), ["loren-untyped"] = adapter("loren-untyped", UNTYPED) }
end

function R.ready() end

-- The facade after setup (GetStats), or nil.
function R.loren(): any
	return Loren
end

return R
