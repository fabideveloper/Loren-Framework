--!strict
--!optimize 2

-- BlinkBlox 0.41.2 generated modules (bench/libs/blinkblox): X.Fire / X.FireAll / X.On, StepReplication.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local RELIABLE = "BLINKBLOX_BLINK_RELIABLE_REMOTE"
local UNRELIABLE = "BLINKBLOX_BLINK_UNRELIABLE_REMOTE"

local mod: any = nil

local R: any = {
	key = "blinkblox",
	name = "BlinkBlox 0.41.2",
	sender = "FireAllClients when nobody diverged, else FireClient per player",
	flush = nil,
	sizeOf = nil,
}

-- StepReplication: one FireAllClients unless a player has own traffic (mixed diverges everyone).
function R.txModel(def: any): string
	return if def.mode == "mixed" then "each" else "all"
end

function R.waitRemotes(): { Instance }
	return { ReplicatedStorage:WaitForChild(RELIABLE), ReplicatedStorage:WaitForChild(UNRELIABLE) }
end

function R.remotes(): { Instance }
	local out = {}
	for _, name in { RELIABLE, UNRELIABLE } do
		local remote = ReplicatedStorage:FindFirstChild(name)
		if remote then
			table.insert(out, remote)
		end
	end
	return out
end

local function member(event: string, key: string): any
	local e: any = mod[event]
	return if type(e) == "table" then (e :: any)[key] else nil
end

local a: any = { lib = "blinkblox" }

function a.has(event: string): boolean
	return mod[event] ~= nil
end

-- Wrapped in one closure, like every other adapter, so each fire costs the same bench overhead.
function a.toPlayer(event: string): ((Player, any) -> ())?
	local found: any = member(event, "Fire")
	if found == nil then
		return nil
	end
	local fire: (...any) -> () = found
	return function(player: Player, value: any)
		fire(player, value)
	end
end

function a.toAll(event: string): ((any) -> ())?
	local found: any = member(event, "FireAll")
	if found == nil then
		return nil
	end
	local fireAll: (...any) -> () = found
	return function(value: any)
		fireAll(value)
	end
end

function a.toServer(event: string): ((any) -> ())?
	local found: any = member(event, "Fire")
	if found == nil then
		return nil
	end
	local fire: (...any) -> () = found
	return function(value: any)
		fire(value)
	end
end

-- Server: fn(player, value). Client: fn(value). SingleSync: the listener must not yield.
function a.connect(event: string, fn: (any, any) -> ()): boolean
	local on: any = member(event, "On")
	local missing = on == nil
	if missing then
		return false
	end
	on(fn)
	return true
end

function R.setup(): { [string]: any }
	if IS_SERVER then
		mod = require(game:GetService("ServerStorage"):WaitForChild("Bench"):WaitForChild("BlinkBloxServer")) :: any
	else
		mod =
			require(ReplicatedStorage:WaitForChild("Bench"):WaitForChild("Libs"):WaitForChild("BlinkBloxClient")) :: any
	end
	R.flush = mod.StepReplication
	return { blinkblox = a }
end

function R.ready() end

return R
