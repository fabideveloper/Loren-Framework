--!strict
--[[
	Helpers for specs/v2/client (not a spec: the runner only collects "*.spec" modules).

	Client specs test through the public API: the Loren facade, the V2Service proxy and V2Controller.
	Several clients run these specs at once, and Signals.Hit broadcasts ("hitExcept") reach every
	other client, so every check filters deliveries by a tag unique to this client and call.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Env = require(ReplicatedStorage.LorenTest.Harness.Env)
local C = require(ReplicatedStorage.LorenRuntime.Constants)

local V2 = {}

-- Mirrors of the V2Service texts (fixtures/v2/Services/V2Service.luau).
V2.Texts = table.freeze({
	Boom = "V2 Boom: the handler failed on purpose",
	MwThrow = "V2 MwThrow: the middleware failed on purpose",
	MwDotDenied = "V2 MwDot: denied",
	MwPromiseDenied = "V2 MwPromise: denied",
	PromiseRejected = "V2 ReturnPromise: rejected on purpose",
})
V2.HEX8 = "^%x%x%x%x%x%x%x%x$"
V2.C = C

local counter = 0

function V2.loren(): any
	return Env.Loren
end

function V2.proxy(): any
	return Env.Loren.GetService("V2Service")
end

function V2.controller(): any
	return Env.Loren.GetController("V2Controller")
end

-- A tag unique to this client and call (fits T.string(64)).
function V2.tag(label: string): string
	counter += 1
	return string.format("%s:%d:%d", label, Players.LocalPlayer.UserId, counter)
end

-- A u32 unique to this client and call, growing between calls and runs.
function V2.nonce(): number
	counter += 1
	return (math.floor(os.clock() * 1000) + counter) % 4294967296
end

function V2.waitUntil(predicate: () -> any, timeout: number?): boolean
	return Env.waitUntil(predicate, timeout or 5, 0.02)
end

-- Awaits a Promise: { [1] = ok, [2..] = values or (message, info), n = count }.
function V2.settle(promise: any): { n: number, [number]: any }
	return table.pack(promise:await())
end

-- Marks a Promise handled at once (no "unhandled rejection" warning while other calls are awaited).
function V2.hold(promise: any): any
	promise:catch(function() end)
	return promise
end

-- True when the Promise was rejected before the call returned (a local rejection).
function V2.rejectedNow(promise: any): boolean
	return promise:getStatus() == "Rejected"
end

--[[
	Checks a settled rejection { false, message, info } for `code` (a Constants.ErrName) and
	returns (message, info). info must be frozen and consistent with the message.
]]
function V2.rejection(expect: any, result: { n: number, [number]: any }, code: string, member: string?): (string, any)
	expect(result[1]).toBe(false)
	local message, info = result[2], result[3]
	expect(typeof(message)).toBe("string")
	expect(typeof(info)).toBe("table")
	expect(info.Code).toBe(code)
	expect(info.CodeId).toBe((C.Err :: any)[code])
	expect(info.Message).toBe(message)
	expect(table.isfrozen(info)).toBe(true)
	expect(info.Service).toBe("V2Service")
	if member ~= nil then
		expect(info.Member).toBe(member)
	end
	return message, info
end

export type Collector = {
	list: { { n: number, [number]: any } },
	stop: () -> (),
}

-- Records every delivery of `signal` whose arguments pass `filter` (all when nil).
function V2.collect(signal: any, filter: ((...any) -> boolean)?): Collector
	local list: { { n: number, [number]: any } } = {}
	local connection = signal:Connect(function(...: any)
		if filter == nil or filter(...) then
			table.insert(list, table.pack(...))
		end
	end)
	return {
		list = list,
		stop = function()
			connection:Disconnect()
		end,
	}
end

return V2
