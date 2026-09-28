--!strict
--!optimize 2

-- BridgeNet2 1.0.0 (bench/libs/bridgenet2): plain Luau tables, flushed and decoded on PostSimulation.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

-- The same events as the .blink schemas; 1.0.0 has no unreliable channel, so those are n/a.
local EVENTS = { "SBool", "SBoolArray", "SEntity", "SEntities", "SPose", "CBool", "CBoolArray", "CEntity", "CInput" }

local BridgeNet2: any = nil
local bridges: { [string]: any } = {}

local R: any = {
	key = "bridgenet2",
	name = "BridgeNet2 1.0.0",
	sender = "FireClient per player (tables, serialized again per player)",
	flush = nil,
	sizeOf = nil,
}

-- Its PostSimulation sends one FireClient per player with traffic.
function R.txModel(_def: any): string
	return "each"
end

local function libs(): Instance
	return ReplicatedStorage:WaitForChild("Bench"):WaitForChild("Libs")
end

function R.waitRemotes(): { Instance }
	return { ReplicatedStorage:WaitForChild("BridgeNet2"):WaitForChild("dataRemoteEvent") }
end

function R.remotes(): { Instance }
	local folder = ReplicatedStorage:FindFirstChild("BridgeNet2")
	local remote = if folder then folder:FindFirstChild("dataRemoteEvent") else nil
	return if remote then { remote } else {}
end

local a: any = { lib = "bridgenet2" }

function a.has(event: string): boolean
	return bridges[event] ~= nil
end

-- Wrapped in one closure, like every other adapter; the method is looked up once.
function a.toPlayer(event: string): ((Player, any) -> ())?
	local bridge = bridges[event]
	if bridge == nil then
		return nil
	end
	local fire = bridge.Fire
	return function(player: Player, value: any)
		fire(bridge, player, value)
	end
end

-- Queued per frame, then one FireClient per player (no FireAllClients).
function a.toAll(event: string): ((any) -> ())?
	local bridge = bridges[event]
	if bridge == nil then
		return nil
	end
	local fire = bridge.Fire
	local all = BridgeNet2.AllPlayers()
	return function(value: any)
		fire(bridge, all, value)
	end
end

function a.toServer(event: string): ((any) -> ())?
	local bridge = bridges[event]
	if bridge == nil then
		return nil
	end
	local fire = bridge.Fire
	return function(value: any)
		fire(bridge, value)
	end
end

-- Server: fn(player, value). Client: fn(value). Same signatures as BridgeNet2's Connect.
function a.connect(event: string, fn: (any, any) -> ()): boolean
	local bridge = bridges[event]
	if bridge == nil then
		return false
	end
	bridge:Connect(fn)
	return true
end

function R.setup(): { [string]: any }
	local package = libs():WaitForChild("BridgeNet2")
	BridgeNet2 = require(package) :: any
	local counter: any = require(package:WaitForChild("RemotePacketSizeCounter")) :: any
	R.sizeOf = counter.GetDataByteSize
	for _, name in EVENTS do
		bridges[name] = BridgeNet2.ReferenceBridge(name)
	end
	return { bridgenet2 = a }
end

-- The client says it loaded 15 frames after BridgeNet2 starts; until then the server queues its traffic.
function R.ready()
	ReplicatedStorage:WaitForChild("BridgeNet2"):WaitForChild("dataRemoteEvent")
	if not IS_SERVER then
		task.wait(1)
	end
end

return R
