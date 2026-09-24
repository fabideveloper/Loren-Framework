--!strict
--!optimize 2
--[[
	Coordinator: server <-> client harness messages over two plain RemoteEvents, kept apart from
	the framework under test (the Exploiter skips ReplicatedStorage.LorenTest):
		TestControl  server -> client  { cmd = "check" | "start" | "stop" | "done", runId, ... }
		TestReport   client -> server  { kind = "hello" | "check" | "started" | "result" | "log", runId, ... }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coordinator = {}

export type ClientInfo = {
	player: Player,
	name: string,
	runtime: string,
	label: string,
	bootOk: boolean,
	bootError: string?,
	bootMs: number,
	joinedAt: number,
}

local control: RemoteEvent = nil :: any
local clients: { [Player]: ClientInfo } = {}
local inbox: { [string]: { [Player]: any } } = {}
local lastHello = 0
local runCounter = 0

local function key(kind: string, runId: any): string
	return kind .. ":" .. tostring(runId)
end

function Coordinator.init()
	local folder = ReplicatedStorage:WaitForChild("LorenTest")
	local report = Instance.new("RemoteEvent")
	report.Name = "TestReport"
	report.OnServerEvent:Connect(function(player, message)
		if typeof(message) ~= "table" or typeof(message.kind) ~= "string" then
			return
		end
		if message.kind == "hello" then
			local info: ClientInfo = {
				player = player,
				name = player.Name,
				runtime = tostring(message.runtime),
				label = tostring(message.label),
				bootOk = message.bootOk == true,
				bootError = if typeof(message.bootError) == "string" then message.bootError else nil,
				bootMs = if typeof(message.bootMs) == "number" then message.bootMs else 0,
				joinedAt = os.clock(),
			}
			clients[player] = info
			lastHello = os.clock()
			print(
				string.format(
					"(LORENঌ - TEST) client %s ready: %s, boot %s in %.0f ms%s",
					player.Name,
					info.label,
					if info.bootOk then "ok" else "FAILED",
					info.bootMs,
					if info.bootError then " (" .. info.bootError .. ")" else ""
				)
			)
		elseif message.kind == "log" then
			print("(LORENঌ - TEST) [" .. player.Name .. "] " .. tostring(message.text))
		else
			local k = key(message.kind, message.runId)
			local box = inbox[k]
			if not box then
				box = {}
				inbox[k] = box
			end
			box[player] = message
		end
	end)
	report.Parent = folder

	control = Instance.new("RemoteEvent")
	control.Name = "TestControl"
	control.Parent = folder

	Players.PlayerRemoving:Connect(function(player)
		clients[player] = nil
	end)
end

function Coordinator.nextRunId(): number
	runCounter += 1
	return runCounter
end

function Coordinator.info(player: Player): ClientInfo?
	return clients[player]
end

-- Players whose client harness said hello and who are still in the game, sorted by name.
function Coordinator.active(): { Player }
	local list = {}
	for player in clients do
		if player.Parent == Players then
			table.insert(list, player)
		end
	end
	table.sort(list, function(a: Player, b: Player)
		return a.Name < b.Name
	end)
	return list
end

-- Waits until `expected` clients said hello; or at least one did, nobody else is still loading
-- and none said hello for `settle` s; or `maxWait` s passed. Returns the active clients.
function Coordinator.waitForClients(expected: number, maxWait: number, settle: number): { Player }
	local deadline = os.clock() + maxWait
	while os.clock() < deadline do
		local count = #Coordinator.active()
		if count >= expected then
			break
		end
		local loading = #Players:GetPlayers() > count
		if count > 0 and not loading and os.clock() - lastHello >= settle then
			break
		end
		task.wait(0.25)
	end
	return Coordinator.active()
end

function Coordinator.send(player: Player, message: { [string]: any })
	if player.Parent == Players then
		control:FireClient(player, message)
	end
end

-- Waits for one `kind` message per player for runId. Returns player -> message (missing = no reply).
function Coordinator.collect(kind: string, runId: number, players: { Player }, timeout: number): { [Player]: any }
	local k = key(kind, runId)
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		local box = inbox[k] or {}
		local missing = false
		for _, player in players do
			if box[player] == nil and player.Parent == Players then
				missing = true
				break
			end
		end
		if not missing then
			break
		end
		task.wait(0.1)
	end
	local box = inbox[k] or {}
	inbox[k] = nil
	return box
end

return Coordinator
