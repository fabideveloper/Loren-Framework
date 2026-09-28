--!strict

-- The server side of the order round (studio/Harness/OrderPlan.luau, specs/v2/*/Order.spec.luau)
-- and of the pre-HELLO outbox check. Handshake with every client:
--   client Order("ready", relSeq) -> once every player is ready: Ctl("arm", role, roles) to each
--   client holds its Hold calls, then Order("armed") -> once every player is armed: the steps run
--   (explicit Loren.Flush() between frames), the unreliable size probe, then
--   Ctl("done", exactBlobLen, controlBlobLen).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Loren: any = require(ReplicatedStorage.Shared.Loren)
local C: any = require(ReplicatedStorage.LorenRuntime.Constants)
local OrderPlan = require(ReplicatedStorage.LorenTest.Harness.OrderPlan)
local T = Loren.T

local FIXTURE_FOLDER = "OrderFixture" -- ReplicatedStorage.OrderFixture: R1, R2, R3 (replicated to everyone)
local HIDDEN = "OrderHidden" -- ServerStorage.OrderHidden: never replicated
local GUI = "OrderFixture" -- PlayerGui.OrderFixture: replicated to its player only
local TAG_MAX = 32
local BLOB_MAX = 1000
local BLOB_PROBE = 950 -- over the limit on purpose: its error names the message size
local BLOB_SENDS = 3
local BLOB_CONTROL_ID = 8 -- 800 B messages: they tell an engine cap below 900 B from a Loren bug
local BLOB_CONTROL_LESS = 100
local BLOB_OVER_ID = 9
local NOTICE_OFFSET = 20000 -- NOTICE seqs far ahead of the client's reliable seq: no call or ring slot matches
local DROP_OFFSET = 30000
local ARM_WAIT = 20 -- seconds for every armed report once "arm" went out
local LIST_MAX = 64

local function weakKeys(): any
	return setmetatable({}, { __mode = "k" })
end

local Probe = {
	earlyArmed = false, -- the pre-HELLO fires run in the check scenario only (see LorenBurn)
	early = weakKeys() :: { [Player]: { helloed: any, dropDelta: number?, error: string? } },
	guiMissing = {} :: { string },
	holds = 0,
	started = false,
	done = false,
	players = {} :: { [string]: string }, -- player name -> role
	errors = {} :: { string },
	blob = nil :: { [string]: any }?,
}

local OrderService: any = {
	Dependencies = {},
	Client = {},
	Signals = { "Seq", "Obj", "Req", "Pos", "Blob", "Ctl", "Early", "UEarly" },
	ClientEvents = { "Order" },
	Spec = {
		Hold = Loren.Method({ Timeout = 30 }),
		Obj = Loren.Signal(T.string(TAG_MAX), T.optional(T.Instance()), T.string(TAG_MAX)),
		Req = Loren.Signal(T.string(TAG_MAX), T.Instance(), T.string(TAG_MAX)),
		Pos = Loren.Signal(T.u16), -- fixed size (the B9 S7/C6 fast paths)
		Blob = Loren.Signal(T.u8, T.string(BLOB_MAX), { Unreliable = true }),
		UEarly = Loren.Signal(T.string(TAG_MAX), { Unreliable = true }), -- unreliable members must be typed
	},
	Probe = Probe,
	BlobSends = BLOB_SENDS,
}

local gates: { [Player]: { [string]: thread } } = weakKeys()
local ready: { [Player]: number } = weakKeys() -- the client's reliable seq at "ready"
local armed: { [Player]: boolean } = weakKeys()
local rolePlayer: { [string]: Player } = {}
local roleList: { string } = {}
local armSent = false
local refs: { [string]: Instance } = {}

-- [[ Helpers ]]

local function push(list: { string }, text: string)
	if #list < LIST_MAX then
		table.insert(list, text)
	end
end

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and (value :: Instance):IsA("Player")
end

-- The runtime's server outbox (test only): NOTICEs at chosen points of the round.
local function outbox(): any
	return require(ServerScriptService:WaitForChild("LorenServer"):WaitForChild("Outbox")) :: any
end

local function fire(signal: string, method: string, ...: any)
	local ok, err = pcall(function(...: any)
		local sig = OrderService.Signals[signal]
		sig[method](sig, ...)
	end, ...)
	if not ok then
		push(Probe.errors, string.format("%s:%s failed: %s", signal, method, tostring(err)))
	end
end

-- [[ Instances ]]

local function ensureInstances()
	local folder = ReplicatedStorage:FindFirstChild(FIXTURE_FOLDER)
	if folder == nil then
		local created = Instance.new("Folder")
		created.Name = FIXTURE_FOLDER
		for _, name in { "R1", "R2", "R3" } do
			local child = Instance.new("Folder")
			child.Name = name
			child.Parent = created
		end
		created.Parent = ReplicatedStorage
		folder = created
	end
	for _, name in { "R1", "R2", "R3" } do
		refs[name] = (folder :: Instance):WaitForChild(name)
	end
	local hidden = ServerStorage:FindFirstChild(HIDDEN)
	if hidden == nil then
		local created = Instance.new("Folder")
		created.Name = HIDDEN
		created.Parent = ServerStorage
		hidden = created
	end
	refs.hidden = hidden :: Instance
	local orphan = Instance.new("Folder")
	orphan.Name = "OrderOrphan" -- never parented: no client ever has it
	refs.orphan = orphan
end

local function ensureGui(player: Player)
	local gui = player:WaitForChild("PlayerGui", 30)
	if gui == nil then
		push(Probe.guiMissing, player.Name)
		return
	end
	if gui:FindFirstChild(GUI) == nil then
		local screen = Instance.new("ScreenGui")
		screen.Name = GUI
		screen.ResetOnSpawn = false
		screen.Parent = gui
	end
end

local function instanceFor(ref: string): Instance?
	if string.sub(ref, 1, 4) == "gui:" then
		local player = rolePlayer[string.sub(ref, 5)]
		local gui = player and player:FindFirstChild("PlayerGui")
		return gui and gui:FindFirstChild(GUI)
	end
	return refs[ref]
end

-- [[ Pre-HELLO outbox: one reliable and one unreliable Fire to every player before its HELLO ]]

local function sendEarly(player: Player)
	if Probe.early[player] ~= nil then
		return
	end
	local record: { helloed: any, dropDelta: number?, error: string? } = { helloed = nil, dropDelta = nil, error = nil }
	Probe.early[player] = record
	local ok, err = pcall(function()
		local before = Loren.GetStats().SignalsDropped
		OrderService.Signals.Early:Fire(player, "early", player.UserId)
		OrderService.Signals.UEarly:Fire(player, "uearly")
		record.dropDelta = Loren.GetStats().SignalsDropped - before
		local ps = outbox().get(player)
		record.helloed = if ps then ps.helloed else "no player state"
	end)
	if not ok then
		record.error = tostring(err)
	end
	task.spawn(ensureGui, player)
end

-- [[ The round ]]

local function release(player: Player, key: string, mode: string, tag: string)
	local mine = gates[player]
	local thread = mine and mine[key]
	if thread == nil then
		push(Probe.errors, string.format("no Hold(%q) call from %s to release", key, player.Name))
		return
	end
	(mine :: { [string]: thread })[key] = nil
	task.spawn(thread, mode, tag)
end

local function playersOf(set: { string }): { Player }
	local out: { Player } = {}
	for _, role in set do
		table.insert(out, rolePlayer[role])
	end
	return out
end

local function runStep(step: OrderPlan.Step, noticeSeq: { [Player]: number }, dropSeq: { [Player]: number })
	local op = step.op
	if op == "flush" then
		Loren.Flush()
		return
	elseif op == "wait" then
		task.wait()
		return
	end
	local target: Player? = if step.to then rolePlayer[step.to] else nil
	if op == "ok" or op == "err" or op == "okFire" then
		local mode = if op == "okFire" then "fire" else op
		release(target :: Player, step.key :: string, mode, step.tag :: string)
		return
	elseif op == "notice" or op == "drop" then
		local ps = outbox().get(target)
		if ps == nil or not ps.helloed then
			push(Probe.errors, string.format("%s: no helloed player state for role %s", op, tostring(step.to)))
			return
		end
		local player = target :: Player
		if op == "notice" then
			outbox().notice(ps, C.Notice.FrameDropped, noticeSeq[player], step.count)
		else
			for _ = 1, step.count :: number do
				outbox().recordDrop(ps, false, dropSeq[player])
				dropSeq[player] = (dropSeq[player] + 1) % 65536
			end
		end
		return
	end
	local sig = step.sig or "Seq"
	local args: { any } = { if sig == "Pos" then tonumber(step.tag) else step.tag }
	if step.ref ~= nil then
		args = { step.tag, instanceFor(step.ref), step.after }
	end
	local n = if step.ref ~= nil then 3 else 1
	if op == "fire" then
		fire(sig, "Fire", target, table.unpack(args, 1, n))
	elseif op == "all" then
		fire(sig, "FireAll", table.unpack(args, 1, n))
	elseif op == "for" then
		fire(sig, "FireFor", playersOf(step.set or {}), table.unpack(args, 1, n))
	elseif op == "except" then
		local except: any = if target then target else playersOf(step.set or {})
		fire(sig, "FireExcept", except, table.unpack(args, 1, n))
	else
		push(Probe.errors, "unknown step op " .. op)
	end
end

-- The unreliable size limit: the probe's error names its size, so the exact-limit payload is known.
local function blobRound()
	local blob = OrderService.Signals.Blob
	local record: { [string]: any } = { exactErrors = {} }
	Probe.blob = record
	local probed, probeErr = pcall(function()
		blob:FireAll(0, string.rep("b", BLOB_PROBE))
	end)
	local size = if probed then nil else tonumber(string.match(tostring(probeErr), "the message is (%d+) bytes"))
	if size == nil then
		push(Probe.errors, "the over-limit Blob probe did not raise the size error: " .. tostring(probeErr))
		return
	end
	local exact = C.Limit.UNRELIABLE_SEAL - (size - BLOB_PROBE)
	local control = exact - BLOB_CONTROL_LESS
	record.exact = exact
	record.control = control
	record.sent = 0
	record.controlSent = 0
	record.controlErrors = {}
	for i = 1, BLOB_SENDS do
		local sent, err = pcall(function()
			blob:FireAll(i, string.rep("b", exact))
		end)
		if sent then
			record.sent += 1
		else
			push(record.exactErrors, tostring(err))
		end
		local controlSent, controlErr = pcall(function()
			blob:FireAll(BLOB_CONTROL_ID, string.rep("c", control))
		end)
		if controlSent then
			record.controlSent += 1
		else
			push(record.controlErrors, tostring(controlErr))
		end
		Loren.Flush()
	end
	local someone = rolePlayer.A
	local before = Loren.GetStats()
	local overAll, overAllErr = pcall(function()
		blob:FireAll(BLOB_OVER_ID, string.rep("b", exact + 1))
	end)
	local overOne, overOneErr = pcall(function()
		blob:Fire(someone, BLOB_OVER_ID, string.rep("b", exact + 1))
	end)
	local after = Loren.GetStats()
	record.overAllRaised = not overAll
	record.overAllError = tostring(overAllErr)
	record.overOneRaised = not overOne
	record.overOneError = tostring(overOneErr)
	record.messagesDelta = after.MessagesOut - before.MessagesOut
	record.droppedDelta = after.SignalsDropped - before.SignalsDropped
	Loren.Flush()
end

local function runRound()
	local noticeSeq: { [Player]: number } = {}
	local dropSeq: { [Player]: number } = {}
	for _, player in rolePlayer do
		local seq = ready[player] or 0
		noticeSeq[player] = (seq + NOTICE_OFFSET) % 65536
		dropSeq[player] = (seq + DROP_OFFSET) % 65536
	end
	for _, role in roleList do
		local player = rolePlayer[role]
		for _, key in OrderPlan.keys(role, roleList) do
			if gates[player] == nil or gates[player][key] == nil then
				push(
					Probe.errors,
					string.format("%s (role %s) holds no Hold(%q) call at the start", player.Name, role, key)
				)
			end
		end
	end
	local ok, err = pcall(function()
		for _, step in OrderPlan.steps(roleList) do
			runStep(step, noticeSeq, dropSeq)
		end
		blobRound()
	end)
	if not ok then
		push(Probe.errors, "the round crashed: " .. tostring(err))
	end
	for player, mine in gates do
		for key in mine do
			push(Probe.errors, string.format("Hold(%q) from %s was never released by the steps", key, player.Name))
			release(player, key, "ok", "unused")
		end
	end
	local blob = Probe.blob
	fire("Ctl", "FireAll", "done", if blob then blob.exact else nil, if blob then blob.control else nil)
	Loren.Flush()
	Probe.done = true
end

local function allIn(set: { [Player]: any }, players: { Player }): boolean
	for _, player in players do
		if player.Parent == Players and set[player] == nil then
			return false
		end
	end
	return true
end

local function tryArm()
	local players = Players:GetPlayers()
	if armSent or #players == 0 or not allIn(ready, players) then
		return
	end
	armSent = true
	table.sort(players, function(a: Player, b: Player): boolean
		return a.Name < b.Name
	end)
	for i, player in players do
		local role = OrderPlan.ROLES[i] or ("Z" .. i)
		rolePlayer[role] = player
		table.insert(roleList, role)
		Probe.players[player.Name] = role
	end
	for _, role in roleList do
		fire("Ctl", "Fire", rolePlayer[role], "arm", role, roleList) -- sent by the next Heartbeat flush
	end
	task.spawn(function()
		local members: { Player } = {}
		for _, role in roleList do
			table.insert(members, rolePlayer[role])
		end
		local deadline = os.clock() + ARM_WAIT
		while not allIn(armed, members) and os.clock() < deadline do
			task.wait(0.05)
		end
		if not allIn(armed, members) then
			push(Probe.errors, "not every player sent armed within " .. ARM_WAIT .. " s")
		end
		Probe.started = true
		runRound()
	end)
end

local function onOrder(player: any, command: any, value: any)
	if not isPlayer(player) then
		return
	end
	if command == "ready" and type(value) == "number" and value == value then
		if ready[player] == nil then
			ready[player] = math.floor(value) % 65536
			tryArm()
		end
	elseif command == "armed" then
		armed[player] = true
	end
end

-- [[ Methods ]]

-- Parks until the round releases it: ("ok", tag) replies tag, ("err", tag) rejects with tag,
-- ("fire", tag) fires Seq(tag .. "s") to the caller first, then replies tag.
function OrderService.Client:Hold(player: Player, key: any): any
	if type(key) ~= "string" or #key == 0 or #key > 16 then
		return Loren.Reject("OrderService.Hold: bad key")
	end
	local mine = gates[player]
	if mine == nil then
		mine = {}
		gates[player] = mine
	end
	if (mine :: { [string]: thread })[key] ~= nil then
		return Loren.Reject("OrderService.Hold: key already held")
	end
	(mine :: { [string]: thread })[key] = coroutine.running()
	Probe.holds += 1
	local mode, tag = coroutine.yield()
	if mode == "err" then
		return Loren.Reject(tag)
	elseif mode == "fire" then
		fire("Seq", "Fire", player, tag .. "s")
	end
	return tag
end

-- [[ Lifecycle ]]

function OrderService:LorenIgnite()
	ensureInstances()
	self.ClientEvents.Order:Connect(onOrder)
end

function OrderService:LorenBurn()
	-- Only when the check runs (its specs read the probe): the UnreliableEarly drop prints a Violations
	-- summary 30 s after each join, which the stress/security/soak/compare runs would count as log spam.
	local config = ReplicatedStorage:FindFirstChild("TestConfig")
	local scenario = if config then config:GetAttribute("Scenario") else nil
	scenario = if type(scenario) == "string" then string.lower(scenario) else nil
	if scenario ~= "check" and scenario ~= "all" then
		return
	end
	Probe.earlyArmed = true
	-- Before Transport.open (boot step 10): no player can have sent HELLO yet.
	for _, player in Players:GetPlayers() do
		sendEarly(player)
	end
	Players.PlayerAdded:Connect(sendEarly)
end

return OrderService
