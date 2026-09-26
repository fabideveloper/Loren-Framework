--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loren: any = require(ReplicatedStorage.Shared.Loren)

local LATE_CONNECT = 1 -- seconds after LorenBurn; well inside BacklogWindow (10 s after Ready)

local Probe = {
	ignite = nil :: any,
	burnReady = nil :: any,
	connectedAt = nil :: number?,
	connectError = nil :: string?,
	boot = {} :: { { kind: any, n: any, at: number } },
}

local V2Controller: any = {
	Dependencies = { "V2Service" },
	Probe = Probe,
	LateConnect = LATE_CONNECT,
}

function V2Controller:LorenIgnite()
	local proxy = self.Dependencies.V2Service
	local found, service = pcall(Loren.GetService, "V2Service")
	Probe.ignite = {
		State = Loren.State,
		IsReady = Loren.IsReady,
		IsOnFire = Loren.IsOnFire,
		HasProxy = proxy ~= nil,
		SameProxy = found and proxy ~= nil and rawequal(service, proxy),
	}
end

function V2Controller:LorenBurn()
	local proxy = self.Dependencies.V2Service
	task.delay(LATE_CONNECT, function()
		Probe.connectedAt = os.clock()
		local ok, err = pcall(function()
			proxy.Signals.BootSignal:Connect(function(kind: any, n: any)
				if #Probe.boot < 16 then
					table.insert(Probe.boot, { kind = kind, n = n, at = os.clock() })
				end
			end)
		end)
		if not ok then
			Probe.connectError = tostring(err)
		end
	end)

	local resolved, value = Loren.OnReady():await()
	Probe.burnReady = {
		ok = resolved,
		SameLoren = rawequal(value, Loren),
		State = Loren.State,
		IsReady = Loren.IsReady,
	}
end

return V2Controller
