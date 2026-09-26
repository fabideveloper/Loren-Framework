--!strict
--!optimize 2

local Instrument = {}

export type MethodStats = { calls: number, errors: number, denied: number, time: number, maxTime: number }

local stats: { [string]: MethodStats } = {}
local wrapped: { [any]: boolean } = {}

local function statFor(name: string): MethodStats
	local s = stats[name]
	if not s then
		s = { calls = 0, errors = 0, denied = 0, time = 0, maxTime = 0 }
		stats[name] = s
	end
	return s
end

local function finish(stat: MethodStats, started: number, ok: boolean, ...: any): ...any
	local elapsed = os.clock() - started
	stat.calls += 1
	stat.time += elapsed
	if elapsed > stat.maxTime then
		stat.maxTime = elapsed
	end
	if not ok then
		stat.errors += 1
		error((...), 0) -- same error value the handler raised
	end
	return ...
end

local function countDenial(stat: MethodStats, ...: any): ...any
	if (...) ~= true then
		stat.denied += 1
	end
	return ...
end

function Instrument.wrapService(serviceName: string, service: any)
	if typeof(service) ~= "table" or wrapped[service] then
		return
	end
	wrapped[service] = true
	local client = service.Client
	if typeof(client) == "table" then
		for methodName, fn in client do
			if typeof(methodName) == "string" and typeof(fn) == "function" then
				local stat = statFor(serviceName .. "." .. methodName)
				client[methodName] = function(...)
					return finish(stat, os.clock(), pcall(fn, ...))
				end
			end
		end
	end
	local middleware = service.Middleware
	if typeof(middleware) == "table" then
		for methodName, fn in middleware do
			if typeof(methodName) == "string" and typeof(fn) == "function" then
				local stat = statFor(serviceName .. "." .. methodName)
				middleware[methodName] = function(...)
					return countDenial(stat, fn(...))
				end
			end
		end
	end
end

function Instrument.snapshot(): { [string]: MethodStats }
	local copy = {}
	for name, s in stats do
		copy[name] = table.clone(s)
	end
	return copy
end

function Instrument.reset()
	for _, s in stats do
		s.calls, s.errors, s.denied, s.time, s.maxTime = 0, 0, 0, 0, 0
	end
end

return Instrument
