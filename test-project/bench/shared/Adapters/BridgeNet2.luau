--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

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

function R.ready()
	ReplicatedStorage:WaitForChild("BridgeNet2"):WaitForChild("dataRemoteEvent")
	if not IS_SERVER then
		task.wait(1)
	end
end

return R
