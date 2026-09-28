--!strict
--!optimize 2

-- ByteNet 0.4.6 (bench/libs/bytenet): packets in one namespace; it flushes itself on Heartbeat.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local NAMESPACE = "LorenSignalBench"

local packets: any = nil

local R: any = {
	key = "bytenet",
	name = "ByteNet 0.4.6",
	sender = "FireAllClients for sendToAll, FireClient per player otherwise",
	flush = nil,
	sizeOf = nil,
}

-- Its Heartbeat sends the shared channel with one FireAllClients, then each player's own channel.
function R.txModel(def: any): string
	return if def.mode == "mixed" then "all+each" else "all"
end

function R.waitRemotes(): { Instance }
	return { ReplicatedStorage:WaitForChild("ByteNetReliable"), ReplicatedStorage:WaitForChild("ByteNetUnreliable") }
end

function R.remotes(): { Instance }
	local out = {}
	for _, name in { "ByteNetReliable", "ByteNetUnreliable" } do
		local remote = ReplicatedStorage:FindFirstChild(name)
		if remote then
			table.insert(out, remote)
		end
	end
	return out
end

-- ByteNet calls server listeners with (value, player); the bench builds its listener in that order.
local a: any = { lib = "bytenet", swapServerArgs = true }

function a.has(event: string): boolean
	return packets[event] ~= nil
end

-- Wrapped in one closure, like every other adapter, so each fire costs the same bench overhead.
function a.toPlayer(event: string): ((Player, any) -> ())?
	local packet = packets[event]
	if packet == nil then
		return nil
	end
	local sendTo = packet.sendTo
	return function(player: Player, value: any)
		sendTo(value, player)
	end
end

-- One shared buffer, one FireAllClients per channel per frame.
function a.toAll(event: string): ((any) -> ())?
	local packet = packets[event]
	if packet == nil then
		return nil
	end
	local sendToAll = packet.sendToAll
	return function(value: any)
		sendToAll(value)
	end
end

function a.toServer(event: string): ((any) -> ())?
	local packet = packets[event]
	if packet == nil then
		return nil
	end
	local send = packet.send
	return function(value: any)
		send(value)
	end
end

function a.connect(event: string, fn: (any, any) -> ()): boolean
	local packet = packets[event]
	if packet == nil then
		return false
	end
	packet.listen(fn)
	return true
end

function R.setup(): { [string]: any }
	local B: any = require(ReplicatedStorage:WaitForChild("Bench"):WaitForChild("Libs"):WaitForChild("ByteNet")) :: any
	if not IS_SERVER then
		-- The client builds packet ids and struct field order from this StringValue.
		ReplicatedStorage:WaitForChild("BytenetStorage"):WaitForChild(NAMESPACE)
	end
	local function entity(): any
		return B.struct({
			id = B.uint16,
			position = B.vec3,
			orientation = B.vec3,
			health = B.uint8,
			alive = B.bool,
			moving = B.bool,
			crouched = B.bool,
		})
	end
	local function input(): any
		return B.struct({
			seq = B.uint16,
			moveX = B.int8,
			moveZ = B.int8,
			yaw = B.float32,
			jump = B.bool,
			sprint = B.bool,
		})
	end
	packets = B.defineNamespace(NAMESPACE, function()
		return {
			SBool = B.definePacket({ value = B.bool }),
			SBoolArray = B.definePacket({ value = B.array(B.bool) }),
			SEntity = B.definePacket({ value = entity() }),
			SEntities = B.definePacket({ value = B.array(entity()) }),
			SEntityUnreliable = B.definePacket({ value = entity(), reliabilityType = "unreliable" }),
			SPose = B.definePacket({ value = B.cframe }),
			CBool = B.definePacket({ value = B.bool }),
			CBoolArray = B.definePacket({ value = B.array(B.bool) }),
			CEntity = B.definePacket({ value = entity() }),
			CInput = B.definePacket({ value = input() }),
			CInputUnreliable = B.definePacket({ value = input(), reliabilityType = "unreliable" }),
		}
	end)
	return { bytenet = a }
end

function R.ready() end

return R
