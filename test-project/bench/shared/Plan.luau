--!strict
--!optimize 2

local Payloads = require(script.Parent.Payloads)

local Plan = {}

export type Adapter = {
	lib: string,
	has: (event: string) -> boolean,
	toPlayer: (event: string) -> ((Player, any) -> ())?,
	toAll: (event: string) -> ((any) -> ())?,
	toServer: (event: string) -> ((any) -> ())?,
	connect: (event: string, fn: (any, any) -> ()) -> boolean,
	swapServerArgs: boolean?,
}

export type TxModel = "all" | "each" | "all+each" | "measured"

export type Runtime = {
	key: string,
	name: string,
	sender: string,
	waitRemotes: () -> { Instance },
	remotes: () -> { Instance },
	setup: () -> { [string]: Adapter },
	ready: () -> (),
	flush: (() -> ())?,
	txModel: (def: Payloads.Def) -> TxModel,
	sizeOf: ((any) -> number)?,
}

export type ServerStep = (players: { Player }, index: number) -> (number, number)
export type ClientStep = (index: number) -> (number, number)

local FRAMES = Payloads.FRAMES

function Plan.supported(adapter: Adapter, def: Payloads.Def): boolean
	return adapter.has(def.event)
end

function Plan.serverStep(adapter: Adapter, def: Payloads.Def): ServerStep?
	local frames = Payloads.pool(def).frames
	if def.mode == "all" then
		local fire = adapter.toAll(def.event)
		if fire == nil then
			return nil
		end
		local fireAll: (any) -> () = fire
		return function(_players: { Player }, index: number): (number, number)
			local frame = frames[index % FRAMES + 1]
			Payloads.stamp(def, frame, index)
			local n = #frame
			local t0 = os.clock()
			for i = 1, n do
				fireAll(frame[i])
			end
			return n, os.clock() - t0
		end
	elseif def.mode == "mixed" then
		local all, one = adapter.toAll(def.event), adapter.toPlayer(def.event)
		if all == nil or one == nil then
			return nil
		end
		local fireAll: (any) -> () = all
		local fireTo: (Player, any) -> () = one
		local pre, count = Payloads.MIXED_PRE, Payloads.MIXED_ALL
		return function(players: { Player }, index: number): (number, number)
			local frame = frames[index % FRAMES + 1]
			Payloads.stamp(def, frame, index)
			local t0 = os.clock()
			for _, player in players do
				for i = 1, pre do
					fireTo(player, frame[i])
				end
			end
			for i = pre + 1, pre + count do
				fireAll(frame[i])
			end
			for _, player in players do
				for i = pre + count + 1, pre * 2 + count do
					fireTo(player, frame[i])
				end
			end
			return pre * 2 * #players + count, os.clock() - t0
		end
	end
	return nil
end

function Plan.clientStep(adapter: Adapter, def: Payloads.Def): ClientStep?
	local fire = adapter.toServer(def.event)
	if fire == nil then
		return nil
	end
	local send: (any) -> () = fire
	local frames = Payloads.pool(def).frames
	return function(index: number): (number, number)
		local frame = frames[index % FRAMES + 1]
		Payloads.stamp(def, frame, index)
		local n = #frame
		local t0 = os.clock()
		for i = 1, n do
			send(frame[i])
		end
		return n, os.clock() - t0
	end
end

function Plan.txCalls(model: TxModel, rx: { number }): number?
	local total = 0
	for _, v in rx do
		total += v
	end
	local n = #rx
	if n == 0 or model == "measured" then
		return nil
	elseif model == "all" then
		return total / n
	elseif model == "each" then
		return total
	end
	return 1 + total - n
end

function Plan.rotate(list: { string }, r: number): { string }
	local n = #list
	local out = table.create(n) :: { string }
	for i = 1, n do
		out[i] = list[(i - 1 + r - 1) % n + 1]
	end
	return out
end

Plan.RUN_OVERHEAD = 1.6
Plan.IDLE_SECONDS = 2
Plan.GAP_SECONDS = 1

function Plan.eta(
	payloads: { string },
	libsFor: (string) -> number,
	seconds: number,
	runs: number,
	warmup: number
): number
	local total = Plan.IDLE_SECONDS
	for _, name in payloads do
		local libs = libsFor(name)
		total += Plan.IDLE_SECONDS
		if warmup > 0 then
			total += libs * (warmup + Plan.RUN_OVERHEAD)
		end
		total += runs * libs * (seconds + Plan.RUN_OVERHEAD)
	end
	return total
end

return Plan
