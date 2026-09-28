--!strict
--!optimize 2

-- TestConfig attributes for the bench place, read the same way on the server and the clients.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = {}

export type Settings = {
	Scenario: string,
	Library: string,
	Payload: string,
	Seconds: number,
	Runs: number,
	Warmup: number,
	libs: { string },
	runtimes: { string },
	payloads: { string },
	problem: string?,
}

-- Result rows run in this order; "loren-untyped" shares the Loren runtime.
Config.LIBS = { "loren", "loren-untyped", "blinkblox", "blink", "bytenet", "bridgenet2" }

-- Runtimes set up in this order: BridgeNet2 first (it must see every PlayerAdded), Loren last (it yields).
Config.RUNTIMES = { "bridgenet2", "bytenet", "blink", "blinkblox", "loren" }

Config.RUNTIME_OF = {
	loren = "loren",
	["loren-untyped"] = "loren",
	blinkblox = "blinkblox",
	blink = "blink",
	bytenet = "bytenet",
	bridgenet2 = "bridgenet2",
} :: { [string]: string }

Config.CORE = { "bool1000", "randbool1000", "entity100", "randentity100", "fireall100", "c2s1000" }
Config.EXTRA = { "mixed", "boolarray", "pose100", "entity100u", "c2s1000u" }

Config.DEFAULTS = { Scenario = "bench", Library = "all", Payload = "all", Seconds = 5, Runs = 3, Warmup = 2 }

local function readNumber(config: Instance, name: string, fallback: number, lo: number, hi: number): number
	local value = config:GetAttribute(name)
	if typeof(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.clamp(math.floor(value), lo, hi)
end

local function readString(config: Instance, name: string, fallback: string): string
	local value = config:GetAttribute(name)
	if typeof(value) ~= "string" or value == "" then
		return fallback
	end
	return string.lower((string.gsub(value, "%s", "")))
end

local function contains(list: { string }, value: string): boolean
	return table.find(list, value) ~= nil
end

function Config.read(): Settings
	local d = Config.DEFAULTS
	local config: Instance = ReplicatedStorage:FindFirstChild("TestConfig") or Instance.new("Configuration")
	local settings: Settings = {
		Scenario = readString(config, "Scenario", d.Scenario),
		Library = readString(config, "Library", d.Library),
		Payload = readString(config, "Payload", d.Payload),
		Seconds = readNumber(config, "Seconds", d.Seconds, 1, 60),
		Runs = readNumber(config, "Runs", d.Runs, 1, 15),
		Warmup = readNumber(config, "Warmup", d.Warmup, 0, 10),
		libs = {},
		runtimes = {},
		payloads = {},
		problem = nil,
	}

	local lib = settings.Library
	if lib == "all" then
		settings.libs = table.clone(Config.LIBS)
	elseif lib == "loren" then
		settings.libs = { "loren", "loren-untyped" }
	elseif contains(Config.LIBS, lib) then
		settings.libs = { lib }
	else
		settings.problem = "unknown Library '" .. lib .. "' (all, loren, blinkblox, blink, bytenet, bridgenet2)"
	end
	for _, runtime in Config.RUNTIMES do
		for _, name in settings.libs do
			if Config.RUNTIME_OF[name] == runtime then
				table.insert(settings.runtimes, runtime)
				break
			end
		end
	end

	local payload = settings.Payload
	if payload == "all" then
		settings.payloads = table.clone(Config.CORE)
	elseif payload == "extra" then
		settings.payloads = table.clone(Config.EXTRA)
	else
		for name in string.gmatch(payload, "[^,]+") do
			if contains(Config.CORE, name) or contains(Config.EXTRA, name) then
				table.insert(settings.payloads, name)
			else
				settings.problem = "unknown Payload '"
					.. name
					.. "' (all, extra, "
					.. table.concat(Config.CORE, ", ")
					.. ", "
					.. table.concat(Config.EXTRA, ", ")
					.. ")"
			end
		end
	end
	return settings
end

return Config
